/**
 * checkin.service — CRUD for `user_checkins` (migrations 027 / 032 / 115), the founder's
 * simplified routines model.
 *
 * A check-in is a GLOBAL daily wake time, not a per-task schedule. A user has up to
 * three slots — morning / midday / night — each independently toggleable with its own
 * delivery hour. At each enabled slot's local hour the backend scheduler
 * (src/scripts/daily-checkins.ts) builds the user's Daily Brief (brief.service) over
 * ALL their tasks and fires one push (push.service). There is no per-routine prompt or
 * connector config here: agent instructions live on the tasks themselves and connectors
 * are global. The only schedule is these rows.
 *
 * Mirrors routine-schedule.service.ts / digest.service.ts conventions: raw
 * parameterized SQL via the shared pool, a RETURNING column list, and a row→domain
 * `formatCheckin` projection. The per-user-timezone due-check reuses the already-shipped
 * pure resolver in routine-schedule.ts (isDailyRoutineDue). Pure shaping helpers are
 * exported so they're unit-testable without a database.
 */

import { pool } from '../db/pool.js';

/** The three fixed daily check-in slots, in chronological order. */
export const CHECKIN_SLOTS = ['morning', 'midday', 'night'] as const;
export type CheckinSlot = (typeof CHECKIN_SLOTS)[number];

export const CHECKIN_SLOT_SET: ReadonlySet<string> = new Set(CHECKIN_SLOTS);

/** Default local delivery hour for each slot, applied when a slot is first written. */
export const DEFAULT_CHECKIN_HOURS: Record<CheckinSlot, number> = {
  morning: 8,
  midday: 12,
  night: 20,
};

/** Default local delivery minute — all slots fire top-of-hour unless the user picks a minute. */
export const DEFAULT_CHECKIN_MINUTE = 0;

/** Domain shape for one check-in slot. */
export interface CheckinSetting {
  id: string | null;
  slot: CheckinSlot;
  enabled: boolean;
  deliveryHour: number;
  deliveryMinute: number;
  timezone: string;
  lastRunAt: string | null;
}

/**
 * Columns returned by every check-in query, in CheckinSetting order.
 *
 * Deliberately WITHOUT `attempt_count` / `attempt_day` (migration 115): those are the scheduler's
 * private retry bookkeeping, not settings, and this projection is the literal body of
 * `GET/PUT /api/v1/checkins`. The scheduler never reads them either — the one statement that
 * touches them (`recordCheckinAttempt`) increments and returns the new value atomically.
 */
export const CHECKIN_RETURNING =
  'id, user_id, slot, enabled, delivery_hour, delivery_minute, timezone, last_run_at';

function toIso(value: unknown): string | null {
  if (!value) return null;
  const d = value instanceof Date ? value : new Date(value as string);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export function isCheckinSlot(value: unknown): value is CheckinSlot {
  return typeof value === 'string' && CHECKIN_SLOT_SET.has(value);
}

/** Clamp an arbitrary input to a valid 0–23 hour, falling back to the slot default. */
export function normalizeHour(value: unknown, slot: CheckinSlot): number {
  const n = typeof value === 'number' ? value : Number.parseInt(String(value), 10);
  if (!Number.isInteger(n) || n < 0 || n > 23) return DEFAULT_CHECKIN_HOURS[slot];
  return n;
}

/** Clamp an arbitrary input to a valid 0–59 minute, falling back to :00. */
export function normalizeMinute(value: unknown): number {
  const n = typeof value === 'number' ? value : Number.parseInt(String(value), 10);
  if (!Number.isInteger(n) || n < 0 || n > 59) return DEFAULT_CHECKIN_MINUTE;
  return n;
}

/** Project a user_checkins row into the camelCase domain shape. Pure. */
export function formatCheckin(row: any): CheckinSetting {
  return {
    id: row.id?.toString() ?? null,
    slot: row.slot,
    enabled: Boolean(row.enabled),
    deliveryHour: Number(row.delivery_hour),
    deliveryMinute: Number(row.delivery_minute ?? 0),
    timezone: row.timezone,
    lastRunAt: toIso(row.last_run_at),
  };
}

/**
 * A check-in setting with its owning user id — the row shape the scheduler needs to
 * fan a brief+push out to the right user. Extends the domain CheckinSetting.
 */
export interface CheckinSettingWithUser extends CheckinSetting {
  userId: string;
}

export function formatCheckinWithUser(row: any): CheckinSettingWithUser {
  return { ...formatCheckin(row), userId: row.user_id.toString() };
}

/**
 * The complete three-slot view for a user, filling defaults for any slot the user has
 * never written. Used by the settings GET so the client always renders all three rows
 * (disabled, at their default hour) even on a brand-new account.
 */
export async function getCheckinSettings(
  userId: string,
  fallbackTimezone = 'UTC',
): Promise<CheckinSetting[]> {
  const result = await pool.query(
    `SELECT ${CHECKIN_RETURNING} FROM user_checkins WHERE user_id = $1::uuid`,
    [userId],
  );
  const bySlot = new Map<string, any>(result.rows.map((r) => [r.slot, r]));
  return CHECKIN_SLOTS.map((slot) => {
    const row = bySlot.get(slot);
    if (row) return formatCheckin(row);
    return {
      id: null,
      slot,
      enabled: false,
      deliveryHour: DEFAULT_CHECKIN_HOURS[slot],
      deliveryMinute: DEFAULT_CHECKIN_MINUTE,
      timezone: fallbackTimezone,
      lastRunAt: null,
    };
  });
}

/** Fields a client may set on a single slot. All optional except the slot itself. */
export interface UpsertCheckinInput {
  enabled?: boolean;
  deliveryHour?: number;
  deliveryMinute?: number;
  timezone?: string;
}

/**
 * Create or update one slot for a user (idempotent on the (user_id, slot) unique key).
 * Defaults are applied for an unset hour/timezone on first write; on conflict only the
 * provided fields change. Returns the stored row.
 */
export async function upsertCheckin(
  userId: string,
  slot: CheckinSlot,
  input: UpsertCheckinInput,
): Promise<CheckinSetting> {
  const enabled = input.enabled ?? false;
  const deliveryHour = normalizeHour(input.deliveryHour, slot);
  const deliveryMinute = normalizeMinute(input.deliveryMinute);
  const timezone = (input.timezone ?? '').trim() || 'UTC';

  const result = await pool.query(
    `INSERT INTO user_checkins (user_id, slot, enabled, delivery_hour, delivery_minute, timezone)
       VALUES ($1::uuid, $2, $3, $4, $5, $6)
     ON CONFLICT (user_id, slot) DO UPDATE
       SET enabled = COALESCE($7, user_checkins.enabled),
           delivery_hour = COALESCE($8, user_checkins.delivery_hour),
           delivery_minute = COALESCE($9, user_checkins.delivery_minute),
           timezone = COALESCE($10, user_checkins.timezone),
           updated_at = NOW()
     RETURNING ${CHECKIN_RETURNING}`,
    [
      userId,
      slot,
      enabled,
      deliveryHour,
      deliveryMinute,
      timezone,
      // COALESCE args: NULL means "leave the existing column" on update.
      input.enabled === undefined ? null : input.enabled,
      input.deliveryHour === undefined ? null : deliveryHour,
      input.deliveryMinute === undefined ? null : deliveryMinute,
      input.timezone === undefined ? null : timezone,
    ],
  );
  return formatCheckin(result.rows[0]);
}

/**
 * All ENABLED check-ins across all users — the scheduler's candidate set. System-scoped
 * (no user JWT); the owning user is carried on each row so the scheduler can fan out.
 */
export async function listEnabledCheckins(): Promise<CheckinSettingWithUser[]> {
  const result = await pool.query(
    `SELECT ${CHECKIN_RETURNING} FROM user_checkins WHERE enabled = TRUE`,
  );
  return result.rows.map(formatCheckinWithUser);
}

/**
 * Record ONE delivery attempt against this slot's local day and return the resulting count
 * (migration 115). System-scoped; the scheduler's only write to the retry bookkeeping.
 *
 * `localDay` is the user's LOCAL calendar date at attempt time (`YYYY-MM-DD`, the same value the
 * brief artifact is keyed on), NOT a UTC date — a slot's budget belongs to the day the user is
 * living in.
 *
 * The day-roll and the increment are ONE statement on purpose. Two overlapping cron workers
 * serialize on the row lock and read back 1 then 2, so no attempt is lost and neither worker resets
 * the other's count. Reading `attempt_day`, comparing in TypeScript, then writing would let both
 * workers see the stale day and both write 1 — a counter permanently stuck at 1, i.e. the unbounded
 * retry loop of #1279 wearing a counter costume. `IS DISTINCT FROM` rather than `<>` so a NULL
 * `attempt_day` is a day change instead of a NULL predicate; on today's data both spellings happen
 * to return 1, so that is intent rather than a fix (see the migration 115 header).
 *
 * Returns `null` when no row matched — the slot was disabled or deleted between the scan and this
 * write. That is not a retry-budget question: a row that no longer exists is never returned by
 * `listEnabledCheckins` again, so it cannot loop.
 */
export async function recordCheckinAttempt(
  id: string,
  localDay: string,
): Promise<number | null> {
  const result = await pool.query<{ attempt_count: number }>(
    `UPDATE user_checkins
        SET attempt_count = CASE
              WHEN attempt_day IS DISTINCT FROM $2::date THEN 1
              ELSE attempt_count + 1
            END,
            attempt_day = $2::date
      WHERE id = $1::uuid
      RETURNING attempt_count`,
    [id, localDay],
  );
  return result.rows.length ? Number(result.rows[0].attempt_count) : null;
}

/**
 * Stamp last_run_at after the scheduler consumes a check-in — on success, on a terminal outcome, or
 * on give-up. System-scoped (called by the scheduler, not a user request), keyed by id alone.
 * Returns the updated row, or null if the slot no longer exists.
 *
 * Clearing the attempt counter here is what makes "consumed" a single fact rather than two that can
 * disagree: after any stamp the invariant is `attempt_count = 0 AND attempt_day IS NULL`, i.e. no
 * attempts outstanding. `attempt_day` is set to NULL rather than to today's local date so this
 * system-scoped stamp does not need a timezone threaded into it; `IS DISTINCT FROM` in
 * `recordCheckinAttempt` treats NULL exactly like a stale day, so tomorrow's first attempt starts
 * at 1 either way.
 */
export async function stampCheckinRun(
  id: string,
  at: Date,
): Promise<CheckinSetting | null> {
  const result = await pool.query(
    `UPDATE user_checkins
        SET last_run_at = $2::timestamptz,
            attempt_count = 0,
            attempt_day = NULL,
            updated_at = NOW()
      WHERE id = $1::uuid
      RETURNING ${CHECKIN_RETURNING}`,
    [id, at.toISOString()],
  );
  return result.rows.length ? formatCheckin(result.rows[0]) : null;
}
