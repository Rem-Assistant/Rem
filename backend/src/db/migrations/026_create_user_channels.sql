-- Channels — connect Rem to the user's messaging surfaces (Discord, WhatsApp, Email, ...).
--
-- A `user_channels` row tracks ONE channel connection for a user. The actual message
-- loop (inbound message -> user's agent -> reply back out) is owned entirely by the
-- OpenClaw gateway: enabling `channels.<provider>` in the gateway config makes the
-- gateway run that provider's connector and route inbound messages to the single
-- default agent (`main`). See openclaw/docs/install/fly.md (Discord) and
-- openclaw/src/gateway/server-channels.ts.
--
-- So this table is NOT a message store. It is the backend's record of *which* channels a
-- user has connected and their status, plus the credential we pushed to the gateway
-- (encrypted at rest) so a connection survives a gateway re-patch / config drift and can
-- be re-applied. Source of truth for the running connector is the gateway config; this
-- table is the backend's durable intent + status mirror.
--
--   provider  — channel id understood by the gateway: 'discord' | 'whatsapp' | 'email'.
--   status    — 'connected' (config pushed, connector live) | 'disconnected'.
--   credential_encrypted — AES-256-GCM (gateway.service encryptSecret), e.g. a Discord bot
--                          token. NULL for credential-less channels (WhatsApp uses QR login
--                          on the gateway; Email connector not yet wired — fast-follows).
--   metadata  — JSONB for small non-secret connection facts (e.g. application id), future-proof.
--
-- One row per (user, provider): connecting a provider again upserts/re-applies.

CREATE TABLE IF NOT EXISTS user_channels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    provider TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'connected',
    credential_encrypted TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, provider)
);

CREATE INDEX IF NOT EXISTS idx_user_channels_user_id ON user_channels(user_id);
