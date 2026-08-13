import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const migration = fs.readFileSync(
  path.join(process.cwd(), 'src/db/migrations/107_create_daily_brief_artifacts.sql'),
  'utf8',
);

describe('migration 107 daily brief artifact lifecycle', () => {
  it('is idempotent and enforces one artifact and delivery per identity', () => {
    expect(migration).toContain('CREATE TABLE IF NOT EXISTS daily_brief_artifacts');
    expect(migration).toContain('UNIQUE (user_id, brief_date, authored_slot)');
    expect(migration).toContain('CREATE TABLE IF NOT EXISTS daily_brief_artifact_deliveries');
    expect(migration).toContain('PRIMARY KEY (artifact_id, session_key)');
  });

  it('persists recoverable authoring and delivery lease state', () => {
    expect(migration).toContain('authoring_lease_token UUID');
    expect(migration).toContain('authoring_lease_expires_at TIMESTAMPTZ');
    expect(migration).toContain('lease_token UUID');
    expect(migration).toContain('lease_expires_at TIMESTAMPTZ');
    expect(migration).toContain('baseline_match_count INTEGER');
    expect(migration).toContain('ADD COLUMN IF NOT EXISTS baseline_match_count INTEGER');
    expect(migration).toContain("CHECK (state IN ('pending', 'delivering', 'delivered'))");
    expect(migration).toContain('gateway_message_id VARCHAR(160)');
  });

  it('cascades delivery state with the user-owned artifact lifecycle', () => {
    expect(migration).toContain('user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL');
    expect(migration).toContain(
      'artifact_id UUID REFERENCES daily_brief_artifacts(id) ON DELETE CASCADE NOT NULL',
    );
  });
});
