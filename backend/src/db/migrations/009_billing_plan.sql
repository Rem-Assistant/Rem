-- Add billing plan to users table (for Apple IAP)
ALTER TABLE users ADD COLUMN IF NOT EXISTS billing_plan VARCHAR(20) DEFAULT 'free';
ALTER TABLE users ADD COLUMN IF NOT EXISTS billing_status VARCHAR(20) DEFAULT 'active';
ALTER TABLE users ADD COLUMN IF NOT EXISTS plan_started_at TIMESTAMPTZ DEFAULT NOW();

-- Add constraints only if columns are new (constraints may exist)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_billing_plan_check') THEN
    ALTER TABLE users ADD CONSTRAINT users_billing_plan_check CHECK (billing_plan IN ('free', 'pro', 'enterprise'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_billing_status_check') THEN
    ALTER TABLE users ADD CONSTRAINT users_billing_status_check CHECK (billing_status IN ('active', 'past_due', 'cancelled'));
  END IF;
END $$;

-- Backfill existing users to free plan
UPDATE users SET billing_plan = 'free', billing_status = 'active', plan_started_at = COALESCE(plan_started_at, NOW()) WHERE billing_plan IS NULL;

-- Usage tracking tables
CREATE TABLE IF NOT EXISTS usage_counters (
  id SERIAL PRIMARY KEY,
  user_id VARCHAR(255) NOT NULL,
  day DATE NOT NULL,
  minute_bucket TIMESTAMPTZ NOT NULL,
  request_count INT DEFAULT 0,
  prompt_tokens INT DEFAULT 0,
  completion_tokens INT DEFAULT 0,
  cost_cents INT DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, minute_bucket)
);

CREATE TABLE IF NOT EXISTS usage_events (
  id SERIAL PRIMARY KEY,
  user_id VARCHAR(255) NOT NULL,
  model VARCHAR(100) NOT NULL,
  prompt_tokens INT NOT NULL,
  completion_tokens INT NOT NULL,
  cost_cents INT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_usage_counters_user_day ON usage_counters(user_id, day);
CREATE INDEX IF NOT EXISTS idx_usage_events_user_created ON usage_events(user_id, created_at);
