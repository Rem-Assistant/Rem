-- Complete the mixed-replica rollout boundary for installation-fenced APNs ownership.
--
-- A pre-fence backend INSERT does not name installation_id, ownership_generation, or enabled.
-- Merely teaching new readers to inspect those fields is insufficient: the old writer creates a
-- NULL installation row, and an old sender ignores enabled entirely. Adopt each live pre-fence row
-- under the same per-user `legacy:<user-id>` compatibility authority used by the current route, make
-- future ambiguous SQL shapes fail closed at the table boundary, physically remove disabled or
-- superseded rows, and retain only exact current-client authority where an installation fence exists.

LOCK TABLE device_tokens IN ACCESS EXCLUSIVE MODE;

-- A shipped client caches token/environment/user and suppresses its launch registration while APNs
-- returns the same token. Deleting its pre-fence row here would therefore stop push delivery until
-- that client updates or APNs rotates the token. Ownership is already exclusive per token/environment
-- (migration 110), so preserve enabled rows under the current route's user-scoped legacy authority.
-- Disabled rows must still be physically retired because a draining old sender ignores `enabled`.
DELETE FROM device_tokens
 WHERE (installation_id IS NULL OR BTRIM(installation_id) = '')
   AND enabled = FALSE;

UPDATE device_tokens
   SET installation_id = 'legacy:' || user_id::text,
       updated_at = NOW()
 WHERE installation_id IS NULL OR BTRIM(installation_id) = '';

-- Replays also physically retire rows that an earlier revision only marked disabled. This makes
-- logout and APNs rotation safe while a pre-fence sender is still draining.
WITH ranked_destinations AS (
    SELECT id,
           installation_id,
           user_id,
           ownership_generation,
           enabled,
           ROW_NUMBER() OVER (
               PARTITION BY installation_id
               ORDER BY ownership_generation DESC,
                        enabled DESC,
                        updated_at DESC NULLS LAST,
                        id DESC
           ) AS installation_rank
      FROM device_tokens
     WHERE installation_id NOT LIKE 'legacy:%'
), authoritative_rows AS (
    SELECT ranked.id
      FROM ranked_destinations AS ranked
      JOIN push_installation_fences AS fence
        ON fence.installation_id = ranked.installation_id
       AND fence.user_id = ranked.user_id
       AND fence.ownership_generation = ranked.ownership_generation
       AND fence.enabled = TRUE
     WHERE ranked.installation_rank = 1
       AND ranked.enabled = TRUE
)
DELETE FROM device_tokens AS destination
 WHERE destination.installation_id NOT LIKE 'legacy:%'
   AND NOT EXISTS (
       SELECT 1 FROM authoritative_rows WHERE authoritative_rows.id = destination.id
   );

-- PostgreSQL validates an INSERT's NOT NULL columns before ON CONFLICT reaches its UPDATE arm.
-- Preserve rolling compatibility for the old route's exact SQL shape only when the destination
-- already belongs to the same user: copy that row's authority onto the transient proposed row so
-- the conflict update can proceed. A new token, a previous-account token, or an otherwise
-- ambiguous write finds no same-owner row and remains NULL, so NOT NULL rejects it. `FOR UPDATE`
-- holds the authority row through the old writer's conflict update. Current rotation/logout must
-- therefore happen entirely before this copy (and the re-read fails closed) or entirely afterward
-- (and retires the refreshed row); it cannot delete between the copy and conflict handling.
CREATE OR REPLACE FUNCTION preserve_existing_device_token_authority()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.installation_id IS NULL THEN
        SELECT installation_id, ownership_generation, enabled
          INTO NEW.installation_id, NEW.ownership_generation, NEW.enabled
         FROM device_tokens
         WHERE user_id = NEW.user_id
           AND apns_token = NEW.apns_token
         FOR UPDATE;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS preserve_existing_device_token_authority_before_insert
    ON device_tokens;
CREATE TRIGGER preserve_existing_device_token_authority_before_insert
BEFORE INSERT ON device_tokens
FOR EACH ROW
EXECUTE FUNCTION preserve_existing_device_token_authority();

-- With no default, an old replica's INSERT that omits installation_id is rejected by PostgreSQL.
-- Existing-row refreshes remain compatible because UPDATE preserves the row's authority, while a
-- request that needs to create or transfer ownership must reach a current backend replica.
ALTER TABLE device_tokens
    ALTER COLUMN installation_id SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid = 'device_tokens'::regclass
           AND conname = 'device_tokens_installation_id_nonempty'
    ) THEN
        ALTER TABLE device_tokens
            ADD CONSTRAINT device_tokens_installation_id_nonempty
            CHECK (BTRIM(installation_id) <> '');
    END IF;
END
$$;
