ALTER TABLE users ADD COLUMN IF NOT EXISTS quota_cycle_started_at TIMESTAMPTZ;

UPDATE users
SET quota_cycle_started_at = COALESCE(plan_started_at, NOW())
WHERE quota_cycle_started_at IS NULL;

ALTER TABLE users ALTER COLUMN quota_cycle_started_at SET DEFAULT NOW();
ALTER TABLE users ALTER COLUMN quota_cycle_started_at SET NOT NULL;
