import { describe, expect, it } from 'vitest';
import { isDailyRoutineDue, localParts, type DailyRoutineSchedule } from './routine-schedule.js';

const LA = 'America/Los_Angeles';
const schedule = (over: Partial<DailyRoutineSchedule> = {}): DailyRoutineSchedule => ({
  deliveryHour: 7,
  timezone: LA,
  ...over,
});

describe('localParts', () => {
  it('converts an instant to local Y-M-D + hour + minute for the timezone', () => {
    // 2026-06-27T14:30:00Z = 07:30 PDT (UTC-7)
    const p = localParts(new Date('2026-06-27T14:30:00Z'), LA);
    expect(p).toEqual({ ymd: '2026-06-27', hour: 7, minute: 30 });
  });

  it('rolls the local date back across midnight UTC', () => {
    // 2026-06-27T05:00:00Z = 2026-06-26 22:00 PDT (previous local day)
    expect(localParts(new Date('2026-06-27T05:00:00Z'), LA).ymd).toBe('2026-06-26');
  });
});

describe('isDailyRoutineDue', () => {
  it('is due when the local hour has reached deliveryHour and it has not run today', () => {
    // 07:30 PDT, never run
    expect(isDailyRoutineDue(schedule(), new Date('2026-06-27T14:30:00Z'), null)).toBe(true);
  });

  it('is NOT due before deliveryHour', () => {
    // 06:00 PDT (13:00Z), deliveryHour 7
    expect(isDailyRoutineDue(schedule(), new Date('2026-06-27T13:00:00Z'), null)).toBe(false);
  });

  it('is NOT due again after it already ran today (same local date)', () => {
    const now = new Date('2026-06-27T16:00:00Z');      // 09:00 PDT
    const lastRun = new Date('2026-06-27T14:05:00Z');  // 07:05 PDT same local day
    expect(isDailyRoutineDue(schedule(), now, lastRun)).toBe(false);
  });

  it('is due again the next local day even if it ran yesterday', () => {
    const now = new Date('2026-06-28T14:30:00Z');      // next day 07:30 PDT
    const lastRun = new Date('2026-06-27T14:05:00Z');  // yesterday 07:05 PDT
    expect(isDailyRoutineDue(schedule(), now, lastRun)).toBe(true);
  });

  it('respects the user timezone (same instant differs by tz)', () => {
    const now = new Date('2026-06-27T11:30:00Z'); // 07:30 in New York (UTC-4), 04:30 in LA
    expect(isDailyRoutineDue(schedule({ timezone: 'America/New_York' }), now, null)).toBe(true);
    expect(isDailyRoutineDue(schedule({ timezone: LA }), now, null)).toBe(false);
  });

  it('is never due when disabled or given an invalid hour', () => {
    const now = new Date('2026-06-27T16:00:00Z');
    expect(isDailyRoutineDue(schedule({ enabled: false }), now, null)).toBe(false);
    expect(isDailyRoutineDue(schedule({ deliveryHour: 99 }), now, null)).toBe(false);
  });
});
