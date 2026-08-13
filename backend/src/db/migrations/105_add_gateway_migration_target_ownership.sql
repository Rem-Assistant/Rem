-- Recovery may delete the deterministic target app only after a successful strict Fly create
-- proves that this migration owns it. Existing/preview checkpoints default to fail-closed:
-- preserve an ambiguous target and restore the database-advertised source.
ALTER TABLE gateway_pool_migrations
  ADD COLUMN IF NOT EXISTS target_ownership_state TEXT NOT NULL DEFAULT 'unclaimed';
