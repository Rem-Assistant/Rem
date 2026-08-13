-- WHY A RUN DID NOT HAPPEN, on the run record itself.
--
-- The automations/run-history surface renders AFTER the fact, so a reason that exists only in
-- an HTTP response cannot be shown there. Before this migration the only durable trace of a
-- blocked run was the ⚠️ prose in `task_comments.body` — a human-readable string, which is the
-- wrong layer for a machine decision (CLAUDE.md principle 5) and cannot distinguish the two
-- cases whose remedies differ most: a Rem-managed user out of quota (upgrade to Pro) from a
-- BYOK user whose own key was refused (fix the key).
--
-- Two columns, both nullable and additive (ADD COLUMN IF NOT EXISTS), so this is idempotent and
-- safe to re-run. Mirrors migration 019's `run_status` column-add pattern and migration 031's
-- `runtime` CHECK-constraint pattern.
--
--   run_block_code — the class of failure. Closed set, checked here so a typo cannot become a
--                    stored fact the client has to defend against.
--   run_block_mode — WHOSE key was going to pay for the run. Carried alongside the code rather
--                    than derived at read time, because the mode at the moment of the run is
--                    what explains that run; a user who later switches modes must not have
--                    their history rewritten.
--
-- Source of truth for both values: backend/src/services/run-block.ts. The CHECK sets below and
-- the `RUN_BLOCK_CODES` / `MODEL_RUNTIME_MODES` unions there must stay in lockstep.
--
-- NULL means "this run was not blocked" (or predates this migration) — never "blocked for an
-- unknown reason". `unknown` is a real, deliberate member of the mode set and means something
-- narrower: Rem could not establish whose key would have paid.

-- Both run paths write these. The manual `Run now` dispatch (routes/tasks.routes.ts) sets them on
-- a blocked run and NULLs them on a successful one. The autonomous orchestrator sweep sets
-- `policy_blocked` on a deny-list refusal and NULLs them on success — it never records a runtime
-- failure here, because a sweep whose gateway turn fails releases its claim to retry rather than
-- stamping a terminal state. The NULLing matters on both paths: a task that failed yesterday and
-- ran fine today must stop advertising a remedy the user already applied.
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS run_block_code TEXT
    CHECK (run_block_code IS NULL OR run_block_code IN (
        'quota_exhausted',
        'credential_rejected',
        'runtime_unavailable',
        'runtime_timeout',
        'runtime_error',
        'policy_blocked'
    ));

ALTER TABLE tasks ADD COLUMN IF NOT EXISTS run_block_mode TEXT
    CHECK (run_block_mode IS NULL OR run_block_mode IN ('rem_managed', 'byok', 'unknown'));

-- The comment IS the activity row the run history renders, so the reason has to live on it too.
-- A task holds only its LAST run's block state; the comment holds the one for its own run, which
-- is what a history list needs to show a run that failed three runs ago.
ALTER TABLE task_comments ADD COLUMN IF NOT EXISTS run_block_code TEXT
    CHECK (run_block_code IS NULL OR run_block_code IN (
        'quota_exhausted',
        'credential_rejected',
        'runtime_unavailable',
        'runtime_timeout',
        'runtime_error',
        'policy_blocked'
    ));

ALTER TABLE task_comments ADD COLUMN IF NOT EXISTS run_block_mode TEXT
    CHECK (run_block_mode IS NULL OR run_block_mode IN ('rem_managed', 'byok', 'unknown'));
