-- attempt_count / attempt_day: a real per-local-day DELIVERY ATTEMPT counter for user_checkins,
-- so the scheduler can bound retries by "how many times did we actually try?" instead of by the
-- wall clock (#1285, superseding the wall-clock bound of #1284/#1279).
--
-- WHY A COLUMN AND NOT ARITHMETIC. Several delivery outcomes in src/scripts/daily-checkins.ts
-- deliberately do NOT stamp `last_run_at`, so the slot stays due and the next 15-minute cron tick
-- retries. That is right for a transient failure and wrong for a persistent one: unbounded, a slot
-- that can never succeed re-runs `authorBriefForUser` every 15 minutes for the rest of the local
-- day (#1279). Bounding it needs the question "has this slot already been attempted today, and how
-- often?" — and that question is UNANSWERABLE from the columns we had:
--
--     last_run_at IS NULL  ⟺  (never attempted today)  OR  (attempted and failed)
--
-- because failing is precisely what does not stamp. Every wall-clock proxy for the missing fact
-- (minutes past the schedule, minutes since `updated_at`) breaks the moment the first attempt
-- happens late — a cron outage, a redeploy gap, or a slot enabled hours after its own delivery
-- time — since the budget is then already spent before attempt #1 ever runs.
--
-- SEMANTICS.
--   attempt_day   the user's LOCAL calendar date (resolved against user_checkins.timezone) that
--                 the current attempt streak belongs to. NULL means "no attempts outstanding" —
--                 which is what a successful/consumed stamp writes.
--   attempt_count how many delivery attempts have ended in "will retry" for that local day.
--
-- The counter is advanced by ONE atomic statement (checkin.service.recordCheckinAttempt) that both
-- rolls the day and increments:
--
--     SET attempt_count = CASE WHEN attempt_day IS DISTINCT FROM $day THEN 1
--                              ELSE attempt_count + 1 END,
--         attempt_day = $day
--
-- Doing the roll inside the same statement is what makes it correct under concurrency: two
-- overlapping cron workers serialize on the row lock and read back 1 and 2, so neither attempt is
-- lost and neither resets the other. A read-compare-write in application code would let both see a
-- stale day and both write 1, stalling the counter at 1 forever.
--
-- `IS DISTINCT FROM` rather than `<>` so a NULL attempt_day is a day change instead of a NULL
-- predicate. On the data this schema can actually produce the two spellings agree — NULL only ever
-- pairs with attempt_count 0, where the ELSE branch computes 0 + 1 = 1 anyway — so this is stated
-- as intent, not as a bug fix: the reset must not depend on the count that happens to sit beside it.
--
-- Because the counter lives in Postgres it survives what an in-process counter cannot: restarts,
-- redeploys, and multiple workers. Because it advances only when an attempt actually happens, a
-- cron outage costs the slot nothing — the first tick back still gets the full budget.
--
-- Additive, idempotent, and backfill-free: existing rows default to 0 attempts / NULL day, which is
-- exactly "no attempts outstanding today" — the state a healthy slot is already in.

ALTER TABLE user_checkins
    ADD COLUMN IF NOT EXISTS attempt_count INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS attempt_day DATE;

ALTER TABLE user_checkins
    DROP CONSTRAINT IF EXISTS user_checkins_attempt_count_check;

ALTER TABLE user_checkins
    ADD CONSTRAINT user_checkins_attempt_count_check
    CHECK (attempt_count >= 0);
