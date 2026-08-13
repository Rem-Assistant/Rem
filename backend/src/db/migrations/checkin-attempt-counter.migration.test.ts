/**
 * Migration 115 + the two statements that own it, against a real Postgres engine (PGlite).
 *
 * The unit tests in `src/scripts/daily-checkins.test.ts` model the counter's behavior in memory so
 * they can replay a whole day of cron ticks. That model is only trustworthy if the actual SQL
 * behaves the way it claims — specifically the `CASE ... attempt_day IS DISTINCT FROM` that has to
 * roll the day and increment in ONE statement, because that single statement is the entire
 * concurrency story. So this file runs `recordCheckinAttempt` / `stampCheckinRun` for real.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// The service talks to `pool.query(text, values)`; PGlite exposes the same shape, so the real
// statements run unmodified rather than being retyped here.
const poolMock = vi.hoisted(() => ({ db: null as any, query: (...args: any[]) => poolMock.db.query(...args) }));
vi.mock('../pool.js', () => ({ pool: poolMock }));

const { recordCheckinAttempt, stampCheckinRun } = await import('../../services/checkin.service.js');

const USER_ID = '11111111-1111-4111-8111-111111111111';
let checkinId: string;

function migration(file: string): string {
  return fs.readFileSync(path.join(__dirname, file), 'utf8');
}

describe('user_checkins attempt counter (migration 115)', () => {
  // PGlite's first cold start (wasm compile + init) can exceed vitest's default 10s hook
  // timeout on a loaded CI box; Codex flagged this on #1292. 60s is generous headroom, and a
  // genuine hang still fails rather than hanging the run.
  beforeAll(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    poolMock.db = new PGlite();
    await poolMock.db.exec('CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())');
    await poolMock.db.query('INSERT INTO users (id) VALUES ($1::uuid)', [USER_ID]);
    await poolMock.db.exec(migration('027_create_user_checkins.sql'));
    await poolMock.db.exec(migration('032_add_delivery_minute_to_user_checkins.sql'));
    // Replayable: the runner records applied files, but every migration is expected to survive a
    // re-run (a first boot after the tracking table was introduced replays everything).
    await poolMock.db.exec(migration('115_add_checkin_attempt_counter.sql'));
    await poolMock.db.exec(migration('115_add_checkin_attempt_counter.sql'));

    const inserted = await poolMock.db.query(
      `INSERT INTO user_checkins (user_id, slot, enabled, delivery_hour, timezone)
       VALUES ($1::uuid, 'morning', TRUE, 8, 'Asia/Tokyo')
       RETURNING id`,
      [USER_ID],
    );
    checkinId = inserted.rows[0].id;
  }, 60_000);
  afterAll(async () => {
    await poolMock.db?.close?.();
  });

  it('starts every existing row at "no attempts outstanding"', async () => {
    const row = await poolMock.db.query(
      'SELECT attempt_count, attempt_day FROM user_checkins WHERE id = $1::uuid',
      [checkinId],
    );
    expect(row.rows[0]).toEqual({ attempt_count: 0, attempt_day: null });
  });

  it('increments within one local day and resets on the day roll — in a single statement', async () => {
    expect(await recordCheckinAttempt(checkinId, '2026-06-29')).toBe(1);
    expect(await recordCheckinAttempt(checkinId, '2026-06-29')).toBe(2);
    expect(await recordCheckinAttempt(checkinId, '2026-06-29')).toBe(3);
    // A new LOCAL day resets rather than continuing — this is what gives the user a fresh budget
    // tomorrow, and what makes a timezone change release a stranded slot.
    expect(await recordCheckinAttempt(checkinId, '2026-06-30')).toBe(1);
    expect(await recordCheckinAttempt(checkinId, '2026-06-30')).toBe(2);
  });

  it('treats a NULL attempt_day as a new streak, independent of the leftover count', async () => {
    // `IS DISTINCT FROM`, not `<>`. On today's data the two are indistinguishable — a NULL
    // attempt_day only ever comes with attempt_count 0, where `<>` yields NULL, falls to the ELSE,
    // and computes 0 + 1 = 1, the same answer. So this is a CONTRACT test, not a live-bug test:
    // the in-memory model the scheduler unit tests replay a whole day against
    // (`attemptDay === localDay ? count + 1 : 1`) assumes NULL means "start at 1" regardless of the
    // count, and this pins the SQL to that. Force the state the two spellings disagree on.
    await poolMock.db.query(
      'UPDATE user_checkins SET attempt_count = 3, attempt_day = NULL WHERE id = $1::uuid',
      [checkinId],
    );
    expect(await recordCheckinAttempt(checkinId, '2026-06-30')).toBe(1);
  });

  it('clears the counter whenever the slot is stamped, so "consumed" is one fact', async () => {
    await recordCheckinAttempt(checkinId, '2026-07-01');
    await recordCheckinAttempt(checkinId, '2026-07-01');
    await stampCheckinRun(checkinId, new Date('2026-07-01T08:45:00.000Z'));

    const row = await poolMock.db.query(
      'SELECT attempt_count, attempt_day, last_run_at FROM user_checkins WHERE id = $1::uuid',
      [checkinId],
    );
    expect(row.rows[0].attempt_count).toBe(0);
    expect(row.rows[0].attempt_day).toBeNull();
    expect(row.rows[0].last_run_at).not.toBeNull();
  });

  it('reports a vanished row instead of inventing a count', async () => {
    const gone = '22222222-2222-4222-8222-222222222222';
    expect(await recordCheckinAttempt(gone, '2026-07-01')).toBeNull();
    expect(await stampCheckinRun(gone, new Date('2026-07-01T08:45:00.000Z'))).toBeNull();
  });

  it('keeps attempt_count non-negative', async () => {
    await expect(poolMock.db.query(
      'UPDATE user_checkins SET attempt_count = -1 WHERE id = $1::uuid',
      [checkinId],
    )).rejects.toThrow();
  });

  it('does not leak the retry bookkeeping into the settings projection', async () => {
    // CHECKIN_RETURNING is the literal body of GET/PUT /api/v1/checkins; the counter is the
    // scheduler's private state, not a user-facing setting.
    const { CHECKIN_RETURNING } = await import('../../services/checkin.service.js');
    expect(CHECKIN_RETURNING).not.toMatch(/attempt_/);
  });
});
