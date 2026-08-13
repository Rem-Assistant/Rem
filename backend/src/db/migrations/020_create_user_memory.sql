-- "What Rem remembers about you" — the simple, user-managed memory store ("Dreaming").
--
-- A `user_memory` row is a single durable fact Rem keeps about the user (preferences,
-- relationships, working hours, "calls my mom Sunday", etc). The Settings screen lets the
-- user add / edit / delete these facts directly, so the list is the user's own source of
-- truth. The follow-up (not in this slice) is auto-extraction: writing 2-3 facts after each
-- chat/session, attributed via `source`. The schema is already shaped for that — `source`
-- distinguishes a user-typed fact (NULL / 'user') from a future agent-extracted one.
--
-- Source of truth = backend Postgres, same as tasks/digests, so iOS and Mac render the
-- identical memory list.

CREATE TABLE IF NOT EXISTS user_memory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    fact TEXT NOT NULL,
    -- How the fact was captured: NULL / 'user' = the user typed it in Settings; a future
    -- auto-extraction pass would stamp e.g. 'chat' or 'session' here for attribution.
    source TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_memory_user_id_created_at ON user_memory(user_id, created_at DESC);
