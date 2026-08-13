/**
 * Task staleness — the brief stops asking about a task the user keeps ignoring.
 *
 * THE PROBLEM (founder's words): "My briefs don't feel intelligent because they've kept asking for
 * the same thing. The same three tasks that I never closed." Nothing in the system asked "is this
 * task still real?" — brief authoring gathered every open task and rendered it, every slot, forever.
 * There was no counter, no decay, and no record that the user had already been asked N times and
 * never acted. This module is that missing record.
 *
 * SOURCE OF TRUTH: `tasks.brief_surface_count` and `tasks.stale_at` (migration 116). Nothing is
 * cached in process; every worker and every replica reads the same two columns. The migration file
 * carries the full argument for why staleness is a SEPARATE column rather than a new `tasks.status`
 * value (short version: `status` is a filter in five different consumers, so 'stale' would make the
 * task vanish from the app — a worse bug than the repetition — and would overwrite the user's real
 * status irreversibly).
 *
 * STATE TRANSITIONS.
 *
 *   fresh (count = 0, stale_at NULL)
 *      │  an authored brief surfaces the task            → recordBriefSurfacing
 *      ▼
 *   nagged (0 < count < THRESHOLD, stale_at NULL)
 *      │  count reaches THRESHOLD                        → recordBriefSurfacing stamps stale_at
 *      ▼
 *   stale (stale_at NOT NULL)  ── excluded from the brief's authoring context, still returned by
 *      │                          GET /api/v1/tasks and still present in GET /api/v1/brief buckets
 *      │                          (flagged `is_stale`). Never deleted, never auto-completed.
 *      │  the user touches the task                      → resetTaskStaleness
 *      ▼
 *   fresh again (count = 0, stale_at NULL)
 *
 * RECOVERY. Both writes are single idempotent-in-effect statements with no read-modify-write in
 * application code, so a crashed cron worker or a duplicated request cannot strand a task in a
 * half-state. A surfacing that fails to record costs the user one extra ask; the caller therefore
 * treats a failure as non-fatal rather than failing the brief (`brief-authoring.service`).
 *
 * NON-GOALS. Staleness does not delete, archive, auto-complete, or auto-cancel anything — "stale"
 * means "stop nagging", not "decide for them". It does not change `tasks.status`. It does not
 * change WHICH rows GET /api/v1/tasks returns.
 *
 * It does add one FIELD to what that route returns: `formatTask` serializes `stale_at` alongside
 * `status` so the client can de-emphasise a stale row and label it. That is not a walk-back of the
 * line above — the row set is identical, and `stale_at` is reported next to the real status rather
 * than in place of it. Without it the client cannot tell a stale task from a live one, which is the
 * half of this feature the user actually sees. See `Shared/Models/TaskDeemphasis.swift`.
 */

import { pool, type DatabaseQueryable } from '../db/pool.js';
import type { BriefItem, DailyBrief } from './brief.service.js';

/**
 * How many authored briefs may surface a task, with no user action in between, before Rem stops
 * bringing it up.
 *
 * WHY 3. `AUTHORING_SLOT_START_HOURS` (brief-authoring.service.ts) gives at most three authored
 * briefs per local day — morning, afternoon, evening — and `recordBriefSurfacing` advances the
 * counter at most once per authored brief. So the threshold reads as: "Rem raised this in three
 * separate briefs, spanning at least one full day and typically two or three, and the user did not
 * touch it once." Two is too twitchy — skipping a morning and an afternoon on a busy day is normal
 * behaviour, not a signal. Four or more is a further half-day-plus of nagging past the point where
 * the user's silence had already answered. Three is also exactly where the founder's own complaint
 * landed ("the same three tasks").
 *
 * Raising this later is safe: `stale_at` is STAMPED, not derived, so already-stale tasks do not
 * silently un-stale themselves when the constant moves.
 */
export const BRIEF_STALE_THRESHOLD = 3;

export interface BriefSurfacingOutcome {
  /** Task ids whose counter advanced on this call. */
  counted: string[];
  /** Task ids that crossed the threshold on this call and are now stale. */
  markedStale: string[];
}

/**
 * Record that an AUTHORED BRIEF surfaced these tasks without the user having acted since the last
 * time we asked.
 *
 * WHAT COUNTS AS "SURFACED". Exactly one thing: a brief artifact was committed for a
 * (user, local day, slot) — i.e. `completeBriefArtifact` returned an artifact. That write is already
 * fenced by the authoring lease, so the count advances at most once per brief the user is actually
 * shown. Deliberately NOT counted:
 *   - `gatherBrief` / GET /api/v1/brief. The app re-fetches the brief on every foreground; counting
 *     reads would make staleness a function of how often the user opens Rem, which is backwards —
 *     an engaged user would have their tasks expire fastest.
 *   - Redelivery retries (`deliverBriefArtifactForRollout` on an already-authored slot). The same
 *     brief being pushed again is one ask, not two.
 *   - Empty or skipped authoring runs. If no brief was written, nothing was asked.
 *
 * Tasks already stale are excluded by the `stale_at IS NULL` predicate: they are no longer in the
 * brief's authoring context, so their counter must stop rather than drift upward forever.
 *
 * ONE STATEMENT, on purpose. The increment and the threshold test happen inside the same UPDATE, so
 * two overlapping cron workers serialize on the row lock and read back 2 and 3 rather than both
 * reading 2 and both writing 3. A read-compare-write in TypeScript would lose a surfacing (and, at
 * the boundary, fail to mark a task stale at all).
 *
 * `COALESCE(stale_at, ...)` rather than a bare assignment so a re-entrant call can never move an
 * existing stale timestamp forward — the marker records when we FIRST stopped asking.
 *
 * Note that `updated_at` is intentionally left alone. It is the cursor for the client's delta sync
 * (`GET /api/v1/tasks?since=`) and for the brief's completed-today window; a machine-side bookkeeping
 * write must not masquerade as a user edit. The client learns about staleness through the brief's
 * `is_stale` flag, which is refetched wholesale.
 */
export async function recordBriefSurfacing(
  userId: string,
  taskIds: readonly string[],
  now: Date,
  db: DatabaseQueryable = pool,
  threshold: number = BRIEF_STALE_THRESHOLD,
): Promise<BriefSurfacingOutcome> {
  const ids = [...new Set(taskIds)];
  if (ids.length === 0) return { counted: [], markedStale: [] };

  const result = await db.query<{ id: string; brief_surface_count: number; newly_stale: boolean }>(
    `UPDATE tasks
        SET brief_surface_count = brief_surface_count + 1,
            brief_last_surfaced_at = $3::timestamptz,
            stale_at = CASE
              WHEN brief_surface_count + 1 >= $4 THEN COALESCE(stale_at, $3::timestamptz)
              ELSE stale_at
            END
      WHERE user_id = $1::uuid
        AND id = ANY($2::uuid[])
        AND stale_at IS NULL
      RETURNING id, brief_surface_count, (stale_at IS NOT NULL) AS newly_stale`,
    [userId, ids, now.toISOString(), threshold],
  );

  const counted: string[] = [];
  const markedStale: string[] = [];
  for (const row of result.rows) {
    const id = row.id.toString();
    counted.push(id);
    if (row.newly_stale) markedStale.push(id);
  }
  return { counted, markedStale };
}

/**
 * Clear the nag counter and un-stale a task because THE USER ACTED ON IT.
 *
 * WHAT COUNTS AS A USER ACTION — the exhaustive list, and why each one is on it. Every caller is a
 * `requireJwt` route, i.e. a request the person made from their own device:
 *   - PATCH  /api/v1/tasks/:id            editing the title, priority, status, any date, the
 *                                         duration, the repeat rule, or the list it is filed in.
 *                                         Reschedule and completion are both just this. Folded into
 *                                         that route's own UPDATE so the reset is atomic with the
 *                                         edit and cannot be forgotten on a new field.
 *   - POST   /api/v1/tasks/:id/comments   the user wrote about the task (author_kind = 'user').
 *                                         Talking about it is engaging with it.
 *   - POST   /api/v1/tasks/:id/agent-run  the user tapped "run" on this task. The RUN is machine
 *                                         work, but the DISPATCH is a deliberate human act on this
 *                                         specific task, so it resets.
 *
 * And what deliberately does NOT reset:
 *   - `orchestrator-sweep.service.ts` writes (run_status transitions, heartbeats, agent-applied
 *     statuses from an autonomous sweep). Rem deciding on its own to touch a row must not buy that
 *     row three more chances to nag — that is the loop this feature exists to break.
 *   - Reading the task, or the brief surfacing it. Being shown something is not acting on it; that
 *     is the entire premise.
 *   - Deleting the task (DELETE /api/v1/tasks/:id) — the row is gone, so there is nothing to reset.
 *
 * This is why the reset is written explicitly at each route instead of as a row trigger on
 * `updated_at`: the sweep writes `updated_at` too, and a trigger could not tell the two apart.
 *
 * Returns true when a row was actually reset (ownership-scoped by `user_id`, so another user's task
 * id is a no-op rather than a cross-tenant write).
 */
export async function resetTaskStaleness(
  userId: string,
  taskId: string,
  db: DatabaseQueryable = pool,
): Promise<boolean> {
  // `RETURNING id` rather than `rowCount` so the answer comes from data every driver reports the
  // same way — `rowCount` is a node-pg field that other Postgres clients (including the PGlite
  // engine the tests run the real statements against) simply do not populate, which would make this
  // silently return false on a row it had just reset.
  const result = await db.query(
    `${RESET_STALENESS_SQL}
      WHERE id = $1::uuid AND user_id = $2::uuid
      RETURNING id`,
    [taskId, userId],
  );
  return result.rows.length > 0;
}

/**
 * The SET clause fragment shared by `resetTaskStaleness` and PATCH /api/v1/tasks/:id, so the two
 * paths cannot drift into resetting different columns.
 *
 * `brief_last_surfaced_at` is NOT cleared: it is history ("Rem last raised this on Tuesday"), not
 * part of the counter. Only the count and the marker are user-clearable state.
 */
export const RESET_STALENESS_SET_CLAUSES = ['brief_surface_count = 0', 'stale_at = NULL'] as const;

/**
 * The STANDALONE reset, used when no other statement is already touching the row (currently the
 * comment route). It adds `updated_at = NOW()`; the shared clause list above deliberately does not.
 *
 * WHY `updated_at` BELONGS HERE. Un-staling is a USER-VISIBLE STATE CHANGE — the client drops the
 * row's de-emphasis and its "Stale" badge — and `GET /api/v1/tasks?since=` filters on `updated_at`.
 * Without this bump, un-staling by commenting is permanently invisible to any `since=`-scoped
 * consumer: the row is never re-sent, so the badge never clears. iOS currently passes `since: nil`
 * and heals on the full pull, but that is luck, not a design — fixed at the SQL so no future delta
 * consumer inherits the trap.
 *
 * WHY NOT IN `RESET_STALENESS_SET_CLAUSES`. The other two callers (PATCH /tasks/:id and the
 * agent-run dispatch) already write `updated_at = NOW()` in their own SET lists. Adding it to the
 * shared fragment would assign the same column twice in one UPDATE, which Postgres rejects outright.
 *
 * This does NOT contradict `recordBriefSurfacing` leaving `updated_at` alone. That is a machine-side
 * bookkeeping increment which must not masquerade as a user edit; this is the user edit.
 */
const RESET_STALENESS_SQL = `UPDATE tasks SET ${RESET_STALENESS_SET_CLAUSES.join(', ')}, updated_at = NOW()`;

// MARK: - Applying staleness to the brief

/**
 * The ids a committed brief actually NAGGED the user about — the argument to
 * `recordBriefSurfacing`.
 *
 * Only the three open buckets count. `completed_today` is excluded because a completed task is the
 * opposite of an unanswered ask (and the user's completion already reset it). Calendar events
 * (`type === 'calendar_event'`) are excluded because they are not asks: nobody "closes" a birthday,
 * and they fall out of the brief by themselves once the day passes, so counting them would let a
 * recurring event age into staleness for no reason.
 */
export function briefSurfacedTaskIds(brief: DailyBrief): string[] {
  const surfaced = [...brief.blocked, ...brief.overdue, ...brief.scheduled_today];
  return [...new Set(surfaced.filter((item) => item.type === 'task').map((item) => item.id))];
}

/**
 * Drop already-stale tasks from a gathered brief, returning the view the AUTHORING turn is given.
 *
 * This is the payoff: the model can only write about what it is handed, so removing stale items
 * here is what makes the brief actually stop repeating itself. It is applied at the authoring
 * boundary and NOWHERE ELSE — `gatherBrief` and GET /api/v1/brief keep returning every open task
 * (flagged `is_stale`), so nothing disappears from the Agenda and the user can still open, edit, or
 * complete a stale task and bring it straight back.
 *
 * COUNTS ARE RECOMPUTED on the filtered buckets, deliberately. The prompt hands the model a
 * headline count line; if the counts still said "3 on deck" while only 2 were listed, the model
 * would invent the third. The visible consequence is that the Agenda's chips (which read the
 * unfiltered GET /api/v1/brief) can show a higher "today" count than the prose discusses. That is
 * the intended split — the chips count everything on your plate, the prose only raises what Rem has
 * not already asked about three times — but it is a real product-visible divergence and should be
 * confirmed with design before this reaches users.
 *
 * Pure: returns a new object, never mutates the input.
 */
export function briefWithoutStaleTasks(brief: DailyBrief): DailyBrief {
  const fresh = (items: BriefItem[]) => items.filter((item) => !item.is_stale);
  const blocked = fresh(brief.blocked);
  const overdue = fresh(brief.overdue);
  const scheduledToday = fresh(brief.scheduled_today);
  // `completed_today` is left untouched: a completed task is not being nagged about, and hiding a
  // stale-then-completed task would under-report the day's "done" half of the ring.
  const completedToday = brief.completed_today;

  if (
    blocked.length === brief.blocked.length
    && overdue.length === brief.overdue.length
    && scheduledToday.length === brief.scheduled_today.length
  ) {
    return brief;
  }

  return {
    ...brief,
    blocked,
    overdue,
    scheduled_today: scheduledToday,
    completed_today: completedToday,
    counts: {
      ...brief.counts,
      blocked: blocked.length,
      overdue: overdue.length,
      scheduled_today: scheduledToday.length,
      completed_today: completedToday.length,
      total: scheduledToday.length + completedToday.length,
      done: completedToday.length,
    },
  };
}
