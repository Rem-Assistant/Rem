import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
const runAgentOnTaskMock = vi.hoisted(() => vi.fn());
vi.mock('../db/pool.js', () => ({ pool: poolMock }));
vi.mock('./task-agent.service.js', () => ({ runAgentOnTask: runAgentOnTaskMock }));
vi.mock('./routine-policy-lock.service.js', () => ({
  withRoutinePolicyLock: async (_routineId: string, work: () => Promise<unknown>) => work(),
}));

import {
  defaultAgentRunner,
  runDueRoutines,
  runRoutine,
  routineOccurrenceId,
  type AgentRunner,
} from './routine-runner.service.js';
import type {
  RoutineRunOccurrenceStore,
  StoredRoutineOccurrence,
} from './routine-run-occurrence.store.js';
import type { RoutineSchedule } from './routine.types.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const ROUTINE_ID = 'a1111111-0000-4000-8000-000000000002';
const TASK_ID = 'b2222222-0000-4000-8000-000000000003';
const COMMENT_ID = 'c3333333-0000-4000-8000-000000000004';
const OCCURRENCE_ID = 'e5555555-0000-4000-8000-000000000006';
const NOW = new Date('2026-06-26T15:00:00.000Z');

function routine(overrides: Partial<RoutineSchedule> = {}): RoutineSchedule {
  return {
    id: ROUTINE_ID,
    userId: USER_ID,
    taskId: TASK_ID,
    cadence: 'daily',
    deliveryHour: 0,
    timezone: 'UTC',
    prompt: 'Summarize my open tasks for the day.',
    autonomy: 3,
    model: 'claude-sonnet',
    enabled: true,
    lastRunAt: null,
    createdAt: '2026-06-26T00:00:00.000Z',
    ...overrides,
  };
}

/** A stub agent that records its calls and returns a fixed reply. */
function stubAgent(body = 'Here is your brief.', confidence: 'high' | 'medium' | 'low' = 'high') {
  const run = vi.fn(async () => ({ body, confidence }));
  return { agent: { run } as AgentRunner, run };
}

function stubOccurrences(overrides: Partial<RoutineRunOccurrenceStore> = {}) {
  const occurrence: StoredRoutineOccurrence = {
    id: OCCURRENCE_ID,
    userId: USER_ID,
    routineId: ROUTINE_ID,
    occurrenceKey: `rem-routine-${ROUTINE_ID}-after-never`,
    state: 'running',
    attemptCount: 1,
    ownerToken: 'f6666666-0000-4000-8000-000000000007',
    commentId: null,
  };
  const store: RoutineRunOccurrenceStore = {
    loadPolicy: vi.fn(async (_userId, _routineId, snapshot) => snapshot),
    claim: vi.fn(async () => ({ kind: 'claimed' as const, occurrence })),
    retry: vi.fn(async () => true),
    waitForModel: vi.fn(async () => COMMENT_ID),
    settle: vi.fn(async () => COMMENT_ID),
    ...overrides,
  };
  return { store, occurrence };
}

/** Sequence an acting run: ownership, task, comments, insert-comment, stamp. */
function mockNormalRun() {
  poolMock.query
    .mockResolvedValueOnce({ rows: [{
      autonomy: 4,
      model: 'claude-sonnet',
      prompt: 'Summarize my open tasks for the day.',
      enabled: true,
    }] })
    .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines', status: 'pending', priority: 'high' }] })
    .mockResolvedValueOnce({ rows: [] })
    .mockResolvedValueOnce({ rows: [{ id: COMMENT_ID }] })
    .mockResolvedValueOnce({ rows: [] });
}

beforeEach(() => {
  vi.clearAllMocks();
  runAgentOnTaskMock.mockResolvedValue({
    reply: 'Here is your brief.',
    verdictSource: 'none',
    runtime: {
      runtimeId: 'rem_shared', persistenceKind: 'rem_runtime', billingMode: 'rem_managed',
    },
  });
});

describe('defaultAgentRunner runtime boundary', () => {
  const input = {
    task: { id: TASK_ID, title: 'Ship routines' },
    comments: [],
    instruction: 'Make a plan.',
    model: 'claude-sonnet',
    userId: USER_ID,
    sessionKey: `rem-routine-${ROUTINE_ID}`,
    idempotencyKey: `rem-routine-${ROUTINE_ID}-after-never`,
  };

  it('routes a plan through the tenant-scoped shared-runtime path with no acting policy', async () => {
    const result = await defaultAgentRunner.run({ ...input, mode: 'plan' });

    expect(runAgentOnTaskMock).toHaveBeenCalledWith(
      input.task,
      input.comments,
      input.instruction,
      {
        model: input.model,
        userId: USER_ID,
        sessionKey: input.sessionKey,
        authority: 'trusted_automation',
        idempotencyKey: input.idempotencyKey,
      },
    );
    expect(result).toEqual({
      body: 'Here is your brief.', confidence: 'medium', runtime: 'rem_runtime',
    });
  });

  it('keeps execute mode on the explicit transitional acting policy', async () => {
    await defaultAgentRunner.run({ ...input, mode: 'execute' });

    expect(runAgentOnTaskMock).toHaveBeenCalledWith(
      input.task,
      input.comments,
      input.instruction,
      expect.objectContaining({
        userId: USER_ID,
        authority: 'trusted_automation',
        idempotencyKey: input.idempotencyKey,
        toolPolicy: {
          mode: 'act', allowedTools: ['*'], approval: 'automation_policy',
        },
      }),
    );
  });

  it('preserves the shared runtime structured error signal', async () => {
    runAgentOnTaskMock.mockResolvedValueOnce({
      reply: 'temporary failure',
      errored: true,
      runBlock: { code: 'runtime_timeout', mode: 'rem_managed' },
    });
    await expect(defaultAgentRunner.run({ ...input, mode: 'plan' })).resolves.toMatchObject({
      errored: true,
      confidence: 'low',
      runBlock: { code: 'runtime_timeout', mode: 'rem_managed' },
    });
  });
});

describe('runRoutine — execute path (L3+)', () => {
  it('runs the agent and writes an attributed task_comment', async () => {
    mockNormalRun();
    const { agent, run } = stubAgent();

    const result = await runRoutine(routine(), NOW, { agent });

    expect(result.status).toBe('executed');
    expect(result.commentId).toBe(COMMENT_ID);
    expect(run).toHaveBeenCalledOnce();
    expect(run).toHaveBeenCalledWith(expect.objectContaining({
      userId: USER_ID,
      idempotencyKey: `rem-routine-${ROUTINE_ID}-after-never`,
      mode: 'execute',
    }));

    // The comment is written with cloud_agent attribution.
    const insertCall = poolMock.query.mock.calls[3];
    expect(insertCall[0]).toContain('INSERT INTO task_comments');
    expect(insertCall[0]).toContain("'cloud_agent'");
    expect(insertCall[1][0]).toBe(TASK_ID);
    expect(insertCall[1][1]).toBe(USER_ID);
    expect(insertCall[1][3]).toBe('Here is your brief.');

    // last_run_at is stamped after a successful run.
    expect(poolMock.query.mock.calls[4][0]).toContain('UPDATE routine_schedules SET last_run_at');
  });

  it('produces a RunReport with the documented shape', async () => {
    mockNormalRun();
    const { agent } = stubAgent('done', 'high');

    const { report } = await runRoutine(routine({ autonomy: 4 }), NOW, { agent });

    expect(report).toEqual({
      timestamp: '2026-06-26T15:00:00.000Z',
      routineId: ROUTINE_ID,
      sources: ['task'],
      writes: ['task_comment'],
      confidence: 'high',
      autonomyLevel: 4,
      needsReview: false,
    });
  });

  it('fails closed before an L3 wildcard run when routine/task ownership does not align', async () => {
    const { agent, run } = stubAgent();
    const { store } = stubOccurrences({ loadPolicy: vi.fn(async () => null) });

    const result = await runRoutine(routine({ autonomy: 4 }), NOW, { agent, occurrences: store });

    expect(result).toMatchObject({
      status: 'retrying', commentId: null, reason: 'routine task ownership unavailable',
    });
    expect(run).not.toHaveBeenCalled();
    expect(store.claim).not.toHaveBeenCalled();
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('honors a current L2 revocation when the scheduler still holds an L3 snapshot', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines' }] })
      .mockResolvedValueOnce({ rows: [] });
    const { agent, run } = stubAgent();
    const { store } = stubOccurrences({
      loadPolicy: vi.fn(async () => ({
        autonomy: 2,
        model: 'claude-sonnet',
        prompt: 'Make a plan only.',
        enabled: true,
      })),
    });

    const result = await runRoutine(
      routine({ autonomy: 4, prompt: 'Act on this task.' }),
      NOW,
      { agent, occurrences: store },
    );

    expect(result.status).toBe('planned');
    expect(store.claim).toHaveBeenCalledOnce();
    expect(run).toHaveBeenCalledWith(expect.objectContaining({
      mode: 'plan',
      instruction: 'Make a plan only.',
    }));
  });

  it('does not execute a scheduled L3 snapshot after the routine is paused', async () => {
    const { agent, run } = stubAgent();
    const { store } = stubOccurrences({
      loadPolicy: vi.fn(async () => ({
        autonomy: 4,
        model: 'claude-sonnet',
        prompt: 'Act on this task.',
        enabled: false,
      })),
    });

    const result = await runRoutine(
      routine({ autonomy: 4, enabled: true }), NOW, { agent, occurrences: store },
    );

    expect(result).toMatchObject({ status: 'skipped', reason: 'routine disabled' });
    expect(run).not.toHaveBeenCalled();
    expect(store.claim).not.toHaveBeenCalled();
    expect(poolMock.query).not.toHaveBeenCalled();
  });
});

describe('routineOccurrenceId', () => {
  it('is stable across stale mutable schedule snapshots until a run completes', () => {
    const priorRun = '2026-06-25T15:00:00.000Z';
    const stale = routine({
      cadence: 'daily', timezone: 'America/Los_Angeles', deliveryHour: 8, lastRunAt: priorRun,
    });
    const edited = routine({
      cadence: 'weekly', timezone: 'Pacific/Auckland', deliveryHour: 21, lastRunAt: priorRun,
    });
    const first = routineOccurrenceId(stale, new Date('2026-06-26T15:01:00.000Z'));
    const retry = routineOccurrenceId(edited, new Date('2026-06-27T00:01:00.000Z'));
    expect(first).toBe(retry);
    expect(first).toBe(`rem-routine-${ROUTINE_ID}-after-${priorRun}`);
    expect(routineOccurrenceId(routine({ lastRunAt: null }), NOW))
      .toBe(`rem-routine-${ROUTINE_ID}-after-never`);
  });

  it('lets an intentional manual dispatch use a distinct caller-owned identity', async () => {
    mockNormalRun();
    const { agent, run } = stubAgent();
    await runRoutine(
      routine(), NOW, { agent }, { kind: 'manual', idempotencyKey: 'manual-run-2' },
    );
    expect(run).toHaveBeenCalledWith(expect.objectContaining({ idempotencyKey: 'manual-run-2' }));
  });
});

describe('runRoutine — plan path (below L3)', () => {
  it('runs but flags the comment as a plan needing review', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines', status: 'pending', priority: 'high' }] })
      .mockResolvedValueOnce({ rows: [] });
    const { agent, run } = stubAgent();
    const { store } = stubOccurrences();

    const result = await runRoutine(routine({ autonomy: 1 }), NOW, { agent, occurrences: store });

    expect(result.status).toBe('planned');
    expect(run).toHaveBeenCalledOnce();
    expect(run).toHaveBeenCalledWith(expect.objectContaining({
      userId: USER_ID,
      sessionKey: `rem-routine-${ROUTINE_ID}`,
      idempotencyKey: `rem-routine-${ROUTINE_ID}-after-never:attempt:1`,
      mode: 'plan',
    }));
    expect(result.report.needsReview).toBe(true);

    // Plan comments are labelled distinctly and prefixed with a plan note.
    expect(store.settle).toHaveBeenCalledWith(expect.objectContaining({
      label: 'Rem Routine (plan)',
      body: expect.stringContaining('Plan'),
      stampSchedule: true,
    }));
    // The product comment and last_run_at stamp belong to one store settlement, not two pool calls.
    expect(poolMock.query).toHaveBeenCalledTimes(2);
  });

  it('releases a transient runtime failure without a comment or schedule stamp', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines' }] })
      .mockResolvedValueOnce({ rows: [] });
    const run = vi.fn(async () => ({
      body: 'temporary failure', confidence: 'low' as const, errored: true,
      runBlock: { code: 'runtime_timeout' as const, mode: 'rem_managed' as const },
    }));
    const { store } = stubOccurrences();

    const result = await runRoutine(
      routine({ autonomy: 1 }),
      NOW,
      { agent: { run }, occurrences: store },
    );

    expect(result).toMatchObject({ status: 'retrying', commentId: null });
    expect(store.retry).toHaveBeenCalledOnce();
    expect(store.settle).not.toHaveBeenCalled();
    expect(poolMock.query).toHaveBeenCalledTimes(2);
  });

  it('surfaces a stable quota block once instead of retrying every scheduler tick', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines' }] })
      .mockResolvedValueOnce({ rows: [] });
    const run = vi.fn(async () => ({
      body: 'Upgrade or wait for quota reset.',
      confidence: 'low' as const,
      errored: true,
      runBlock: { code: 'quota_exhausted' as const, mode: 'rem_managed' as const },
    }));
    const { store } = stubOccurrences();

    const result = await runRoutine(
      routine({ autonomy: 1 }), NOW, { agent: { run }, occurrences: store },
    );

    expect(result).toMatchObject({
      status: 'needs_attention', commentId: COMMENT_ID, reason: 'quota_exhausted',
    });
    expect(store.retry).not.toHaveBeenCalled();
    expect(store.settle).toHaveBeenCalledWith(expect.objectContaining({
      body: 'Upgrade or wait for quota reset.',
      label: 'Rem Routine (needs attention)',
      runBlock: { code: 'quota_exhausted', mode: 'rem_managed' },
      stampSchedule: true,
    }));
  });

  it('persists a structured unknown-runtime block when the defensive agent boundary throws', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines' }] })
      .mockResolvedValueOnce({ rows: [] });
    const run = vi.fn(async () => { throw new Error('socket exploded'); });
    const { store } = stubOccurrences();

    const result = await runRoutine(
      routine({ autonomy: 1 }), NOW, { agent: { run }, occurrences: store },
    );

    expect(result).toMatchObject({
      status: 'needs_attention', reason: 'runtime_error', commentId: COMMENT_ID,
    });
    expect(store.settle).toHaveBeenCalledWith(expect.objectContaining({
      runBlock: { code: 'runtime_error', mode: 'unknown' },
      stampSchedule: true,
    }));
  });

  it('does not run the agent twice for an already claimed occurrence', async () => {
    const { agent, run } = stubAgent();
    const fixture = stubOccurrences();
    fixture.store.claim = vi.fn(async () => ({
      kind: 'existing' as const, occurrence: fixture.occurrence,
    }));
    const { store } = fixture;

    const result = await runRoutine(routine({ autonomy: 2 }), NOW, { agent, occurrences: store });

    expect(result).toMatchObject({ status: 'skipped', commentId: null });
    expect(run).not.toHaveBeenCalled();
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('does not publish after losing settlement ownership', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines' }] })
      .mockResolvedValueOnce({ rows: [] });
    const { agent } = stubAgent();
    const { store } = stubOccurrences({ settle: vi.fn(async () => null) });

    const result = await runRoutine(routine({ autonomy: 1 }), NOW, { agent, occurrences: store });

    expect(result).toMatchObject({ status: 'retrying', commentId: null });
    expect(result.report.writes).toEqual([]);
  });
});

describe('runRoutine — null model short-circuit (#808)', () => {
  it('does not run the agent and surfaces a select-a-model comment', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{
        autonomy: 3, model: null, prompt: 'Summarize.', enabled: true,
      }] })
      .mockResolvedValueOnce({ rows: [{ id: COMMENT_ID }] });
    const { agent, run } = stubAgent();

    const result = await runRoutine(
      routine({ model: null }), NOW, { agent },
      { kind: 'manual', idempotencyKey: 'manual-missing-model' },
    );

    expect(result.status).toBe('needs_model');
    expect(result.reason).toBe('select a model');
    expect(run).not.toHaveBeenCalled();
    expect(result.report.needsReview).toBe(true);

    // Authoritative policy read + one surfaced comment. A warning is not a completed run.
    expect(poolMock.query).toHaveBeenCalledTimes(2);
    expect(poolMock.query.mock.calls[1][0]).toContain('INSERT INTO task_comments');
  });

  it('fences an L0-L2 model warning while preserving the scheduled occurrence', async () => {
    const { agent, run } = stubAgent();
    const { store } = stubOccurrences();

    const result = await runRoutine(
      routine({ autonomy: 1, model: null }),
      NOW,
      { agent, occurrences: store },
    );

    expect(result.status).toBe('needs_model');
    expect(run).not.toHaveBeenCalled();
    expect(store.claim).toHaveBeenCalledWith(expect.objectContaining({
      occurrenceKey: `rem-routine-${ROUTINE_ID}-after-never`,
    }));
    expect(store.waitForModel).toHaveBeenCalledWith(expect.objectContaining({
      body: expect.stringContaining('no model selected'),
    }));
    expect(store.settle).not.toHaveBeenCalled();
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('keeps a scheduled one-shot eligible until a model is selected', async () => {
    const { agent, run } = stubAgent();
    const { store } = stubOccurrences();

    const result = await runRoutine(
      routine({ autonomy: 1, cadence: 'once', model: null }),
      NOW,
      { agent, occurrences: store },
    );

    expect(result.status).toBe('needs_model');
    expect(store.waitForModel).toHaveBeenCalledOnce();
    expect(store.settle).not.toHaveBeenCalled();
    expect(run).not.toHaveBeenCalled();
  });

  it('retries the preserved scheduled occurrence after a model is selected', async () => {
    const { agent, run } = stubAgent();
    const fixture = stubOccurrences();

    const missing = await runRoutine(
      routine({ autonomy: 1, model: null }),
      NOW,
      { agent, occurrences: fixture.store },
    );
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines' }] })
      .mockResolvedValueOnce({ rows: [] });
    const afterSelection = new Date('2026-06-26T15:05:00.000Z');
    const recovered = await runRoutine(
      routine({ autonomy: 1, model: 'claude-sonnet', lastRunAt: null }),
      afterSelection,
      { agent, occurrences: fixture.store },
    );

    expect(missing.status).toBe('needs_model');
    expect(recovered.status).toBe('planned');
    expect(run).toHaveBeenCalledOnce();
    expect(vi.mocked(fixture.store.claim).mock.calls.map(([input]) => input.occurrenceKey))
      .toEqual([
        `rem-routine-${ROUTINE_ID}-after-never`,
        `rem-routine-${ROUTINE_ID}-after-never`,
      ]);
  });

  it('settles only one model warning when schedulers race', async () => {
    const fixture = stubOccurrences();
    fixture.store.claim = vi.fn()
      .mockResolvedValueOnce({ kind: 'claimed' as const, occurrence: fixture.occurrence })
      .mockResolvedValueOnce({ kind: 'existing' as const, occurrence: fixture.occurrence });
    const { agent, run } = stubAgent();

    const results = await Promise.all([
      runRoutine(routine({ autonomy: 1, model: null }), NOW, { agent, occurrences: fixture.store }),
      runRoutine(routine({ autonomy: 1, model: null }), NOW, { agent, occurrences: fixture.store }),
    ]);

    expect(results.map((result) => result.status).sort()).toEqual(['needs_model', 'skipped']);
    expect(fixture.store.waitForModel).toHaveBeenCalledOnce();
    expect(fixture.store.settle).not.toHaveBeenCalled();
    expect(run).not.toHaveBeenCalled();
  });

  it('fences an L3 missing-model warning when scheduler replicas race', async () => {
    const fixture = stubOccurrences();
    fixture.store.claim = vi.fn()
      .mockResolvedValueOnce({ kind: 'claimed' as const, occurrence: fixture.occurrence })
      .mockResolvedValueOnce({ kind: 'existing' as const, occurrence: fixture.occurrence });
    const { agent, run } = stubAgent();
    const missingModel = routine({ autonomy: 4, model: null });

    const results = await Promise.all([
      runRoutine(missingModel, NOW, { agent, occurrences: fixture.store }),
      runRoutine(missingModel, NOW, { agent, occurrences: fixture.store }),
    ]);

    expect(results.map((result) => result.status).sort()).toEqual(['needs_model', 'skipped']);
    expect(fixture.store.claim).toHaveBeenCalledTimes(2);
    expect(fixture.store.waitForModel).toHaveBeenCalledOnce();
    expect(fixture.store.settle).not.toHaveBeenCalled();
    expect(run).not.toHaveBeenCalled();
  });

  it('uses one canonical fence when scheduler replicas hold different config snapshots', async () => {
    const fixture = stubOccurrences();
    fixture.store.claim = vi.fn()
      .mockResolvedValueOnce({ kind: 'claimed' as const, occurrence: fixture.occurrence })
      .mockResolvedValueOnce({ kind: 'existing' as const, occurrence: fixture.occurrence });
    const { agent, run } = stubAgent();
    const stale = routine({
      autonomy: 1, model: null, cadence: 'daily', timezone: 'UTC', deliveryHour: 0,
    });
    const refreshed = routine({
      autonomy: 1, model: 'claude-sonnet', cadence: 'weekly',
      timezone: 'Pacific/Auckland', deliveryHour: 21,
    });

    const results = await Promise.all([
      runRoutine(stale, NOW, { agent, occurrences: fixture.store }),
      runRoutine(refreshed, NOW, { agent, occurrences: fixture.store }),
    ]);

    expect(results.map((result) => result.status).sort()).toEqual(['needs_model', 'skipped']);
    expect(fixture.store.claim).toHaveBeenCalledTimes(2);
    const claimedKeys = vi.mocked(fixture.store.claim).mock.calls
      .map(([input]) => input.occurrenceKey);
    expect(new Set(claimedKeys)).toEqual(new Set([
      `rem-routine-${ROUTINE_ID}-after-never`,
    ]));
    expect(run).not.toHaveBeenCalled();
  });
});

describe('runRoutine — hard deny list (#797)', () => {
  it('blocks a denied action before running the agent', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{
        autonomy: 3,
        model: 'claude-sonnet',
        prompt: 'Send an email to my boss with the report.',
        enabled: true,
      }] }) // authoritative policy preflight
      .mockResolvedValueOnce({ rows: [{ id: COMMENT_ID }] }) // surfaced blocked comment
      .mockResolvedValueOnce({ rows: [] }); // stamp
    const { agent, run } = stubAgent();

    const result = await runRoutine(
      routine({ prompt: 'Send an email to my boss with the report.' }),
      NOW,
      { agent },
      { kind: 'manual', idempotencyKey: 'manual-denied-run' },
    );

    expect(result.status).toBe('denied');
    expect(result.reason).toContain('send_communications');
    expect(run).not.toHaveBeenCalled();
    expect(result.report.needsReview).toBe(true);

    const insertCall = poolMock.query.mock.calls[1];
    expect(insertCall[0]).toContain('INSERT INTO task_comments');
    expect(insertCall[1][2]).toBe('Rem Routine (blocked)');
  });

  it('fences and atomically settles an L0-L2 denied outcome', async () => {
    const { agent, run } = stubAgent();
    const { store } = stubOccurrences();

    const result = await runRoutine(
      routine({ autonomy: 2, prompt: 'Send an email to my boss with the report.' }),
      NOW,
      { agent, occurrences: store },
    );

    expect(result.status).toBe('denied');
    expect(run).not.toHaveBeenCalled();
    expect(store.claim).toHaveBeenCalledWith(expect.objectContaining({
      occurrenceKey: `rem-routine-${ROUTINE_ID}-after-never`,
    }));
    expect(store.settle).toHaveBeenCalledWith(expect.objectContaining({
      label: 'Rem Routine (blocked)',
      stampSchedule: true,
    }));
    expect(poolMock.query).not.toHaveBeenCalled();
  });

  it('settles only one denied comment and stamp when schedulers race', async () => {
    const fixture = stubOccurrences();
    fixture.store.claim = vi.fn()
      .mockResolvedValueOnce({ kind: 'claimed' as const, occurrence: fixture.occurrence })
      .mockResolvedValueOnce({ kind: 'existing' as const, occurrence: fixture.occurrence });
    const { agent, run } = stubAgent();
    const denied = routine({ autonomy: 2, prompt: 'Send an email to my boss.' });

    const results = await Promise.all([
      runRoutine(denied, NOW, { agent, occurrences: fixture.store }),
      runRoutine(denied, NOW, { agent, occurrences: fixture.store }),
    ]);

    expect(results.map((result) => result.status).sort()).toEqual(['denied', 'skipped']);
    expect(fixture.store.settle).toHaveBeenCalledOnce();
    expect(fixture.store.settle).toHaveBeenCalledWith(expect.objectContaining({ stampSchedule: true }));
    expect(run).not.toHaveBeenCalled();
  });
});

describe('runDueRoutines — due-check integration', () => {
  it('runs only routines that are due in the user timezone', async () => {
    mockNormalRun(); // one due routine → one normal run
    const { agent, run } = stubAgent();

    const due = routine({ deliveryHour: 0, timezone: 'UTC', lastRunAt: null }); // due
    const notDue = routine({ id: 'd4444444-0000-4000-8000-000000000005', enabled: false }); // paused

    const results = await runDueRoutines([due, notDue], NOW, { agent });

    expect(results).toHaveLength(1);
    expect(results[0].status).toBe('executed');
    expect(run).toHaveBeenCalledOnce();
  });

  it('skips a routine that already ran today (local date)', async () => {
    const { agent, run } = stubAgent();
    const alreadyRan = routine({ lastRunAt: '2026-06-26T06:00:00.000Z' }); // same UTC day as NOW

    const results = await runDueRoutines([alreadyRan], NOW, { agent });

    expect(results).toHaveLength(0);
    expect(run).not.toHaveBeenCalled();
    expect(poolMock.query).not.toHaveBeenCalled();
  });
});
