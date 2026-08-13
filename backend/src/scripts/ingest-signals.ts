/**
 * ingest-signals — the tier-2 SIGNAL PRODUCER (`npm run signals:ingest`).
 *
 * Polls each connected source a recently-active user has authorized and writes what it finds into
 * `channel_signals`, so `deriveSuggestions` finally has tier-2 rows to reason over. Until this
 * job, that table had never held a single row: migration 039 shipped the consumer and left the
 * producer to a gateway hook that was never built.
 *
 * OFF BY DEFAULT: no-ops and exits 0 unless `SIGNAL_INGEST_ENABLED` is truthy (1/true/yes/on) —
 * same kill-switch shape as MEMORY_KEEPER_ENABLED / ORCHESTRATOR_SWEEP_ENABLED /
 * GATEWAY_KEEPWARM_ENABLED. A fleet-wide job that reads user mailboxes must be one env change to
 * stop, with no deploy.
 *
 * Schedule (Railway cron): part of `cron:all`, every 15 minutes, placed BEFORE `checkins:run` —
 * see cron-all.ts for why the order matters.
 *
 * All bounds, isolation and counting live in signal-ingest.service.ts; this file is only the
 * entrypoint: gate → select users → run → log. Mirrors run-orchestrator-sweep.ts / run-keepwarm.ts
 * (kill-switch + thin main + direct-invoke guard) and daily-checkins.ts / run-routines.ts
 * (per-user isolation, honest summary).
 */

import { fileURLToPath } from 'node:url';
import '../config/env.js';
import { pool } from '../db/pool.js';
import { listDescriptors } from '../services/connector-signals.registry.js';
import {
  composioActiveAccountSource,
  composioSignalExecutor,
  isComposioConfigured,
} from '../services/composio.service.js';
import {
  formatSignalIngestSummary,
  runSignalIngestBatch,
  selectSignalIngestUsers,
  signalIngestExitCode,
  signalIngestFailureReason,
  signalIngestGate,
  SIGNAL_INGEST_FAILURE_MESSAGES,
} from '../services/signal-ingest.service.js';

/** Human line for each structured gate reason. The REASON is the machine-readable part. */
const GATE_MESSAGES: Record<string, string> = {
  disabled: 'set SIGNAL_INGEST_ENABLED=1 to enable',
  composio_unconfigured: 'COMPOSIO_API_KEY is unset on this backend',
  no_descriptors: 'no connector signal descriptors are registered',
};

async function main() {
  // The SAME registry the Daily Brief collector and the derived-inputs API read. A descriptor
  // added there is polled here on the next tick with no second registration step — which is the
  // whole reason this job stopped being a permanent no-op.
  const descriptors = [...listDescriptors()];
  const gate = signalIngestGate({
    composioConfigured: isComposioConfigured(),
    descriptorCount: descriptors.length,
  });
  if (!gate.run) {
    // Exit 0, not 1: a deliberately-off job is not a cron failure. The reason is logged so a run
    // that read nothing can never be mistaken for a run that found nothing.
    console.log(`[signals] not running — reason=${gate.reason} (${GATE_MESSAGES[gate.reason]}); exiting 0`);
    process.exit(0);
  }

  const now = new Date();
  console.log(
    `[signals] starting at ${now.toISOString()} — descriptors=${descriptors.map((d) => d.source).join(',')}`,
  );

  const userIds = await selectSignalIngestUsers(pool);
  const summary = await runSignalIngestBatch(userIds, descriptors, now, {
    accounts: composioActiveAccountSource,
    executor: composioSignalExecutor,
  });

  console.log(`[signals] done — ${formatSignalIngestSummary(summary)}`);

  // A red run must say WHY on the line above the non-zero exit. `fetched>0, ingested+duplicates=0`
  // in particular is invisible in the counters unless it is named: every one of them looks healthy
  // on its own, and that combination is what a dead producer prints.
  const failureReason = signalIngestFailureReason(summary);
  if (failureReason) {
    console.error(
      `[signals] FAILED — reason=${failureReason} (${SIGNAL_INGEST_FAILURE_MESSAGES[failureReason]})`,
    );
  }

  process.exit(signalIngestExitCode(summary));
}

// Only run the batch when invoked directly (`tsx ingest-signals.ts`). Importing this module in
// tests must not open a database connection or read anyone's mailbox.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    // Safe to print in full ONLY because nothing above it handles message-derived text:
    // `runSignalIngestBatch` never throws, and the one other await is the users select. Anything
    // added here that touches signal content must log a reason code instead.
    console.error('[signals] fatal error:', err);
    process.exit(1);
  });
}
