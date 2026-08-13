-- A user/app reservation belongs to exactly one deploy pipeline. Backfill any provisional row
-- created by the first ownership rollout with an unguessable-enough stable legacy identity so a
-- new replica observes it as in-progress instead of taking it over.
ALTER TABLE gateway_fly_app_ownership
  ADD COLUMN IF NOT EXISTS provisioning_attempt_id TEXT;

UPDATE gateway_fly_app_ownership
   SET provisioning_attempt_id = 'legacy-' || md5(fly_app_name || created_at::text)
 WHERE state = 'provisioning'
   AND provisioning_attempt_id IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'gateway_fly_app_provisioning_attempt_required'
       AND conrelid = 'gateway_fly_app_ownership'::regclass
  ) THEN
    ALTER TABLE gateway_fly_app_ownership
      ADD CONSTRAINT gateway_fly_app_provisioning_attempt_required CHECK (
        state <> 'provisioning' OR provisioning_attempt_id IS NOT NULL
      );
  END IF;
END $$;
