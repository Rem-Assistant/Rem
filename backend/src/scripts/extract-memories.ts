/**
 * Auto-extract durable user facts — the scheduled "Dreaming" pass.
 *
 * For every user with recent activity, ask THAT USER'S OWN GATEWAY AGENT to distill 2-3
 * durable facts worth remembering (preferences, ongoing goals, recurring context) and write
 * each via the user-memory service with source='auto'. Candidates are deduped against the
 * user's existing facts so the same durable fact isn't re-added every night.
 *
 * Self-gated to a nightly cadence. The Railway `cron-all` service invokes this every 15
 * minutes (alongside check-ins + routines), but this pass is meant to run once per night —
 * so main() SELF-GATES on a nightly UTC window plus a global once-per-day last-run stamp
 * (cron_job_runs, migration 030). Outside the window, or if it already ran today, main()
 * logs a skip and exits 0 without touching any user gateway. This is what stops the
 * "memory keeper" prompt from opening a fresh `rem-memory-<date>` chat every 15 minutes.
 *
 *   npm run memories:extract   # no-ops unless inside the nightly window + not yet run today
 *
 * Cadence note: extraction is doubly idempotent — the nightly gate bounds it to one pass per
 * UTC day, and dedupe drops anything already known so even a forced re-run writes nothing new.
 * A nightly cadence keeps gateway spend bounded while staying fresh enough for the Memory
 * screen's "last updated" line.
 *
 * "Active user" = anyone whose tasks/comments changed within RECENT_ACTIVITY_DAYS, so we never
 * wake a dormant account's gateway. Never-throw per user: one user's failure is logged and the
 * batch continues. Mirrors src/scripts/run-digests.ts / run-routines.ts.
 */

import { fileURLToPath } from 'node:url';
import '../config/env.js';
import { pool } from '../db/pool.js';
import {
  addMemory,
  listMemories,
  VolatileMemoryRejectedError,
} from '../services/user-memory.service.js';
import { getCronJobLastRun, stampCronJobRun } from '../services/cron-job-runs.service.js';
import {
  activityCutoff,
  extractNovelFactsForUser,
  RECENT_ACTIVITY_DAYS,
} from '../services/memory-extraction.service.js';

/** Source tag stamped on every auto-extracted fact (vs NULL/'user' for user-typed ones). */
export const AUTO_SOURCE = 'auto';

/**
 * RETIRED (2026-07-04, docs/rebuild/31-MEMORY-LANE-D.md): this scheduled "memory keeper"
 * pass is superseded by native OpenClaw memory. The gateway now runs **dreaming**
 * (memory-core background consolidation → MEMORY.md, cron `0 3 * * *`) plus **memory-wiki
 * bridge mode** for a provenance-rich knowledge layer — both enabled in
 * backend/src/config/gateway-defaults.ts buildGatewayConfigPatch(). That is the
 * upstream-blessed mechanism (CLAUDE.md principle 1); this backend cron reinvented
 * consolidation badly by opening a `rem-memory-<date>` chat and string-parsing durable
 * facts out of a completion.
 *
 * OFF BY DEFAULT so a single deploy retires it fleet-wide without touching any data:
 *   - it does NOT delete or modify any existing `user_memories` row (source='auto' facts
 *     already written stay exactly as-is and still surface in Settings → Memory).
 *   - the user-typed memory path (user-memory.service / user-memory.routes) is untouched.
 *
 * REVERSIBLE: set `MEMORY_KEEPER_ENABLED=1` (or true/yes/on) in the backend env to
 * re-enable the old extraction pass — e.g. if dreaming turns out not to cover a case we
 * relied on. Mirrors the BRIEF_AI_AUTHORING_ENABLED kill-switch in run-brief-authoring.ts.
 */
export function isMemoryKeeperEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const v = env.MEMORY_KEEPER_ENABLED?.trim().toLowerCase();
  return v === '1' || v === 'true' || v === 'yes' || v === 'on';
}

/** Global-cron stamp key (cron_job_runs.job_name) for the nightly Dreaming pass. */
export const MEMORIES_JOB_NAME = 'memories:extract';

/**
 * Nightly window (UTC) the Dreaming pass is allowed to run in. The Railway `cron-all`
 * service ticks every 15 min, so without a gate extraction fired ~96×/day — spamming
 * each user's gateway and materializing a fresh `rem-memory-<date>` chat every tick.
 * We instead run at most once per UTC day, on the first tick that lands in this window.
 * A window (not a single hour) survives a missed tick; the last-run stamp collapses the
 * remaining ticks in the window to a no-op. Override the start hour via env for ops.
 */
export const NIGHTLY_EXTRACTION_HOUR_UTC = clampHour(
  Number(process.env.MEMORIES_EXTRACT_UTC_HOUR ?? 8),
  8,
);
export const NIGHTLY_EXTRACTION_WINDOW_HOURS = 2;

function clampHour(value: number, fallback: number): number {
  return Number.isInteger(value) && value >= 0 && value <= 23 ? value : fallback;
}

/** UTC calendar date (yyyy-mm-dd) — the once-per-day idempotency key. */
export function utcDateKey(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/**
 * Should the nightly extraction run right now? True only when the current UTC hour is
 * inside the nightly window AND it has not already run on this UTC date. Pure → pass
 * `now`/`lastRunAt` so it's deterministic in tests.
 */
export function shouldRunNightlyExtraction(
  now: Date,
  lastRunAt: Date | null,
  hourUtc: number = NIGHTLY_EXTRACTION_HOUR_UTC,
  windowHours: number = NIGHTLY_EXTRACTION_WINDOW_HOURS,
): boolean {
  const hour = now.getUTCHours();
  if (hour < hourUtc || hour >= hourUtc + windowHours) return false;
  if (!lastRunAt) return true;
  return utcDateKey(lastRunAt) !== utcDateKey(now);
}

/** A candidate user plus the last time they did anything we'd summarize. */
export interface UserActivity {
  userId: string;
  lastActivityAt: string | null;
}

/**
 * Filter candidate users down to those active within the window. Pure → unit-testable without a
 * database. Mirrors selectDueRoutines in run-routines.ts: the SQL gathers candidates, this
 * decides who is actually "due" for a pass.
 */
export function selectActiveUsers(
  users: UserActivity[],
  now: Date,
  windowDays: number = RECENT_ACTIVITY_DAYS,
): string[] {
  const cutoff = activityCutoff(now, windowDays).getTime();
  return users
    .filter((u) => {
      if (!u.lastActivityAt) return false;
      const t = new Date(u.lastActivityAt).getTime();
      return !Number.isNaN(t) && t >= cutoff;
    })
    .map((u) => u.userId);
}

/** Load every user's most-recent activity timestamp across tasks + comments. */
async function loadUserActivity(): Promise<UserActivity[]> {
  const result = await pool.query<{ user_id: string; last_activity_at: string | null }>(
    `SELECT user_id, MAX(last_activity) AS last_activity_at
       FROM (
         SELECT user_id, MAX(updated_at) AS last_activity FROM tasks GROUP BY user_id
         UNION ALL
         SELECT user_id, MAX(created_at) AS last_activity FROM task_comments GROUP BY user_id
       ) activity
      GROUP BY user_id`,
  );
  return result.rows.map((r) => ({
    userId: r.user_id,
    lastActivityAt: r.last_activity_at ? new Date(r.last_activity_at).toISOString() : null,
  }));
}

async function main() {
  const now = new Date();

  // Retirement gate (docs/rebuild/31-MEMORY-LANE-D.md): native OpenClaw dreaming + memory-wiki
  // now own memory consolidation. This backend "memory keeper" pass is OFF by default; it only
  // runs when MEMORY_KEEPER_ENABLED is explicitly truthy. No data is touched when disabled —
  // previously-written auto facts remain and still show in Settings → Memory.
  if (!isMemoryKeeperEnabled()) {
    console.log(
      '[memories] retired — native dreaming/memory-wiki own consolidation; ' +
        'set MEMORY_KEEPER_ENABLED=1 to re-enable the legacy extraction pass. Exiting 0.',
    );
    process.exit(0);
  }

  // Nightly gate: the Dreaming pass runs at most once per UTC day, inside a nightly
  // window — even though `cron-all` invokes this script every 15 minutes. Without it,
  // extraction spammed each user's gateway and created a `rem-memory-<date>` chat on
  // every tick. Stamp BEFORE doing any work so a mid-pass crash can't re-spam the day.
  const lastRun = await getCronJobLastRun(MEMORIES_JOB_NAME);
  if (!shouldRunNightlyExtraction(now, lastRun)) {
    console.log(
      `[memories] skip — outside nightly window or already ran today ` +
        `(utcHour=${now.getUTCHours()} window=${NIGHTLY_EXTRACTION_HOUR_UTC}..` +
        `${NIGHTLY_EXTRACTION_HOUR_UTC + NIGHTLY_EXTRACTION_WINDOW_HOURS} ` +
        `lastRun=${lastRun?.toISOString() ?? 'never'})`,
    );
    process.exit(0);
  }
  await stampCronJobRun(MEMORIES_JOB_NAME, now);

  console.log(`[memories] starting at ${now.toISOString()} (window=${RECENT_ACTIVITY_DAYS}d)`);

  const candidates = await loadUserActivity();
  const userIds = selectActiveUsers(candidates, now);
  console.log(`[memories] ${candidates.length} user(s), ${userIds.length} active`);

  let ok = 0;
  let failed = 0;
  let added = 0;
  let skippedDuplicates = 0;
  let volatileDropped = 0;

  for (const userId of userIds) {
    try {
      const existing = (await listMemories(userId)).map((m) => m.fact);
      const novel = await extractNovelFactsForUser(userId, now, existing);
      for (const fact of novel) {
        try {
          await addMemory(userId, fact, AUTO_SOURCE);
          added++;
        } catch (writeErr) {
          // The store rejected a VOLATILE runtime fact (#1282/#1277). parseFactsFromCompletion
          // already drops these, so reaching here means the two filters disagree — worth a log,
          // but it is a correct filter doing its job, NOT a failed pass. Counting it as `failed`
          // would exit non-zero and mark the whole cron-all run red.
          //
          // The error message names the category and rule id only, never the candidate fact —
          // cron logs must not carry user memory content.
          if (writeErr instanceof VolatileMemoryRejectedError) {
            volatileDropped++;
            console.warn(`[memories] user ${userId}: ${writeErr.message}`);
            continue;
          }
          throw writeErr;
        }
      }
      // Everything the model surfaced that we already knew counts as a skipped duplicate
      // only loosely; the exact count lives in the service. Here we just note "no new facts".
      if (novel.length === 0) skippedDuplicates++;
      ok++;
    } catch (err) {
      // #906's `GmiEmptyCompletionError` branch used to live here, classifying a transient
      // empty completion as a SKIP so one model no-op could not fail the whole cron run. It is
      // gone because the condition it classified can no longer occur: extraction runs only on
      // the user's own gateway now (the org-key GMI fallback was removed — see
      // memory-extraction.service.ts), and a gateway turn that comes back empty or fails is
      // already `[]` inside the service rather than a thrown error. The protection #906 bought
      // is therefore structural instead of a catch clause.
      //
      // What reaches here is what always should have: genuine failures (network, auth,
      // malformed data, DB). They still count as `failed` and still surface via a non-zero exit.
      failed++;
      console.error(`[memories] user ${userId} failed:`, (err as Error).message);
    }
  }

  // `skipped=` is gone from this line rather than printed as a constant 0: its only source was
  // the GMI empty-completion branch, and a counter that can never increment is a worse signal
  // than no counter (it reads as "nothing was skipped tonight", which nobody measured).
  console.log(
    `[memories] done — users=${userIds.length} ok=${ok} failed=${failed} ` +
      `factsAdded=${added} noNewFacts=${skippedDuplicates} volatileDropped=${volatileDropped}`,
  );
  // Only real failures should fail the process (and thus the cron run).
  process.exit(failed > 0 ? 1 : 0);
}

// Only run the batch when invoked directly (`tsx extract-memories.ts`). Importing this module in
// tests pulls in selectActiveUsers without opening a DB connection.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error('[memories] fatal error:', err);
    process.exit(1);
  });
}
