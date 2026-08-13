-- Idempotency key for usage_events so spooled /usage/record retries from the
-- gateway can't double-count. Nullable + partial-unique: existing rows (and any
-- future call that omits event_id) keep the current insert-every-time behaviour,
-- while any row that DOES carry an event_id is deduplicated.
--
-- The service uses `INSERT ... ON CONFLICT (event_id) DO NOTHING`, which needs a
-- unique index on event_id. A partial index (WHERE event_id IS NOT NULL) lets
-- unlimited NULLs coexist while still enforcing uniqueness on real ids — and
-- makes ON CONFLICT (event_id) resolve to this arbiter index.
--
-- NOTE: run-migrations.ts wraps each file in a transaction, so CREATE INDEX
-- CONCURRENTLY is NOT usable here. usage_events is small/append-only, so a plain
-- (brief) index build is acceptable.

ALTER TABLE usage_events ADD COLUMN IF NOT EXISTS event_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_events_event_id
  ON usage_events (event_id)
  WHERE event_id IS NOT NULL;
