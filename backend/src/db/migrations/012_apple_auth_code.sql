-- Store Apple authorization code for token revocation on account deletion
ALTER TABLE auth_identities ADD COLUMN IF NOT EXISTS apple_auth_code TEXT;
