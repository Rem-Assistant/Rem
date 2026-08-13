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
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

import {
  runReadyTask,
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

/** A stub gateway runner that records its calls and returns a fixed result. */
function stubAgent(
  result:
    | {
        ok: true;
        reply: string;
        proposedStatus: 'completed' | 'in_progress' | 'blocked' | null;
        taskContext?: string | null;
      }
    | { ok: false; reason: string } = { ok: true, reply: 'Did it.', proposedStatus: 'completed' },
) {
  const run = vi.fn(async () => result);
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

/** The description write (migration 120) issued inside the run's transaction, if any. */
function descriptionWriteOnClient() {
  return clientMock.query.mock.calls.find(
    (c) => typeof c[0] === 'string' && c[0].includes('UPDATE tasks') && c[0].includes('SET description'),
  );
}

/** Never-deny screen so the deny-list branch doesn't interfere with happy-path tests. */
const allowScreen = () => ({ denied: false as const, categories: [] });

beforeEach(() => {
  vi.clearAllMocks();
  // Reset the default client query behaviour after clearAllMocks wiped the implementation.
  clientMock.query.mockImplementation(async () => ({ rows: [{ id: COMMENT_ID }], rowCount: 1 }));
  poolMock.connect.mockImplementation(async () => clientMock);
});

describe('taskSessionKey', () => {
  it('normalizes device-style uppercase UUIDs to the backend canonical key', () => {
    expect(taskSessionKey(`  ${TASK_ID.toUpperCase()}  `)).toBe(`rem-task-${TASK_ID}`);
  });
});

describe('runReadyTask — the run records what it learned (migration 120)', () => {
  /** Make the FOR UPDATE read return a real stored description; everything else keeps
   *  the default comment-id row so BEGIN/UPDATE/INSERT/COMMIT resolve. */
  function clientReturningDescription(stored: string | null) {
    clientMock.query.mockImplementation(async (sql: string) => {
      if (typeof sql === 'string' && sql.includes('SELECT description')) {
        return { rows: [{ description: stored }], rowCount: 1 };
      }
      return { rows: [{ id: COMMENT_ID, description: stored }], rowCount: 1 };
    });
  }

  it('writes the agent block IN THE RUN TRANSACTION and leaves the user text intact', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    clientReturningDescription('Attorney is Ada. Deadline is the 30th.');
    const { agent } = stubAgent({
      ok: true,
      reply: 'Drafted the letter.',
      proposedStatus: 'in_progress',
      taskContext: 'Cover letter drafted; need the receipt number.',
    });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });
    expect(result.status).toBe('executed');

    // The read takes the row lock, so a concurrent user PATCH cannot interleave.
    const lockingRead = clientMock.query.mock.calls.find(
      (c) => typeof c[0] === 'string' && c[0].includes('SELECT description') && c[0].includes('FOR UPDATE'),
    );
    expect(lockingRead).toBeDefined();

    const write = descriptionWriteOnClient();
    expect(write).toBeDefined();
    // The user's sentence survives, and the agent's state is inside its own block.
    expect(write![1][0]).toContain('Attorney is Ada. Deadline is the 30th.');
    expect(write![1][0]).toContain('<!-- rem:agent-context -->');
    expect(write![1][0]).toContain('Cover letter drafted; need the receipt number.');

    // Same transaction as the status apply and the comment — a description can never
    // claim state the comment and status don't back up.
    expect(clientMock.query.mock.calls[0][0]).toBe('BEGIN');
    expect(clientMock.query.mock.calls.at(-1)?.[0]).toBe('COMMIT');
  });

  it('a run with nothing new to say does not touch the description at all', async () => {
    poolMock.query.mockResolvedValueOnce({ rowCount: 1 }).mockResolvedValueOnce({ rows: [] });
    clientReturningDescription('Attorney is Ada.');
    const { agent } = stubAgent({ ok: true, reply: 'Nothing to add.', proposedStatus: null, taskContext: null });

    await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(descriptionWriteOnClient()).toBeUndefined();
  });
});

describe('runReadyTask — executed path (apply-with-Undo, atomic)', () => {
  it('claims, runs the gateway turn, applies status, and records previous_status for Undo', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }); // gatherComments
    const { agent, run } = stubAgent({ ok: true, reply: 'Drafted the outline.', proposedStatus: 'completed' });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('executed');
    expect(result.appliedStatus).toBe('completed');
    expect(result.commentId).toBe(COMMENT_ID);
    expect(run).toHaveBeenCalledOnce();

    // Apply + comment share ONE transaction (BEGIN/…/COMMIT on a pooled client).
    expect(poolMock.connect).toHaveBeenCalledOnce();
    expect(clientMock.query.mock.calls[0][0]).toBe('BEGIN');
    expect(clientMock.query.mock.calls.at(-1)?.[0]).toBe('COMMIT');

    // Applied UPDATE sets both run_status and status.
    const applyCall = lastTasksUpdateOnClient()!;
    expect(applyCall[0]).toContain('SET run_status = $1, status = $2');
    expect(applyCall[1][0]).toBe('done'); // completed → terminal run_status 'done'
    expect(applyCall[1][1]).toBe('completed');

    // Comment carries proposed_status + previous_status + the loadable gateway sessionKey.
    const insertCall = lastCommentInsert()!;
    expect(insertCall[0]).toContain("'cloud_agent'");
    expect(insertCall[0]).toContain("'gateway'"); // runtime = 'gateway' (migration 031)
    expect(insertCall[1][2]).toBe('Rem Orchestrator'); // author_label
    expect(insertCall[1][4]).toBe('completed'); // proposed_status
    expect(insertCall[1][5]).toBe('pending'); // previous_status (Undo target)
    // session_id is the gateway session key (rem-task-<id>), NOT a random runId (H2).
    expect(insertCall[1][6]).toBe(taskSessionKey(TASK_ID));
  });

  it('does NOT stamp previous_status when the agent re-affirms the current status (no-op)', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }); // comments
    // Agent proposes nothing (null) → no status change, no Undo affordance.
    const { agent } = stubAgent({ ok: true, reply: 'Working on it.', proposedStatus: null });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('executed');
    expect(result.appliedStatus).toBeNull();

    const applyCall = lastTasksUpdateOnClient()!;
    expect(applyCall[0]).not.toContain('status = $2'); // run_status only
    expect(applyCall[1][0]).toBe('review'); // null proposal → 'review'

    const insertCall = lastCommentInsert()!;
    expect(insertCall[1][4]).toBeNull(); // proposed_status
    expect(insertCall[1][5]).toBeNull(); // previous_status → no Undo
  });

  it('rolls back and releases the claim when the comment INSERT fails (C1 — no silent status mutation)', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }) // comments
      .mockResolvedValueOnce({ rowCount: 1 }); // releaseClaim after rollback
    // Client: BEGIN ok, UPDATE ok, INSERT throws (e.g. constraint), ROLLBACK ok.
    clientMock.query.mockImplementation(async (sql: string) => {
      if (typeof sql === 'string' && sql.includes('INSERT INTO task_comments')) {
        throw new Error('violates check constraint "task_comments_runtime_check"');
      }
      return { rows: [], rowCount: 1 };
    });
    const { agent } = stubAgent({ ok: true, reply: 'Did it.', proposedStatus: 'completed' });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    // The whole apply is atomic — nothing applied, task released for retry.
    expect(result.status).toBe('skipped_gateway');
    expect(result.reason).toContain('task_comments_runtime_check');
    expect(clientMock.query).toHaveBeenCalledWith('ROLLBACK');
    // Claim released back to NULL (last pool.query is the release).
    const releaseCall = poolMock.query.mock.calls.at(-1)!;
    expect(releaseCall[0]).toContain('SET run_status = NULL');
  });
});

describe('runReadyTask — deny-list safety (never auto-runs a dangerous task)', () => {
  it('records blocked-for-review in one transaction and never dispatches the gateway turn', async () => {
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
    expect(run).not.toHaveBeenCalled(); // gateway never touched

    // Blocked flip + comment share a transaction.
    expect(clientMock.query.mock.calls[0][0]).toBe('BEGIN');
    const updateCall = lastTasksUpdateOnClient()!;
    expect(updateCall[0]).toContain("run_status = 'blocked'");
    const insertCall = lastCommentInsert()!;
    expect(insertCall[1][2]).toBe('Rem Orchestrator (blocked)');
    expect(insertCall[1][5]).toBeNull(); // nothing applied → no Undo

    // A deny IS a blocked run — the sweep's most common one — so it must carry a machine
    // reason and not only the 🚫 prose. `policy_blocked` is what tells run history apart from
    // a dead gateway; without it, both surface as "blocked" with no code. Task row and comment
    // row both, because the task holds only its last run's state.
    expect(updateCall[0]).toContain('run_block_code = $3');
    expect(updateCall[1][2]).toBe('policy_blocked');
    expect(insertCall[1][7]).toBe('policy_blocked');
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

    const updateCall = lastTasksUpdateOnClient()!;
    expect(updateCall[0]).toContain('run_block_code = NULL');
    expect(updateCall[0]).toContain('run_block_mode = NULL');
  });

  // The screen has to cover everything `buildSweepMessage` puts in the prompt. The
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
  it('releases the claim (run_status → NULL) and skips when the gateway is unavailable', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rowCount: 1 }) // claim
      .mockResolvedValueOnce({ rows: [] }) // comments
      .mockResolvedValueOnce({ rowCount: 1 }); // release
    const { agent } = stubAgent({ ok: false, reason: 'no_gateway' });

    const result = await runReadyTask(task(), NOW, { agent, screen: allowScreen });

    expect(result.status).toBe('skipped_gateway');
    expect(result.reason).toBe('no_gateway');
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
  it('reaps stale claims, isolates a per-task failure, and reports gateway/claim skips separately', async () => {
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
      .mockResolvedValueOnce({ ok: true, reply: 'done', proposedStatus: 'completed' })
      .mockResolvedValueOnce({ ok: false, reason: 'timeout' });

    const report = await sweepReadyTasks(NOW, {
      agent: { run } as ReadyTaskAgentRunner,
      screen: allowScreen,
    });

    expect(report.reaped).toBe(1);
    expect(report.scanned).toBe(2);
    expect(report.executed).toBe(1);
    expect(report.skipped).toBe(1);
    expect(report.skippedGateway).toBe(1);
    expect(report.skippedClaim).toBe(0);
  });
});
