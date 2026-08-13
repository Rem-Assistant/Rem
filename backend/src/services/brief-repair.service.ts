import { createHash, randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import { pool } from '../db/pool.js';
import {
  readAssistantHistoryOnGateway,
  type GatewayAssistantHistoryMessage,
} from './gateway-agent.service.js';
import {
  extractBriefHeadline,
  localBriefDate,
  localTimeOfDay,
  resolveStoredUserTimezone,
  summarizeBriefLead,
  type TimeOfDay,
} from './brief-authoring.service.js';

export const DURABLE_BRIEF_SESSION_KEY = 'rem-orchestrator';

export type BriefRepairFailureCode =
  | 'invalid_arguments'
  | 'timezone_missing'
  | 'history_failed'
  | 'message_not_found'
  | 'message_id_required'
  | 'message_ambiguous'
  | 'user_not_found'
  | 'database_identity_mismatch'
  | 'repair_busy';

export class BriefRepairError extends Error {
  constructor(
    readonly code: BriefRepairFailureCode,
    message: string,
  ) {
    super(message);
    this.name = 'BriefRepairError';
  }
}

export interface BriefRepairOptions {
  userId: string;
  localDay: string;
  transcriptDigest: string;
  messageId?: string;
  commit: boolean;
}

export interface BriefRepairResult {
  mode: 'dry-run' | 'committed';
  localDay: string;
  authoredSlot: TimeOfDay;
  transcriptDigest: string;
  messageIdVerified: boolean;
  invalidatedFallbackArtifacts: number;
  invalidatedFallbackCacheRows: number;
  alreadyAdopted: boolean;
}

interface RepairDatabase {
  connect(): Promise<PoolClient>;
}

interface BriefRepairDependencies {
  database: RepairDatabase;
  resolveTimezone(userId: string): Promise<string | null>;
  readHistory(opts: {
    userId: string;
    sessionKey: string;
    limit?: number;
  }): ReturnType<typeof readAssistantHistoryOnGateway>;
}

const defaultDependencies: BriefRepairDependencies = {
  database: pool,
  resolveTimezone: resolveStoredUserTimezone,
  readHistory: readAssistantHistoryOnGateway,
};

// SHA-256("<current_database>:<pg_control_system.system_identifier>") for the durable staging
// Postgres cluster. This second, database-resident gate prevents a production DATABASE_URL from
// being paired with forged Railway environment variables. A restored/replaced staging cluster must
// be deliberately re-fingerprinted before this exceptional repair can commit again.
export const STAGING_DATABASE_FINGERPRINT = '9dbbd60e70fdececd184fb18b38cee82dafe09d4675b84e5c3af6589a4fa2188';

export async function assertStagingDatabaseIdentity(client: PoolClient): Promise<void> {
  const identity = await client.query<{ database_name: string; system_identifier: string }>(
    `SELECT current_database() AS database_name,
            system_identifier::text AS system_identifier
       FROM pg_control_system()`,
  );
  const row = identity.rows[0];
  const actual = row
    ? createHash('sha256')
        .update(`${row.database_name}:${row.system_identifier}`, 'utf8')
        .digest('hex')
    : '';
  if (actual !== STAGING_DATABASE_FINGERPRINT) {
    throw new BriefRepairError(
      'database_identity_mismatch',
      'connected database is not the pinned staging cluster',
    );
  }
}

export function transcriptMessageDigest(text: string): string {
  return createHash('sha256').update(text.trim(), 'utf8').digest('hex');
}

function parseTranscriptTimestamp(value: number | string | null): Date | null {
  if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
    const seconds = value > 10_000_000_000 ? value / 1_000 : value;
    const date = new Date(seconds * 1_000);
    return Number.isNaN(date.getTime()) ? null : date;
  }
  if (typeof value === 'string' && value.trim()) {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }
  return null;
}

function validateOptions(opts: BriefRepairOptions): BriefRepairOptions {
  const userId = opts.userId.trim();
  const localDay = opts.localDay.trim();
  const transcriptDigest = opts.transcriptDigest.trim().toLowerCase();
  const messageId = opts.messageId?.trim() || undefined;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
    throw new BriefRepairError('invalid_arguments', 'user id must be a UUID');
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(localDay)) {
    throw new BriefRepairError('invalid_arguments', 'local day must be YYYY-MM-DD');
  }
  if (!/^[0-9a-f]{64}$/.test(transcriptDigest)) {
    throw new BriefRepairError('invalid_arguments', 'transcript digest must be a SHA-256 hex digest');
  }
  return { ...opts, userId, localDay, transcriptDigest, messageId };
}

export interface VerifiedBriefMessage {
  text: string;
  timestamp: Date;
  messageId: string | null;
}

/** Select only an explicitly identified transcript message; ordering is never used as identity. */
export function selectVerifiedBriefMessage(
  messages: GatewayAssistantHistoryMessage[],
  opts: Pick<BriefRepairOptions, 'localDay' | 'transcriptDigest' | 'messageId'>,
  timezone: string,
): VerifiedBriefMessage {
  const digestMatches = messages.flatMap((message): VerifiedBriefMessage[] => {
    const timestamp = parseTranscriptTimestamp(message.timestamp);
    if (!timestamp || localBriefDate(timestamp, timezone) !== opts.localDay) return [];
    if (transcriptMessageDigest(message.text) !== opts.transcriptDigest) return [];
    return [{ text: message.text.trim(), timestamp, messageId: message.messageId }];
  });

  if (!opts.messageId && digestMatches.some((message) => message.messageId)) {
    throw new BriefRepairError(
      'message_id_required',
      'the gateway exposes message identity; rerun with the exact message id',
    );
  }
  const matches = opts.messageId
    ? digestMatches.filter((message) => message.messageId === opts.messageId)
    : digestMatches;

  if (matches.length === 0) {
    throw new BriefRepairError('message_not_found', 'no current-day transcript message matched the required identity');
  }
  if (matches.length !== 1) {
    throw new BriefRepairError('message_ambiguous', 'multiple transcript messages matched; require a unique message id');
  }
  return matches[0];
}

async function adoptVerifiedBrief(
  client: PoolClient,
  opts: BriefRepairOptions,
  verified: VerifiedBriefMessage,
  slot: TimeOfDay,
): Promise<Omit<BriefRepairResult, 'mode' | 'localDay' | 'authoredSlot' | 'transcriptDigest' | 'messageIdVerified'>> {
  const user = await client.query(
    `SELECT id FROM users WHERE id = $1::uuid FOR UPDATE`,
    [opts.userId],
  );
  if (user.rows.length !== 1) {
    throw new BriefRepairError('user_not_found', 'target staging user does not exist');
  }

  // Lock every artifact for this user/day before inspecting lifecycle state. Authoring completion
  // and delivery preparation both update/lock these same rows, so this is the shared fence that
  // prevents the exceptional repair from clearing a live worker's lease or delivery proof.
  const artifactLifecycle = await client.query<{
    id: string;
    authoring_active: boolean;
    delivery_fence_active: boolean;
  }>(
    `SELECT id,
            authoring_lease_expires_at > NOW() AS authoring_active,
            delivery_fence_expires_at > NOW() AS delivery_fence_active
       FROM daily_brief_artifacts
      WHERE user_id = $1::uuid AND brief_date = $2::date
      FOR UPDATE`,
    [opts.userId, opts.localDay],
  );
  if (artifactLifecycle.rows.some((row) => row.authoring_active || row.delivery_fence_active)) {
    throw new BriefRepairError('repair_busy', 'brief authoring or delivery is active; retry after it settles');
  }
  const artifactIds = artifactLifecycle.rows.map((row) => row.id);
  if (artifactIds.length > 0) {
    const activeDelivery = await client.query(
      `SELECT artifact_id
         FROM daily_brief_artifact_deliveries
        WHERE artifact_id = ANY($1::uuid[]) AND state = 'delivering'
        FOR UPDATE`,
      [artifactIds],
    );
    if (activeDelivery.rows.length > 0) {
      throw new BriefRepairError('repair_busy', 'brief delivery is active; retry after it settles');
    }
  }

  const existing = await client.query<{
    id: string;
    revision: string;
    markdown: string;
    summary: string | null;
    source: 'gateway' | 'fallback';
    authoring_active: boolean;
    delivery_fence_active: boolean;
    delivery_active: boolean;
  }>(
    `SELECT a.id, a.revision, a.markdown, a.summary, a.source,
            a.authoring_lease_expires_at > NOW() AS authoring_active,
            a.delivery_fence_expires_at > NOW() AS delivery_fence_active,
            EXISTS (
              SELECT 1 FROM daily_brief_artifact_deliveries d
               WHERE d.artifact_id = a.id AND d.state = 'delivering'
            ) AS delivery_active
       FROM daily_brief_artifacts a
      WHERE a.user_id = $1::uuid AND a.brief_date = $2::date AND a.authored_slot = $3
      FOR UPDATE`,
    [opts.userId, opts.localDay, slot],
  );
  const selectedArtifact = existing.rows[0];
  if (selectedArtifact
      && (selectedArtifact.authoring_active
        || selectedArtifact.delivery_fence_active
        || selectedArtifact.delivery_active)) {
    throw new BriefRepairError('repair_busy', 'brief authoring or delivery became active; retry after it settles');
  }

  // #1213 fallback artifacts are invalidated only for this explicitly targeted user/day and only
  // after both the day scan and exact-slot revalidation are quiet. SERIALIZABLE isolation turns a
  // concurrent phantom insert after those scans into a serialization failure rather than allowing
  // this transaction to clear its lease. Any later failure rolls all deletes back.
  const invalidatedCache = await client.query(
    `DELETE FROM daily_briefs
      WHERE user_id = $1::uuid AND brief_date = $2::date AND source = 'fallback'`,
    [opts.userId, opts.localDay],
  );
  const invalidatedArtifacts = await client.query(
    `DELETE FROM daily_brief_artifacts
      WHERE user_id = $1::uuid AND brief_date = $2::date AND source = 'fallback'`,
    [opts.userId, opts.localDay],
  );

  const existingArtifact = selectedArtifact?.source === 'gateway' ? selectedArtifact : undefined;
  const existingDelivery = existingArtifact
    ? await client.query<{ gateway_message_id: string | null }>(
        `SELECT gateway_message_id
           FROM daily_brief_artifact_deliveries
          WHERE artifact_id = $1::uuid AND artifact_revision = $2::uuid
            AND session_key = $3 AND state = 'delivered'`,
        [existingArtifact.id, existingArtifact.revision, DURABLE_BRIEF_SESSION_KEY],
      )
    : { rows: [] as { gateway_message_id: string | null }[] };
  const existingCache = existingArtifact
    ? await client.query(
        `SELECT 1 FROM daily_briefs
          WHERE user_id = $1::uuid AND brief_date = $2::date AND source = 'gateway'
            AND authored_slot = $3 AND markdown = $4`,
        [opts.userId, opts.localDay, slot, verified.text],
      )
    : { rows: [] as unknown[] };

  const delivery = existingDelivery.rows[0];
  const messageIdentityMatches = verified.messageId
    ? delivery?.gateway_message_id === verified.messageId
    : delivery !== undefined;
  const alreadyAdopted = existingArtifact?.markdown === verified.text
    && messageIdentityMatches
    && existingCache.rows.length === 1;
  if (alreadyAdopted) {
    return {
      invalidatedFallbackArtifacts: invalidatedArtifacts.rowCount ?? 0,
      invalidatedFallbackCacheRows: invalidatedCache.rowCount ?? 0,
      alreadyAdopted: true,
    };
  }

  const summary = summarizeBriefLead(verified.text);
  // Adoption re-authors the artifact from the verified transcript message, so it must re-derive
  // the headline from that same text. Leaving the column alone would strand the previous
  // artifact's title on top of different prose in both surfaces.
  const headline = extractBriefHeadline(verified.text);
  let artifactId: string;
  let revision: string;
  if (existingArtifact) {
    revision = randomUUID();
    const updated = await client.query<{ id: string }>(
      `UPDATE daily_brief_artifacts
          SET markdown = $4, summary = $5, source = 'gateway', revision = $6::uuid,
              headline = $7,
              authoring_lease_token = NULL, authoring_lease_expires_at = NULL,
              delivery_fence_expires_at = NULL, updated_at = NOW()
        WHERE id = $1::uuid AND user_id = $2::uuid AND brief_date = $3::date
        RETURNING id`,
      [existingArtifact.id, opts.userId, opts.localDay, verified.text, summary, revision, headline],
    );
    artifactId = updated.rows[0]?.id;
    if (!artifactId) throw new Error('artifact update lost ownership');
    await client.query(
      `DELETE FROM daily_brief_artifact_deliveries WHERE artifact_id = $1::uuid`,
      [artifactId],
    );
  } else {
    revision = randomUUID();
    const inserted = await client.query<{ id: string }>(
      `INSERT INTO daily_brief_artifacts
         (user_id, brief_date, authored_slot, markdown, summary, source, revision, headline)
       VALUES ($1::uuid, $2::date, $3, $4, $5, 'gateway', $6::uuid, $7)
       RETURNING id`,
      [opts.userId, opts.localDay, slot, verified.text, summary, revision, headline],
    );
    artifactId = inserted.rows[0]?.id;
    if (!artifactId) throw new Error('artifact insert returned no id');
  }

  await client.query(
    `INSERT INTO daily_brief_artifact_deliveries
       (artifact_id, session_key, state, gateway_message_id, delivered_at, artifact_revision)
     VALUES ($1::uuid, $2, 'delivered', $3, $4::timestamptz, $5::uuid)
     ON CONFLICT (artifact_id, session_key)
     DO UPDATE SET state = 'delivered', gateway_message_id = EXCLUDED.gateway_message_id,
                   delivered_at = EXCLUDED.delivered_at,
                   artifact_revision = EXCLUDED.artifact_revision,
                   lease_token = NULL, lease_expires_at = NULL, last_error = NULL,
                   updated_at = NOW()`,
    [artifactId, DURABLE_BRIEF_SESSION_KEY, verified.messageId, verified.timestamp.toISOString(), revision],
  );
  await client.query(
    `INSERT INTO daily_briefs
       (user_id, brief_date, markdown, summary, source, model, session_key, authored_slot, generated_at, conversation_seeded)
     VALUES ($1::uuid, $2::date, $3, $4, 'gateway', 'gateway', $5, $6, NOW(), TRUE)
     ON CONFLICT (user_id, brief_date)
     DO UPDATE SET markdown = EXCLUDED.markdown, summary = EXCLUDED.summary,
                   source = 'gateway', model = 'gateway', session_key = EXCLUDED.session_key,
                   authored_slot = EXCLUDED.authored_slot, generated_at = NOW(),
                   conversation_seeded = TRUE`,
    [opts.userId, opts.localDay, verified.text, summary, DURABLE_BRIEF_SESSION_KEY, slot],
  );

  return {
    invalidatedFallbackArtifacts: invalidatedArtifacts.rowCount ?? 0,
    invalidatedFallbackCacheRows: invalidatedCache.rowCount ?? 0,
    alreadyAdopted: false,
  };
}

/**
 * Verify first, then optionally adopt. Dry-run performs no database checkout or write.
 * Commit mode fences fallback invalidation and adoption inside one PostgreSQL transaction.
 */
export async function repairCanonicalBrief(
  rawOptions: BriefRepairOptions,
  dependencies: BriefRepairDependencies = defaultDependencies,
): Promise<BriefRepairResult> {
  const opts = validateOptions(rawOptions);
  const timezone = await dependencies.resolveTimezone(opts.userId);
  if (!timezone) {
    throw new BriefRepairError('timezone_missing', 'target user has no valid stored timezone');
  }
  const history = await dependencies.readHistory({
    userId: opts.userId,
    sessionKey: DURABLE_BRIEF_SESSION_KEY,
    limit: 500,
  });
  if (!history.ok) {
    throw new BriefRepairError('history_failed', `gateway history verification failed: ${history.reason}`);
  }
  const verified = selectVerifiedBriefMessage(history.messages, opts, timezone);
  const slot = localTimeOfDay(verified.timestamp, timezone);

  const common = {
    localDay: opts.localDay,
    authoredSlot: slot,
    transcriptDigest: opts.transcriptDigest,
    messageIdVerified: Boolean(opts.messageId && verified.messageId === opts.messageId),
  };
  if (!opts.commit) {
    return {
      mode: 'dry-run',
      ...common,
      invalidatedFallbackArtifacts: 0,
      invalidatedFallbackCacheRows: 0,
      alreadyAdopted: false,
    };
  }

  const client = await dependencies.database.connect();
  try {
    // Verify the actual Postgres cluster on this same connection before opening any transaction.
    // This is intentionally in addition to the CLI's immutable Railway environment-ID gate.
    await assertStagingDatabaseIdentity(client);
    await client.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
    const adopted = await adoptVerifiedBrief(client, opts, verified, slot);
    await client.query('COMMIT');
    return { mode: 'committed', ...common, ...adopted };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
