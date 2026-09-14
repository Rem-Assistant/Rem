import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const migrationsDir = path.dirname(fileURLToPath(import.meta.url));
const USER_A = '11111111-1111-4111-8111-111111111111';
const USER_B = '22222222-2222-4222-8222-222222222222';
const CONVERSATION = '33333333-3333-4333-8333-333333333333';
const MESSAGE = '44444444-4444-4444-8444-444444444444';
const TASK = '55555555-5555-4555-8555-555555555555';
const RUN = '66666666-6666-4666-8666-666666666666';
const OTHER_CONVERSATION = '77777777-7777-4777-8777-777777777777';
const OTHER_MESSAGE = '88888888-8888-4888-8888-888888888888';

describe('ordinary-conversation task proposal authority (migration 135)', () => {
  let db: any;

  beforeEach(async () => {
    const { PGlite } = await import('@electric-sql/pglite');
    db = new PGlite();
    await db.exec('CREATE TABLE users (id UUID PRIMARY KEY)');
    await db.exec('CREATE TABLE channel_signals (id UUID PRIMARY KEY)');
    await db.query('INSERT INTO users (id) VALUES ($1), ($2)', [USER_A, USER_B]);
    for (const migration of [
      '006_create_tasks_table.sql',
      '125_create_rem_agent_runs.sql',
      '129_create_rem_capability_effects.sql',
      '130_add_rem_agent_run_tool_calls.sql',
      '131_add_capability_grant_approval_key.sql',
      '132_add_rem_tool_effect_proposal_lineage.sql',
      '134_create_rem_conversations.sql',
      '135_create_rem_conversation_task_proposals.sql',
    ]) {
      const sql = fs.readFileSync(path.join(migrationsDir, migration), 'utf8');
      await db.exec(sql);
      if (migration === '135_create_rem_conversation_task_proposals.sql') await db.exec(sql);
    }
    await db.query(
      `INSERT INTO tasks (id, user_id, title, status)
       VALUES ($1, $2, 'Renew permit', 'pending')`,
      [TASK, USER_A],
    );
    await db.query(
      `INSERT INTO rem_conversations (id, user_id, title)
       VALUES ($1, $2, 'Tasks'), ($3, $4, 'Other tasks')`,
      [CONVERSATION, USER_A, OTHER_CONVERSATION, USER_B],
    );
    await db.query(
      `INSERT INTO rem_conversation_messages
         (id, conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, $3, 'assistant', 'Review this proposal', $4)`,
      [MESSAGE, CONVERSATION, USER_A, RUN],
    );
    await db.query(
      `INSERT INTO rem_conversation_messages
         (id, conversation_id, user_id, role, content, run_id)
       VALUES ($1, $2, $3, 'assistant', 'Other review', $4)`,
      [OTHER_MESSAGE, OTHER_CONVERSATION, USER_B, RUN],
    );
  }, 60_000);

  afterEach(async () => {
    await db?.close();
  });

  async function insertProposal(userId = USER_A) {
    return db.query(
      `INSERT INTO rem_conversation_task_proposals
         (conversation_id, user_id, assistant_message_id, proposal_run_id, tool_call_id,
          task_id, task_title, proposed_status, expected_task_status,
          expected_task_updated_at, explanation)
       VALUES ($1, $2, $3, $4, 'call-1', $5, 'Renew permit', 'completed',
               'pending', NOW(), 'The user said this is complete')
       RETURNING id`,
      [CONVERSATION, userId, MESSAGE, RUN, TASK],
    );
  }

  it('binds a proposal to the same tenant as its durable conversation and assistant message', async () => {
    await expect(insertProposal(USER_B)).rejects.toThrow();
    await expect(db.query(
      `INSERT INTO rem_conversation_task_proposals
         (conversation_id, user_id, assistant_message_id, proposal_run_id, tool_call_id,
          task_id, task_title, proposed_status, expected_task_status,
          expected_task_updated_at, explanation)
       VALUES ($1, $2, $3, $4, 'cross-message', $5, 'Renew permit', 'completed',
               'pending', NOW(), 'Cross-tenant assistant message')`,
      [OTHER_CONVERSATION, USER_B, MESSAGE, RUN, TASK],
    )).rejects.toThrow();
    await expect(insertProposal()).resolves.toBeTruthy();
    await expect(insertProposal()).rejects.toThrow();
  });

  it('requires an effect before a proposal can claim success', async () => {
    const proposal = await insertProposal();
    await expect(db.query(
      `UPDATE rem_conversation_task_proposals
          SET state = 'succeeded', resolved_at = NOW()
        WHERE id = $1`,
      [proposal.rows[0].id],
    )).rejects.toThrow();
    await expect(db.query(
      `UPDATE rem_conversation_task_proposals
          SET state = 'dismissed', resolved_at = NOW()
        WHERE id = $1`,
      [proposal.rows[0].id],
    )).resolves.toBeTruthy();
  });

  it('keeps proposal history if the target task disappears and purges it with conversation content', async () => {
    await insertProposal();
    await db.query('DELETE FROM tasks WHERE id = $1 AND user_id = $2', [TASK, USER_A]);
    expect((await db.query('SELECT id FROM rem_conversation_task_proposals')).rows).toHaveLength(1);
    await db.query('DELETE FROM rem_conversation_messages WHERE id = $1', [MESSAGE]);
    expect((await db.query('SELECT id FROM rem_conversation_task_proposals')).rows).toEqual([]);
  });

  it('cascades all proposal content when the account is deleted', async () => {
    await insertProposal();
    await db.query('DELETE FROM users WHERE id = $1', [USER_A]);
    expect((await db.query('SELECT id FROM rem_conversation_task_proposals')).rows).toEqual([]);
  });
});
