-- Per-user "recently active" signal for the gateway keep-warm cron.
--
-- Before this, no single column recorded when a user last touched the app: usage_events
-- only fires on quota-consuming LLM turns (too narrow — a user reading their brief or
-- tapping around is active but books no usage event), and device_tokens.last_seen_at
-- tracks push-token refreshes, not app activity. The keep-warm job needs a broad,
-- cheap "did this user do ANYTHING in the last N minutes" signal so it can resume only
-- the Fly gateways of active users (cost-controlled) rather than the whole fleet.
--
-- requireJwt stamps this column (throttled, fire-and-forget) on every authenticated
-- request, so it reflects any app interaction. Nullable so existing rows need no backfill.
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_active_at TIMESTAMPTZ;

-- The keep-warm select is `WHERE last_active_at >= NOW() - INTERVAL 'N minutes'`.
CREATE INDEX IF NOT EXISTS idx_users_last_active_at ON users(last_active_at);
