-- Task collaboration: comments authored by the user, cloud agents (GMI AgentBox),
-- and local runtimes (Mac/iOS gateway). The task becomes a long-lived object that
-- multiple runtimes act on and leave attributed comments against.
-- See docs/agentbox/CONTRACT.md.

CREATE TABLE IF NOT EXISTS task_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID REFERENCES tasks(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    author_kind VARCHAR(20) NOT NULL DEFAULT 'user'
        CHECK (author_kind IN ('user', 'cloud_agent', 'local_runtime')),
    author_label VARCHAR(120) NOT NULL DEFAULT 'You',
    body TEXT NOT NULL,
    proposed_status VARCHAR(20)
        CHECK (proposed_status IS NULL OR proposed_status IN ('pending', 'in_progress', 'completed', 'cancelled')),
    runtime VARCHAR(20)
        CHECK (runtime IS NULL OR runtime IN ('agentbox', 'local_mac', 'local_ios')),
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_task_comments_task_id ON task_comments(task_id);
CREATE INDEX IF NOT EXISTS idx_task_comments_user_id ON task_comments(user_id);
CREATE INDEX IF NOT EXISTS idx_task_comments_created_at ON task_comments(created_at);

-- Which runtime currently owns execution of a task (drives the local-vs-cloud demo).
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS assigned_runtime VARCHAR(20)
    CHECK (assigned_runtime IS NULL OR assigned_runtime IN ('agentbox', 'local_mac', 'local_ios'));
