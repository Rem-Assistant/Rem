import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const clientMock = vi.hoisted(() => ({
  query: vi.fn(),
  release: vi.fn(),
}));
const poolMock = vi.hoisted(() => ({
  query: vi.fn(),
  connect: vi.fn(),
}));
const poolClientMock = vi.hoisted(() => ({
  query: vi.fn(),
  release: vi.fn(),
}));

// The model completion is behind Rem's runtime boundary. Everything from the HTTP
// request down to the SQL — including the verdict read — is the real code.
const runAgentTurnOnSharedRuntimeMock = vi.hoisted(() => vi.fn());
const runAgentTurnMock = vi.hoisted(() => vi.fn());
const executeTaskStatusProposalMock = vi.hoisted(() => vi.fn());
vi.mock('../runtime/agent-runtime.service.js', () => ({
  runAgentTurnOnSharedRuntime: runAgentTurnOnSharedRuntimeMock,
  runAgentTurn: runAgentTurnMock,
}));
vi.mock('../runtime/rem-task-tool-execution.js', () => ({
  executeInteractiveTaskStatusProposal: executeTaskStatusProposalMock,
  executeTrustedAutomationTaskStatusProposal: vi.fn(),
}));

/** A successful Rem-runtime turn returning `text` verbatim. */
function runtimeReplies(text: string, toolCalls: unknown[] = []) {
  runAgentTurnOnSharedRuntimeMock.mockResolvedValueOnce({
    ok: true,
    text,
    runId: 'rem-run-1',
    sessionKey: 'rem-task-x',
    toolCalls,
    provenance: {
      runtimeId: 'rem_shared',
      persistenceKind: 'rem_runtime',
      billingMode: 'rem_managed',
    },
  });
}

vi.mock('../db/pool.js', () => ({
  pool: poolMock,
  taskConversationPool: { connect: async () => clientMock },
}));

// Only the mode LOOKUP is stubbed. It would otherwise issue its own SELECT through the pool
// mock and shift every positional query assertion in this file; the lookup's real behaviour is
// covered in run-block.test.ts. Everything else in `run-block.js` stays real.
const resolveModeMock = vi.hoisted(() => vi.fn());
vi.mock('../services/run-block.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/run-block.js')>()),
  resolveModelRuntimeMode: resolveModeMock,
}));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = 'f8679a96-0000-4000-8000-000000000001';
    next();
  },
}));

const TASK_ID = '11111111-1111-4111-8111-111111111111';
const USER_ID = 'f8679a96-0000-4000-8000-000000000001';

const taskRow = {
  id: TASK_ID,
  title: 'Clear inbox',
  status: 'pending',
  priority: 'medium',
  start_date: null,
  end_date: null,
  duration_minutes: null,
  alert_time: null,
  repeat_frequency: null,
  type: 'task',
  created_at: '2026-06-26T17:00:00.000Z',
  updated_at: '2026-06-26T17:00:00.000Z',
};

const tasksRoutes = (await import('./tasks.routes.js')).default;
const { TASK_VERDICT_TOOL_NAME } = await import('../services/task-verdict.js');

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', tasksRoutes);
  return app;
}

describe('task comments + agent-run routes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    poolClientMock.query.mockImplementation(async (sql: string, values?: unknown[]) => {
      if (/^\s*(BEGIN|COMMIT|ROLLBACK)\s*$/i.test(String(sql))) return { rows: [] };
      return poolMock.query(sql, values);
    });
    poolMock.connect.mockResolvedValue(poolClientMock);
    clientMock.query.mockImplementation(async (sql: string) =>
      String(sql).includes('pg_try_advisory_xact_lock')
        ? { rows: [{ acquired: true }] }
        : { rows: [] });
    // Default: runtime admission fails, so the route persists the degraded result.
    // Tests that need a real turn call `runtimeReplies(...)` first.
    runAgentTurnOnSharedRuntimeMock.mockResolvedValue({
      ok: false,
      reason: 'unavailable',
      provenance: {
        runtimeId: 'rem_shared',
        persistenceKind: 'rem_runtime',
        billingMode: 'rem_managed',
      },
    });
    runAgentTurnMock.mockResolvedValue({
      ok: false,
      reason: 'unavailable',
      provenance: {
        runtimeId: 'openclaw_gateway',
        persistenceKind: 'gateway',
        billingMode: 'byok',
      },
    });
    resolveModeMock.mockResolvedValue('rem_managed');
    executeTaskStatusProposalMock.mockResolvedValue({
      kind: 'not_applied', reason: 'execution_unavailable',
    });
  });

  it('posts a user comment with author_kind=user and author_label=You', async () => {
    poolMock.query
      // loadOwnedTask
      .mockResolvedValueOnce({ rows: [taskRow] })
      // INSERT ... RETURNING
      .mockResolvedValueOnce({
        rows: [
          {
            id: 'c0000000-0000-4000-8000-000000000001',
            task_id: TASK_ID,
            author_kind: 'user',
            author_label: 'You',
            body: 'Please draft a plan',
            proposed_status: null,
            runtime: null,
            created_at: '2026-06-26T17:01:00.000Z',
          },
        ],
      })
      // resetTaskStaleness — commenting is a user action (migration 116).
      .mockResolvedValueOnce({ rowCount: 1, rows: [] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/comments`)
      .send({ body: 'Please draft a plan' });

    expect(response.status).toBe(201);
    expect(response.body).toMatchObject({
      task_id: TASK_ID,
      author_kind: 'user',
      author_label: 'You',
      body: 'Please draft a plan',
      proposed_status: null,
      runtime: null,
    });

    // Writing about a task un-stales it (migration 116): the route must issue the reset, scoped to
    // the authenticated user AND this task id, or a user who answers the brief by commenting would
    // keep being asked.
    const reset = poolMock.query.mock.calls.find(
      ([sql]) => typeof sql === 'string' && /brief_surface_count = 0/.test(sql) && /stale_at = NULL/.test(sql),
    );
    expect(reset).toBeDefined();
    expect(reset![1]).toEqual([TASK_ID, USER_ID]);
    const taskFence = poolMock.query.mock.calls.find(
      ([sql]) => typeof sql === 'string' && /SELECT id FROM tasks/.test(sql) && /FOR UPDATE/.test(sql),
    );
    expect(taskFence).toBeDefined();
    expect(poolClientMock.query).toHaveBeenCalledWith('COMMIT');
  });

  it('rejects an empty comment body with 400', async () => {
    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/comments`)
      .send({ body: '   ' });

    expect(response.status).toBe(400);
  });

  it('rejects an invalid proposed_status with 400', async () => {
    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/comments`)
      .send({ body: 'ok', proposed_status: 'bogus' });

    expect(response.status).toBe(400);
  });

  it('returns 404 when the task is not owned by the user', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/comments`)
      .send({ body: 'hi' });

    expect(response.status).toBe(404);
  });

  it('lists comments ordered oldest-first', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] })
      .mockResolvedValueOnce({
        rows: [
          {
            id: 'c1',
            task_id: TASK_ID,
            author_kind: 'user',
            author_label: 'You',
            body: 'first',
            proposed_status: null,
            runtime: null,
            created_at: '2026-06-26T17:00:00.000Z',
          },
          {
            id: 'c2',
            task_id: TASK_ID,
            author_kind: 'cloud_agent',
            author_label: 'Rem Cloud (AgentBox)',
            body: 'second',
            proposed_status: 'in_progress',
            runtime: 'agentbox',
            created_at: '2026-06-26T17:05:00.000Z',
          },
        ],
      });

    const response = await request(testApp()).get(`/api/v1/tasks/${TASK_ID}/comments`);

    expect(response.status).toBe(200);
    expect(response.body.comments).toHaveLength(2);
    expect(response.body.comments[0].body).toBe('first');
    expect(response.body.comments[1]).toMatchObject({
      author_kind: 'cloud_agent',
      author_label: 'Rem Cloud (AgentBox)',
      runtime: 'agentbox',
      proposed_status: 'in_progress',
    });
    // Verify the ORDER BY created_at ASC clause is used.
    const listCall = poolMock.query.mock.calls[1][0] as string;
    expect(listCall).toContain('ORDER BY created_at ASC');
  });

  // The agent-run route now runs 6 queries in order:
  //   1 loadOwnedTask  2 load comments  3 UPDATE run_status='running'
  //   4 UPDATE terminal run_status RETURNING task  5 INSERT cloud_agent comment
  //   6 INSERT task_chat_messages (replayable transcript, migration 025)
  // This helper wires those mocks; `terminalRunStatus` is what the terminal UPDATE
  // RETURNING reports back, and the inserted comment echoes its bound values.
  function mockAgentRun(terminalRow: Record<string, unknown>) {
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] }) // loadOwnedTask
      .mockResolvedValueOnce({ rows: [] }) // load comments
      .mockResolvedValueOnce({ rows: [] }) // UPDATE running
      .mockResolvedValueOnce({ rows: [{ ...taskRow, ...terminalRow }] }) // UPDATE terminal
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        rows: [
          {
            id: 'c-agent',
            task_id: TASK_ID,
            author_kind: 'cloud_agent',
            author_label: 'Rem Cloud',
            body: values[2],
            proposed_status: values[3],
            runtime: values[5],
            created_at: '2026-06-26T17:10:00.000Z',
          },
        ],
      }))
      .mockResolvedValueOnce({ rows: [] }); // INSERT task_chat_messages transcript
  }

  it('agent-run lands an actionable comment when Rem-runtime admission fails', async () => {
    mockAgentRun({ run_status: 'blocked', run_id: 'run-1' });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.status).toBe(201);
    expect(response.body).toMatchObject({
      author_kind: 'cloud_agent',
      author_label: 'Rem Cloud',
      runtime: 'rem_runtime',
      proposed_status: null,
    });
    expect(response.body.body).toContain('not ready to run this task');

    // Confirm the insert is attributed to the runtime that actually ran.
    const insertCall = poolMock.query.mock.calls[4][0] as string;
    expect(insertCall).toContain("'cloud_agent'");
    expect(insertCall).toContain("'Rem Cloud'");
    expect((poolMock.query.mock.calls[4][1] as any[])[5]).toBe('rem_runtime');
    expect(insertCall).not.toContain("'agentbox'");
    expect(runAgentTurnMock).not.toHaveBeenCalled();
  });

  it('agent-run PERSISTS the structured block reason on the task and on the comment', async () => {
    // The founder's requirement, at the layer that can satisfy it: run history renders AFTER
    // the fact, so a reason that lives only in the HTTP response cannot be shown there. Both
    // rows carry `{ code, mode }` (migration 121) — the task for "how did the last run end",
    // the comment for "how did THAT run end" three runs later.
    runAgentTurnOnSharedRuntimeMock.mockResolvedValueOnce({
      ok: false,
      reason: 'unavailable',
      provenance: {
        runtimeId: 'rem_shared',
        persistenceKind: 'rem_runtime',
        billingMode: 'byok',
      },
    });
    mockAgentRun({ run_status: 'blocked', run_id: 'run-1' });

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    // Query #4 is the terminal task UPDATE. No status was applied, so the bound values are
    // [runStatus, blockCode, blockMode, taskId, userId].
    const terminal = poolMock.query.mock.calls[3];
    expect(String(terminal[0])).toContain('run_block_code = $2');
    expect(String(terminal[0])).toContain('run_block_mode = $3');
    expect((terminal[1] as any[])[1]).toBe('runtime_unavailable');
    expect((terminal[1] as any[])[2]).toBe('byok');

    // Query #5 is the comment INSERT: [taskId, userId, body, proposed, previous, runtime, runId, code, mode].
    const insert = poolMock.query.mock.calls[4];
    expect(String(insert[0])).toContain('run_block_code, run_block_mode');
    expect((insert[1] as any[])[7]).toBe('runtime_unavailable');
    expect((insert[1] as any[])[8]).toBe('byok');
  });

  it('agent-run CLEARS a previous block when the next run succeeds', async () => {
    // The reason the write is unconditional rather than bolted onto the error branch. A task
    // that failed yesterday and ran fine today must stop advertising "your runtime is
    // unavailable", or the user is told to fix something they already fixed.
    mockAgentRun({ run_status: 'review', run_id: 'run-2' });
    runtimeReplies('Looked into it.');

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    const terminal = poolMock.query.mock.calls[3];
    expect((terminal[1] as any[])[1]).toBeNull();
    expect((terminal[1] as any[])[2]).toBeNull();
    const insert = poolMock.query.mock.calls[4];
    expect((insert[1] as any[])[7]).toBeNull();
    expect((insert[1] as any[])[8]).toBeNull();
    // Provenance belongs to every runtime result; the route does not re-derive it.
    expect(resolveModeMock).not.toHaveBeenCalled();
  });

  it('agent-run returns the block reason on the wire, on the task and on the comment', async () => {
    // The live half of the same contract: the client that dispatched the run should not have
    // to re-fetch to learn why it failed.
    resolveModeMock.mockResolvedValue('rem_managed');
    mockAgentRun({
      run_status: 'blocked',
      run_id: 'run-1',
      run_block_code: 'runtime_unavailable',
      run_block_mode: 'rem_managed',
    });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.body.task_run).toMatchObject({
      run_status: 'blocked',
      run_block_code: 'runtime_unavailable',
      run_block_mode: 'rem_managed',
    });
    // And the comment row echoes the same pair, so an activity list needs no join. Asserted on
    // the value the INSERT actually bound, not merely on key presence — `formatComment` emits
    // `?? null` unconditionally, so `toHaveProperty` here could never fail.
    const insertedCode = (poolMock.query.mock.calls[4][1] as any[])[7];
    expect(insertedCode).toBe('runtime_unavailable');
  });

  it('agent-run dispatches a reporting-only Rem-runtime turn under the task session key', async () => {
    mockAgentRun({ run_status: 'review', run_id: 'run-1' });
    runtimeReplies('Looked into it.');

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    expect(runAgentTurnOnSharedRuntimeMock).toHaveBeenCalledWith(
      expect.objectContaining({
        principal: { userId: USER_ID, authority: 'authenticated_user' },
        sessionKey: `rem-task-${TASK_ID.toLowerCase()}`,
        toolPolicy: {
          mode: 'observe',
          allowedTools: [TASK_VERDICT_TOOL_NAME],
          approval: 'none',
        },
      }),
    );
    expect(String(clientMock.query.mock.calls[1][0])).toContain('pg_try_advisory_xact_lock');
    expect(String(clientMock.query.mock.calls.at(-1)?.[0])).toBe('ROLLBACK');
    expect(clientMock.release).toHaveBeenCalledOnce();
  });

  it('agent-run preserves proven BYOK fallback in a separate legacy recovery session', async () => {
    runAgentTurnOnSharedRuntimeMock.mockResolvedValueOnce({
      ok: false,
      reason: 'unavailable',
      provenance: {
        runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'byok',
      },
    });
    runAgentTurnMock.mockResolvedValueOnce({
      ok: true,
      text: 'Handled with your connected model.',
      runId: 'legacy-run',
      sessionKey: `openclaw-manual-task-${TASK_ID}`,
      toolCalls: [],
      provenance: {
        runtimeId: 'openclaw_gateway', persistenceKind: 'gateway', billingMode: 'byok',
      },
    });
    mockAgentRun({ run_status: 'review', run_id: 'run-legacy' });

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    expect(runAgentTurnMock).toHaveBeenCalledWith(expect.objectContaining({
      sessionKey: `openclaw-manual-task-${TASK_ID}`,
    }));
    const commentValues = poolMock.query.mock.calls[4][1] as any[];
    expect(commentValues[5]).toBe('gateway');
    expect(commentValues[6]).toBe(`openclaw-manual-task-${TASK_ID}`);
  });

  it('agent-run stamps run_status=running with a generated run_id BEFORE dispatch', async () => {
    mockAgentRun({ run_status: 'blocked', run_id: 'run-1' });

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    // Query #3 is the pre-dispatch UPDATE that marks the task as running.
    const runningCall = poolMock.query.mock.calls[2];
    const runningSql = runningCall[0] as string;
    const runningValues = runningCall[1] as any[];
    expect(runningSql).toContain("run_status = 'running'");
    expect(runningSql).toContain('run_started_at = NOW()');
    // run_id is a generated UUID bound as $1.
    expect(runningValues[0]).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
    // A STABLE per-task session_key (`rem-task-<taskId>`) is stamped at run START (bound
    // as $2) — the same scheme the orchestrator sweep uses — so the client's "Open
    // conversation" jump (P2) has a durable handle, not the run_id (which changes per run).
    expect(runningSql).toContain('session_key = $2');
    expect(runningValues[1]).toBe(`rem-task-${TASK_ID.toLowerCase()}`);
  });

  it('agent-run surfaces the new run-state on the response as task_run', async () => {
    mockAgentRun({ run_status: 'blocked', run_id: 'run-1' });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.body.task_run).toMatchObject({ run_status: 'blocked', run_id: 'run-1' });
  });

  it('agent-run persists a replayable transcript (user ask + assistant reply) keyed by run_id', async () => {
    mockAgentRun({ run_status: 'blocked', run_id: 'run-1' });

    await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({ instruction: 'Draft the filing' });

    // Query #6 is the transcript INSERT into task_chat_messages.
    const transcriptCall = poolMock.query.mock.calls[5];
    const transcriptSql = transcriptCall[0] as string;
    const transcriptValues = transcriptCall[1] as any[];
    expect(transcriptSql).toContain('INSERT INTO task_chat_messages');
    expect(transcriptSql).toContain("'user'");
    expect(transcriptSql).toContain("'assistant'");
    // Bound values: [taskId, userId, ask, runId, reply].
    expect(transcriptValues[0]).toBe(TASK_ID);
    expect(transcriptValues[1]).toBe(USER_ID);
    expect(transcriptValues[2]).toBe('Draft the filing'); // ask = the instruction
    // run_id stamped on the transcript matches the generated run UUID bound here.
    expect(transcriptValues[3]).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
    expect(transcriptValues[4]).toContain('not ready to run this task'); // reply = errored body
  });

  it('agent-run synthesizes the ask from the task title when no instruction is given', async () => {
    mockAgentRun({ run_status: 'review', run_id: 'run-2' });

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    const transcriptValues = poolMock.query.mock.calls[5][1] as any[];
    expect(transcriptValues[2]).toBe('Let\'s work on "Clear inbox".');
  });

  it('GET /tasks/:id/chat returns the persisted transcript ordered oldest-first', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] }) // loadOwnedTask
      .mockResolvedValueOnce({
        rows: [
          {
            id: 'm1',
            task_id: TASK_ID,
            role: 'user',
            content: 'Draft the filing',
            run_id: 'run-1',
            created_at: '2026-06-26T17:10:00.000Z',
          },
          {
            id: 'm2',
            task_id: TASK_ID,
            role: 'assistant',
            content: 'Here is a draft.',
            run_id: 'run-1',
            created_at: '2026-06-26T17:10:00.000Z',
          },
        ],
      });

    const response = await request(testApp()).get(`/api/v1/tasks/${TASK_ID}/chat`);

    expect(response.status).toBe(200);
    expect(response.body.messages).toHaveLength(2);
    expect(response.body.messages[0]).toMatchObject({ role: 'user', content: 'Draft the filing' });
    expect(response.body.messages[1]).toMatchObject({ role: 'assistant', content: 'Here is a draft.' });
    // Stable intra-run ordering comes from the seq column.
    const listCall = poolMock.query.mock.calls[1][0] as string;
    expect(listCall).toContain('ORDER BY seq ASC');
  });

  it('GET /tasks/:id/chat returns 404 when the task is not owned by the user', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });

    const response = await request(testApp()).get(`/api/v1/tasks/${TASK_ID}/chat`);

    expect(response.status).toBe(404);
  });

  it('POST /tasks/:id/chat continues on the Rem runtime and commits one durable turn pair', async () => {
    const dispatchID = '33333333-3333-4333-8333-333333333333';
    runtimeReplies('Start with the oldest unread threads.');
    clientMock.query
      .mockResolvedValueOnce({ rows: [] }) // BEGIN
      .mockResolvedValueOnce({ rows: [{ acquired: true }] }) // non-blocking task-scoped lock
      .mockResolvedValueOnce({ rows: [taskRow] }) // owned task
      .mockResolvedValueOnce({ rows: [] }) // no replayed assistant row
      .mockResolvedValueOnce({ rows: [{ role: 'user', content: 'Help me triage.' }] })
      .mockResolvedValueOnce({
        rows: [
          {
            id: 'm-user', task_id: TASK_ID, role: 'user', content: 'What first?',
            run_id: dispatchID, created_at: '2026-06-26T17:11:00.000Z',
          },
          {
            id: 'm-assistant', task_id: TASK_ID, role: 'assistant',
            content: 'Start with the oldest unread threads.', run_id: dispatchID,
            created_at: '2026-06-26T17:11:00.000Z',
          },
        ],
      })
      .mockResolvedValueOnce({ rows: [] }); // COMMIT

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/chat`)
      .send({ message: 'What first?', idempotency_key: dispatchID });

    expect(response.status).toBe(201);
    expect(response.body).toMatchObject({
      run_id: dispatchID,
      session_key: `rem-task-${TASK_ID}`,
      status: 'completed',
      message: { role: 'assistant', content: 'Start with the oldest unread threads.' },
    });
    expect(runAgentTurnOnSharedRuntimeMock).toHaveBeenCalledWith(expect.objectContaining({
      principal: { userId: USER_ID, authority: 'authenticated_user' },
      sessionKey: `rem-task-${TASK_ID}`,
      idempotencyKey: dispatchID,
      requestIdentity: expect.stringMatching(/^task-chat:.*:[0-9a-f]{64}$/),
      toolPolicy: { mode: 'observe', allowedTools: [], approval: 'none' },
      message: expect.stringContaining('PRIOR CONVERSATION (oldest to newest):\nUSER: Help me triage.'),
    }));
    const insert = clientMock.query.mock.calls[5];
    expect(String(insert[0])).toContain('ON CONFLICT (user_id, run_id, role)');
    expect(insert[1]).toEqual([TASK_ID, USER_ID, 'What first?', dispatchID, 'Start with the oldest unread threads.']);
    expect(clientMock.release).toHaveBeenCalledOnce();
  });

  it('POST /tasks/:id/chat replays a persisted dispatch without invoking the runtime', async () => {
    const dispatchID = '33333333-3333-4333-8333-333333333333';
    clientMock.query
      .mockResolvedValueOnce({ rows: [] }) // BEGIN
      .mockResolvedValueOnce({ rows: [{ acquired: true }] }) // non-blocking task-scoped lock
      .mockResolvedValueOnce({ rows: [taskRow] }) // owned task
      .mockResolvedValueOnce({
        rows: [
          {
            id: 'm-user', task_id: TASK_ID, role: 'user', content: 'What first?',
            run_id: dispatchID, created_at: '2026-06-26T17:11:00.000Z',
          },
          {
            id: 'm-assistant', task_id: TASK_ID, role: 'assistant', content: 'Already answered.',
            run_id: dispatchID, created_at: '2026-06-26T17:11:00.000Z',
          },
        ],
      })
      .mockResolvedValueOnce({ rows: [] }); // COMMIT

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/chat`)
      .send({ message: 'What first?', idempotency_key: dispatchID });

    expect(response.status).toBe(200);
    expect(response.body.message.content).toBe('Already answered.');
    expect(runAgentTurnOnSharedRuntimeMock).not.toHaveBeenCalled();
  });

  it('POST /tasks/:id/chat rejects reuse of a dispatch id for different text', async () => {
    const dispatchID = '33333333-3333-4333-8333-333333333333';
    clientMock.query
      .mockResolvedValueOnce({ rows: [] }) // BEGIN
      .mockResolvedValueOnce({ rows: [{ acquired: true }] }) // non-blocking task-scoped lock
      .mockResolvedValueOnce({ rows: [taskRow] }) // owned task
      .mockResolvedValueOnce({
        rows: [
          {
            id: 'm-user', task_id: TASK_ID, role: 'user', content: 'Original text',
            run_id: dispatchID, created_at: '2026-06-26T17:11:00.000Z',
          },
          {
            id: 'm-assistant', task_id: TASK_ID, role: 'assistant', content: 'Original answer',
            run_id: dispatchID, created_at: '2026-06-26T17:11:00.000Z',
          },
        ],
      })
      .mockResolvedValueOnce({ rows: [] }); // ROLLBACK

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/chat`)
      .send({ message: 'Different text', idempotency_key: dispatchID });

    expect(response.status).toBe(409);
    expect(runAgentTurnOnSharedRuntimeMock).not.toHaveBeenCalled();
  });

  it('POST /tasks/:id/chat rolls back a failed runtime turn without writing partial history', async () => {
    const dispatchID = '33333333-3333-4333-8333-333333333333';
    runAgentTurnOnSharedRuntimeMock.mockResolvedValueOnce({
      ok: false,
      reason: 'quota_exhausted',
      provenance: {
        runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed',
      },
    });
    clientMock.query
      .mockResolvedValueOnce({ rows: [] }) // BEGIN
      .mockResolvedValueOnce({ rows: [{ acquired: true }] }) // non-blocking lock
      .mockResolvedValueOnce({ rows: [taskRow] })
      .mockResolvedValueOnce({ rows: [] }) // replay lookup
      .mockResolvedValueOnce({ rows: [] }) // transcript
      .mockResolvedValueOnce({ rows: [] }); // ROLLBACK

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/chat`)
      .send({ message: 'Continue', idempotency_key: dispatchID });

    expect(response.status).toBe(429);
    expect(response.body.error).toContain('Upgrade or wait');
    expect(clientMock.query.mock.calls.map(([sql]) => String(sql))).not.toEqual(
      expect.arrayContaining([expect.stringContaining('INSERT INTO task_chat_messages')]),
    );
  });

  it('POST /tasks/:id/chat fails fast when another turn owns the task lock', async () => {
    clientMock.query
      .mockResolvedValueOnce({ rows: [] }) // BEGIN
      .mockResolvedValueOnce({ rows: [{ acquired: false }] })
      .mockResolvedValueOnce({ rows: [] }); // ROLLBACK

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/chat`)
      .send({
        message: 'Do not queue this behind a long turn',
        idempotency_key: '33333333-3333-4333-8333-333333333333',
      });

    expect(response.status).toBe(409);
    expect(runAgentTurnOnSharedRuntimeMock).not.toHaveBeenCalled();
    expect(clientMock.release).toHaveBeenCalledOnce();
  });

  it('agent-run maps a completed verdict to run_status=done and applies the status', async () => {
    // Real service path: the Rem-runtime turn carries the verdict envelope, `task-verdict`
    // reads it, and terminalRunStatus maps it to 'done'.
    runtimeReplies('Wrapped it up.\nrem.task_verdict.v1 {"status":"completed"}');
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] }) // loadOwnedTask
      .mockResolvedValueOnce({ rows: [] }) // load comments
      .mockResolvedValueOnce({ rows: [] }) // UPDATE running
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        // UPDATE terminal — echo the bound run_status so we can assert the mapping.
        rows: [{ ...taskRow, run_status: values[0], run_id: 'run-1' }],
      }))
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        rows: [
          {
            id: 'c-agent',
            task_id: TASK_ID,
            author_kind: 'cloud_agent',
            author_label: 'Rem Cloud',
            body: values[2],
            proposed_status: values[3],
            runtime: 'rem_runtime',
            created_at: '2026-06-26T17:10:00.000Z',
          },
        ],
      }));

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    const terminalValues = poolMock.query.mock.calls[3][1] as any[];
    expect(terminalValues[0]).toBe('done');
    // The task's own status column is APPLIED, not merely proposed (bound as $2).
    expect(terminalValues[1]).toBe('completed');
    expect(response.body.task_run.run_status).toBe('done');
    // The verdict propagates to the comment's proposed_status…
    expect(response.body.proposed_status).toBe('completed');
    // …and the machine line never reaches the body the user reads.
    expect(response.body.body).toBe('Wrapped it up.');
    // …and `previous_status` is stamped so the client can offer Undo.
    const insertValues = poolMock.query.mock.calls[4][1] as any[];
    expect(insertValues[4]).toBe('pending');
  });

  it('executes a Rem tool-call status proposal through the audited tasks.update lifecycle', async () => {
    runtimeReplies('', [{
      name: TASK_VERDICT_TOOL_NAME,
      toolCallId: 'report-call-1',
      args: {
        status: 'completed',
        comment: 'Wrapped it up.',
        task_context: 'Permit renewed; receipt saved.',
      },
    }]);
    executeTaskStatusProposalMock.mockResolvedValueOnce({
      kind: 'succeeded',
      task: {
        ...taskRow,
        status: 'completed',
        run_status: 'done',
        run_id: 'run-1',
        description: 'Permit renewed; receipt saved.',
      },
      comment: {
        id: 'c-agent', task_id: TASK_ID, author_kind: 'cloud_agent',
        author_label: 'Rem Cloud', body: 'Wrapped it up.', proposed_status: 'completed',
        previous_status: 'pending', runtime: 'rem_runtime', session_id: 'run-product-1',
        run_block_code: null, run_block_mode: null,
        created_at: '2026-06-26T17:10:00.000Z',
      },
      effectId: 'effect-1',
      replayed: false,
    });
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(executeTaskStatusProposalMock).toHaveBeenCalledWith({
      userId: USER_ID,
      taskId: TASK_ID,
      status: 'completed',
      sessionKey: `rem-task-${TASK_ID}`,
      proposalRunId: 'rem-run-1',
      toolCallId: 'report-call-1',
      externalContentInfluenced: false,
      productCompletion: {
        expectedStatus: 'pending',
        runStatus: 'done',
        runBlockCode: null,
        runBlockMode: null,
        commentBody: 'Wrapped it up.',
        proposedStatus: 'completed',
        previousStatus: 'pending',
        runtime: 'rem_runtime',
        sessionId: expect.any(String),
        taskContext: 'Permit renewed; receipt saved.',
      },
    });
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('SET run_status = $1')))
      .toBe(false);
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('INSERT INTO task_comments')))
      .toBe(false);
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('SET description')))
      .toBe(false);
    expect(response.body).toMatchObject({
      body: 'Wrapped it up.', proposed_status: 'completed', previous_status: 'pending',
      task_run: { status: 'completed', run_status: 'done' },
    });
  });

  it('replays an ambiguous audited commit before writing any fallback state', async () => {
    runtimeReplies('', [{
      name: TASK_VERDICT_TOOL_NAME,
      toolCallId: 'report-call-1',
      args: { status: 'completed', comment: 'Wrapped it up.' },
    }]);
    const committedTask = {
      ...taskRow, status: 'completed', run_status: 'done', run_id: 'run-1',
    };
    const committedComment = {
      id: 'c-agent', task_id: TASK_ID, author_kind: 'cloud_agent',
      author_label: 'Rem Cloud', body: 'Wrapped it up.', proposed_status: 'completed',
      previous_status: 'pending', runtime: 'rem_runtime', session_id: 'run-product-1',
      run_block_code: null, run_block_mode: null,
      created_at: '2026-06-26T17:10:00.000Z',
    };
    executeTaskStatusProposalMock
      .mockRejectedValueOnce(new Error('response lost after COMMIT'))
      .mockResolvedValueOnce({
        kind: 'succeeded',
        task: committedTask,
        comment: committedComment,
        effectId: 'effect-1',
        replayed: true,
      });
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.status).toBe(201);
    expect(executeTaskStatusProposalMock).toHaveBeenCalledTimes(2);
    expect(executeTaskStatusProposalMock.mock.calls[1][0]).toEqual(
      executeTaskStatusProposalMock.mock.calls[0][0],
    );
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('SET run_status = $1')))
      .toBe(false);
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('INSERT INTO task_comments')))
      .toBe(false);
    expect(response.body).toMatchObject({
      body: 'Wrapped it up.', previous_status: 'pending',
      task_run: { status: 'completed', run_status: 'done' },
    });
  });

  it('does not write fallback state while an audited effect remains pending', async () => {
    runtimeReplies('', [{
      name: TASK_VERDICT_TOOL_NAME,
      toolCallId: 'report-call-1',
      args: { status: 'completed', comment: 'Wrapped it up.' },
    }]);
    executeTaskStatusProposalMock.mockResolvedValueOnce({
      kind: 'not_applied', reason: 'effect_pending',
    });
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.status).toBe(503);
    expect(response.body).toEqual({
      error: 'Task update outcome is still being verified', retryable: true,
    });
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('SET run_status = $1')))
      .toBe(false);
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('INSERT INTO task_comments')))
      .toBe(false);
  });

  it('does not write fallback state when ambiguous outcome reconciliation is unavailable', async () => {
    runtimeReplies('', [{
      name: TASK_VERDICT_TOOL_NAME,
      toolCallId: 'report-call-1',
      args: { status: 'completed', comment: 'Wrapped it up.' },
    }]);
    executeTaskStatusProposalMock
      .mockRejectedValueOnce(new Error('response lost after COMMIT'))
      .mockRejectedValueOnce(new Error('database unavailable during replay'));
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.status).toBe(503);
    expect(executeTaskStatusProposalMock).toHaveBeenCalledTimes(2);
    expect(response.body).toEqual({
      error: 'Task update outcome is still being verified', retryable: true,
    });
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('SET run_status = $1')))
      .toBe(false);
    expect(poolMock.query.mock.calls.some(([sql]) => String(sql).includes('INSERT INTO task_comments')))
      .toBe(false);
  });

  it('leaves a failed audited proposal unapplied and visible for review', async () => {
    runtimeReplies('', [{
      name: TASK_VERDICT_TOOL_NAME,
      toolCallId: 'report-call-1',
      args: { status: 'completed', comment: 'I recommend marking this complete.' },
    }]);
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [] })
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        rows: [{ ...taskRow, run_status: values[0], run_id: 'run-1' }],
      }))
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        rows: [{
          id: 'c-agent', task_id: TASK_ID, author_kind: 'cloud_agent',
          author_label: 'Rem Cloud', body: values[2], proposed_status: values[3],
          previous_status: values[4], runtime: 'rem_runtime',
          created_at: '2026-06-26T17:10:00.000Z',
        }],
      }));

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.body).toMatchObject({
      proposed_status: 'completed', previous_status: null,
      task_run: { status: 'pending', run_status: 'review' },
    });
  });

  it('agent-run maps a blocked verdict to run_status=blocked (needs-info)', async () => {
    // Agent ran fine but is blocked on missing info — reports `blocked`, which
    // terminalRunStatus maps to run_status='blocked' (feeds the daily-brief sweep).
    runtimeReplies(
      'I need the filing reference before I can proceed.\nrem.task_verdict.v1 {"status":"blocked"}',
    );
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] }) // loadOwnedTask
      .mockResolvedValueOnce({ rows: [] }) // load comments
      .mockResolvedValueOnce({ rows: [] }) // UPDATE running
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        rows: [{ ...taskRow, run_status: values[0], run_id: 'run-1' }],
      }))
      .mockImplementationOnce(async (_sql: string, values: any[]) => ({
        rows: [
          {
            id: 'c-agent',
            task_id: TASK_ID,
            author_kind: 'cloud_agent',
            author_label: 'Rem Cloud',
            body: values[2],
            proposed_status: values[3],
            runtime: 'rem_runtime',
            created_at: '2026-06-26T17:10:00.000Z',
          },
        ],
      }));

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    const terminalValues = poolMock.query.mock.calls[3][1] as any[];
    expect(terminalValues[0]).toBe('blocked');
    expect(response.body.task_run.run_status).toBe('blocked');
    expect(response.body.proposed_status).toBe('blocked');
    expect(response.body.body).toBe('I need the filing reference before I can proceed.');
  });

  it('accepts blocked as a valid human proposed_status (not rejected as bogus)', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [taskRow] }) // loadOwnedTask
      .mockResolvedValueOnce({
        rows: [
          {
            id: 'c-1',
            task_id: TASK_ID,
            author_kind: 'user',
            author_label: 'You',
            body: 'waiting on legal',
            proposed_status: 'blocked',
            runtime: null,
            created_at: '2026-06-26T17:00:00.000Z',
          },
        ],
      })
      // resetTaskStaleness — commenting is a user action (migration 116).
      .mockResolvedValueOnce({ rowCount: 1, rows: [] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/comments`)
      .send({ body: 'waiting on legal', proposed_status: 'blocked' });

    expect(response.status).toBe(201);
    expect(response.body.proposed_status).toBe('blocked');
  });

  // --- Event backing (migration 024): make a calendar event "workable" -------------

  it('event-backing find-or-create returns the backing task (calendar_event_id set)', async () => {
    const CAL_EVENT_ID = 'EKEvent-ABC-123';
    poolMock.query.mockResolvedValueOnce({
      rows: [
        {
          ...taskRow,
          id: '22222222-2222-4222-8222-222222222222',
          title: 'Standup',
          type: 'calendar_event',
          calendar_event_id: CAL_EVENT_ID,
        },
      ],
    });

    const response = await request(testApp())
      .post('/api/v1/tasks/event-backing')
      .send({ calendar_event_id: CAL_EVENT_ID, title: 'Standup', duration_minutes: 30 });

    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({
      id: '22222222-2222-4222-8222-222222222222',
      type: 'calendar_event',
      calendar_event_id: CAL_EVENT_ID,
    });
    // Single idempotent upsert (INSERT ... ON CONFLICT), keyed by calendar_event_id.
    const upsertValues = poolMock.query.mock.calls[0][1] as any[];
    expect(upsertValues).toContain(CAL_EVENT_ID);
  });

  it('event-backing rejects a missing calendar_event_id with 400', async () => {
    const response = await request(testApp())
      .post('/api/v1/tasks/event-backing')
      .send({ title: 'No event id' });

    expect(response.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });
});
