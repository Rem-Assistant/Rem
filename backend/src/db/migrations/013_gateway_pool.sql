CREATE TABLE IF NOT EXISTS gateway_pool (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fly_app_name TEXT NOT NULL UNIQUE,
  machine_id TEXT,
  volume_id TEXT,
  setup_password TEXT NOT NULL,  -- AES-256-GCM encrypted via gateway.service encrypt()
  gateway_token TEXT NOT NULL,  -- AES-256-GCM encrypted via gateway.service encrypt()
  gateway_url TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'creating',  -- creating, available, claimed
  region TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  claimed_at TIMESTAMPTZ,
  claimed_by UUID REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_gateway_pool_status ON gateway_pool(status);
