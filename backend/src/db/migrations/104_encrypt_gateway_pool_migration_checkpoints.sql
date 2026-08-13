-- Compatibility for preview databases that applied an earlier, branch-only version of migration
-- 103 with a plaintext JSONB checkpoint. Production has never run the pooled migration. Refuse to
-- discard a real interrupted checkpoint; an operator must recover it before retrying this schema
-- migration.
ALTER TABLE gateway_pool_migrations
  ADD COLUMN IF NOT EXISTS original_source_config_encrypted TEXT;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM information_schema.columns
     WHERE table_schema = current_schema()
       AND table_name = 'gateway_pool_migrations'
       AND column_name = 'original_source_config'
  ) THEN
    IF EXISTS (SELECT 1 FROM gateway_pool_migrations) THEN
      RAISE EXCEPTION
        'gateway_pool_migrations contains plaintext checkpoints; recover them before migration 104';
    END IF;
    ALTER TABLE gateway_pool_migrations DROP COLUMN original_source_config;
  END IF;
END $$;

ALTER TABLE gateway_pool_migrations
  ALTER COLUMN original_source_config_encrypted SET NOT NULL;
