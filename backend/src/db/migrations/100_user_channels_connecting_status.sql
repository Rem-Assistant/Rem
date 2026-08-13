-- Channels: allow the honest "connecting" status.
--
-- A channel used to be marked `connected` the moment its connector was enabled — even though no
-- live session existed yet (WhatsApp QR unscanned, Discord token only shape-checked). We now
-- record `connecting` on enable and promote to `connected` only when the gateway confirms a real
-- live session (see backend/src/services/channels.service.ts reconcileChannelStatuses).
--
-- If the original `user_channels` migration added a CHECK constraint that only permits
-- ('connected','disconnected'), inserting 'connecting' would fail. This migration drops ANY
-- CHECK constraint on user_channels.status (whatever its generated/explicit name) and re-adds a
-- single named one that includes 'connecting'. Idempotent: safe to run repeatedly, and a no-op if
-- the table never had a status CHECK constraint (it just installs ours).

DO $$
DECLARE
  con RECORD;
BEGIN
  -- Only act if the table exists (guard for fresh DBs where create runs later in the same boot;
  -- the runner applies files in sorted order, so this file's high prefix runs after create).
  IF to_regclass('public.user_channels') IS NULL THEN
    RETURN;
  END IF;

  -- Drop every CHECK constraint on user_channels whose definition references the status column,
  -- regardless of its name (Postgres auto-names them e.g. user_channels_status_check).
  FOR con IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE t.relname = 'user_channels'
      AND n.nspname = 'public'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.user_channels DROP CONSTRAINT %I', con.conname);
  END LOOP;

  -- Re-add a canonical constraint that includes 'connecting'.
  ALTER TABLE public.user_channels
    ADD CONSTRAINT user_channels_status_check
    CHECK (status IN ('connecting', 'connected', 'disconnected'));
END $$;
