/**
 * run-orchestrator-sweep — the "brief that ACTS" sweep (#922). Finds tasks that are
 * READY TO RUN and runs each one AUTONOMOUSLY through the owner's OpenClaw gateway
 * (Move-2), applying status + leaving an Undo-able Activity comment. The brief/check-in
 * that reads `task_comments` then reports what Rem did with no extra wiring.
 *
 * OFF BY DEFAULT (M5): fleet-wide autonomous, side-effecting execution only runs when the
 * `ORCHESTRATOR_SWEEP_ENABLED` env flag is truthy (1/true/yes/on). Without it, this
 * no-ops and exits 0 — the kill-switch, so the sweep is an explicit opt-in rather than
 * something a single deploy silently turns on for everyone.
 *
 * Schedule (Railway cron): part of `cron:all`, every 15 minutes. It runs BEFORE
 * `checkins:run` in the cron-all job order so a check-in fired the same tick reflects the
 * actions the sweep just took.
 *
 * Idempotent across ticks: `findReadyTasks` only picks tasks with `run_status IS NULL`
 * and each run stamps a terminal run_status (or, on gateway failure, releases the claim
 * back to NULL to retry later) — so re-running within the interval never double-acts. A
 * claim stranded 'running' by a crashed tick is reaped back to NULL at the top of the
 * next sweep, so a mid-run crash can't strand a task forever.
 *
 * Never-throw per task: sweepReadyTasks isolates each task; a flaky/sleeping gateway
 * degrades to a skip (claim released), never crashing the cron. Mirrors run-routines.ts.
 */

import { fileURLToPath } from 'node:url';
import '../config/env.js';
import { sweepReadyTasks, isSweepEnabled } from '../services/orchestrator-sweep.service.js';

async function main() {
  if (!isSweepEnabled()) {
    console.log('[sweep] disabled — set ORCHESTRATOR_SWEEP_ENABLED=1 to enable; exiting 0');
    process.exit(0);
  }

  const now = new Date();
  console.log(`[sweep] starting at ${now.toISOString()}`);

  const report = await sweepReadyTasks(now);

  console.log(
    `[sweep] done — scanned=${report.scanned} executed=${report.executed} ` +
      `denied=${report.denied} skipped=${report.skipped} ` +
      `(gateway=${report.skippedGateway} claim=${report.skippedClaim}) reaped=${report.reaped}`,
  );
  // Exit non-zero only if we scanned tasks but every one failed to RUN — matches the
  // other cron scripts' "surface a total failure, tolerate partials" convention. Pure
  // claim contention (skipped_claim) is NOT a failure — another worker got there first —
  // so it is excluded from the failure count (L8).
  const totalFailed = report.skippedGateway;
  process.exit(report.scanned > 0 && report.executed === 0 && report.denied === 0 && totalFailed > 0 ? 1 : 0);
}

// Only run when invoked directly (`tsx run-orchestrator-sweep.ts`); importing this module
// in tests must not open a DB connection or dispatch a sweep.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error('[sweep] fatal error:', err);
    process.exit(1);
  });
}
