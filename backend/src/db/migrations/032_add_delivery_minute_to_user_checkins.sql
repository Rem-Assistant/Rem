-- delivery_minute: the founder's check-in time picker now holds MINUTE precision, not
-- just top-of-hour. Migration 027 stored `delivery_hour` only, but the iOS/macOS control
-- surfaces a `.hourAndMinute` wheel — so when the user spun the minute wheel to e.g. :10
-- the setter truncated it to the hour, the getter returned hour:00, and the wheel snapped
-- back to :00 (the minute wheel was effectively non-functional). This adds the minute
-- component so the picker holds the chosen time end-to-end (hour AND minute).
--
-- The scheduler (src/scripts/daily-checkins.ts → routine-schedule.isDailyRoutineDue) now
-- compares hour AND minute against the user's local wall-clock, so a check-in fires at or
-- after its exact local minute (still idempotent once per local day via last_run_at).
--
-- Additive + idempotent. Existing rows default to :00, which exactly preserves the old
-- top-of-hour behavior.

ALTER TABLE user_checkins
    ADD COLUMN IF NOT EXISTS delivery_minute INT NOT NULL DEFAULT 0;

ALTER TABLE user_checkins
    DROP CONSTRAINT IF EXISTS user_checkins_delivery_minute_check;

ALTER TABLE user_checkins
    ADD CONSTRAINT user_checkins_delivery_minute_check
    CHECK (delivery_minute >= 0 AND delivery_minute <= 59);
