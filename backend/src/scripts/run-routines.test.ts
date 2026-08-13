import { describe, expect, it, vi } from 'vitest';

// Importing the script pulls in db/pool.js (which reads DATABASE_URL at module load) via
// the runRoutine import. Mock the pool so the pure due-filter functions are importable
// without a database/env. The script's main() is guarded behind an import.meta check and
// never runs under test.
const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

import { isRoutineDue, selectDueRoutines } from './run-routines.js';
import type { RoutineSchedule } from '../services/routine.types.js';

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';
const ROUTINE_ID = 'a1111111-0000-4000-8000-000000000002';
const TASK_ID = 'b2222222-0000-4000-8000-000000000003';

// 2026-06-29 is a Monday. 15:00Z is afternoon in every timezone we test against, so a
// deliveryHour of 0 is always "reached" for daily routines at NOW.
const NOW = new Date('2026-06-29T15:00:00.000Z');

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
    createdAt: '2026-06-29T00:00:00.000Z',
    ...overrides,
  };
}

describe('selectDueRoutines — the due-filter loop', () => {
  it('keeps only routines that are due now, in the user timezone', () => {
    const due = routine({ id: 'r-due', deliveryHour: 0, timezone: 'UTC', lastRunAt: null });
    const hourNotReached = routine({
      id: 'r-future',
      // 23:00 local in UTC has not been reached at 15:00Z.
      deliveryHour: 23,
      timezone: 'UTC',
      lastRunAt: null,
    });
    const alreadyRanToday = routine({
      id: 'r-ran',
      deliveryHour: 0,
      timezone: 'UTC',
      lastRunAt: '2026-06-29T06:00:00.000Z', // same local day as NOW
    });

    const result = selectDueRoutines([due, hourNotReached, alreadyRanToday], NOW);

    expect(result.map((r) => r.id)).toEqual(['r-due']);
  });

  it('skips disabled routines even when their schedule would otherwise be due', () => {
    const enabled = routine({ id: 'r-on', enabled: true });
    const disabled = routine({ id: 'r-off', enabled: false });

    const result = selectDueRoutines([enabled, disabled], NOW);

    expect(result.map((r) => r.id)).toEqual(['r-on']);
  });

  it('returns an empty list when nothing is due', () => {
    const disabled = routine({ id: 'r-off', enabled: false });
    const future = routine({ id: 'r-future', deliveryHour: 23 });

    expect(selectDueRoutines([disabled, future], NOW)).toHaveLength(0);
  });
});

describe('isRoutineDue — cadence handling', () => {
  it('daily: due once the delivery hour is reached and it has not run today', () => {
    expect(isRoutineDue(routine({ cadence: 'daily' }), NOW, null)).toBe(true);
  });

  it('disabled routines are never due', () => {
    expect(isRoutineDue(routine({ enabled: false }), NOW, null)).toBe(false);
  });

  it('weekly: due on Monday local, not on other weekdays', () => {
    // NOW (2026-06-29) is a Monday.
    expect(isRoutineDue(routine({ cadence: 'weekly', timezone: 'UTC' }), NOW, null)).toBe(true);
    // Tuesday 2026-06-30 is not Monday → not due.
    const tuesday = new Date('2026-06-30T15:00:00.000Z');
    expect(isRoutineDue(routine({ cadence: 'weekly', timezone: 'UTC' }), tuesday, null)).toBe(false);
  });

  it('once: due only when it has never run', () => {
    expect(isRoutineDue(routine({ cadence: 'once' }), NOW, null)).toBe(true);
    const ranAlready = new Date('2026-06-20T06:00:00.000Z');
    expect(isRoutineDue(routine({ cadence: 'once' }), NOW, ranAlready)).toBe(false);
  });
});
