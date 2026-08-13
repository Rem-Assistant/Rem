-- Separate request-counting rows from token-only rows in usage_events.
--
-- BACKGROUND (billing double-count, PR #972): a managed chat turn writes TWO
-- usage_events rows — one from /usage/consume (the app, before chat.send) and
-- one from /usage/record (the gateway llm_output hook, carrying tokens). Because
-- getUserUsage() counts requests with COUNT(*), the turn consumed TWO quota
-- slots and displayed doubled request usage.
--
-- FIX: a request counts once. The `/consume` row is the request row; the hook's
-- `/record` row is token-only and must NOT add to the request count — but its
-- tokens/cost still need to be summed for display and cost tracking.
--
-- `counts_as_request boolean NOT NULL DEFAULT true`:
--   * DEFAULT true is backward-compatible — every existing row (and any caller
--     that omits the flag, e.g. /consume, or a self-hosted /record) keeps
--     counting as a request exactly as before this migration.
--   * The gateway llm_output hook path (/usage/record) explicitly writes FALSE,
--     so per-turn token reports no longer inflate the request count.
--
-- getUserUsage() counts requests via COUNT(*) FILTER (WHERE counts_as_request)
-- and sums tokens across ALL rows. The partial index below keeps the request
-- count query fast on the hot path.

ALTER TABLE usage_events
  ADD COLUMN IF NOT EXISTS counts_as_request BOOLEAN NOT NULL DEFAULT true;

-- Speeds up the request-count query (COUNT FILTER counts_as_request) without
-- scanning the token-only rows.
CREATE INDEX IF NOT EXISTS idx_usage_events_user_request
  ON usage_events (user_id, created_at)
  WHERE counts_as_request;
