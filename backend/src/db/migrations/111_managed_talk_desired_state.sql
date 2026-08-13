ALTER TABLE users
  ADD COLUMN IF NOT EXISTS managed_talk_desired_credential_fingerprint TEXT,
  ADD COLUMN IF NOT EXISTS managed_talk_credential_generation BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS managed_talk_reconcile_required BOOLEAN NOT NULL DEFAULT FALSE;

-- One durable in-progress assignment per user closes cross-replica double-claim races. Fail closed
-- if historical duplicates exist: silently recycling either row could expose user data or secrets.
CREATE UNIQUE INDEX IF NOT EXISTS idx_gateway_pool_one_claim_per_user
  ON gateway_pool (claimed_by)
  WHERE status = 'claimed' AND claimed_by IS NOT NULL;
