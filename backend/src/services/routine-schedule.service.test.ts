import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

// CRUD no longer touches the gateway: scheduling is backend-driven (run-routines.ts
// reads the row at run time), so there is nothing to stub beyond the DB pool.

import {
  buildRunReport,
  buildUpdateAssignments,
  createRoutine,
  deleteRoutine,
  formatRoutine,
  getRoutine,
  ROUTINE_RETURNING,
  setRoutineEnabled,
  stampLastRun,
  updateRoutine,
} from './routine-schedule.service.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const ROUTINE_ID = 'a1111111-0000-4000-8000-000000000002';
const TASK_ID = 'b2222222-0000-4000-8000-000000000003';

/** A raw routine_schedules row as pg would return it. */
function row(overrides: Record<string, unknown> = {}) {
  return {
    id: ROUTINE_ID,
    user_id: USER_ID,
    task_id: TASK_ID,
    cadence: 'daily',
    delivery_hour: 7,
    timezone: 'America/Los_Angeles',
    prompt: null,
    autonomy: 1,
    model: null,
    enabled: true,
    last_run_at: null,
    created_at: new Date('2026-06-26T00:00:00.000Z'),
    ...overrides,
  };
}

beforeEach(() => vi.clearAllMocks());

describe('formatRoutine', () => {
  it('projects a row into the camelCase domain shape with ISO dates', () => {
    const r = formatRoutine(
      row({
        prompt: 'Farm my context',
        autonomy: 3,
        model: 'claude-sonnet',
        last_run_at: new Date('2026-06-26T15:00:00.000Z'),
      }),
    );
    expect(r).toEqual({
      id: ROUTINE_ID,
      userId: USER_ID,
      taskId: TASK_ID,
      cadence: 'daily',
      deliveryHour: 7,
      timezone: 'America/Los_Angeles',
      prompt: 'Farm my context',
      autonomy: 3,
      model: 'claude-sonnet',
      enabled: true,
      lastRunAt: '2026-06-26T15:00:00.000Z',
      createdAt: '2026-06-26T00:00:00.000Z',
    });
  });

  it('normalizes nullable columns and never-run routines', () => {
    const r = formatRoutine(row());
    expect(r.prompt).toBeNull();
    expect(r.model).toBeNull();
    expect(r.lastRunAt).toBeNull();
  });
});

describe('buildUpdateAssignments', () => {
  it('returns no assignments for an empty patch', () => {
    expect(buildUpdateAssignments({})).toEqual({ assignments: [], values: [] });
  });

  it('builds a single assignment at the default start index', () => {
    expect(buildUpdateAssignments({ deliveryHour: 9 })).toEqual({
      assignments: ['delivery_hour = $1'],
      values: [9],
    });
  });

  it('maps camelCase fields to columns and numbers placeholders in column order', () => {
    const { assignments, values } = buildUpdateAssignments({
      enabled: false,
      timezone: 'UTC',
      autonomy: 2,
    });
    // Order follows UPDATE_COLUMNS: timezone, autonomy, enabled.
    expect(assignments).toEqual(['timezone = $1', 'autonomy = $2', 'enabled = $3']);
    expect(values).toEqual(['UTC', 2, false]);
  });

  it('honors an explicit startIndex so trailing WHERE params line up', () => {
    expect(buildUpdateAssignments({ model: 'gmi' }, 5)).toEqual({
      assignments: ['model = $5'],
      values: ['gmi'],
    });
  });

  it('treats null as a real value (clears prompt/model) but skips undefined', () => {
    const { assignments, values } = buildUpdateAssignments({ prompt: null, model: undefined });
    expect(assignments).toEqual(['prompt = $1']);
    expect(values).toEqual([null]);
  });
});

describe('buildRunReport', () => {
  const base = {
    routineId: ROUTINE_ID,
    timestamp: new Date('2026-06-26T15:00:00.000Z'),
    sources: ['task', 'comments'],
    writes: [] as string[],
    confidence: 'high' as const,
    autonomyLevel: 1,
  };

  it('shapes the report and serializes the timestamp', () => {
    const report = buildRunReport(base);
    expect(report.timestamp).toBe('2026-06-26T15:00:00.000Z');
    expect(report.routineId).toBe(ROUTINE_ID);
    expect(report.sources).toEqual(['task', 'comments']);
    expect(report.needsReview).toBe(false);
  });

  it('flags low confidence for review even with no writes', () => {
    expect(buildRunReport({ ...base, confidence: 'low' }).needsReview).toBe(true);
  });

  it('flags writes attempted below execute autonomy (L1)', () => {
    const report = buildRunReport({ ...base, writes: ['task_comment'], autonomyLevel: 1 });
    expect(report.needsReview).toBe(true);
  });

  it('allows writes at execute autonomy (L3) with sufficient confidence', () => {
    const report = buildRunReport({
      ...base,
      writes: ['task_comment'],
      autonomyLevel: 3,
      confidence: 'high',
    });
    expect(report.needsReview).toBe(false);
  });
});

describe('createRoutine', () => {
  it('applies defaults and inserts with parameterized values', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [row()] });

    await createRoutine(USER_ID, {
      taskId: TASK_ID,
      deliveryHour: 7,
      timezone: 'America/Los_Angeles',
    });

    const [sql, params] = poolMock.query.mock.calls[0];
    expect(sql).toContain('INSERT INTO routine_schedules');
    expect(sql).toContain(ROUTINE_RETURNING);
    // user_id, task_id, cadence, delivery_hour, timezone, prompt, autonomy, model, enabled
    expect(params).toEqual([USER_ID, TASK_ID, 'daily', 7, 'America/Los_Angeles', null, 1, null, true]);
  });

  it('clamps autonomy into the ladder range', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [row({ autonomy: 4 })] });
    await createRoutine(USER_ID, {
      taskId: TASK_ID,
      deliveryHour: 7,
      timezone: 'UTC',
      autonomy: 99,
    });
    const params = poolMock.query.mock.calls[0][1];
    expect(params[6]).toBe(4); // autonomy clamped to AUTONOMY_MAX
  });
});

describe('getRoutine', () => {
  it('returns the row scoped to the user', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [row()] });
    const r = await getRoutine(USER_ID, ROUTINE_ID);
    expect(r?.id).toBe(ROUTINE_ID);
    expect(poolMock.query.mock.calls[0][1]).toEqual([ROUTINE_ID, USER_ID]);
  });

  it('returns null when no row matches', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    expect(await getRoutine(USER_ID, ROUTINE_ID)).toBeNull();
  });
});

describe('updateRoutine', () => {
  it('builds a dynamic UPDATE with WHERE params after the SET values', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [row({ delivery_hour: 9, enabled: false })] });

    await updateRoutine(USER_ID, ROUTINE_ID, { deliveryHour: 9, enabled: false });

    const [sql, params] = poolMock.query.mock.calls[0];
    expect(sql).toContain('UPDATE routine_schedules SET delivery_hour = $1, enabled = $2');
    expect(sql).toContain('WHERE id = $3::uuid AND user_id = $4::uuid');
    expect(params).toEqual([9, false, ROUTINE_ID, USER_ID]);
  });

  it('skips the UPDATE and reads back the row for an empty patch', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [row()] });
    await updateRoutine(USER_ID, ROUTINE_ID, {});
    const sql = poolMock.query.mock.calls[0][0];
    expect(sql).toContain('SELECT');
    expect(sql).not.toContain('UPDATE');
  });
});

describe('setRoutineEnabled / deleteRoutine / stampLastRun', () => {
  it('setRoutineEnabled patches only the enabled flag', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [row({ enabled: false })] });
    const r = await setRoutineEnabled(USER_ID, ROUTINE_ID, false);
    expect(r?.enabled).toBe(false);
    expect(poolMock.query.mock.calls[0][1]).toEqual([ROUTINE_ID, USER_ID, false]);
  });

  it('deleteRoutine returns true when a row was removed', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [{ id: ROUTINE_ID }] });
    expect(await deleteRoutine(USER_ID, ROUTINE_ID)).toBe(true);
  });

  it('deleteRoutine returns false when nothing matched', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    expect(await deleteRoutine(USER_ID, ROUTINE_ID)).toBe(false);
  });

  it('stampLastRun writes an ISO timestamp keyed by id only', async () => {
    const at = new Date('2026-06-26T15:30:00.000Z');
    poolMock.query.mockResolvedValueOnce({ rows: [row({ last_run_at: at })] });
    const r = await stampLastRun(ROUTINE_ID, at);
    expect(r?.lastRunAt).toBe('2026-06-26T15:30:00.000Z');
    expect(poolMock.query.mock.calls[0][1]).toEqual([ROUTINE_ID, at.toISOString()]);
  });
});
