import '../crypto-polyfill.js'; // MUST be first — installs globalThis.crypto before the Composio SDK loads
/**
 * cron-all — the Railway `rem-cron` service entrypoint (every 15 minutes).
 *
 * Runs each scheduled loop job independently so one flaky job can't block the
 * others (the old `a && b && c` chain stopped at the first non-zero exit — e.g.
 * a memory-extraction provider hiccup was starving check-ins + routines).
 *
 * Each job still runs to completion; we collect failures, log a summary, and
 * exit non-zero only if at least one failed — so Railway surfaces the failure
 * while every job still got its turn.
 */
import { execSync } from "node:child_process";

// orchestrator:sweep runs BEFORE checkins:run so a check-in fired the same tick reflects
// the autonomous actions the sweep just took (#922 — a brief that ACTS).
// brief:author runs LAST as delivery-only recovery for artifacts authored by due check-ins
// earlier in this or a prior tick. It never creates a fresh artifact or sends APNs. It's
// flag-gated (BRIEF_AI_AUTHORING_ENABLED) and no-ops when off.
//
// memories:extract is RETIRED (docs/rebuild/31-MEMORY-LANE-D.md): native OpenClaw dreaming
// (memory-core) + memory-wiki bridge mode now own memory consolidation on the gateway. The
// job stays wired here but is OFF by default and self-no-ops unless MEMORY_KEEPER_ENABLED is
// set (same kill-switch shape as brief:author). Kept in the list rather than deleted so the
// retirement is a one-line, reversible env change — no cron topology change needed to restore.
//
// signals:ingest runs BEFORE orchestrator:sweep and checkins:run because it is the PRODUCER for
// data both of them consume: it writes `channel_signals`, and `deriveSuggestions` (the tier-2
// suggestions the Agenda and the brief show) reads that table. Placed after it, a check-in fired
// the same tick would reason over the previous tick's inbox — a 15-minute-stale brief that claims
// to be current. Placed here, the messages a user received since the last tick are already rows by
// the time the brief is authored. Like memories:extract it is OFF by default and self-no-ops
// unless SIGNAL_INGEST_ENABLED is set, so wiring it here is not the same as turning it on.
const JOBS = [
  "memories:extract",
  "signals:ingest",
  "orchestrator:sweep",
  "checkins:run",
  "routines:run",
  "brief:author",
] as const;

const failures: string[] = [];

for (const job of JOBS) {
  console.log(`[cron-all] → ${job}`);
  try {
    execSync(`npm run ${job}`, { stdio: "inherit" });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    failures.push(job);
    console.error(`[cron-all] ${job} FAILED (continuing): ${msg}`);
  }
}

console.log(
  `[cron-all] done — ${JOBS.length - failures.length}/${JOBS.length} ok` +
    (failures.length ? `, failed: ${failures.join(", ")}` : ""),
);

process.exit(failures.length ? 1 : 0);
