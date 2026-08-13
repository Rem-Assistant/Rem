-- Task staleness — "the brief has asked N times and you never touched it, so stop asking."
--
-- THE USER-VISIBLE PROBLEM. The founder: "My briefs don't feel intelligent because they've kept
-- asking for the same thing. The same three tasks that I never closed." Brief authoring gathers
-- every open task and renders it, every slot, forever. Nothing in the system has ever asked "is
-- this task still real?" — there was no counter, no decay, and no record that the user had already
-- been asked and never acted. That ABSENCE is the bug; the model was never the problem.
--
--
-- WHY A SEPARATE COLUMN AND NOT A NEW `tasks.status` VALUE.
--
-- The obvious move is `status = 'stale'`. It is wrong here, for three independent reasons.
--
--   1. IT WOULD MAKE THE TASK VANISH FROM THE APP. `status` is a filter, not a label, in every
--      consumer we have. All of these select on it, and every one of them would silently drop a
--      'stale' row (checked, one by one, before writing this migration):
--          brief.service.ts:278            status IN ('pending','in_progress')   → gone from Agenda
--          suggestions.service.ts:220      status IN ('pending','in_progress')   → gone from suggestions
--          digest.service.ts:391           status IN ('pending','in_progress')   → gone from the digest
--          orchestrator-sweep.service.ts:296,395  status = 'pending'             → never swept again
--          tasks.routes.ts GET /tasks      ?status= passthrough filter
--      "Stop nagging" must not mean "delete from the user's world". A task that disappears from
--      the app because a new status value is unhandled is a WORSE bug than the repetition.
--
--   2. IT WOULD DESTROY THE REAL STATUS, IRREVERSIBLY. `status` holds one value. Writing 'stale'
--      over 'in_progress' (or 'blocked') throws away the state the user actually set, with nothing
--      to restore it from — and the requirement is explicitly that a stale task stays recoverable.
--      Staleness is ORTHOGONAL to workflow state: a task can be pending-and-stale, in_progress-and-
--      stale, or blocked-and-stale. Orthogonal facts get their own column.
--
--   3. THE CLIENT WOULD MISREAD IT, QUIETLY. `TaskEvent.statusFromBackend` (RemClaw/Sources/Models/
--      TaskEvent.swift:143) ends in `default: TaskStatus(rawValue:) ?? .todo`. An unknown 'stale'
--      does not crash — it decodes as `.todo`. So the phone would render a stale task as an
--      ordinary to-do while the backend believed it had marked it. Silent disagreement between
--      client and server is the failure mode we keep paying for.
--
-- Widening `status` would also require re-widening `tasks_status_check`, `task_comments
-- .proposed_status` (015/021), `task_comments.previous_status` (028), the `PROPOSED_STATUSES` set
-- in tasks.routes.ts, and `TaskProposedStatus` in Shared/Models/TaskCollaboration.swift — five
-- constraint/enum edits to express one boolean. `status` stays exactly as migration 029 left it.
--
--
-- SEMANTICS.
--
--   brief_surface_count     How many AUTHORED BRIEFS have surfaced this task since the user last
--                           acted on it. Not "how many times was it read": incremented once per
--                           committed brief artifact (brief-authoring.service `completeBriefArtifact`
--                           succeeded), which the authoring lease already fences to at most once per
--                           (user, local day, slot). Opening the app and re-fetching
--                           GET /api/v1/brief does NOT count — that is a read, not a nag.
--
--   brief_last_surfaced_at  When the last such increment happened. Observability + the "quiet
--                           since" timestamp a future UI can render. Deliberately NOT reset by user
--                           action: it is history, not the counter.
--
--   stale_at                NON-NULL ⟺ THE TASK IS STALE. The single source of truth for the
--                           question "is this stale?" — a marker, not a second copy of the count.
--
-- WHY `stale_at` IS STORED RATHER THAN DERIVED from `brief_surface_count >= threshold`. The
-- threshold is a POLICY constant that lives in TypeScript and will be tuned. Deriving would make
-- every already-marked task silently un-mark itself the moment someone raises the threshold from 3
-- to 4 — a config edit retroactively rewriting user-visible state. A stamped marker cannot do that.
-- It also records WHEN we stopped asking, which a derived boolean cannot.
--
--
-- THRESHOLD = 3 (the constant lives in services/task-staleness.service.ts, not here).
-- `AUTHORING_SLOT_START_HOURS` gives at most three authored briefs a day (morning / afternoon /
-- evening), and the counter advances at most once per slot. So 3 means: "Rem raised this in three
-- separate briefs — at minimum one full day, more typically two or three — and you did not touch it
-- once." Two is too twitchy (skipping a morning and an afternoon on a busy day is normal, not a
-- signal). Four or more means over a day of visible nagging past the point the user's silence was
-- already an answer. It also lands exactly where the founder's own complaint landed: "the same
-- three tasks."
--
--
-- RESET. Any USER action on a task clears `brief_surface_count` to 0 and `stale_at` to NULL —
-- edit, reschedule, priority change, status change, completion, filing it into a list, commenting
-- on it, or dispatching an agent run on it. A task the user touched is not stale, and a task that
-- goes stale must be able to come back. The reset is written EXPLICITLY at each user-facing route,
-- NOT as a row trigger on `updated_at`: the orchestrator sweep and agent-run completion also write
-- `updated_at`, and a machine deciding on its own to re-nag the user is precisely what this
-- migration exists to stop. See `resetTaskStaleness` for the exact enumeration.
--
--
-- Additive, idempotent, backfill-free: every existing row starts at 0 surfacings / NULL stale_at,
-- which is exactly "this task has never been nagged about yet" — the state a fresh task is in.

ALTER TABLE tasks
    ADD COLUMN IF NOT EXISTS brief_surface_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS brief_last_surfaced_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS stale_at TIMESTAMPTZ;

ALTER TABLE tasks
    DROP CONSTRAINT IF EXISTS tasks_brief_surface_count_check;

ALTER TABLE tasks
    ADD CONSTRAINT tasks_brief_surface_count_check
    CHECK (brief_surface_count >= 0);
