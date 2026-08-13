-- Persist a REPLAYABLE transcript for each cloud (AgentBox) run against a task, so
-- the task's chat can open the *actual* prior conversation — not an empty composer
-- with a prefilled nudge (#874 / #869).
--
-- Root cause this fixes: a cloud run executes in the GMI AgentBox namespace, never
-- on the user's per-user gateway. Only the run's FINAL reply was persisted (as the
-- `task_comments` body); the run's conversation turns (the ask + Rem's reply) were
-- never stored anywhere the device could replay. `comment.session_id` is a backend
-- run UUID, not a gateway session key, so routing the chat at it loads no messages.
--
-- This table is the device-reachable home for those turns. The agent-run route
-- appends the user ask + the assistant reply (and, when available, tool turns) here
-- keyed by task id + run id; the device loads them via GET /tasks/:id/chat and
-- renders them as real prior messages in the task-scoped continuation chat.
--
-- `seq` (BIGSERIAL) gives a stable, monotonic intra-run ordering: the user ask and
-- the assistant reply of one run share a created_at (DEFAULT NOW()), so ordering by
-- created_at alone could interleave them — order by seq to keep ask-before-reply.
--
-- Idempotent + additive (CREATE TABLE / INDEX IF NOT EXISTS). 025 is the next free
-- migration number (024 = add_calendar_event_backing). See docs/agentbox/CONTRACT.md.

CREATE TABLE IF NOT EXISTS task_chat_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    seq BIGSERIAL,
    task_id UUID REFERENCES tasks(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    role VARCHAR(20) NOT NULL
        CHECK (role IN ('user', 'assistant', 'tool')),
    content TEXT NOT NULL,
    -- The run this turn belongs to (mirrors task_comments.session_id / tasks.run_id).
    -- NULL-safe: a turn not tied to a specific run (future paths) leaves it NULL.
    run_id UUID,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_task_chat_messages_task_seq
    ON task_chat_messages(task_id, seq);
CREATE INDEX IF NOT EXISTS idx_task_chat_messages_user_id
    ON task_chat_messages(user_id);
