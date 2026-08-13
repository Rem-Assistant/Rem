import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

import {
  runDueRoutines,
  runRoutine,
  type AgentRunner,
} from './routine-runner.service.js';
import type { RoutineSchedule } from './routine.types.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const ROUTINE_ID = 'a1111111-0000-4000-8000-000000000002';
const TASK_ID = 'b2222222-0000-4000-8000-000000000003';
const COMMENT_ID = 'c3333333-0000-4000-8000-000000000004';
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

/** Sequence the DB calls a normal run makes: task, comments, insert-comment, stamp. */
function mockNormalRun() {
  poolMock.query
    .mockResolvedValueOnce({ rows: [{ id: TASK_ID, title: 'Ship routines', status: 'pending', priority: 'high' }] })
    .mockResolvedValueOnce({ rows: [] })
    .mockResolvedValueOnce({ rows: [{ id: COMMENT_ID }] })
    .mockResolvedValueOnce({ rows: [] });
}

beforeEach(() => vi.clearAllMocks());

describe('runRoutine — execute path (L3+)', () => {
  it('runs the agent and writes an attributed task_comment', async () => {
    mockNormalRun();
    const { agent, run } = stubAgent();

    const result = await runRoutine(routine(), NOW, { agent });

    expect(result.status).toBe('executed');
    expect(result.commentId).toBe(COMMENT_ID);
    expect(run).toHaveBeenCalledOnce();

    // The comment is written with cloud_agent attribution.
    const insertCall = poolMock.query.mock.calls[2];
    expect(insertCall[0]).toContain('INSERT INTO task_comments');
    expect(insertCall[0]).toContain("'cloud_agent'");
    expect(insertCall[1][0]).toBe(TASK_ID);
    expect(insertCall[1][1]).toBe(USER_ID);
    expect(insertCall[1][3]).toBe('Here is your brief.');

    // last_run_at is stamped after a successful run.
    expect(poolMock.query.mock.calls[3][0]).toContain('UPDATE routine_schedules SET last_run_at');
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
});

describe('runRoutine — plan path (below L3)', () => {
  it('runs but flags the comment as a plan needing review', async () => {
    mockNormalRun();
    const { agent, run } = stubAgent();

    const result = await runRoutine(routine({ autonomy: 1 }), NOW, { agent });

    expect(result.status).toBe('planned');
    expect(run).toHaveBeenCalledOnce();
    expect(result.report.needsReview).toBe(true);

    // Plan comments are labelled distinctly and prefixed with a plan note.
    const insertCall = poolMock.query.mock.calls[2];
    expect(insertCall[1][2]).toBe('Rem Routine (plan)');
    expect(insertCall[1][3]).toContain('Plan');
  });
});

describe('runRoutine — null model short-circuit (#808)', () => {
  it('does not run the agent and surfaces a select-a-model comment', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ id: COMMENT_ID }] });
    const { agent, run } = stubAgent();

    const result = await runRoutine(routine({ model: null }), NOW, { agent });

    expect(result.status).toBe('needs_model');
    expect(result.reason).toBe('select a model');
    expect(run).not.toHaveBeenCalled();
    expect(result.report.needsReview).toBe(true);

    // Exactly one DB write (the surfaced comment); last_run_at is NOT stamped.
    expect(poolMock.query).toHaveBeenCalledOnce();
    expect(poolMock.query.mock.calls[0][0]).toContain('INSERT INTO task_comments');
  });
});

describe('runRoutine — hard deny list (#797)', () => {
  it('blocks a denied action before running the agent', async () => {
    poolMock.query
      .mockResolvedValueOnce({ rows: [{ id: COMMENT_ID }] }) // surfaced blocked comment
      .mockResolvedValueOnce({ rows: [] }); // stamp
    const { agent, run } = stubAgent();

    const result = await runRoutine(
      routine({ prompt: 'Send an email to my boss with the report.' }),
      NOW,
      { agent },
    );

    expect(result.status).toBe('denied');
    expect(result.reason).toContain('send_communications');
    expect(run).not.toHaveBeenCalled();
    expect(result.report.needsReview).toBe(true);

    const insertCall = poolMock.query.mock.calls[0];
    expect(insertCall[0]).toContain('INSERT INTO task_comments');
    expect(insertCall[1][2]).toBe('Rem Routine (blocked)');
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
