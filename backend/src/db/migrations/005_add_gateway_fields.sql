-- Gateway metadata per user (hackathon). Idempotent: safe to run multiple times.
ALTER TABLE users ADD COLUMN IF NOT EXISTS gateway_url TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS gateway_token_encrypted TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS hosting_provider TEXT DEFAULT 'railway';
