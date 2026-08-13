import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import { gatherBrief } from '../services/brief.service.js';
import { createHash } from 'node:crypto';
import { deriveSuggestions, suggestionSnapshotId } from '../services/suggestions.service.js';
import { pool, type DatabaseQueryable } from '../db/pool.js';
import {
  conversationSessionKey,
  legacyConversationSessionKey,
  localBriefDate,
  readAuthoredBriefDelivery,
  resolveUserTimezone,
} from '../services/brief-authoring.service.js';

const router = Router();

export const DURABLE_CONVERSATION_CAPABILITY = 'durable-orchestrator-v1';

export function supportsDurableBriefConversation(req: Request): boolean {
  return req.header('X-Rem-Conversation-Continuity') === DURABLE_CONVERSATION_CAPABILITY;
}

async function buildBriefResponse(
  req: Request,
  userId: string,
  now: Date,
  timezone: string,
  db: DatabaseQueryable,
  atomicSuggestions: boolean,
) {
  const brief = await gatherBrief(userId, now, timezone, db);
  const conversationKey = supportsDurableBriefConversation(req)
    ? conversationSessionKey(now, timezone)
    : legacyConversationSessionKey(now, timezone);
  const briefDate = localBriefDate(now, timezone);
  let authoredRevision: string | null = null;
  let authored = null;
  if (atomicSuggestions) {
    // PostgreSQL marks a transaction failed after any statement error. A savepoint preserves the
    // established best-effort authored-prose fallback without abandoning the captured snapshot.
    await db.query('SAVEPOINT brief_authored_read');
    try {
      authored = await readAuthoredBriefDelivery(userId, briefDate, conversationKey, db);
      await db.query('RELEASE SAVEPOINT brief_authored_read');
    } catch {
      await db.query('ROLLBACK TO SAVEPOINT brief_authored_read');
      await db.query('RELEASE SAVEPOINT brief_authored_read');
    }
  } else {
    authored = await readAuthoredBriefDelivery(userId, briefDate, conversationKey, db)
      .catch(() => null);
  }
  if (authored?.delivered) {
    brief.markdown = authored.markdown;
    // Never pair canonical markdown/session authority with gatherBrief's deterministic summary.
    // The authored reader derives a lead when possible; an empty value is safer than presenting
    // unrelated fallback prose as the delivered artifact's summary.
    brief.summary = authored.summary ?? '';
    // The ONE title. Both the Agenda summary card and the orchestrator chat render this exact
    // string; neither synthesizes its own from prose or the clock. Null when the artifact has no
    // authored headline — clients then fall back to their prior titles.
    brief.headline = authored.headline;
    brief.brief_session_key = conversationKey;
    authoredRevision = authored.revision;
  }

  if (atomicSuggestions) {
    const suggestions = await deriveSuggestions(userId, now, timezone, db);
    const hasStructuredBriefItems = brief.counts.blocked > 0
      || brief.counts.overdue > 0
      || brief.counts.scheduled_today > 0
      || brief.counts.completed_today > 0;
    if (!authoredRevision && !hasStructuredBriefItems && suggestions.length > 0) {
      // Connected-source signals can be the only actionable state today. The deterministic
      // task-only composer would otherwise claim the user is "all clear" directly above real
      // Gmail/WhatsApp/etc proposals. Carry no synthetic artifact prose; clients render the exact
      // revision-bound proposals as a standalone block instead.
      brief.markdown = '';
      brief.summary = 'Rem noticed a few suggested next steps.';
    }
    const briefRevision = authoredRevision ?? `deterministic:${createHash('sha256')
      .update(JSON.stringify({
        briefDate,
        windowStart: brief.window_start,
        markdown: brief.markdown,
        counts: brief.counts,
        blocked: brief.blocked,
        overdue: brief.overdue,
        scheduledToday: brief.scheduled_today,
        completedToday: brief.completed_today,
      }))
      .digest('hex')}`;
    Object.assign(brief, {
      brief_revision: briefRevision,
      suggestion_snapshot_id: suggestionSnapshotId(briefRevision, suggestions),
      suggestions,
    });
  }
  return brief;
}

/**
 * GET /api/v1/brief — today's Daily Brief for the authed user.
 *
 * Returns the four orchestrator buckets (blocked / overdue / scheduled_today /
 * completed_today) plus a `counts` summary for the agenda card's progress ring.
 * Idempotent read — the counts/buckets are derived live from the tasks table.
 *
 * When an authored Daily Brief has already been delivered, the brief is a regenerating ARTIFACT
 * the user can DISCUSS: the full-brief `markdown` (the card) and one-line `summary` are overridden
 * with what the user's gateway agent AUTHORED for today (cached in `daily_briefs`, migration 033).
 * `BRIEF_AI_AUTHORING_ENABLED` gates creation of future artifacts, never reads of an existing
 * delivery. Clients receive a transcript key only after that exact artifact is visibly delivered.
 * Continuity-capable clients independently know that Summary opens the durable `rem-orchestrator`
 * doorway, so withholding the key prevents premature reconciliation without reviving a second
 * detail surface. The cache row remains
 * scoped to the user's LOCAL day (via their check-in timezone) so an evening brief isn't stamped
 * with tomorrow's UTC date. The authored read is best-effort: any failure
 * (or no cached row yet) leaves the deterministic prose in place, so the endpoint never gets
 * slower or less reliable. The capsule counts always stay live.
 */
router.get('/brief', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const now = new Date();
    const atomicSuggestions = req.header('X-Rem-Suggestion-Contract') === 'atomic-v1';
    if (!atomicSuggestions) {
      const timezone = (await resolveUserTimezone(userId).catch(() => undefined)) ?? 'UTC';
      return res.json(await buildBriefResponse(req, userId, now, timezone, pool, false));
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      // Local-day authority is database state too. Resolve it only after BEGIN and through the
      // checked-out client so timezone, buckets, authored revision, dismissals, signals, and action
      // proposals all belong to one PostgreSQL snapshot.
      const timezone = (await resolveUserTimezone(userId, 'UTC', client).catch(() => undefined)) ?? 'UTC';
      const brief = await buildBriefResponse(req, userId, now, timezone, client, true);
      await client.query('COMMIT');
      return res.json(brief);
    } catch (error) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  } catch (error: any) {
    console.error('[BRIEF] Error building brief:', error.message);
    res.status(500).json({ error: error.message || 'Failed to build brief' });
  }
});

export default router;
