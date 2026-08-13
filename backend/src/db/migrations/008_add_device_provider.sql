-- Allow 'device' as an auth provider for anonymous device-based registration
ALTER TABLE auth_identities DROP CONSTRAINT IF EXISTS auth_identities_provider_check;
ALTER TABLE auth_identities ADD CONSTRAINT auth_identities_provider_check
  CHECK (provider IN ('apple', 'google', 'device'));
