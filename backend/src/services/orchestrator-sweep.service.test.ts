import { beforeEach, describe, expect, it, vi } from 'vitest';

// A single Postgres client the transaction helper (pool.connect) hands out. Its query
// mock returns a comment-id row by default so BEGIN/UPDATE/INSERT/COMMIT all resolve; the
// INSERT reads rows[0].id, the rest ignore the value. Loosely typed (bare vi.fn()) so
// .mock.calls stays any[] for positional assertions.
const clientMock = vi.hoisted(() => ({
  query: vi.fn(),
  release: vi.fn(),
}));
const poolMock = vi.hoisted(() => ({
  query: vi.fn(),
  connect: vi.fn(),
}));
const conversationClientMock = vi.hoisted(() => ({
  query: vi.fn(),
  release: vi.fn(),
}));
const taskConversationPoolMock = vi.hoisted(() => ({ connect: vi.fn() }));
vi.mock('../db/pool.js', () => ({
  pool: poolMock,
  taskConversationPool: taskConversationPoolMock,
}));

const executeStatusMock = vi.hoisted(() => vi.fn());
vi.mock('../runtime/rem-task-tool-execution.js', () => ({
  executeTrustedAutomationTaskStatusProposal: executeStatusMock,
}));

const runAgentOnTaskMock = vi.hoisted(() => vi.fn());
vi.mock('./task-agent.service.js', () => ({ runAgentOnTask: runAgentOnTaskMock }));

const resolveModeMock = vi.hoisted(() => vi.fn());
vi.mock('./run-block.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./run-block.js')>()),
  resolveModelRuntimeMode: resolveModeMock,
}));

import {
  runReadyTask,
  defaultReadyTaskAgentRunner,
  sweepReadyTasks,
  applyPerUserCap,
  findReadyTasks,
  reapStaleRunningClaims,
  isSweepEnabled,
  taskSessionKey,
  MAX_TASKS_PER_USER,
  STALE_CLAIM_MINUTES,
  type ReadyTask,
  type ReadyTaskAgentRunner,
} from './orchestrator-sweep.service.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const TASK_ID = 'b2222222-0000-4000-8000-000000000003';
const COMMENT_ID = 'c3333333-0000-4000-8000-000000000004';
const NOW = new Date('2026-06-30T15:00:00.000Z');

function task(overrides: Partial<ReadyTask> = {}): ReadyTask {
  return {
    id: TASK_ID,
    userId: USER_ID,
    title: 'Draft the Q3 planning outline',
    description: null,
    status: 'pending',
    priority: 'high',
    ...overrides,
  };
}

/** A stub observe runner that records its calls and returns a durable proposal. */
function stubAgent(
  result:
    | {
        ok: true;
        reply: string;
        proposedStatus: 'pending' | 'completed' | 'in_progress' | 'blocked';
        taskContext?: string | null;
        externalContentInfluenced?: boolean;
      }
    | { ok: false; reason: string } = { ok: true, reply: 'Did it.', proposedStatus: 'completed' },
) {
  const run = vi.fn(async () => result.ok
    ? {
        externalContentInfluenced: false,
        ...result,
        proposalRunId: 'proposal-run-1',
        toolCallId: 'report-call-1',
      }
    : result);
  return { agent: { run } as ReadyTaskAgentRunner, run };
}

/** The last INSERT INTO task_comments call made on the transaction client. */
function lastCommentInsert() {
  return [...clientMock.query.mock.calls]
    .reverse()
    .find((c) => typeof c[0] === 'string' && c[0].includes('INSERT INTO task_comments'));
}

/** The last tasks UPDATE call made on the transaction client (the status apply).
 *  Matched on `SET run_status` specifically: the same transaction also issues the
 *  description write (migration 120), and a bare 'UPDATE tasks' would now find that. */
function lastTasksUpdateOnClient() {
  return [...clientMock.query.mock.calls]
    .reverse()
    .find((c) => typeof c[0] === 'string' && c[0].includes('UPDATE tasks') && c[0].includes('SET run_status'));
}

/** Never-deny screen so the deny-list branch doesn't interfere with happy-path tests. */
const allowScreen = () => ({ denied: false as const, categories: [] });

beforeEach(() => {
  vi.clearAllMocks();
  resolveModeMock.mockResolvedValue('rem_managed');
  // Reset the default client query behaviour after clearAllMocks wiped the implementation.
  clientMock.query.mockImplementation(async () => ({ rows: [{ id: COMMENT_ID }], rowCount: 1 }));
  poolMock.connect.mockImplementation(async () => clientMock);
  executeStatusMock.mockResolvedValue({
    kind: 'succeeded',
    task: { id: TASK_ID },
    comment: { id: COMMENT_ID },
    effectId: 'effect-1',
    replayed: false,
  });
  runAgentOnTaskMock.mockReset();
  conversationClientMock.query.mockResolvedValue({ rows: [{ acquired: true }] });
  taskConversationPoolMock.connect.mockResolvedValue(conversationClientMock);
});

describe('defaultReadyTaskAgentRunner', () => {
  it('uses the canonical Rem observe turn with trusted-automation authority', async () => {
    runAgentOnTaskMock.mockResolvedValue({
      reply: 'Prepared the outline.',
      proposedStatus: 'completed',
      taskContext: 'Outline is ready.',
      verdictSource: 'tool_call',
      runtime: { persistenceKind: 'rem_runtime' },
      taskUpdateProposal: { runtimeRunId: 'proposal-run-1', toolCallId: 'report-call-1' },
    });

    const result = await defaultReadyTaskAgentRunner.run({
      task: task({
        description: 'User notes\n\n<!-- rem:agent-context -->\nUnproven prior context\n<!-- /rem:agent-context -->',
      }),
      comments: [
        { author_kind: 'user', author_label: null, body: 'Please keep it short.' },
        { author_kind: 'cloud_agent', author_label: 'Rem', body: 'Unproven prior output.' },
      ],
      sessionKey: taskSessionKey(TASK_ID),
      idempotencyKey: 'sweep-run-1',
    });

    expect(result).toMatchObject({
      ok: true,
      proposedStatus: 'completed',
      proposalRunId: 'proposal-run-1',
      toolCallId: 'report-call-1',
      externalContentInfluenced: false,
    });
    expect(runAgentOnTaskMock).toHaveBeenCalledWith(
      expect.objectContaining({
        id: TASK_ID,
        description_user: 'User notes',
        description_agent: null,
      }),
      [{ author_kind: 'user', body: 'Please keep it short.' }],
      expect.stringContaining('UNATTENDED'),
      expect.objectContaining({
        userId: USER_ID,
        authority: 'trusted_automation',
        sessionKey: taskSessionKey(TASK_ID),
        idempotencyKey: 'sweep-run-1',
      }),
    );
  });
});

describe('taskSessionKey', () => {
  it('normalizes device-style uppercase UUIDs to the backend canonical key', () => {
    expect(taskSessionKey(`  ${TASK_ID.toUpperCase()}  `)).toBe(`rem-task-${TASK_ID}`);
  });

  it('uses the same canonical session for unattended and interactive task turns', () => {
    expect(taskSessionKey(TASK_ID)).toBe(`rem-task-${TASK_ID}`);
  });
});

describe('runReadyTask — the run records what it learned (migration 120)', () => {
  it('includes the bounded canonical task-chat history and fences its observed tail', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 })
      .mockResolvedValueOnce({
        rows: [{
          comments: [
            { author_kind: 'user', author_label: 'You', body: 'Activity first.', created_at: '2026-06-30T14:00:00Z' },
            { author_kind: 'user', author_label: 'You', body: 'Activity last.', created_at: '2026-06-30T17:00:00Z' },
          ],
          comment_count: 2,
          chat_messages: [
            { role: 'user', content: 'Use option B.', seq: 1, created_at: '2026-06-30T15:00:00Z' },
            { role: 'assistant', content: 'I can do that.', seq: 2, created_at: '2026-06-30T16:00:00Z' },
          ],
          chat_message_count: 2,
        }],
      });
    const { agent, run } = stubAgent();

    await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    const firstRunCall = run.mock.calls.at(0) as unknown as [any];
    expect(firstRunCall[0].comments).toEqual([
      { author_kind: 'user', author_label: 'You', body: 'Activity first.' },
      { author_kind: 'user', author_label: 'You (task chat)', body: 'Use option B.' },
      { author_kind: 'cloud_agent', author_label: 'Rem (task chat)', body: 'I can do that.' },
      { author_kind: 'user', author_label: 'You', body: 'Activity last.' },
    ]);
    expect(executeStatusMock.mock.calls[0][0].productCompletion.expectedChatMessageCount).toBe(2);
  });

  it('hands task context to the audited product transaction', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    const { agent } = stubAgent({
      ok: true,
      reply: 'Drafted the letter.',
      proposedStatus: 'in_progress',
      taskContext: 'Cover letter drafted; need the receipt number.',
    });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });
    expect(result.status).toBe('executed');
    expect(executeStatusMock.mock.calls[0][0].productCompletion.taskContext).toBe(
      'Cover letter drafted; need the receipt number.',
    );
  });

  it('preserves the no-new-context signal for the adapter no-op', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    const { agent } = stubAgent({ ok: true, reply: 'Nothing to add.', proposedStatus: 'pending', taskContext: null });

    await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(executeStatusMock.mock.calls[0][0].productCompletion.taskContext).toBeNull();
  });
});

describe('runReadyTask — executed path (apply-with-Undo, atomic)', () => {
  it('claims, runs the Rem observe turn, and executes its durable proposal through the audited adapter', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }); // gatherComments
    const { agent, run } = stubAgent({ ok: true, reply: 'Drafted the outline.', proposedStatus: 'completed' });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('executed');
    expect(result.appliedStatus).toBe('completed');
    expect(result.commentId).toBe(COMMENT_ID);
    expect(run).toHaveBeenCalledOnce();

    expect(executeStatusMock).toHaveBeenCalledWith(expect.objectContaining({
      userId: USER_ID,
      taskId: TASK_ID,
      status: 'completed',
      sessionKey: taskSessionKey(TASK_ID),
      proposalRunId: 'proposal-run-1',
      toolCallId: 'report-call-1',
      externalContentInfluenced: false,
      productCompletion: expect.objectContaining({
        runStatus: 'done',
        expectedCommentCount: 0,
        proposedStatus: 'completed',
        previousStatus: 'pending',
        runtime: 'rem_runtime',
        sessionId: taskSessionKey(TASK_ID),
        transcript: expect.objectContaining({
          ask: 'Work on "Draft the Q3 planning outline" now.',
          reply: 'Drafted the outline.',
        }),
      }),
    }));
  });

  it('does not start while the canonical task conversation is already running', async () => {
    conversationClientMock.query
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rows: [{ acquired: false }] })
      .mockResolvedValue({ rows: [] });
    const { agent, run } = stubAgent();

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('skipped_claim');
    expect(run).not.toHaveBeenCalled();
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('does NOT stamp previous_status when the agent re-affirms the current status (no-op)', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }); // comments
    // Re-affirming pending → no status change, no Undo affordance.
    const { agent } = stubAgent({ ok: true, reply: 'Working on it.', proposedStatus: 'pending' });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('executed');
    expect(result.appliedStatus).toBeNull();

    expect(executeStatusMock.mock.calls[0][0].productCompletion).toMatchObject({
      runStatus: 'review', proposedStatus: 'pending', previousStatus: null,
    });
  });

  it('propagates external-content provenance so automation policy can fail closed', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 })
      .mockResolvedValueOnce({ rows: [] });
    const { agent } = stubAgent({
      ok: true,
      reply: 'Prepared a draft from imported material.',
      proposedStatus: 'completed',
      externalContentInfluenced: true,
    });
    executeStatusMock.mockResolvedValueOnce({
      kind: 'blocked',
      reason: 'external_content_requires_user',
      effectId: 'effect-external',
      replayed: false,
    });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(executeStatusMock.mock.calls[0][0].externalContentInfluenced).toBe(true);
    expect(result).toMatchObject({
      status: 'skipped_runtime',
      reason: 'external_content_requires_user',
    });
  });

  it('does not mint a second identity when effect execution throws ambiguously', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }); // comments
    executeStatusMock.mockRejectedValueOnce(new Error('commit acknowledgement lost'));
    const { agent } = stubAgent({ ok: true, reply: 'Did it.', proposedStatus: 'completed' });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('skipped_runtime');
    expect(result.reason).toContain('commit acknowledgement lost');
    expect(poolMock.query).toHaveBeenCalledTimes(2); // claim + comments; no immediate release
  });

  it('holds the task claim while an admitted effect is still pending', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    executeStatusMock.mockResolvedValueOnce({ kind: 'not_applied', reason: 'effect_pending' });
    const { agent } = stubAgent();

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result).toMatchObject({ status: 'skipped_runtime', reason: 'effect_pending' });
    expect(poolMock.query).toHaveBeenCalledTimes(2); // no immediate release / redispatch window
  });

  it('releases the task when policy rejection proves no mutation committed', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 })
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce({ rowCount: 1 });
    executeStatusMock.mockResolvedValueOnce({ kind: 'not_applied', reason: 'effect_blocked' });
    const { agent } = stubAgent();

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result).toMatchObject({ status: 'skipped_runtime', reason: 'effect_blocked' });
    expect(poolMock.query.mock.calls[2][0]).toContain('SET run_status = NULL');
  });
});

describe('runReadyTask — deny-list safety (never auto-runs a dangerous task)', () => {
  it('records blocked-for-review in one transaction and never dispatches the model turn', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }); // comments
    const { agent, run } = stubAgent();

    const result = await runReadyTask(
      task({ title: 'Send an email to my landlord about the lease' }),
      NOW,
      { agent }, // real deny screen
    );

    expect(result.status).toBe('denied');
    expect(result.reason).toContain('send_communications');
    expect(run).not.toHaveBeenCalled(); // runtime never touched

    // Blocked flip + comment share a transaction.
    expect(clientMock.query.mock.calls[0][0]).toBe('BEGIN');
    const updateCall = lastTasksUpdateOnClient()!;
    expect(updateCall[0]).toContain("run_status = 'blocked'");
    const insertCall = lastCommentInsert()!;
    expect(insertCall[1][2]).toBe('Rem Orchestrator (blocked)');
    expect(insertCall[1][5]).toBeNull(); // nothing applied → no Undo

    // A deny IS a blocked run — the sweep's most common one — so it must carry a machine
    // reason and not only the 🚫 prose. `policy_blocked` is what tells run history apart from
    // a failed runtime; without it, both surface as "blocked" with no code. Task row and comment
    // row both, because the task holds only its last run's state.
    expect(updateCall[0]).toContain('run_block_code = $3');
    expect(updateCall[1][2]).toBe('policy_blocked');
    expect(insertCall[1][7]).toBe('policy_blocked');
  });

  it('releases instead of recording a denial when the observed task revision changed', async () => {
    poolMock.query
      .mockResolvedValueOnce({
        rowCount: 1,
        rows: [{
          title: 'Send an email to my landlord',
          status: 'pending',
          priority: 'high',
          description: null,
          updated_at: '2026-06-30T15:00:00.000Z',
        }],
      })
      .mockResolvedValueOnce({
        rows: [{ comments: [], comment_count: 0, chat_messages: [], chat_message_count: 0 }],
      })
      .mockResolvedValueOnce({ rowCount: 1 });
    clientMock.query.mockImplementation(async (sql: string) => {
      if (String(sql).includes('SELECT updated_at')) {
        return {
          rows: [{
            updated_at: '2026-06-30T15:01:00.000Z',
            comment_count: 0,
            chat_message_count: 0,
          }],
        };
      }
      return { rows: [] };
    });
    const { agent, run } = stubAgent();

    const result = await runReadyTask(task({ title: 'Send an email to my landlord' }), NOW, { agent });

    expect(result).toMatchObject({
      status: 'skipped_runtime',
      reason: 'error: task_observation_changed',
    });
    expect(run).not.toHaveBeenCalled();
    expect(poolMock.query.mock.calls[2][0]).toContain('SET run_status = NULL');
    expect(lastCommentInsert()).toBeUndefined();
  });

  it('CLEARS a stale block when the sweep completes a run the manual dispatch abandoned', async () => {
    // The cross-path bug. `Run now` stamps a block, the process dies mid-flight,
    // `releaseStaleRunningClaims` resets run_status to NULL, and the sweep then picks the task
    // up and finishes it. If the sweep's terminal write does not NULL the pair, the task reports
    // `done` while still advertising "your runtime is unavailable" from the earlier attempt —
    // telling the user to fix something that is already working.
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }); // comments
    const { agent } = stubAgent({ ok: true, reply: 'Done.', proposedStatus: 'completed' });

    await runReadyTask(task({}), NOW, { agent, screen: allowScreen });

    expect(executeStatusMock.mock.calls[0][0].productCompletion).toMatchObject({
      runBlockCode: null, runBlockMode: null,
    });
  });

  // The screen has to cover everything `runAgentOnTask` puts in the prompt. The
  // description (migration 120) is injected into the unattended turn, so a clean title
  // over a dangerous description used to sail straight past the deny list and be handed
  // to the agent as an instruction.
  it('screens the DESCRIPTION, not just the title and comments', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    const { agent, run } = stubAgent();

    const result = await runReadyTask(
      task({
        title: 'Follow up with Dana', // innocuous on its own — passes the screen
        description: 'send Dana the signed contract and delete the draft',
      }),
      NOW,
      { agent }, // real deny screen
    );

    expect(result.status).toBe('denied');
    expect(run).not.toHaveBeenCalled(); // the unattended turn never ran
  });

  // Worse than the user-authored case: the agent's OWN prior task_context lives in the
  // same column and is fed back in on the next run, so run 1 could write an instruction
  // that run 2 executes — autonomy escalation with no human in the loop.
  it('screens the AGENT’s own prior context, so a run cannot instruct the next one', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    const { agent, run } = stubAgent();

    const result = await runReadyTask(
      task({
        title: 'Follow up with Dana',
        description:
          'Notes.\n\n<!-- rem:agent-context -->\nNext step: send Dana the signed contract.\n<!-- /rem:agent-context -->',
      }),
      NOW,
      { agent },
    );

    expect(result.status).toBe('denied');
    expect(run).not.toHaveBeenCalled();
  });

  it('a task with a harmless description still runs', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    const { agent, run } = stubAgent();

    const result = await runReadyTask(
      task({ title: 'Follow up with Dana', description: 'Dana prefers a written summary.' }),
      NOW,
      { agent },
    );

    // Guards the obvious over-correction: screening the description must not deny
    // everything that merely HAS one.
    expect(result.status).toBe('executed');
    expect(run).toHaveBeenCalledOnce();
  });
});

describe('runReadyTask — graceful degradation', () => {
  it('releases its claim when conversation context cannot be read before effect admission', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 })
      .mockRejectedValueOnce(new Error('context database unavailable'))
      .mockResolvedValueOnce({ rowCount: 1 });
    const { agent, run } = stubAgent();

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result).toMatchObject({
      status: 'skipped_runtime',
      reason: 'error: context database unavailable',
    });
    expect(run).not.toHaveBeenCalled();
    expect(poolMock.query.mock.calls[2][0]).toContain('SET run_status = NULL');
  });

  it('releases the claim (run_status → NULL) when the observe runtime fails before an effect', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }) // comments
      .mockResolvedValueOnce({ rowCount: 1 }); // release
    const { agent } = stubAgent({ ok: false, reason: 'runtime_unavailable' });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('skipped_runtime');
    expect(result.reason).toBe('runtime_unavailable');
    expect(result.commentId).toBeNull();
    expect(poolMock.connect).not.toHaveBeenCalled(); // no transaction on the failure path

    const releaseCall = poolMock.query.mock.calls[2];
    expect(releaseCall[0]).toContain('SET run_status = NULL');
  });

  it('skips without side effects when another worker already claimed the task', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 0 }); // claim lost
    const { agent, run } = stubAgent();

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('skipped_claim');
    expect(run).not.toHaveBeenCalled();
    expect(poolMock.query).toHaveBeenCalledOnce(); // only the claim attempt
    expect(poolMock.connect).not.toHaveBeenCalled();
  });
});

describe('reapStaleRunningClaims', () => {
  it('releases only claims older than STALE_CLAIM_MINUTES back to NULL', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 2 });

    const reaped = await reapStaleRunningClaims(NOW);

    expect(reaped).toBe(2);
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain("run_status = 'running'");
    expect(sql).toContain('SET run_status = NULL');
    expect(sql).toContain("run_started_at < $1::timestamptz - ($2 || ' minutes')::interval");
    expect(poolMock.query.mock.calls[0][1]).toEqual([NOW.toISOString(), String(STALE_CLAIM_MINUTES)]);
  });
});

describe('isSweepEnabled (kill-switch, off by default)', () => {
  it('is false when the flag is unset or falsey', () => {
    expect(isSweepEnabled({} as NodeJS.ProcessEnv)).toBe(false);
    expect(isSweepEnabled({ ORCHESTRATOR_SWEEP_ENABLED: '' } as NodeJS.ProcessEnv)).toBe(false);
    expect(isSweepEnabled({ ORCHESTRATOR_SWEEP_ENABLED: '0' } as NodeJS.ProcessEnv)).toBe(false);
    expect(isSweepEnabled({ ORCHESTRATOR_SWEEP_ENABLED: 'false' } as NodeJS.ProcessEnv)).toBe(false);
  });

  it('is true only for explicit truthy opt-in values', () => {
    for (const v of ['1', 'true', 'TRUE', 'yes', 'on']) {
      expect(isSweepEnabled({ ORCHESTRATOR_SWEEP_ENABLED: v } as NodeJS.ProcessEnv)).toBe(true);
    }
  });
});

describe('applyPerUserCap', () => {
  it('caps the number of tasks per user while preserving order', () => {
    const many: ReadyTask[] = Array.from({ length: MAX_TASKS_PER_USER + 2 }, (_, i) =>
      task({ id: `t-${i}` }),
    );
    const other = task({ id: 'other', userId: 'u2' });

    const kept = applyPerUserCap([...many, other]);

    expect(kept.filter((t) => t.userId === USER_ID)).toHaveLength(MAX_TASKS_PER_USER);
    expect(kept.filter((t) => t.userId === 'u2')).toHaveLength(1);
  });
});

describe('findReadyTasks', () => {
  it('queries pending, never-run, due tasks and caps per-user IN SQL before the global LIMIT', async () => {
    poolMock.query.mockResolvedValueOnce({
      rows: [{ id: TASK_ID, user_id: USER_ID, title: 'X', description: 'ctx', status: 'pending', priority: 'high' }],
    });

    const tasks = await findReadyTasks(NOW);

    expect(tasks).toEqual([{ id: TASK_ID, userId: USER_ID, title: 'X', description: 'ctx', status: 'pending', priority: 'high' }]);
    // The description must be SELECTed, or an autonomous run gets no prior context and
    // the "every run starts from zero" bug survives the column existing (migration 120).
    expect(poolMock.query.mock.calls[0][0] as string).toContain('description');
    const sql = poolMock.query.mock.calls[0][0] as string;
    expect(sql).toContain("status = 'pending'");
    expect(sql).toContain('run_status IS NULL');
    expect(sql).toContain('start_date <= $1::timestamptz');
    // M4: the per-user cap is a windowed rank applied BEFORE the global LIMIT, so one
    // user's backlog can't consume every global slot.
    expect(sql).toContain('ROW_NUMBER() OVER');
    expect(sql).toContain('PARTITION BY user_id');
    expect(sql).toContain('user_rank <= $3');
    expect(sql).toContain('LIMIT $4');
  });
});

describe('sweepReadyTasks — batch isolation', () => {
  it('reaps stale claims, isolates a per-task failure, and reports runtime/claim skips separately', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // reapStaleRunningClaims
      .mockResolvedValueOnce({
        rows: [
          { id: 't-1', user_id: USER_ID, title: 'A', status: 'pending', priority: 'low' },
          { id: 't-2', user_id: USER_ID, title: 'B', status: 'pending', priority: 'low' },
        ],
      }) // findReadyTasks
      // t-1: claim, comments (then apply+insert on the client). t-2: claim, comments, release.
      .mockResolvedValueOnce({ rowCount: 1 }) // t-1 claim
      .mockResolvedValueOnce({ rows: [] }) // t-1 comments
      .mockResolvedValueOnce({ rowCount: 1 }) // t-2 claim
      .mockResolvedValueOnce({ rows: [] }) // t-2 comments
      .mockResolvedValueOnce({ rowCount: 1 }); // t-2 release

    const run = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        reply: 'done',
        proposedStatus: 'completed',
        proposalRunId: 'proposal-run-1',
        toolCallId: 'report-call-1',
      })
      .mockResolvedValueOnce({ ok: false, reason: 'timeout' });

    const report = await sweepReadyTasks(NOW, {
      agent: { run } as ReadyTaskAgentRunner,
      screen: allowScreen,
    });

    expect(report.reaped).toBe(1);
    expect(report.scanned).toBe(2);
    expect(report.executed).toBe(1);
    expect(report.skipped).toBe(1);
    expect(report.skippedRuntime).toBe(1);
    expect(report.skippedClaim).toBe(0);
  });
});
