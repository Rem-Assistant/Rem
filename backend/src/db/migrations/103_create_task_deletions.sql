-- Durable per-user task deletion tombstones.
--
-- A paginated task list cannot safely prove deletion: it can be stale or mutate between
-- offset pages. Clients consume these explicit tombstones instead of deleting local tasks
-- merely because an id is absent from GET /tasks.
CREATE TABLE IF NOT EXISTS task_deletions (
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    task_id UUID NOT NULL,
    deleted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, task_id)
);

CREATE INDEX IF NOT EXISTS idx_task_deletions_user_deleted_at
    ON task_deletions(user_id, deleted_at DESC);

-- Serialize create/delete for the same user + task UUID and reject recreation after
-- a tombstone commits. DELETE acquires the same transaction-scoped advisory lock in
-- the route before removing the row and inserting its tombstone. Whichever operation
-- starts second therefore observes the first operation's committed state; deletion wins.
CREATE OR REPLACE FUNCTION prevent_tombstoned_task_recreation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended(NEW.user_id::text || ':' || NEW.id::text, 0)
    );
    IF EXISTS (
        SELECT 1
        FROM task_deletions
        WHERE user_id = NEW.user_id AND task_id = NEW.id
    ) THEN
        RAISE EXCEPTION 'task id was previously deleted' USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_tombstoned_task_recreation ON tasks;
CREATE TRIGGER trg_prevent_tombstoned_task_recreation
    BEFORE INSERT ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION prevent_tombstoned_task_recreation();
