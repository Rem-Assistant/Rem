/**
 * Generate proactive digests for every active user. Designed to be run by an
 * external scheduler (Railway cron, GitHub Actions, etc.) twice a day:
 *
 *   # morning brief (run in the user's morning, e.g. 13:00 UTC)
 *   DIGEST_KIND=morning_brief npm run digests:run
 *   # end-of-day recap (run in the user's evening, e.g. 01:00 UTC)
 *   DIGEST_KIND=evening_recap npm run digests:run
 *
 * With no DIGEST_KIND set, the kind defaults from the current UTC hour
 * (before noon → morning_brief, otherwise evening_recap).
 *
 * "Active user" = anyone with at least one task/event, so we never spend GMI
 * credits generating empty digests for dormant accounts. createDigestForUser is
 * never-throw per user: a single user's GMI failure falls back to a local summary
 * and does not abort the batch.
 *
 * See docs/agentbox/DIGESTS.md.
 */

import '../config/env.js';
import { pool } from '../db/pool.js';
import {
  createDigestForUser,
  defaultKindForDate,
  DIGEST_KINDS,
  type DigestKind,
} from '../services/digest.service.js';

function resolveKind(now: Date): DigestKind {
  const raw = process.env.DIGEST_KIND?.trim();
  if (raw) {
    if (!DIGEST_KINDS.has(raw)) {
      throw new Error(`Invalid DIGEST_KIND="${raw}". Use morning_brief or evening_recap.`);
    }
    return raw as DigestKind;
  }
  return defaultKindForDate(now);
}

async function main() {
  const now = new Date();
  const kind = resolveKind(now);
  console.log(`[digests] starting — kind=${kind} at ${now.toISOString()}`);

  // Only users with at least one task/event get a digest (skip dormant accounts).
  const usersResult = await pool.query<{ user_id: string }>(
    `SELECT DISTINCT user_id FROM tasks`,
  );
  const userIds = usersResult.rows.map((r) => r.user_id);
  console.log(`[digests] ${userIds.length} active user(s)`);

  let ok = 0;
  let failed = 0;
  const sources: Record<string, number> = { gmi: 0, fallback: 0, empty: 0 };

  for (const userId of userIds) {
    try {
      const digest = await createDigestForUser(userId, kind, now);
      sources[digest.source] = (sources[digest.source] ?? 0) + 1;
      ok++;
    } catch (err) {
      failed++;
      console.error(`[digests] user ${userId} failed:`, (err as Error).message);
    }
  }

  console.log(
    `[digests] done — generated=${ok} failed=${failed} ` +
      `(gmi=${sources.gmi} fallback=${sources.fallback} empty=${sources.empty})`,
  );
  process.exit(failed > 0 && ok === 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('[digests] fatal error:', err);
  process.exit(1);
});
