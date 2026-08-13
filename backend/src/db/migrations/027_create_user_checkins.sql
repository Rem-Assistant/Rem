-- user_checkins: the founder's simplified routines model. Instead of a per-task
-- schedule (routine_schedules, migration 017), the user sets up to THREE global
-- daily check-in times — morning / midday / night — each independently toggleable
-- with its own delivery hour. At each set time the backend scheduler
-- (src/scripts/daily-checkins.ts) wakes, builds the user's Daily Brief
-- (brief.service.gatherBrief — ALL their tasks, not one) and fires a push
-- (push.service.sendPush) that deep-links into the brief. Connectors/agent
-- instructions stay global; the ONLY schedule is these three rows.
--
-- One row per (user, slot). The slot is a fixed enum so the table is a small,
-- bounded settings store: a user has at most three rows. `delivery_hour` is the
-- local hour-of-day the check-in fires, resolved against `timezone` by the same
-- pure resolver routines use (isDailyRoutineDue, src/services/routine-schedule.ts),
-- so a check-in fires once per local day and re-running the 15-min scheduler is
-- idempotent. `last_run_at` is that idempotency stamp, tracked per slot.
--
-- Default hours (morning 8 / midday 12 / night 20) are applied in the service
-- (checkin.service.DEFAULT_CHECKIN_HOURS) when a slot is first written; rows are
-- created disabled so a new user opts in explicitly.

CREATE TABLE IF NOT EXISTS user_checkins (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    slot TEXT NOT NULL
        CHECK (slot IN ('morning', 'midday', 'night')),
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    delivery_hour INT NOT NULL
        CHECK (delivery_hour >= 0 AND delivery_hour <= 23),
    timezone TEXT NOT NULL,                       -- IANA, e.g. America/Los_Angeles
    last_run_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, slot)
);

CREATE INDEX IF NOT EXISTS idx_user_checkins_user_id ON user_checkins(user_id);
-- The scheduler scans enabled check-ins every ~15 min; keep that scan index-only.
CREATE INDEX IF NOT EXISTS idx_user_checkins_enabled ON user_checkins(enabled) WHERE enabled = TRUE;
