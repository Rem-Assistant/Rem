-- Serialize Daily Brief APNs side effects per account across local days. The canonical transcript fence
-- prevents an older artifact from being injected after a newer one, but APNs happens afterward and
-- is itself irreversible: without this row lock, an older worker can send after a newer worker and
-- replace the newer collapse-id alert. Keep the latest consumed slot durably so an older waiter
-- fails closed after acquiring the lock.

CREATE TABLE IF NOT EXISTS daily_brief_notification_fences (
    user_id UUID REFERENCES users(id) ON DELETE CASCADE PRIMARY KEY,
    latest_brief_date DATE,
    latest_slot TEXT
        CHECK (latest_slot IN ('morning', 'afternoon', 'evening')),
    last_notified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
