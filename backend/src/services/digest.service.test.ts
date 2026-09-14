import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

// The Rem-owned runtime a digest may use. Mocked so these tests exercise the product boundary
// without reaching provider I/O or the runtime's PostgreSQL run ledger.
const runAgentTurnMock = vi.hoisted(() => vi.fn());
vi.mock('../runtime/agent-runtime.service.js', () => ({
  runAgentTurnOnSharedRuntime: runAgentTurnMock,
}));

import {
  buildDigestUserPrompt,
  dayWindow,
  dayWindowInTimezone,
  monthWindow,
  monthWindowInTimezone,
  defaultKindForDate,
  gatherDigestContext,
  generateDigest,
  isContextEmpty,
  renderFallbackBody,
  type DigestContext,
} from './digest.service.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const NOON = new Date('2026-06-26T12:00:00.000Z');

function ctx(partial: Partial<DigestContext>): DigestContext {
  return {
    kind: 'morning_brief',
    windowStart: '2026-06-26T00:00:00.000Z',
    windowEnd: '2026-06-27T00:00:00.000Z',
    events: [],
    openTasks: [],
    completedToday: [],
    recentComments: [],
    ...partial,
  };
}

describe('digest pure helpers', () => {
  it('defaultKindForDate splits on UTC noon', () => {
    expect(defaultKindForDate(new Date('2026-06-26T08:00:00Z'))).toBe('morning_brief');
    expect(defaultKindForDate(new Date('2026-06-26T18:00:00Z'))).toBe('evening_recap');
  });

  it('dayWindow returns a 24h UTC window containing now', () => {
    const { start, end } = dayWindow(NOON);
    expect(start.toISOString()).toBe('2026-06-26T00:00:00.000Z');
    expect(end.toISOString()).toBe('2026-06-27T00:00:00.000Z');
  });

  it('dayWindowInTimezone bounds the LOCAL calendar day (matching localBriefDate), not the UTC day', () => {
    // 8pm Sunday Pacific: instant is 2026-07-05T03:00Z (already the 5th in UTC), but the user's
    // LOCAL day is Saturday July 4. The window must be [Jul 4 00:00 PT, Jul 5 00:00 PT) so the
    // brief's buckets describe the SAME day the card is dated (bug 1). PT is UTC-7 in July (DST).
    const sundayEvening = new Date('2026-07-05T03:00:00.000Z');
    const { start, end } = dayWindowInTimezone(sundayEvening, 'America/Los_Angeles');
    expect(start.toISOString()).toBe('2026-07-04T07:00:00.000Z'); // Jul 4 00:00 PT
    expect(end.toISOString()).toBe('2026-07-05T07:00:00.000Z'); // Jul 5 00:00 PT
    // The instant sits inside the local window (proves buckets and date agree).
    expect(sundayEvening.getTime()).toBeGreaterThanOrEqual(start.getTime());
    expect(sundayEvening.getTime()).toBeLessThan(end.getTime());
    // ...whereas the UTC window would have wrongly rolled to Jul 5.
    expect(dayWindow(sundayEvening).start.toISOString()).toBe('2026-07-05T00:00:00.000Z');
  });

  it('dayWindowInTimezone is DST-transition-correct: LA spring-forward day is a 23h local window', () => {
    // 2026-03-08 is US spring-forward: 02:00 PST (UTC-8) jumps to 03:00 PDT (UTC-7) at
    // 2026-03-08T10:00Z. `now` is that afternoon (PDT). The LOCAL day runs from Mar 8 00:00
    // PST (08:00Z) to Mar 9 00:00 PDT (07:00Z next day) — the two boundaries use DIFFERENT
    // offsets. Reading the offset only at `now` (the old bug) would have skewed the start.
    const springForwardAfternoon = new Date('2026-03-08T20:00:00.000Z'); // 12:00 PDT
    const { start, end } = dayWindowInTimezone(springForwardAfternoon, 'America/Los_Angeles');
    expect(start.toISOString()).toBe('2026-03-08T08:00:00.000Z'); // Mar 8 00:00 PST (UTC-8)
    expect(end.toISOString()).toBe('2026-03-09T07:00:00.000Z'); // Mar 9 00:00 PDT (UTC-7)
    // The local day is only 23 hours on the spring-forward date.
    expect(end.getTime() - start.getTime()).toBe(23 * 60 * 60 * 1000);
    // `now` sits inside the window (buckets and the local date agree even across the jump).
    expect(springForwardAfternoon.getTime()).toBeGreaterThanOrEqual(start.getTime());
    expect(springForwardAfternoon.getTime()).toBeLessThan(end.getTime());
  });

  it('dayWindowInTimezone handles a zone ahead of UTC (Tokyo) and falls back to UTC on a bad zone', () => {
    // 2026-06-26T18:00Z is already 2026-06-27 03:00 in Tokyo (UTC+9) → local day is the 27th.
    const evening = new Date('2026-06-26T18:00:00.000Z');
    const { start, end } = dayWindowInTimezone(evening, 'Asia/Tokyo');
    expect(start.toISOString()).toBe('2026-06-26T15:00:00.000Z'); // Jun 27 00:00 JST
    expect(end.toISOString()).toBe('2026-06-27T15:00:00.000Z');
    // Unknown/garbage zone → the safe UTC window (never throws).
    const utc = dayWindowInTimezone(NOON, 'Not/AZone');
    expect(utc.start.toISOString()).toBe('2026-06-26T00:00:00.000Z');
    expect(utc.end.toISOString()).toBe('2026-06-27T00:00:00.000Z');
  });

  it('monthWindow returns the UTC calendar month containing now', () => {
    const { start, end } = monthWindow(NOON);
    expect(start.toISOString()).toBe('2026-06-01T00:00:00.000Z');
    expect(end.toISOString()).toBe('2026-07-01T00:00:00.000Z');
  });

  it('monthWindowInTimezone bounds the LOCAL calendar month, not the UTC one', () => {
    // 2026-08-31 18:00 PDT is already 2026-09-01 in UTC — the user is still in August.
    const lastEveningOfAugust = new Date('2026-09-01T01:00:00.000Z');
    const { start, end } = monthWindowInTimezone(lastEveningOfAugust, 'America/Los_Angeles');
    expect(start.toISOString()).toBe('2026-08-01T07:00:00.000Z'); // Aug 1 00:00 PDT
    expect(end.toISOString()).toBe('2026-09-01T07:00:00.000Z'); // Sep 1 00:00 PDT
    expect(lastEveningOfAugust.getTime()).toBeGreaterThanOrEqual(start.getTime());
    expect(lastEveningOfAugust.getTime()).toBeLessThan(end.getTime());
    // ...whereas the UTC window would already have rolled to September.
    expect(monthWindow(lastEveningOfAugust).start.toISOString()).toBe('2026-09-01T00:00:00.000Z');
  });

  it('monthWindowInTimezone rolls EARLY for a zone ahead of UTC (Tokyo)', () => {
    // 2026-09-01 08:30 JST is still 2026-08-31 in UTC — the user is already in September.
    const firstMorningOfSeptember = new Date('2026-08-31T23:30:00.000Z');
    const { start, end } = monthWindowInTimezone(firstMorningOfSeptember, 'Asia/Tokyo');
    expect(start.toISOString()).toBe('2026-08-31T15:00:00.000Z'); // Sep 1 00:00 JST
    expect(end.toISOString()).toBe('2026-09-30T15:00:00.000Z'); // Oct 1 00:00 JST
    expect(monthWindow(firstMorningOfSeptember).start.toISOString()).toBe('2026-08-01T00:00:00.000Z');
  });

  it('monthWindowInTimezone uses the offset AT each boundary, not the one at `now`', () => {
    // March 2026 in LA straddles spring-forward (Mar 8). `now` is PDT (UTC-7) but the month
    // began in PST (UTC-8). Seeding the guess from `now`'s offset alone would be an hour off.
    const midMarch = new Date('2026-03-20T19:00:00.000Z'); // 12:00 PDT
    const { start, end } = monthWindowInTimezone(midMarch, 'America/Los_Angeles');
    expect(start.toISOString()).toBe('2026-03-01T08:00:00.000Z'); // Mar 1 00:00 PST
    expect(end.toISOString()).toBe('2026-04-01T07:00:00.000Z'); // Apr 1 00:00 PDT
    // The month is one hour short of 31 local days because of the jump.
    expect(end.getTime() - start.getTime()).toBe((31 * 24 - 1) * 60 * 60 * 1000);
  });

  it('monthWindowInTimezone crosses the year boundary and falls back to UTC on a bad zone', () => {
    // 2027-01-01 09:00 JST is 2026-12-31 in UTC — December for UTC, January for the user.
    const newYearMorning = new Date('2026-12-31T15:30:00.000Z');
    const { start, end } = monthWindowInTimezone(newYearMorning, 'Asia/Tokyo');
    expect(start.toISOString()).toBe('2026-12-31T15:00:00.000Z'); // Jan 1 2027 00:00 JST
    expect(end.toISOString()).toBe('2027-01-31T15:00:00.000Z'); // Feb 1 2027 00:00 JST
    // Unknown/garbage zone → the safe UTC window (never throws).
    const utc = monthWindowInTimezone(NOON, 'Not/AZone');
    expect(utc.start.toISOString()).toBe('2026-06-01T00:00:00.000Z');
    expect(utc.end.toISOString()).toBe('2026-07-01T00:00:00.000Z');
  });

  // A local midnight is not always one instant. `America/Havana` ends DST at 01:00 CDT →
  // 00:00 CST (first Sunday of November) and `Atlantic/Azores` at 01:00 WEST → 00:00 WET
  // (last Sunday of October), so midnight happens TWICE. These are the only two IANA zones
  // that do it. Every consumer of these windows — quota, the daily brief, digests — needs
  // the boundary to be the same instant no matter which side of the rewind it is asked from.
  it('dayWindowInTimezone pins a repeated local midnight to the FIRST of the two instants', () => {
    for (const [zone, firstMidnight, beforeRewind, afterRewind] of [
      ['America/Havana', '2024-11-03T04:00:00.000Z', '2024-11-03T04:30:00.000Z', '2024-11-03T05:30:00.000Z'],
      ['Atlantic/Azores', '2024-10-27T00:00:00.000Z', '2024-10-27T00:30:00.000Z', '2024-10-27T01:30:00.000Z'],
    ] as const) {
      const wall = (iso: string) =>
        new Intl.DateTimeFormat('en-CA', {
          timeZone: zone, dateStyle: 'short', timeStyle: 'medium', hour12: false,
        }).format(new Date(iso));
      // Precondition: the two probes really are the same local wall clock (the ambiguity).
      expect(wall(afterRewind)).toBe(wall(beforeRewind));

      const before = dayWindowInTimezone(new Date(beforeRewind), zone);
      const after = dayWindowInTimezone(new Date(afterRewind), zone);

      expect(before.start.toISOString()).toBe(firstMidnight);
      expect(after.start.toISOString()).toBe(before.start.toISOString());
      expect(after.end.toISOString()).toBe(before.end.toISOString());
      // The local day really is 25 hours long — that is what a fall-back day is.
      expect(before.end.getTime() - before.start.getTime()).toBe(25 * 60 * 60 * 1000);
    }
  });

  it('monthWindowInTimezone never starts a month after `now`', () => {
    // Cuba's fall-back is the first Sunday of November, which IS the 1st in 2020/2026/2037 —
    // so the month opens on a repeated midnight. Anchoring on the LATER instant puts `start`
    // an hour after `now`, and a `created_at >= start` read then matches nothing at all.
    const zone = 'America/Havana';
    for (const nowIso of [
      '2026-11-01T04:00:00.000Z', // 00:00 local, first pass
      '2026-11-01T04:30:00.000Z',
      '2026-11-01T04:59:00.000Z', // last minute before the rewind
    ]) {
      const now = new Date(nowIso);
      const { start, end } = monthWindowInTimezone(now, zone);
      expect(start.getTime()).toBeLessThanOrEqual(now.getTime());
      expect(now.getTime()).toBeLessThan(end.getTime());
      expect(start.toISOString()).toBe('2026-11-01T04:00:00.000Z');
    }
  });

  it('isContextEmpty is kind-aware', () => {
    expect(isContextEmpty(ctx({ kind: 'morning_brief' }))).toBe(true);
    expect(isContextEmpty(ctx({ kind: 'morning_brief', openTasks: [{ title: 'x', status: 'pending', priority: 'high', start_date: null, overdue: false }] }))).toBe(false);
    expect(isContextEmpty(ctx({ kind: 'evening_recap' }))).toBe(true);
    expect(isContextEmpty(ctx({ kind: 'evening_recap', completedToday: ['done'] }))).toBe(false);
  });

  it('buildDigestUserPrompt includes events and tasks for the morning brief', () => {
    const prompt = buildDigestUserPrompt(
      ctx({
        events: [{ title: 'Standup', start_date: '2026-06-26T15:00:00Z', duration_minutes: 30 }],
        openTasks: [{ title: 'Ship digests', status: 'pending', priority: 'high', start_date: null, overdue: true }],
      }),
    );
    expect(prompt).toContain('Standup');
    expect(prompt).toContain('Ship digests');
    expect(prompt).toContain('OVERDUE');
  });

  it('renderFallbackBody summarizes without a model', () => {
    const body = renderFallbackBody(
      ctx({ events: [{ title: 'Standup', start_date: '2026-06-26T15:00:00Z', duration_minutes: 30 }] }),
    );
    expect(body).toContain('Standup');
  });
});

describe('generateDigest resolution order', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    delete process.env.GMI_API_KEY;
    vi.unstubAllGlobals();
    runAgentTurnMock.mockResolvedValue({ ok: false, reason: 'unavailable' });
  });
  afterEach(() => vi.unstubAllGlobals());

  function mockGatherEmpty() {
    poolMock.query.mockResolvedValue({ rows: [] });
  }

  function mockGatherWithOpenTask() {
    // gather runs 4 SELECTs: events, open tasks, completed, comments.
    poolMock.query
      .mockResolvedValueOnce({ rows: [] }) // events
      .mockResolvedValueOnce({
        rows: [{ title: 'Ship digests', status: 'pending', priority: 'high', start_date: null, overdue: false }],
      }) // open tasks
      .mockResolvedValueOnce({ rows: [] }) // completed
      .mockResolvedValueOnce({ rows: [] }); // comments
  }

  it('returns an empty digest without calling GMI when there is nothing to report', async () => {
    process.env.GMI_API_KEY = 'should-not-be-used';
    mockGatherEmpty();
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);

    const d = await generateDigest(USER_ID, 'morning_brief', NOON);

    expect(d.source).toBe('empty');
    expect(d.model).toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('falls back to a local summary when the Rem runtime cannot take the turn', async () => {
    mockGatherWithOpenTask();
    const d = await generateDigest(USER_ID, 'morning_brief', NOON);
    expect(d.source).toBe('fallback');
    expect(d.body).toContain('Ship digests');
  });

  it('does not bypass the Rem runtime with an unmetered direct provider call', async () => {
    process.env.GMI_API_KEY = 'k';
    mockGatherWithOpenTask();
    const fetchSpy = vi.fn(async () => ({
      ok: true,
      json: async () => ({ choices: [{ message: { content: 'You have 1 high-priority task.' } }] }),
    }));
    vi.stubGlobal('fetch', fetchSpy);

    const d = await generateDigest(USER_ID, 'morning_brief', NOON);

    // Not one HTTP request left this process: no chat-completions call was even attempted.
    expect(fetchSpy).not.toHaveBeenCalled();
    // And the user still gets a digest — the deterministic local render, one step sooner.
    expect(d.source).toBe('fallback');
    expect(d.model).toBeNull();
    expect(d.body).toContain('Ship digests');
  });

  it('runs a populated digest through the Rem-owned tool-free runtime contract', async () => {
    process.env.GMI_API_KEY = 'k';
    mockGatherWithOpenTask();
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    runAgentTurnMock.mockResolvedValue({
      ok: true,
      text: 'You have 1 high-priority task.',
      runId: 'r1',
      sessionKey: 'rem-digest',
      model: 'runtime-model',
      provenance: {
        runtimeId: 'rem_shared',
        persistenceKind: 'rem_runtime',
        billingMode: 'rem_managed',
      },
      toolCalls: [],
    });

    const d = await generateDigest(USER_ID, 'morning_brief', NOON);

    expect(d.source).toBe('gmi');
    expect(d.model).toBe('runtime-model');
    expect(d.body).toBe('You have 1 high-priority task.');
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(runAgentTurnMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: USER_ID, authority: 'internal_service' },
      sessionKey: 'rem-digest-morning_brief-20260626',
      idempotencyKey: expect.stringMatching(/^rem-digest:morning_brief:[a-f0-9-]{36}$/),
      toolPolicy: { mode: 'observe', allowedTools: [], approval: 'none' },
    }));
  });

  it('falls back when loading the shared runtime rejects', async () => {
    mockGatherWithOpenTask();
    runAgentTurnMock.mockRejectedValue(new Error('module unavailable'));
    const d = await generateDigest(USER_ID, 'morning_brief', NOON);
    expect(d.source).toBe('fallback');
    expect(d.body).toContain('Ship digests');
  });

  it('gives a later refresh a fresh dispatch after a terminal runtime failure', async () => {
    mockGatherWithOpenTask();
    mockGatherWithOpenTask();
    runAgentTurnMock
      .mockResolvedValueOnce({ ok: false, reason: 'timeout' })
      .mockResolvedValueOnce({
        ok: true,
        text: 'Recovered digest.',
        runId: 'r2',
        sessionKey: 'rem-digest',
        model: 'runtime-model',
        provenance: {
          runtimeId: 'rem_shared',
          persistenceKind: 'rem_runtime',
          billingMode: 'rem_managed',
        },
        toolCalls: [],
      });

    expect((await generateDigest(USER_ID, 'morning_brief', NOON)).source).toBe('fallback');
    expect((await generateDigest(USER_ID, 'morning_brief', NOON)).body).toBe('Recovered digest.');
    const firstKey = runAgentTurnMock.mock.calls[0][0].idempotencyKey;
    const secondKey = runAgentTurnMock.mock.calls[1][0].idempotencyKey;
    expect(secondKey).not.toBe(firstKey);
  });
});

describe('gatherDigestContext day window', () => {
  beforeEach(() => vi.clearAllMocks());

  it('scopes the SQL bounds to the user LOCAL day when a timezone is passed', async () => {
    poolMock.query.mockResolvedValue({ rows: [] });
    // 2026-06-28T04:00Z is Saturday 9pm in Los Angeles (PDT, UTC-7) — still June 27 LOCALLY,
    // though it is already June 28 in UTC. The evening digest must cover the LOCAL June 27
    // day: [June 27 00:00 PDT, June 28 00:00 PDT) = [2026-06-27T07:00Z, 2026-06-28T07:00Z).
    const laEvening = new Date('2026-06-28T04:00:00.000Z');
    const ctxResult = await gatherDigestContext(USER_ID, 'evening_recap', laEvening, 'America/Los_Angeles');

    // The gathered window reflects the LOCAL June 27 day, not the UTC June 28 day.
    expect(ctxResult.windowStart).toBe('2026-06-27T07:00:00.000Z');
    expect(ctxResult.windowEnd).toBe('2026-06-28T07:00:00.000Z');

    // And the actual SQL bounds passed to the events query use those LOCAL-day timestamps.
    const [, params] = poolMock.query.mock.calls[0] as [string, unknown[]];
    expect(params[1]).toBe('2026-06-27T07:00:00.000Z'); // startIso
    expect(params[2]).toBe('2026-06-28T07:00:00.000Z'); // endIso
  });

  it('defaults to the UTC day window when no timezone is passed (backward compatible)', async () => {
    poolMock.query.mockResolvedValue({ rows: [] });
    const ctxResult = await gatherDigestContext(USER_ID, 'morning_brief', NOON);
    expect(ctxResult.windowStart).toBe('2026-06-26T00:00:00.000Z');
    expect(ctxResult.windowEnd).toBe('2026-06-27T00:00:00.000Z');
  });
});
