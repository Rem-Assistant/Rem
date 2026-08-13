-- Trusted backend-owned input provenance for authored Daily Brief artifacts.
-- The manifest is written only by the artifact lease holder and excludes provider text; client-
-- writable suggestion signals are intentionally not evidence that connector data was collected.
ALTER TABLE daily_brief_artifacts
    ADD COLUMN IF NOT EXISTS input_producer VARCHAR(64) NOT NULL DEFAULT 'remclaw-backend',
    ADD COLUMN IF NOT EXISTS input_manifest JSONB,
    ADD COLUMN IF NOT EXISTS input_fingerprint CHAR(64),
    ADD COLUMN IF NOT EXISTS input_captured_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS authoring_producer VARCHAR(64) NOT NULL DEFAULT 'gateway',
    ADD COLUMN IF NOT EXISTS authoring_model TEXT;

ALTER TABLE daily_brief_artifacts
    DROP CONSTRAINT IF EXISTS daily_brief_artifacts_input_fingerprint_check;
ALTER TABLE daily_brief_artifacts
    ADD CONSTRAINT daily_brief_artifacts_input_fingerprint_check
    CHECK (input_fingerprint IS NULL OR input_fingerprint ~ '^[0-9a-f]{64}$');
