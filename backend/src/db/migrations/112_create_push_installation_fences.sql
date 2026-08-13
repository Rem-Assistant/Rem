-- APNs token rotation can leave a registration request in flight while sign-out unregisters the
-- installation. A destination-row tombstone is insufficient when unregister wins before the new
-- token row exists. Keep the monotonic generation independently of any one APNs token so every
-- registration and sign-out is ordered durably across backend replicas and process restarts.

CREATE TABLE IF NOT EXISTS push_installation_fences (
    installation_id VARCHAR(100) PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ownership_generation BIGINT NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed the strongest known generation for current-client destinations. Legacy rows have no stable
-- cross-account installation identity and continue through their user-scoped unregister path.
INSERT INTO push_installation_fences (
    installation_id, user_id, ownership_generation, enabled, updated_at
)
SELECT DISTINCT ON (installation_id)
       installation_id,
       user_id,
       ownership_generation,
       enabled,
       COALESCE(updated_at, NOW())
  FROM device_tokens
 WHERE installation_id IS NOT NULL
   AND installation_id <> ''
   AND installation_id NOT LIKE 'legacy:%'
 ORDER BY installation_id,
          ownership_generation DESC,
          enabled DESC,
          updated_at DESC NULLS LAST,
          id DESC
ON CONFLICT (installation_id) DO UPDATE
   SET user_id = EXCLUDED.user_id,
       ownership_generation = EXCLUDED.ownership_generation,
       enabled = EXCLUDED.enabled,
       updated_at = GREATEST(push_installation_fences.updated_at, EXCLUDED.updated_at)
 WHERE EXCLUDED.ownership_generation > push_installation_fences.ownership_generation;

-- Reconcile rows written by an older replica during a rolling deploy and retire every stale token
-- left behind by APNs rotation. The fence wins generation ties (notably a sign-out tombstone); when
-- a destination has a strictly newer generation, replay adopts that old-replica transfer first.
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
     WHERE installation_id IS NOT NULL
       AND installation_id <> ''
       AND installation_id NOT LIKE 'legacy:%'
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
 WHERE destination.installation_id IS NOT NULL
   AND destination.installation_id <> ''
   AND destination.installation_id NOT LIKE 'legacy:%'
   AND destination.enabled = TRUE
   AND NOT EXISTS (
       SELECT 1 FROM authoritative_rows WHERE authoritative_rows.id = destination.id
   );
