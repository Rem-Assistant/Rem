import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({
  query: vi.fn(),
}));

// The run's ONLY network boundary is now the user's gateway. Everything from the HTTP
// request down to the SQL — including the verdict read — is the real code.
const runAgentTurnOnGatewayMock = vi.hoisted(() => vi.fn());
vi.mock('../services/gateway-agent.service.js', () => ({
  runAgentTurnOnGateway: runAgentTurnOnGatewayMock,
  injectAssistantMessageOnGateway: vi.fn(),
}));

/** A successful gateway turn returning `text` verbatim. */
function gatewayReplies(text: string, toolCalls: unknown[] = []) {
  runAgentTurnOnGatewayMock.mockResolvedValueOnce({
    ok: true,
    text,
    runId: 'gw-run-1',
    sessionKey: 'rem-task-x',
    toolCalls,
  });
}

vi.mock('../db/pool.js', () => ({ pool: poolMock }));

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

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', tasksRoutes);
  return app;
}

describe('task comments + agent-run routes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Default: the user has no gateway, so the run cannot proceed and lands the errored
    // result. Tests that need a real turn call `gatewayReplies(...)` first.
    runAgentTurnOnGatewayMock.mockResolvedValue({ ok: false, reason: 'no_gateway' });
    resolveModeMock.mockResolvedValue('rem_managed');
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
  });

  it('rejects an empty comment body with 400', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [taskRow] });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/comments`)
      .send({ body: '   ' });

    expect(response.status).toBe(400);
  });

  it('rejects an invalid proposed_status with 400', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [taskRow] });

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
            runtime: 'gateway',
            created_at: '2026-06-26T17:10:00.000Z',
          },
        ],
      }))
      .mockResolvedValueOnce({ rows: [] }); // INSERT task_chat_messages transcript
  }

  it('agent-run lands an actionable comment — and no status change — with no gateway', async () => {
    // The old behaviour here was to fall back to the operator's shared GMI key. There is
    // no fallback now: the run reports honestly and touches nothing.
    mockAgentRun({ run_status: 'blocked', run_id: 'run-1' });

    const response = await request(testApp())
      .post(`/api/v1/tasks/${TASK_ID}/agent-run`)
      .send({});

    expect(response.status).toBe(201);
    expect(response.body).toMatchObject({
      author_kind: 'cloud_agent',
      author_label: 'Rem Cloud',
      runtime: 'gateway',
      proposed_status: null,
    });
    expect(response.body.body).toContain('needs your own Rem gateway');

    // Confirm the insert is attributed to the runtime that actually ran.
    const insertCall = poolMock.query.mock.calls[4][0] as string;
    expect(insertCall).toContain("'cloud_agent'");
    expect(insertCall).toContain("'Rem Cloud'");
    expect(insertCall).toContain("'gateway'");
    expect(insertCall).not.toContain("'agentbox'");
  });

  it('agent-run PERSISTS the structured block reason on the task and on the comment', async () => {
    // The founder's requirement, at the layer that can satisfy it: run history renders AFTER
    // the fact, so a reason that lives only in the HTTP response cannot be shown there. Both
    // rows carry `{ code, mode }` (migration 121) — the task for "how did the last run end",
    // the comment for "how did THAT run end" three runs later.
    resolveModeMock.mockResolvedValue('byok');
    mockAgentRun({ run_status: 'blocked', run_id: 'run-1' });

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    // Query #4 is the terminal task UPDATE. No status was applied, so the bound values are
    // [runStatus, blockCode, blockMode, taskId, userId].
    const terminal = poolMock.query.mock.calls[3];
    expect(String(terminal[0])).toContain('run_block_code = $2');
    expect(String(terminal[0])).toContain('run_block_mode = $3');
    expect((terminal[1] as any[])[1]).toBe('runtime_unavailable');
    expect((terminal[1] as any[])[2]).toBe('byok');

    // Query #5 is the comment INSERT: [taskId, userId, body, proposed, previous, runId, code, mode].
    const insert = poolMock.query.mock.calls[4];
    expect(String(insert[0])).toContain('run_block_code, run_block_mode');
    expect((insert[1] as any[])[6]).toBe('runtime_unavailable');
    expect((insert[1] as any[])[7]).toBe('byok');
  });

  it('agent-run CLEARS a previous block when the next run succeeds', async () => {
    // The reason the write is unconditional rather than bolted onto the error branch. A task
    // that failed yesterday and ran fine today must stop advertising "your runtime is
    // unavailable", or the user is told to fix something they already fixed.
    mockAgentRun({ run_status: 'review', run_id: 'run-2' });
    gatewayReplies('Looked into it.');

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    const terminal = poolMock.query.mock.calls[3];
    expect((terminal[1] as any[])[1]).toBeNull();
    expect((terminal[1] as any[])[2]).toBeNull();
    const insert = poolMock.query.mock.calls[4];
    expect((insert[1] as any[])[6]).toBeNull();
    expect((insert[1] as any[])[7]).toBeNull();
    // The mode is not even looked up on a successful run — it would tell the client nothing
    // actionable and would cost a query on the hot path.
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
    const insertedCode = (poolMock.query.mock.calls[4][1] as any[])[6];
    expect(insertedCode).toBe('runtime_unavailable');
  });

  it('agent-run dispatches the turn to the OWNER\'S gateway under the task session key', async () => {
    // The billing fix, asserted where it is decided: the run names this user, so the tokens
    // it spends meter to them and not to a shared org key.
    mockAgentRun({ run_status: 'review', run_id: 'run-1' });
    gatewayReplies('Looked into it.');

    await request(testApp()).post(`/api/v1/tasks/${TASK_ID}/agent-run`).send({});

    expect(runAgentTurnOnGatewayMock).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: USER_ID,
        sessionKey: `rem-task-${TASK_ID.toLowerCase()}`,
      }),
    );
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
    expect(transcriptValues[4]).toContain('needs your own Rem gateway'); // reply = errored body
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

  it('agent-run maps a completed verdict to run_status=done and applies the status', async () => {
    // Real service path: the gateway turn carries the verdict envelope, `task-verdict`
    // reads it, and terminalRunStatus maps it to 'done'.
    gatewayReplies('Wrapped it up.\nrem.task_verdict.v1 {"status":"completed"}');
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
            runtime: 'gateway',
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

  it('agent-run maps a blocked verdict to run_status=blocked (needs-info)', async () => {
    // Agent ran fine but is blocked on missing info — reports `blocked`, which
    // terminalRunStatus maps to run_status='blocked' (feeds the daily-brief sweep).
    gatewayReplies(
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
            runtime: 'gateway',
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
