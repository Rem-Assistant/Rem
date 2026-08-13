-- AI autonomy: the cloud agent now APPLIES the status it decides on directly to the
-- task (`tasks.status`) instead of merely proposing it for the human to Accept. To
-- keep that reversible, the comment records the task's status *before* the agent
-- changed it — the one-tap Undo target the client renders beside "Applied: <status>".
--
-- `previous_status` is non-null ONLY on a comment whose run actually changed the task
-- status. It is therefore both the marker that "this run applied a status" (→ render
-- Applied + Undo) and the value Undo reverts to. NULL on human comments, on runs that
-- proposed nothing, and on runs whose proposal matched the current status (no change).
-- Additive + idempotent.

ALTER TABLE task_comments
    ADD COLUMN IF NOT EXISTS previous_status VARCHAR(20);

ALTER TABLE task_comments
    DROP CONSTRAINT IF EXISTS task_comments_previous_status_check;

ALTER TABLE task_comments
    ADD CONSTRAINT task_comments_previous_status_check
    CHECK (
        previous_status IS NULL
        OR previous_status IN ('pending', 'in_progress', 'completed', 'cancelled', 'blocked')
    );
