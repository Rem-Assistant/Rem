// Remote push (APNs) — the backend's ability to wake a closed app, which is the
// gap that unblocks proactive routines (docs/rebuild/16-ROUTINES-BUILD-PLAN.md P6,
// 09-ROUTINES-VISION.md). Until now the apps only had LOCAL notifications
// (RemClaw/Sources/Services/TaskNotificationService.swift — UNUserNotificationCenter).
//
// Mirrors OpenClaw's direct token-based APNs model (openclaw/src/infra/push-apns.ts +
// push-apns-http2.ts): mint an ES256 provider JWT (iss=teamId, kid=keyId), POST to
// /3/device/{token} over HTTP/2, sandbox vs production picks the authority. We do NOT
// port the relay transport — that's for a managed fleet; Rem talks to APNs directly.
//
// Source of truth for "where to reach a user" = the device_tokens table
// (migration 017). The app registers its token via POST /api/v1/push/register.
//
// Safe to merge without credentials: sendPush is a NO-OP (logs and returns) until
// APNS_KEY_ID / APNS_TEAM_ID / APNS_BUNDLE_ID / APNS_AUTH_KEY are all set.
import http2 from 'node:http2';
import { createPrivateKey, sign as signJwt } from 'node:crypto';
import type { PoolClient } from 'pg';
import { pool } from '../db/pool.js';
import { env } from '../config/env.js';

export type ApnsEnvironment = 'sandbox' | 'production';
export type DevicePlatform = 'ios' | 'macos';

export interface PushPayload {
  title: string;
  body: string;
  /** APNs coalescing identity. Newer pushes replace pending notifications with the same id. */
  collapseId?: string;
  /** Notification Center grouping identity, mirrored into `aps.thread-id`. */
  threadId?: string;
  /** Arbitrary key/value data delivered alongside the alert (custom aps keys). */
  data?: Record<string, unknown>;
}

export interface DeviceTokenRow {
  id: string;
  apns_token: string;
  environment: ApnsEnvironment;
  platform: DevicePlatform;
}

/** Outcome of a single per-device APNs send, surfaced for logging/telemetry. */
export interface PushSendResult {
  token: string;
  ok: boolean;
  status: number;
  reason?: string;
}

/**
 * The requested registration lost the destination-generation fence. Callers must not report a
 * successful registration for the row that still belongs to another account (or to a newer
 * sign-out tombstone). Legacy generation-0 clients can safely retry after their user-scoped
 * unregister finishes; current clients retry only with their latest installation generation.
 */
export class DeviceTokenOwnershipConflictError extends Error {
  readonly code = 'device_token_ownership_conflict';
  readonly retryable = true;

  constructor() {
    super('APNs destination ownership changed; retry registration');
    this.name = 'DeviceTokenOwnershipConflictError';
  }
}

const isLegacyInstallationId = (installationId: string): boolean =>
  installationId.startsWith('legacy:');

async function withInstallationTransaction<T>(
  installationId: string,
  operation: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // The row-level CTE locks protect established state. This transaction-scoped lock also closes
    // the empty-installation race: a concurrent first registration must finish before this
    // statement takes its fresh READ COMMITTED snapshot and retires the winner's token as a sibling.
    await client.query(
      'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
      [installationId],
    );
    const result = await operation(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

export const REGISTER_CURRENT_DEVICE_TOKEN_SQL = `WITH current_installation_rows AS MATERIALIZED (
  SELECT id, user_id, ownership_generation, enabled, updated_at
    FROM device_tokens
   WHERE installation_id = $5
   FOR UPDATE
), strongest_destination AS (
  SELECT user_id, ownership_generation, enabled, updated_at
    FROM current_installation_rows
   ORDER BY ownership_generation DESC,
            enabled DESC,
            updated_at DESC NULLS LAST,
            id DESC
   LIMIT 1
), target_destination AS MATERIALIZED (
  SELECT user_id, ownership_generation, enabled, updated_at
    FROM device_tokens
   WHERE apns_token = $2
     AND environment = $3
   FOR UPDATE
), current_fence AS MATERIALIZED (
  SELECT user_id, ownership_generation, enabled, updated_at
    FROM push_installation_fences
   WHERE installation_id = $5
   FOR UPDATE
), strongest_authority AS (
  SELECT user_id, ownership_generation, enabled
    FROM (
      SELECT user_id, ownership_generation, enabled, updated_at, 2 AS authority_priority
        FROM current_fence
      UNION ALL
      SELECT user_id, ownership_generation, enabled, updated_at, 1 AS authority_priority
        FROM strongest_destination
      UNION ALL
      SELECT user_id, ownership_generation, enabled, updated_at, 0 AS authority_priority
        FROM target_destination
    ) AS candidates
   ORDER BY ownership_generation DESC,
            authority_priority DESC,
            updated_at DESC NULLS LAST
   LIMIT 1
), claimed_installation AS (
  INSERT INTO push_installation_fences
    (installation_id, user_id, ownership_generation, enabled)
  SELECT $5, $1::uuid, $6, TRUE
   WHERE NOT EXISTS (SELECT 1 FROM strongest_authority)
      OR $6 > (SELECT ownership_generation FROM strongest_authority)
      OR (
        $6 = (SELECT ownership_generation FROM strongest_authority)
        AND (SELECT user_id FROM strongest_authority) = $1::uuid
        AND (SELECT enabled FROM strongest_authority) = TRUE
      )
  ON CONFLICT (installation_id) DO UPDATE
    SET user_id = EXCLUDED.user_id,
        ownership_generation = EXCLUDED.ownership_generation,
        enabled = TRUE,
        updated_at = NOW()
  WHERE EXCLUDED.ownership_generation > push_installation_fences.ownership_generation
     OR (
       EXCLUDED.ownership_generation = push_installation_fences.ownership_generation
       AND push_installation_fences.user_id = EXCLUDED.user_id
       AND push_installation_fences.enabled = TRUE
     )
  RETURNING installation_id, ownership_generation
), retired_siblings AS (
  DELETE FROM device_tokens
    USING claimed_installation
   WHERE device_tokens.installation_id = claimed_installation.installation_id
     AND (device_tokens.apns_token, device_tokens.environment)
         IS DISTINCT FROM ($2, $3)
     AND device_tokens.ownership_generation <= claimed_installation.ownership_generation
  RETURNING device_tokens.id
), upserted_destination AS (
  INSERT INTO device_tokens
    (user_id, apns_token, environment, platform, installation_id, ownership_generation)
  SELECT $1::uuid, $2, $3, $4, installation_id, ownership_generation
    FROM claimed_installation
  ON CONFLICT (apns_token, environment) DO UPDATE
    SET user_id = EXCLUDED.user_id,
        platform = EXCLUDED.platform,
        installation_id = EXCLUDED.installation_id,
        ownership_generation = EXCLUDED.ownership_generation,
        enabled = TRUE,
        updated_at = NOW(),
        last_seen_at = NOW()
  WHERE EXCLUDED.ownership_generation > device_tokens.ownership_generation
     OR (
       EXCLUDED.ownership_generation = device_tokens.ownership_generation
       AND device_tokens.user_id = EXCLUDED.user_id
     )
  RETURNING id, apns_token, environment, platform
)
SELECT * FROM upserted_destination`;

export const DISABLE_CURRENT_INSTALLATION_SQL = `WITH current_installation_rows AS MATERIALIZED (
  SELECT id, user_id, ownership_generation, enabled, updated_at
    FROM device_tokens
   WHERE installation_id = $3
   FOR UPDATE
), strongest_destination AS (
  SELECT user_id, ownership_generation, enabled, updated_at
    FROM current_installation_rows
   ORDER BY ownership_generation DESC,
            enabled DESC,
            updated_at DESC NULLS LAST,
            id DESC
   LIMIT 1
), current_fence AS MATERIALIZED (
  SELECT user_id, ownership_generation, enabled, updated_at
    FROM push_installation_fences
   WHERE installation_id = $3
   FOR UPDATE
), strongest_authority AS (
  SELECT user_id, ownership_generation, enabled
    FROM (
      SELECT user_id, ownership_generation, enabled, updated_at, 1 AS authority_priority
        FROM current_fence
      UNION ALL
      SELECT user_id, ownership_generation, enabled, updated_at, 0 AS authority_priority
        FROM strongest_destination
    ) AS candidates
   ORDER BY ownership_generation DESC,
            authority_priority DESC,
            updated_at DESC NULLS LAST
   LIMIT 1
), authorized_disable AS (
  SELECT $3::varchar AS installation_id, $1::uuid AS user_id, $4::bigint AS ownership_generation
   WHERE NOT EXISTS (SELECT 1 FROM strongest_authority)
      OR (
        (SELECT user_id FROM strongest_authority) = $1::uuid
        AND (SELECT ownership_generation FROM strongest_authority) <= $4
      )
), fenced_installation AS (
  INSERT INTO push_installation_fences
    (installation_id, user_id, ownership_generation, enabled)
  SELECT installation_id, user_id, ownership_generation, FALSE
    FROM authorized_disable
  ON CONFLICT (installation_id) DO UPDATE
    SET user_id = EXCLUDED.user_id,
        ownership_generation = EXCLUDED.ownership_generation,
        enabled = FALSE,
        updated_at = NOW()
  WHERE EXCLUDED.ownership_generation > push_installation_fences.ownership_generation
     OR (
       push_installation_fences.user_id = EXCLUDED.user_id
       AND push_installation_fences.ownership_generation <= EXCLUDED.ownership_generation
     )
  RETURNING installation_id
), disabled_destinations AS (
  DELETE FROM device_tokens
    USING fenced_installation
   WHERE device_tokens.user_id = $1::uuid
     AND device_tokens.installation_id = fenced_installation.installation_id
     AND device_tokens.ownership_generation <= $4
  RETURNING device_tokens.id
), retired_legacy_destination AS (
  DELETE FROM device_tokens
   WHERE $5::boolean
     AND device_tokens.user_id = $1::uuid
     AND device_tokens.apns_token = $2
     AND device_tokens.installation_id = 'legacy:' || $1::text
  RETURNING device_tokens.id
)
SELECT EXISTS (SELECT 1 FROM fenced_installation) AS fenced,
       EXISTS (SELECT 1 FROM disabled_destinations) AS disabled,
       EXISTS (SELECT 1 FROM retired_legacy_destination) AS legacy_retired`;

export const LIST_DELIVERABLE_DEVICE_TOKENS_SQL = `WITH ranked_destinations AS (
  SELECT device_tokens.*,
         ROW_NUMBER() OVER (
           PARTITION BY installation_id
           ORDER BY ownership_generation DESC,
                    enabled DESC,
                    updated_at DESC NULLS LAST,
                    id DESC
         ) AS installation_rank
    FROM device_tokens
)
SELECT destination.id, destination.apns_token, destination.environment, destination.platform
  FROM ranked_destinations AS destination
 LEFT JOIN push_installation_fences AS fence
    ON fence.installation_id = destination.installation_id
 WHERE destination.enabled = TRUE
   AND destination.user_id = $1::uuid
   AND (
     destination.installation_id LIKE 'legacy:%'
     OR (
       destination.installation_rank = 1
       AND fence.user_id = destination.user_id
       AND fence.ownership_generation = destination.ownership_generation
       AND fence.enabled = TRUE
     )
   )`;

const RETRYABLE_APNS_REASONS = new Set([
  'IdleTimeout',
  'ExpiredProviderToken',
  'InvalidProviderToken',
  'DeviceTokenNotForTopic',
  'BadTopic',
  'MissingTopic',
  'TopicDisallowed',
  'BadCertificate',
  'BadCertificateEnvironment',
]);

/** APNs failures that must not consume the scheduled trigger before recovery. */
export function isRetryablePushResult(result: PushSendResult): boolean {
  if (result.ok) return false;
  if (result.status === 0 || result.status === 429 || result.status >= 500) return true;

  // These responses describe provider credentials/topic configuration, not a bad destination
  // or malformed brief. Keep the scheduled trigger available so correcting APNs configuration
  // can deliver the already-authored canonical artifact on the next worker tick.
  return RETRYABLE_APNS_REASONS.has(result.reason ?? '');
}

/** A cached provider JWT may be stale even though its local 55-minute TTL has not elapsed. */
export function shouldRefreshApnsProviderToken(result: Pick<PushSendResult, 'ok' | 'reason'>): boolean {
  return !result.ok && result.reason === 'ExpiredProviderToken';
}

/** Token-specific terminal responses that should never remain in the destination registry. */
export function isPermanentlyInvalidDeviceTokenResponse(
  status: number,
  reason?: string,
): boolean {
  // DeviceTokenNotForTopic can be caused by a wrong server APNS_BUNDLE_ID. It is terminal for
  // this send, but deleting an otherwise-valid token would make a configuration mistake purge
  // the entire registry and the client's local success cache can prevent automatic re-registration.
  return status === 410 || reason === 'BadDeviceToken';
}

interface ApnsAuthConfig {
  keyId: string;
  teamId: string;
  bundleId: string;
  privateKey: string;
}

const APNS_ENVIRONMENTS: ReadonlySet<string> = new Set(['sandbox', 'production']);
const DEVICE_PLATFORMS: ReadonlySet<string> = new Set(['ios', 'macos']);

// APNs provider tokens are valid for one hour; cache slightly under that so a
// burst of pushes avoids repeated ECDSA signing (mirrors upstream's 55m cache).
const APNS_JWT_TTL_MS = 55 * 60 * 1000;
const APNS_REQUEST_TIMEOUT_MS = 10_000;

let cachedJwt: { cacheKey: string; token: string; expiresAtMs: number } | null = null;

export function normalizeApnsEnvironment(value: unknown): ApnsEnvironment {
  const s = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return APNS_ENVIRONMENTS.has(s) ? (s as ApnsEnvironment) : 'production';
}

export function normalizeDevicePlatform(value: unknown): DevicePlatform {
  const s = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return DEVICE_PLATFORMS.has(s) ? (s as DevicePlatform) : 'ios';
}

/** True only when every APNs credential is present. Drives the no-op guard. */
export function isApnsConfigured(): boolean {
  return resolveApnsAuth() !== null;
}

function resolveApnsAuth(): ApnsAuthConfig | null {
  const keyId = env.APNS_KEY_ID;
  const teamId = env.APNS_TEAM_ID;
  const bundleId = env.APNS_BUNDLE_ID;
  const rawKey = env.APNS_AUTH_KEY;
  if (!keyId || !teamId || !bundleId || !rawKey) return null;
  // Deploy envs (Railway) escape newlines as literal "\n"; restore them so the
  // PEM parses. Already-multiline values pass through unchanged.
  const privateKey = rawKey.includes('\\n') ? rawKey.replace(/\\n/g, '\n') : rawKey;
  return { keyId, teamId, bundleId, privateKey };
}

function base64Url(input: Buffer): string {
  return input.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function base64UrlJson(value: object): string {
  return base64Url(Buffer.from(JSON.stringify(value)));
}

/** Mint (or reuse) an ES256 provider bearer token. Mirrors getApnsBearerToken upstream. */
function getApnsBearerToken(auth: ApnsAuthConfig, nowMs: number = Date.now()): string {
  const cacheKey = `${auth.teamId}:${auth.keyId}`;
  if (cachedJwt && cachedJwt.cacheKey === cacheKey && nowMs < cachedJwt.expiresAtMs) {
    return cachedJwt.token;
  }
  const iat = Math.floor(nowMs / 1000);
  const header = base64UrlJson({ alg: 'ES256', kid: auth.keyId, typ: 'JWT' });
  const payload = base64UrlJson({ iss: auth.teamId, iat });
  const signingInput = `${header}.${payload}`;
  const signature = signJwt('sha256', Buffer.from(signingInput, 'utf8'), {
    key: createPrivateKey(auth.privateKey),
    dsaEncoding: 'ieee-p1363',
  });
  const token = `${signingInput}.${base64Url(signature)}`;
  cachedJwt = { cacheKey, token, expiresAtMs: nowMs + APNS_JWT_TTL_MS };
  return token;
}

/** Build the APNs JSON payload from our generic PushPayload shape. */
export function buildApnsPayload(payload: PushPayload): Record<string, unknown> {
  return {
    aps: {
      alert: { title: payload.title, body: payload.body },
      sound: 'default',
      ...(payload.threadId ? { 'thread-id': payload.threadId } : {}),
    },
    ...(payload.data ?? {}),
  };
}

// ---------------------------------------------------------------------------
// Token lifecycle (create / read / delete)
// ---------------------------------------------------------------------------

/**
 * Upsert a device's APNs token. A token/environment pair belongs to exactly one account: signing
 * into another account atomically transfers the row instead of leaving the physical device in both
 * users' push registries. A delayed unregister from the old account is user-scoped and therefore
 * cannot delete the transferred row.
 */
export async function registerDeviceToken(
  userId: string,
  token: string,
  environment: ApnsEnvironment = 'production',
  platform: DevicePlatform = 'ios',
  installationId: string = `legacy:${userId}`,
  ownershipGeneration: number = 0,
): Promise<DeviceTokenRow> {
  if (isLegacyInstallationId(installationId)) {
    const legacyResult = await pool.query(
      `INSERT INTO device_tokens
         (user_id, apns_token, environment, platform, installation_id, ownership_generation)
       VALUES ($1::uuid, $2, $3, $4, $5, $6)
       ON CONFLICT (apns_token, environment) DO UPDATE
         SET user_id = EXCLUDED.user_id,
             platform = EXCLUDED.platform,
             installation_id = EXCLUDED.installation_id,
             ownership_generation = EXCLUDED.ownership_generation,
             enabled = TRUE,
             updated_at = NOW(),
             last_seen_at = NOW()
       WHERE EXCLUDED.ownership_generation > device_tokens.ownership_generation
          OR (
            EXCLUDED.ownership_generation = device_tokens.ownership_generation
            AND device_tokens.user_id = EXCLUDED.user_id
          )
       RETURNING id, apns_token, environment, platform`,
      [userId, token, environment, platform, installationId, ownershipGeneration],
    );
    if (legacyResult.rows[0]) return legacyResult.rows[0] as DeviceTokenRow;
    const current = await pool.query<DeviceTokenRow & { user_id: string; enabled: boolean }>(
      `SELECT id, user_id::text, apns_token, environment, platform, enabled
         FROM device_tokens
        WHERE apns_token = $1 AND environment = $2`,
      [token, environment],
    );
    const currentRow = current.rows[0];
    if (currentRow?.user_id === userId && currentRow.enabled) return currentRow;
    throw new DeviceTokenOwnershipConflictError();
  }

  return withInstallationTransaction(installationId, async (client) => {
    const result = await client.query(
      REGISTER_CURRENT_DEVICE_TOKEN_SQL,
      [userId, token, environment, platform, installationId, ownershipGeneration],
    );
    if (result.rows[0]) return result.rows[0] as DeviceTokenRow;

    const current = await client.query<DeviceTokenRow & { user_id: string; enabled: boolean }>(
      `SELECT destination.id,
                destination.user_id::text,
                destination.apns_token,
                destination.environment,
                destination.platform,
                destination.enabled
           FROM device_tokens AS destination
           JOIN push_installation_fences AS fence
             ON fence.installation_id = destination.installation_id
            AND fence.user_id = destination.user_id
            AND fence.ownership_generation = destination.ownership_generation
            AND fence.enabled = TRUE
          WHERE destination.apns_token = $1
            AND destination.environment = $2
            AND destination.installation_id = $3
            AND destination.user_id = $4::uuid
            AND destination.enabled = TRUE
            AND NOT EXISTS (
              SELECT 1
                FROM device_tokens AS stronger
               WHERE stronger.installation_id = destination.installation_id
                 AND (
                   stronger.ownership_generation > destination.ownership_generation
                   OR (
                     stronger.ownership_generation = destination.ownership_generation
                     AND stronger.enabled = TRUE
                     AND destination.enabled = FALSE
                   )
                   OR (
                     stronger.ownership_generation = destination.ownership_generation
                     AND stronger.enabled = destination.enabled
                     AND (
                       stronger.updated_at > destination.updated_at
                       OR (stronger.updated_at = destination.updated_at AND stronger.id > destination.id)
                     )
                   )
                 )
            )`,
      [token, environment, installationId, userId],
    );
    const currentRow = current.rows[0];
    // A delayed lower-generation refresh is idempotent only when this exact installation remains
    // the live fenced authority. Every other rejected write must remain a retryable conflict.
    if (currentRow?.user_id === userId && currentRow.enabled) return currentRow;
    throw new DeviceTokenOwnershipConflictError();
  });
}

/**
 * Disable a destination on sign-out while retaining its generation as a tombstone. A delayed
 * registration from the signed-out account therefore cannot recreate the subscription after the
 * unregister request wins the network race.
 */
export async function disableDeviceToken(
  userId: string,
  token: string,
  installationId: string,
  ownershipGeneration: number,
  retireLegacyAuthority: boolean = false,
): Promise<boolean> {
  if (isLegacyInstallationId(installationId)) {
    return unregisterDeviceToken(userId, token);
  }
  return withInstallationTransaction(installationId, async (client) => {
    const result = await client.query(
      DISABLE_CURRENT_INSTALLATION_SQL,
      [userId, token, installationId, ownershipGeneration, retireLegacyAuthority],
    );
    return result.rows[0]?.fenced === true || result.rows[0]?.legacy_retired === true;
  });
}

/** Remove a device token (e.g. on logout or when APNs reports it unregistered). */
export async function unregisterDeviceToken(userId: string, token: string): Promise<boolean> {
  const result = await pool.query(
    `DELETE FROM device_tokens WHERE user_id = $1::uuid AND apns_token = $2 RETURNING id`,
    [userId, token],
  );
  return result.rowCount! > 0;
}

/** All of a user's registered device tokens. */
export async function listDeviceTokens(userId: string): Promise<DeviceTokenRow[]> {
  const result = await pool.query(
    LIST_DELIVERABLE_DEVICE_TOKENS_SQL,
    [userId],
  );
  return result.rows as DeviceTokenRow[];
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

/**
 * Send a remote push to every device a user has registered.
 *
 * NO-OP when APNs is unconfigured: logs and returns an empty result so callers
 * (routines, digests) can fire pushes unconditionally and this PR is safe to
 * merge without credentials. Per-device failures are isolated — one bad token
 * does not stop the rest.
 */
export async function sendPush(userId: string, payload: PushPayload): Promise<PushSendResult[]> {
  const auth = resolveApnsAuth();
  if (!auth) {
    console.log(
      `[PUSH] Skipping send for user=${userId} — APNs not configured (set APNS_KEY_ID/APNS_TEAM_ID/APNS_BUNDLE_ID/APNS_AUTH_KEY)`,
    );
    return [];
  }

  const tokens = await listDeviceTokens(userId);
  if (tokens.length === 0) {
    console.log(`[PUSH] No device tokens for user=${userId}`);
    return [];
  }

  const apnsPayload = buildApnsPayload(payload);
  const results: PushSendResult[] = [];
  for (const row of tokens) {
    try {
      const request = async () => sendApnsRequest({
        token: row.apns_token,
        environment: row.environment,
        bundleId: auth.bundleId,
        bearerToken: getApnsBearerToken(auth),
        payload: apnsPayload,
        collapseId: payload.collapseId,
      });
      let res = await request();
      if (shouldRefreshApnsProviderToken({
        ok: res.status === 200,
        reason: res.reason,
      })) {
        // APNs is authoritative about provider-token expiry. Drop the cached JWT and retry this
        // device once with a freshly minted token; a repeated failure remains retryable for the
        // scheduler rather than consuming the brief trigger.
        cachedJwt = null;
        res = await request();
      }
      const ok = res.status === 200;
      results.push({ token: row.apns_token, ok, status: res.status, reason: ok ? undefined : res.reason });
      // Token-specific terminal responses never become valid by retrying the same registry row.
      if (isPermanentlyInvalidDeviceTokenResponse(res.status, res.reason)) {
        await unregisterDeviceToken(userId, row.apns_token).catch(() => {});
      }
    } catch (err) {
      results.push({ token: row.apns_token, ok: false, status: 0, reason: (err as Error).message });
    }
  }

  const okCount = results.filter((r) => r.ok).length;
  console.log(`[PUSH] Sent to ${okCount}/${results.length} devices for user=${userId}`);
  return results;
}

interface ApnsRequestParams {
  token: string;
  environment: ApnsEnvironment;
  bundleId: string;
  bearerToken: string;
  payload: object;
  collapseId?: string;
}

interface ApnsRequestResponse {
  status: number;
  apnsId?: string;
  reason?: string;
}

/**
 * One HTTP/2 POST to APNs for a single device token. Mirrors sendApnsRequest in
 * openclaw/src/infra/push-apns.ts (direct transport, no managed proxy).
 */
async function sendApnsRequest(params: ApnsRequestParams): Promise<ApnsRequestResponse> {
  const authority =
    params.environment === 'production'
      ? 'https://api.push.apple.com'
      : 'https://api.sandbox.push.apple.com';
  const body = JSON.stringify(params.payload);
  const client = http2.connect(authority);

  return await new Promise<ApnsRequestResponse>((resolve, reject) => {
    let settled = false;
    const fail = (err: unknown) => {
      if (settled) return;
      settled = true;
      client.destroy();
      reject(err instanceof Error ? err : new Error(String(err)));
    };
    const finish = (result: ApnsRequestResponse) => {
      if (settled) return;
      settled = true;
      client.close();
      resolve(result);
    };

    client.once('error', fail);

    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${params.token}`,
      authorization: `bearer ${params.bearerToken}`,
      'apns-topic': params.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      ...(params.collapseId ? { 'apns-collapse-id': params.collapseId } : {}),
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body).toString(),
    });

    let statusCode = 0;
    let apnsId: string | undefined;
    let responseBody = '';

    req.setEncoding('utf8');
    req.setTimeout(APNS_REQUEST_TIMEOUT_MS, () => {
      req.close(http2.constants.NGHTTP2_CANCEL);
      fail(new Error(`APNs request timed out after ${APNS_REQUEST_TIMEOUT_MS}ms`));
    });
    req.on('response', (headers) => {
      const statusHeader = headers[':status'];
      statusCode = typeof statusHeader === 'number' ? statusHeader : Number(statusHeader) || 0;
      const idHeader = headers['apns-id'];
      if (typeof idHeader === 'string' && idHeader.trim().length > 0) apnsId = idHeader.trim();
    });
    req.on('data', (chunk) => {
      responseBody += chunk;
    });
    req.on('end', () => {
      let reason: string | undefined;
      if (statusCode !== 200 && responseBody) {
        try {
          reason = JSON.parse(responseBody).reason;
        } catch {
          reason = responseBody.slice(0, 200);
        }
      }
      finish({ status: statusCode, apnsId, reason });
    });
    req.on('error', fail);
    req.end(body);
  });
}
