/**
 * The classifier has two failure modes and this file pins both.
 *
 *  - Letting a VOLATILE runtime claim into durable memory is the #1282/#1277 bug: a stored
 *    "the user is on WebChat" outranks the correct, regenerated prompt forever.
 *  - Dropping a DURABLE user fact is equally a defect, and it is the one the previous revision
 *    shipped: the module's own doc comment promised that "a durable user preference that merely
 *    mentions a channel must survive", and then the bare-token surface patterns dropped exactly
 *    those sentences.
 *
 * Plus a hard privacy assertion: no verdict, and no error built from a verdict, may carry any
 * slice of the candidate fact. Verdicts travel into cron logs and into an HTTP response body.
 */

import { describe, it, expect } from 'vitest';
import {
  classifyVolatileFact,
  isDurableUserPreference,
  isMachineMemorySource,
  isVolatileRuntimeFact,
  rejectVolatileFacts,
  VOLATILE_RULE_IDS,
  VolatileMemoryRejectedError,
} from './volatile-runtime-facts.service.js';

/** The observed false claims. Every one of these must be refused. */
const VOLATILE_FACTS = [
  "The user is on WebChat — they're chatting with me through the Rem web interface.",
  'The user chats with Rem through the web version.',
  'Rem can check the user’s photos.',
  'Rem cannot access the user\'s camera.',
  'You can read the user\'s notifications.',
  'Rem has access to their screen.',
  'photos.latest is not exposed as a tool.',
  "The user's iPhone is currently connected to the gateway.",
  'The iPhone is paired and online.',
  'Rem is currently running on OpenClaw.',
  'The device is disconnected right now.',
];

/**
 * Durable facts about the PERSON. Several deliberately name a channel, a surface, or a
 * capability — that is the class the doc comment promises to preserve.
 */
const DURABLE_FACTS = [
  'The user prefers WhatsApp over email for quick messages.',
  'The user prefers the web version of Notion over the desktop app.',
  'The user does not want Rem to have access to their photos.',
  'Rem should confirm before sending email on the user\'s behalf.',
  'Rem must not schedule anything before 9am.',
  'The user prefers messaging with Rem through voice rather than typing.',
  'The user wants short answers with no preamble.',
  'The user\'s name is Samuel and he goes by Sam.',
  'The user commutes to the office on Tuesdays and Thursdays with their phone.',
  'The user is a designer working on an iOS app called Rem.',
  'The user likes their calendar blocked in 90-minute focus sessions.',
];

describe('classifyVolatileFact — refuses runtime assertions', () => {
  it.each(VOLATILE_FACTS)('refuses: %s', (fact) => {
    const verdict = classifyVolatileFact(fact);
    expect(verdict.volatile, `should be refused: ${fact}`).toBe(true);
    expect(verdict.category).toBeDefined();
    expect(VOLATILE_RULE_IDS).toContain(verdict.rule);
  });

  it('categorises the two observed live failures', () => {
    expect(classifyVolatileFact('The user is on WebChat.').category).toBe('surface');
    expect(classifyVolatileFact('Rem can check the user’s photos.').category).toBe(
      'capability',
    );
  });
});

describe('classifyVolatileFact — preserves durable facts about the person', () => {
  it.each(DURABLE_FACTS)('preserves: %s', (fact) => {
    expect(classifyVolatileFact(fact).volatile, `should survive: ${fact}`).toBe(false);
  });

  it('honours the carve-out its doc comment promises', () => {
    // A preference is durable even when it names a channel or a surface.
    expect(isDurableUserPreference('The user prefers the web version of Notion.')).toBe(true);
    expect(isVolatileRuntimeFact('The user prefers the web version of Notion.')).toBe(false);
    // But a bare assertion about the surface is not a preference.
    expect(isDurableUserPreference('The user is on the Rem web interface.')).toBe(false);
    expect(isVolatileRuntimeFact('The user is on the Rem web interface.')).toBe(true);
  });

  it('does not treat a web app the user merely mentions as a surface claim', () => {
    expect(isVolatileRuntimeFact('The user tracks invoices in a web app called Wave.')).toBe(false);
  });
});

describe('PRIVACY: a verdict never carries user content', () => {
  const SECRET = 'MedicalDiagnosisXYZ';

  it('the verdict exposes a rule id, not the matched text', () => {
    const verdict = classifyVolatileFact(`Rem can see the user's ${SECRET} photos.`);
    expect(verdict.volatile).toBe(true);
    expect(JSON.stringify(verdict)).not.toContain(SECRET);
    // The whole verdict is a closed set of constants.
    expect([...Object.keys(verdict)].sort()).toEqual(['category', 'rule', 'volatile']);
    expect(VOLATILE_RULE_IDS).toContain(verdict.rule);
  });

  it('the rejection error message carries no user content', () => {
    const verdict = classifyVolatileFact(`Rem can see the user's ${SECRET} photos.`);
    const error = new VolatileMemoryRejectedError(verdict.category!, verdict.rule!);
    expect(error.message).not.toContain(SECRET);
    expect(error.message).toContain(verdict.rule!);
    expect(error.message).toContain('volatile');
  });

  it('every reportable rule id is a stable constant, not derived from input', () => {
    for (const id of VOLATILE_RULE_IDS) {
      expect(id).toMatch(/^(surface|capability|connection)\.[a-z-]+$/);
    }
    expect(new Set(VOLATILE_RULE_IDS).size).toBe(VOLATILE_RULE_IDS.length);
  });
});

describe('batch + source helpers', () => {
  it('rejectVolatileFacts preserves order and keeps only durable facts', () => {
    const mixed = [DURABLE_FACTS[0], VOLATILE_FACTS[0], DURABLE_FACTS[1]];
    expect(rejectVolatileFacts(mixed)).toEqual([DURABLE_FACTS[0], DURABLE_FACTS[1]]);
  });

  it('non-strings and blanks are not volatile', () => {
    for (const value of [undefined, null, 42, {}, '', '   ']) {
      expect(isVolatileRuntimeFact(value as unknown)).toBe(false);
    }
  });

  it('only machine sources are screened', () => {
    for (const source of ['auto', 'AGENT', ' gateway ', 'session', 'chat']) {
      expect(isMachineMemorySource(source)).toBe(true);
    }
    for (const source of [null, undefined, '', 'user', 'manual']) {
      expect(isMachineMemorySource(source)).toBe(false);
    }
  });
});
