CREATE TABLE IF NOT EXISTS gateway_lifecycle_waiters (
  token UUID PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_gateway_lifecycle_waiters_user_queue
  ON gateway_lifecycle_waiters(user_id, created_at, token);

CREATE INDEX IF NOT EXISTS idx_gateway_lifecycle_waiters_expiry
  ON gateway_lifecycle_waiters(expires_at);
