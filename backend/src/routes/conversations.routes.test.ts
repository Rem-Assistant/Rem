import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const USER_ID = '11111111-1111-4111-8111-111111111111';
const CONVERSATION_ID = '22222222-2222-4222-8222-222222222222';
const RUN_ID = '33333333-3333-4333-8333-333333333333';
const TASK_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const PROPOSAL_ID = '66666666-6666-4666-8666-666666666666';
const CREATED_AT = '2026-09-05T20:00:00.000Z';

const clientMock = vi.hoisted(() => ({ query: vi.fn(), release: vi.fn() }));
const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
const runtimeConversationPoolMock = vi.hoisted(() => ({ connect: vi.fn() }));
const runtimeMock = vi.hoisted(() => vi.fn());
const executeProposalMock = vi.hoisted(() => vi.fn());

vi.mock('../db/pool.js', () => ({
  pool: poolMock,
  runtimeConversationPool: runtimeConversationPoolMock,
}));
vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = '11111111-1111-4111-8111-111111111111';
    next();
  },
}));
vi.mock('../runtime/agent-runtime.service.js', () => ({
  runAgentTurnOnSharedRuntime: runtimeMock,
}));
vi.mock('../runtime/rem-conversation-task-tool-execution.js', () => ({
  executeConversationTaskProposal: executeProposalMock,
}));

const { default: conversationRoutes, conversationPrompt } = await import('./conversations.routes.js');

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', conversationRoutes);
  return app;
}

function conversationRow(overrides: Record<string, unknown> = {}) {
  return {
    id: CONVERSATION_ID,
    title: null,
    created_at: CREATED_AT,
    updated_at: CREATED_AT,
    last_message_preview: null,
    message_count: 0,
    ...overrides,
  };
}

function messageRow(role: 'user' | 'assistant', content: string, seq?: string) {
  return {
    id: role === 'user'
      ? '44444444-4444-4444-8444-444444444444'
      : '55555555-5555-4555-8555-555555555555',
    role,
    conversation_id: CONVERSATION_ID,
    seq: seq ?? (role === 'user' ? '1' : '2'),
    content,
    run_id: RUN_ID,
    created_at: CREATED_AT,
  };
}

function proposalRow(overrides: Record<string, unknown> = {}) {
  return {
    id: PROPOSAL_ID,
    assistant_message_id: '55555555-5555-4555-8555-555555555555',
    task_id: TASK_ID,
    task_title: 'Renew permit',
    proposed_status: 'completed',
    explanation: 'The user said this is complete.',
    state: 'pending',
    effect_id: null,
    failure_code: null,
    created_at: CREATED_AT,
    updated_at: CREATED_AT,
    resolved_at: null,
    ...overrides,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  runtimeConversationPoolMock.connect.mockResolvedValue(clientMock);
  runtimeMock.mockResolvedValue({
    ok: true,
    text: 'A Rem-owned reply',
    runId: RUN_ID,
    sessionKey: `rem-chat-${CONVERSATION_ID}`,
    model: 'test-model',
    provenance: { runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed' },
    toolCalls: [],
  });
  executeProposalMock.mockResolvedValue({
    kind: 'succeeded',
    task: { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', status: 'completed' },
    effectId: '77777777-7777-4777-8777-777777777777',
    replayed: false,
  });
});

describe('Rem-owned ordinary conversation lifecycle', () => {
  it('creates idempotently inside the authenticated tenant', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [conversationRow()] });
    const response = await request(testApp())
      .post('/api/v1/conversations')
      .send({ id: CONVERSATION_ID });
    expect(response.status).toBe(201);
    expect(response.body.session_key).toBe(`rem-chat-${CONVERSATION_ID}`);
    expect(poolMock.query.mock.calls[0][1]).toEqual([CONVERSATION_ID, USER_ID, null]);
  });

  it('does not resurrect a tombstoned conversation on a delayed create retry', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [conversationRow({ deleted_at: CREATED_AT })] });
    const response = await request(testApp())
      .post('/api/v1/conversations')
      .send({ id: CONVERSATION_ID });
    expect(response.status).toBe(410);
    expect(response.body.error).toContain('deleted');
  });

  it('lists only live tenant rows with bounded keyset pagination', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [
        conversationRow({ title: 'First', last_message_preview: 'latest', message_count: '2' }),
        conversationRow({ id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }),
      ],
    });
    const response = await request(testApp()).get('/api/v1/conversations?limit=1');
    expect(response.status).toBe(200);
    expect(response.body.conversations).toHaveLength(1);
    expect(response.body.conversations[0]).toMatchObject({ title: 'First', message_count: 2 });
    expect(response.body.next_cursor).toEqual(expect.any(String));
    expect(poolMock.query.mock.calls[0][0]).toContain('c.deleted_at IS NULL');
    expect(poolMock.query.mock.calls[0][1]).toEqual([USER_ID, null, null, 2]);
  });

  it('rejects malformed pagination limits rather than partially parsing them', async () => {
    const response = await request(testApp()).get('/api/v1/conversations?limit=1x');
    expect(response.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('reads history only after proving conversation ownership', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: CONVERSATION_ID }] })
      .mockResolvedValueOnce({ rows: [messageRow('user', 'hello'), messageRow('assistant', 'hi')] })
      .mockResolvedValueOnce({ rows: [proposalRow()] });
    const response = await request(testApp()).get(`/api/v1/conversations/${CONVERSATION_ID}`);
    expect(response.status).toBe(200);
    expect(response.body.messages.map((item: any) => item.content)).toEqual(['hello', 'hi']);
    expect(response.body.tool_proposals).toEqual([expect.objectContaining({
      id: PROPOSAL_ID,
      task_id: TASK_ID,
      patch: { status: 'completed' },
      state: 'pending',
    })]);
    expect(poolMock.query.mock.calls[0][0]).toContain('user_id = $2::uuid');
    expect(poolMock.query.mock.calls[0][1]).toEqual([CONVERSATION_ID, USER_ID]);
    expect(poolMock.query.mock.calls[1][0]).toContain('LIMIT $4');
    expect(poolMock.query.mock.calls[1][1]).toEqual([CONVERSATION_ID, USER_ID, null, 101]);
  });

  it('returns only the newest bounded history page and a cursor for older messages', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: CONVERSATION_ID }] })
      .mockResolvedValueOnce({
        rows: [
          messageRow('user', 'older overflow', '1'),
          messageRow('assistant', 'middle', '2'),
          messageRow('user', 'newest', '3'),
        ],
      })
      .mockResolvedValueOnce({ rows: [] });
    const response = await request(testApp()).get(`/api/v1/conversations/${CONVERSATION_ID}?limit=2`);
    expect(response.status).toBe(200);
    expect(response.body.messages.map((item: any) => item.content)).toEqual(['middle', 'newest']);
    expect(response.body.next_cursor).toEqual(expect.any(String));
    expect(poolMock.query.mock.calls[1][1]).toEqual([CONVERSATION_ID, USER_ID, null, 3]);

    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: CONVERSATION_ID }] })
      .mockResolvedValueOnce({ rows: [messageRow('user', 'older overflow', '1')] })
      .mockResolvedValueOnce({ rows: [] });
    const older = await request(testApp()).get(
      `/api/v1/conversations/${CONVERSATION_ID}?limit=2&cursor=${encodeURIComponent(response.body.next_cursor)}`,
    );
    expect(older.status).toBe(200);
    expect(older.body.messages.map((item: any) => item.content)).toEqual(['older overflow']);
    expect(older.body.next_cursor).toBeNull();
    expect(poolMock.query.mock.calls[4][1]).toEqual([CONVERSATION_ID, USER_ID, '2', 3]);
  });

  it('rejects a history cursor outside the PostgreSQL BIGINT range before querying', async () => {
    const cursor = Buffer.from(JSON.stringify({ beforeSeq: '9223372036854775808' })).toString('base64url');
    const response = await request(testApp()).get(
      `/api/v1/conversations/${CONVERSATION_ID}?cursor=${encodeURIComponent(cursor)}`,
    );
    expect(response.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('returns no history when the authenticated tenant does not own the conversation', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const response = await request(testApp()).get(`/api/v1/conversations/${CONVERSATION_ID}`);
    expect(response.status).toBe(404);
    expect(poolMock.query).toHaveBeenCalledOnce();
    expect(poolMock.query.mock.calls[0][0]).toContain('user_id = $2::uuid');
  });

  it('renames only a live owned conversation', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [conversationRow({
        title: 'One line title',
        last_message_preview: 'still here',
        message_count: '7',
      })],
    });
    const response = await request(testApp())
      .patch(`/api/v1/conversations/${CONVERSATION_ID}`)
      .send({ title: ' One\nline   title ' });
    expect(response.status).toBe(200);
    expect(response.body.title).toBe('One line title');
    expect(response.body.last_message_preview).toBe('still here');
    expect(response.body.message_count).toBe(7);
    expect(poolMock.query.mock.calls[0][0]).toContain('COUNT(*)::bigint AS message_count');
    expect(poolMock.query.mock.calls[0][1]).toEqual([CONVERSATION_ID, USER_ID, 'One line title']);
  });

  it('deletes content and runtime output while retaining the tombstone', async () => {
    clientMock.query.mockImplementation(async (sql: string, values?: any[]) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('ON CONFLICT (id) DO UPDATE')) return { rows: [{ id: CONVERSATION_ID }] };
      return { rows: [] };
    });
    const response = await request(testApp()).delete(`/api/v1/conversations/${CONVERSATION_ID}`);
    expect(response.status).toBe(204);
    const calls = clientMock.query.mock.calls;
    expect(calls[1][1]).toEqual([`rem-conversation:${USER_ID}:${CONVERSATION_ID}`]);
    expect(calls.map((call) => call[0])).toEqual([
      'BEGIN',
      expect.stringContaining('pg_try_advisory_xact_lock'),
      expect.stringContaining('ON CONFLICT (id) DO UPDATE'),
      expect.stringContaining('DELETE FROM rem_conversation_messages'),
      expect.stringContaining('DELETE FROM rem_agent_runs'),
      'COMMIT',
    ]);
    expect(calls[4][1]).toEqual([USER_ID, `rem-chat-${CONVERSATION_ID}`]);
    expect(clientMock.release).toHaveBeenCalledOnce();
  });

  it('persists a tombstone via upsert even when the create has not arrived yet', async () => {
    // Requests can reorder on the wire, so a delete may land before the create for the
    // same client-chosen id. The route must WRITE a tombstone (INSERT ... ON CONFLICT DO
    // UPDATE setting deleted_at), never a bare UPDATE that hits 0 rows — otherwise a
    // delayed create retry resurrects the deleted conversation.
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('ON CONFLICT (id) DO UPDATE')) return { rows: [{ id: CONVERSATION_ID }] };
      return { rows: [] };
    });
    const response = await request(testApp()).delete(`/api/v1/conversations/${CONVERSATION_ID}`);
    expect(response.status).toBe(204);
    const tombstoneSql = clientMock.query.mock.calls
      .map((call) => String(call[0]))
      .find((sql) => sql.includes('rem_conversations') && sql.includes('deleted_at'));
    expect(tombstoneSql).toBeDefined();
    expect(tombstoneSql).toContain('INSERT INTO rem_conversations');
    expect(tombstoneSql).toContain('ON CONFLICT (id)');
    // A persisted tombstone means the purge of prior content still runs.
    expect(clientMock.query.mock.calls.map((call) => call[0])).toEqual([
      'BEGIN',
      expect.stringContaining('pg_try_advisory_xact_lock'),
      expect.stringContaining('ON CONFLICT (id) DO UPDATE'),
      expect.stringContaining('DELETE FROM rem_conversation_messages'),
      expect.stringContaining('DELETE FROM rem_agent_runs'),
      'COMMIT',
    ]);
  });

  it('fails retryably without mutation when another turn owns the conversation lock', async () => {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: false }] };
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'Latest turn', idempotency_key: RUN_ID });
    expect(response.status).toBe(409);
    expect(runtimeMock).not.toHaveBeenCalled();
    expect(clientMock.query.mock.calls.map((call) => call[0])).toEqual([
      'BEGIN',
      expect.stringContaining('pg_try_advisory_xact_lock'),
      'ROLLBACK',
    ]);
    expect(clientMock.release).toHaveBeenCalledOnce();
  });

  it('continues on the proposal-only Rem runtime and commits both visible turns atomically', async () => {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) return { rows: [] };
      if (sql.includes(') recent ORDER BY')) return { rows: [{ role: 'user', content: 'Earlier turn' }] };
      if (sql.includes('INSERT INTO rem_conversation_messages')) {
        return { rows: [messageRow('user', 'Latest turn'), messageRow('assistant', 'A Rem-owned reply')] };
      }
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'Latest turn', idempotency_key: RUN_ID });
    expect(response.status).toBe(201);
    expect(response.body.message.content).toBe('A Rem-owned reply');
    expect(runtimeMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: USER_ID, authority: 'authenticated_user' },
      sessionKey: `rem-chat-${CONVERSATION_ID}`,
      idempotencyKey: RUN_ID,
      toolPolicy: {
        mode: 'observe',
        allowedTools: ['rem_task_update_proposal'],
        approval: 'none',
      },
    }));
    expect(runtimeMock.mock.calls[0][0].message).toContain('Earlier turn');
    expect(clientMock.query.mock.calls.map((call) => call[0]).at(-1)).toBe('COMMIT');
  });

  it('persists one validated task proposal without granting or executing it', async () => {
    runtimeMock.mockResolvedValueOnce({
      ok: true,
      text: 'I will mark it done.',
      runId: RUN_ID,
      sessionKey: `rem-chat-${CONVERSATION_ID}`,
      model: 'test-model',
      provenance: { runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed' },
      toolCalls: [{
        name: 'rem_task_update_proposal',
        toolCallId: 'proposal-call-1',
        args: {
          taskId: TASK_ID,
          patch: { status: 'completed' },
          comment: 'The user said this is complete.',
        },
      }],
    });
    clientMock.query.mockImplementation(async (sql: string, values?: any[]) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) return { rows: [] };
      if (sql.includes(') recent ORDER BY')) return { rows: [] };
      if (sql.includes('FROM tasks')) {
        return {
          rows: [{
            id: TASK_ID,
            title: 'Renew permit',
            status: 'pending',
            updated_at: CREATED_AT,
          }],
        };
      }
      if (sql.includes('INSERT INTO rem_conversation_messages')) {
        return {
          rows: [
            messageRow('user', 'Mark the permit task done'),
            messageRow('assistant', values?.[4] ?? 'missing assistant content'),
          ],
        };
      }
      if (sql.includes('INSERT INTO rem_conversation_task_proposals')) {
        return { rows: [proposalRow()] };
      }
      return { rows: [] };
    });

    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'Mark the permit task done', idempotency_key: RUN_ID });

    expect(response.status).toBe(201);
    expect(response.body.message.content).toContain('Review the proposal to approve it');
    expect(response.body.message.content).not.toContain('mark it done');
    expect(response.body.tool_proposals).toEqual([expect.objectContaining({
      id: PROPOSAL_ID,
      task_id: TASK_ID,
      patch: { status: 'completed' },
      state: 'pending',
    })]);
    expect(executeProposalMock).not.toHaveBeenCalled();
    const proposalInsert = clientMock.query.mock.calls.find(([sql]) => (
      String(sql).includes('INSERT INTO rem_conversation_task_proposals')
    ));
    expect(proposalInsert?.[1]).toEqual([
      CONVERSATION_ID,
      USER_ID,
      '55555555-5555-4555-8555-555555555555',
      RUN_ID,
      'proposal-call-1',
      TASK_ID,
      'Renew permit',
      'completed',
      'pending',
      CREATED_AT,
      'The user said this is complete.',
    ]);
  });

  it('neutralizes the reply when a proposal targets a task outside the bounded context', async () => {
    runtimeMock.mockResolvedValueOnce({
      ok: true,
      text: 'I will mark it done.',
      runId: RUN_ID,
      sessionKey: `rem-chat-${CONVERSATION_ID}`,
      model: 'test-model',
      provenance: { runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed' },
      toolCalls: [{
        name: 'rem_task_update_proposal',
        toolCallId: 'proposal-call-1',
        args: { taskId: TASK_ID, patch: { status: 'completed' }, comment: 'The user said this is complete.' },
      }],
    });
    clientMock.query.mockImplementation(async (sql: string, values?: any[]) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) return { rows: [] };
      if (sql.includes(') recent ORDER BY')) return { rows: [] };
      if (sql.includes('FROM tasks')) {
        // The only task in the bounded context is a DIFFERENT task than the one proposed.
        return { rows: [{ id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', title: 'Unrelated', status: 'pending', updated_at: CREATED_AT }] };
      }
      if (sql.includes('INSERT INTO rem_conversation_messages')) {
        return { rows: [messageRow('user', 'Mark the permit task done'), messageRow('assistant', values?.[4] ?? 'missing')] };
      }
      return { rows: [] };
    });

    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'Mark the permit task done', idempotency_key: RUN_ID });

    expect(response.status).toBe(201);
    expect(response.body.message.content).toContain('can only propose a status change for a task shown in this conversation');
    expect(response.body.message.content).not.toContain('mark it done');
    expect(response.body.message.content).not.toContain('Review the proposal');
    expect(response.body.tool_proposals).toEqual([]);
    expect(executeProposalMock).not.toHaveBeenCalled();
    expect(clientMock.query.mock.calls.find(([sql]) => (
      String(sql).includes('INSERT INTO rem_conversation_task_proposals')
    ))).toBeUndefined();
  });

  it('neutralizes the reply when the model emits more than one proposal', async () => {
    runtimeMock.mockResolvedValueOnce({
      ok: true,
      text: 'I marked both tasks done.',
      runId: RUN_ID,
      sessionKey: `rem-chat-${CONVERSATION_ID}`,
      model: 'test-model',
      provenance: { runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed' },
      toolCalls: [
        { name: 'rem_task_update_proposal', toolCallId: 'c1', args: { taskId: TASK_ID, patch: { status: 'completed' }, comment: 'done one' } },
        { name: 'rem_task_update_proposal', toolCallId: 'c2', args: { taskId: TASK_ID, patch: { status: 'blocked' }, comment: 'done two' } },
      ],
    });
    clientMock.query.mockImplementation(async (sql: string, values?: any[]) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) return { rows: [] };
      if (sql.includes(') recent ORDER BY')) return { rows: [] };
      if (sql.includes('FROM tasks')) {
        return { rows: [{ id: TASK_ID, title: 'Renew permit', status: 'pending', updated_at: CREATED_AT }] };
      }
      if (sql.includes('INSERT INTO rem_conversation_messages')) {
        return { rows: [messageRow('user', 'update my tasks'), messageRow('assistant', values?.[4] ?? 'missing')] };
      }
      return { rows: [] };
    });

    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'update my tasks', idempotency_key: RUN_ID });

    expect(response.status).toBe(201);
    expect(response.body.message.content).toContain('can only propose a status change for a task shown in this conversation');
    expect(response.body.message.content).not.toContain('marked both');
    expect(response.body.tool_proposals).toEqual([]);
    expect(executeProposalMock).not.toHaveBeenCalled();
    expect(clientMock.query.mock.calls.find(([sql]) => (
      String(sql).includes('INSERT INTO rem_conversation_task_proposals')
    ))).toBeUndefined();
  });

  it.each([
    {
      name: 'one malformed proposal',
      toolCalls: [
        { name: 'rem_task_update_proposal', toolCallId: 'bad', rejected: true },
      ],
    },
    {
      name: 'one valid and one malformed proposal',
      toolCalls: [
        { name: 'rem_task_update_proposal', toolCallId: 'valid', args: { taskId: TASK_ID, patch: { status: 'completed' }, comment: 'Done' } },
        { name: 'rem_task_update_proposal', toolCallId: 'bad', rejected: true },
      ],
    },
  ])('neutralizes action-claiming prose after $name', async ({ toolCalls }) => {
    runtimeMock.mockResolvedValueOnce({
      ok: true,
      text: 'I updated the task.',
      runId: RUN_ID,
      sessionKey: `rem-chat-${CONVERSATION_ID}`,
      model: 'test-model',
      provenance: { runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed' },
      toolCalls,
    });
    clientMock.query.mockImplementation(async (sql: string, values?: any[]) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) return { rows: [] };
      if (sql.includes(') recent ORDER BY')) return { rows: [] };
      if (sql.includes('FROM tasks')) {
        return { rows: [{ id: TASK_ID, title: 'Renew permit', status: 'pending', updated_at: CREATED_AT }] };
      }
      if (sql.includes('INSERT INTO rem_conversation_messages')) {
        return { rows: [messageRow('user', 'update my task'), messageRow('assistant', values?.[4] ?? 'missing')] };
      }
      return { rows: [] };
    });

    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'update my task', idempotency_key: RUN_ID });

    expect(response.status).toBe(201);
    expect(response.body.message.content).toContain('can only propose a status change for a task shown in this conversation');
    expect(response.body.message.content).not.toContain('I updated');
    expect(response.body.tool_proposals).toEqual([]);
    expect(executeProposalMock).not.toHaveBeenCalled();
    expect(clientMock.query.mock.calls.find(([sql]) => (
      String(sql).includes('INSERT INTO rem_conversation_task_proposals')
    ))).toBeUndefined();
  });

  it('executes a proposal only from the separate authenticated approval endpoint', async () => {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/task-proposals/${PROPOSAL_ID}/approve`)
      .send({});
    expect(response.status).toBe(200);
    expect(executeProposalMock).toHaveBeenCalledWith({
      userId: USER_ID,
      conversationId: CONVERSATION_ID,
      proposalId: PROPOSAL_ID,
    });
    expect(response.body).toMatchObject({
      status: 'succeeded',
      effect_id: '77777777-7777-4777-8777-777777777777',
      replayed: false,
    });
    expect(clientMock.query.mock.calls.map((call) => call[0]).at(-1)).toBe('COMMIT');
  });

  it('dismisses a pending proposal idempotently without executing it', async () => {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('UPDATE rem_conversation_task_proposals')) return { rows: [{ id: PROPOSAL_ID }] };
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/task-proposals/${PROPOSAL_ID}/dismiss`)
      .send({});
    expect(response.status).toBe(204);
    expect(executeProposalMock).not.toHaveBeenCalled();
    expect(clientMock.query.mock.calls.map((call) => call[0]).at(-1)).toBe('COMMIT');
  });

  it('rolls back without transcript mutation when managed runtime quota is exhausted', async () => {
    runtimeMock.mockResolvedValueOnce({
      ok: false,
      reason: 'quota_exhausted',
      provenance: { runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed' },
      runState: 'terminal',
    });
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'Latest turn', idempotency_key: RUN_ID });
    expect(response.status).toBe(429);
    expect(response.body.reason).toBe('quota_exhausted');
    expect(clientMock.query.mock.calls.some((call) => (
      String(call[0]).includes('INSERT INTO rem_conversation_messages')
    ))).toBe(false);
    expect(clientMock.query.mock.calls.map((call) => call[0]).at(-1)).toBe('ROLLBACK');
  });

  it('replays an exact committed dispatch without calling the runtime again', async () => {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) {
        return { rows: [messageRow('user', 'same'), messageRow('assistant', 'prior reply')] };
      }
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'same', idempotency_key: RUN_ID });
    expect(response.status).toBe(200);
    expect(response.body.message.content).toBe('prior reply');
    expect(runtimeMock).not.toHaveBeenCalled();
  });

  it('rejects a reused dispatch before runtime work even if only its user row survived', async () => {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) return { rows: [messageRow('user', 'original')] };
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'different', idempotency_key: RUN_ID });
    expect(response.status).toBe(409);
    expect(runtimeMock).not.toHaveBeenCalled();
    expect(clientMock.query.mock.calls.map((call) => call[0]).at(-1)).toBe('ROLLBACK');
  });

  it('rejects a tenant-global dispatch key already used by another conversation before runtime work', async () => {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (sql.includes('pg_try_advisory_xact_lock')) return { rows: [{ acquired: true }] };
      if (sql.includes('SELECT id FROM rem_conversations')) return { rows: [{ id: CONVERSATION_ID }] };
      if (sql.includes('AND run_id =')) {
        return {
          rows: [{
            ...messageRow('user', 'original'),
            conversation_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          }],
        };
      }
      return { rows: [] };
    });
    const response = await request(testApp())
      .post(`/api/v1/conversations/${CONVERSATION_ID}/chat`)
      .send({ message: 'new conversation', idempotency_key: RUN_ID });
    expect(response.status).toBe(409);
    expect(response.body.error).toContain('another conversation');
    expect(runtimeMock).not.toHaveBeenCalled();
  });
});

describe('conversation prompt bounds', () => {
  it('keeps only the newest bounded transcript suffix and labels user data', () => {
    const prior = Array.from({ length: 45 }, (_, index) => ({
      role: index % 2 ? 'assistant' : 'user',
      content: `turn-${index}`,
    }));
    const prompt = conversationPrompt(prior, 'latest');
    expect(prompt).not.toContain('turn-0\n');
    expect(prompt).toContain('turn-44');
    expect(prompt).toContain('USER:\nlatest');
    expect(prompt.endsWith('REM:')).toBe(true);
  });
});
