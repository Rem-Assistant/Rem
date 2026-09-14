-- Durable, user-approved task mutations proposed inside ordinary Rem conversations.
--
-- The observe runtime may describe one exact tasks.update operation, but it receives no acting
-- authority. The normalized proposal is retained here with the task revision the model observed.
-- Only a later authenticated approve request can mint a one-use capability grant and dispatch the
-- existing audited adapter. Conversation deletion cascades the proposal; task deletion does not,
-- so history can still explain why a pending proposal became inapplicable.

CREATE UNIQUE INDEX IF NOT EXISTS idx_rem_conversation_messages_proposal_owner
    ON rem_conversation_messages (id, conversation_id, user_id);

CREATE TABLE IF NOT EXISTS rem_conversation_task_proposals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    assistant_message_id UUID NOT NULL,
    proposal_run_id UUID NOT NULL,
    tool_call_id TEXT NOT NULL CHECK (char_length(tool_call_id) BETWEEN 1 AND 256),
    task_id UUID NOT NULL,
    task_title TEXT NOT NULL CHECK (char_length(task_title) BETWEEN 1 AND 500),
    proposed_status VARCHAR(20) NOT NULL
        CHECK (proposed_status IN ('pending', 'in_progress', 'completed', 'blocked')),
    expected_task_status VARCHAR(20) NOT NULL,
    expected_task_updated_at TIMESTAMPTZ NOT NULL,
    explanation TEXT NOT NULL CHECK (char_length(explanation) BETWEEN 1 AND 2000),
    state VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'succeeded', 'failed', 'dismissed')),
    -- Audit lineage intentionally has no FK: effect/run retention and environment-copy policy may
    -- prune those rows while the user-visible conversation history remains durable.
    effect_id UUID,
    failure_code TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    FOREIGN KEY (conversation_id, user_id)
        REFERENCES rem_conversations(id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (assistant_message_id, conversation_id, user_id)
        REFERENCES rem_conversation_messages(id, conversation_id, user_id) ON DELETE CASCADE,
    UNIQUE (assistant_message_id),
    UNIQUE (user_id, proposal_run_id, tool_call_id),
    UNIQUE (effect_id),
    CHECK (
        (state = 'pending' AND effect_id IS NULL AND failure_code IS NULL AND resolved_at IS NULL)
        OR (state = 'succeeded' AND effect_id IS NOT NULL AND failure_code IS NULL AND resolved_at IS NOT NULL)
        OR (state = 'failed' AND failure_code IS NOT NULL AND resolved_at IS NOT NULL)
        OR (state = 'dismissed' AND effect_id IS NULL AND failure_code IS NULL AND resolved_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_rem_conversation_task_proposals_conversation
    ON rem_conversation_task_proposals (conversation_id, created_at, id);

CREATE INDEX IF NOT EXISTS idx_rem_conversation_task_proposals_pending
    ON rem_conversation_task_proposals (user_id, created_at)
    WHERE state = 'pending';
