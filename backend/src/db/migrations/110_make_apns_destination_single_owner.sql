-- One physical APNs destination must never remain subscribed to two Rem accounts. Sign-out token
-- removal is best-effort and can race the next sign-in, so registration itself is the ownership
-- transfer boundary. Migrations replay on every boot; this file must remain idempotent.

LOCK TABLE device_tokens IN ACCESS EXCLUSIVE MODE;

ALTER TABLE device_tokens
    ADD COLUMN IF NOT EXISTS installation_id VARCHAR(100),
    ADD COLUMN IF NOT EXISTS ownership_generation BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS enabled BOOLEAN NOT NULL DEFAULT TRUE;

WITH ranked_destinations AS (
    SELECT id,
           ROW_NUMBER() OVER (
               PARTITION BY apns_token, environment
               ORDER BY ownership_generation DESC,
                        last_seen_at DESC NULLS LAST,
                        updated_at DESC NULLS LAST,
                        created_at DESC,
                        id DESC
           ) AS ownership_rank
      FROM device_tokens
)
DELETE FROM device_tokens AS destination
 USING ranked_destinations AS ranked
 WHERE destination.id = ranked.id
   AND ranked.ownership_rank > 1;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid = 'device_tokens'::regclass
           AND conname = 'device_tokens_apns_token_environment_key'
    ) THEN
        ALTER TABLE device_tokens
            ADD CONSTRAINT device_tokens_apns_token_environment_key
            UNIQUE (apns_token, environment);
    END IF;
END
$$;
