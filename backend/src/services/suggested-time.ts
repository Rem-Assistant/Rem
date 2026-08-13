/**
 * THE SUGGESTED-TIME CONTRACT — how a proposed task's TIME reaches the user's agenda.
 *
 * ── THE MODEL, AS THE FOUNDER SETTLED IT ─────────────────────────────────────────────────────
 * "Timeblocking shouldn't be blocked… it's just no UI. Creation on task IS timeblocking, and AI
 * setting the right time for a created task is timeblocking."
 *
 * So: A TASK'S `start_date` IS THE TIMEBLOCK. There is no separate block entity, no calendar-block
 * table, and nothing here creates one. This module owns exactly one new fact — the time the judge
 * RECOMMENDS for a suggestion — and the rule for when that recommendation is trustworthy enough to
 * use.
 *
 * ── WHY A SEPARATE MODULE ────────────────────────────────────────────────────────────────────
 * The rule has two call sites on opposite sides of a 15-minute cron boundary:
 *
 *   JUDGE TIME  `signal-relevance.service.ts` decides whether to STORE what the model returned.
 *   READ TIME   `suggestions.service.ts` decides whether the stored value is STILL usable when the
 *               user opens the app — which can be days later, by which point "today at 4pm" is a
 *               time in the past.
 *
 * Two copies of a plausibility rule is how the `proposed_status:` regex ended up meaning three
 * different things on three paths (`task-verdict.ts` header). One function, two callers.
 *
 * This file is a LEAF: it imports one strict parser and nothing else. No pool, no gateway, no env.
 * Every rule in it is testable without a database, which is the point.
 *
 * ── PATTERN MIRRORED (principle 1) ───────────────────────────────────────────────────────────
 * `task-verdict.ts` (PR #1327), which is itself mirroring upstream's `heartbeat_respond`
 * normalizer: a TYPED field the model fills, ONE normalizer, enum/range-checked, `null` on
 * anything unrecognised — never a default, never a partial, never a regex over prose. CLAUDE.md
 * principle 5. In particular there is no code path here that reads a time out of the model's
 * sentence; the model fills a named field or we have no time.
 *
 * ── THE ISO TRAP ─────────────────────────────────────────────────────────────────────────────
 * `parseConnectorInstant` (`connector-signals.registry.ts`), NOT `new Date(string)`. It is the
 * repo's one strict reader for an instant that arrived from outside: fractional seconds optional,
 * a UTC OFFSET REQUIRED, and the parsed instant round-tripped through every wall-clock field so
 * `2026-02-30` cannot silently roll into March. `new Date()` accepts all of those and guesses.
 * CLAUDE.md "Common Gotchas → ISO 8601 Date Parsing" is about exactly this class of bug.
 *
 * The model is told to echo back the user's own offset, which the prompt hands it literally. It
 * therefore does no timezone arithmetic. The one residual: a recommendation on the far side of a
 * DST transition inside the horizon lands one hour off, because the offset in effect then differs
 * from the one echoed. That is a one-hour imprecision in a RECOMMENDATION the card displays and
 * the user can change — not a correctness hole, and the label the card shows is computed from the
 * resulting instant, so what the user reads is always what the task will actually be.
 *
 * ── WHAT "IMPLAUSIBLE" MEANS, AND WHY EACH CLAUSE IS THERE ───────────────────────────────────
 * A recommendation is used only if ALL of these hold. Anything else degrades to the pre-existing
 * behaviour (`laterToday`) — never to a fabricated slot.
 *
 *   1. RESOLVES TO AN ABSOLUTE INSTANT. Enforced by `parseConnectorInstant`, and the rule it
 *      enforces is narrower than "is a date": an ISO 8601 value MUST carry an explicit offset, so
 *      a bare `2026-08-14T16:00` is refused rather than read as server-local — its meaning would
 *      otherwise depend on where the process happens to run.
 *
 *      An epoch-number STRING (`"1786620600"`) is also accepted, and that is not a hole in the
 *      offset rule. Epoch is inherently UTC: there is no ambiguity to refuse. The offset
 *      requirement exists to reject a WALL CLOCK with no zone, which is a different shape. The
 *      prompt asks for ISO regardless, so this is tolerance rather than an invitation.
 *   2. STRICTLY IN THE FUTURE. A past instant would create a task that is instantly overdue —
 *      the exact defect `laterToday` was written to avoid (`suggestions.service.ts`). This is the
 *      clause that does the work at READ time: a time judged yesterday is simply stale today.
 *   3. INSIDE THE HORIZON (14 days). Beyond two weeks the model is placing work on a calendar it
 *      cannot see — the schedule context handed to it covers the same 14 days, so a recommendation
 *      past the horizon is by construction uninformed. It is also longer than a signal survives:
 *      dismissals decay at 7 days and the suggestion list is capped at 5 by recency.
 *   4. INSIDE WAKING HOURS (06:00–22:00 LOCAL). Not a taste preference — it is the difference
 *      between a feature and an embarrassment. One tap on Add must never silently file work at
 *      03:00. Judged in the USER'S zone, because that is the only zone in which "4pm" means
 *      anything.
 *
 * Deliberately NOT a clause: "does not collide with an existing event". The judge is TOLD the
 * user's schedule and asked to avoid it, but a collision is a bad recommendation, not an invalid
 * one — and rejecting on overlap would need durations we only partly have. Degrade on nonsense;
 * do not arbitrate taste.
 */

import { parseConnectorInstant } from './connector-signals.registry.js';

/**
 * The only bounds on a recommended time. A model-chosen instant that lands the user's work
 * somewhere must not be able to move outside these without a code change.
 */
export const SUGGESTED_TIME_BOUNDS = {
  /** How far ahead a recommendation may land. Matches the schedule window the judge is shown. */
  horizonDays: 14,
  /** Earliest local hour (inclusive) a task may be scheduled for. */
  earliestLocalHour: 6,
  /** Latest local hour (EXCLUSIVE) — 22 means the last usable slot starts at 21:59. */
  latestLocalHour: 22,
} as const;

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * `YYYY-MM-DD` for an instant as rendered in `timezone`. Local-date identity, so "is this today"
 * is a string comparison rather than millisecond arithmetic that a DST day breaks.
 *
 * Built from `formatToParts` rather than a locale whose format happens to be ISO-shaped, so the
 * result cannot change with the host's locale data. Returns null on an invalid zone — every
 * caller treats that as "cannot judge", which degrades rather than guesses.
 */
export function localDayStamp(date: Date, timezone: string): string | null {
  try {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).formatToParts(date);
    const get = (type: string) => parts.find((part) => part.type === type)?.value;
    const year = get('year');
    const month = get('month');
    const day = get('day');
    if (!year || !month || !day) return null;
    return `${year}-${month}-${day}`;
  } catch {
    return null;
  }
}

/**
 * The local hour (0–23) an instant falls on in `timezone`. `hourCycle: 'h23'` on purpose: the
 * `hour12: false` spelling still renders midnight as "24" under some ICU versions, which would
 * put every midnight recommendation outside the waking-hours window for the wrong reason.
 */
export function localHour(date: Date, timezone: string): number | null {
  try {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hour: '2-digit',
      hourCycle: 'h23',
    }).formatToParts(date);
    const raw = parts.find((part) => part.type === 'hour')?.value;
    if (raw === undefined) return null;
    const hour = Number(raw);
    return Number.isInteger(hour) && hour >= 0 && hour <= 23 ? hour : null;
  } catch {
    return null;
  }
}

/**
 * THE ONE RULE. Both call sites funnel through this, so a time accepted by the judge and a time
 * accepted by the reader cannot diverge in what they allow.
 *
 * `value` is untrusted in both directions: at judge time it is raw model output, at read time it
 * is a database column whose contents were raw model output. It is re-checked on read rather than
 * trusted because clause 2 is time-relative — the same stored value is valid at 09:00 and stale at
 * 17:00, and only the reader knows which.
 *
 * Returns the instant, or `null` meaning "no recommendation" — never a substitute, never a clamp.
 * A clamped time would be OUR guess wearing the model's authority.
 */
export function plausibleSuggestedStart(
  value: unknown,
  now: Date,
  timezone: string,
): Date | null {
  // Accept a Date directly so the read path can hand a `TIMESTAMPTZ` straight through without a
  // round trip back to a string. Anything else must survive the strict parser.
  const parsed = value instanceof Date
    ? (Number.isNaN(value.getTime()) ? null : value)
    : parseConnectorInstant(value);
  if (!parsed) return null;

  // 2. strictly future — a past slot creates an instantly-overdue task.
  if (parsed.getTime() <= now.getTime()) return null;

  // 3. inside the horizon the judge could actually see.
  if (parsed.getTime() > now.getTime() + SUGGESTED_TIME_BOUNDS.horizonDays * DAY_MS) return null;

  // 4. waking hours, in the user's own zone. An unresolvable zone is not an excuse to skip the
  // check — it means we cannot tell what hour this is for them, so we decline the recommendation.
  const hour = localHour(parsed, timezone);
  if (hour === null) return null;
  if (hour < SUGGESTED_TIME_BOUNDS.earliestLocalHour) return null;
  if (hour >= SUGGESTED_TIME_BOUNDS.latestLocalHour) return null;

  return parsed;
}

/** "4:00 PM" in the user's zone. Locale-driven, never a hardcoded `h:mm a`. */
function timeOfDayLabel(date: Date, timezone: string): string {
  try {
    return new Intl.DateTimeFormat('en-US', {
      hour: 'numeric',
      minute: '2-digit',
      timeZone: timezone,
    }).format(date);
  } catch {
    return new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' }).format(date);
  }
}

function weekdayLabel(date: Date, timezone: string): string | null {
  try {
    return new Intl.DateTimeFormat('en-US', { weekday: 'long', timeZone: timezone }).format(date);
  } catch {
    return null;
  }
}

function monthDayLabel(date: Date, timezone: string): string | null {
  try {
    return new Intl.DateTimeFormat('en-US', {
      month: 'short',
      day: 'numeric',
      timeZone: timezone,
    }).format(date);
  } catch {
    return null;
  }
}

/**
 * The string the SUGGESTION CARD shows: "Today 4:00 PM", "Tomorrow 9:30 AM", "Thursday 4:00 PM",
 * "Aug 28, 4:00 PM".
 *
 * ── WHY THE SERVER RENDERS THIS (the "minimum new UI" call) ──────────────────────────────────
 * The card already renders a server-authored `subtitle`, and the calendar suggestion already puts
 * a local time in it (`Standup · 9:00 AM · Calendar`). Prepending the recommended time to that
 * same string means the founder's "a card showing Thursday 4:00 PM" ships with ZERO new SwiftUI —
 * no new label, no new row slot, and no risk to the two source-text contract tests that police
 * `SuggestedTaskRow`'s layout. It is also the only place that knows the user's configured zone
 * without a round trip.
 *
 * Day naming is deliberately relative-then-absolute: "Today"/"Tomorrow" are what a person says
 * about the next 36 hours, a bare weekday is unambiguous inside a week, and past a week a weekday
 * would be ("Thursday" — which one?), so it becomes a date.
 *
 * ⚠️ THE BAND IS COUNTED IN CALENDAR DAYS, NOT IN ELAPSED MILLISECONDS, and the difference is a
 * user-visible bug rather than a nicety. This guard was first written as
 * `date.getTime() - now.getTime() < 7 * DAY_MS`. Whenever the recommended time-of-day is EARLIER
 * than the current time-of-day, a target seven calendar days out is under 7×24h and fell into the
 * weekday branch — printing TODAY'S weekday:
 *
 *     now    2026-08-12T18:00−04:00 (Wednesday evening)
 *     target 2026-08-19T10:00−04:00 (next Wednesday, 6.67 days elapsed)
 *     label  "Wednesday 10:00 AM"   ← reads as today at 10am, which is already past
 *
 * The user reads a time that has been and gone, taps Add, and the task silently lands a week out.
 * `localDayDelta` counts the boundaries actually crossed in the user's zone, so day 7 is day 7 no
 * matter what o'clock it is — and DST cannot bend it, because both stamps are calendar dates.
 */
export function formatSuggestedTimeLabel(date: Date, now: Date, timezone: string): string {
  const time = timeOfDayLabel(date, timezone);
  const today = localDayStamp(now, timezone);
  const target = localDayStamp(date, timezone);
  if (!today || !target) return time;

  const delta = localDayDelta(today, target);
  if (delta === 0) return `Today ${time}`;
  if (delta === 1) return `Tomorrow ${time}`;

  // 2–6 days out, and ONLY there, a bare weekday names exactly one day. At 7 it is the same
  // weekday as today — the worst possible label — and past that it is worse still.
  if (delta !== null && delta >= 2 && delta <= 6) {
    const weekday = weekdayLabel(date, timezone);
    if (weekday) return `${weekday} ${time}`;
  }
  const monthDay = monthDayLabel(date, timezone);
  return monthDay ? `${monthDay}, ${time}` : time;
}

/**
 * Whole calendar days from one `YYYY-MM-DD` stamp to another. Both are parsed as UTC midnights, so
 * the subtraction is exact integer days regardless of either day's real length in the user's zone.
 * `null` when either stamp is malformed — callers then fall back to the absolute date form.
 */
export function localDayDelta(fromStamp: string, toStamp: string): number | null {
  const parse = (stamp: string): number | null => {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(stamp);
    if (!match) return null;
    return Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  };
  const from = parse(fromStamp);
  const to = parse(toStamp);
  if (from === null || to === null) return null;
  return Math.round((to - from) / DAY_MS);
}

/**
 * `2026-08-12T14:32:00+02:00` — an instant rendered as the USER'S local wall clock plus the offset
 * in effect for them at that instant.
 *
 * This is the single value that lets the model do zero timezone arithmetic: it reads the wall
 * clock it needs to reason from and the offset it needs to echo back, from one string. Built with
 * `timeZoneName: 'longOffset'` (`GMT+02:00`) and normalised, rather than assembled from a numeric
 * offset we compute ourselves, so DST is resolved by ICU rather than by us.
 *
 * Returns null on an invalid zone — the caller then omits the time instruction entirely rather
 * than asking for a time relative to a clock it could not state.
 */
export function localIsoWithOffset(date: Date, timezone: string): string | null {
  try {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
      timeZoneName: 'longOffset',
    }).formatToParts(date);
    const get = (type: string) => parts.find((part) => part.type === type)?.value;
    const [year, month, day, hour, minute, second] = [
      get('year'), get('month'), get('day'), get('hour'), get('minute'), get('second'),
    ];
    if (!year || !month || !day || !hour || !minute || !second) return null;
    // `GMT+02:00` → `+02:00`; plain `GMT` (UTC and every zone at offset zero) → `+00:00`.
    const zoneName = get('timeZoneName') ?? '';
    const offset = zoneName === 'GMT' ? '+00:00' : zoneName.replace(/^GMT/, '');
    if (!/^[+-]\d{2}:\d{2}$/.test(offset)) return null;
    return `${year}-${month}-${day}T${hour}:${minute}:${second}${offset}`;
  } catch {
    return null;
  }
}

/**
 * How the judge is told to name a time, and the exact offset to echo.
 *
 * ONE definition so the prompt and `plausibleSuggestedStart` cannot drift into asking for a shape
 * the reader rejects — the drift `TASK_VERDICT_PROMPT` exists to prevent. The bounds are
 * interpolated from `SUGGESTED_TIME_BOUNDS` rather than restated in prose for the same reason:
 * changing a bound cannot leave the prompt describing the old one.
 *
 * `nowLocalIso` carries BOTH the current local wall clock and the offset, so the model's whole job
 * is to pick a wall-clock time and copy the offset it was given. It is never asked to convert
 * zones, which is the arithmetic it would get wrong invisibly.
 */
export function buildSuggestedTimePrompt(
  nowLocalIso: string,
  timezone: string,
  hasSchedule = false,
): string[] {
  const offset = nowLocalIso.slice(-6);
  // Pointing at "THEIR SCHEDULE below" when no such section was written is an instruction about an
  // empty set — the same failure `CONTEXT_PRECEDENCE` is withheld to avoid, and an invitation to
  // hallucinate the commitments it was told to dodge.
  const freeChoice = hasSchedule
    ? '- Otherwise pick a slot that does not collide with anything under THEIR SCHEDULE below, and '
      + 'that suits the work: a quick reply fits a gap, focused work needs a clear stretch.'
    : '- Otherwise pick a slot that suits the work: a quick reply fits a gap, focused work needs a '
      + 'clear stretch. Nothing is on their calendar in this window.';
  return [
    `TIME. This person is in ${JSON.stringify(timezone)} and it is currently ${nowLocalIso} for `
    + 'them. When an item is worth acting on AND you can name a defensible time to do it, add a '
    + '"w" field holding that instant in ISO 8601 — for example '
    + `"2026-08-14T16:00:00${offset}". Copy the offset "${offset}" exactly as given; do NOT `
    + 'convert to UTC and do NOT invent a different offset.',
    `- The time must be in the future, within ${SUGGESTED_TIME_BOUNDS.horizonDays} days, and `
    + `between ${SUGGESTED_TIME_BOUNDS.earliestLocalHour}:00 and `
    + `${SUGGESTED_TIME_BOUNDS.latestLocalHour}:00 local. Anything else is discarded.`,
    '- If the message itself names a time — a meeting, a deadline, a flight — use THAT time (or, '
    + 'for a deadline, a sensible slot before it) rather than choosing freely.',
    freeChoice,
    '- OMIT "w" entirely when you cannot justify a specific time. A wrong time is worse than none '
    + '— the task is simply created for later today instead, which is what happens now.',
  ];
}
