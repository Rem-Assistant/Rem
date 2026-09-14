import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Reproduces the reordered-request defect (Codex P1 on PR #1412): a soft-delete
// (tombstone) request for a client-chosen conversation id can arrive on the wire
// BEFORE the create for the same id. The delete must persist a tombstone that the
// later create then respects, so private history cannot be resurrected by a delayed
// create retry. This test drives the REAL Express routes against an in-process
// PostgreSQL (PGlite) running the actual migration-134 schema — so it exercises the
// route SQL end to end, not a hand-copied query.

const USER_ID = '11111111-1111-4111-8111-111111111111';
const CONVERSATION_ID = '22222222-2222-4222-8222-222222222222';

const dbHolder = vi.hoisted(() => ({ db: null as any }));

function pgQuery(text: string, params?: unknown[]) {
  return params === undefined ? dbHolder.db.query(text) : dbHolder.db.query(text, params);
}

vi.mock('../db/pool.js', () => ({
  pool: { query: (text: string, params?: unknown[]) => pgQuery(text, params) },
  runtimeConversationPool: {
    connect: async () => ({
      query: (text: string, params?: unknown[]) => pgQuery(text, params),
      release: () => {},
    }),
  },
}));
vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = USER_ID;
    next();
  },
}));
vi.mock('../runtime/agent-runtime.service.js', () => ({ runAgentTurnOnSharedRuntime: vi.fn() }));

const { default: conversationRoutes } = await import('./conversations.routes.js');

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', conversationRoutes);
  return app;
}

const migrationSql = fs.readFileSync(
  path.join(path.dirname(fileURLToPath(import.meta.url)), '../db/migrations/134_create_rem_conversations.sql'),
  'utf8',
);

describe('Rem conversation reordered delete/create (PR #1412 P1)', () => {
  beforeEach(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    dbHolder.db = new PGlite();
    await dbHolder.db.exec('CREATE TABLE users (id UUID PRIMARY KEY)');
    await dbHolder.db.query('INSERT INTO users (id) VALUES ($1)', [USER_ID]);
    await dbHolder.db.exec(migrationSql);
    // The delete route also purges runtime output; a minimal shape is enough here.
    await dbHolder.db.exec(
      `CREATE TABLE rem_agent_runs (
         id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
         user_id UUID NOT NULL,
         session_key TEXT NOT NULL
       )`,
    );
  }, 60_000);

  afterEach(async () => {
    await dbHolder.db?.close();
  });

  it('does not resurrect a conversation when the delete lands before the create', async () => {
    // 1. Tombstone/delete arrives first, before any create for this id.
    const deleted = await request(testApp()).delete(`/api/v1/conversations/${CONVERSATION_ID}`);
    expect(deleted.status).toBe(204);

    // 2. The delete must have PERSISTED a tombstone even though no row existed yet.
    const afterDelete = await dbHolder.db.query(
      'SELECT deleted_at IS NOT NULL AS deleted FROM rem_conversations WHERE id = $1',
      [CONVERSATION_ID],
    );
    expect(afterDelete.rows).toEqual([{ deleted: true }]);

    // 3. The delayed create retry must NOT resurrect the deleted conversation.
    const created = await request(testApp())
      .post('/api/v1/conversations')
      .send({ id: CONVERSATION_ID });
    expect(created.status).toBe(410);
    expect(created.body.error).toContain('deleted');

    // 4. The row is still a tombstone; no live conversation leaked back.
    const finalState = await dbHolder.db.query(
      'SELECT deleted_at IS NOT NULL AS deleted FROM rem_conversations WHERE id = $1',
      [CONVERSATION_ID],
    );
    expect(finalState.rows).toEqual([{ deleted: true }]);
  });

  it('still deletes a live conversation and purges its content', async () => {
    const createdLive = await request(testApp())
      .post('/api/v1/conversations')
      .send({ id: CONVERSATION_ID });
    expect(createdLive.status).toBe(201);

    const deleted = await request(testApp()).delete(`/api/v1/conversations/${CONVERSATION_ID}`);
    expect(deleted.status).toBe(204);

    const state = await dbHolder.db.query(
      'SELECT title, deleted_at IS NOT NULL AS deleted FROM rem_conversations WHERE id = $1',
      [CONVERSATION_ID],
    );
    expect(state.rows).toEqual([{ title: null, deleted: true }]);
  });
});
