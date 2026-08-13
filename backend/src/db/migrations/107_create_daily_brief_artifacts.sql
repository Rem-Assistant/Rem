-- Recoverable daily-brief authoring + delivery state.
--
-- `daily_briefs` remains the fast read cache used by GET /brief. These tables own the slower
-- cross-process lifecycle: exactly one canonical artifact is authored per user/day/slot, and that
-- artifact is delivered to both the legacy per-day chat and durable chat during the client rollout.
-- Expiring leases recover automatically if a worker crashes after claiming work. Delivery identity
-- is stable, allowing the next worker to reconcile an ambiguous chat.inject result before retrying.

CREATE TABLE IF NOT EXISTS daily_brief_artifacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    brief_date DATE NOT NULL,
    authored_slot VARCHAR(16) NOT NULL CHECK (authored_slot IN ('morning', 'afternoon', 'evening')),
    markdown TEXT,
    summary TEXT,
    authoring_lease_token UUID,
    authoring_lease_expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, brief_date, authored_slot)
);

CREATE TABLE IF NOT EXISTS daily_brief_artifact_deliveries (
    artifact_id UUID REFERENCES daily_brief_artifacts(id) ON DELETE CASCADE NOT NULL,
    session_key VARCHAR(160) NOT NULL,
    state VARCHAR(16) NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'delivering', 'delivered')),
    lease_token UUID,
    lease_expires_at TIMESTAMPTZ,
    gateway_message_id VARCHAR(160),
    baseline_match_count INTEGER CHECK (baseline_match_count IS NULL OR baseline_match_count >= 0),
    last_error TEXT,
    delivered_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (artifact_id, session_key)
);

-- Keep migration 107 safe for PR/staging databases that applied an earlier preview revision.
ALTER TABLE daily_brief_artifact_deliveries
    ADD COLUMN IF NOT EXISTS baseline_match_count INTEGER
        CHECK (baseline_match_count IS NULL OR baseline_match_count >= 0);

CREATE INDEX IF NOT EXISTS idx_daily_brief_artifacts_user_date
    ON daily_brief_artifacts(user_id, brief_date DESC);
