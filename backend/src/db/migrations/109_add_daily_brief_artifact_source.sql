-- Track whether a canonical brief artifact came from a gateway model turn or from the
-- deterministic all-clear composer. Existing artifacts predate deterministic persistence and
-- are therefore gateway-authored.

ALTER TABLE daily_brief_artifacts
    ADD COLUMN IF NOT EXISTS source VARCHAR(20) NOT NULL DEFAULT 'gateway';

-- Delivery preparation and same-slot replacement coordinate on this artifact-row fence. Keeping
-- the guard on the conflict target itself avoids READ COMMITTED cross-table snapshot races.
ALTER TABLE daily_brief_artifacts
    ADD COLUMN IF NOT EXISTS delivery_fence_expires_at TIMESTAMPTZ;

ALTER TABLE daily_brief_artifacts
    ADD COLUMN IF NOT EXISTS revision UUID NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE daily_brief_artifact_deliveries
    ADD COLUMN IF NOT EXISTS artifact_revision UUID;

UPDATE daily_brief_artifact_deliveries d
   SET artifact_revision = a.revision
  FROM daily_brief_artifacts a
 WHERE d.artifact_id = a.id AND d.artifact_revision IS NULL;

ALTER TABLE daily_brief_artifact_deliveries
    ALTER COLUMN artifact_revision SET NOT NULL;

DO $$
BEGIN
    ALTER TABLE daily_brief_artifacts
        ADD CONSTRAINT daily_brief_artifacts_source_check
        CHECK (source IN ('gateway', 'fallback'));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
