-- AI-authored daily brief cache (docs/rebuild/27-BRIEF-AS-AI-AND-LANDING.md).
--
-- The daily brief's PROSE (`markdown`, the full-brief document the app expands into)
-- is written by the user's own gateway agent — not the deterministic template in
-- brief.service.ts. Because authoring runs a gateway turn (wake + up to 120s), it
-- cannot happen inside the fast GET /api/v1/brief handler; it runs ahead of time in a
-- flag-gated cron (run-brief-authoring.ts) and is CACHED here, then read back by the
-- GET. This mirrors the digests pipeline (migration 016) exactly: agent authors prose,
-- Postgres is the source of truth, iOS + Mac render the identical brief.
--
-- One row per user per UTC calendar day. Re-authoring the same day UPSERTs (a later
-- cron tick refreshes the prose as the day's tasks move). The buckets/counts the app
-- shows are NOT stored here — they stay live, computed per request from `tasks`.

CREATE TABLE IF NOT EXISTS daily_briefs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    -- The UTC calendar day this brief covers. We only ever read *today's* row, so a
    -- stale prior-day brief can never leak into the current brief.
    brief_date DATE NOT NULL,
    -- The AI-authored markdown prose (the full-brief document AssistantMarkdownView
    -- renders). Stored verbatim from the gateway turn.
    markdown TEXT NOT NULL,
    -- How the prose was produced: 'gateway' = written by the user's gateway agent.
    -- ('fallback' is reserved; today the read path falls back to the deterministic
    -- composer in-memory rather than persisting a fallback row — see the doc §1.5.)
    source VARCHAR(20) NOT NULL DEFAULT 'gateway' CHECK (source IN ('gateway', 'fallback')),
    model VARCHAR(120),
    -- The stable, loadable gateway session key (`rem-brief-<yyyymmdd>`, Move-2) whose
    -- turn produced this prose — so the brief the user reads IS a real chat.
    session_key VARCHAR(160),
    generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, brief_date)
);

CREATE INDEX IF NOT EXISTS idx_daily_briefs_user_date ON daily_briefs(user_id, brief_date DESC);
