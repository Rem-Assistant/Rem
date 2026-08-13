-- Time-gate brief authoring + make conversation seeding retryable
-- (docs/rebuild/27-BRIEF-AS-AI-AND-LANDING.md; PR #984 review nits).
--
-- Two additive, backward-compatible columns on daily_briefs (migration 033):
--
--   authored_slot — the LOCAL time-of-day slot (morning/afternoon/evening) the CURRENT
--     cached prose was authored in. Lets run-brief-authoring dedupe: author at most ONCE
--     per slot per local day instead of on every */15 cron tick (~96 gateway wakes/user/day
--     → a few). NULL for legacy rows written before this migration (treated as "not yet
--     authored this slot", so the next tick re-authors once and stamps the slot).
--
--   conversation_seeded — TRUE only after the `rem-today-<day>` conversation session was
--     successfully seeded with the authored prose. Migration 033's seed fired once, on the
--     row's first INSERT; if that seed gateway turn failed (wake hiccup) the chat was never
--     seeded and no later tick retried. With this flag a later authoring run re-attempts the
--     seed whenever the row exists but conversation_seeded is still FALSE. Defaults FALSE so
--     existing rows are re-seeded on their next authoring run (idempotent, best-effort).
--
-- Idempotent (IF NOT EXISTS) so it is safe whether or not an env already has the columns.

ALTER TABLE daily_briefs ADD COLUMN IF NOT EXISTS authored_slot VARCHAR(16);
ALTER TABLE daily_briefs ADD COLUMN IF NOT EXISTS conversation_seeded BOOLEAN NOT NULL DEFAULT FALSE;
