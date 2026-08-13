import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

/**
 * Wiring tests for the tier-2 signal producer.
 *
 * These read the files rather than importing them (mirrors cron-pool-cleanup.test.ts): importing
 * the script would open a database connection and pull in the Composio client. The claims below
 * are the ones that are load-bearing and invisible to the service's own unit tests — job ORDER in
 * the cron chain, the npm mapping the chain shells out to, the kill-switch, and the rule that this
 * lane never writes `channel_signals` behind the shared upsert's back.
 */

const cronAll = readFileSync(new URL('./cron-all.ts', import.meta.url), 'utf8');
const script = readFileSync(new URL('./ingest-signals.ts', import.meta.url), 'utf8');
const service = readFileSync(
  new URL('../services/signal-ingest.service.ts', import.meta.url),
  'utf8',
);
const packageJson = JSON.parse(
  readFileSync(new URL('../../package.json', import.meta.url), 'utf8'),
);

describe('signals:ingest cron wiring', () => {
  it('is in the cron:all chain and npm maps it to this script', () => {
    expect(cronAll).toContain('"signals:ingest"');
    expect(packageJson.scripts['signals:ingest']).toBe('tsx src/scripts/ingest-signals.ts');
  });

  it('runs BEFORE checkins:run, because it PRODUCES what the check-in consumes', () => {
    // deriveSuggestions (the tier-2 suggestions a brief shows) reads channel_signals. Ordering
    // this job after checkins:run would author every brief from the previous tick's inbox.
    const jobs = cronAll.slice(cronAll.indexOf('const JOBS'), cronAll.indexOf('] as const'));
    const order = [...jobs.matchAll(/"([a-z:]+)"/g)].map((match) => match[1]);
    expect(order).toContain('signals:ingest');
    expect(order.indexOf('signals:ingest')).toBeLessThan(order.indexOf('checkins:run'));
    expect(order.indexOf('signals:ingest')).toBeLessThan(order.indexOf('orchestrator:sweep'));
  });

  it('the ordering is EXPLAINED in the file, not just enacted', () => {
    expect(cronAll).toMatch(/signals:ingest runs BEFORE/);
  });
});

describe('signals:ingest safety posture', () => {
  it('is gated by a kill-switch and exits 0 when it declines to run', () => {
    expect(service).toContain('SIGNAL_INGEST_ENABLED');
    expect(script).toContain('signalIngestGate');
    // A deliberately-off job is not a red cron run.
    expect(script).toMatch(/reason=\$\{gate\.reason\}[\s\S]*?process\.exit\(0\)/);
  });

  it('writes channel_signals ONLY through the shared idempotent upsert', () => {
    // Re-implementing the INSERT here would fork the (user, source, source_ref) idempotency rule
    // that the route and this poller are both supposed to share.
    expect(service).not.toMatch(/INSERT\s+INTO\s+channel_signals/i);
    expect(script).not.toMatch(/INSERT\s+INTO\s+channel_signals/i);
    expect(service).toContain('ingestSignalDetailed');
  });

  it('never logs a provider error message, on any path', () => {
    // `error.message` from a driver or an HTTP client can quote the bound parameters, and those
    // parameters are message-derived text. Only `error.name` and reason codes are logged.
    expect(service).not.toMatch(/console\.(log|warn|error)\([^)]*\.message/);
  });
});
