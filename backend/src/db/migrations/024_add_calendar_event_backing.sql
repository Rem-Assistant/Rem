-- Make calendar events "workable": an Activity thread (task_comments) + agent runs
-- can attach to a CALENDAR EVENT via a lightweight backing task row. When the user
-- first "works" an event (Run now / "Let Rem work this"), the client find-or-creates
-- a task of type 'calendar_event' keyed by the calendar's event id; comments and the
-- agent-run path then work unchanged against that row. App-side only — the backing
-- never mutates the underlying calendar event.
--
-- Idempotent: repeated "Run now" on the same event reuses one row (one thread) via
-- ON CONFLICT (user_id, calendar_event_id). See tasks.routes.ts POST /tasks/event-backing.
-- Foundation slice (#868 follow-up); richer event/task unification is a later step.

ALTER TABLE tasks ADD COLUMN IF NOT EXISTS calendar_event_id TEXT;

-- One backing task per (user, calendar event). Partial unique index so ordinary
-- tasks (NULL calendar_event_id) stay unconstrained, while the find-or-create can
-- infer this index in `ON CONFLICT (user_id, calendar_event_id)` to stay idempotent.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_user_calendar_event
    ON tasks(user_id, calendar_event_id) WHERE calendar_event_id IS NOT NULL;
