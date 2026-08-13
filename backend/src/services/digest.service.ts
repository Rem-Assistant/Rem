/**
 * Proactive cloud digests.
 *
 * A digest is a short brief the GMI cloud agent writes for a user on a schedule,
 * without being asked — making the cloud runtime feel proactive instead of only
 * reacting to per-task `agent-run` calls (see task-agent.service.ts).
 *
 *   - morning_brief : today's calendar events + open/overdue tasks → "here's your day"
 *   - evening_recap : what changed today (completed, new comments) + what's still open
 *
 * Source of truth is the same backend Postgres the apps read, so iOS and Mac render
 * the identical digest. See docs/agentbox/DIGESTS.md.
 *
 * Resolution order (never throws past createDigest):
 *   1. Nothing to report → store an 'empty' digest, run no model at all.
 *   2. The user's OWN gateway writes it ('gmi' source, model 'gateway').
 *   3. The gateway could not take the turn → render a deterministic local summary ('fallback').
 *
 * ── THE GMI FALLBACK IS GONE (and this is why) ───────────────────────────────────────────
 * Step 3 used to be "call GMI MaaS directly on the org `GMI_API_KEY`", with the local render
 * only after THAT failed. `task-agent.service.ts` dropped the same fallback in #1327 because
 * one shared org key billed the operator for the user's work; digests kept theirs, filed as a
 * separate decision. It is not a separate decision. BYOK is a GLOBAL per-user mode — a user is
 * on their own key or on Rem's, for everything — so a path that picks the key independently of
 * the user's mode is wrong by construction, not merely expensive.
 *
 * The concrete harm this closed: a user whose runtime is their own (a Mac local gateway, a
 * self-hosted or Railway-deployed one — see `run-block.ts` for how that is established) had
 * their digest run on THEIR key on the happy path, and silently on REM's key the moment their
 * gateway failed to wake. Same feature, same user, two different payers, decided by a
 * transient. That is the "hybrid case by case" the rule forbids, and it was invisible: the
 * stored row said `source='gmi'` either way.
 *
 * What a user loses: nothing they can see. The deterministic local render was always the last
 * resort and is unchanged; a gateway failure now reaches it one step sooner. No user-visible
 * copy changed, and no digest that used to be written is no longer written.
 *
 * Connector data (Calendar/Gmail/Slack/Notion) is intentionally out of scope here:
 * those live on the gateway, not the backend. The gather step is the seam where a
 * future connector snapshot would be merged in — see DIGESTS.md "Extending".
 */

import { pool } from '../db/pool.js';
import { runAgentTurnOnGateway, utcDateStamp } from './gateway-agent.service.js';
import { DEFAULT_BRIEF_TIMEZONE, resolveUserTimezone } from './brief-authoring.service.js';

/** Re-export the timezone default so digest callers can source a single fallback. */
export { DEFAULT_BRIEF_TIMEZONE };

export type DigestKind = 'morning_brief' | 'evening_recap';

export const DIGEST_KINDS: ReadonlySet<string> = new Set<DigestKind>([
  'morning_brief',
  'evening_recap',
]);

export interface DigestEvent {
  title: string;
  start_date: string | null;
  duration_minutes: number | null;
}

export interface DigestTask {
  title: string;
  status: string | null;
  priority: string | null;
  start_date: string | null;
  overdue: boolean;
}

export interface DigestComment {
  author_label: string;
  body: string;
  task_title: string;
}

export interface DigestContext {
  kind: DigestKind;
  /** Inclusive day window the digest covers, in ISO-8601 (UTC). */
  windowStart: string;
  windowEnd: string;
  events: DigestEvent[];
  openTasks: DigestTask[];
  completedToday: string[];
  recentComments: DigestComment[];
}

export interface GeneratedDigest {
  kind: DigestKind;
  title: string;
  body: string;
  source: 'gmi' | 'fallback' | 'empty';
  model: string | null;
}

export interface DigestRow {
  id: string;
  kind: DigestKind;
  title: string;
  body: string;
  source: string;
  model: string | null;
  created_at: string | null;
}

/**
 * Default digest kind for a moment in time. UTC-hour based: before noon UTC →
 * morning_brief, otherwise evening_recap. Per-user timezones are a known follow-up
 * (DIGESTS.md "Scheduling"); the scheduler can also pass an explicit --kind.
 */
export function defaultKindForDate(now: Date): DigestKind {
  return now.getUTCHours() < 12 ? 'morning_brief' : 'evening_recap';
}

const DAY_MS = 24 * 60 * 60 * 1000;

/** [start, end) UTC bounds for the calendar day containing `now`. */
export function dayWindow(now: Date): { start: Date; end: Date } {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const end = new Date(start.getTime() + DAY_MS);
  return { start, end };
}

/**
 * [start, end) absolute-instant bounds for the calendar day containing `now` IN A GIVEN
 * IANA TIMEZONE — i.e. local midnight → next local midnight, returned as UTC `Date`s so
 * the SQL `>= start AND < end` comparisons stay correct.
 *
 * WHY THIS EXISTS: `dayWindow` computes the day in UTC. For a user whose local date differs
 * from UTC (e.g. Pacific at 8pm), a UTC window describes the WRONG calendar day — the brief
 * gets dated their local day (via `localBriefDate`) but its task buckets came from the UTC
 * window, so the card's date and its agenda disagree. Threading the user's tz here makes the
 * bucket boundaries match `localDateStamp`/`localBriefDate`.
 *
 * We derive the boundaries WITHOUT a date library, DST-correctly:
 *   1. Read the target LOCAL CALENDAR DATE from `now` in the zone. The offset used is read
 *      AT `now`, so it is exact and the date is right even mid-transition.
 *   2. Resolve local-MIDNIGHT of that date, and of the NEXT date, each to its true UTC
 *      instant via `localWallClockToUtc`. That helper enumerates the candidate instants and
 *      takes the EARLIEST one that genuinely renders as local midnight — see its own comment
 *      for why one guess-then-correct is not enough: local midnight can happen twice (DST
 *      fall-back onto midnight, `America/Havana`) or not at all (spring-forward onto
 *      midnight, `Asia/Beirut`), and a seed-dependent answer moved the window under us.
 * On a transition day the two boundaries use DIFFERENT offsets, so the window is the real
 * 23h/25h local day — e.g. LA spring-forward 2026-03-08 → [08:00Z (PST midnight), next-day
 * 07:00Z (PDT midnight)). Falls back to the UTC window when `timezone` is unset/invalid.
 */
export function dayWindowInTimezone(now: Date, timezone: string): { start: Date; end: Date } {
  // Step 1: the target LOCAL calendar date, from the offset in effect at `now`.
  const nowOffsetMs = timezoneOffsetMs(now, timezone);
  if (nowOffsetMs === null) return dayWindow(now);
  const localNow = new Date(now.getTime() + nowOffsetMs);
  const y = localNow.getUTCFullYear();
  const mo = localNow.getUTCMonth();
  const d = localNow.getUTCDate();

  // Step 2: each midnight boundary resolved with the offset in effect AT that boundary.
  const start = localWallClockToUtc(y, mo, d, timezone, nowOffsetMs);
  const end = localWallClockToUtc(y, mo, d + 1, timezone, nowOffsetMs); // Date.UTC normalizes d+1
  if (start === null || end === null) return dayWindow(now);
  return { start, end };
}

/** [start, end) UTC bounds for the calendar month containing `now`. */
export function monthWindow(now: Date): { start: Date; end: Date } {
  return {
    start: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)),
    end: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)),
  };
}

/**
 * [start, end) absolute-instant bounds for the calendar MONTH containing `now` IN A GIVEN
 * IANA TIMEZONE — local midnight on the 1st → local midnight on the 1st of the next month,
 * returned as UTC `Date`s. The month sibling of `dayWindowInTimezone`, built from the same
 * two primitives so both boundaries agree with `localDateStamp` (and with each other).
 *
 * WHY THIS EXISTS: a UTC month start rolls over at 17:00 local for a Pacific user on the last
 * day of the month, so a monthly quota shown as "this month" would reset mid-afternoon on the
 * 31st. Same defect class as the day window (#1289) — fixed the same way.
 *
 * ONE DIFFERENCE from the day case: `now` can be up to 31 days from either boundary, so its
 * own UTC offset is a poor seed for `localWallClockToUtc` (it can be a full hour off if a
 * transition falls inside the month). We therefore re-seed each boundary from the offset at
 * local NOON of that boundary's own date — noon is never inside a transition — so the seed
 * starts within minutes of the truth. `localWallClockToUtc` then resolves the boundary
 * itself, including the ambiguous case where the 1st opens with a local midnight that
 * happens twice (`America/Havana`, first Sunday of November — which IS the 1st in 2020,
 * 2026 and 2037). Picking the LATER of those two instants would put `start` after `now` for
 * an hour and exclude every event from the quota read; that is why the helper takes the
 * earliest. Falls back to the UTC month window when `timezone` is unset/invalid.
 */
export function monthWindowInTimezone(now: Date, timezone: string): { start: Date; end: Date } {
  const nowOffsetMs = timezoneOffsetMs(now, timezone);
  if (nowOffsetMs === null) return monthWindow(now);
  const localNow = new Date(now.getTime() + nowOffsetMs);
  const y = localNow.getUTCFullYear();
  const mo = localNow.getUTCMonth();

  // Re-seed each boundary at ITS OWN local noon, then let localWallClockToUtc resolve the
  // exact instant of that midnight. Date.UTC normalizes mo + 1 → January of y + 1.
  const startSeed = noonOffsetMs(y, mo, timezone, nowOffsetMs);
  const endSeed = noonOffsetMs(y, mo + 1, timezone, nowOffsetMs);
  if (startSeed === null || endSeed === null) return monthWindow(now);
  const start = localWallClockToUtc(y, mo, 1, timezone, startSeed);
  const end = localWallClockToUtc(y, mo + 1, 1, timezone, endSeed);
  if (start === null || end === null) return monthWindow(now);
  return { start, end };
}

/**
 * The zone offset in effect around local noon on the 1st of `y-mo`. Noon is the DST-safe
 * anchor — every transition in tzdata happens between ~00:00 and ~03:00 local, so noon is
 * never inside one — making this a seed that is at most minutes off even when `now` sits on
 * the other side of a transition. Pure.
 */
function noonOffsetMs(
  y: number,
  mo: number,
  timezone: string,
  seedOffsetMs: number,
): number | null {
  return timezoneOffsetMs(new Date(Date.UTC(y, mo, 1, 12) - seedOffsetMs), timezone);
}

/**
 * The UTC instant whose LOCAL wall-clock time in `timezone` is exactly `y-mo-d 00:00`.
 *
 * Local midnight is not always a single instant, and both edge cases are real:
 *
 *   AMBIGUOUS (DST fall-back lands ON midnight) — local midnight happens TWICE. In
 *   `America/Havana` the clock goes 00:59 CDT → 00:00 CST, so 2026-11-01 00:30 local is both
 *   04:30Z and 05:30Z. `Atlantic/Azores` does the same at the end of October (01:00 WEST →
 *   00:00 WET). These are the only two zones that do it in tzdata 2024-2031.
 *
 *   NONEXISTENT (DST spring-forward lands ON midnight) — local midnight never happens; the
 *   clock goes 23:59:59 → 01:00:00. `Asia/Beirut` does this on the last Sunday of March.
 *
 * WHY A SEED-DEPENDENT ANSWER IS A BUG. The previous implementation guessed once from
 * `guessOffsetMs` and corrected once. For an ambiguous midnight that returns whichever of the
 * two instants the seed happened to be near — so the SAME local day resolved to a start of
 * 04:00Z before the clock rewound and 05:00Z after it. Two user-visible failures fell out:
 *
 *   1. The day window MOVED during the repeated hour, so `usage_events` recorded in it
 *      dropped out of the quota window and the counter appeared to reset mid-day
 *      (`usage_counters` also minted a second `minute_bucket` row for one local day).
 *   2. When the ambiguous midnight was also a MONTH start (Havana, 2026-11-01 — Cuba's
 *      fall-back is the first Sunday of November, which is the 1st whenever that Sunday is
 *      the 1st: 2020, 2026, 2037), `monthWindowInTimezone` returned the LATER instant, so
 *      for `now` in [04:00Z, 05:00Z) the month `start` was AFTER `now`. Quota reads bound
 *      `created_at >= start`, so every event — including the one being inserted — was
 *      excluded, the user read 0 usage, and the monthly limit stopped enforcing entirely.
 *
 * THE RULE, and it resolves both: enumerate the candidate instants and prefer the EARLIEST
 * one that genuinely renders as the requested wall clock. A candidate built from offset `o`
 * is only real if the offset actually in effect there is also `o` — that check is what
 * distinguishes the two arms of an ambiguity from the two near-misses of a gap.
 *
 *   - ambiguous → both candidates are real; the earliest is the FIRST local midnight, which
 *     is where the local day actually began. Stable across the rewind, and it never excludes
 *     an event that belongs to the day.
 *   - nonexistent → no candidate is real; fall back to the LATEST candidate, which is exactly
 *     the transition instant (`midnight − offsetBefore`, and offsetBefore < offsetAfter on a
 *     spring-forward). That is the first instant of the local day, so the window still starts
 *     when the day did.
 *   - ordinary day → the seeds agree, there is one candidate, and the answer is unchanged.
 *
 * Seeds bracket the boundary: the offset one day either side of the caller's guess, plus the
 * guess itself. A single transition can only make those differ, and each distinct seed yields
 * one candidate. Returns null on a bad zone. Pure.
 */
function localWallClockToUtc(
  y: number,
  mo: number,
  d: number,
  timezone: string,
  guessOffsetMs: number,
): Date | null {
  const midnightAsUtc = Date.UTC(y, mo, d);
  const anchor = midnightAsUtc - guessOffsetMs;
  const seeds = [
    timezoneOffsetMs(new Date(anchor - DAY_MS), timezone),
    guessOffsetMs,
    timezoneOffsetMs(new Date(anchor + DAY_MS), timezone),
  ];

  let earliestReal: number | null = null;
  let latestCandidate: number | null = null;

  for (const seed of seeds) {
    if (seed === null) continue;
    const candidate = midnightAsUtc - seed;
    const actualOffsetMs = timezoneOffsetMs(new Date(candidate), timezone);
    if (actualOffsetMs === null) continue;
    if (latestCandidate === null || candidate > latestCandidate) latestCandidate = candidate;
    // Real only if the zone offset AT the candidate is the one we built it from — i.e. the
    // candidate's local rendering really is `y-mo-d 00:00`.
    if (actualOffsetMs === seed && (earliestReal === null || candidate < earliestReal)) {
      earliestReal = candidate;
    }
  }

  if (earliestReal !== null) return new Date(earliestReal);
  if (latestCandidate !== null) return new Date(latestCandidate); // gap: the transition instant
  return null;
}

/**
 * One `Intl.DateTimeFormat` per zone. Constructing a formatter is by far the expensive part
 * of `timezoneOffsetMs` (it loads the zone's rule table); `formatToParts` on an existing one
 * is cheap. `localWallClockToUtc` probes several candidate instants per boundary, so a fresh
 * formatter per probe would make every quota read noticeably slower — this keeps the
 * disambiguation essentially free. Formatters are immutable and thread-safe to reuse; the map
 * is bounded by the number of distinct IANA zones the process ever sees.
 */
const zoneFormatters = new Map<string, Intl.DateTimeFormat>();

function zoneFormatter(timezone: string): Intl.DateTimeFormat {
  let formatter = zoneFormatters.get(timezone);
  if (!formatter) {
    // `en-US` with an explicit `timeZone` yields that zone's wall-clock parts for an instant.
    // Throws for an invalid zone — the caller's try/catch turns that into the UTC fallback.
    formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    });
    zoneFormatters.set(timezone, formatter);
  }
  return formatter;
}

/**
 * The signed offset (ms) to add to a UTC instant to get the wall-clock time in `timezone`
 * at that instant — DST-correct because it reads the actual zone rendering of `now`. Returns
 * null for an invalid/unknown zone so callers can fall back to UTC. Pure.
 */
function timezoneOffsetMs(now: Date, timezone: string): number | null {
  try {
    const parts = zoneFormatter(timezone).formatToParts(now);
    const get = (t: string) => Number(parts.find((p) => p.type === t)?.value);
    const y = get('year');
    const mo = get('month');
    const d = get('day');
    let h = get('hour');
    const mi = get('minute');
    const s = get('second');
    if ([y, mo, d, h, mi, s].some((n) => Number.isNaN(n))) return null;
    if (h === 24) h = 0; // hour12:false can emit 24 for midnight
    const asUtc = Date.UTC(y, mo - 1, d, h, mi, s);
    // asUtc is the wall-clock read as if it were UTC; the difference from the real instant
    // (rounded to whole seconds to drop sub-second render noise) is the zone offset.
    return asUtc - Math.floor(now.getTime() / 1000) * 1000;
  } catch {
    return null;
  }
}

function toIso(value: unknown): string | null {
  if (!value) return null;
  const d = value instanceof Date ? value : new Date(value as string);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/**
 * Gather the data a digest summarizes, scoped to one user. Pure-ish: the only side
 * effect is read queries. The shape is deterministic so buildDigestPrompt and the
 * fallback renderer can both consume it.
 */
export async function gatherDigestContext(
  userId: string,
  kind: DigestKind,
  now: Date,
  timezone: string = DEFAULT_BRIEF_TIMEZONE,
): Promise<DigestContext> {
  // Bucket by the user's OWN local day (DST-correct via dayWindowInTimezone), not UTC — so a
  // non-UTC user gets their local day's digest. `timezone` defaults to 'UTC' (identical to the
  // old dayWindow behaviour), and dayWindowInTimezone falls back to the UTC window for any
  // invalid/unknown zone, so this never throws.
  const { start, end } = dayWindowInTimezone(now, timezone);
  const startIso = start.toISOString();
  const endIso = end.toISOString();

  // Today's calendar events (relevant to the morning brief; harmless context otherwise).
  const eventsResult = await pool.query(
    `SELECT title, start_date, duration_minutes
       FROM tasks
      WHERE user_id = $1::uuid
        AND type = 'calendar_event'
        AND start_date >= $2::timestamptz
        AND start_date < $3::timestamptz
      ORDER BY start_date ASC
      LIMIT 50`,
    [userId, startIso, endIso],
  );

  // Open tasks (pending / in_progress), most urgent first. Overdue = start_date before today.
  const openResult = await pool.query(
    `SELECT title, status, priority, start_date,
            (start_date IS NOT NULL AND start_date < $2::timestamptz) AS overdue
       FROM tasks
      WHERE user_id = $1::uuid
        AND type = 'task'
        AND status IN ('pending', 'in_progress')
      ORDER BY overdue DESC,
               CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END ASC,
               start_date ASC NULLS LAST
      LIMIT 50`,
    [userId, startIso],
  );

  // Tasks completed today (the heart of the evening recap).
  const completedResult = await pool.query(
    `SELECT title
       FROM tasks
      WHERE user_id = $1::uuid
        AND status = 'completed'
        AND updated_at >= $2::timestamptz
        AND updated_at < $3::timestamptz
      ORDER BY updated_at DESC
      LIMIT 50`,
    [userId, startIso, endIso],
  );

  // Comments added today across the user's tasks (activity from cloud/local runtimes + the user).
  const commentsResult = await pool.query(
    `SELECT c.author_label, c.body, t.title AS task_title
       FROM task_comments c
       JOIN tasks t ON t.id = c.task_id
      WHERE c.user_id = $1::uuid
        AND c.created_at >= $2::timestamptz
        AND c.created_at < $3::timestamptz
      ORDER BY c.created_at DESC
      LIMIT 30`,
    [userId, startIso, endIso],
  );

  return {
    kind,
    windowStart: startIso,
    windowEnd: endIso,
    events: eventsResult.rows.map((r) => ({
      title: r.title,
      start_date: toIso(r.start_date),
      duration_minutes: r.duration_minutes ?? null,
    })),
    openTasks: openResult.rows.map((r) => ({
      title: r.title,
      status: r.status ?? null,
      priority: r.priority ?? null,
      start_date: toIso(r.start_date),
      overdue: Boolean(r.overdue),
    })),
    completedToday: completedResult.rows.map((r) => r.title as string),
    recentComments: commentsResult.rows.map((r) => ({
      author_label: r.author_label,
      body: r.body,
      task_title: r.task_title,
    })),
  };
}

/** True when there is genuinely nothing worth a digest (so we skip the GMI call). */
export function isContextEmpty(ctx: DigestContext): boolean {
  if (ctx.kind === 'morning_brief') {
    return ctx.events.length === 0 && ctx.openTasks.length === 0;
  }
  return (
    ctx.completedToday.length === 0 &&
    ctx.recentComments.length === 0 &&
    ctx.openTasks.length === 0
  );
}

function fmtTime(iso: string | null): string {
  if (!iso) return 'unscheduled';
  const d = new Date(iso);
  return d.toLocaleTimeString('en-US', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'UTC',
    timeZoneName: 'short',
  });
}

const MORNING_SYSTEM =
  "You are Rem's proactive cloud assistant. Write the user's morning brief: a warm, " +
  'concise summary of the day ahead based only on the events and tasks provided. ' +
  '2-4 short sentences or a tight bullet list. Lead with anything time-sensitive or ' +
  'overdue. Do not invent items that are not in the data. No preamble like "Here is".';

const EVENING_SYSTEM =
  "You are Rem's proactive cloud assistant. Write the user's end-of-day recap: what got " +
  'done today, notable activity, and what is still open for tomorrow, based only on the ' +
  'data provided. 2-4 short sentences or a tight bullet list. Encouraging but honest. ' +
  'Do not invent items. No preamble like "Here is".';

/** Render the gathered context as the user-message text for the model. Pure. */
export function buildDigestUserPrompt(ctx: DigestContext): string {
  const lines: string[] = [];

  if (ctx.kind === 'morning_brief') {
    lines.push("TODAY'S EVENTS:");
    lines.push(
      ctx.events.length
        ? ctx.events.map((e) => `- ${fmtTime(e.start_date)}: ${e.title}`).join('\n')
        : '(none)',
    );
    lines.push('', 'OPEN TASKS (most urgent first):');
    lines.push(
      ctx.openTasks.length
        ? ctx.openTasks
            .map(
              (t) =>
                `- ${t.title} [${t.priority ?? 'medium'}${t.overdue ? ', OVERDUE' : ''}]`,
            )
            .join('\n')
        : '(none)',
    );
  } else {
    lines.push('COMPLETED TODAY:');
    lines.push(
      ctx.completedToday.length
        ? ctx.completedToday.map((t) => `- ${t}`).join('\n')
        : '(none)',
    );
    lines.push('', "TODAY'S ACTIVITY (comments):");
    lines.push(
      ctx.recentComments.length
        ? ctx.recentComments
            .map((c) => `- [${c.author_label} on "${c.task_title}"]: ${c.body}`)
            .join('\n')
        : '(none)',
    );
    lines.push('', 'STILL OPEN:');
    lines.push(
      ctx.openTasks.length
        ? ctx.openTasks
            .map((t) => `- ${t.title} [${t.priority ?? 'medium'}${t.overdue ? ', OVERDUE' : ''}]`)
            .join('\n')
        : '(none)',
    );
  }

  return lines.join('\n');
}

function digestTitle(kind: DigestKind): string {
  return kind === 'morning_brief' ? 'Your morning brief' : 'Your end-of-day recap';
}

/**
 * Deterministic, model-free summary used when GMI is unreachable (or for the empty
 * case). Keeps digests useful even when the cloud call fails — mirrors agentbox's
 * "never hard-fail" philosophy.
 */
export function renderFallbackBody(ctx: DigestContext): string {
  if (isContextEmpty(ctx)) {
    return ctx.kind === 'morning_brief'
      ? 'Nothing scheduled and no open tasks for today. Enjoy the clear runway.'
      : 'No completed tasks or activity logged today, and nothing left open. All quiet.';
  }

  const parts: string[] = [];
  if (ctx.kind === 'morning_brief') {
    if (ctx.events.length) {
      parts.push(
        `${ctx.events.length} event${ctx.events.length === 1 ? '' : 's'} today, starting with "${ctx.events[0].title}" at ${fmtTime(ctx.events[0].start_date)}.`,
      );
    }
    const overdue = ctx.openTasks.filter((t) => t.overdue).length;
    if (ctx.openTasks.length) {
      parts.push(
        `${ctx.openTasks.length} open task${ctx.openTasks.length === 1 ? '' : 's'}${overdue ? `, ${overdue} overdue` : ''}. Top: "${ctx.openTasks[0].title}".`,
      );
    }
  } else {
    if (ctx.completedToday.length) {
      parts.push(
        `Completed ${ctx.completedToday.length} task${ctx.completedToday.length === 1 ? '' : 's'} today, including "${ctx.completedToday[0]}".`,
      );
    }
    if (ctx.recentComments.length) {
      parts.push(`${ctx.recentComments.length} new comment${ctx.recentComments.length === 1 ? '' : 's'} across your tasks.`);
    }
    if (ctx.openTasks.length) {
      parts.push(`${ctx.openTasks.length} task${ctx.openTasks.length === 1 ? '' : 's'} still open for tomorrow.`);
    }
  }
  return parts.join(' ');
}

/**
 * Generate (but do not persist) a digest for a user. Never throws — on a GMI error
 * it returns a 'fallback' digest; with nothing to report it returns 'empty'.
 */
export async function generateDigest(
  userId: string,
  kind: DigestKind,
  now: Date,
  timezone: string = DEFAULT_BRIEF_TIMEZONE,
): Promise<GeneratedDigest> {
  const ctx = await gatherDigestContext(userId, kind, now, timezone);
  const title = digestTitle(kind);

  if (isContextEmpty(ctx)) {
    return { kind, title, body: renderFallbackBody(ctx), source: 'empty', model: null };
  }

  const system = ctx.kind === 'morning_brief' ? MORNING_SYSTEM : EVENING_SYSTEM;
  const userPrompt = buildDigestUserPrompt(ctx);

  // ONE RUNTIME: the user's own gateway (chat.send). The brief threads into a stable,
  // loadable session (`rem-digest-<kind>`) so the user can open it as a chat. Never throws —
  // a gateway-less user (or a wake/turn failure) lands on the deterministic local render,
  // NOT on the operator's key. See the fallback note in this file's header.
  const viaGateway = await runAgentTurnOnGateway({
    userId,
    // Date-scoped so each day's brief is its own session (no unbounded history growth).
    sessionKey: `rem-digest-${kind}-${utcDateStamp(now)}`,
    message: `${system}\n\n${userPrompt}`,
  });
  if (viaGateway.ok && viaGateway.text.trim()) {
    return { kind, title, body: viaGateway.text.trim(), source: 'gmi', model: 'gateway' };
  }

  return { kind, title, body: renderFallbackBody(ctx), source: 'fallback', model: null };
}

const DIGEST_RETURNING = 'id, kind, title, body, source, model, created_at';

function formatDigest(row: any): DigestRow {
  return {
    id: row.id.toString(),
    kind: row.kind,
    title: row.title,
    body: row.body,
    source: row.source,
    model: row.model ?? null,
    created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
  };
}

/**
 * Generate a digest for a user and persist it. Returns the stored row.
 *
 * Resolves the user's IANA timezone (from their check-in settings, the same source the
 * daily brief uses — `resolveUserTimezone`) so the digest's day window is the user's LOCAL
 * day, not UTC. `timezone` can be passed to skip the lookup (tests / a caller that already
 * resolved it); otherwise it's resolved here and falls back to 'UTC'. Never throws on the
 * resolve — `resolveUserTimezone` swallows its own errors and returns the fallback.
 */
export async function createDigestForUser(
  userId: string,
  kind: DigestKind,
  now: Date,
  timezone?: string,
): Promise<DigestRow> {
  const tz = timezone ?? (await resolveUserTimezone(userId));
  const generated = await generateDigest(userId, kind, now, tz);
  const result = await pool.query(
    `INSERT INTO digests (user_id, kind, title, body, source, model)
     VALUES ($1::uuid, $2, $3, $4, $5, $6)
     RETURNING ${DIGEST_RETURNING}`,
    [userId, generated.kind, generated.title, generated.body, generated.source, generated.model],
  );
  return formatDigest(result.rows[0]);
}

export { DIGEST_RETURNING, formatDigest };
