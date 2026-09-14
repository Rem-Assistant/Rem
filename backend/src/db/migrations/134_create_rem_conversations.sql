-- Rem-owned durable authority for ordinary conversations.
--
-- Gateway sessions cannot be the long-term product store once personal OpenClaw/Fly runtimes are
-- removed. These tables retain the user-visible lifecycle (create, list, rename, read, continue,
-- delete) in Rem's existing PostgreSQL account boundary. A deleted conversation keeps only its
-- tombstone row; the route atomically marks deletion and purges message content and runtime output so
-- a delayed create retry cannot resurrect private history.

CREATE TABLE IF NOT EXISTS rem_conversations (
    id UUID PRIMARY KEY,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    title TEXT CHECK (title IS NULL OR char_length(title) BETWEEN 1 AND 200),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    UNIQUE (id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_rem_conversations_user_updated
    ON rem_conversations (user_id, updated_at DESC, id DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS rem_conversation_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    seq BIGSERIAL,
    conversation_id UUID NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant', 'tool')),
    content TEXT NOT NULL CHECK (char_length(content) > 0),
    run_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (conversation_id, user_id)
        REFERENCES rem_conversations(id, user_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_rem_conversation_messages_conversation_seq
    ON rem_conversation_messages (conversation_id, seq);

CREATE UNIQUE INDEX IF NOT EXISTS idx_rem_conversation_messages_user_run_role
    ON rem_conversation_messages (user_id, run_id, role)
    WHERE run_id IS NOT NULL AND role IN ('user', 'assistant');
