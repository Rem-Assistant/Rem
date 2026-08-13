-- Add the session/run id a comment executed in, so the client can resolve an
-- activity row back to the agent session/chat that produced it (the task is the
-- "workboard"; each comment is a doorway into its session — OpenClaw Workboard ->
-- session). Until now `TaskComment` carried no session handle, so the iOS
-- "tap activity row -> open its session" seam was a no-op stub.
--
-- Nullable + additive (ADD COLUMN IF NOT EXISTS): human comments and any comment
-- not produced by a run leave this NULL. Idempotent + safe to re-run. Mirrors the
-- migration 019 column-add pattern.
--
-- 022 is the next free migration number (021 = add_blocked_proposed_status). Note:
-- 010 already has two files (010_iap_identity_and_chains + 010_quota_cycle_started_at)
-- — a pre-existing duplicate-number case — but there is no 022 collision.

ALTER TABLE task_comments ADD COLUMN IF NOT EXISTS session_id TEXT;
