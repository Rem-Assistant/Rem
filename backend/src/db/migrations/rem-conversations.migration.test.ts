import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const migrationsDir = path.dirname(fileURLToPath(import.meta.url));
const USER_A = '11111111-1111-4111-8111-111111111111';
const USER_B = '22222222-2222-4222-8222-222222222222';
const CONVERSATION_ID = '33333333-3333-4333-8333-333333333333';
const RUN_ID = '44444444-4444-4444-8444-444444444444';

describe('Rem conversation authority (migration 134)', () => {
  let db: any;

  beforeEach(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    db = new PGlite();
    await db.exec('CREATE TABLE users (id UUID PRIMARY KEY)');
    await db.query('INSERT INTO users (id) VALUES ($1), ($2)', [USER_A, USER_B]);
    const sql = fs.readFileSync(path.join(migrationsDir, '134_create_rem_conversations.sql'), 'utf8');
    await db.exec(sql);
    await db.exec(sql);
  }, 60_000);

  afterEach(async () => {
    await db?.close();
  });

  it('enforces tenant ownership through the message foreign key', async () => {
    await db.query(
      'INSERT INTO rem_conversations (id, user_id, title) VALUES ($1, $2, $3)',
      [CONVERSATION_ID, USER_A, 'Owned chat'],
    );
    await expect(db.query(
      `INSERT INTO rem_conversation_messages
         (conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, 'user', 'cross tenant', $3)`,
      [CONVERSATION_ID, USER_B, RUN_ID],
    )).rejects.toThrow();
  });

  it('deduplicates each client dispatch role for one tenant', async () => {
    await db.query(
      'INSERT INTO rem_conversations (id, user_id, title) VALUES ($1, $2, $3)',
      [CONVERSATION_ID, USER_A, 'Owned chat'],
    );
    await db.query(
      `INSERT INTO rem_conversation_messages
         (conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, 'user', 'hello', $3)`,
      [CONVERSATION_ID, USER_A, RUN_ID],
    );
    await expect(db.query(
      `INSERT INTO rem_conversation_messages
         (conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, 'user', 'duplicate', $3)`,
      [CONVERSATION_ID, USER_A, RUN_ID],
    )).rejects.toThrow();
    await expect(db.query(
      `INSERT INTO rem_conversation_messages
         (conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, 'assistant', 'reply', $3)`,
      [CONVERSATION_ID, USER_A, RUN_ID],
    )).resolves.toBeTruthy();
  });

  it('retains a deletion tombstone while allowing message content to be purged', async () => {
    await db.query(
      'INSERT INTO rem_conversations (id, user_id, title) VALUES ($1, $2, $3)',
      [CONVERSATION_ID, USER_A, 'Owned chat'],
    );
    await db.query(
      `INSERT INTO rem_conversation_messages
         (conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, 'user', 'private content', $3)`,
      [CONVERSATION_ID, USER_A, RUN_ID],
    );
    await db.query(
      `UPDATE rem_conversations SET title = NULL, deleted_at = NOW()
        WHERE id = $1 AND user_id = $2`,
      [CONVERSATION_ID, USER_A],
    );
    await db.query(
      'DELETE FROM rem_conversation_messages WHERE conversation_id = $1 AND user_id = $2',
      [CONVERSATION_ID, USER_A],
    );
    const retry = await db.query(
      `INSERT INTO rem_conversations (id, user_id, title)
       VALUES ($1, $2, 'resurrected') ON CONFLICT (id) DO NOTHING RETURNING id`,
      [CONVERSATION_ID, USER_A],
    );
    expect(retry.rows).toEqual([]);
    const state = await db.query(
      `SELECT title, deleted_at IS NOT NULL AS deleted,
              (SELECT COUNT(*)::int FROM rem_conversation_messages
                WHERE conversation_id = rem_conversations.id) AS message_count
         FROM rem_conversations WHERE id = $1`,
      [CONVERSATION_ID],
    );
    expect(state.rows).toEqual([{ title: null, deleted: true, message_count: 0 }]);
  });

  it('cascades every conversation row when the account is deleted', async () => {
    await db.query(
      'INSERT INTO rem_conversations (id, user_id, title) VALUES ($1, $2, $3)',
      [CONVERSATION_ID, USER_A, 'Owned chat'],
    );
    await db.query(
      `INSERT INTO rem_conversation_messages
         (conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, 'user', 'private content', $3)`,
      [CONVERSATION_ID, USER_A, RUN_ID],
    );
    await db.query('DELETE FROM users WHERE id = $1', [USER_A]);
    const conversations = await db.query('SELECT id FROM rem_conversations');
    const messages = await db.query('SELECT id FROM rem_conversation_messages');
    expect(conversations.rows).toEqual([]);
    expect(messages.rows).toEqual([]);
  });
});
