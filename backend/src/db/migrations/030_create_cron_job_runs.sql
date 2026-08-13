-- Global last-run stamps for backend cron jobs that run as a SINGLE global batch
-- (not per-user / per-entity).
--
-- Routines, check-ins, and digests each carry their own `last_run_at` on the entity
-- row, so the every-15-min Railway `cron-all` service can re-run them idempotently
-- (a job only fires once per local day). Memory-extraction (the nightly "Dreaming"
-- pass) is different: it is a global batch with no per-entity row, so it had no way to
-- gate itself and was firing on every 15-min tick — spamming each user's gateway (and
-- creating a visible `rem-memory-<date>` chat session) all day long.
--
-- This table is the missing global idempotency stamp: one row per job name holding the
-- last time that global batch ran. extract-memories reads it to run at most once per
-- UTC day inside a nightly window. Reusable for any future global cron.

CREATE TABLE IF NOT EXISTS cron_job_runs (
    job_name TEXT PRIMARY KEY,
    last_run_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
