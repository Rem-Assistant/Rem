-- Durable ownership for Fly apps that exist before the users.gateway_url pointer is committed or
-- must survive deletion of that user. The row is intentionally not deleted with users: account
-- deletion sets user_id to NULL and scheduled cleanup keeps retrying until Fly confirms deletion.
CREATE TABLE IF NOT EXISTS gateway_fly_app_ownership (
  fly_app_name TEXT PRIMARY KEY,
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  state TEXT NOT NULL CHECK (state IN ('provisioning', 'canonical', 'delete_pending')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_gateway_fly_app_ownership_user
  ON gateway_fly_app_ownership (user_id);

CREATE INDEX IF NOT EXISTS idx_gateway_fly_app_ownership_cleanup
  ON gateway_fly_app_ownership (state, updated_at);
