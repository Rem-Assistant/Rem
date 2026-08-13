import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Unit tests for the tier-2 signal producer. Every dependency (accounts, executor, writer, clock)
 * is injected, so these run with no database, no Composio key and no network — and they exercise
 * the runner in full even though the descriptor registry is still an empty stub.
 *
 * signal-ingest.service imports suggestions.service → db/pool.js, which reads DATABASE_URL at
 * module load. Mock the pool so the pure helpers import without a database (mirrors
 * run-keepwarm.test.ts). The default writer is never reached: every test injects `write`.
 */
const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

import {
  clampSignalText,
  collectSignalsForDescriptor,
  formatSignalIngestSummary,
  ingestSignalsForUser,
  isSignalIngestEnabled,
  normalizeSignalForIngest,
  parseSignalInstant,
  runSignalIngestBatch,
  selectSignalIngestUsers,
  signalIngestExitCode,
  signalIngestFailureReason,
  signalIngestGate,
  SIGNAL_INGEST_ACTIVE_WINDOW_MINUTES,
  SIGNAL_INGEST_FAILURE_MESSAGES,
  SIGNAL_INGEST_BOUNDS,
  SIGNAL_INGEST_MAX_WINDOW_MINUTES,
  SIGNAL_TEXT_LIMITS,
  type ActiveConnectorAccountsByToolkitSource,
  type ConnectorSignalExecutor,
  type ConnectorSignalPage,
  type QueryableDb,
  type SignalIngestDependencies,
  type SignalWriter,
} from './signal-ingest.service.js';
import type { ConnectorSignalDescriptor } from './connector-signals.registry.js';

const NOW = new Date('2026-08-10T12:00:00.000Z');
const USER = 'user-1';

interface RawItem {
  id: string;
  sender?: string;
  summary?: string;
  timestamp?: string;
}

function raw(id: string, overrides: Partial<RawItem> = {}): RawItem {
  return { id, sender: 'Ada', summary: `message ${id}`, timestamp: NOW.toISOString(), ...overrides };
}

function descriptor(overrides: Partial<ConnectorSignalDescriptor> = {}): ConnectorSignalDescriptor {
  return {
    source: 'gmail',
    toolkitSlug: 'gmail',
    action: 'GMAIL_FETCH_EMAILS',
    actionVersion: '20260721_00',
    displayName: 'Gmail',
    buildQuery: () => ({ query: 'after:2026/08/09' }),
    mapItem: (item, connectedAccountId) => {
      const value = item as RawItem;
      return {
        source: 'gmail',
        sourceRef: `${connectedAccountId}:${value.id}`,
        sender: value.sender ?? null,
        summary: value.summary ?? '',
        suggestedTitle: null,
        receivedAt: value.timestamp ?? NOW.toISOString(),
      };
    },
    ...overrides,
  };
}

/** Every requested toolkit resolves to the same account ids. Honours the map contract: an entry per slug. */
function accountsWith(ids: string[]): ActiveConnectorAccountsByToolkitSource {
  return {
    listActiveAccountIdsByToolkit: async (_userId, toolkitSlugs) =>
      new Map(toolkitSlugs.map((slug) => [slug, ids])),
  };
}

/** Executor that replays a fixed page script per account and records every call. */
function executorWith(pages: ConnectorSignalPage[]) {
  const calls: Array<{ connectedAccountId: string; pageToken?: string; arguments: Record<string, unknown> }> = [];
  const executor: ConnectorSignalExecutor = {
    async fetchPage(input) {
      calls.push({
        connectedAccountId: input.connectedAccountId,
        ...(input.pageToken ? { pageToken: input.pageToken } : {}),
        arguments: input.arguments,
      });
      const index = calls.filter((c) => c.connectedAccountId === input.connectedAccountId).length - 1;
      return pages[Math.min(index, pages.length - 1)];
    },
  };
  return { executor, calls };
}

/**
 * A fake clock that spends HALF the collection budget on every reading, so the first page fits the
 * deadline and the second cannot.
 *
 * DERIVED from `SIGNAL_INGEST_BOUNDS.timeoutMs`, not hardcoded. Three tests used a literal
 * `time += 1_500` under a comment reading "deadline is 2_500ms"; the bound was later raised to
 * 15_000 and the step was not, so the deadline stopped being reachable — two of those tests had
 * been failing and the third had quietly stopped exercising the incomplete-read path it names.
 * A budget-relative step cannot rot the same way.
 */
function halfBudgetClock(): () => number {
  const step = Math.ceil(SIGNAL_INGEST_BOUNDS.timeoutMs / 2);
  let time = 0;
  return () => { const value = time; time += step; return value; };
}

/** In-memory stand-in for the `channel_signals` unique key, so `inserted` is real, not asserted. */
function memoryWriter() {
  const rows = new Map<string, { summary: string }>();
  const writer: SignalWriter = async (userId, signal) => {
    const key = `${userId}|${signal.source}|${signal.sourceRef}`;
    const existed = rows.has(key);
    rows.set(key, { summary: signal.summary });
    return { id: key, inserted: !existed };
  };
  return { writer, rows };
}

function deps(overrides: Partial<SignalIngestDependencies> = {}): SignalIngestDependencies {
  return {
    accounts: accountsWith(['acct-1']),
    executor: executorWith([{ items: [raw('m1')], nextPageToken: null }]).executor,
    write: memoryWriter().writer,
    // Default the relevance pass to a no-op. Without this, every ingest unit test would fall
    // through to the REAL `runRelevancePassForUser`, which opens the pg pool and calls a model —
    // turning pure unit tests into ones that need a database and a GMI key.
    judgeRelevance: async () => ({
      considered: 0, act: 0, drop: 0, unjudged: 0, unavailableReason: null,
    }),
    ...overrides,
  };
}

beforeEach(() => {
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('isSignalIngestEnabled', () => {
  it('is OFF by default and for empty/unknown values — a mailbox reader must opt in', () => {
    expect(isSignalIngestEnabled({})).toBe(false);
    expect(isSignalIngestEnabled({ SIGNAL_INGEST_ENABLED: '' })).toBe(false);
    expect(isSignalIngestEnabled({ SIGNAL_INGEST_ENABLED: '0' })).toBe(false);
    expect(isSignalIngestEnabled({ SIGNAL_INGEST_ENABLED: 'false' })).toBe(false);
    expect(isSignalIngestEnabled({ SIGNAL_INGEST_ENABLED: 'maybe' })).toBe(false);
  });

  it('accepts the same truthy vocabulary as the other kill-switches', () => {
    for (const value of ['1', 'true', 'TRUE', 'yes', 'on', ' On ']) {
      expect(isSignalIngestEnabled({ SIGNAL_INGEST_ENABLED: value })).toBe(true);
    }
  });
});

describe('signalIngestGate', () => {
  const on = { SIGNAL_INGEST_ENABLED: '1' } as NodeJS.ProcessEnv;

  it('reports a STRUCTURED reason for each way a tick declines to run', () => {
    expect(signalIngestGate({ env: {}, composioConfigured: true, descriptorCount: 1 }))
      .toEqual({ run: false, reason: 'disabled' });
    expect(signalIngestGate({ env: on, composioConfigured: false, descriptorCount: 1 }))
      .toEqual({ run: false, reason: 'composio_unconfigured' });
    expect(signalIngestGate({ env: on, composioConfigured: true, descriptorCount: 0 }))
      .toEqual({ run: false, reason: 'no_descriptors' });
  });

  it('runs only when enabled, configured and something is registered', () => {
    expect(signalIngestGate({ env: on, composioConfigured: true, descriptorCount: 1 }))
      .toEqual({ run: true });
  });

  it('the disabled flag wins even when everything else is ready', () => {
    expect(signalIngestGate({
      env: { SIGNAL_INGEST_ENABLED: 'off' },
      composioConfigured: true,
      descriptorCount: 3,
    })).toEqual({ run: false, reason: 'disabled' });
  });
});

describe('parseSignalInstant', () => {
  it('accepts BOTH fractional and non-fractional seconds', () => {
    expect(parseSignalInstant('2026-02-15T01:00:00Z')?.toISOString()).toBe('2026-02-15T01:00:00.000Z');
    expect(parseSignalInstant('2026-02-15T01:00:00.123Z')?.toISOString()).toBe('2026-02-15T01:00:00.123Z');
    expect(parseSignalInstant('2026-02-15T01:00:00.123456Z')?.getTime())
      .toBe(Date.parse('2026-02-15T01:00:00.123Z'));
  });

  it('accepts explicit offsets', () => {
    expect(parseSignalInstant('2026-02-15T02:00:00+01:00')?.toISOString()).toBe('2026-02-15T01:00:00.000Z');
    expect(parseSignalInstant('2026-02-15T00:00:00-01:00')?.toISOString()).toBe('2026-02-15T01:00:00.000Z');
  });

  /**
   * REGRESSION. The previous implementation validated the written calendar date with
   *   `new Date(parsed.getTime() - offsetMinutes(...) * 60_000)`
   * but `parsed.getTime()` is ALREADY the UTC instant, so subtracting the offset a second time
   * landed 2× the offset away from the value that was written. Whenever that error crossed
   * midnight the round-trip check failed and a perfectly valid provider timestamp was DROPPED.
   *
   * The two offset cases above did not catch it: ±1h never crosses a date boundary from 02:00 or
   * 00:00, so the arithmetic was wrong and the assertion still passed. Every other fixture in the
   * suite used `Z`, where the offset is 0 and the bug cancels exactly.
   *
   * Verified against the old body: `+05:00`, `-05:00` and `+05:30` all returned null.
   */
  it('keeps a valid instant whose offset crosses the written calendar date', () => {
    // 01:00 at +05:00 is 20:00 the PREVIOUS day in UTC — the case the old arithmetic dropped.
    expect(parseSignalInstant('2026-02-15T01:00:00+05:00')?.toISOString())
      .toBe('2026-02-14T20:00:00.000Z');
    // 22:00 at -05:00 is 03:00 the NEXT day in UTC — the same failure in the other direction.
    expect(parseSignalInstant('2026-02-15T22:00:00-05:00')?.toISOString())
      .toBe('2026-02-16T03:00:00.000Z');
    // A half-hour offset (India) — the sub-hour arm of the same arithmetic.
    expect(parseSignalInstant('2026-02-15T01:00:00+05:30')?.toISOString())
      .toBe('2026-02-14T19:30:00.000Z');
  });

  it('still rejects an impossible calendar date, offset or not', () => {
    // The round-trip check is what this arithmetic was FOR; fixing the sign must not lose it.
    expect(parseSignalInstant('2026-02-30T01:00:00Z')).toBeNull();
    expect(parseSignalInstant('2026-02-30T01:00:00+05:00')).toBeNull();
    expect(parseSignalInstant('2026-13-01T01:00:00Z')).toBeNull();
    expect(parseSignalInstant('2026-02-15T25:00:00Z')).toBeNull();
  });

  it('rejects anything without a single unambiguous instant', () => {
    expect(parseSignalInstant('2026-02-15T01:00:00')).toBeNull(); // no offset → no instant
    expect(parseSignalInstant('2026-02-15')).toBeNull();
    expect(parseSignalInstant('yesterday')).toBeNull();
    expect(parseSignalInstant(1_760_000_000_000)).toBeNull();
    expect(parseSignalInstant(null)).toBeNull();
    expect(parseSignalInstant('2026-02-30T01:00:00Z')).toBeNull(); // shape-valid, not a real date
  });

  /**
   * The INGEST re-check must accept everything a descriptor's `mapItem` is allowed to emit.
   * Bound to the ISO-only parser it would drop a Slack signal AFTER mapping it — the item counted
   * as fetched, refused here, and reported as a drop with no reason anyone could read.
   * The unit rule itself is specified and boundary-tested in connector-signals.registry.test.ts.
   */
  it('accepts the epoch shapes connectors send, at the exact instant, not merely non-null', () => {
    expect(parseSignalInstant('1786359600.123456')?.toISOString(), 'Slack ts — epoch seconds')
      .toBe('2026-08-10T11:00:00.123Z');
    expect(parseSignalInstant('1786359600000')?.toISOString(), 'Gmail internalDate — epoch millis')
      .toBe('2026-08-10T11:00:00.000Z');
  });
});

describe('clampSignalText', () => {
  it('hard-clamps and collapses control characters and newlines', () => {
    expect(clampSignalText('a'.repeat(900), 500)).toHaveLength(500);
    expect(clampSignalText('line one\nline\ttwo\u0000', 100)).toBe('line one line two');
    expect(clampSignalText(undefined, 100)).toBe('');
  });
});

describe('normalizeSignalForIngest', () => {
  const windowStart = new Date(NOW.getTime() - 24 * 3_600_000);

  it('refuses a signal whose source is not the descriptor that emitted it', () => {
    const mapped = {
      source: 'slack', sourceRef: 'x', sender: null, summary: 'hi',
      suggestedTitle: null, receivedAt: NOW.toISOString(),
    };
    expect(normalizeSignalForIngest(descriptor(), mapped, windowStart, NOW)).toBeNull();
  });

  it('clamps every message-derived field so a summary can never become a body', () => {
    const out = normalizeSignalForIngest(descriptor(), {
      source: 'gmail',
      sourceRef: 'r'.repeat(400),
      sender: 's'.repeat(400),
      summary: 'b'.repeat(5_000),
      suggestedTitle: 't'.repeat(400),
      receivedAt: NOW.toISOString(),
    }, windowStart, NOW);
    expect(out!.summary).toHaveLength(SIGNAL_TEXT_LIMITS.summary);
    expect(out!.sender).toHaveLength(SIGNAL_TEXT_LIMITS.sender);
    expect(out!.suggestedTitle).toHaveLength(SIGNAL_TEXT_LIMITS.suggestedTitle);
    expect(out!.sourceRef).toHaveLength(SIGNAL_TEXT_LIMITS.sourceRef);
  });

  it('drops blank summaries (NOT NULL column, and the deriver skips them anyway)', () => {
    expect(normalizeSignalForIngest(descriptor(), {
      source: 'gmail', sourceRef: 'a', sender: null, summary: '   ',
      suggestedTitle: null, receivedAt: NOW.toISOString(),
    }, windowStart, NOW)).toBeNull();
  });

  /**
   * End of the parse chain: an epoch timestamp survives validation AND is written as ISO.
   * `channel_signals.received_at` is what the deriver and the 24h window compare against, so the
   * stored value — not just "it wasn't dropped" — is the thing worth asserting.
   */
  it('keeps an epoch-number receivedAt and stores it as the ISO instant it names', () => {
    const out = normalizeSignalForIngest(descriptor(), {
      source: 'gmail',
      sourceRef: 'acct-1:m1',
      sender: null,
      // Slack's documented `ts` shape, one hour inside the window.
      summary: 'a message arrived',
      suggestedTitle: null,
      receivedAt: '1786359600.123456',
    }, windowStart, NOW);
    expect(out, 'an epoch receivedAt must not be dropped at the ingest boundary').not.toBeNull();
    expect(out!.receivedAt).toBe('2026-08-10T11:00:00.123Z');
  });

  it('still applies the window to an epoch receivedAt — the unit is read, not ignored', () => {
    // 1786276800 = 2026-08-09T12:00:00Z, exactly 24h+ before NOW → outside the window.
    expect(normalizeSignalForIngest(descriptor(), {
      source: 'gmail', sourceRef: 'acct-1:old', sender: null, summary: 'stale',
      suggestedTitle: null, receivedAt: '1786276799',
    }, windowStart, NOW)).toBeNull();
  });
});

describe('collectSignalsForDescriptor — bounds', () => {
  it('makes ZERO provider calls when the user has no ACTIVE account for the toolkit', async () => {
    const { executor, calls } = executorWith([{ items: [raw('m1')], nextPageToken: null }]);
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({
      accounts: accountsWith([]),
      executor,
    }));
    expect(result.unavailableReason).toBe('no_active_connection');
    expect(calls).toHaveLength(0);
    expect(result.signals).toEqual([]);
  });

  it('refuses — with ZERO provider calls — when more than maxAccounts are active', async () => {
    const { executor, calls } = executorWith([{ items: [raw('m1')], nextPageToken: null }]);
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({
      accounts: accountsWith(['a', 'b', 'c', 'd']),
      executor,
    }));
    expect(SIGNAL_INGEST_BOUNDS.maxAccounts).toBe(3);
    expect(result.unavailableReason).toBe('active_connection_cap_exceeded');
    expect(calls).toHaveLength(0);
  });

  it('stops at maxPages per account even when the provider always offers another cursor', async () => {
    const { executor, calls } = executorWith([{ items: [raw('m1')], nextPageToken: 'next' }]);
    await collectSignalsForDescriptor(USER, descriptor({
      // Unique per page so the item cap never ends the loop before the page cap does.
      mapItem: (item, account) => ({
        source: 'gmail',
        sourceRef: `${account}:${(item as RawItem).id}:${Math.random()}`,
        sender: null, summary: 'x', suggestedTitle: null, receivedAt: NOW.toISOString(),
      }),
    }), NOW, deps({ accounts: accountsWith(['acct-1', 'acct-2']), executor }));
    expect(SIGNAL_INGEST_BOUNDS.maxPages).toBe(3);
    expect(calls.filter((c) => c.connectedAccountId === 'acct-1')).toHaveLength(3);
    expect(calls.filter((c) => c.connectedAccountId === 'acct-2')).toHaveLength(3);
  });

  it('a descriptor cannot widen the item cap by asking the provider for more', async () => {
    const items = Array.from({ length: 50 }, (_, i) => raw(`m${i}`));
    const { executor, calls } = executorWith([{ items, nextPageToken: null }]);
    const result = await collectSignalsForDescriptor(USER, descriptor({
      buildQuery: () => ({ max_results: 1_000 }),
    }), NOW, deps({ executor }));
    // The runner passes the descriptor's query through verbatim — bounds are enforced by COUNTING
    // what came back, never by trusting what was asked for.
    expect(calls[0].arguments).toEqual({ max_results: 1_000 });
    expect(result.fetched).toBe(50);
    expect(result.signals).toHaveLength(SIGNAL_INGEST_BOUNDS.maxItems);
    expect(result.fetched).toBe(result.dropped + result.signals.length);
  });

  it('splits the item budget across accounts rather than letting the first mailbox win', async () => {
    const items = Array.from({ length: 30 }, (_, i) => raw(`m${i}`));
    const { executor } = executorWith([{ items, nextPageToken: null }]);
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({
      accounts: accountsWith(['acct-1', 'acct-2']),
      executor,
    }));
    const perAccount = (id: string) => result.signals.filter((s) => s.sourceRef.startsWith(`${id}:`)).length;
    expect(perAccount('acct-1')).toBe(10);
    expect(perAccount('acct-2')).toBe(10);
  });

  it('drops items outside [windowStart, now] after the provider returns them', async () => {
    const tooOld = new Date(NOW.getTime() - 25 * 3_600_000).toISOString();
    const future = new Date(NOW.getTime() + 60_000).toISOString();
    const { executor } = executorWith([{
      items: [raw('old', { timestamp: tooOld }), raw('future', { timestamp: future }), raw('ok')],
      nextPageToken: null,
    }]);
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({ executor }));
    expect(result.fetched).toBe(3);
    expect(result.dropped).toBe(2);
    expect(result.signals.map((s) => s.sourceRef)).toEqual(['acct-1:ok']);
  });

  it('drops in-batch duplicates on source_ref — the key the database is unique on', async () => {
    const { executor } = executorWith([{ items: [raw('m1'), raw('m1'), raw('m2')], nextPageToken: null }]);
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({ executor }));
    expect(result.fetched).toBe(3);
    expect(result.signals).toHaveLength(2);
    expect(result.dropped).toBe(1);
  });

  it('one item that makes mapItem throw does not lose the rest of the page', async () => {
    const { executor } = executorWith([{ items: [raw('bad'), raw('good')], nextPageToken: null }]);
    const result = await collectSignalsForDescriptor(USER, descriptor({
      mapItem: (item, account) => {
        const value = item as RawItem;
        if (value.id === 'bad') throw new Error('provider changed shape');
        return {
          source: 'gmail', sourceRef: `${account}:${value.id}`, sender: null,
          summary: 'ok', suggestedTitle: null, receivedAt: NOW.toISOString(),
        };
      },
    }), NOW, deps({ executor }));
    expect(result.signals.map((s) => s.sourceRef)).toEqual(['acct-1:good']);
    expect(result.dropped).toBe(1);
    expect(result.unavailableReason).toBeNull();
  });
});

describe('collectSignalsForDescriptor — failure classification', () => {
  it('classifies a blown wall-clock budget as `timeout` and KEEPS what it already mapped', async () => {
    const clock = halfBudgetClock(); // page 1 fits the deadline, page 2 does not
    const { executor, calls } = executorWith([{ items: [raw('m1')], nextPageToken: 'next' }]);
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({ executor, clock }));
    expect(calls).toHaveLength(1);
    expect(result.unavailableReason).toBe('timeout');
    expect(result.signals).toHaveLength(1);
  });

  it('never surfaces the provider error text — reason codes only, because it can quote a message', async () => {
    const executor: ConnectorSignalExecutor = {
      async fetchPage() {
        throw new Error('500 from provider while reading "Re: your bank password is hunter2"');
      },
    };
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({ executor }));
    expect(result.unavailableReason).toBe('connector_unavailable');
    expect(JSON.stringify(result)).not.toContain('hunter2');
  });

  it('classifies a failing account lookup as unavailable rather than "no connection"', async () => {
    const result = await collectSignalsForDescriptor(USER, descriptor(), NOW, deps({
      accounts: {
        listActiveAccountIdsByToolkit: async () => { throw new Error('composio 503'); },
      },
    }));
    expect(result.unavailableReason).toBe('connector_unavailable');
  });
});

describe('ingestSignalsForUser — honest counters', () => {
  it('counts a re-ingested source_ref as a DUPLICATE, never as new work', async () => {
    const { writer, rows } = memoryWriter();
    const pages = () => executorWith([{ items: [raw('m1'), raw('m2')], nextPageToken: null }]).executor;

    const first = await ingestSignalsForUser(USER, [descriptor()], NOW, deps({ executor: pages(), write: writer }));
    expect(first).toMatchObject({ sources: 1, fetched: 2, ingested: 2, duplicates: 0, failed: 0 });

    const second = await ingestSignalsForUser(USER, [descriptor()], NOW, deps({ executor: pages(), write: writer }));
    expect(second).toMatchObject({ sources: 1, fetched: 2, ingested: 0, duplicates: 2, failed: 0 });
    expect(rows.size).toBe(2);
  });

  it('every counter reconciles: fetched === dropped + ingested + duplicates + writesFailed', async () => {
    const { writer } = memoryWriter();
    const failing: SignalWriter = async (userId, signal) => {
      if (signal.sourceRef.endsWith('boom')) throw new Error('deadlock detected');
      return writer(userId, signal);
    };
    const { executor } = executorWith([{
      items: [raw('m1'), raw('m1'), raw('boom'), raw('stale', { timestamp: '2020-01-01T00:00:00Z' })],
      nextPageToken: null,
    }]);
    const counters = await ingestSignalsForUser(USER, [descriptor()], NOW, deps({ executor, write: failing }));
    expect(counters.fetched).toBe(4);
    expect(counters.dropped).toBe(2); // one in-batch duplicate + one out-of-window
    expect(counters.ingested).toBe(1);
    expect(counters.duplicates).toBe(0);
    expect(counters.writesFailed).toBe(1);
    expect(counters.fetched).toBe(
      counters.dropped + counters.ingested + counters.duplicates + counters.writesFailed,
    );
    expect(counters.failed).toBe(counters.sourcesFailed + counters.writesFailed);
  });

  it('a source with no connection is SKIPPED, not counted as an attempted read', async () => {
    const counters = await ingestSignalsForUser(USER, [descriptor()], NOW, deps({
      accounts: accountsWith([]),
    }));
    expect(counters).toMatchObject({ sources: 0, sourcesSkipped: 1, sourcesFailed: 0, failed: 0 });
  });

  it('an incomplete read is counted as failed even when it still wrote rows', async () => {
    const clock = halfBudgetClock();
    const { executor } = executorWith([{ items: [raw('m1')], nextPageToken: 'next' }]);
    const counters = await ingestSignalsForUser(USER, [descriptor()], NOW, deps({ executor, clock }));
    expect(counters.ingested).toBe(1);
    expect(counters.sourcesFailed).toBe(1);
    expect(counters.failed).toBe(1);
  });

  it('one source failing does not stop the next source for the same user', async () => {
    const slack = descriptor({
      source: 'slack',
      toolkitSlug: 'slack',
      displayName: 'Slack',
      // A descriptor must emit ITS OWN source — the base factory's mapItem hardcodes 'gmail', and
      // the runner would (correctly) drop every one of those as a source mismatch.
      mapItem: (item, account) => ({
        source: 'slack', sourceRef: `${account}:${(item as RawItem).id}`, sender: null,
        summary: 'x', suggestedTitle: null, receivedAt: NOW.toISOString(),
      }),
    });
    const executor: ConnectorSignalExecutor = {
      async fetchPage(input) {
        if (input.action === 'GMAIL_FETCH_EMAILS' && input.version === 'break') {
          throw new Error('gmail down');
        }
        return { items: [raw('m1')], nextPageToken: null };
      },
    };
    const counters = await ingestSignalsForUser(
      USER,
      [descriptor({ actionVersion: 'break' }), slack],
      NOW,
      deps({ executor }),
    );
    expect(counters.sources).toBe(2);
    expect(counters.sourcesFailed).toBe(1);
    expect(counters.ingested).toBe(1);
  });

  /**
   * THE ROUND-TRIP DEFECT. `collectSignalsForDescriptor` asked
   * `listActiveAccountIds(userId, descriptor.toolkitSlug)` PER DESCRIPTOR — one Composio round
   * trip each, every one of them spent before a single message is fetched, and every one of them
   * charged against the wall-clock budget that decides how many users the tick reaches at all.
   * At one descriptor it is invisible. At the catalog this product is heading toward it is 13.
   */
  it('discovers connections in ONE provider call per user per tick, not one per descriptor', async () => {
    const asked: string[][] = [];
    const accounts: ActiveConnectorAccountsByToolkitSource = {
      listActiveAccountIdsByToolkit: async (_userId, toolkitSlugs) => {
        asked.push([...toolkitSlugs]);
        return new Map(toolkitSlugs.map((slug) => [slug, ['acct-1']]));
      },
    };
    const sources = ['gmail', 'slack', 'notion', 'linear'];
    const descriptors = sources.map((source) => descriptor({
      source,
      toolkitSlug: source,
      displayName: source,
      mapItem: (item, account) => ({
        source,
        sourceRef: `${account}:${(item as RawItem).id}`,
        sender: null,
        summary: 'a message arrived',
        suggestedTitle: null,
        receivedAt: NOW.toISOString(),
      }),
    }));
    const { writer } = memoryWriter();

    const counters = await ingestSignalsForUser(USER, descriptors, NOW, deps({
      accounts,
      executor: executorWith([{ items: [raw('m1')], nextPageToken: null }]).executor,
      write: writer,
    }));

    // Every source still read and written — the saving is round trips, not coverage.
    expect(counters).toMatchObject({ sources: 4, ingested: 4, failed: 0 });
    expect(asked, 'one account lookup for the whole tick').toHaveLength(1);
    expect([...asked[0]].sort()).toEqual([...sources].sort());
  });

  it('a failed shared lookup fails EVERY source individually, never one lost user', async () => {
    const counters = await ingestSignalsForUser(
      USER,
      [descriptor(), descriptor({ source: 'slack', toolkitSlug: 'slack' })],
      NOW,
      deps({ accounts: { listActiveAccountIdsByToolkit: async () => { throw new Error('composio 503'); } } }),
    );
    // Batching the lookup must not batch the ACCOUNTING: two descriptors were attempted, so two
    // sources failed. Collapsing them into one would under-report the outage.
    expect(counters).toMatchObject({ sources: 2, sourcesFailed: 2, failed: 2, ingested: 0 });
  });

  it('never logs message-derived text, on either the write-failure or incomplete-read path', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const { executor } = executorWith([{
      items: [raw('m1', { summary: 'PATIENT RECORD: confidential body text', sender: 'ada@example.com' })],
      nextPageToken: 'next',
    }]);
    const clock = halfBudgetClock();
    await ingestSignalsForUser(USER, [descriptor()], NOW, deps({
      executor,
      clock,
      write: async () => { throw new Error('duplicate key value violates "PATIENT RECORD: confidential body text"'); },
    }));
    const logged = [...errorSpy.mock.calls, ...warnSpy.mock.calls].flat().join(' ');
    expect(logged).not.toContain('PATIENT RECORD');
    expect(logged).not.toContain('ada@example.com');
    expect(logged).toContain('gmail');
  });
});

describe('runSignalIngestBatch — per-user isolation', () => {
  it("one user's connector failure never aborts the batch", async () => {
    const { writer, rows } = memoryWriter();
    const accounts: ActiveConnectorAccountsByToolkitSource = {
      listActiveAccountIdsByToolkit: async (userId, toolkitSlugs) => {
        if (userId === 'user-broken') throw new Error('composio 503 for this user');
        return new Map(toolkitSlugs.map((slug) => [slug, ['acct-1']]));
      },
    };
    const summary = await runSignalIngestBatch(
      ['user-broken', 'user-ok'],
      [descriptor()],
      NOW,
      deps({ accounts, write: writer }),
    );
    expect(summary.users).toBe(2);
    expect(summary.sourcesFailed).toBe(1);
    expect(summary.ingested).toBe(1);
    expect([...rows.keys()]).toEqual(['user-ok|gmail|acct-1:m1']);
  });

  it('costs users × 1 account lookups per tick, not users × descriptors', async () => {
    const asked: Array<{ userId: string; toolkitSlugs: string[] }> = [];
    const accounts: ActiveConnectorAccountsByToolkitSource = {
      listActiveAccountIdsByToolkit: async (userId, toolkitSlugs) => {
        asked.push({ userId, toolkitSlugs: [...toolkitSlugs] });
        return new Map(toolkitSlugs.map((slug) => [slug, ['acct-1']]));
      },
    };
    const sources = ['gmail', 'slack', 'notion'];
    const descriptors = sources.map((source) => descriptor({
      source,
      toolkitSlug: source,
      mapItem: (item, account) => ({
        source,
        sourceRef: `${account}:${(item as RawItem).id}`,
        sender: null,
        summary: 'a message arrived',
        suggestedTitle: null,
        receivedAt: NOW.toISOString(),
      }),
    }));
    const { writer } = memoryWriter();

    await runSignalIngestBatch(['user-a', 'user-b'], descriptors, NOW, deps({ accounts, write: writer }));

    // 2 users × 3 descriptors was 6 round trips; it is now 2. The per-user lookup stays per-user —
    // grants are per user, so this is the floor, not a cache we could drift from.
    expect(asked).toHaveLength(2);
    expect(asked.map((call) => call.userId)).toEqual(['user-a', 'user-b']);
    expect([...asked[0].toolkitSlugs].sort()).toEqual([...sources].sort());
  });

  it('keeps each user\'s signals under their own id', async () => {
    const { writer, rows } = memoryWriter();
    const summary = await runSignalIngestBatch(['user-a', 'user-b'], [descriptor()], NOW, deps({ write: writer }));
    expect(summary.ingested).toBe(2);
    expect([...rows.keys()].sort()).toEqual(['user-a|gmail|acct-1:m1', 'user-b|gmail|acct-1:m1']);
  });

  it('an EMPTY descriptor registry is an honest no-op: zero users touched, zero reads', async () => {
    const listActiveAccountIdsByToolkit = vi.fn(async () => new Map<string, string[]>());
    const { executor, calls } = executorWith([{ items: [raw('m1')], nextPageToken: null }]);
    const summary = await runSignalIngestBatch(['user-a'], [], NOW, deps({
      accounts: { listActiveAccountIdsByToolkit },
      executor,
    }));
    expect(summary).toMatchObject({ users: 0, sources: 0, fetched: 0, ingested: 0, failed: 0 });
    expect(listActiveAccountIdsByToolkit).not.toHaveBeenCalled();
    expect(calls).toHaveLength(0);
  });

  it('stops at the batch wall-clock budget and REPORTS the users it never reached', async () => {
    let time = 0;
    const { writer } = memoryWriter();
    const summary = await runSignalIngestBatch(['a', 'b', 'c', 'd'], [descriptor()], NOW, deps({
      clock: () => time,
      batchBudgetMs: 120_000,
      write: async (userId, signal) => { time += 70_000; return writer(userId, signal); },
    }));
    expect(summary.users).toBe(2);
    expect(summary.usersSkipped).toBe(2);
    expect(summary.ingested).toBe(2);
  });
});

describe('selectSignalIngestUsers', () => {
  it('selects recently-active users and binds the window as a coerced integer parameter', async () => {
    const query = vi.fn(async () => ({ rows: [{ id: 'u1' }, { id: 'u2' }] }));
    const db: QueryableDb = { query };
    expect(await selectSignalIngestUsers(db, 90)).toEqual(['u1', 'u2']);
    const [sql, params] = query.mock.calls[0] as unknown as [string, unknown[]];
    expect(sql).toContain('last_active_at >= NOW()');
    expect(params).toEqual(['90']);
  });

  it('a non-finite window falls back to the default instead of binding NaN', async () => {
    // Binding 'NaN' would make the predicate NULL — every user excluded, reported as a clean
    // `users=0` run. That is exactly the "green signal that measures nothing" failure mode.
    const query = vi.fn(async () => ({ rows: [] }));
    await selectSignalIngestUsers({ query }, Number.NaN);
    const [sql, params] = query.mock.calls[0] as unknown as [string, unknown[]];
    expect(sql).not.toContain('NaN');
    expect(params).toEqual([String(SIGNAL_INGEST_ACTIVE_WINDOW_MINUTES)]);
  });

  it('clamps an absurd window rather than turning the poller into a fleet-wide scan', async () => {
    const query = vi.fn(async () => ({ rows: [] }));
    await selectSignalIngestUsers({ query }, 5_000_000);
    expect((query.mock.calls[0] as unknown as [string, unknown[]])[1])
      .toEqual([String(SIGNAL_INGEST_MAX_WINDOW_MINUTES)]);
  });
});

describe('a quiet mailbox is not a failed run', () => {
  const base = {
    users: 1, usersSkipped: 0, sources: 1, sourcesSkipped: 0, sourcesFailed: 0,
    ingested: 0, duplicates: 0, writesFailed: 0, failed: 0,
    // Relevance counters are reported but deliberately excluded from the failure arithmetic.
    judged: 0, judgedAct: 0, judgedDrop: 0, judgeUnjudged: 0, judgeUnavailable: 0,
  };

  // OBSERVED before this fix, through the real executor/descriptor/batch: NOW=2026-08-10T15:00:00Z
  // with one legitimate message dated 2026-08-09T08:00:00Z gave
  //   QUERY {"query":"after:2026/08/09 before:2026/08/11"}
  //   fetched=1 dropped=1 ingested=0 duplicates=0  ->  fetched_but_ingested_nothing, exit 1
  // gmailSignalDescriptor.buildQuery asks for whole CALENDAR DAYS because Gmail's query language
  // cannot express a rolling 24h bound, so trimming the excess is the design working. cron-all
  // exits 1 if any job fails, so this reddened the entire 15-minute Railway tick for any mailbox
  // whose only recent mail predates the window but shares its calendar day.
  it('does not fail the run when everything fetched was merely outside the window', () => {
    const summary = { ...base, fetched: 1, dropped: 1, outOfWindow: 1 };
    expect(signalIngestFailureReason(summary)).toBeNull();
    expect(signalIngestExitCode(summary)).toBe(0);
  });

  // The guard must not swallow the real case it was added for (#round-3: a producer that fetched
  // real work and wrote nothing).
  it('still fails when items were in-window and none were written', () => {
    const summary = { ...base, fetched: 1, dropped: 1, outOfWindow: 0 };
    expect(signalIngestFailureReason(summary)).toBe('fetched_but_ingested_nothing');
    expect(signalIngestExitCode(summary)).toBe(1);
  });

  it('still fails on a mixed page where the in-window items all failed to map', () => {
    const summary = { ...base, fetched: 5, dropped: 5, outOfWindow: 3 };
    expect(signalIngestFailureReason(summary)).toBe('fetched_but_ingested_nothing');
    expect(signalIngestExitCode(summary)).toBe(1);
  });
});

describe('formatSignalIngestSummary', () => {
  it('prints every counter, so no single number can stand in for the run', () => {
    const line = formatSignalIngestSummary({
      users: 3, usersSkipped: 1, sources: 2, sourcesSkipped: 4, sourcesFailed: 1,
      fetched: 9, dropped: 3, outOfWindow: 2, ingested: 4, duplicates: 1, writesFailed: 1, failed: 2,
      judged: 7, judgedAct: 2, judgedDrop: 4, judgeUnjudged: 1, judgeUnavailable: 1,
    });
    for (const fragment of [
      'users=3', 'skippedUsers=1', 'sources=2', 'skippedSources=4', 'outOfWindow=2',
      'fetched=9', 'dropped=3', 'ingested=4', 'duplicates=1', 'failed=2',
      // The relevance verdicts are part of the run's honest record: a tick that judged 7 signals
      // and hid 4 of them from the user must say so on the line an operator actually reads.
      'judged=7', 'act=2', 'drop=4', 'unjudged=1', 'unavailable=1',
    ]) {
      expect(line).toContain(fragment);
    }
  });
});

describe('signalIngestExitCode', () => {
  const base = {
    users: 1, usersSkipped: 0, sources: 0, sourcesSkipped: 0, sourcesFailed: 0,
    fetched: 0, outOfWindow: 0, dropped: 0, ingested: 0, duplicates: 0, writesFailed: 0, failed: 0,
    judged: 0, judgedAct: 0, judgedDrop: 0, judgeUnjudged: 0, judgeUnavailable: 0,
  };

  /**
   * REGRESSION. The exit expression was
   *   `summary.sources > 0 && summary.sourcesFailed === summary.sources ? 1 : 0`
   * which does not mention `writesFailed` at all. A run where every COLLECT succeeded and every
   * WRITE failed — Postgres unreachable, a constraint violation, a bad DATABASE_URL on rem-cron —
   * exited 0. That is a green cron tick that read the user's mail and persisted none of it: the
   * exact "green signal that measures nothing" this job is supposed to make impossible.
   */
  it('is RED when the write path failed even though every collect succeeded', () => {
    expect(signalIngestExitCode({
      ...base, sources: 2, sourcesFailed: 0, fetched: 10, ingested: 0, writesFailed: 10, failed: 10,
    })).toBe(1);
  });

  it('is RED on a single write failure — a partially persisted tick is not success', () => {
    expect(signalIngestExitCode({
      ...base, sources: 2, fetched: 10, ingested: 9, writesFailed: 1, failed: 1,
    })).toBe(1);
  });

  it('is RED when every attempted source failed', () => {
    expect(signalIngestExitCode({ ...base, sources: 2, sourcesFailed: 2, failed: 2 })).toBe(1);
  });

  it('is GREEN on a partial source failure — one flaky connector is not an outage', () => {
    expect(signalIngestExitCode({
      ...base, sources: 3, sourcesFailed: 1, ingested: 4, failed: 1,
    })).toBe(0);
  });

  it('is GREEN when nobody had a connector to read', () => {
    expect(signalIngestExitCode({ ...base, sources: 0, sourcesSkipped: 5 })).toBe(0);
  });

  it('is GREEN on a clean run', () => {
    expect(signalIngestExitCode({ ...base, sources: 2, fetched: 6, ingested: 6 })).toBe(0);
  });

  /**
   * REGRESSION #2 — the shape that survived two review rounds.
   *
   * Every counter can be individually healthy while the job does nothing: no source failed, no
   * write failed, no exception was thrown, and not one row was written — because the descriptor
   * refused every item (a `mapItem` reading field names the transport no longer emits). The log
   * read `fetched=2 dropped=2 ingested=0 failed=0` and the process exited 0.
   *
   * These cases pin the PREDICATE. The end-to-end proof that it fires on the real thing — real
   * `composioSignalExecutor`, real registry, real `channel_signals` — is in
   * `signal-ingest.executor-shape.db.test.ts`; a hand-built counter tuple cannot establish that,
   * and pretending it could is the mistake this whole branch is correcting.
   */
  it('is RED when items were fetched and NOT ONE of them reached the table', () => {
    expect(signalIngestExitCode({ ...base, sources: 1, fetched: 2, outOfWindow: 0, dropped: 2 })).toBe(1);
    expect(signalIngestFailureReason({ ...base, sources: 1, fetched: 2, outOfWindow: 0, dropped: 2 }))
      .toBe('fetched_but_ingested_nothing');
  });

  /**
   * The deliberate carve-out. This poller re-reads a rolling 24h window every 15 minutes, so
   * `fetched=20 ingested=0 duplicates=20` is the HEALTHY steady state — every message is already
   * a row. Firing on `ingested === 0` alone would turn the cron permanently red inside one window,
   * which teaches everyone to ignore it: a false red is the same disease as a false green.
   */
  it('is GREEN when nothing was NEW but every fetched item is already a row', () => {
    expect(signalIngestExitCode({ ...base, sources: 1, fetched: 20, duplicates: 20 })).toBe(0);
    expect(signalIngestFailureReason({ ...base, sources: 1, fetched: 20, duplicates: 20 })).toBeNull();
  });

  it('is GREEN when the window was simply empty — nothing fetched is not a failure', () => {
    expect(signalIngestExitCode({ ...base, sources: 2, fetched: 0 })).toBe(0);
    expect(signalIngestFailureReason({ ...base, sources: 2, fetched: 0 })).toBeNull();
  });

  it('names writes and total source failure ahead of the productivity check', () => {
    // Ordering matters to whoever reads the log: "the database is down" is more actionable than
    // "nothing landed", and the second is implied by the first.
    expect(signalIngestFailureReason({
      ...base, sources: 1, fetched: 3, writesFailed: 3, failed: 3,
    })).toBe('writes_failed');
    expect(signalIngestFailureReason({
      ...base, sources: 1, sourcesFailed: 1, fetched: 3, outOfWindow: 0, dropped: 3, failed: 1,
    })).toBe('all_sources_failed');
  });

  it('every failure reason has an operator message, so a red run always says what to check', () => {
    for (const reason of ['writes_failed', 'all_sources_failed', 'fetched_but_ingested_nothing'] as const) {
      expect(SIGNAL_INGEST_FAILURE_MESSAGES[reason]).toBeTruthy();
    }
  });
});
