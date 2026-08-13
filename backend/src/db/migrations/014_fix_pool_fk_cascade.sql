-- Fix: gateway_pool.claimed_by foreign key blocks user deletion.
-- Change to ON DELETE SET NULL so deleting a user doesn't fail.
ALTER TABLE gateway_pool
  DROP CONSTRAINT IF EXISTS gateway_pool_claimed_by_fkey;

ALTER TABLE gateway_pool
  ADD CONSTRAINT gateway_pool_claimed_by_fkey
  FOREIGN KEY (claimed_by) REFERENCES users(id) ON DELETE SET NULL;
