CREATE TABLE IF NOT EXISTS gateway_pool_migrations (
  user_id UUID PRIMARY KEY,
  source_app_name TEXT NOT NULL,
  source_machine_id TEXT NOT NULL,
  target_app_name TEXT NOT NULL,
  original_source_config_encrypted TEXT NOT NULL,
  original_source_state TEXT NOT NULL,
  target_ownership_state TEXT NOT NULL DEFAULT 'unclaimed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gateway_pool_migrations_created_at
  ON gateway_pool_migrations(created_at);
