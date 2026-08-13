/**
 * Real-PostgreSQL route proof for the negotiated atomic Daily Brief contract.
 *
 * The request itself opens REPEATABLE READ and resolves timezone as its first snapshot statement.
 * A writer commits a timezone/day change plus task, artifact, dismissal, and signal changes before
 * the route continues. The HTTP response must remain entirely on the reader's captured revision.
 *
 * THE SCHEMA HERE IS THE REAL ONE. Every migration in `src/db/migrations` is applied to a throwaway
 * database (see `../db/test-support/migrated-database.ts`); nothing below re-declares a table. This
 * file used to hand-write a `CREATE TABLE` stub of the tables it touched, which meant a column
 * added to a migration had to be hand-copied here too — and when it was not, the failure named
 * something unrelated ("expected 500 to be 200", a wrong-brief-text assertion) because the route
 * reads the authored delivery inside a SAVEPOINT and swallows the error. Adding a column to a
 * migration now requires no edit to this file.
 *
 * That stub was also, quietly, WRONG about production rather than merely behind it:
 *   - `daily_brief_artifact_deliveries` has no `id` column at all; its key is
 *     (artifact_id, session_key). The stub declared `id UUID PRIMARY KEY`.
 *   - `revision` / `artifact_revision` are UUID, not TEXT, so the old `'revision-captured'`
 *     literal could never have been stored by the real code path.
 *   - `channel_signals.source_ref` is NOT NULL and the stub omitted it entirely.
 * Seeds below therefore name their columns explicitly, which is also what keeps them valid when a
 * column is added anywhere but the end of a table.
 */
import express from 'express';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { createMigratedDatabase, type MigratedDatabase } from '../db/test-support/migrated-database.js';

const routePool = vi.hoisted(() => ({
  connect: vi.fn(),
  query: vi.fn(),
}));

vi.mock('../db/pool.js', () => ({ pool: routePool }));
vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = USER_ID;
    next();
  },
}));

const testDatabaseUrl = process.env.TEST_DATABASE_URL?.trim();
const USER_ID = 'b1111111-1111-4111-8111-111111111111';
const TASK_ID = 'b2222222-2222-4222-8222-222222222222';
const SIGNAL_ID = 'b3333333-3333-4333-8333-333333333333';
const NEW_SIGNAL_ID = 'b4444444-4444-4444-8444-444444444444';
const ARTIFACT_ID = 'b5555555-5555-4555-8555-555555555555';
// `revision` is UUID in the real schema, so the captured revision has to be one.
const CAPTURED_REVISION = 'b6666666-6666-4666-8666-666666666666';
const NOW = new Date('2026-08-17T00:30:00.000Z');

let database: MigratedDatabase;

describe.skipIf(!testDatabaseUrl)('atomic-v1 PostgreSQL route snapshot', () => {
  beforeAll(async () => {
    process.env.BRIEF_AI_AUTHORING_ENABLED = '1';
    database = await createMigratedDatabase({
      adminConnectionString: testDatabaseUrl!,
      label: 'brief_atomic',
    });
    const setup = await database.pool.connect();
    try {
      await setup.query(
        `INSERT INTO users (id, timezone) VALUES ($1::uuid, 'UTC')`,
        [USER_ID],
      );
      await setup.query(
        `INSERT INTO tasks (id, user_id, title, type, status, priority, start_date, updated_at)
         VALUES ($2::uuid, $1::uuid, 'Captured overdue task', 'task', 'pending', 'medium',
                 '2026-08-16T09:00:00Z', '2026-08-16T09:00:00Z')`,
        [USER_ID, TASK_ID],
      );
      await setup.query(
        `INSERT INTO channel_signals (id, user_id, source, source_ref, sender, summary, received_at)
         VALUES ($2::uuid, $1::uuid, 'gmail', 'captured-signal', 'Ada', 'Captured signal',
                 '2026-08-17T00:00:00Z')`,
        [USER_ID, SIGNAL_ID],
      );
      await setup.query(
        `INSERT INTO daily_briefs (user_id, brief_date, authored_slot, source, markdown, summary)
         VALUES ($1::uuid, '2026-08-17', 'morning', 'gateway',
                 'Captured UTC-day brief', 'Captured summary')`,
        [USER_ID],
      );
      await setup.query(
        `INSERT INTO daily_brief_artifacts
           (id, user_id, brief_date, authored_slot, source, markdown, summary, revision)
         VALUES ($2::uuid, $1::uuid, '2026-08-17', 'morning', 'gateway',
                 'Captured UTC-day brief', 'Captured summary', $3::uuid)`,
        [USER_ID, ARTIFACT_ID, CAPTURED_REVISION],
      );
      await setup.query(
        `INSERT INTO daily_brief_artifact_deliveries
           (artifact_id, artifact_revision, session_key, state)
         VALUES ($1::uuid, $2::uuid, 'rem-orchestrator', 'delivered')`,
        [ARTIFACT_ID, CAPTURED_REVISION],
      );
    } finally {
      setup.release();
    }
  });

  afterAll(async () => {
    delete process.env.BRIEF_AI_AUTHORING_ENABLED;
    await database?.drop();
    vi.useRealTimers();
  });

  it('keeps route timezone, local day, brief, tasks, dismissals, and signals on one revision', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const reader = await database.pool.connect();
    const writer = await database.pool.connect();

    let writerCommitted = false;
    const readerFacade = {
      query: async (sql: string, params?: unknown[]) => {
        const result = await reader.query(sql, params);
        if (!writerCommitted && sql.includes('SELECT timezone FROM users')) {
          await writer.query('BEGIN');
          await writer.query(`UPDATE users SET timezone = 'America/Los_Angeles' WHERE id = $1`, [USER_ID]);
          await writer.query(`UPDATE tasks SET status = 'completed', updated_at = $2 WHERE id = $1`, [
            TASK_ID, NOW.toISOString(),
          ]);
          // Dismissed just now, so it is inside the TTL and must still suppress its signal.
          await writer.query(
            `INSERT INTO suggestion_dismissals (user_id, suggestion_key, dismissed_at)
             VALUES ($1, $2, $3)`,
            [USER_ID, `gmail:${SIGNAL_ID}`, NOW.toISOString()],
          );
          await writer.query(
            `INSERT INTO channel_signals
               (id, user_id, source, source_ref, sender, summary, received_at)
             VALUES ($1::uuid, $2::uuid, 'gmail', 'new-signal', 'Bob', 'New signal', $3)`,
            [NEW_SIGNAL_ID, USER_ID, NOW.toISOString()],
          );
          await writer.query(
            `UPDATE daily_briefs SET markdown = 'Replacement brief', summary = 'Replacement summary'
               WHERE user_id = $1`,
            [USER_ID],
          );
          await writer.query('COMMIT');
          writerCommitted = true;
        }
        return result;
      },
      release: () => reader.release(),
    };
    routePool.connect.mockResolvedValueOnce(readerFacade);

    const briefRoutes = (await import('./brief.routes.js')).default;
    const app = express();
    app.use(express.json());
    app.use('/api/v1', briefRoutes);

    try {
      const response = await request(app)
        .get('/api/v1/brief')
        .set('X-Rem-Conversation-Continuity', 'durable-orchestrator-v1')
        .set('X-Rem-Suggestion-Contract', 'atomic-v1');

      expect(response.status).toBe(200);
      expect(writerCommitted).toBe(true);
      expect(response.body.markdown).toBe('Captured UTC-day brief');
      expect(response.body.brief_revision).toBe(CAPTURED_REVISION);
      expect(response.body.overdue.map((item: { id: string }) => item.id)).toEqual([TASK_ID]);
      expect(response.body.suggestions.some((item: { key: string }) => item.key === `gmail:${SIGNAL_ID}`)).toBe(true);
      expect(response.body.suggestions.some((item: { key: string }) => item.key === `gmail:${NEW_SIGNAL_ID}`)).toBe(false);
    } finally {
      if (!writerCommitted) await writer.query('ROLLBACK').catch(() => undefined);
      writer.release();
    }
  });
});
