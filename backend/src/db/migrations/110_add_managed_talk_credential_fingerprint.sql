ALTER TABLE users
ADD COLUMN IF NOT EXISTS managed_talk_credential_fingerprint TEXT;
