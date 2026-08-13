/**
 * Daily Brief — Rem's orchestrator surface.
 *
 * The brief is the structured, machine-derived view of "your day": the tasks that
 * need a decision (Blocked / Overdue), what's on deck (Scheduled today), and what's
 * already Done. Unlike a digest (digest.service.ts), the brief is NOT prose written
 * by GMI — it is a deterministic projection of the same Postgres the apps already
 * read, so iOS and Mac render identical buckets and the client can act on each item
 * (prioritize / schedule / mark done / ask Rem). See docs/rebuild/19-TASKS-VS-WORKBOARD.md.
 *
 * Signals (no new migration — all columns already exist):
 *   - blocked         : tasks with structured run_status = 'blocked' (migration 019,
 *                       #860). A run that could not complete or that needs info — a
 *                       structured field, not a parsed comment string (principle 5).
 *   - overdue         : open tasks whose start_date is already in the past (< now).
 *                       Matches the Agenda's status bucketing (AgendaViewModel.
 *                       statusBucket: `start < now`) so a task due earlier *today*
 *                       but past its time is counted as overdue, not as scheduled.
 *   - scheduled_today : tasks + calendar events whose start_date falls inside today.
 *   - completed_today : tasks marked completed today (the "done" half of the ring).
 *
 * Buckets are mutually exclusive for an honest done/total ring: a blocked task is
 * only counted as blocked even if it is also past due, so the four counts sum cleanly.
 */

import { pool, type DatabaseQueryable } from '../db/pool.js';
import { dayWindowInTimezone } from './digest.service.js';

export type BriefBucket = 'blocked' | 'overdue' | 'scheduled_today' | 'completed_today';

/**
 * Latest non-user activity on a task — what Rem (a cloud/local runtime) last did or
 * said. This is the one-line preview the brief surfaces so the user can tap in to
 * unblock. Sourced from the most recent `task_comments` row whose author is an agent.
 */
export interface BriefActivity {
  author_label: string;
  author_kind: string;
  summary: string;
  created_at: string | null;
}

export interface BriefItem {
  id: string;
  title: string;
  status: string | null;
  priority: string | null;
  run_status: string | null;
  start_date: string | null;
  type: string;
  bucket: BriefBucket;
  /** Latest AI comment/status on this task, or null when Rem hasn't acted yet. */
  latest_activity: BriefActivity | null;
  /**
   * True once `tasks.stale_at` is set (migration 116): the brief surfaced this task
   * `BRIEF_STALE_THRESHOLD` times and the user never acted, so Rem has stopped bringing it up.
   *
   * The item is STILL RETURNED here, and still returned by GET /api/v1/tasks — "stale" means stop
   * nagging, not stop existing. What changes is that `authorBriefForUser` drops these from the
   * context it authors prose from (task-staleness.service.ts), and a client can render them
   * de-emphasised. Widening `tasks.status` instead would have removed the row from this very query
   * (`status IN ('pending','in_progress')`) and made it vanish from the Agenda — see migration 116.
   */
  is_stale: boolean;
}

export interface BriefCounts {
  blocked: number;
  overdue: number;
  scheduled_today: number;
  completed_today: number;
  /** Today's workload = scheduled_today + completed_today (the ring denominator). */
  total: number;
  /** Items finished today (the ring numerator). */
  done: number;
}

export interface DailyBrief {
  generated_at: string;
  window_start: string;
  window_end: string;
  counts: BriefCounts;
  blocked: BriefItem[];
  overdue: BriefItem[];
  scheduled_today: BriefItem[];
  completed_today: BriefItem[];
  /**
   * The brief rendered as a living markdown *prose* document — the orient-the-human
   * artifact the client shows as the full brief (card → expand to prose, #916). A
   * deterministic projection of the same buckets/counts above (Phase 1); a later phase
   * hands authorship to the gateway digest turn so it can update through the day.
   */
  markdown: string;
  /** One/two-line condensed prose for the agenda summary card (sits beside the capsules). */
  summary: string;
  /**
   * The brief's authored HEADLINE — one title string for every surface that names this brief
   * (Agenda summary card, orchestrator chat title). Populated from
   * `daily_brief_artifacts.headline` by the route once an artifact has been delivered.
   *
   * Absent/null means the brief has no authored headline (a pre-migration-119 artifact whose
   * prose opened without a heading, or the deterministic composer, which has no author to write
   * one). Clients then keep the fallback title they already used, so nothing regresses.
   */
  headline?: string | null;
  /**
   * The stable gateway chat session the AI-authored brief lives in (`rem-brief-<yyyymmdd>`),
   * so the app can open the brief as a chat (founder FR: tap brief → open the chat with the
   * brief as a card). Set by the route only for an exact persisted delivery; the switch that
   * controls future authoring does not revoke an existing current-day artifact. The deterministic
   * `gatherBrief` leaves it undefined. See docs/rebuild/27-BRIEF-AS-AI-AND-LANDING.md.
   */
  brief_session_key?: string;
}

/** Max items returned per bucket — the card shows counts; the detail shows a capped list. */
const BUCKET_LIMIT = 50;

function toIso(value: unknown): string | null {
  if (!value) return null;
  const d = value instanceof Date ? value : new Date(value as string);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function toItem(row: any, bucket: BriefBucket): BriefItem {
  return {
    id: row.id.toString(),
    title: row.title,
    status: row.status ?? null,
    priority: row.priority ?? null,
    run_status: row.run_status ?? null,
    start_date: toIso(row.start_date),
    type: row.type ?? 'task',
    bucket,
    latest_activity: null,
    is_stale: row.stale_at != null,
  };
}

/** One-line preview of a comment body: first non-empty line, trimmed and capped. */
function summarizeActivity(body: unknown): string {
  const text = typeof body === 'string' ? body : '';
  const firstLine = text
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l.length > 0) ?? '';
  return firstLine.length > 140 ? `${firstLine.slice(0, 139)}…` : firstLine;
}

// MARK: - Prose composition (#916)
//
// The brief is now a living markdown *document*, not just counts. We compose the prose
// deterministically from the very same buckets the capsules render, so the two views can
// never disagree (single source of truth = these buckets). The client renders `markdown`
// as the full brief (card → expand to prose) and `summary` as the condensed agenda line;
// the capsules stay driven by `counts`. A later phase can swap this deterministic render
// for the gateway digest turn (digest.service.ts) without changing the client contract.

/** Cap prose bullet lists so the document stays readable even on a busy day. */
const PROSE_BUCKET_LIMIT = 6;

function pluralize(n: number, word: string): string {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

function capitalize(s: string): string {
  return s.length === 0 ? s : s.charAt(0).toUpperCase() + s.slice(1);
}

/** "a", "a and b", "a, b, and c". */
function joinAnd(items: string[]): string {
  if (items.length <= 1) return items[0] ?? '';
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(', ')}, and ${items[items.length - 1]}`;
}

/** Render one bucket as capped markdown bullets, appending "…and N more" when truncated. */
function bulletList(items: BriefItem[], render: (item: BriefItem) => string): string[] {
  const shown = items.slice(0, PROSE_BUCKET_LIMIT).map((it) => `- ${render(it)}`);
  const extra = items.length - PROSE_BUCKET_LIMIT;
  if (extra > 0) shown.push(`- …and ${extra} more`);
  return shown;
}

/**
 * Sanitize free-text (task titles) for safe inline use inside a prose bullet. Titles are
 * user/AI-authored and can contain newlines or markdown control chars; interpolated raw,
 * a multi-line title splits the bullet and a `## `-shaped line injects a fake heading into
 * the document (the client parser splits on `\n` and renders `##`-prefixed lines as
 * headings). Collapse all whitespace to single spaces and cap length so the bullet stays
 * one clean line regardless of what's in the DB.
 */
function proseInline(text: unknown): string {
  const collapsed = (typeof text === 'string' ? text : '').replace(/\s+/g, ' ').trim();
  if (collapsed.length === 0) return 'Untitled task';
  return collapsed.length > 120 ? `${collapsed.slice(0, 119)}…` : collapsed;
}

/**
 * Compose the brief's prose (`markdown`) and condensed `summary` from the resolved
 * buckets + counts. Pure and deterministic — no clock/timezone dependence (the backend
 * runs UTC; the client renders exact times locally), so the prose stays correct for
 * every user regardless of server timezone.
 */
function composeBriefProse(
  counts: BriefCounts,
  blocked: BriefItem[],
  overdue: BriefItem[],
  scheduledToday: BriefItem[],
  completedToday: BriefItem[],
): { markdown: string; summary: string } {
  // All-clear day: one warm line does for both the card and the full brief.
  if (
    counts.blocked === 0 &&
    counts.overdue === 0 &&
    counts.scheduled_today === 0 &&
    counts.completed_today === 0
  ) {
    const line =
      "You're all clear — nothing blocked, overdue, or scheduled for today. Enjoy the open runway.";
    return { markdown: line, summary: line };
  }

  // Attention clause: blocked + overdue are the "needs a decision" surface.
  const attention: string[] = [];
  if (counts.blocked > 0) attention.push(`${pluralize(counts.blocked, 'task')} blocked`);
  if (counts.overdue > 0) attention.push(`${pluralize(counts.overdue, 'task')} overdue`);
  const attentionTotal = counts.blocked + counts.overdue;
  const attentionVerb = attentionTotal === 1 ? 'needs' : 'need';

  // ----- Condensed summary (agenda card, beside the capsules) -----
  const summaryParts: string[] = [];
  if (attention.length) summaryParts.push(`${capitalize(joinAnd(attention))} ${attentionVerb} attention`);
  if (counts.scheduled_today > 0) summaryParts.push(`${counts.scheduled_today} on deck`);
  if (counts.total > 0) summaryParts.push(`${counts.done} of ${counts.total} done`);
  else if (counts.completed_today > 0) summaryParts.push(`${pluralize(counts.completed_today, 'task')} done`);
  const summary = summaryParts.length ? `${summaryParts.join(' · ')}.` : 'Here’s where your day stands.';

  // ----- Full prose document -----
  const opening: string[] = [];
  if (attention.length) opening.push(`${capitalize(joinAnd(attention))} ${attentionVerb} your attention.`);
  if (counts.scheduled_today > 0) opening.push(`You've got ${pluralize(counts.scheduled_today, 'thing')} on deck today.`);
  if (counts.total > 0) opening.push(`So far ${counts.done} of ${counts.total} ${counts.total === 1 ? 'is' : 'are'} done.`);

  const md: string[] = [];
  if (opening.length) md.push(opening.join(' '));

  if (blocked.length) {
    md.push('', '## Needs a decision');
    md.push(
      ...bulletList(blocked, (it) => {
        const act = it.latest_activity?.summary?.trim();
        return act ? `**${proseInline(it.title)}** — ${act}` : `**${proseInline(it.title)}** — waiting on you`;
      }),
    );
  }
  if (overdue.length) {
    md.push('', '## Overdue');
    md.push(...bulletList(overdue, (it) => `**${proseInline(it.title)}**`));
  }
  if (scheduledToday.length) {
    md.push('', '## On deck today');
    md.push(...bulletList(scheduledToday, (it) => proseInline(it.title)));
  }
  if (completedToday.length) {
    md.push('', '## Done today');
    md.push(...bulletList(completedToday, (it) => proseInline(it.title)));
  }

  return { markdown: md.join('\n').trim(), summary };
}

/**
 * Gather today's brief for one user. Pure-ish (only read queries); the bucket shape
 * is deterministic so the route and tests can assert it directly.
 *
 * `timezone` (IANA) scopes the day-window boundaries (today / overdue / scheduled / done)
 * to the user's LOCAL calendar day, so the buckets agree with the brief's LOCAL date +
 * heading (localBriefDate / localDateHeading in brief-authoring.service). Omitting it (or
 * passing 'UTC') keeps the legacy UTC window — the conservative fallback for a user who has
 * never stored a timezone. See dayWindowInTimezone for the DST-correct derivation.
 */
export async function gatherBrief(
  userId: string,
  now: Date,
  timezone: string = 'UTC',
  db: DatabaseQueryable = pool,
): Promise<DailyBrief> {
  const { start, end } = dayWindowInTimezone(now, timezone);
  const startIso = start.toISOString();
  const endIso = end.toISOString();

  // Active tasks: anything still open OR flagged blocked by a run. Bucketed in JS so
  // the blocked / overdue / scheduled-today split stays mutually exclusive.
  const activeResult = await db.query(
    `SELECT id, title, status, priority, run_status, start_date, type, stale_at
       FROM tasks
      WHERE user_id = $1::uuid
        AND type = 'task'
        AND (status IN ('pending', 'in_progress') OR run_status = 'blocked')
      ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END ASC,
               start_date ASC NULLS LAST
      LIMIT 200`,
    [userId],
  );

  const blocked: BriefItem[] = [];
  const overdue: BriefItem[] = [];
  const scheduledToday: BriefItem[] = [];

  for (const row of activeResult.rows) {
    // Mutual exclusivity: a task completed today belongs only in the Done bucket
    // (the completed query below), never in Blocked/Overdue/Today — even if it is
    // still flagged run_status='blocked'. Without this guard a completed+blocked
    // task double-counts (the Today/Done overlap the founder reported).
    if (row.status === 'completed') continue;
    // Blocked is the headline bucket — the unblock surface. A run that could not
    // complete is surfaced here and nowhere else, even if it is also past due.
    if (row.run_status === 'blocked') {
      blocked.push(toItem(row, 'blocked'));
      continue;
    }
    const startMs = row.start_date ? new Date(row.start_date).getTime() : null;
    if (startMs === null || Number.isNaN(startMs)) continue; // unscheduled inbox task — not today's concern
    // Overdue = start time already elapsed. Compare against `now`, NOT start-of-today:
    // a task due earlier *today* but past its time is overdue, mirroring the Agenda
    // (AgendaViewModel.statusBucket uses `start < now`). Using start-of-today here sent
    // those earlier-today tasks into scheduled_today, so the brief's "N overdue"
    // undercounted by one for every task due-but-passed today (the founder's 2-vs-3).
    if (startMs < now.getTime()) {
      overdue.push(toItem(row, 'overdue'));
    } else if (startMs < end.getTime()) {
      scheduledToday.push(toItem(row, 'scheduled_today'));
    }
    // start_date still in the future today, or after today → not overdue
  }

  // Calendar events scheduled inside today belong on the agenda's "today" line too.
  const eventsResult = await db.query(
    `SELECT id, title, status, priority, run_status, start_date, type, stale_at
       FROM tasks
      WHERE user_id = $1::uuid
        AND type = 'calendar_event'
        AND start_date >= $2::timestamptz
        AND start_date < $3::timestamptz
      ORDER BY start_date ASC
      LIMIT $4`,
    [userId, startIso, endIso, BUCKET_LIMIT],
  );
  for (const row of eventsResult.rows) {
    scheduledToday.push(toItem(row, 'scheduled_today'));
  }

  // Tasks completed today — the "done" half of the progress ring.
  const completedResult = await db.query(
    `SELECT id, title, status, priority, run_status, start_date, type, stale_at
       FROM tasks
      WHERE user_id = $1::uuid
        AND status = 'completed'
        AND updated_at >= $2::timestamptz
        AND updated_at < $3::timestamptz
      ORDER BY updated_at DESC
      LIMIT $4`,
    [userId, startIso, endIso, BUCKET_LIMIT],
  );
  const completedToday = completedResult.rows.map((r) => toItem(r, 'completed_today'));

  const cap = (items: BriefItem[]) => items.slice(0, BUCKET_LIMIT);
  const blockedC = cap(blocked);
  const overdueC = cap(overdue);
  const scheduledC = cap(scheduledToday);

  // Per-item latest AI activity: the most recent non-user comment on each surfaced
  // task, so the brief shows what Rem last did and the user can tap in to unblock.
  // One round-trip for all buckets, keyed by task id. Calendar events have no agent
  // activity in practice, but they share the tasks table so they're harmless to join.
  const activeItems = [...blockedC, ...overdueC, ...scheduledC, ...completedToday];
  const itemIds = [...new Set(activeItems.map((i) => i.id))];
  if (itemIds.length > 0) {
    const activityResult = await db.query(
      `SELECT DISTINCT ON (task_id)
              task_id, author_kind, author_label, body, created_at
         FROM task_comments
        WHERE user_id = $1::uuid
          AND task_id = ANY($2::uuid[])
          AND author_kind <> 'user'
        ORDER BY task_id, created_at DESC`,
      [userId, itemIds],
    );
    const byTask = new Map<string, BriefActivity>();
    for (const r of activityResult.rows) {
      byTask.set(r.task_id.toString(), {
        author_label: r.author_label,
        author_kind: r.author_kind,
        summary: summarizeActivity(r.body),
        created_at: toIso(r.created_at),
      });
    }
    for (const item of activeItems) {
      item.latest_activity = byTask.get(item.id) ?? null;
    }
  }

  const counts: BriefCounts = {
    blocked: blocked.length,
    overdue: overdue.length,
    scheduled_today: scheduledToday.length,
    completed_today: completedToday.length,
    total: scheduledToday.length + completedToday.length,
    done: completedToday.length,
  };

  const { markdown, summary } = composeBriefProse(
    counts,
    blockedC,
    overdueC,
    scheduledC,
    completedToday,
  );

  return {
    generated_at: now.toISOString(),
    window_start: startIso,
    window_end: endIso,
    counts,
    blocked: blockedC,
    overdue: overdueC,
    scheduled_today: scheduledC,
    completed_today: completedToday,
    markdown,
    summary,
  };
}
