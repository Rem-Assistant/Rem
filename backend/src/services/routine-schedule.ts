/**
 * routine-schedule — pure scheduling logic for routines (the Daily Context
 * Farmer model). No I/O, fully unit-testable. This is the building block a
 * gateway-free scheduler (#788) needs, and it fixes the digest's per-user
 * timezone TODO (today digests use a global UTC-hour heuristic).
 *
 * See docs/rebuild/09-ROUTINES-VISION.md.
 */

export interface DailyRoutineSchedule {
  /** Hour-of-day (0–23) in the user's local timezone when the routine should run. */
  deliveryHour: number;
  /**
   * Minute-of-hour (0–59) in the user's local timezone. Optional; defaults to 0
   * (top-of-hour) so existing hour-only callers keep their exact behavior. Used by
   * check-ins, whose picker holds a specific minute (e.g. 8:10).
   */
  deliveryMinute?: number;
  /** IANA timezone, e.g. "America/Los_Angeles". */
  timezone: string;
  /** When false, the routine is paused and never due. Defaults to true. */
  enabled?: boolean;
}

/** Local Y-M-D + hour + minute for an instant in a given IANA timezone. */
export function localParts(
  at: Date,
  timezone: string,
): { ymd: string; hour: number; minute: number } {
  // en-CA gives ISO-ish YYYY-MM-DD; hour12:false gives 0–23 (00 for midnight).
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  });
  const parts = Object.fromEntries(fmt.formatToParts(at).map((p) => [p.type, p.value]));
  return {
    ymd: `${parts.year}-${parts.month}-${parts.day}`,
    hour: Number.parseInt(parts.hour === '24' ? '0' : parts.hour, 10),
    minute: Number.parseInt(parts.minute, 10),
  };
}

/**
 * Is a daily routine due now? Due when, in the user's timezone:
 *   (1) the routine is enabled,
 *   (2) the current local time has reached deliveryHour:deliveryMinute, and
 *   (3) it has not already run today (no run with the same local date).
 *
 * When `deliveryMinute` is omitted the check is hour-granular (minute 0), preserving
 * the original behavior for routine callers. Check-ins pass a minute so a slot at 8:10
 * fires at or after 8:10 local, not at 8:00.
 *
 * Pure — pass `now` and `lastRunAt` explicitly so it's deterministic in tests.
 */
export function isDailyRoutineDue(
  schedule: DailyRoutineSchedule,
  now: Date,
  lastRunAt: Date | null,
): boolean {
  if (schedule.enabled === false) return false;
  if (!Number.isInteger(schedule.deliveryHour) || schedule.deliveryHour < 0 || schedule.deliveryHour > 23) {
    return false;
  }

  const deliveryMinute =
    Number.isInteger(schedule.deliveryMinute) &&
    (schedule.deliveryMinute as number) >= 0 &&
    (schedule.deliveryMinute as number) <= 59
      ? (schedule.deliveryMinute as number)
      : 0;

  const nowLocal = localParts(now, schedule.timezone);
  if (nowLocal.hour < schedule.deliveryHour) return false;
  // Same hour: not due until the local minute has reached the delivery minute.
  if (nowLocal.hour === schedule.deliveryHour && nowLocal.minute < deliveryMinute) {
    return false;
  }

  if (lastRunAt) {
    const lastLocal = localParts(lastRunAt, schedule.timezone);
    if (lastLocal.ymd === nowLocal.ymd) return false; // already ran today (local)
  }
  return true;
}
