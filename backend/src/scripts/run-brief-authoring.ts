import '../crypto-polyfill.js'; // MUST be first — installs globalThis.crypto before the Composio SDK loads
/**
 * run-brief-authoring — recover interrupted transcript delivery for already-authored
 * canonical Daily Brief artifacts. Fresh scheduled authoring is owned exclusively by
 * enabled, due `user_checkins` in daily-checkins.ts.
 *
 * OFF BY DEFAULT: only runs when `BRIEF_AI_AUTHORING_ENABLED` is truthy (1/true/yes/on).
 * Without it this no-ops and exits 0 — the kill-switch, so brief authoring is an explicit
 * opt-in rather than something a single deploy silently turns on fleet-wide.
 *
 * Schedule (Railway cron): part of `cron:all`, every 15 minutes, after check-ins. This job
 * never gathers tasks, claims an authoring slot, creates an artifact, or sends APNs. It only
 * retries the two rollout transcript deliveries for recent canonical gateway artifacts.
 */

import { fileURLToPath } from 'node:url';
import '../config/env.js';
import { pool } from '../db/pool.js';
import {
  isBriefAuthoringEnabled,
  recoverBriefArtifactDeliveriesForUser,
} from '../services/brief-authoring.service.js';

/**
 * Users with a recent canonical gateway artifact missing either rollout delivery. Tasks and
 * enabled check-ins are deliberately absent: daily-checkins.ts is the sole fresh-authoring path.
 */
export async function listBriefDeliveryRecoveryUserIds(): Promise<string[]> {
  const result = await pool.query<{ user_id: string }>(
    `SELECT DISTINCT a.user_id
       FROM daily_brief_artifacts a
       JOIN daily_briefs b
         ON b.user_id = a.user_id
        AND b.brief_date = a.brief_date
        AND b.authored_slot = a.authored_slot
        AND b.source = a.source
        AND b.markdown = a.markdown
      WHERE a.source = 'gateway'
        AND a.markdown IS NOT NULL AND BTRIM(a.markdown) <> ''
        AND a.brief_date BETWEEN CURRENT_DATE - 1 AND CURRENT_DATE + 1
        AND (
          NOT EXISTS (
            SELECT 1 FROM daily_brief_artifact_deliveries d
             WHERE d.artifact_id = a.id
               AND d.artifact_revision = a.revision
               AND d.session_key = 'rem-orchestrator' AND d.state = 'delivered'
          ) OR NOT EXISTS (
            SELECT 1 FROM daily_brief_artifact_deliveries d
             WHERE d.artifact_id = a.id
               AND d.artifact_revision = a.revision
               AND d.session_key = 'rem-today-' || TO_CHAR(a.brief_date, 'YYYYMMDD')
               AND d.state = 'delivered'
          )
        )`,
  );
  return result.rows.map((row) => row.user_id);
}

export async function recoverBriefDeliveries(
  userIds: string[],
  recover: (userId: string) => Promise<number> = recoverBriefArtifactDeliveriesForUser,
): Promise<{ recovered: number; failed: number }> {
  let recovered = 0;
  let failed = 0;
  for (const userId of userIds) {
    try {
      recovered += await recover(userId);
    } catch (error) {
      failed += 1;
      console.error(`[brief-author] user ${userId} delivery recovery failed:`, error);
    }
  }
  return { recovered, failed };
}

async function main() {
  if (!isBriefAuthoringEnabled()) {
    console.log('[brief-author] disabled — set BRIEF_AI_AUTHORING_ENABLED=1 to enable; exiting 0');
    process.exit(0);
  }

  console.log(`[brief-author] delivery recovery starting at ${new Date().toISOString()}`);

  const userIds = await listBriefDeliveryRecoveryUserIds();
  console.log(`[brief-author] ${userIds.length} user(s) with pending artifact delivery`);

  const result = await recoverBriefDeliveries(userIds);
  console.log(`[brief-author] done — recovered=${result.recovered} failed=${result.failed}`);
  process.exit(result.failed > 0 && result.recovered === 0 ? 1 : 0);
}

// Only run when invoked directly; importing this module in tests must not open a DB
// connection or dispatch the cron.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error('[brief-author] fatal error:', err);
    process.exit(1);
  });
}
