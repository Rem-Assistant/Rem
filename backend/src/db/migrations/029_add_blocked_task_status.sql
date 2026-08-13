-- Add 'blocked' to the set of statuses a TASK (not just a comment proposal) may hold.
-- Migration 021 already widened `task_comments.proposed_status` to allow 'blocked';
-- this widens the canonical `tasks.status` column so an agent (or the human, via the
-- status menu-picker) can actually SET a task to blocked — the agent now APPLIES the
-- status it decides on rather than only proposing it. 'blocked' = the task can't
-- proceed (needs info / waiting on an input), a real status, not an error (principle 5).
--
-- Migration 006 created the CHECK constraint inline on the column with the system
-- name `tasks_status_check`. We drop and re-add it widened. Idempotent + additive.

ALTER TABLE tasks
    DROP CONSTRAINT IF EXISTS tasks_status_check;

ALTER TABLE tasks
    ADD CONSTRAINT tasks_status_check
    CHECK (status IN ('pending', 'in_progress', 'completed', 'cancelled', 'blocked'));
