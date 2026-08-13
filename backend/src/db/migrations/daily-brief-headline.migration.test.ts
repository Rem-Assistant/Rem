/**
 * Migration 119 + the read path that serves the headline, against a real Postgres engine (PGlite).
 *
 * The unit tests in `src/services/brief-authoring.service.test.ts` mock `pool.query`, so they can
 * prove the extractor and the parameter binding but NOT that the SQL does what it claims. Two
 * claims here are pure SQL and are exactly the ones that would silently rot:
 *
 *   1. the backfill lifts a pre-existing `## The Day` heading into the new column, and leaves a
 *      prose-first artifact NULL (so nothing renders worse than it did before the migration);
 *   2. `readAuthoredBriefDelivery` — the statement GET /brief serves the card and chat title
 *      from — actually returns that column.
 *
 * So this file runs the real migration files and the real reader.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeAll, describe, expect, it, vi } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const poolMock = vi.hoisted(() => ({
  db: null as any,
  query: (...args: any[]) => poolMock.db.query(...args),
}));
vi.mock('../pool.js', () => ({ pool: poolMock }));

const { readAuthoredBriefDelivery } = await import('../../services/brief-authoring.service.js');

const USER_ID = '22222222-2222-4222-8222-222222222222';
const SESSION_KEY = 'rem-orchestrator';

// Two artifacts written BEFORE this migration existed: one whose authoring turn happened to open
// with a heading (this is the real shape on staging — see `## The Day`), one that opened with
// prose (the majority shape).
const HEADED_MARKDOWN = '## The Day\n\nNo completed tasks recorded and nothing on deck yet.';
const PROSE_MARKDOWN = 'Your Monday is quiet on the surface — three items have slipped.';

function migration(file: string): string {
  return fs.readFileSync(path.join(__dirname, file), 'utf8');
}

async function seedLegacyArtifact(briefDate: string, slot: string, markdown: string) {
  const artifact = await poolMock.db.query(
    `INSERT INTO daily_brief_artifacts (user_id, brief_date, authored_slot, markdown, summary, source)
     VALUES ($1::uuid, $2::date, $3, $4, $5, 'gateway') RETURNING id, revision`,
    [USER_ID, briefDate, slot, markdown, 'seeded summary'],
  );
  const { id, revision } = artifact.rows[0];
  await poolMock.db.query(
    `INSERT INTO daily_briefs (user_id, brief_date, markdown, summary, source, session_key, authored_slot)
     VALUES ($1::uuid, $2::date, $3, $4, 'gateway', $5, $6)`,
    [USER_ID, briefDate, markdown, 'seeded summary', SESSION_KEY, slot],
  );
  await poolMock.db.query(
    `INSERT INTO daily_brief_artifact_deliveries (artifact_id, session_key, state, artifact_revision, delivered_at)
     VALUES ($1::uuid, $2, 'delivered', $3::uuid, NOW())`,
    [id, SESSION_KEY, revision],
  );
  return id as string;
}

describe('daily_brief_artifacts.headline (migration 119)', () => {
  beforeAll(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    poolMock.db = new PGlite();
    await poolMock.db.exec('CREATE TABLE users (id UUID PRIMARY KEY DEFAULT gen_random_uuid())');
    await poolMock.db.query('INSERT INTO users (id) VALUES ($1::uuid)', [USER_ID]);
    // The Agenda cache the artifact reader joins against. Only the columns this path touches.
    await poolMock.db.exec(`
      CREATE TABLE daily_briefs (
        user_id UUID NOT NULL,
        brief_date DATE NOT NULL,
        markdown TEXT,
        summary TEXT,
        source VARCHAR(20) NOT NULL DEFAULT 'gateway',
        model TEXT,
        session_key VARCHAR(160),
        authored_slot VARCHAR(16),
        conversation_seeded BOOLEAN NOT NULL DEFAULT FALSE,
        generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (user_id, brief_date)
      )
    `);
    await poolMock.db.exec(migration('107_create_daily_brief_artifacts.sql'));
    await poolMock.db.exec(migration('109_add_daily_brief_artifact_source.sql'));
    await poolMock.db.exec(migration('114_add_daily_brief_input_provenance.sql'));

    // Artifacts exist BEFORE the headline column does — this is the real upgrade order.
    await seedLegacyArtifact('2026-08-11', 'morning', HEADED_MARKDOWN);
    await seedLegacyArtifact('2026-08-10', 'morning', PROSE_MARKDOWN);

    await poolMock.db.exec(migration('119_add_daily_brief_headline.sql'));
  }, 60_000);

  it('backfills an existing brief that already opened with a heading', async () => {
    const row = await poolMock.db.query(
      `SELECT headline FROM daily_brief_artifacts WHERE brief_date = '2026-08-11'::date`,
    );
    expect(row.rows[0].headline).toBe('The Day');
  });

  it('leaves a prose-first brief NULL rather than inventing a title for it', async () => {
    const row = await poolMock.db.query(
      `SELECT headline FROM daily_brief_artifacts WHERE brief_date = '2026-08-10'::date`,
    );
    expect(row.rows[0].headline).toBeNull();
  });

  it('is idempotent — re-running does not overwrite an authored headline', async () => {
    await poolMock.db.query(
      `UPDATE daily_brief_artifacts SET headline = 'Hand authored'
        WHERE brief_date = '2026-08-11'::date`,
    );
    await poolMock.db.exec(migration('119_add_daily_brief_headline.sql'));
    const row = await poolMock.db.query(
      `SELECT headline FROM daily_brief_artifacts WHERE brief_date = '2026-08-11'::date`,
    );
    expect(row.rows[0].headline).toBe('Hand authored');
  });

  it('serves the stored headline through the exact statement GET /brief reads', async () => {
    await poolMock.db.query(
      `UPDATE daily_brief_artifacts SET headline = 'The Day'
        WHERE brief_date = '2026-08-11'::date`,
    );
    const delivered = await readAuthoredBriefDelivery(USER_ID, '2026-08-11', SESSION_KEY);
    expect(delivered?.headline).toBe('The Day');
    expect(delivered?.markdown).toBe(HEADED_MARKDOWN);
  });

  it('serves null for a delivered brief with no authored headline', async () => {
    const delivered = await readAuthoredBriefDelivery(USER_ID, '2026-08-10', SESSION_KEY);
    expect(delivered?.markdown).toBe(PROSE_MARKDOWN);
    expect(delivered?.headline).toBeNull();
  });
});
