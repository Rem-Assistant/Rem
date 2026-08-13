-- Add the landing summary to the daily-brief card cache
-- (docs/rebuild/27-BRIEF-AS-AI-AND-LANDING.md).
--
-- Migration 033 (create daily_briefs) already shipped in #943 and ran on staging WITHOUT
-- this column. Migrations run ONCE (tracked in schema_migrations), so editing 033 would
-- never re-run — the column must be added in a NEW, additive migration instead.
--
-- The brief lives in a chat (founder FRs): the card (`markdown`) is the chat's latest
-- authored message, and `summary` is a short lead derived from it — "a summary of the
-- brief chat's LATEST message" the landing surface renders. Stored so GET /api/v1/brief
-- returns it without re-deriving; each cron tick / check-in UPSERTs both together.
--
-- Idempotent: IF NOT EXISTS makes this safe whether or not a given env already has the
-- column (e.g. an env whose daily_briefs was created after the column was folded in).

ALTER TABLE daily_briefs ADD COLUMN IF NOT EXISTS summary TEXT;
