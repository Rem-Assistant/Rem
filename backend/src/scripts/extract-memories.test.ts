import { describe, expect, it, vi } from 'vitest';

// Importing the script pulls in db/pool.js (via the user-memory + extraction service imports),
// which reads DATABASE_URL at module load. Mock the pool so the pure selection/dedupe functions
// are importable without a database/env. The script's main() is guarded behind an import.meta
// check and never runs under test.
const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));

import {
  isMemoryKeeperEnabled,
  selectActiveUsers,
  shouldRunNightlyExtraction,
  utcDateKey,
  NIGHTLY_EXTRACTION_HOUR_UTC,
  NIGHTLY_EXTRACTION_WINDOW_HOURS,
  type UserActivity,
} from './extract-memories.js';
import {
  isNearDuplicateFact,
  selectNovelFacts,
  parseFactsFromCompletion,
  factSimilarity,
} from '../services/memory-extraction.service.js';

// 2026-06-29T12:00Z; default window is 14 days → cutoff is 2026-06-15T12:00Z.
const NOW = new Date('2026-06-29T12:00:00.000Z');

const USER_A = 'aaaaaaaa-0000-4000-8000-000000000001';
const USER_B = 'bbbbbbbb-0000-4000-8000-000000000002';
const USER_C = 'cccccccc-0000-4000-8000-000000000003';

describe('isMemoryKeeperEnabled — retirement kill-switch (docs/rebuild/31)', () => {
  it('is OFF by default (retired: native dreaming/memory-wiki own consolidation)', () => {
    expect(isMemoryKeeperEnabled({} as NodeJS.ProcessEnv)).toBe(false);
    expect(isMemoryKeeperEnabled({ MEMORY_KEEPER_ENABLED: '' } as NodeJS.ProcessEnv)).toBe(false);
    expect(isMemoryKeeperEnabled({ MEMORY_KEEPER_ENABLED: '0' } as NodeJS.ProcessEnv)).toBe(false);
    expect(isMemoryKeeperEnabled({ MEMORY_KEEPER_ENABLED: 'false' } as NodeJS.ProcessEnv)).toBe(false);
  });

  it('is re-enabled only by an explicit truthy flag', () => {
    for (const v of ['1', 'true', 'TRUE', 'yes', 'on', ' On ']) {
      expect(isMemoryKeeperEnabled({ MEMORY_KEEPER_ENABLED: v } as NodeJS.ProcessEnv)).toBe(true);
    }
  });
});

describe('selectActiveUsers — the due/selection logic', () => {
  it('keeps only users active within the window', () => {
    const users: UserActivity[] = [
      { userId: USER_A, lastActivityAt: '2026-06-28T10:00:00.000Z' }, // 1 day ago → active
      { userId: USER_B, lastActivityAt: '2026-05-01T10:00:00.000Z' }, // ~2 months ago → dormant
      { userId: USER_C, lastActivityAt: '2026-06-16T10:00:00.000Z' }, // 13 days ago → active
    ];
    expect(selectActiveUsers(users, NOW)).toEqual([USER_A, USER_C]);
  });

  it('treats the cutoff as inclusive (>= window boundary is active)', () => {
    const exactlyAtCutoff: UserActivity = {
      userId: USER_A,
      lastActivityAt: '2026-06-15T12:00:00.000Z', // exactly 14 days before NOW
    };
    expect(selectActiveUsers([exactlyAtCutoff], NOW)).toEqual([USER_A]);
  });

  it('skips users with no activity timestamp or an unparseable one', () => {
    const users: UserActivity[] = [
      { userId: USER_A, lastActivityAt: null },
      { userId: USER_B, lastActivityAt: 'not-a-date' },
    ];
    expect(selectActiveUsers(users, NOW)).toEqual([]);
  });

  it('honours a custom window', () => {
    const users: UserActivity[] = [
      { userId: USER_A, lastActivityAt: '2026-06-27T12:00:00.000Z' }, // 2 days ago
    ];
    expect(selectActiveUsers(users, NOW, 1)).toEqual([]); // outside a 1-day window
    expect(selectActiveUsers(users, NOW, 7)).toEqual([USER_A]);
  });
});

describe('shouldRunNightlyExtraction — nightly once-per-day gate', () => {
  // Use an explicit in-window hour so the test is independent of the env-configured default.
  const HOUR = NIGHTLY_EXTRACTION_HOUR_UTC; // window is [HOUR, HOUR+WINDOW)
  const WINDOW = NIGHTLY_EXTRACTION_WINDOW_HOURS;
  const inWindow = (h: number) => new Date(Date.UTC(2026, 5, 29, h, 0, 0));

  it('runs on the first in-window tick when it has never run', () => {
    expect(shouldRunNightlyExtraction(inWindow(HOUR), null)).toBe(true);
  });

  it('does NOT run outside the nightly window', () => {
    const before = (HOUR + 23) % 24; // an hour outside [HOUR, HOUR+WINDOW)
    const after = (HOUR + WINDOW) % 24;
    expect(shouldRunNightlyExtraction(inWindow(before), null)).toBe(false);
    expect(shouldRunNightlyExtraction(inWindow(after), null)).toBe(false);
  });

  it('skips later ticks the same UTC day once it has already run', () => {
    const firstTick = new Date(Date.UTC(2026, 5, 29, HOUR, 0, 0));
    const laterTick = new Date(Date.UTC(2026, 5, 29, HOUR, 45, 0));
    // Ran at firstTick → the :45 tick in the same window/day is a no-op.
    expect(shouldRunNightlyExtraction(laterTick, firstTick)).toBe(false);
  });

  it('runs again the next UTC day', () => {
    const yesterday = new Date(Date.UTC(2026, 5, 29, HOUR, 0, 0));
    const today = new Date(Date.UTC(2026, 5, 30, HOUR, 0, 0));
    expect(shouldRunNightlyExtraction(today, yesterday)).toBe(true);
  });

  it('utcDateKey is stable within a day and changes across days', () => {
    expect(utcDateKey(new Date('2026-06-29T00:00:00Z'))).toBe('2026-06-29');
    expect(utcDateKey(new Date('2026-06-29T23:59:59Z'))).toBe('2026-06-29');
    expect(utcDateKey(new Date('2026-06-30T00:00:00Z'))).toBe('2026-06-30');
  });
});

describe('isNearDuplicateFact — dedupe primitive', () => {
  it('treats identical facts as duplicates regardless of case/punctuation', () => {
    expect(isNearDuplicateFact('Has two cats.', 'has two cats')).toBe(true);
  });

  it('treats a substring/superset fact as a duplicate', () => {
    expect(isNearDuplicateFact('Prefers morning workouts', 'Prefers morning workouts before 8am'))
      .toBe(true);
  });

  it('treats a close rephrasing as a duplicate via token overlap', () => {
    // "calls mom every sunday" vs "calls his mom on sundays" — stopwords stripped, high overlap.
    expect(isNearDuplicateFact('Calls mom every Sunday', 'Calls his mom on Sundays')).toBe(true);
  });

  it('keeps genuinely distinct facts apart', () => {
    expect(isNearDuplicateFact('Has two cats', 'Works out in the morning')).toBe(false);
    expect(factSimilarity('Has two cats', 'Works out in the morning')).toBeLessThan(0.6);
  });
});

describe('selectNovelFacts — dedupe against existing + within batch', () => {
  it('drops candidates that duplicate an existing fact', () => {
    const existing = ['Has two cats named Mochi and Soba'];
    const candidates = ['Has two cats', 'Prefers tea over coffee'];
    expect(selectNovelFacts(candidates, existing)).toEqual(['Prefers tea over coffee']);
  });

  it('drops candidates that duplicate an earlier accepted candidate in the same batch', () => {
    const candidates = ['Prefers morning workouts', 'Prefers morning workouts before 8am'];
    expect(selectNovelFacts(candidates, [])).toEqual(['Prefers morning workouts']);
  });

  it('keeps all distinct candidates when nothing overlaps', () => {
    const candidates = ['Has two cats', 'Lives in Lagos', 'Runs every weekend'];
    expect(selectNovelFacts(candidates, [])).toEqual(candidates);
  });

  it('ignores blank candidates', () => {
    expect(selectNovelFacts(['  ', 'Lives in Lagos'], [])).toEqual(['Lives in Lagos']);
  });
});

describe('parseFactsFromCompletion — model output → clean candidate facts', () => {
  it('strips bullets, numbering, and wrapping quotes', () => {
    const text = '- Prefers morning workouts\n2. "Has two cats"\n* Calls mom on Sundays';
    expect(parseFactsFromCompletion(text)).toEqual([
      'Prefers morning workouts',
      'Has two cats',
      'Calls mom on Sundays',
    ]);
  });

  it('drops preamble and blank lines', () => {
    const text = 'Here are the durable facts I found:\n\nPrefers tea over coffee\n';
    expect(parseFactsFromCompletion(text)).toEqual(['Prefers tea over coffee']);
  });

  it('caps the number of facts and de-dupes within the output', () => {
    const text = 'Loves hiking\nLoves hiking on weekends\nReads sci-fi\nPlays guitar\nCooks Thai food';
    const facts = parseFactsFromCompletion(text, 3);
    expect(facts).toHaveLength(3);
    // "Loves hiking" and "Loves hiking on weekends" collapse to one.
    expect(facts).toEqual(['Loves hiking', 'Reads sci-fi', 'Plays guitar']);
  });

  it('returns nothing for an empty completion', () => {
    expect(parseFactsFromCompletion('')).toEqual([]);
  });

  // #1282/#1277 — volatile runtime facts are INELIGIBLE for durable memory. A stored
  // "the user is on WebChat" is re-injected into every future session and beats the correct,
  // regenerated prompt forever, which is how Rem came to tell a native iOS user it was on the
  // web. Durable facts in the same batch must still survive — including the ones that NAME a
  // channel or a capability, which is the false-drop the first attempt shipped.
  it('drops volatile runtime facts while keeping durable ones', () => {
    // Phrasings deliberately chosen NOT to start with "the user" — that prefix is already
    // caught by the preamble filter above, so using it here would make this test pass whether
    // or not the volatile filter exists.
    const text = [
      'Prefers morning workouts',
      'Chats with Rem through the Rem web interface (WebChat)',
      'Rem can access their photos and camera',
      'Their iPhone is currently paired and connected',
      'Prefers to be reached on WhatsApp rather than email',
      'Prefers the web version of Notion over the desktop app',
      'Does not want Rem to have access to their photos',
    ].join('\n');

    expect(parseFactsFromCompletion(text, 10)).toEqual([
      'Prefers morning workouts',
      'Prefers to be reached on WhatsApp rather than email',
      'Prefers the web version of Notion over the desktop app',
      'Does not want Rem to have access to their photos',
    ]);
  });
});
