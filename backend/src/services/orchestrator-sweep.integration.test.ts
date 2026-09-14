/**
 * Real-Postgres integration test for the orchestrator sweep (#922). Unlike the mocked
 * unit test (orchestrator-sweep.service.test.ts), this runs every migration against a
 * REAL database and exercises the actual INSERT/UPDATE the sweep performs — so it would
 * have caught the CHECK-constraint violation the mocked test could not (the sweep writes
 * status, comment, task context, grant, and effect settlement as one audited product outcome.
 *
 * Guarded on TEST_DATABASE_URL (same convention as usage.integration.test.ts): only runs
 * under `npm run test:integration` with a throwaway Postgres pointed at by that env var.
 */
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import pg from 'pg';

const testDatabaseUrl = process.env.TEST_DATABASE_URL?.trim();
if (!testDatabaseUrl) {
  throw new Error('TEST_DATABASE_URL is required for integration tests');
}
// The service imports the shared pool from db/pool.js, which reads DATABASE_URL at import.
process.env.DATABASE_URL = testDatabaseUrl;

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationsDir = path.join(__dirname, '..', 'db', 'migrations');

const USER_ID = 'a1111111-1111-4111-8111-111111111111';
const NOW = new Date('2026-06-30T15:00:00.000Z');

let pool: pg.Pool;
// Imported lazily AFTER DATABASE_URL is set so the service's pool binds to the test DB.
let sweep: typeof import('./orchestrator-sweep.service.js');

async function runMigrations() {
  await pool.query('CREATE EXTENSION IF NOT EXISTS pgcrypto');
  const files = fs.readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
  for (const file of files) {
    await pool.query(fs.readFileSync(path.join(migrationsDir, file), 'utf8'));
  }
}

async function seedTask(overrides: { title?: string; startDate?: Date } = {}): Promise<string> {
  const { rows } = await pool.query(
    `INSERT INTO tasks (user_id, title, priority, status, type, start_date)
     VALUES ($1::uuid, $2, 'high', 'pending', 'task', $3::timestamptz)
     RETURNING id`,
    [USER_ID, overrides.title ?? 'Draft the Q3 outline', (overrides.startDate ?? NOW).toISOString()],
  );
  return rows[0].id.toString();
}

/** A provider stub that persists the exact observe-run evidence the real runtime would return. */
const okAgent = (
  reply: string,
  proposedStatus: 'pending' | 'completed' | 'in_progress' | 'blocked',
): import('./orchestrator-sweep.service.js').ReadyTaskAgentRunner => ({
  async run(input) {
    const proposalRunId = randomUUID();
    const toolCallId = `report-${proposalRunId}`;
    await pool.query(
      `INSERT INTO rem_agent_runs
         (id, user_id, idempotency_key, request_fingerprint, session_key, authority,
          tool_policy, state, owner_token, lease_expires_at, admitted_model, model,
          result_text, tool_calls, completed_at)
       VALUES ($1::uuid, $2::uuid, $3, $4, $5, 'trusted_automation', $6::jsonb,
               'succeeded', $7::uuid, NOW(), 'test-model', 'test-model', $8, $9::jsonb, NOW())`,
      [
        proposalRunId,
        input.task.userId,
        `proposal:${proposalRunId}`,
        'a'.repeat(64),
        input.sessionKey,
        JSON.stringify({ mode: 'observe', allowedTools: ['rem_task_report'], approval: 'none' }),
        randomUUID(),
        reply,
        JSON.stringify([{
          name: 'rem_task_report',
          toolCallId,
          args: { status: proposedStatus, comment: reply, task_context: 'Prepared result.' },
        }]),
      ],
    );
    return {
      ok: true as const,
      reply,
      proposedStatus,
      taskContext: 'Prepared result.',
      externalContentInfluenced: false,
      proposalRunId,
      toolCallId,
    };
  },
});
const allowScreen = () => ({ denied: false as const, categories: [] });

beforeAll(async () => {
  pool = new pg.Pool({ connectionString: testDatabaseUrl });
  await runMigrations();
  await pool.query(
    `INSERT INTO users (id, email) VALUES ($1::uuid, 'sweep-int@example.com')
     ON CONFLICT (id) DO NOTHING`,
    [USER_ID],
  );
  sweep = await import('./orchestrator-sweep.service.js');
});

afterAll(async () => {
  await pool.query('TRUNCATE TABLE rem_tool_effects, rem_capability_grants, rem_agent_runs, task_comments, task_chat_messages, tasks, users RESTART IDENTITY CASCADE');
  await pool.end();
});

beforeEach(async () => {
  await pool.query('TRUNCATE TABLE rem_tool_effects, rem_capability_grants, rem_agent_runs, task_comments, task_chat_messages, tasks RESTART IDENTITY CASCADE');
  await pool.query(
    `INSERT INTO users (id, email) VALUES ($1::uuid, 'sweep-int@example.com')
     ON CONFLICT (id) DO NOTHING`,
    [USER_ID],
  );
});

describe('orchestrator sweep against a real database', () => {
  it('C1: commits Rem comment, context, status, grant, and audited effect atomically', async () => {
    const taskId = await seedTask();

    const result = await sweep.runReadyTask(
      { id: taskId, userId: USER_ID, title: 'Draft the Q3 outline', description: null, status: 'pending', priority: 'high' },
      NOW,
      { agent: okAgent('Drafted the outline and prepared next steps.', 'completed'), screen: allowScreen },
    );

    expect(result.status).toBe('executed');
    expect(result.appliedStatus).toBe('completed');
    expect(result.commentId).not.toBeNull();

    // The comment points at the canonical Rem transcript and retains the Undo target.
    const comment = (
      await pool.query(
        `SELECT runtime, session_id, proposed_status, previous_status, author_label
           FROM task_comments WHERE id = $1::uuid`,
        [result.commentId],
      )
    ).rows[0];
    expect(comment.runtime).toBe('rem_runtime');
    expect(comment.session_id).toBe(`rem-task-${taskId}`);
    expect(comment.proposed_status).toBe('completed');
    expect(comment.previous_status).toBe('pending'); // Undo target
    expect(comment.author_label).toBe('Rem Orchestrator');

    const transcript = (
      await pool.query(
        `SELECT role, content, run_id IS NOT NULL AS has_run_id
           FROM task_chat_messages
          WHERE task_id = $1::uuid AND user_id = $2::uuid
          ORDER BY seq`,
        [taskId, USER_ID],
      )
    ).rows;
    expect(transcript).toEqual([
      { role: 'user', content: 'Work on "Draft the Q3 outline" now.', has_run_id: true },
      { role: 'assistant', content: 'Drafted the outline and prepared next steps.', has_run_id: true },
    ]);

    // Status + terminal run_status were applied in the same transaction as the comment.
    const t = (await pool.query('SELECT status, run_status, description FROM tasks WHERE id = $1::uuid', [taskId])).rows[0];
    expect(t.status).toBe('completed');
    expect(t.run_status).toBe('done');
    expect(t.description).toContain('Prepared result.');
    const effect = (await pool.query(
      `SELECT e.state, e.approval_source, e.proposal_run_id IS NOT NULL AS has_proposal,
              g.grant_authority
         FROM rem_tool_effects e
         JOIN rem_capability_grants g ON g.id = e.grant_id`,
    )).rows[0];
    expect(effect).toEqual({
      state: 'succeeded',
      approval_source: 'automation_policy',
      has_proposal: true,
      grant_authority: 'internal_service',
    });
  });

  it('H3: reaps a claim stranded running past the stale threshold back to NULL', async () => {
    const taskId = await seedTask();
    // Simulate a tick that claimed the task then crashed before writing a terminal state,
    // long enough ago to be considered orphaned.
    const stale = new Date(NOW.getTime() - (sweep.STALE_CLAIM_MINUTES + 5) * 60_000);
    await pool.query(
      `UPDATE tasks SET run_status = 'running', run_id = 'dead-run', run_started_at = $2::timestamptz
        WHERE id = $1::uuid`,
      [taskId, stale.toISOString()],
    );

    const reaped = await sweep.reapStaleRunningClaims(NOW);
    expect(reaped).toBe(1);

    const t = (await pool.query('SELECT run_status, run_id FROM tasks WHERE id = $1::uuid', [taskId])).rows[0];
    expect(t.run_status).toBeNull();
    expect(t.run_id).toBeNull();

    // A fresh claim was NOT reaped: seed a recent one and confirm it survives.
    const recentTaskId = await seedTask();
    await pool.query(
      `UPDATE tasks SET run_status = 'running', run_started_at = $2::timestamptz WHERE id = $1::uuid`,
      [recentTaskId, NOW.toISOString()],
    );
    expect(await sweep.reapStaleRunningClaims(NOW)).toBe(0);
  });

  it('H3: does not reap a stale claim while its audited task effect is unresolved', async () => {
    const taskId = await seedTask();
    const stale = new Date(NOW.getTime() - (sweep.STALE_CLAIM_MINUTES + 5) * 60_000);
    await pool.query(
      `UPDATE tasks SET run_status = 'running', run_id = 'ambiguous-run',
              run_started_at = $2::timestamptz
        WHERE id = $1::uuid`,
      [taskId, stale.toISOString()],
    );
    const grantId = randomUUID();
    await pool.query(
      `INSERT INTO rem_capability_grants
         (id, user_id, capability_key, tool_name, scope_kind, approval_source,
          grant_authority, scope_fingerprint)
       VALUES ($1::uuid, $2::uuid, 'tasks.write', 'tasks.update', 'persistent',
               'automation_policy', 'internal_service', $3)`,
      [grantId, USER_ID, 'b'.repeat(64)],
    );
    const effectId = randomUUID();
    await pool.query(
      `INSERT INTO rem_tool_effects
         (id, user_id, admitted_run_id, grant_id, idempotency_key,
          request_fingerprint, session_key, tool_call_id, connector, capability_key,
          tool_name, approval_source, scope_fingerprint, state, owner_token,
          lease_expires_at, target_summary, risk_level, approved_at, started_at)
       VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6,
               $7, 'ambiguous-call', 'Rem Tasks', 'tasks.write', 'tasks.update',
               'automation_policy', $6, 'running', $8::uuid,
               NOW() + INTERVAL '5 minutes', $9, 'medium', NOW(), NOW())`,
      [
        effectId,
        USER_ID,
        randomUUID(),
        grantId,
        `ambiguous-effect:${effectId}`,
        'b'.repeat(64),
        `rem-task-${taskId}`,
        randomUUID(),
        `Update task ${taskId}`,
      ],
    );

    expect(await sweep.reapStaleRunningClaims(NOW)).toBe(0);
    expect((await pool.query('SELECT run_status FROM tasks WHERE id = $1::uuid', [taskId])).rows[0].run_status)
      .toBe('running');

    await pool.query(
      `UPDATE rem_tool_effects
          SET state = 'failed', completed_at = NOW(), result_summary = 'Not committed',
              failure_code = 'task_update_not_committed'
        WHERE id = $1::uuid`,
      [effectId],
    );
    expect(await sweep.reapStaleRunningClaims(NOW)).toBe(1);
  });

  it('M4: caps per user in SQL so one backlog can not consume every global slot', async () => {
    // Seed more due tasks for this user than the per-user cap allows.
    for (let i = 0; i < sweep.MAX_TASKS_PER_USER + 3; i++) {
      await seedTask({ title: `Backlog ${i}`, startDate: new Date(NOW.getTime() - i * 60_000) });
    }

    const ready = await sweep.findReadyTasks(NOW);
    expect(ready.filter((t) => t.userId === USER_ID)).toHaveLength(sweep.MAX_TASKS_PER_USER);
  });

  it('deny-list: records a blocked-for-review comment and never changes status', async () => {
    const taskId = await seedTask({ title: 'Send an email to the landlord about the lease' });

    const result = await sweep.runReadyTask(
      { id: taskId, userId: USER_ID, title: 'Send an email to the landlord about the lease', description: null, status: 'pending', priority: 'high' },
      NOW,
      { agent: okAgent('should not run', 'completed') }, // real deny screen
    );

    expect(result.status).toBe('denied');
    const t = (await pool.query('SELECT status, run_status FROM tasks WHERE id = $1::uuid', [taskId])).rows[0];
    expect(t.status).toBe('pending'); // never changed
    expect(t.run_status).toBe('blocked');
    const comment = (
      await pool.query('SELECT runtime, previous_status FROM task_comments WHERE id = $1::uuid', [result.commentId])
    ).rows[0];
    expect(comment.runtime).toBe('rem_runtime');
    expect(comment.previous_status).toBeNull(); // nothing applied → no Undo
  });
});
