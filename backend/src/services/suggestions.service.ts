/**
 * Suggested tasks — the "usage" payoff (WS2, doc 38 §4/§8, tier 1).
 *
 * A **suggestion** converts a SIGNAL (an external event that *might* imply work) into a
 * candidate the user can act on — per the taxonomy (doc 19): a signal is never itself a task;
 * the suggester either turns it into a nameable-outcome action or emits nothing.
 *
 * Tier 1 uses only signals we ALREADY have locally (no channel required — that's tier 2):
 *   - **calendar** — an event coming up with no prep yet → "Prep for <event>" (a NEW task).
 *   - **overdue**  — a task whose start date has passed → "Reschedule '<task>' to today"
 *                    (a triage action on the existing task; keeps the user on track).
 *
 * Suggestions are DERIVED on every read (never stored) so they always reflect current state.
 * Only **dismissals** are persisted (durable, keyed on the stable `key`) — a suggestion the
 * user waved away must never return, or the feature is a nag (doc 38 §6).
 *
 * Accept is performed CLIENT-side (the app creates/updates the TaskEvent through its normal
 * SwiftData + sync path, keeping the app the source of truth) and the app then POSTs a dismiss
 * so the accepted suggestion won't re-derive. This service therefore exposes read + dismiss;
 * it never mutates the tasks table.
 */

import { pool, type DatabaseQueryable } from '../db/pool.js';
import { dayWindowInTimezone } from './digest.service.js';
import { formatSuggestedTimeLabel, plausibleSuggestedStart } from './suggested-time.js';
import { createHash } from 'node:crypto';

/** How the accepting client should turn an accepted suggestion into a real task. */

/**
 * How long a dismissal suppresses its suggestion. `dismissed_at` has existed since migration 038
 * but nothing read it, so dismissals were permanent — see the note on `notDismissed`.
 */
export const DISMISSAL_TTL_DAYS = 7;

export type SuggestionActionKind = 'createTask' | 'rescheduleTask';

export interface SuggestionAction {
  kind: SuggestionActionKind;
  /** createTask: the title of the NEW task to create ("Prep for Standup"). */
  taskTitle?: string;
  /** rescheduleTask: the existing task to move. */
  targetTaskId?: string;
  /** ISO 8601. createTask → when to schedule the new task; rescheduleTask → the new start. */
  startDate?: string;
}

/**
 * Where a suggestion came from. `calendar`/`overdue` are tier-1 (derived from tasks we already
 * have); the rest are tier-2 CONNECTED sources — a signal from an app the user linked (doc 38 §4).
 */
export type SuggestionSource = 'calendar' | 'overdue' | 'gmail' | 'whatsapp' | 'discord';

/** Human label for a connected source, for the attribution line ("· Gmail"). */
const SOURCE_LABEL: Record<string, string> = {
  gmail: 'Gmail',
  whatsapp: 'WhatsApp',
  discord: 'Discord',
};

export interface TaskSuggestion {
  /** Stable identity, source-prefixed: "cal:<eventId>" | "overdue:<taskId>". Dismissal key. */
  key: string;
  /** Stable backend-issued action identity. createTask clients also use this UUID as the task id. */
  actionId: string;
  source: SuggestionSource;
  /** The headline the card shows ("Prep for Standup" / "Reschedule to today"). */
  title: string;
  /** The WHY / attribution ("Standup · 9:00 AM · Calendar" / "'File visa paperwork' · overdue 3d"). */
  subtitle: string;
  action: SuggestionAction;
}

/**
 * Stable UUID-shaped action identity derived from the authenticated owner plus canonical key.
 * It intentionally excludes the proposed schedule: `laterToday` moves as time advances, while an
 * already accepted proposal must keep one idempotency identity across refresh and retry.
 */
export function suggestionActionId(userId: string, key: string, kind: SuggestionActionKind): string {
  const bytes = Buffer.from(createHash('sha256').update(`${userId}\u0000${key}\u0000${kind}`).digest().subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Exact identity for one atomic brief/suggestion response, including mutable action payloads. */
export function suggestionSnapshotId(briefRevision: string, suggestions: TaskSuggestion[]): string {
  return createHash('sha256')
    .update(JSON.stringify({ briefRevision, suggestions }))
    .digest('hex');
}

/** Cap so the Agenda shows a helpful few, never a wall (doc 38 §6 — orientation, not noise). */
const MAX_SUGGESTIONS = 5;
/** How far ahead a calendar event counts as "coming up" and worth prepping for. */
const CALENDAR_LOOKAHEAD_MS = 36 * 60 * 60 * 1000;

interface OverdueRow {
  id: string;
  title: string;
  start_date: string; // ISO
}
interface EventRow {
  id: string;
  title: string;
  start_date: string; // ISO
}
interface SignalRow {
  id: string;
  source: string;
  sender: string | null;
  summary: string;
  suggested_title: string | null;
  relevance_title: string | null;
  /** The judge's recommended start (migration 122). NULL = no recommendation. */
  relevance_start_at: Date | string | null;
  received_at: string; // ISO
}

/** Compact relative age for the attribution line ("2h ago", "3d ago"). Min 1m. */
function relativeAge(from: Date, now: Date): string {
  const mins = Math.max(1, Math.floor((now.getTime() - from.getTime()) / 60_000));
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

/**
 * Whole CALENDAR days a task is overdue, in the user's timezone. Counts day
 * BOUNDARIES crossed between the due date's local day and today's local day — not a
 * 24h ms bucket — so:
 *   - a task due earlier the SAME local day reads 0 (an intraday overdue, never "1d");
 *   - a task due late yesterday reads 1 even if only a few wall-clock hours have passed;
 *   - a task due two local days ago reads 2 even if <48h have elapsed.
 * Fixes #1094: a task dated today no longer renders "overdue 1d". Callers show the "Nd"
 * chip only when this is ≥1; 0 is labelled as a plain intraday "overdue".
 */
function daysOverdue(startDate: Date, now: Date, timezone: string): number {
  const startOfToday = dayWindowInTimezone(now, timezone).start.getTime();
  const startOfDueDay = dayWindowInTimezone(startDate, timezone).start.getTime();
  const days = Math.round((startOfToday - startOfDueDay) / (24 * 60 * 60 * 1000));
  return Math.max(0, days);
}

/** "9:00 AM" in the user's timezone, for the calendar attribution line. */
function localTimeLabel(date: Date, timezone: string): string {
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

/**
 * Derive the current suggestions for a user. Read-only over `tasks`; filters out anything the
 * user has dismissed. Overdue (more urgent) sorts before calendar; capped at MAX_SUGGESTIONS.
 */
export async function deriveSuggestions(
  userId: string,
  now: Date,
  timezone: string,
  db: DatabaseQueryable = pool,
): Promise<TaskSuggestion[]> {
  const { end: dayEnd } = dayWindowInTimezone(now, timezone);
  const out: TaskSuggestion[] = [];

  // Where "reschedule to today" / a new prep task should land. It MUST be in the future, or the
  // task is instantly overdue again (the overdue signal is `start_date < now`, and the local
  // day's *start* is already in the past by any time after midnight). Aim an hour out, but never
  // spill past the end of today — and never BEFORE now (the last seconds of the day, where
  // `dayEnd - 1s` is already in the past), or we'd hand back a past time and re-trip overdue.
  const earliestFuture = now.getTime() + 60 * 1000;
  const latestToday = dayEnd.getTime() - 1000;
  // There is no truthful future instant "today" during the final minute. Suppress this transient
  // snapshot rather than relabeling tomorrow as today or creating an immediately-overdue task.
  if (earliestFuture > latestToday) return [];
  const laterToday = new Date(Math.min(now.getTime() + 60 * 60 * 1000, latestToday));
  const laterTodayISO = laterToday.toISOString();

  // Dismissals are filtered in SQL (before LIMIT) so a user with many dismissed items can't
  // starve a still-valid candidate that sorts past the cap. The `$1` user scoping is shared.
  // A dismissal means "not now", not "never again". It used to mean never again: the filter was a
  // bare NOT IN with no time bound, and `dismissed_at` — recorded since migration 038 — was never
  // read by anything. Measured on staging: the founder's account had 3 dismissals against exactly
  // the 3 overdue tasks that could produce a suggestion, so the suggestion list was permanently
  // empty and could never recover. Their report was "I still don't see suggestions in app."
  //
  // So dismissals now decay. A week later, "want to reschedule this?" is a fresh question about a
  // task the user still has, not a repeat of one they answered. Shorter would re-nag (the exact
  // complaint that motivated task staleness); longer leaves the surface dead for people who tidy
  // up once and never see it again.
  //
  // Deliberately NOT coupled to task staleness: the brief is push and goes quiet, suggestions are
  // pull and the user opened the app on purpose. A stale task may absolutely suggest itself again.
  const notDismissed = `AND (%PREFIX% || id::text) NOT IN
        (SELECT suggestion_key FROM suggestion_dismissals
          WHERE user_id = $1 AND dismissed_at > NOW() - INTERVAL '${DISMISSAL_TTL_DAYS} days')`;

  // ── connected-source signals → reply/act ─────────────────────────────────
  // A message from an app the user linked (Gmail, WhatsApp, …). This is the tier-2 payoff — a
  // suggestion that came FROM your inbox — so it LEADS the list. Each signal becomes a
  // nameable-outcome task ("Reply to Ada"), never the raw event (doc 19 taxonomy). The key is
  // "<source>:<id>"; accept → the app dismisses it, so it won't re-derive. Rows are produced by
  // the connector poller (signal-ingest.service.ts) and judged by signal-relevance.service.ts.
  //
  // RELEVANCE FILTER — `relevance_decision IS DISTINCT FROM 'drop'`.
  //
  // Not everything that arrives deserves to interrupt someone. A deployment-crash alert from a
  // no-reply robot was becoming "Reply to Deploybot <alerts@example-ci.test>"; the judge marks that
  // 'drop' and this predicate is what stops it here.
  //
  // The comparison is `IS DISTINCT FROM` and NOT `= 'act'`, and that is the whole fail-open
  // guarantee in one operator. `relevance_decision` is NULL for a row nothing has judged yet — a
  // brand-new signal, a row the model timed out on, a batch that came back as unparseable, a policy
  // bump that has not been swept. Every one of those NULLs SURFACES. Only an explicit, stored
  // 'drop' hides anything. Written as `= 'act'`, a single bad classifier day would silently empty
  // the user's suggestions and look exactly like a quiet inbox. Losing a real signal is worse than
  // showing a mediocre one.
  const signals = await db.query<SignalRow>(
    `SELECT id, source, sender, summary, suggested_title, relevance_title,
            relevance_start_at, received_at
       FROM channel_signals
      WHERE user_id = $1
        AND btrim(summary) <> ''
        AND relevance_decision IS DISTINCT FROM 'drop'
        AND ((source || ':' || id::text) NOT IN
             (SELECT suggestion_key FROM suggestion_dismissals
               WHERE user_id = $1 AND dismissed_at > NOW() - INTERVAL '${DISMISSAL_TTL_DAYS} days'))
      ORDER BY received_at DESC
      LIMIT ${MAX_SUGGESTIONS}`,
    [userId],
  );
  for (const row of signals.rows) {
    const label = SOURCE_LABEL[row.source] ?? row.source;
    // Title precedence, best first:
    //   1. `relevance_title` — the OUTCOME the judge named ("Look at why the rem-canary deploy
    //      crashed"). This is the only one of the three that read the message and decided what a
    //      person would actually DO about it.
    //   2. `suggested_title` — a descriptor-precomputed title. No descriptor sets one today
    //      (gmailSignalDescriptor pins it to null on purpose), but the POST /signals route accepts
    //      one from a caller that genuinely knows better.
    //   3. `Reply to <sender>` — the last-resort template, and the thing the founder rejected.
    //      It is deliberately still here, because the row it now serves is an UNJUDGED row, and the
    //      alternative to a mediocre title on an unjudged row is no row at all. Reaching this
    //      branch for a judged row is impossible: an 'act' verdict always carries a title (the
    //      parser refuses an 'act' without one), and a 'drop' never gets this far.
    const title = row.relevance_title?.trim()
      || row.suggested_title?.trim()
      || `Reply to ${row.sender?.trim() || label}`;
    const age = relativeAge(new Date(row.received_at), now);
    const key = `${row.source}:${row.id}`;

    // ── THE TIMEBLOCK ────────────────────────────────────────────────────────
    // A task's `start_date` IS its timeblock, so the judge's recommended time is simply the
    // `startDate` the accepting client already applies (`AgendaViewModel.performAccept`,
    // `MacOrchestratorSuggestionStore.performAccept`). Nothing new has to happen on tap: one tap
    // on Add creates the task ALREADY SCHEDULED for the recommended slot.
    //
    // RE-CHECKED HERE, not trusted from the column. The verdict was written at ingest — up to a
    // fortnight ago for a row that keeps re-deriving — so `plausibleSuggestedStart`'s
    // "strictly in the future" clause is doing real work on this side: yesterday's "today at 4pm"
    // is stale, and using it would create an instantly-overdue task, the exact defect
    // `laterToday` exists to avoid. One rule, both sides (`suggested-time.ts`).
    const recommended = plausibleSuggestedStart(row.relevance_start_at, now, timezone);

    // The label is shown ONLY when the time was recommended. Every suggestion carries a
    // `startDate` (it always has — `laterToday`), but that fallback is an implementation detail,
    // not a proposal, and rendering "Today 3:00 PM" on every card would be false precision that
    // teaches the user to ignore the one time we actually meant.
    const timeLabel = recommended ? `${formatSuggestedTimeLabel(recommended, now, timezone)} · ` : '';

    out.push({
      key,
      actionId: suggestionActionId(userId, key, 'createTask'),
      source: (row.source as SuggestionSource),
      title,
      // Time FIRST: the card clamps the subtitle to two lines, and a recommendation the user
      // cannot see is a recommendation they cannot decline.
      subtitle: `${timeLabel}${row.summary} · ${label} · ${age}`,
      action: {
        kind: 'createTask',
        taskTitle: title,
        startDate: (recommended ?? laterToday).toISOString(),
      },
    });
  }

  // ── overdue → reschedule ──────────────────────────────────────────────────
  // A live task whose scheduled start is in the past. Excludes blocked runs (they need
  // unblocking, not rescheduling) and unscheduled inbox rows (NULL start_date is not overdue).
  const overdue = await db.query<OverdueRow>(
    `SELECT id, title, start_date
       FROM tasks
      WHERE user_id = $1
        AND type = 'task'
        AND status IN ('pending', 'in_progress')
        AND (run_status IS NULL OR run_status <> 'blocked')
        AND start_date IS NOT NULL
        AND start_date < $2
        AND btrim(title) <> ''
        ${notDismissed.replace('%PREFIX%', "'overdue:'")}
      ORDER BY start_date ASC
      LIMIT ${MAX_SUGGESTIONS}`,
    [userId, now.toISOString()],
  );
  for (const row of overdue.rows) {
    const started = new Date(row.start_date);
    // Calendar-day count in the user's zone. 0 = due earlier the same local day → a plain
    // intraday "overdue" (matches the "Overdue" pill copy), NOT "overdue 1d". The "Nd" chip
    // only appears once the task is on a strictly earlier local day. (#1094)
    const overdueDays = daysOverdue(started, now, timezone);
    const overdueLabel = overdueDays >= 1 ? `overdue ${overdueDays}d` : 'overdue';
    const key = `overdue:${row.id}`;
    out.push({
      key,
      actionId: suggestionActionId(userId, key, 'rescheduleTask'),
      source: 'overdue',
      title: 'Reschedule to today',
      subtitle: `'${row.title}' · ${overdueLabel}`,
      action: { kind: 'rescheduleTask', targetTaskId: row.id, startDate: laterTodayISO },
    });
  }

  // ── calendar → prep ───────────────────────────────────────────────────────
  // An upcoming event (next 36h) that has NO prep task yet. The prep-exists check is the durable
  // dedup: even if the client's post-accept dismiss never lands, once the "Prep for <event>" task
  // exists we stop re-suggesting it — so a dropped dismiss can't yield a duplicate prep task.
  const lookaheadEnd = new Date(now.getTime() + CALENDAR_LOOKAHEAD_MS);
  const events = await db.query<EventRow>(
    `SELECT e.id, e.title, e.start_date
       FROM tasks e
      WHERE e.user_id = $1
        AND e.type = 'calendar_event'
        AND e.start_date IS NOT NULL
        AND e.start_date >= $2
        AND e.start_date < $3
        AND btrim(e.title) <> ''
        AND NOT EXISTS (
          SELECT 1 FROM tasks p
           WHERE p.user_id = $1 AND p.type = 'task'
             AND p.title = 'Prep for ' || e.title
        )
        ${notDismissed.replace('%PREFIX%', "'cal:'").replace(/\bid::text\b/, 'e.id::text')}
      ORDER BY e.start_date ASC
      LIMIT ${MAX_SUGGESTIONS}`,
    [userId, now.toISOString(), lookaheadEnd.toISOString()],
  );
  for (const row of events.rows) {
    const when = new Date(row.start_date);
    const prepTitle = `Prep for ${row.title}`;
    const key = `cal:${row.id}`;
    out.push({
      key,
      actionId: suggestionActionId(userId, key, 'createTask'),
      source: 'calendar',
      title: prepTitle,
      subtitle: `${row.title} · ${localTimeLabel(when, timezone)} · Calendar`,
      // Schedule prep for later today (non-overdue) so accepting lands it on today's agenda.
      action: { kind: 'createTask', taskTitle: prepTitle, startDate: laterTodayISO },
    });
  }

  return out.slice(0, MAX_SUGGESTIONS);
}

/**
 * Durably record that the user dismissed (or accepted — the app dismisses on accept too) a
 * suggestion, so it never re-derives. Idempotent: re-dismissing the same key is a no-op.
 */
export async function dismissSuggestion(userId: string, key: string): Promise<void> {
  await pool.query(
    `INSERT INTO suggestion_dismissals (user_id, suggestion_key)
     VALUES ($1, $2)
     ON CONFLICT (user_id, suggestion_key) DO NOTHING`,
    [userId, key],
  );
}

export interface ChannelSignalInput {
  source: string; // 'gmail' | 'whatsapp' | 'discord' | …
  sourceRef: string; // stable per-source id (message/thread id) — makes ingest idempotent
  summary: string; // the human text the suggestion reasons over / shows
  sender?: string; // who it's from, for attribution
  suggestedTitle?: string; // optional precomputed task title
  receivedAt?: string; // ISO 8601; defaults to now
}

export interface ChannelSignalIngestResult {
  /** The `channel_signals` row id — the same id for every re-delivery of one (source, sourceRef). */
  id: string;
  /**
   * TRUE when this call CREATED the row; FALSE when it updated an existing
   * (user, source, source_ref). Read from Postgres's own `xmax` on the returned tuple — the
   * structured fact about which arm of `ON CONFLICT` ran — rather than inferred by a caller doing
   * a racy pre-read or guessing from the id. A poller that re-scans an overlapping window needs
   * this to report `ingested` and `duplicates` honestly instead of counting every non-throwing
   * write as new work.
   */
  inserted: boolean;
}

/**
 * Ingest a connected-source signal (WS2 doc 38 §4 — the WS1 fill point). Idempotent on
 * (user, source, source_ref): re-delivering the same message updates its content rather than
 * duplicating.
 *
 * Callers: the `POST /api/v1/suggestions/signals` route (a linked app delivering a message) and
 * `signal-ingest.service.ts` (the scheduled connector poller). This is the ONLY writer of
 * `channel_signals` — producers go through it so the unique-key idempotency is shared, not
 * re-implemented per producer.
 */
export async function ingestSignalDetailed(
  userId: string,
  input: ChannelSignalInput,
): Promise<ChannelSignalIngestResult> {
  const { rows } = await pool.query<{ id: string; inserted: boolean }>(
    `INSERT INTO channel_signals (user_id, source, source_ref, sender, summary, suggested_title, received_at)
     VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7::timestamptz, now()))
     ON CONFLICT (user_id, source, source_ref)
     DO UPDATE SET sender = EXCLUDED.sender,
                   summary = EXCLUDED.summary,
                   suggested_title = EXCLUDED.suggested_title,
                   received_at = EXCLUDED.received_at,
                   -- A verdict is about SPECIFIC TEXT. When a re-delivery changes that text, the
                   -- stored judgment was made about something else and must not survive it —
                   -- otherwise an edited message keeps a 'drop' decided on its earlier content and
                   -- is invisible forever. Clearing to NULL re-queues the row for the judge, and
                   -- NULL surfaces in the meantime, so the failure direction is "shown again",
                   -- never "silently hidden".
                   --
                   -- Unchanged content keeps its verdict; that is what makes the 15-minute
                   -- re-poll of a rolling 24h window cost zero extra model calls.
                   relevance_decision = CASE
                     WHEN channel_signals.summary IS DISTINCT FROM EXCLUDED.summary
                       OR channel_signals.sender IS DISTINCT FROM EXCLUDED.sender
                     THEN NULL ELSE channel_signals.relevance_decision END,
                   relevance_title = CASE
                     WHEN channel_signals.summary IS DISTINCT FROM EXCLUDED.summary
                       OR channel_signals.sender IS DISTINCT FROM EXCLUDED.sender
                     THEN NULL ELSE channel_signals.relevance_title END,
                   relevance_policy = CASE
                     WHEN channel_signals.summary IS DISTINCT FROM EXCLUDED.summary
                       OR channel_signals.sender IS DISTINCT FROM EXCLUDED.sender
                     THEN NULL ELSE channel_signals.relevance_policy END,
                   relevance_judged_at = CASE
                     WHEN channel_signals.summary IS DISTINCT FROM EXCLUDED.summary
                       OR channel_signals.sender IS DISTINCT FROM EXCLUDED.sender
                     THEN NULL ELSE channel_signals.relevance_judged_at END,
                   -- The recommended TIME is part of the same judgment and decays with it. A
                   -- message edited from "call me Tuesday" to "call me Friday" must not keep
                   -- Tuesday: clearing re-queues the row for the judge, and a NULL meanwhile means
                   -- the suggestion falls back to "later today" rather than proposing a slot that
                   -- was decided about text that no longer exists.
                   relevance_start_at = CASE
                     WHEN channel_signals.summary IS DISTINCT FROM EXCLUDED.summary
                       OR channel_signals.sender IS DISTINCT FROM EXCLUDED.sender
                     THEN NULL ELSE channel_signals.relevance_start_at END
     RETURNING id, (xmax = 0) AS inserted`,
    [
      userId,
      input.source,
      input.sourceRef,
      input.sender ?? null,
      input.summary,
      input.suggestedTitle ?? null,
      input.receivedAt ?? null,
    ],
  );
  return { id: rows[0].id, inserted: rows[0].inserted === true };
}

/**
 * Ingest a connected-source signal and return the row id. Thin wrapper over
 * `ingestSignalDetailed` (one SQL path, one idempotency rule) for callers that do not need to
 * distinguish a fresh row from a re-delivery.
 */
export async function ingestSignal(userId: string, input: ChannelSignalInput): Promise<string> {
  return (await ingestSignalDetailed(userId, input)).id;
}
