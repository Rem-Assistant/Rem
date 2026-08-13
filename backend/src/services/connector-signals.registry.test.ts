import { describe, expect, it } from 'vitest';
import {
  getDescriptor,
  gmailSignalDescriptor,
  listDescriptors,
  parseConnectorInstant,
  parseIsoInstant,
  GMAIL_BRIEF_ACTION,
  GMAIL_BRIEF_ACTION_VERSION,
} from './connector-signals.registry.js';

const RAW = {
  providerMessageId: 'msg-1',
  providerThreadId: 'thread-1',
  sender: 'Founder <founder@example.com>',
  subject: 'Launch review',
  snippet: 'Ship it Friday',
  timestamp: '2026-08-09T16:30:00.000Z',
};

describe('connector signal registry', () => {
  it('looks a descriptor up by source and carries the pinned action + version', () => {
    const descriptor = getDescriptor('gmail');
    expect(descriptor).toBe(gmailSignalDescriptor);
    expect(descriptor).toMatchObject({
      source: 'gmail',
      toolkitSlug: 'gmail',
      action: GMAIL_BRIEF_ACTION,
      actionVersion: GMAIL_BRIEF_ACTION_VERSION,
      displayName: 'Gmail',
    });
  });

  it('returns undefined for an unknown source instead of guessing or throwing', () => {
    expect(getDescriptor('slack')).toBeUndefined();
    expect(getDescriptor('')).toBeUndefined();
    expect(getDescriptor('GMAIL')).toBeUndefined();
    expect(listDescriptors().some((entry) => entry.source === 'slack')).toBe(false);
  });

  it('lists unique sources, so "which sources can we read?" has one answer', () => {
    const sources = listDescriptors().map((entry) => entry.source);
    expect(sources).toEqual([...new Set(sources)]);
    expect(sources).toContain('gmail');
    for (const source of sources) expect(getDescriptor(source)?.source).toBe(source);
  });

  it('emits a signal whose source equals the descriptor that produced it', () => {
    for (const descriptor of listDescriptors()) {
      const signal = descriptor.mapItem(RAW, 'account-1');
      expect(signal?.source).toBe(descriptor.source);
    }
  });

  it('cannot be mutated through listDescriptors()', () => {
    const listed = listDescriptors();
    expect(() => (listed as typeof gmailSignalDescriptor[]).push(gmailSignalDescriptor)).toThrow();
    expect(listDescriptors()).toHaveLength(listed.length);
  });

  describe('gmail descriptor', () => {
    it('builds the pinned calendar-day query and is pure across calls', () => {
      const windowStart = new Date('2026-08-08T17:00:00.000Z');
      const windowEnd = new Date('2026-08-09T17:00:00.000Z');
      const first = gmailSignalDescriptor.buildQuery(windowStart, windowEnd);
      const second = gmailSignalDescriptor.buildQuery(windowStart, windowEnd);
      expect(first).toEqual({ query: 'after:2026/08/08 before:2026/08/10' });
      expect(second).toEqual(first);
      expect(second).not.toBe(first);
      expect(windowStart.toISOString()).toBe('2026-08-08T17:00:00.000Z');
      expect(windowEnd.toISOString()).toBe('2026-08-09T17:00:00.000Z');
    });

    it('maps a raw message onto the channel_signals column set', () => {
      expect(gmailSignalDescriptor.mapItem(RAW, 'account-1')).toEqual({
        source: 'gmail',
        sourceRef: 'account-1:msg-1',
        sender: 'Founder <founder@example.com>',
        summary: 'Launch review — Ship it Friday',
        suggestedTitle: null,
        receivedAt: '2026-08-09T16:30:00.000Z',
      });
    });

    it('accepts ISO 8601 with AND without fractional seconds', () => {
      const withFraction = gmailSignalDescriptor.mapItem({ ...RAW, timestamp: '2026-08-09T16:30:00.250Z' }, 'a');
      const withoutFraction = gmailSignalDescriptor.mapItem({ ...RAW, timestamp: '2026-08-09T16:30:00Z' }, 'a');
      expect(withFraction?.receivedAt).toBe('2026-08-09T16:30:00.250Z');
      expect(withoutFraction?.receivedAt).toBe('2026-08-09T16:30:00.000Z');
    });

    it('returns null — the drop signal — for an unusable raw item', () => {
      expect(gmailSignalDescriptor.mapItem(null, 'a')).toBeNull();
      expect(gmailSignalDescriptor.mapItem('not-an-object', 'a')).toBeNull();
      expect(gmailSignalDescriptor.mapItem({ ...RAW, providerMessageId: '   ' }, 'a')).toBeNull();
      expect(gmailSignalDescriptor.mapItem({ ...RAW, timestamp: 'yesterday' }, 'a')).toBeNull();
      expect(gmailSignalDescriptor.mapItem({ ...RAW, timestamp: undefined }, 'a')).toBeNull();
    });

    it('projects the Daily Brief row with account-qualified identity, and drops what mapItem drops', () => {
      const signal = gmailSignalDescriptor.mapItem(RAW, 'account-1')!;
      expect(gmailSignalDescriptor.toBriefItem(RAW, signal)).toEqual({
        stableId: 'gmail:account-1:msg-1',
        providerMessageId: 'msg-1',
        providerThreadId: 'thread-1',
        sender: 'Founder <founder@example.com>',
        subject: 'Launch review',
        snippet: 'Ship it Friday',
        timestamp: '2026-08-09T16:30:00.000Z',
      });
      expect(gmailSignalDescriptor.toBriefItem({ ...RAW, timestamp: 'yesterday' }, signal)).toBeNull();
    });

    it('strips control characters and truncates over-long provider text', () => {
      const signal = gmailSignalDescriptor.mapItem({
        ...RAW,
        subject: `Launch${String.fromCharCode(0)}${String.fromCharCode(31)}review`,
        snippet: 'x'.repeat(2_000),
      }, 'a')!;
      const item = gmailSignalDescriptor.toBriefItem({
        ...RAW,
        subject: `Launch${String.fromCharCode(0)}${String.fromCharCode(31)}review`,
        snippet: 'x'.repeat(2_000),
      }, signal)!;
      expect(item.subject).toBe('Launch review');
      expect(item.snippet).toHaveLength(1_000);
      expect(item.snippet.endsWith('…')).toBe(true);
    });
  });
});

describe('the pinned action version is un-floatable', () => {
  /**
   * REGRESSION. `Object.freeze([gmailSignalDescriptor])` froze the ARRAY only. `listDescriptors()`
   * and `getDescriptor()` hand out live SINGLETONS, so any consumer could assign
   * `descriptor.actionVersion = '20260801_00'` and float the pinned version for the whole process
   * — silently, for every later caller, including the Daily Brief. A version a caller can reassign
   * is not pinned, and pinning it is the reason this module exists.
   */
  it('deep-freezes every descriptor the registry hands out', () => {
    for (const descriptor of listDescriptors()) {
      expect(Object.isFrozen(descriptor)).toBe(true);
    }
  });

  it('silently ignores (non-strict) and refuses (strict) a write to actionVersion', () => {
    const descriptor = getDescriptor('gmail')!;
    const pinned = descriptor.actionVersion;
    expect(() => {
      'use strict';
      (descriptor as { actionVersion: string }).actionVersion = '20990101_00';
    }).toThrow(TypeError);
    expect(descriptor.actionVersion).toBe(pinned);
  });

  it('refuses to add or delete a field', () => {
    const descriptor = getDescriptor('gmail')!;
    expect(() => {
      'use strict';
      (descriptor as unknown as Record<string, unknown>).sneaky = true;
    }).toThrow(TypeError);
    expect(() => {
      'use strict';
      delete (descriptor as unknown as Record<string, unknown>).toolkitSlug;
    }).toThrow(TypeError);
    expect(descriptor.toolkitSlug).toBe('gmail');
  });

  it('freezes the SAME object the array exposes — no defensive copy hiding the mutation', () => {
    expect(getDescriptor('gmail')).toBe(listDescriptors().find((d) => d.source === 'gmail'));
  });
});

describe('parseIsoInstant is an ISO-8601 parse, not new Date()', () => {
  /**
   * REGRESSION. The body was `new Date(value)` under a docblock promising only the
   * fractional/non-fractional tolerance. It kept that promise and ALSO accepted everything the
   * Date constructor's implementation-defined fallback accepts — including offset-less local
   * times, whose instant depends on the server's timezone. This parser decides which window a
   * provider timestamp falls into; a value the spec gives no meaning must be a DROP, not a guess
   * that differs between deploy regions.
   */
  it('still accepts BOTH fractional and non-fractional seconds (the standing gotcha)', () => {
    expect(parseIsoInstant('2026-02-15T01:00:00Z')?.toISOString()).toBe('2026-02-15T01:00:00.000Z');
    expect(parseIsoInstant('2026-02-15T01:00:00.123Z')?.toISOString())
      .toBe('2026-02-15T01:00:00.123Z');
  });

  it('rejects the implementation-defined shapes bare new Date() would have taken', () => {
    // Each of these produces a VALID Date from `new Date(...)` in V8.
    for (const value of ['Dec 25, 2026', 'Fri Aug 08 2026', '2026', '2026-02-15T01:00:00']) {
      expect(new Number(new Date(value).getTime()).valueOf(), `${value} should parse via new Date`)
        .not.toBeNaN();
      expect(parseIsoInstant(value), `${value} must be dropped`).toBeNull();
    }
  });

  it('rejects a non-string without throwing', () => {
    expect(parseIsoInstant(undefined)).toBeNull();
    expect(parseIsoInstant(null)).toBeNull();
    expect(parseIsoInstant(1_760_000_000_000)).toBeNull();
  });

  it('rejects an impossible calendar date instead of rolling it over', () => {
    expect(parseIsoInstant('2026-02-30T01:00:00Z')).toBeNull();
    expect(parseIsoInstant('2026-13-01T01:00:00Z')).toBeNull();
  });

  it('keeps a valid instant whose offset crosses the written date', () => {
    expect(parseIsoInstant('2026-02-15T01:00:00+05:00')?.toISOString())
      .toBe('2026-02-14T20:00:00.000Z');
  });
});

/**
 * The epoch shapes. Every assertion here is on the RESULTING INSTANT, never on "it parsed" —
 * a non-null check passes just as happily when the value is 1000× off, and a wrong instant still
 * WRITES a row. That is strictly worse than the rejection this replaces.
 */
describe('parseConnectorInstant — epoch numbers, and the seconds-vs-millis rule', () => {
  /**
   * THE DEFECT. Slack's `ts` is epoch seconds with microseconds, as a string — Composio's own
   * output schema documents it as `0123456789.012345`. The ISO-only parser refuses it, so 100% of
   * a Slack collection would drop: `fetched=N dropped=N ingested=0`, exit 0, zero rows, green cron.
   */
  it('parses a Slack-shaped `ts` to the exact instant the ISO-only parser threw away', () => {
    expect(parseIsoInstant('1786620600.123456'), 'the shape that used to drop 100%').toBeNull();
    expect(parseConnectorInstant('1786620600.123456')?.toISOString())
      .toBe('2026-08-13T11:30:00.123Z');
  });

  /**
   * THE 1000× CHECK. Two strings, two units, ONE instant. If the unit rule inverted, one of these
   * lands in 1970 and the other around the year 58000 — and both are still non-null, so only an
   * assertion on the value itself can see it.
   */
  it('reads seconds as seconds and milliseconds as milliseconds — same instant from both', () => {
    const seconds = parseConnectorInstant('1786620600');
    const millis = parseConnectorInstant('1786620600000');
    expect(seconds?.toISOString()).toBe('2026-08-13T11:30:00.000Z');
    expect(millis?.toISOString()).toBe('2026-08-13T11:30:00.000Z');
    expect(seconds?.getTime()).toBe(millis?.getTime());
  });

  /**
   * BOTH SIDES OF THE BOUNDARY. 1e11 is the split. One below it is the largest value read as
   * seconds; 1e11 itself is the smallest read as milliseconds. The two land 3165 years apart,
   * which is the point: nothing a connector can send falls in between, so the guess is never wrong
   * for real data.
   */
  it('splits at 1e11 — the value just below reads as seconds, the value itself as millis', () => {
    expect(parseConnectorInstant('99999999999')?.toISOString()).toBe('5138-11-16T09:46:39.000Z');
    expect(parseConnectorInstant('100000000000')?.toISOString()).toBe('1973-03-03T09:46:40.000Z');
  });

  it('refuses a number too small to be an epoch, so a bare year is never read as a timestamp', () => {
    // The ISO-only parser's own must-drop corpus contains '2026'. Widening the parser must not
    // quietly turn it into 1970-01-01T00:33:46Z.
    expect(parseConnectorInstant('2026')).toBeNull();
    expect(parseConnectorInstant('999999999'), '1e9 - 1').toBeNull();
    expect(parseConnectorInstant('1000000000')?.toISOString(), '1e9')
      .toBe('2001-09-09T01:46:40.000Z');
  });

  it('refuses a number past the top of the band rather than dating a signal in the year 58000', () => {
    expect(parseConnectorInstant('99999999999999')?.toISOString(), '1e14 - 1')
      .toBe('5138-11-16T09:46:39.999Z');
    expect(parseConnectorInstant('100000000000000'), '1e14').toBeNull();
  });

  it('refuses numeric-ish shapes that are not a plain epoch count', () => {
    for (const value of [
      '-1786620600',      // signed
      '1786620600.',      // trailing separator, no fraction
      '.1786620600',      // no whole part
      '1.786e9',          // exponent
      '1_786_620_600',    // separators
      '1786620600,123',   // comma decimal
      '',
      '   ',
    ]) {
      expect(parseConnectorInstant(value), `${JSON.stringify(value)} must be dropped`).toBeNull();
    }
    // Still string-only. A raw JS millisecond number is an already-parsed value, not wire data.
    expect(parseConnectorInstant(1_786_620_600_000)).toBeNull();
    expect(parseConnectorInstant(null)).toBeNull();
  });

  it('does not regress ISO 8601 — the standing both-forms gotcha, and offsets', () => {
    expect(parseConnectorInstant('2026-02-15T01:00:00Z')?.toISOString())
      .toBe('2026-02-15T01:00:00.000Z');
    expect(parseConnectorInstant('2026-02-15T01:00:00.123Z')?.toISOString())
      .toBe('2026-02-15T01:00:00.123Z');
    expect(parseConnectorInstant('2026-02-15T01:00:00+05:00')?.toISOString())
      .toBe('2026-02-14T20:00:00.000Z');
    // And still refuses everything bare `new Date()` would have guessed at.
    for (const value of ['Dec 25, 2026', 'Fri Aug 08 2026', '2026-02-15T01:00:00', '2026-02-30T01:00:00Z']) {
      expect(parseConnectorInstant(value), `${value} must be dropped`).toBeNull();
    }
  });

  /**
   * The descriptor layer is where a provider item's timestamp is actually read, so the widening
   * has to reach it — a parser that accepts Slack's shape while `mapItem` still drops it fixes
   * nothing. Gmail's descriptor stands in for "a descriptor", since it is the only one registered.
   */
  it('reaches the descriptor: mapItem keeps an item whose timestamp is an epoch number', () => {
    const signal = gmailSignalDescriptor.mapItem(
      { ...RAW, timestamp: '1786620600.123456' },
      'acct-1',
    );
    expect(signal, 'an epoch timestamp must not drop the item').not.toBeNull();
    expect(signal!.receivedAt).toBe('2026-08-13T11:30:00.123Z');
  });
});
