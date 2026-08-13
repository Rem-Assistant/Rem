/**
 * The verdict contract itself, in isolation — the readers and the one normalizer.
 *
 * Most of these are NEGATIVE cases on purpose. A verdict reader that is too eager is worse
 * than one that is too strict: a missing verdict leaves the task untouched, a wrong one moves
 * it. So the tests that matter most here are the ones asserting that something does NOT parse.
 */
import { describe, expect, it } from 'vitest';
import {
  TASK_VERDICT_ENVELOPE_ID,
  TASK_VERDICT_TOOL_NAME,
  normalizeTaskVerdict,
  readVerdictFromReply,
  readVerdictFromToolCalls,
} from './task-verdict.js';

describe('normalizeTaskVerdict', () => {
  it('accepts each of the four statuses and nothing else', () => {
    for (const status of ['pending', 'in_progress', 'completed', 'blocked']) {
      expect(normalizeTaskVerdict({ status })).toEqual({ status });
    }
    expect(normalizeTaskVerdict({ status: 'cancelled' })).toBeUndefined();
    expect(normalizeTaskVerdict({ status: 'done' })).toBeUndefined();
    expect(normalizeTaskVerdict({ status: '' })).toBeUndefined();
  });

  it('normalizes spacing/casing of a status but never invents one', () => {
    expect(normalizeTaskVerdict({ status: ' In-Progress ' })).toEqual({ status: 'in_progress' });
    expect(normalizeTaskVerdict({ status: 'in progress' })).toEqual({ status: 'in_progress' });
    expect(normalizeTaskVerdict({ status: 'progress' })).toBeUndefined();
  });

  it('reads snake_case and camelCase spellings of the same field', () => {
    expect(normalizeTaskVerdict({ proposed_status: 'blocked' })).toEqual({ status: 'blocked' });
    expect(normalizeTaskVerdict({ proposedStatus: 'blocked' })).toEqual({ status: 'blocked' });
    expect(normalizeTaskVerdict({ status: 'pending', task_context: 'x' })?.taskContext).toBe('x');
    expect(normalizeTaskVerdict({ status: 'pending', taskContext: 'x' })?.taskContext).toBe('x');
  });

  it('yields NOTHING when the status is missing, even if other fields are valid', () => {
    // A confidence with no decision attached is not half a verdict.
    expect(normalizeTaskVerdict({ confidence: 0.9, task_context: 'lots of detail' })).toBeUndefined();
  });

  it('clamps confidence into [0,1] and drops a non-numeric one', () => {
    expect(normalizeTaskVerdict({ status: 'pending', confidence: 1.7 })?.confidence).toBe(1);
    expect(normalizeTaskVerdict({ status: 'pending', confidence: -3 })?.confidence).toBe(0);
    expect(normalizeTaskVerdict({ status: 'pending', confidence: 'high' })?.confidence).toBeUndefined();
    expect(normalizeTaskVerdict({ status: 'pending', confidence: NaN })?.confidence).toBeUndefined();
  });

  it('rejects non-objects outright', () => {
    for (const v of [null, undefined, 'completed', 42, ['completed']]) {
      expect(normalizeTaskVerdict(v)).toBeUndefined();
    }
  });
});

describe('readVerdictFromToolCalls', () => {
  it('reads the verdict off the tool call arguments', () => {
    expect(
      readVerdictFromToolCalls([{ name: TASK_VERDICT_TOOL_NAME, args: { status: 'completed' } }]),
    ).toEqual({ status: 'completed' });
  });

  it('accepts the dotted node-command spelling of the same tool', () => {
    expect(readVerdictFromToolCalls([{ name: 'task.report', args: { status: 'blocked' } }]))
      .toEqual({ status: 'blocked' });
    expect(readVerdictFromToolCalls([{ name: 'rem.task.report', args: { status: 'blocked' } }]))
      .toEqual({ status: 'blocked' });
  });

  it('falls back to the tool RESULT when the call carried no readable args', () => {
    expect(
      readVerdictFromToolCalls([
        { name: TASK_VERDICT_TOOL_NAME, args: undefined, result: { status: 'in_progress' } },
      ]),
    ).toEqual({ status: 'in_progress' });
  });

  it('takes the LAST verdict when the agent reported more than once', () => {
    expect(
      readVerdictFromToolCalls([
        { name: TASK_VERDICT_TOOL_NAME, args: { status: 'in_progress' } },
        { name: 'web_search', args: { q: 'x' } },
        { name: TASK_VERDICT_TOOL_NAME, args: { status: 'completed' } },
      ]),
    ).toEqual({ status: 'completed' });
  });

  it('ignores other tools even when their arguments happen to contain a status', () => {
    expect(
      readVerdictFromToolCalls([{ name: 'nodes', args: { status: 'completed', command: 'device.status' } }]),
    ).toBeUndefined();
  });

  it('returns nothing for an empty or absent list', () => {
    expect(readVerdictFromToolCalls([])).toBeUndefined();
    expect(readVerdictFromToolCalls(undefined)).toBeUndefined();
  });
});

describe('readVerdictFromReply', () => {
  it('reads the envelope and removes its line from the body', () => {
    const read = readVerdictFromReply(
      `Filed it.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"completed","confidence":0.5}`,
    );
    expect(read.verdict).toEqual({ status: 'completed', confidence: 0.5 });
    expect(read.body).toBe('Filed it.');
  });

  it('finds an envelope that is NOT the last line', () => {
    // The bug `stripStatusMarkerLine` was written to fix: a marker regex anchored on
    // end-of-string only worked when the model happened to put the marker last.
    const read = readVerdictFromReply(
      `${TASK_VERDICT_ENVELOPE_ID} {"status":"blocked"}\nStill waiting on them.`,
    );
    expect(read.verdict).toEqual({ status: 'blocked' });
    expect(read.body).toBe('Still waiting on them.');
  });

  it('tolerates markdown decoration around the machine line', () => {
    const read = readVerdictFromReply(`Done.\n> \`${TASK_VERDICT_ENVELOPE_ID} {"status":"completed"}\``);
    expect(read.verdict).toEqual({ status: 'completed' });
    expect(read.body).toBe('Done.');
  });

  it('does NOT read a status out of prose', () => {
    for (const prose of [
      'The status: completed checkbox is still unticked.',
      'proposed_status: completed',
      'I would mark this in_progress if I could.',
      'Status = blocked, apparently.',
    ]) {
      expect(readVerdictFromReply(prose).verdict).toBeUndefined();
    }
  });

  it('declines a DIFFERENT schema version rather than half-understanding it', () => {
    const read = readVerdictFromReply('ok\nrem.task_verdict.v2 {"status":"completed"}');
    expect(read.verdict).toBeUndefined();
  });

  it('strips a malformed machine line from the body but reads no verdict from it', () => {
    const read = readVerdictFromReply(`Tried.\n${TASK_VERDICT_ENVELOPE_ID} {status: completed`);
    expect(read.verdict).toBeUndefined();
    expect(read.body).toBe('Tried.');
    expect(read.body).not.toContain(TASK_VERDICT_ENVELOPE_ID);
  });

  it('reads no verdict from a well-formed envelope carrying an unknown status', () => {
    const read = readVerdictFromReply(`Tried.\n${TASK_VERDICT_ENVELOPE_ID} {"status":"cancelled"}`);
    expect(read.verdict).toBeUndefined();
    expect(read.body).toBe('Tried.');
  });

  it('takes the LAST valid envelope when the model emitted several', () => {
    const read = readVerdictFromReply(
      [
        'Thinking out loud.',
        `${TASK_VERDICT_ENVELOPE_ID} {"status":"in_progress"}`,
        'Actually, it is finished.',
        `${TASK_VERDICT_ENVELOPE_ID} {"status":"completed"}`,
      ].join('\n'),
    );
    expect(read.verdict).toEqual({ status: 'completed' });
    expect(read.body).toBe('Thinking out loud.\nActually, it is finished.');
  });

  it('returns an empty body for empty input rather than throwing', () => {
    expect(readVerdictFromReply(null)).toEqual({ body: '' });
    expect(readVerdictFromReply(undefined)).toEqual({ body: '' });
    expect(readVerdictFromReply('')).toEqual({ body: '' });
  });
});
