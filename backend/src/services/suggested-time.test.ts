import { describe, expect, it } from 'vitest';

/**
 * Unit tests for the suggested-time contract.
 *
 * The module is a LEAF — no pool, no gateway, no env — so nothing here is mocked and every rule is
 * exercised directly. The theme, mirroring `signal-relevance.service.test.ts`: NO failure mode of
 * this contract may put a task somewhere the user did not expect. Every "the model misbehaved"
 * test asserts `null`, because `null` is what degrades to the pre-existing "later today".
 *
 * ZONES USED, and why each. All dates are in August 2026, so:
 *   America/New_York  UTC−4 (EDT)   — the "local day differs from the UTC day" cases
 *   Pacific/Auckland  UTC+12 (NZST) — the "local HOUR differs from the UTC hour" cases, in both
 *                                     directions, so a waking-hours check done in the wrong zone
 *                                     fails here rather than passing by luck
 */

import {
  SUGGESTED_TIME_BOUNDS,
  buildSuggestedTimePrompt,
  formatSuggestedTimeLabel,
  localDayStamp,
  localHour,
  localIsoWithOffset,
  plausibleSuggestedStart,
} from './suggested-time.js';
import { parseConnectorInstant } from './connector-signals.registry.js';

/** 2026-08-12 is a WEDNESDAY. 12:00Z = 08:00 in New York, 00:00 on the 13th in Auckland. */
const NOW = new Date('2026-08-12T12:00:00.000Z');
const NY = 'America/New_York';
const NZ = 'Pacific/Auckland';
const DAY_MS = 24 * 60 * 60 * 1000;

describe('plausibleSuggestedStart — the one rule, enforced on write AND on read', () => {
  it('accepts a future, in-horizon, waking-hours instant carrying an explicit offset', () => {
    // 2026-08-13T16:00−04:00 → 20:00Z. Tomorrow, 4pm local. The happy path.
    const out = plausibleSuggestedStart('2026-08-13T16:00:00-04:00', NOW, NY);
    expect(out?.toISOString()).toBe('2026-08-13T20:00:00.000Z');
  });

  it('accepts the equivalent instant written in UTC — the contract is the instant, not the spelling', () => {
    const out = plausibleSuggestedStart('2026-08-13T20:00:00Z', NOW, NY);
    expect(out?.toISOString()).toBe('2026-08-13T20:00:00.000Z');
  });

  /**
   * THE ISO TRAP (CLAUDE.md "Common Gotchas"). `new Date('2026-08-13T16:00:00')` happily returns
   * an instant by assuming the SERVER's zone — which on Railway is UTC and on a laptop is not. A
   * recommendation whose meaning depends on where the process runs is not a recommendation.
   */
  it('REFUSES an offset-less local datetime rather than assuming the server zone', () => {
    expect(plausibleSuggestedStart('2026-08-13T16:00:00', NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart('2026-08-13 16:00', NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart('2026-08-13', NOW, NY)).toBeNull();
  });

  it('refuses a calendar-impossible date instead of rolling it into the next month', () => {
    // `new Date('2026-02-30T16:00:00Z')` is Invalid Date in V8, but 2026-06-31 rolls to July 1 in
    // plenty of parsers. The strict reader round-trips every field, so neither survives.
    expect(plausibleSuggestedStart('2026-08-32T16:00:00-04:00', NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart('2026-09-31T16:00:00-04:00', NOW, NY)).toBeNull();
  });

  it('refuses prose that merely contains a time — there is no regex over the sentence', () => {
    expect(plausibleSuggestedStart('Thursday at 4pm', NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart('tomorrow', NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart('as soon as possible', NOW, NY)).toBeNull();
  });

  it('refuses the absent, the empty and the wrongly-typed', () => {
    expect(plausibleSuggestedStart(undefined, NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart(null, NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart('', NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart({ when: '2026-08-13T16:00:00Z' }, NOW, NY)).toBeNull();
    // A raw NUMBER is refused by type — `parseEpochInstant` is string-only on purpose, so an
    // already-parsed millisecond timestamp cannot re-enter as data.
    expect(plausibleSuggestedStart(1786620600000, NOW, NY)).toBeNull();
  });

  /**
   * The epoch STRING form, pinned deliberately rather than left to chance. It is accepted, and
   * that is not a hole in the offset rule: epoch is inherently UTC, so unlike a bare wall clock
   * there is nothing ambiguous to refuse. The clauses still apply to it in full.
   */
  it('accepts an epoch-number string, and still holds it to every other clause', () => {
    const target = new Date('2026-08-13T20:00:00.000Z'); // 16:00 New York, inside every bound
    const epochSeconds = String(target.getTime() / 1000);
    const epochMillis = String(target.getTime());
    expect(plausibleSuggestedStart(epochSeconds, NOW, NY)?.getTime()).toBe(target.getTime());
    expect(plausibleSuggestedStart(epochMillis, NOW, NY)?.getTime()).toBe(target.getTime());

    // Same shape, 03:00 New York — refused by the waking-hours clause, not waved through.
    const threeAm = String(new Date('2026-08-13T07:00:00.000Z').getTime());
    expect(plausibleSuggestedStart(threeAm, NOW, NY)).toBeNull();
    // Same shape, in the past.
    expect(plausibleSuggestedStart(String(NOW.getTime() - 1000), NOW, NY)).toBeNull();
  });

  /** Clause 2 — a past slot creates an instantly-overdue task, the defect `laterToday` avoids. */
  it('refuses a time in the past, and refuses `now` itself', () => {
    expect(plausibleSuggestedStart('2026-08-11T16:00:00-04:00', NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart(NOW.toISOString(), NOW, NY)).toBeNull();
    expect(plausibleSuggestedStart(new Date(NOW.getTime() - 1), NOW, NY)).toBeNull();
  });

  /** Clause 3 — past the horizon the judge was placing work on a calendar it was never shown. */
  it('refuses a time past the horizon, and accepts one just inside it', () => {
    // Both land at 08:00 New York, so the waking-hours clause cannot be what decides either.
    const insideHorizon = new Date(NOW.getTime() + 13 * DAY_MS); // 2026-08-25T12:00Z = 08:00 NY
    const pastHorizon = new Date(NOW.getTime() + 15 * DAY_MS);
    expect(plausibleSuggestedStart(insideHorizon, NOW, NY)?.getTime()).toBe(insideHorizon.getTime());
    expect(plausibleSuggestedStart(pastHorizon, NOW, NY)).toBeNull();
    expect(SUGGESTED_TIME_BOUNDS.horizonDays).toBe(14);
  });

  /** The boundary itself. Inclusive at exactly the horizon, exclusive one millisecond later. */
  it('accepts exactly the horizon and refuses one millisecond past it', () => {
    const exactly = new Date(NOW.getTime() + SUGGESTED_TIME_BOUNDS.horizonDays * DAY_MS);
    const justPast = new Date(exactly.getTime() + 1);
    expect(plausibleSuggestedStart(exactly, NOW, NY)?.getTime()).toBe(exactly.getTime());
    expect(plausibleSuggestedStart(justPast, NOW, NY)).toBeNull();
  });

  describe('clause 4 — waking hours, judged in the USER\'S zone', () => {
    it('refuses 3am local', () => {
      expect(plausibleSuggestedStart('2026-08-13T03:00:00-04:00', NOW, NY)).toBeNull();
    });

    it('accepts the inclusive 6am floor and refuses 5:59am', () => {
      expect(plausibleSuggestedStart('2026-08-13T06:00:00-04:00', NOW, NY)).not.toBeNull();
      expect(plausibleSuggestedStart('2026-08-13T05:59:00-04:00', NOW, NY)).toBeNull();
    });

    it('accepts 9:59pm and refuses the exclusive 10pm ceiling', () => {
      expect(plausibleSuggestedStart('2026-08-13T21:59:00-04:00', NOW, NY)).not.toBeNull();
      expect(plausibleSuggestedStart('2026-08-13T22:00:00-04:00', NOW, NY)).toBeNull();
    });

    /**
     * The pair that fails if the hour is read in UTC instead of the user's zone. Same two
     * instants, opposite verdicts, and the UTC reading gets BOTH backwards.
     */
    it('is decided by the local hour, not the UTC hour — in both directions', () => {
      // 16:00Z is a perfectly reasonable UTC hour, and 04:00 the next morning in Auckland.
      expect(plausibleSuggestedStart('2026-08-12T16:00:00Z', NOW, NZ)).toBeNull();
      // 23:00Z is outside waking hours in UTC, and 11:00 the next morning in Auckland.
      expect(plausibleSuggestedStart('2026-08-12T23:00:00Z', NOW, NZ)).not.toBeNull();
    });

    it('declines rather than skipping the check when the zone cannot be resolved', () => {
      expect(plausibleSuggestedStart('2026-08-13T16:00:00-04:00', NOW, 'Mars/Olympus')).toBeNull();
    });
  });

  it('accepts a Date straight through, so the read path needs no round trip to a string', () => {
    const stored = new Date('2026-08-13T20:00:00.000Z');
    expect(plausibleSuggestedStart(stored, NOW, NY)?.getTime()).toBe(stored.getTime());
    expect(plausibleSuggestedStart(new Date('nonsense'), NOW, NY)).toBeNull();
  });

  /**
   * THE READ-SIDE POINT OF THE WHOLE RULE. One stored value, judged valid when it was written and
   * stale a day later. This is why the reader re-checks instead of trusting the column.
   */
  it('turns stale the moment its instant passes, with no change to the stored value', () => {
    const stored = new Date('2026-08-13T20:00:00.000Z');
    expect(plausibleSuggestedStart(stored, NOW, NY)).not.toBeNull();
    const nextDay = new Date('2026-08-14T09:00:00.000Z');
    expect(plausibleSuggestedStart(stored, nextDay, NY)).toBeNull();
  });
});

describe('formatSuggestedTimeLabel — what the card actually shows', () => {
  it('names the next 36 hours the way a person does', () => {
    expect(formatSuggestedTimeLabel(new Date('2026-08-12T20:00:00Z'), NOW, NY))
      .toBe('Today 4:00 PM');
    expect(formatSuggestedTimeLabel(new Date('2026-08-13T14:00:00Z'), NOW, NY))
      .toBe('Tomorrow 10:00 AM');
  });

  it('uses a bare weekday inside a week — the founder\'s "Thursday 4:00 PM"', () => {
    // 2026-08-13 is a Thursday; 20:00Z is 4:00 PM in New York.
    expect(formatSuggestedTimeLabel(new Date('2026-08-13T20:00:00Z'), NOW, NY))
      .toBe('Tomorrow 4:00 PM');
    // 2026-08-15 is a Saturday — far enough to be named, close enough to be unambiguous.
    expect(formatSuggestedTimeLabel(new Date('2026-08-15T20:00:00Z'), NOW, NY))
      .toBe('Saturday 4:00 PM');
    // Day 6: 2026-08-18 is a Tuesday.
    expect(formatSuggestedTimeLabel(new Date('2026-08-18T20:00:00Z'), NOW, NY))
      .toBe('Tuesday 4:00 PM');
  });

  /** The founder's own headline string, asserted literally. */
  it('produces exactly "Thursday 4:00 PM" for a Thursday inside the week', () => {
    const monday = new Date('2026-08-10T12:00:00.000Z'); // 08:00 Monday in New York
    const thursday = new Date('2026-08-13T20:00:00.000Z'); // 16:00 Thursday in New York
    expect(formatSuggestedTimeLabel(thursday, monday, NY)).toBe('Thursday 4:00 PM');
  });

  it('falls back to a date past a week, where a weekday would be ambiguous', () => {
    expect(formatSuggestedTimeLabel(new Date('2026-08-25T20:00:00Z'), NOW, NY))
      .toBe('Aug 25, 4:00 PM');
  });

  /**
   * THE 6–7 DAY BAND — the case an elapsed-milliseconds guard gets wrong.
   *
   * A target seven CALENDAR days out whose time-of-day is earlier than now is only 6.67×24h away.
   * Counted in milliseconds it takes the weekday branch and prints TODAY'S weekday, so the user
   * reads a time that has already passed today, taps Add, and the task lands a week out.
   *
   * Both directions are asserted from the SAME calendar day, so this cannot pass by accident: the
   * earlier time-of-day (under 7×24h) and the later one (over it) must agree that day 7 is a date.
   */
  it('never names day 7 by weekday, however the clock falls', () => {
    const wednesdayEvening = new Date('2026-08-12T22:00:00.000Z'); // 18:00 Wed in New York
    const nextWednesdayMorning = new Date('2026-08-19T14:00:00.000Z'); // 10:00 Wed 19th
    expect(nextWednesdayMorning.getTime() - wednesdayEvening.getTime())
      .toBeLessThan(7 * 24 * 60 * 60 * 1000); // the trap: seven calendar days, under 7×24h

    const label = formatSuggestedTimeLabel(nextWednesdayMorning, wednesdayEvening, NY);
    expect(label).toBe('Aug 19, 10:00 AM');
    expect(label).not.toContain('Wednesday');

    const nextWednesdayNight = new Date('2026-08-20T00:00:00.000Z'); // 20:00 Wed 19th
    expect(formatSuggestedTimeLabel(nextWednesdayNight, wednesdayEvening, NY))
      .toBe('Aug 19, 8:00 PM');
  });

  it('counts the band in calendar days, so a late "now" cannot shrink it', () => {
    const lateWednesday = new Date('2026-08-12T23:30:00.000Z'); // 19:30 Wed in New York
    const earlyTuesday = new Date('2026-08-18T11:00:00.000Z'); // 07:00 Tue 18th — day 6
    expect(earlyTuesday.getTime() - lateWednesday.getTime())
      .toBeLessThan(6 * 24 * 60 * 60 * 1000); // under 6×24h, but six calendar days out
    expect(formatSuggestedTimeLabel(earlyTuesday, lateWednesday, NY)).toBe('Tuesday 7:00 AM');
  });

  /** "Today" must mean the user's today. In UTC this instant is already tomorrow. */
  it('decides Today/Tomorrow by the user\'s local day, not the UTC day', () => {
    const lateEvening = new Date('2026-08-13T01:00:00Z'); // 2026-08-12 21:00 in New York
    expect(lateEvening.toISOString().slice(0, 10)).toBe('2026-08-13'); // …but the 13th in UTC
    expect(formatSuggestedTimeLabel(lateEvening, NOW, NY)).toBe('Today 9:00 PM');
  });

  it('degrades to a bare time rather than throwing on an unresolvable zone', () => {
    expect(formatSuggestedTimeLabel(new Date('2026-08-13T20:00:00Z'), NOW, 'Mars/Olympus'))
      .not.toContain('Invalid');
  });
});

describe('localIsoWithOffset — the one string that spares the model any timezone arithmetic', () => {
  it('renders the local wall clock with the offset actually in effect', () => {
    expect(localIsoWithOffset(NOW, NY)).toBe('2026-08-12T08:00:00-04:00');
    expect(localIsoWithOffset(NOW, 'Europe/Berlin')).toBe('2026-08-12T14:00:00+02:00');
    expect(localIsoWithOffset(NOW, NZ)).toBe('2026-08-13T00:00:00+12:00');
  });

  it('spells a zero offset as +00:00, not as the bare "GMT" ICU hands back', () => {
    expect(localIsoWithOffset(NOW, 'UTC')).toBe('2026-08-12T12:00:00+00:00');
  });

  it('produces a string the strict parser reads back to the SAME instant', () => {
    for (const zone of [NY, NZ, 'Europe/Berlin', 'UTC', 'Asia/Kolkata']) {
      const rendered = localIsoWithOffset(NOW, zone);
      expect(rendered, zone).not.toBeNull();
      expect(parseConnectorInstant(rendered)?.getTime(), zone).toBe(NOW.getTime());
    }
  });

  it('returns null on an unresolvable zone rather than inventing an offset', () => {
    expect(localIsoWithOffset(NOW, 'Mars/Olympus')).toBeNull();
  });
});

describe('localDayStamp / localHour', () => {
  it('stamps the local calendar day, zero-padded', () => {
    expect(localDayStamp(new Date('2026-08-13T01:00:00Z'), NY)).toBe('2026-08-12');
    expect(localDayStamp(new Date('2026-08-13T01:00:00Z'), 'UTC')).toBe('2026-08-13');
  });

  it('reports midnight as hour 0, not as 24', () => {
    expect(localHour(new Date('2026-08-12T12:00:00Z'), NZ)).toBe(0);
    expect(localHour(new Date('2026-08-12T12:00:00Z'), NY)).toBe(8);
  });

  it('returns null on an unresolvable zone', () => {
    expect(localDayStamp(NOW, 'Mars/Olympus')).toBeNull();
    expect(localHour(NOW, 'Mars/Olympus')).toBeNull();
  });
});

describe('buildSuggestedTimePrompt', () => {
  const lines = buildSuggestedTimePrompt('2026-08-12T08:00:00-04:00', NY).join('\n');

  /** A bound restated in prose can go stale silently; interpolated, it cannot. */
  it('states the bounds it will actually enforce, taken from the bounds object', () => {
    expect(lines).toContain(`within ${SUGGESTED_TIME_BOUNDS.horizonDays} days`);
    expect(lines).toContain(`between ${SUGGESTED_TIME_BOUNDS.earliestLocalHour}:00`);
    expect(lines).toContain(`${SUGGESTED_TIME_BOUNDS.latestLocalHour}:00 local`);
  });

  it('hands the model the clock and the exact offset to echo, and forbids converting', () => {
    expect(lines).toContain('2026-08-12T08:00:00-04:00');
    expect(lines).toContain('Copy the offset "-04:00" exactly');
    expect(lines).toContain('do NOT convert to UTC');
  });

  it('tells it a time named IN the message beats a free choice', () => {
    expect(lines).toContain('use THAT time');
  });

  /** Mirrors `TASK_VERDICT_PROMPT`: omission is a supported answer, and the safer one. */
  it('makes omission explicit, and names what happens instead', () => {
    expect(lines).toContain('OMIT "w"');
    expect(lines).toContain('A wrong time is worse than none');
    expect(lines).toContain('later today');
  });

  /**
   * Never point at a section that was not written. "Avoid THEIR SCHEDULE" with no schedule block
   * is an instruction about an empty set — the same trap `CONTEXT_PRECEDENCE` is withheld to avoid.
   */
  it('only references the schedule section when one exists', () => {
    const withSchedule = buildSuggestedTimePrompt('2026-08-12T08:00:00-04:00', NY, true).join('\n');
    expect(withSchedule).toContain('THEIR SCHEDULE below');
    expect(lines).not.toContain('THEIR SCHEDULE');
    expect(lines).toContain('Nothing is on their calendar in this window');
  });
});
