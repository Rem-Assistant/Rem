-- routine_schedules: a routine is an existing task that does work on a cadence.
-- The gateway-free scheduler (#788) wakes each enabled routine in the user's own
-- timezone (isDailyRoutineDue, src/services/routine-schedule.ts), the shared agent
-- runs it, and the result lands as a task_comment. See docs/rebuild/10-ROUTINES-DESIGN.md.
--
-- The design doc sketches user_id as VARCHAR; we use the repo's canonical UUID FK
-- (matching tasks/task_comments/digests) so routines join those tables and cascade
-- on user/task deletion. `model` is nullable per #808 — a routine runs on an
-- explicitly-selected model, never a hard-coded default.

CREATE TABLE IF NOT EXISTS routine_schedules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    task_id UUID REFERENCES tasks(id) ON DELETE CASCADE NOT NULL,
    -- 'daily' is the shipped cadence; 'weekly'/'once' reserved for later.
    cadence TEXT NOT NULL DEFAULT 'daily'
        CHECK (cadence IN ('daily', 'weekly', 'once')),
    delivery_hour INT NOT NULL
        CHECK (delivery_hour >= 0 AND delivery_hour <= 23),
    timezone TEXT NOT NULL,                       -- IANA, e.g. America/Los_Angeles
    prompt TEXT,                                  -- null = default Daily Context Farmer
    -- Autonomy ladder level: L0 observe → L1 brief → L2 propose → L3 safe writes → L4 auto-execute.
    autonomy INT NOT NULL DEFAULT 1
        CHECK (autonomy >= 0 AND autonomy <= 4),
    model TEXT,                                   -- explicitly-selected model (#808); null until chosen
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    last_run_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_routine_schedules_user_id ON routine_schedules(user_id);
CREATE INDEX IF NOT EXISTS idx_routine_schedules_task_id ON routine_schedules(task_id);
-- The scheduler scans enabled routines every ~15 min; keep that scan index-only.
CREATE INDEX IF NOT EXISTS idx_routine_schedules_enabled ON routine_schedules(enabled) WHERE enabled = TRUE;
