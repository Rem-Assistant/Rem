import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ConnectorSignalDescriptor, NormalizedSignal } from './connector-signals.registry.js';
import {
  collectConnectorSignals,
  ConnectorSignalTimeoutError,
  CONNECTOR_SIGNAL_BOUNDS,
  type ConnectorSignalFetchInput,
  type ConnectorSignalPage,
} from './connector-signals.runner.js';

const NOW = new Date('2026-08-09T17:00:00.000Z');
const IN_WINDOW = '2026-08-09T16:30:00.000Z';

interface Raw {
  id: string;
  at?: string;
  foreignSource?: string;
  drop?: boolean;
}

/**
 * A deliberately greedy descriptor: it asks for far more than the bounds allow and tries to
 * overwrite runner-owned fetch keys through `buildQuery`. The runner must win every time.
 */
function descriptor(overrides: Partial<ConnectorSignalDescriptor> = {}): ConnectorSignalDescriptor {
  return {
    source: 'testsource',
    toolkitSlug: 'testkit',
    action: 'TEST_FETCH',
    actionVersion: '20260101_00',
    displayName: 'Test',
    buildQuery: () => ({ q: 'window' }),
    mapItem: (raw: unknown, connectedAccountId: string): NormalizedSignal | null => {
      const item = raw as Raw;
      if (item.drop) return null;
      return {
        source: item.foreignSource ?? 'testsource',
        sourceRef: `${connectedAccountId}:${item.id}`,
        sender: 'Ada',
        summary: `summary ${item.id}`,
        suggestedTitle: null,
        receivedAt: item.at ?? IN_WINDOW,
      };
    },
    ...overrides,
  };
}

function accounts(ids: string[]) {
  return { listActiveAccountIds: vi.fn(async () => ids) };
}

function pagingAdapter(pageFor: (call: number) => ConnectorSignalPage<Raw>) {
  let call = 0;
  // Typed on the fetch input so `mock.calls[0][0]` stays a real `ConnectorSignalFetchInput` —
  // the bounds assertions below read it directly.
  const fetchPage = vi.fn(
    async (_input: ConnectorSignalFetchInput): Promise<ConnectorSignalPage<Raw>> => pageFor(call++),
  );
  return { fetchPage };
}

function items(count: number, prefix = 'm'): Raw[] {
  return Array.from({ length: count }, (_, index) => ({ id: `${prefix}${index}` }));
}

let warn: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe('collectConnectorSignals — bounds are the runner\'s, never a descriptor\'s', () => {
  it('caps a single greedy page at maxItems', async () => {
    const adapter = pagingAdapter(() => ({ items: items(50), nextPageToken: null }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result.availability).toBe('available');
    expect(result.collected).toHaveLength(CONNECTOR_SIGNAL_BOUNDS.maxItems);
  });

  it('splits maxItems across accounts so N accounts cannot multiply the cap', async () => {
    const adapter = pagingAdapter(() => ({ items: items(30), nextPageToken: null }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a', 'b']), adapter,
    });
    expect(result.collected).toHaveLength(CONNECTOR_SIGNAL_BOUNDS.maxItems);
    expect(result.connectedAccountIds).toEqual(['a', 'b']);
  });

  it('stops at maxPages however many pages the provider offers', async () => {
    const adapter = pagingAdapter((call) => ({ items: items(1, `p${call}-`), nextPageToken: 'more' }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(adapter.fetchPage).toHaveBeenCalledTimes(CONNECTOR_SIGNAL_BOUNDS.maxPages);
    expect(result.collected).toHaveLength(CONNECTOR_SIGNAL_BOUNDS.maxPages);
  });

  it('stops paging as soon as the item budget is spent, even with a cursor left', async () => {
    const adapter = pagingAdapter(() => ({ items: items(50), nextPageToken: 'more' }));
    await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(adapter.fetchPage).toHaveBeenCalledTimes(1);
  });

  it('fails closed above maxAccounts without touching the provider', async () => {
    const adapter = pagingAdapter(() => ({ items: items(1), nextPageToken: null }));
    const source = accounts(['a', 'b', 'c', 'd']);
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: source, adapter,
    });
    expect(result).toMatchObject({
      availability: 'unavailable',
      unavailableReason: 'active_connection_cap_exceeded',
      connectedAccountIds: [],
      collected: [],
    });
    expect(adapter.fetchPage).not.toHaveBeenCalled();
  });

  it('reports no_active_connection rather than reading with zero grants', async () => {
    const adapter = pagingAdapter(() => ({ items: items(1), nextPageToken: null }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts([]), adapter,
    });
    expect(result).toMatchObject({ availability: 'unavailable', unavailableReason: 'no_active_connection' });
    expect(adapter.fetchPage).not.toHaveBeenCalled();
  });

  it('refuses a buildQuery that tries to widen maxResults, timeoutMs, or seed a cursor', async () => {
    const greedy = descriptor({
      buildQuery: () => ({
        q: 'window',
        maxResults: 5_000,
        timeoutMs: 900_000,
        pageToken: 'descriptor-cursor',
        action: 'SOMETHING_ELSE',
        version: 'floating',
        userId: 'other-user',
        connectedAccountId: 'other-account',
      }),
    });
    const adapter = pagingAdapter(() => ({ items: items(1), nextPageToken: null }));
    await collectConnectorSignals(greedy, { userId: 'u', now: NOW, accounts: accounts(['a']), adapter });
    const input = adapter.fetchPage.mock.calls[0][0];
    expect(input).toMatchObject({
      q: 'window',
      userId: 'u',
      connectedAccountId: 'a',
      action: 'TEST_FETCH',
      version: '20260101_00',
      maxResults: CONNECTOR_SIGNAL_BOUNDS.maxItems,
    });
    expect(input.timeoutMs).toBeLessThanOrEqual(CONNECTOR_SIGNAL_BOUNDS.timeoutMs);
    expect(input.pageToken).toBeUndefined();
  });
});

describe('collectConnectorSignals — item handling', () => {
  it('drops an item whose mapItem returns null, without spending the item budget', async () => {
    const adapter = pagingAdapter(() => ({
      items: [{ id: 'keep-1' }, { id: 'skip', drop: true }, { id: 'keep-2' }],
      nextPageToken: null,
    }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result.collected.map((entry) => entry.stableId))
      .toEqual(['testsource:a:keep-1', 'testsource:a:keep-2']);
  });

  it('drops an item whose signal claims a source the descriptor does not own', async () => {
    const adapter = pagingAdapter(() => ({
      items: [{ id: 'mine' }, { id: 'theirs', foreignSource: 'slack' }],
      nextPageToken: null,
    }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result.collected.map((entry) => entry.signal.sourceRef)).toEqual(['a:mine']);
  });

  it('re-checks timestamps against the exact window and accepts both ISO 8601 forms', async () => {
    const adapter = pagingAdapter(() => ({
      items: [
        { id: 'before', at: '2026-08-08T16:59:59.999Z' },
        { id: 'start', at: '2026-08-08T17:00:00.000Z' },
        { id: 'no-fraction', at: '2026-08-09T12:00:00Z' },
        { id: 'end', at: NOW.toISOString() },
        { id: 'after', at: '2026-08-09T17:00:00.001Z' },
        { id: 'garbage', at: 'yesterday' },
      ],
      nextPageToken: null,
    }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result.collected.map((entry) => entry.signal.sourceRef))
      .toEqual(['a:end', 'a:no-fraction', 'a:start']);
    expect(result.windowStart).toBe('2026-08-08T17:00:00.000Z');
    expect(result.windowEnd).toBe('2026-08-09T17:00:00.000Z');
  });

  it('orders by instant, not by text, so mixed ISO 8601 forms cannot invert the sort', async () => {
    const adapter = pagingAdapter(() => ({
      items: [
        // Lexicographically '…:00Z' > '…:00.500Z' (Z outranks '.'), but it happened FIRST.
        { id: 'earlier', at: '2026-08-09T12:00:00Z' },
        { id: 'later', at: '2026-08-09T12:00:00.500Z' },
      ],
      nextPageToken: null,
    }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result.collected.map((entry) => entry.signal.sourceRef)).toEqual(['a:later', 'a:earlier']);
  });

  it('deduplicates cursor overlap on <source>:<sourceRef>', async () => {
    const adapter = pagingAdapter((call) => ({
      items: [{ id: 'same' }],
      nextPageToken: call === 0 ? 'more' : null,
    }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(adapter.fetchPage).toHaveBeenCalledTimes(2);
    expect(result.collected).toHaveLength(1);
    expect(result.collected[0].stableId).toBe('testsource:a:same');
    expect(result.collected[0].raw).toEqual({ id: 'same' });
  });

  it('distinguishes a successful empty read from an unavailable one', async () => {
    const adapter = pagingAdapter(() => ({ items: [], nextPageToken: null }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result).toMatchObject({ availability: 'available', unavailableReason: null, collected: [] });
  });
});

describe('collectConnectorSignals — failure classification', () => {
  it('classifies the runner\'s own deadline breach as timeout and discards the prefix', async () => {
    vi.useFakeTimers();
    const adapter = pagingAdapter(() => {
      vi.advanceTimersByTime(CONNECTOR_SIGNAL_BOUNDS.timeoutMs + 1);
      return { items: items(1), nextPageToken: 'more' };
    });
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(adapter.fetchPage).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({ availability: 'unavailable', unavailableReason: 'timeout', collected: [] });
  });

  it('treats an AbortSignal.timeout DOMException as timeout via its name, not its text', async () => {
    const aborted = new Error('The operation was aborted due to timeout');
    aborted.name = 'TimeoutError';
    const adapter = pagingAdapter(() => { throw aborted; });
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result.unavailableReason).toBe('timeout');
  });

  it('still honours the legacy Error("timeout") that listActiveGmailAccountIds throws', async () => {
    const source = { listActiveAccountIds: vi.fn(async () => { throw new Error('timeout'); }) };
    const adapter = pagingAdapter(() => ({ items: items(1), nextPageToken: null }));
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: source, adapter,
    });
    expect(result.unavailableReason).toBe('timeout');
    expect(adapter.fetchPage).not.toHaveBeenCalled();
  });

  it('classifies anything else as connector_unavailable and never a partial read', async () => {
    const adapter = pagingAdapter((call) => {
      if (call === 1) throw new Error('provider down');
      return { items: items(1), nextPageToken: 'more' };
    });
    const result = await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(result).toMatchObject({ availability: 'unavailable', unavailableReason: 'connector_unavailable', collected: [] });
  });

  it('logs the descriptor source, the error class and a truncated message', async () => {
    const adapter = pagingAdapter(() => { throw new Error(`boom ${'y'.repeat(500)}`); });
    await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(warn).toHaveBeenCalledTimes(1);
    const line = String(warn.mock.calls[0][0]);
    expect(line).toContain('[connector-signals] testsource collect connector_unavailable: Error: boom');
    expect(line.length).toBeLessThan(300);
    expect(line.endsWith('…')).toBe(true);
  });

  it('names the timeout class rather than a generic Error', async () => {
    const adapter = pagingAdapter(() => { throw new ConnectorSignalTimeoutError(); });
    await collectConnectorSignals(descriptor(), {
      userId: 'u', now: NOW, accounts: accounts(['a']), adapter,
    });
    expect(String(warn.mock.calls[0][0]))
      .toContain('[connector-signals] testsource collect timeout: ConnectorSignalTimeoutError');
  });
});

describe('one malformed item cannot speak for the whole collection', () => {
  /**
   * REGRESSION. `descriptor.mapItem()` was called unguarded inside the page loop, so a single
   * throwing item propagated to the outer catch and the ENTIRE collect became
   * `connector_unavailable`: every other message in the window discarded, and (on the Daily Brief
   * path) a snapshot that reports we could not look at the mailbox at all. One bad row is a
   * descriptor bug about one row; it is not an outage.
   */
  it('drops the throwing item, keeps the rest, and stays available', async () => {
    const adapter = pagingAdapter(() => ({
      items: [{ id: 'good-1' }, { id: 'poison' }, { id: 'good-2' }],
      nextPageToken: null,
    }));
    const result = await collectConnectorSignals(
      descriptor({
        mapItem: (raw: unknown, accountId: string) => {
          const item = raw as Raw;
          if (item.id === 'poison') throw new TypeError("Cannot read 'subject' of undefined");
          return {
            source: 'testsource',
            sourceRef: `${accountId}:${item.id}`,
            sender: 'Ada',
            summary: `summary ${item.id}`,
            suggestedTitle: null,
            receivedAt: IN_WINDOW,
          };
        },
      }),
      { userId: 'u', now: NOW, accounts: accounts(['a']), adapter },
    );

    expect(result.availability).toBe('available');
    expect(result.unavailableReason).toBeNull();
    expect(result.collected.map((entry) => entry.signal.sourceRef))
      .toEqual(['a:good-1', 'a:good-2']);
  });

  it('COUNTS what it dropped, so a silent haemorrhage is visible', async () => {
    const adapter = pagingAdapter(() => ({
      items: [{ id: 'a' }, { id: 'b' }, { id: 'c' }],
      nextPageToken: null,
    }));
    const result = await collectConnectorSignals(
      descriptor({ mapItem: () => { throw new Error('always'); } }),
      { userId: 'u', now: NOW, accounts: accounts(['a']), adapter },
    );
    // Every item unmappable is still a COMPLETE read of an inbox we could not interpret — not a
    // connector outage. The count is the only thing that distinguishes it from an empty inbox.
    expect(result.availability).toBe('available');
    expect(result.collected).toHaveLength(0);
    expect(result.malformedItems).toBe(3);
  });

  it('never logs the thrown MESSAGE — mapItem runs on provider content', async () => {
    const adapter = pagingAdapter(() => ({ items: [{ id: 'x' }], nextPageToken: null }));
    await collectConnectorSignals(
      descriptor({
        mapItem: () => { throw new Error('failed on "Re: your invoice from alice@example.com"'); },
      }),
      { userId: 'u', now: NOW, accounts: accounts(['a']), adapter },
    );
    const logged = warn.mock.calls.flat().join(' ');
    expect(logged).not.toContain('alice@example.com');
    expect(logged).not.toContain('your invoice');
    expect(logged).toContain('Error');
  });
});

describe('a descriptor cannot reach the window it is handed', () => {
  /**
   * The file header claims a descriptor "has no field with which to widen a bound". `buildQuery`
   * used to receive the runner's OWN `windowStartDate`/`windowEndDate` objects — and `windowEndDate`
   * was literally the caller's `now` — so one `setTime()` would move the post-fetch re-check and
   * mutate the caller's clock. Clones are passed, making the comment true.
   */
  it('mutating the bounds inside buildQuery changes neither the re-check nor the caller\'s now', async () => {
    const now = new Date(NOW.getTime());
    const adapter = pagingAdapter(() => ({
      // Two years old: only kept if a descriptor managed to drag windowStart backwards.
      items: [{ id: 'ancient', at: '2024-01-01T00:00:00.000Z' }, { id: 'fresh' }],
      nextPageToken: null,
    }));

    const result = await collectConnectorSignals(
      descriptor({
        buildQuery(windowStart: Date, windowEnd: Date) {
          windowStart.setTime(Date.parse('2000-01-01T00:00:00.000Z'));
          windowEnd.setTime(Date.parse('2099-01-01T00:00:00.000Z'));
          return { q: 'window' };
        },
      }),
      { userId: 'u', now, accounts: accounts(['a']), adapter },
    );

    expect(result.collected.map((entry) => entry.signal.sourceRef)).toEqual(['a:fresh']);
    expect(result.windowEnd).toBe(NOW.toISOString());
    expect(result.windowStart).toBe(
      new Date(NOW.getTime() - CONNECTOR_SIGNAL_BOUNDS.windowHours * 3_600_000).toISOString(),
    );
    // The caller's clock is untouched.
    expect(now.getTime()).toBe(NOW.getTime());
  });
});

describe('the runner is source-generic', () => {
  /**
   * `ActiveConnectorAccountSource.listActiveAccountIds` was two-arg (userId, timeoutMs), so the
   * "shared" runner could not tell its account source WHICH toolkit authorized the read and
   * `descriptor.toolkitSlug` had no live read anywhere on this path. A second descriptor would
   * silently have been handed the first one's accounts.
   */
  it('asks for the DESCRIPTOR\'s toolkit, not a hardcoded one', async () => {
    const adapter = pagingAdapter(() => ({ items: [{ id: 'm' }], nextPageToken: null }));
    const source = accounts(['a']);
    await collectConnectorSignals(
      descriptor({ source: 'slack', toolkitSlug: 'slack', mapItem: () => null }),
      { userId: 'u', now: NOW, accounts: source, adapter },
    );
    expect(source.listActiveAccountIds).toHaveBeenCalledWith(
      'u', 'slack', CONNECTOR_SIGNAL_BOUNDS.timeoutMs,
    );
  });
});
