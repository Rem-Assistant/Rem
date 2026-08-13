import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const migration = fs.readFileSync(
  path.join(process.cwd(), 'src/db/migrations/114_add_daily_brief_input_provenance.sql'),
  'utf8',
);

describe('migration 114 daily brief input provenance', () => {
  it('is additive and persists trusted producer, capture, snapshot, and fingerprint', () => {
    expect(migration).toContain('ADD COLUMN IF NOT EXISTS input_producer');
    expect(migration).toContain('ADD COLUMN IF NOT EXISTS input_manifest JSONB');
    expect(migration).toContain('ADD COLUMN IF NOT EXISTS input_fingerprint CHAR(64)');
    expect(migration).toContain('ADD COLUMN IF NOT EXISTS input_captured_at TIMESTAMPTZ');
    expect(migration).toContain('ADD COLUMN IF NOT EXISTS authoring_producer');
    expect(migration).toContain('ADD COLUMN IF NOT EXISTS authoring_model TEXT');
    expect(migration).toContain("DEFAULT 'remclaw-backend'");
    expect(migration).toContain("input_fingerprint ~ '^[0-9a-f]{64}$'");
  });

  it('does not treat client-writable suggestion signals as provenance', () => {
    expect(migration).not.toContain('suggestion_signals');
    expect(migration).not.toContain('channel_signals');
  });
});
