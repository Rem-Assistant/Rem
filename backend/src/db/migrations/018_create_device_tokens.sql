-- Remote push foundation: APNs device tokens per user. This is the backend's
-- address book for waking a closed app — the gap that unblocks proactive
-- routines (docs/rebuild/16-ROUTINES-BUILD-PLAN.md P6, 09-ROUTINES-VISION.md).
--
-- Today the apps only have LOCAL notifications (UNUserNotificationCenter, see
-- RemClaw/Sources/Services/TaskNotificationService.swift). They cannot be woken
-- by the backend when closed. The app registers its APNs device token here; the
-- push service (src/services/push.service.ts) reads these rows to send a remote
-- push to every device a user has.
--
-- Mirrors OpenClaw's direct token-based APNs model (openclaw/src/infra/push-apns.ts):
-- one (token, environment) pair per device, sandbox vs production picks the APNs
-- authority. Source of truth for "where to reach this user" = this table.

CREATE TABLE IF NOT EXISTS device_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    -- 'ios' today; 'macos' reserved for when the Mac app registers for push.
    platform VARCHAR(20) NOT NULL DEFAULT 'ios'
        CHECK (platform IN ('ios', 'macos')),
    apns_token VARCHAR(200) NOT NULL,
    -- Which APNs host to use. Debug/TestFlight builds mint sandbox tokens; the
    -- App Store build mints production tokens. The same device string is invalid
    -- on the wrong host, so we store the environment alongside it.
    environment VARCHAR(20) NOT NULL DEFAULT 'production'
        CHECK (environment IN ('sandbox', 'production')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    -- A device re-registers the same token on every launch; upsert on this pair.
    UNIQUE (user_id, apns_token)
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON device_tokens(user_id);
