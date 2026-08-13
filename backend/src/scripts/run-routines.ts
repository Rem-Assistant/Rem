import '../crypto-polyfill.js'; // MUST be first — installs globalThis.crypto before the Composio SDK loads
/**
 * Run every enabled routine that is DUE now. This is the backend-scheduled path that
 * REPLACES the gateway-cron trigger (the deleted routine-cron.service.ts): instead of
 * registering a per-routine job on the user's OpenClaw gateway, an external scheduler
 * (Railway cron) runs this script on a fixed interval and the backend itself decides
 * which routines are due — keeping the single execution + governance gate in
 * routine-runner.service.runRoutine (model-gate + deny-list + attributed comment +
 * RunReport + stampLastRun), with no gateway round-trip in the scheduled loop.
 *
 * Schedule (Railway cron): run every 15 minutes — cron expression
 * "(slash)15 * * * *" (slash = the literal "/"), i.e. at :00/:15/:30/:45 — running
 * `npm run routines:run` each tick.
 *
 * A 15-minute cadence is safe because due-ness is idempotent per local day:
 * isDailyRoutineDue only fires once per local date (it checks last_run_at's local
 * Y-M-D), so re-running the script within the same hour never double-runs a routine.
 * The interval just bounds how soon after `deliveryHour` a routine first fires.
 *
 * Wake-on-demand (no explicit gateway wake step): runRoutine executes the cloud agent
 * (AgentBox/GMI) and leaves a task_comment. If the agent issues a device command, the
 * user's Fly gateway auto-wakes on the inbound request via `auto_start_machines` — so
 * the common case needs no separate wake call from this scheduler. Commands that need a
 * live, already-awake foreground device remain a known gap (same as every backend→
 * gateway path), not something a wake step in the scheduler would fix.
 *
 * Never-throw per routine: a single routine's failure is logged and the batch
 * continues (runRoutine itself is never-throw — every governance path lands a comment).
 *
 * Mirrors src/scripts/run-digests.ts. See docs/rebuild/10-ROUTINES-DESIGN.md and
 * docs/rebuild/21-OPEN-THREADS.md (Decisions log: routines backend-scheduled).
 */

import { fileURLToPath } from 'node:url';
import '../config/env.js';
import { pool } from '../db/pool.js';
import { formatRoutine, ROUTINE_RETURNING } from '../services/routine-schedule.service.js';
import { runRoutine } from '../services/routine-runner.service.js';
import { isDailyRoutineDue } from '../services/routine-schedule.js';
import type { RoutineSchedule } from '../services/routine.types.js';

/** Local weekday (0=Sun … 6=Sat) for an instant in a given IANA timezone. */
function localWeekday(at: Date, timezone: string): number {
  const weekday = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    weekday: 'short',
  }).format(at);
  const map: Record<string, number> = {
    Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6,
  };
  return map[weekday] ?? 0;
}

/**
 * Is a routine due now, accounting for its cadence (tz-correct via routine-schedule.ts)?
 *
 *   daily  → isDailyRoutineDue (deliveryHour reached + not already run this local day)
 *   weekly → isDailyRoutineDue AND today is Monday local (routines carry no weekday field;
 *            Monday is the canonical weekly day — same convention the old gateway-cron used)
 *   once   → isDailyRoutineDue AND it has never run (lastRunAt null) — fires a single time
 *
 * Pure: pass `now`/`lastRunAt` so it's deterministic in tests.
 */
export function isRoutineDue(
  routine: RoutineSchedule,
  now: Date,
  lastRunAt: Date | null,
): boolean {
  if (!routine.enabled) return false;
  if (!isDailyRoutineDue(routine, now, lastRunAt)) return false;

  switch (routine.cadence) {
    case 'weekly':
      return localWeekday(now, routine.timezone) === 1; // Monday
    case 'once':
      return lastRunAt === null;
    case 'daily':
    default:
      return true;
  }
}

/**
 * Filter a batch of routines down to the ones due now. Exported so the due-filter loop
 * is unit-testable without a database.
 */
export function selectDueRoutines(
  routines: RoutineSchedule[],
  now: Date,
): RoutineSchedule[] {
  return routines.filter((routine) => {
    const lastRunAt = routine.lastRunAt ? new Date(routine.lastRunAt) : null;
    return isRoutineDue(routine, now, lastRunAt);
  });
}

async function main() {
  const now = new Date();
  console.log(`[routines] starting at ${now.toISOString()}`);

  // Only enabled routines are candidates; disabled rows never run (DB-level skip).
  const result = await pool.query(
    `SELECT ${ROUTINE_RETURNING} FROM routine_schedules WHERE enabled = TRUE`,
  );
  const routines = result.rows.map(formatRoutine);
  const due = selectDueRoutines(routines, now);
  console.log(`[routines] ${routines.length} enabled, ${due.length} due now`);

  let ok = 0;
  let failed = 0;
  const statuses: Record<string, number> = {};

  for (const routine of due) {
    try {
      const run = await runRoutine(routine, now);
      statuses[run.status] = (statuses[run.status] ?? 0) + 1;
      ok++;
    } catch (err) {
      // runRoutine is never-throw by design; guard anyway so one bad routine can't
      // abort the batch (mirrors run-digests.ts per-user isolation).
      failed++;
      console.error(`[routines] routine ${routine.id} failed:`, (err as Error).message);
    }
  }

  const breakdown = Object.entries(statuses)
    .map(([status, count]) => `${status}=${count}`)
    .join(' ');
  console.log(`[routines] done — ran=${ok} failed=${failed}${breakdown ? ` (${breakdown})` : ''}`);
  process.exit(failed > 0 && ok === 0 ? 1 : 0);
}

// Only run the batch when invoked directly (`tsx run-routines.ts`). Importing this module
// in tests pulls in selectDueRoutines/isRoutineDue without opening a DB connection.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error('[routines] fatal error:', err);
    process.exit(1);
  });
}
