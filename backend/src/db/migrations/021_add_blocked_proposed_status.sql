-- Add 'blocked' to the set of statuses a comment may propose for its task.
-- An agent that needs information (e.g. "I need the filing details before I can
-- continue") is BLOCKED, not in_progress — a real structured proposal it emits,
-- not an error (see docs/agentbox/CONTRACT.md §3.3, principle 5).
--
-- Migration 015 created the CHECK constraint inline on the column with the system
-- name `task_comments_proposed_status_check`. We drop and re-add it widened.
-- Idempotent + additive: safe to re-run.

ALTER TABLE task_comments
    DROP CONSTRAINT IF EXISTS task_comments_proposed_status_check;

ALTER TABLE task_comments
    ADD CONSTRAINT task_comments_proposed_status_check
    CHECK (
        proposed_status IS NULL
        OR proposed_status IN ('pending', 'in_progress', 'completed', 'cancelled', 'blocked')
    );
