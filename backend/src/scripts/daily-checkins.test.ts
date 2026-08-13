import { describe, expect, it, vi } from 'vitest';

// Importing the script pulls in db/pool.js (read at module load) via the service/brief
// imports. Mock the pool so the pure due-filter + push-builder functions are importable
// without a database/env. The script's main() is guarded behind an import.meta check and
// never runs under test.
const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

import {
  isCheckinDue,
  selectDueCheckins,
  buildCheckinPush,
  canNotifyForAuthoringResult,
  deliverCheckin,
  sendBriefPushMonotonically,
  CHECKIN_DEEP_LINK,
  CHECKIN_AUTHORING_SLOTS,
  CHECKIN_MAX_DELIVERY_ATTEMPTS,
  CHECKIN_NOTIFICATION_THREAD,
} from './daily-checkins.js';
import type { CheckinSetting, CheckinSettingWithUser } from '../services/checkin.service.js';
import type { DailyBrief } from '../services/brief.service.js';
import type { PushSendResult } from '../services/push.service.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const CHECKIN_ID = 'c1111111-0000-4000-8000-000000000002';

// 2026-06-29 15:00Z is afternoon in every timezone we test against, so a deliveryHour
// of 8 is always "reached" at NOW for the UTC/UTC-leaning cases below.
//
// Since #1285 the retry bound is an ATTEMPT COUNT, not a wall clock, so how late NOW is relative to
// the slot no longer changes whether a failure retries — the first attempt retries whether it lands
// at 08:15 or at 15:00. That is the point of the change and it is why these tests need only one
// `NOW` again.
const NOW = new Date('2026-06-29T15:00:00.000Z');

function checkin(overrides: Partial<CheckinSettingWithUser> = {}): CheckinSettingWithUser {
  return {
    id: CHECKIN_ID,
    userId: USER_ID,
    slot: 'morning',
    enabled: true,
    deliveryHour: 8,
    deliveryMinute: 0,
    timezone: 'UTC',
    lastRunAt: null,
    ...overrides,
  };
}

/**
 * The durable half of the retry bound: an in-memory stand-in for the `user_checkins` row columns
 * `attempt_count` / `attempt_day` / `last_run_at`.
 *
 * It reproduces the BEHAVIOR of the two statements in checkin.service (`recordCheckinAttempt`
 * increments within the same local day and resets to 1 on a day change; `stampCheckinRun` clears
 * the counter), so a test can run many cron ticks and see the budget actually deplete, roll over,
 * and reset. The SQL itself — the `CASE ... IS DISTINCT FROM` that makes this atomic for concurrent
 * workers — is exercised against a real Postgres engine in
 * `src/db/migrations/checkin-attempt-counter.migration.test.ts`.
 *
 * Because the state lives here and not in the deps, a test can hand the SAME store to a freshly
 * built `dependencies()` and that is exactly what a cron restart or redeploy looks like.
 */
function checkinStore(id = CHECKIN_ID) {
  const row = { attemptCount: 0, attemptDay: null as string | null, lastRunAt: null as string | null };
  const recordCheckinAttempt = vi.fn(async (rowId: string, localDay: string) => {
    if (rowId !== id) return null;
    row.attemptCount = row.attemptDay === localDay ? row.attemptCount + 1 : 1;
    row.attemptDay = localDay;
    return row.attemptCount;
  });
  const stampCheckinRun = vi.fn(async (rowId: string, at: Date): Promise<CheckinSetting | null> => {
    if (rowId !== id) return null;
    row.attemptCount = 0;
    row.attemptDay = null;
    row.lastRunAt = at.toISOString();
    return null;
  });
  return { row, recordCheckinAttempt, stampCheckinRun };
}

/**
 * Replay the real Railway cadence — a tick every 15 minutes — re-reading the row each time, exactly
 * as `main()` does. `last_run_at` is what makes a stamped slot stop being due, so feeding the
 * store's stamp back into the row is what lets these tests assert the USER-visible thing: how many
 * briefs got authored and how many pushes got sent over a whole day.
 */
async function runCronDay(
  base: CheckinSettingWithUser,
  deps: any,
  store: ReturnType<typeof checkinStore>,
  fromIso: string,
  untilIso: string,
): Promise<string[]> {
  const outcomes: string[] = [];
  const until = new Date(untilIso).getTime();
  for (let t = new Date(fromIso).getTime(); t <= until; t += 15 * 60_000) {
    const result = await deliverCheckin(
      { ...base, lastRunAt: store.row.lastRunAt },
      new Date(t),
      deps,
    );
    outcomes.push(result.outcome);
  }
  return outcomes;
}

describe('selectDueCheckins — the due-filter loop', () => {
  it('orders multiple overdue slots from oldest to newest regardless of database row order', () => {
    const due = [
      checkin({ id: 'night', slot: 'night' }),
      checkin({ id: 'midday', slot: 'midday' }),
      checkin({ id: 'morning', slot: 'morning' }),
    ];

    expect(selectDueCheckins(due, NOW).map((entry) => entry.slot)).toEqual([
      'morning',
      'midday',
      'night',
    ]);
  });

  it('keeps only check-ins whose local delivery hour is reached and not run today', () => {
    const due = checkin({ id: 'c-due', slot: 'morning', deliveryHour: 8, timezone: 'UTC' });
    const hourNotReached = checkin({
      id: 'c-future',
      slot: 'night',
      deliveryHour: 23, // 23:00 UTC has not been reached at 15:00Z
      timezone: 'UTC',
    });
    const alreadyRanToday = checkin({
      id: 'c-ran',
      slot: 'midday',
      deliveryHour: 8,
      timezone: 'UTC',
      lastRunAt: '2026-06-29T09:00:00.000Z', // same local day as NOW
    });

    const result = selectDueCheckins([due, hourNotReached, alreadyRanToday], NOW);

    expect(result.map((c) => c.id)).toEqual(['c-due']);
  });

  it('skips disabled check-ins even when the hour is reached', () => {
    const on = checkin({ id: 'c-on', enabled: true });
    const off = checkin({ id: 'c-off', enabled: false });

    const result = selectDueCheckins([on, off], NOW);

    expect(result.map((c) => c.id)).toEqual(['c-on']);
  });

  it('keeps fresh authoring authority with the enabled trigger that is actually due', () => {
    const enabledDue = checkin({ id: 'enabled-due', enabled: true, deliveryHour: 8 });
    const enabledFuture = checkin({ id: 'enabled-future', enabled: true, deliveryHour: 23 });
    const disabledDue = checkin({ id: 'disabled-due', enabled: false, deliveryHour: 8 });

    expect(selectDueCheckins([enabledFuture, disabledDue, enabledDue], NOW)).toEqual([enabledDue]);
  });

  it('respects per-user timezone — same local hour, different UTC moment', () => {
    // deliveryHour 8 local. At 15:00Z it is 08:00 in America/Los_Angeles (UTC-7 in June)
    // so LA is due; but in Asia/Tokyo (UTC+9) it is already 00:00 next day — hour 8 not
    // yet reached, so Tokyo is not due.
    const la = checkin({ id: 'c-la', timezone: 'America/Los_Angeles', deliveryHour: 8 });
    const tokyo = checkin({ id: 'c-tokyo', timezone: 'Asia/Tokyo', deliveryHour: 8 });

    const result = selectDueCheckins([la, tokyo], NOW);

    expect(result.map((c) => c.id)).toEqual(['c-la']);
  });

  it('returns an empty list when nothing is due', () => {
    const off = checkin({ id: 'c-off', enabled: false });
    const future = checkin({ id: 'c-future', deliveryHour: 23 });

    expect(selectDueCheckins([off, future], NOW)).toHaveLength(0);
  });
});

describe('isCheckinDue — single-slot resolver', () => {
  it('due once the delivery hour is reached and it has not run today', () => {
    expect(isCheckinDue(checkin({ deliveryHour: 8 }), NOW, null)).toBe(true);
  });

  it('not due before the delivery hour', () => {
    expect(isCheckinDue(checkin({ deliveryHour: 23 }), NOW, null)).toBe(false);
  });

  it('not due again the same local day', () => {
    const ranToday = new Date('2026-06-29T09:00:00.000Z');
    expect(isCheckinDue(checkin({ deliveryHour: 8 }), NOW, ranToday)).toBe(false);
  });

  it('due again on a new local day', () => {
    const ranYesterday = new Date('2026-06-28T09:00:00.000Z');
    expect(isCheckinDue(checkin({ deliveryHour: 8 }), NOW, ranYesterday)).toBe(true);
  });

  it('disabled is never due', () => {
    expect(isCheckinDue(checkin({ enabled: false }), NOW, null)).toBe(false);
  });

  it('honors the delivery minute within the delivery hour', () => {
    // 2026-06-29T08:05:00Z — hour 8 reached, but only 5 minutes past the hour.
    const at0805 = new Date('2026-06-29T08:05:00.000Z');
    // A slot at 8:10 is NOT yet due at 8:05...
    expect(isCheckinDue(checkin({ deliveryHour: 8, deliveryMinute: 10, timezone: 'UTC' }), at0805, null)).toBe(false);
    // ...but a slot at 8:00 IS due at 8:05 (minute already passed).
    expect(isCheckinDue(checkin({ deliveryHour: 8, deliveryMinute: 0, timezone: 'UTC' }), at0805, null)).toBe(true);
  });

  it('is due once the delivery minute is reached', () => {
    const at0810 = new Date('2026-06-29T08:10:00.000Z');
    expect(isCheckinDue(checkin({ deliveryHour: 8, deliveryMinute: 10, timezone: 'UTC' }), at0810, null)).toBe(true);
  });

  it('ignores the delivery minute once past the delivery hour', () => {
    // 09:00Z is a full hour past an 8:59 slot, so the minute no longer gates it.
    const at0900 = new Date('2026-06-29T09:00:00.000Z');
    expect(isCheckinDue(checkin({ deliveryHour: 8, deliveryMinute: 59, timezone: 'UTC' }), at0900, null)).toBe(true);
  });
});

describe('buildCheckinPush — push payload', () => {
  function brief(counts: Partial<DailyBrief['counts']>): DailyBrief {
    return {
      generated_at: NOW.toISOString(),
      window_start: NOW.toISOString(),
      window_end: NOW.toISOString(),
      counts: {
        blocked: 0,
        overdue: 0,
        scheduled_today: 0,
        completed_today: 0,
        total: 0,
        done: 0,
        ...counts,
      },
      blocked: [],
      overdue: [],
      scheduled_today: [],
      completed_today: [],
      markdown: '',
      summary: '',
    };
  }

  const artifact = {
    markdown: 'Saturday morning, and your task list needs attention.',
    summary: 'Two decisions need your attention.',
    headline: null,
    delivered: true,
    source: 'gateway' as const,
    revision: '11111111-1111-4111-8111-111111111111',
    authoredSlot: 'morning' as const,
  };

  it('uses neutral lock-screen copy and deep-links into canonical latest-brief playback', () => {
    const payload = buildCheckinPush('morning', artifact, '2026-06-29', USER_ID);
    expect(payload.title).toMatch(/morning/i);
    expect(payload.body).toBe('Tap to hear what needs your attention.');
    expect(payload.data?.deepLink).toBe(CHECKIN_DEEP_LINK);
    expect(payload.data?.type).toBe('daily_brief');
    expect(payload.data?.accountId).toBe(USER_ID);
    expect(payload.data?.slot).toBe('morning');
    expect(payload.data?.briefDate).toBe('2026-06-29');
    expect(payload.collapseId).toBe(CHECKIN_NOTIFICATION_THREAD);
    expect(payload.threadId).toBe(CHECKIN_NOTIFICATION_THREAD);
  });

  it('uses neutral copy when the delivered artifact has no summary', () => {
    const payload = buildCheckinPush('midday', { ...artifact, summary: null }, '2026-06-29', USER_ID);
    expect(payload.body).toMatch(/hear what needs your attention/i);
  });
});

describe('deliverCheckin — artifact-first notification lifecycle', () => {
  function dependencies(
    overrides: Record<string, unknown> = {},
    store = checkinStore(),
  ) {
    return {
      gatherBrief: vi.fn(async () => ({
        generated_at: NOW.toISOString(),
        window_start: NOW.toISOString(),
        window_end: NOW.toISOString(),
        counts: { blocked: 1, overdue: 0, scheduled_today: 0, completed_today: 0, total: 0, done: 0 },
        blocked: [], overdue: [], scheduled_today: [], completed_today: [],
        markdown: 'deterministic projection', summary: 'deterministic projection',
      })),
      authorBriefForUser: vi.fn(async () => ({ userId: USER_ID, status: 'authored' as const, reason: null })),
      isBriefAuthoringEnabled: vi.fn(() => true),
      readAuthoredBriefDelivery: vi.fn(async () => ({
        markdown: 'Canonical Today message.',
        summary: 'Canonical Today summary.',
        headline: null,
        delivered: true,
        source: 'gateway' as const,
        revision: '11111111-1111-4111-8111-111111111111',
        authoredSlot: 'morning' as const,
      })),
      sendPush: vi.fn(async () => [{ token: 'device', ok: true, status: 200 }]),
      sendBriefPushMonotonically: vi.fn(async (
        _userId: string,
        _briefDate: string,
        _slot: string,
        send: () => Promise<PushSendResult[]>,
      ) => ({ status: 'sent' as const, results: await send() })),
      stampCheckinRun: store.stampCheckinRun,
      recordCheckinAttempt: store.recordCheckinAttempt,
      collectBriefInput: vi.fn(async () => ({
        producer: 'remclaw-backend' as const,
        producerVersion: 'brief-input-v1' as const,
        capturedAt: NOW.toISOString(),
        manifest: [{
          source: 'gmail' as const,
          availability: 'unavailable' as const,
          action: 'GMAIL_FETCH_EMAILS' as const,
          actionVersion: '20260721_00' as const,
          windowStart: new Date(NOW.getTime() - 86_400_000).toISOString(),
          windowEnd: NOW.toISOString(),
          stableIds: [], connectedAccountIds: [], fingerprint: '0'.repeat(64),
          unavailableReason: 'connector_unavailable',
        }],
        gmail: [], fingerprint: '1'.repeat(64),
      })),
      ...overrides,
    };
  }

  it('notifies and stamps only after the canonical Today artifact is delivered', async () => {
    const deps = dependencies();
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 1, artifactDelivered: true, outcome: 'stamped' });
    expect(deps.authorBriefForUser).toHaveBeenCalledWith(
      USER_ID,
      NOW,
      expect.objectContaining({ requestedSlot: 'morning', timezone: 'UTC', collectInput: expect.any(Function) }),
    );
    expect(deps.readAuthoredBriefDelivery).toHaveBeenCalledWith(
      USER_ID,
      '2026-06-29',
      'rem-orchestrator',
    );
    expect(deps.sendPush).toHaveBeenCalledOnce();
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('serializes APNs so an older paused worker cannot send after a newer slot', async () => {
    let latestSlot: 'morning' | 'afternoon' | 'evening' | null = null;
    let latestBriefDate: string | null = null;
    let canonicalSlot: 'morning' | 'afternoon' | 'evening' = 'morning';
    let releaseOlder!: () => void;
    const olderMayContinue = new Promise<void>((resolve) => { releaseOlder = resolve; });
    let markOlderPaused!: () => void;
    const olderPaused = new Promise<void>((resolve) => { markOlderPaused = resolve; });
    const sends: string[] = [];
    let connectionNumber = 0;

    const connect = async () => {
      const connection = connectionNumber++;
      return {
        query: vi.fn(async (sqlValue: unknown, params?: unknown[]) => {
          const sql = String(sqlValue);
          if (sql.includes('INSERT INTO daily_brief_notification_fences') && connection === 0) {
            markOlderPaused();
            await olderMayContinue;
          }
          if (sql.includes('SELECT latest_brief_date::text')) {
            return { rows: [{ latest_brief_date: latestBriefDate, latest_slot: latestSlot }] };
          }
          if (sql.includes('SELECT b.authored_slot')) {
            return { rows: [{ authored_slot: canonicalSlot, delivered: true }] };
          }
          if (sql.includes('UPDATE daily_brief_notification_fences')) {
            latestBriefDate = params?.[1] as string;
            latestSlot = params?.[2] as typeof latestSlot;
          }
          return { rows: [] };
        }),
        release: vi.fn(),
      } as any;
    };

    // This morning worker already read its artifact before entering the durable notification
    // fence, exactly matching the production race that previously allowed a late stale send.
    const older = sendBriefPushMonotonically(
      USER_ID,
      '2026-06-29',
      'morning',
      async () => {
        sends.push('morning');
        return [{ token: 'device', ok: true, status: 200 }];
      },
      connect,
    );
    await olderPaused;

    canonicalSlot = 'afternoon';
    const newer = await sendBriefPushMonotonically(
      USER_ID,
      '2026-06-29',
      'afternoon',
      async () => {
        sends.push('afternoon');
        return [{ token: 'device', ok: true, status: 200 }];
      },
      connect,
    );
    releaseOlder();

    await expect(older).resolves.toEqual({ status: 'superseded', results: [] });
    expect(newer.status).toBe('sent');
    expect(sends).toEqual(['afternoon']);
    expect(latestBriefDate).toBe('2026-06-29');
    expect(latestSlot).toBe('afternoon');
  });

  it('does not send a duplicate after the same slot has durably consumed its push', async () => {
    const send = vi.fn(async () => [{ token: 'device', ok: true, status: 200 }]);
    const client = {
      query: vi.fn(async (sqlValue: unknown) => {
        const sql = String(sqlValue);
        if (sql.includes('SELECT latest_brief_date::text')) {
          return { rows: [{ latest_brief_date: '2026-06-29', latest_slot: 'morning' }] };
        }
        return { rows: [] };
      }),
      release: vi.fn(),
    } as any;

    await expect(sendBriefPushMonotonically(
      USER_ID,
      '2026-06-29',
      'morning',
      send,
      async () => client,
    )).resolves.toEqual({ status: 'superseded', results: [] });
    expect(send).not.toHaveBeenCalled();
  });

  it('does not let a delayed prior-day worker replace the next morning alert', async () => {
    const send = vi.fn(async () => [{ token: 'device', ok: true, status: 200 }]);
    const client = {
      query: vi.fn(async (sqlValue: unknown) => {
        const sql = String(sqlValue);
        if (sql.includes('SELECT latest_brief_date::text')) {
          return { rows: [{ latest_brief_date: '2026-06-30', latest_slot: 'morning' }] };
        }
        return { rows: [] };
      }),
      release: vi.fn(),
    } as any;

    await expect(sendBriefPushMonotonically(
      USER_ID,
      '2026-06-29',
      'evening',
      send,
      async () => client,
    )).resolves.toEqual({ status: 'superseded', results: [] });
    expect(send).not.toHaveBeenCalled();
  });

  it('does not notify or stamp when authoring fails, so the next tick can retry', async () => {
    const deps = dependencies({
      authorBriefForUser: vi.fn(async () => ({
        userId: USER_ID,
        status: 'skipped_gateway' as const,
        reason: 'timeout',
      })),
    });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'retrying' });
    expect(deps.readAuthoredBriefDelivery).not.toHaveBeenCalled();
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).not.toHaveBeenCalled();
  });

  // ─── #1279 / #1285: the retry budget is a COUNT OF ATTEMPTS ───────────────────────────────────
  // Live on staging, a midday slot enabled at 14:52 was still "1 due now" at 15:30 and 15:45 with
  // last_run_at NULL. Every retryable branch left the slot un-stamped, so it re-ran
  // authorBriefForUser every 15 minutes for the rest of the local day — a brand-new brief each
  // tick, burning model quota, and re-notifying whenever a push finally landed.
  //
  // These assert what the USER experiences over a whole day of ticks — how many briefs were
  // authored, whether a push ever landed, whether tomorrow still works — not the counter itself.

  const COLD_GATEWAY = {
    userId: USER_ID,
    status: 'skipped_gateway' as const,
    reason: 'wake_failed', // documented transient: the Fly machine never reported ready
  };

  it('authors at most the attempt budget for a slot that fails all day, not one brief per tick', async () => {
    const store = checkinStore();
    const authorBriefForUser = vi.fn(async () => COLD_GATEWAY);
    const deps = dependencies({ authorBriefForUser }, store);

    // A full local day of the real 15-minute cadence, from the 08:00 slot to midnight: 64 ticks.
    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T23:45:00.000Z',
    );

    expect(outcomes).toHaveLength(64);
    // The bug: 64 brand-new briefs. The fix: five attempts, then the slot is consumed for the day.
    expect(authorBriefForUser).toHaveBeenCalledTimes(CHECKIN_MAX_DELIVERY_ATTEMPTS);
    expect(outcomes.filter((o) => o === 'retrying')).toHaveLength(CHECKIN_MAX_DELIVERY_ATTEMPTS - 1);
    expect(outcomes.filter((o) => o === 'gave_up')).toHaveLength(1);
    // Everything after the give-up is simply not due — no authoring, no push, no notification.
    expect(outcomes.slice(CHECKIN_MAX_DELIVERY_ATTEMPTS)).toEqual(
      Array(64 - CHECKIN_MAX_DELIVERY_ATTEMPTS).fill('not_due'),
    );
    expect(deps.sendPush).not.toHaveBeenCalled();
  });

  it('still delivers the brief when a transient failure clears inside the budget', async () => {
    // The reason the bound is 5 and not 1: a cold gateway that wakes on the third tick must still
    // produce the user's brief, exactly once.
    const store = checkinStore();
    let ticks = 0;
    const authorBriefForUser = vi.fn(async () => {
      ticks += 1;
      return ticks < 3 ? COLD_GATEWAY : { userId: USER_ID, status: 'authored' as const, reason: null };
    });
    const deps = dependencies({ authorBriefForUser }, store);

    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T23:45:00.000Z',
    );

    expect(outcomes.slice(0, 3)).toEqual(['retrying', 'retrying', 'stamped']);
    expect(deps.sendPush).toHaveBeenCalledOnce();
    // And never again for the rest of the day — one brief, one notification.
    expect(outcomes.slice(3).every((o) => o === 'not_due')).toBe(true);
  });

  it('gives the full budget back after a cron outage swallowed the delivery window (#1285)', async () => {
    // THE GAP THE WALL CLOCK COULD NOT CLOSE. rem-cron is down 08:00–09:30 local; the first tick
    // back is 90 minutes past the slot AND past any `updated_at`, so a minutes-since-origin bound
    // consumed the slot on that single tick. An attempt counter cannot: no tick ran, so no attempt
    // was recorded, so the budget is untouched and the user still gets their brief.
    const store = checkinStore();
    let ticks = 0;
    const authorBriefForUser = vi.fn(async () => {
      ticks += 1;
      return ticks < 2 ? COLD_GATEWAY : { userId: USER_ID, status: 'authored' as const, reason: null };
    });
    const deps = dependencies({ authorBriefForUser }, store);

    // First tick after the outage, 90 minutes late, and it fails once.
    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T09:30:00.000Z',
      '2026-06-29T23:45:00.000Z',
    );

    expect(outcomes[0]).toBe('retrying');
    expect(outcomes[1]).toBe('stamped');
    expect(deps.sendPush).toHaveBeenCalledOnce();
  });

  it('does not hand a failing slot a fresh budget when the cron process restarts', async () => {
    // The budget lives in the row, not in the worker. Two `dependencies()` objects here are two
    // process lifetimes (a restart, a redeploy, or the second of two overlapping workers); the
    // store is the row they share.
    const store = checkinStore();
    const authorBriefForUser = vi.fn(async () => COLD_GATEWAY);

    const before = await runCronDay(
      checkin(),
      dependencies({ authorBriefForUser }, store),
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T08:30:00.000Z',
    );
    expect(before).toEqual(['retrying', 'retrying', 'retrying']);

    // Redeploy: brand-new mocks, same row.
    const after = await runCronDay(
      checkin(),
      dependencies({ authorBriefForUser }, store),
      store,
      '2026-06-29T08:45:00.000Z',
      '2026-06-29T23:45:00.000Z',
    );

    expect(after[0]).toBe('retrying'); // attempt 4
    expect(after[1]).toBe('gave_up'); // attempt 5 — the restart bought nothing
    expect(authorBriefForUser).toHaveBeenCalledTimes(CHECKIN_MAX_DELIVERY_ATTEMPTS);
  });

  it("resets the budget on the user's next local day, so tomorrow's brief still arrives", async () => {
    const store = checkinStore();
    let failing = true;
    const authorBriefForUser = vi.fn(async () =>
      (failing ? COLD_GATEWAY : { userId: USER_ID, status: 'authored' as const, reason: null }));
    const deps = dependencies({ authorBriefForUser }, store);

    // Day one burns the whole budget and is consumed.
    await runCronDay(checkin(), deps, store, '2026-06-29T08:00:00.000Z', '2026-06-29T23:45:00.000Z');
    expect(deps.sendPush).not.toHaveBeenCalled();

    // Day two: the gateway is healthy again and the slot delivers normally.
    failing = false;
    const day2 = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-30T08:00:00.000Z',
      '2026-06-30T23:45:00.000Z',
    );
    expect(day2[0]).toBe('stamped');
    expect(deps.sendPush).toHaveBeenCalledOnce();
  });

  it('buckets attempts by the user LOCAL day, so an east-of-UTC slot is freed nine hours early', async () => {
    // Named for what the fixture actually does: it pins ONE timezone (Asia/Tokyo, UTC+9) and rolls
    // the clock across that user's local midnight. It does not change timezone mid-test, and the
    // budget's behaviour when a user's tz changes is NOT covered here.
    //
    // Tokyo at 2026-06-29 23:00Z is already 2026-06-30 locally. A slot that spent its budget on the
    // user's June 29 must be free again the moment their local date rolls — 15:00Z, nine hours
    // before a UTC-day counter would release it. That gap is the whole assertion.
    const store = checkinStore();
    let failing = true;
    const authorBriefForUser = vi.fn(async () =>
      (failing ? COLD_GATEWAY : { userId: USER_ID, status: 'authored' as const, reason: null }));
    const deps = dependencies({ authorBriefForUser }, store);
    const tokyo = checkin({ timezone: 'Asia/Tokyo', deliveryHour: 8 });

    // 2026-06-28T23:00Z is 08:00 on June 29 in Tokyo — burn that local day's budget.
    await runCronDay(tokyo, deps, store, '2026-06-28T23:00:00.000Z', '2026-06-29T00:00:00.000Z');
    expect(store.row.lastRunAt).not.toBeNull();
    expect(deps.sendPush).not.toHaveBeenCalled();

    // 2026-06-29T23:00Z is 08:00 on June 30 in Tokyo: a new local day, a fresh budget.
    failing = false;
    const nextLocalDay = await runCronDay(
      tokyo,
      deps,
      store,
      '2026-06-29T23:00:00.000Z',
      '2026-06-30T00:00:00.000Z',
    );
    expect(nextLocalDay[0]).toBe('stamped');
    expect(deps.sendPush).toHaveBeenCalledOnce();
  });

  it('spends the budget on `no_gateway` too, then gives up', async () => {
    // This previously asserted `no_gateway` was consumed on attempt 1, on the premise that it
    // "will answer identically at 08:15, 08:30 and 08:45". Codex disproved that premise on #1292:
    // a user whose gateway is still PROVISIONING reports `no_gateway` and then succeeds minutes
    // later. The budget is now the single bound — no reason short-circuits it.
    const store = checkinStore();
    const authorBriefForUser = vi.fn(async () => ({
      userId: USER_ID,
      status: 'skipped_gateway' as const,
      reason: 'no_gateway',
    }));
    const deps = dependencies({ authorBriefForUser }, store);

    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T23:45:00.000Z',
    );

    // Bounded, not unbounded: five attempts, then done for the day. #1279 stays fixed.
    expect(outcomes.slice(0, 5)).toEqual([
      'retrying', 'retrying', 'retrying', 'retrying', 'gave_up',
    ]);
    expect(authorBriefForUser).toHaveBeenCalledTimes(5);
    expect(outcomes.slice(5).every((o) => o === 'not_due')).toBe(true);
  });

  it('recovers the brief when the gateway finishes provisioning mid-window', async () => {
    // The case that motivated the change. First-ever check-in fires while deployment is still in
    // flight (~30-100s, or <30s from the warm pool), so the first tick reports `no_gateway`. Under
    // the old permanent classification the user silently lost their first brief forever. Breaking
    // the fix — reinstating the `isPermanentGatewaySkip` short-circuit — turns this red.
    const store = checkinStore();
    let tick = 0;
    const authorBriefForUser = vi.fn(async () => {
      tick += 1;
      return tick === 1
        ? { userId: USER_ID, status: 'skipped_gateway' as const, reason: 'no_gateway' }
        : { userId: USER_ID, status: 'authored' as const, reason: null };
    });
    const deps = dependencies({ authorBriefForUser }, store);

    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T09:00:00.000Z',
    );

    expect(outcomes[0]).toBe('retrying');
    expect(outcomes[1]).toBe('stamped');
    expect(outcomes.slice(2).every((o) => o === 'not_due')).toBe(true);
  });

  it('retries a bare transport `error` within the budget instead of burning the day on attempt 1', async () => {
    // `runAgentTurnOnGateway` returns the BARE reason 'error' for a dropped socket, a rejected
    // `chat.send`, or "gateway connection closed before final" (gateway-agent.service.ts) — a
    // transport blip, not a standing condition. It answers differently 15 minutes later, so it
    // belongs to the retry budget. Classifying it as a hard failure deleted the recovery path for
    // the entire transport class: one dropped WebSocket frame cost the user their whole day's
    // brief, which is the exact opposite of what a retry bound is for (#1285).
    const store = checkinStore();
    let tick = 0;
    const authorBriefForUser = vi.fn(async () => {
      tick += 1;
      return tick < 3
        ? { userId: USER_ID, status: 'skipped_gateway' as const, reason: 'error' }
        : { userId: USER_ID, status: 'authored' as const, reason: null };
    });
    const deps = dependencies({ authorBriefForUser }, store);

    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T09:00:00.000Z',
    );

    // Two blips, then the third tick authors and the user actually gets their brief.
    expect(outcomes.slice(0, 3)).toEqual(['retrying', 'retrying', 'stamped']);
    expect(deps.sendPush).toHaveBeenCalledOnce();
  });

  it('recovers a brief that was authored but whose rollout delivery threw', async () => {
    // `deliverBriefArtifactForRollout` performs TWO `deliverBriefArtifact` writes. A throw between
    // them lands in brief-authoring's catch as `error: …` with the artifact ALREADY committed:
    // authored, undelivered. Consuming the slot there strands it permanently — the user sees
    // nothing, forever, with no error surface anywhere.
    //
    // The next tick is what converges, and only because `claimBriefAuthoring` returning an existing
    // artifact RE-RUNS the rollout delivery before reporting `already_authored_<slot>`
    // (brief-authoring.service.ts). This fixture replays that exact two-tick sequence, so it fails
    // if either half regresses: the classification here, or the re-delivery over there.
    const store = checkinStore();
    let delivered = false;
    let tick = 0;
    const authorBriefForUser = vi.fn(async () => {
      tick += 1;
      if (tick === 1) {
        // Artifact committed by completeBriefArtifact; the rollout delivery then threw.
        return {
          userId: USER_ID,
          status: 'skipped_gateway' as const,
          reason: 'error: delivery write failed',
        };
      }
      delivered = true; // the already-authored path re-delivered it
      return { userId: USER_ID, status: 'skipped_slot' as const, reason: 'already_authored_morning' };
    });
    const readAuthoredBriefDelivery = vi.fn(async () => ({
      markdown: 'Canonical Today message.',
      summary: 'Canonical Today summary.',
      headline: null,
      delivered,
      source: 'gateway' as const,
      revision: '11111111-1111-4111-8111-111111111111',
      authoredSlot: 'morning' as const,
    }));
    const deps = dependencies({ authorBriefForUser, readAuthoredBriefDelivery }, store);

    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T09:00:00.000Z',
    );

    expect(outcomes.slice(0, 2)).toEqual(['retrying', 'stamped']);
    expect(deps.sendPush).toHaveBeenCalledOnce();
  });

  it('reports the true attempt number when a hard failure lands mid-budget', async () => {
    // What an operator reads at 3am. A wall-clock bound could only say "62 minutes late"; the whole
    // reason for the counter is that this line can say which try it was — and it must stay honest
    // when transient failures already spent part of the budget before the hard one arrived.
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    try {
      const store = checkinStore();
      let tick = 0;
      const deps = dependencies({
        authorBriefForUser: vi.fn(async () => {
          tick += 1;
          return tick < 4
            ? COLD_GATEWAY
            : { userId: USER_ID, status: 'skipped_gateway' as const, reason: 'no_gateway' };
        }),
      }, store);

      const outcomes = await runCronDay(
        checkin(),
        deps,
        store,
        '2026-06-29T08:00:00.000Z',
        '2026-06-29T09:00:00.000Z',
      );

      // `no_gateway` on tick 4 is no longer a hard failure (#1292), so the slot spends its full
      // budget and the give-up line reports attempt 5 — still the TRUE count, which is what this
      // test is actually about.
      expect(outcomes).toEqual(['retrying', 'retrying', 'retrying', 'retrying', 'gave_up']);
      expect(warn).toHaveBeenCalledOnce();
      expect(warn.mock.calls[0][0]).toContain('GAVE UP on attempt 5 of 5');
    } finally {
      warn.mockRestore();
    }
  });

  it('spends the full budget on a thrown/transport authoring error, then gives up', async () => {
    // This test previously asserted the OPPOSITE — that `error: …` is consumed on attempt 1 — and
    // that assertion was the #1285 P1 written down as a contract. `connect ECONNREFUSED` is a
    // transport failure: the gateway may well answer 15 minutes later, and the same catch also
    // covers a throw inside `deliverBriefArtifactForRollout`, where giving up strands a brief that
    // was already committed. So it retries on its budget, and the bound is what stops it.
    const store = checkinStore();
    const authorBriefForUser = vi.fn(async () => ({
      userId: USER_ID,
      status: 'skipped_gateway' as const,
      reason: 'error: connect ECONNREFUSED',
    }));
    const deps = dependencies({ authorBriefForUser }, store);

    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T23:45:00.000Z',
    );

    // Four retries, then consumed on the fifth — and never re-authored for the rest of the day.
    expect(outcomes.slice(0, CHECKIN_MAX_DELIVERY_ATTEMPTS)).toEqual([
      'retrying', 'retrying', 'retrying', 'retrying', 'gave_up',
    ]);
    expect(authorBriefForUser).toHaveBeenCalledTimes(CHECKIN_MAX_DELIVERY_ATTEMPTS);
    expect(outcomes.slice(CHECKIN_MAX_DELIVERY_ATTEMPTS).every((o) => o === 'not_due')).toBe(true);
    expect(deps.stampCheckinRun).toHaveBeenCalledTimes(1);
  });

  it('keeps the full budget for every reason the authoring service calls transient', async () => {
    for (const reason of [
      'wake_failed',
      'timeout',
      'empty_text',
      'connector_input_unavailable',
      'connector_model_unavailable',
    ]) {
      const store = checkinStore();
      const deps = dependencies({
        authorBriefForUser: vi.fn(async () => ({
          userId: USER_ID,
          status: 'skipped_gateway' as const,
          reason,
        })),
      }, store);

      const result = await deliverCheckin(checkin(), NOW, deps);
      expect(result, `reason=${reason}`).toEqual({
        pushed: 0,
        artifactDelivered: false,
        outcome: 'retrying',
      });
      expect(deps.stampCheckinRun, `reason=${reason}`).not.toHaveBeenCalled();
    }
  });

  it('bounds the push-only failure path too, since retrying there re-authors (#1279)', async () => {
    // The artifact is already durably delivered here; only the push failed. Retrying regenerates a
    // whole brief, so this branch must be bounded like the others.
    const store = checkinStore();
    const deps = dependencies({
      sendPush: vi.fn(async (): Promise<PushSendResult[]> => [
        { token: 'device', ok: false, status: 500, reason: 'ServiceUnavailable' },
      ]),
    }, store);

    const outcomes = await runCronDay(
      checkin(),
      deps,
      store,
      '2026-06-29T08:00:00.000Z',
      '2026-06-29T23:45:00.000Z',
    );

    expect(outcomes.filter((o) => o === 'retrying')).toHaveLength(CHECKIN_MAX_DELIVERY_ATTEMPTS - 1);
    expect(outcomes.filter((o) => o === 'gave_up')).toHaveLength(1);
    expect(deps.authorBriefForUser).toHaveBeenCalledTimes(CHECKIN_MAX_DELIVERY_ATTEMPTS);
    expect(deps.sendPush).toHaveBeenCalledTimes(CHECKIN_MAX_DELIVERY_ATTEMPTS);
  });

  it('does not stamp a task-empty slot when malformed connector input is unavailable', async () => {
    const deps = dependencies({
      authorBriefForUser: vi.fn(async (_userId: string, _now: Date, options: any) => {
        await options.collectInput();
        return {
          userId: USER_ID,
          status: 'skipped_gateway' as const,
          reason: 'connector_input_unavailable',
        };
      }),
    });
    const result = await deliverCheckin(checkin(), NOW, deps);
    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'retrying' });
    expect(deps.collectBriefInput).toHaveBeenCalledOnce();
    expect(deps.stampCheckinRun).not.toHaveBeenCalled();
    expect(deps.sendPush).not.toHaveBeenCalled();
  });

  it('consumes an intentional empty snapshot without sending a late brief', async () => {
    const deps = dependencies({
      authorBriefForUser: vi.fn(async () => ({
        userId: USER_ID,
        status: 'empty' as const,
        reason: 'no_actionable_items',
      })),
    });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'stamped' });
    expect(deps.readAuthoredBriefDelivery).not.toHaveBeenCalled();
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('does not notify or stamp when the artifact is not visibly delivered', async () => {
    const deps = dependencies({ readAuthoredBriefDelivery: vi.fn(async () => null) });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'retrying' });
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).not.toHaveBeenCalled();
  });

  it('consumes an older trigger rejected by the durable notification fence', async () => {
    const deps = dependencies({
      sendBriefPushMonotonically: vi.fn(async () => ({
        status: 'superseded' as const,
        results: [] as [],
      })),
    });

    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'stamped' });
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('keeps the trigger retryable if the fenced canonical artifact is temporarily unavailable', async () => {
    const deps = dependencies({
      sendBriefPushMonotonically: vi.fn(async () => ({
        status: 'artifact_unavailable' as const,
        results: [] as [],
      })),
    });

    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'retrying' });
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).not.toHaveBeenCalled();
  });

  it('can recover a prior same-slot artifact without authoring a duplicate', async () => {
    const deps = dependencies({
      authorBriefForUser: vi.fn(async () => ({
        userId: USER_ID,
        status: 'skipped_slot' as const,
        reason: 'already_authored_morning',
      })),
    });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result.artifactDelivered).toBe(true);
    expect(deps.sendPush).toHaveBeenCalledOnce();
  });

  it('consumes a retry whose canonical pointer has advanced to a newer slot', async () => {
    const deps = dependencies({
      authorBriefForUser: vi.fn(async () => ({
        userId: USER_ID,
        status: 'skipped_slot' as const,
        reason: 'already_authored_morning',
      })),
      readAuthoredBriefDelivery: vi.fn(async () => ({
        markdown: 'Canonical afternoon prose.',
        summary: 'Afternoon summary.',
        headline: null,
        delivered: true,
        source: 'gateway' as const,
        revision: '22222222-2222-4222-8222-222222222222',
        authoredSlot: 'afternoon' as const,
      })),
    });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'stamped' });
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('consumes an overdue slot rejected by the canonical monotonicity fence', async () => {
    const deps = dependencies({
      authorBriefForUser: vi.fn(async () => ({
        userId: USER_ID,
        status: 'skipped_slot' as const,
        reason: 'superseded_by_afternoon',
      })),
    });

    const result = await deliverCheckin(checkin({ slot: 'morning' }), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'stamped' });
    expect(deps.readAuthoredBriefDelivery).not.toHaveBeenCalled();
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('does not consume the trigger when registered devices all reject the push', async () => {
    const deps = dependencies({
      sendPush: vi.fn(async () => [{ token: 'device', ok: false, status: 503 }]),
    });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: true, outcome: 'retrying' });
    expect(deps.stampCheckinRun).not.toHaveBeenCalled();
  });

  it('does not consume the trigger when APNs provider or topic configuration can be repaired', async () => {
    for (const [status, reason] of [
      [400, 'IdleTimeout'],
      [403, 'ExpiredProviderToken'],
      [400, 'DeviceTokenNotForTopic'],
    ] as const) {
      const deps = dependencies({
        sendPush: vi.fn(async () => [{ token: 'device', ok: false, status, reason }]),
      });
      const result = await deliverCheckin(checkin(), NOW, deps);

      expect(result).toEqual({ pushed: 0, artifactDelivered: true, outcome: 'retrying' });
      expect(deps.stampCheckinRun).not.toHaveBeenCalled();
    }
  });

  it('consumes the trigger when every APNs destination fails terminally', async () => {
    const deps = dependencies({
      sendPush: vi.fn(async () => [{
        token: 'device',
        ok: false,
        status: 400,
        reason: 'BadDeviceToken',
      }]),
    });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: true, outcome: 'stamped' });
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('consumes the trigger when there are no registered devices to notify', async () => {
    const deps = dependencies({ sendPush: vi.fn(async () => []) });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: true, outcome: 'stamped' });
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('consumes an intentionally disabled schedule without sending a false brief', async () => {
    const deps = dependencies({ isBriefAuthoringEnabled: vi.fn(() => false) });
    const result = await deliverCheckin(checkin(), NOW, deps);

    expect(result).toEqual({ pushed: 0, artifactDelivered: false, outcome: 'stamped' });
    expect(deps.authorBriefForUser).not.toHaveBeenCalled();
    expect(deps.collectBriefInput).not.toHaveBeenCalled();
    expect(deps.sendPush).not.toHaveBeenCalled();
    expect(deps.stampCheckinRun).toHaveBeenCalledOnce();
  });

  it('never collects when a direct delivery call is disabled or not due', async () => {
    for (const ineligible of [
      checkin({ enabled: false }),
      checkin({ deliveryHour: 23 }),
      checkin({ lastRunAt: NOW.toISOString() }),
    ]) {
      const deps = dependencies();
      await expect(deliverCheckin(ineligible, NOW, deps)).resolves.toEqual({ pushed: 0, artifactDelivered: false, outcome: 'not_due' });
      expect(deps.collectBriefInput).not.toHaveBeenCalled();
      expect(deps.gatherBrief).not.toHaveBeenCalled();
      expect(deps.authorBriefForUser).not.toHaveBeenCalled();
    }
  });

  it('lets the authoring lease owner collect exactly once', async () => {
    const deps = dependencies({
      authorBriefForUser: vi.fn(async (_userId: string, _now: Date, options: any) => {
        await options.collectInput();
        return { userId: USER_ID, status: 'authored' as const, reason: null };
      }),
    });
    await deliverCheckin(checkin(), NOW, deps);
    expect(deps.collectBriefInput).toHaveBeenCalledOnce();
  });
});

describe('canNotifyForAuthoringResult', () => {
  it('allows only a newly authored or already-authored artifact for this exact slot', () => {
    expect(canNotifyForAuthoringResult({ userId: USER_ID, status: 'authored', reason: null }, 'midday')).toBe(true);
    expect(canNotifyForAuthoringResult({ userId: USER_ID, status: 'skipped_slot', reason: 'already_authored_afternoon' }, 'midday')).toBe(true);
    expect(canNotifyForAuthoringResult({ userId: USER_ID, status: 'skipped_slot', reason: 'already_authored_evening' }, 'night')).toBe(true);
    expect(canNotifyForAuthoringResult({ userId: USER_ID, status: 'skipped_slot', reason: 'already_authored_morning' }, 'midday')).toBe(false);
    expect(canNotifyForAuthoringResult({ userId: USER_ID, status: 'skipped_slot', reason: 'already_authored_midday' }, 'midday')).toBe(false);
    expect(canNotifyForAuthoringResult({ userId: USER_ID, status: 'empty', reason: null }, 'midday')).toBe(false);
  });

  it('maps product check-in names to the structured authoring slots', () => {
    expect(CHECKIN_AUTHORING_SLOTS).toEqual({
      morning: 'morning',
      midday: 'afternoon',
      night: 'evening',
    });
  });
});
