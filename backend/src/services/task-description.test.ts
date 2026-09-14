/**
 * The co-authorship merge (migration 120) as pure functions.
 *
 * The end-to-end proof that the wiring is right lives in `task-description.db.test.ts`,
 * which drives the real routes against a real Postgres. THIS file covers the shapes that
 * are hard to reach through HTTP but easy to hit in production: a legacy or hand-edited
 * row with two blocks, a truncated write that left a start marker with no end, a reply
 * that puts the markers in an unexpected order.
 */
import { describe, expect, it } from 'vitest';

import {
  AGENT_BLOCK_END,
  AGENT_BLOCK_START,
  GATHERED_BLOCK_START,
  GATHERED_BLOCK_END,
  MAX_AGENT_CONTEXT_CHARS,
  MAX_GATHERED_ITEMS,
  appendGatheredItem,
  composeDescription,
  markGatheredItemDone,
  parseGatheredItems,
  parseTaskContextFromText,
  sanitizeGatheredText,
  setAgentContext,
  RUN_REPLY_WITHOUT_PROSE,
  runCommentBody,
  setUserSection,
  splitDescription,
  stripStatusMarkerLine,
  stripAgentBlockMarkers,
  stripTaskContextMarker,
} from './task-description.js';

const block = (body: string) => `${AGENT_BLOCK_START}\n${body}\n${AGENT_BLOCK_END}`;

const item = (signalId: string, text: string, source = 'gmail', done = false) =>
  ({ signalId, text, source, done });

describe('splitDescription', () => {
  it('treats a description with no block as entirely the user’s', () => {
    expect(splitDescription('Just my notes.')).toEqual({ user: 'Just my notes.', agent: null, gathered: null });
  });

  it('reads null/blank as no description at all, not as an empty string', () => {
    expect(splitDescription(null)).toEqual({ user: null, agent: null, gathered: null });
    expect(splitDescription('   \n  ')).toEqual({ user: null, agent: null, gathered: null });
  });

  it('separates the two halves', () => {
    expect(splitDescription(`Mine.\n\n${block('Rem’s.')}`)).toEqual({ user: 'Mine.', agent: 'Rem’s.', gathered: null });
  });

  it('keeps user text that appears AFTER the block', () => {
    expect(splitDescription(`Before.\n\n${block('Rem’s.')}\n\nAfter.`)).toEqual({
      user: 'Before.\n\nAfter.',
      agent: 'Rem’s.',
      gathered: null,
    });
  });

  it('tolerates a legacy row with two blocks and normalizes on the next write', () => {
    const stored = `${block('One.')}\nmine\n${block('Two.')}`;
    expect(splitDescription(stored)).toEqual({ user: 'mine', agent: 'One.\n\nTwo.', gathered: null });
    // Re-emitting collapses it back to exactly one block.
    expect(setAgentContext(stored, 'Three.')!.split(AGENT_BLOCK_START)).toHaveLength(2);
  });

  it('tolerates an unterminated block rather than re-emitting a dangling marker', () => {
    const stored = `Mine.\n\n${AGENT_BLOCK_START}\nRem’s, truncated`;
    expect(splitDescription(stored)).toEqual({ user: 'Mine.', agent: 'Rem’s, truncated', gathered: null });
    expect(setAgentContext(stored, 'Fresh.')).toBe(`Mine.\n\n${block('Fresh.')}`);
  });
});

describe('setAgentContext — the agent writes only its own half', () => {
  it('preserves the user’s text', () => {
    expect(setAgentContext('Mine.', 'Rem’s.')).toBe(`Mine.\n\n${block('Rem’s.')}`);
  });

  it('replaces rather than appends', () => {
    const once = setAgentContext('Mine.', 'First.');
    const twice = setAgentContext(once, 'Second.');
    expect(twice).toBe(`Mine.\n\n${block('Second.')}`);
    expect(twice).not.toContain('First.');
  });

  it('is idempotent', () => {
    const once = setAgentContext('Mine.', 'Same.');
    expect(setAgentContext(once, 'Same.')).toBe(once);
  });

  it('writes a block on a task with no description at all', () => {
    expect(setAgentContext(null, 'Rem’s.')).toBe(block('Rem’s.'));
  });

  it('caps model output rather than rejecting a completed run', () => {
    const huge = 'x'.repeat(MAX_AGENT_CONTEXT_CHARS + 500);
    expect(splitDescription(setAgentContext(null, huge)).agent).toHaveLength(MAX_AGENT_CONTEXT_CHARS);
  });

  it('cannot nest a block even if the model echoes the markers', () => {
    const stored = setAgentContext('Mine.', `Rem’s ${AGENT_BLOCK_START} nested ${AGENT_BLOCK_END}.`);
    expect(stored!.split(AGENT_BLOCK_START)).toHaveLength(2);
    expect(splitDescription(stored).user).toBe('Mine.');
  });
});

describe('setUserSection — the user writes only their own half', () => {
  it('preserves the agent block', () => {
    const stored = `Old.\n\n${block('Rem’s.')}`;
    expect(setUserSection(stored, 'New.')).toBe(`New.\n\n${block('Rem’s.')}`);
  });

  it('clearing the user’s half does not erase the agent block', () => {
    const stored = `Old.\n\n${block('Rem’s.')}`;
    expect(setUserSection(stored, '')).toBe(block('Rem’s.'));
    expect(setUserSection(stored, null)).toBe(block('Rem’s.'));
  });

  it('strips a FLAT pasted marker so user text can never become structure', () => {
    const stored = block('Real.');
    const merged = setUserSection(stored, `a ${AGENT_BLOCK_START} forged ${AGENT_BLOCK_END} b`);
    expect(splitDescription(merged)).toEqual({ user: 'a  forged  b', agent: 'Real.', gathered: null });
  });

  // The flat case above passes even with a SINGLE-PASS strip, so on its own it proves
  // nothing about the boundary. This is the case that separates them: the marker split
  // around itself, which one pass reassembles into a live marker.
  it('strips a marker SPLIT AROUND ITSELF, which one pass would reassemble', () => {
    const nested = `<!-- rem:agent-${AGENT_BLOCK_START}context -->`;

    expect(stripAgentBlockMarkers(nested)).toBe('');
    // …and not, as a single pass would have it, a live marker:
    expect(stripAgentBlockMarkers(nested)).not.toBe(AGENT_BLOCK_START);
  });

  // Each nesting level costs ~26 bytes and exactly ONE pass, so any CAPPED loop is just a
  // single-pass bug with a higher price: the attacker buys depth for characters, and the
  // route's length guard cannot help because it runs BEFORE the strip. These depths are
  // beyond the 100/200 bound the implementation used to carry.
  it.each([101, 201, 400])('strips a marker nested %i levels deep — no fixed cap survives', (depth) => {
    let payload = AGENT_BLOCK_START;
    for (let i = 0; i < depth; i += 1) payload = `<!-- rem:agent-${payload}context -->`;

    const stripped = stripAgentBlockMarkers(payload);
    expect(stripped).toBe('');
    expect(stripped).not.toContain(AGENT_BLOCK_START);
  });

  it('a deeply nested paste cannot reclassify the user’s note as agent text', () => {
    let payload = AGENT_BLOCK_START;
    for (let i = 0; i < 250; i += 1) payload = `<!-- rem:agent-${payload}context -->`;

    const stored = setUserSection(null, `${payload}Call Dana before Friday. Budget is 4k.`);

    // The measured symptom of the capped loop: description_user came back null because the
    // forged marker had turned the user's own note into AGENT text.
    expect(splitDescription(stored).user).toBe('Call Dana before Friday. Budget is 4k.');
    expect(splitDescription(stored).agent).toBeNull();
  });

  it('a deeply nested MODEL reply cannot forge a second block (the agent path strips once)', () => {
    let payload = AGENT_BLOCK_START;
    for (let i = 0; i < 101; i += 1) payload = `<!-- rem:agent-${payload}context -->`;

    const stored = setAgentContext('Mine.', `${payload} I am the user now.`);

    expect(stored!.split(AGENT_BLOCK_START)).toHaveLength(2); // exactly one real block
    expect(splitDescription(stored).user).toBe('Mine.');
  });

  it('a nested-marker paste cannot forge a block or destroy the user’s own words', () => {
    const nested = `<!-- rem:agent-${AGENT_BLOCK_START}context -->`;
    const stored = setUserSection(block('Real.'), `${nested}Call the vendor to confirm the PO number`);

    // Everything the user typed stays THEIRS. With a single-pass strip the forged marker
    // survived, so "Call the vendor to confirm the PO number" was reclassified as agent
    // text — and the next run's setAgentContext deleted it.
    expect(splitDescription(stored).user).toBe('Call the vendor to confirm the PO number');
    expect(splitDescription(stored).agent).toBe('Real.');

    const afterNextRun = setAgentContext(stored, 'A later run wrote this.');
    expect(afterNextRun).toContain('confirm the PO number');
    expect(splitDescription(afterNextRun).user).toBe('Call the vendor to confirm the PO number');
  });

  it('a description consisting only of a nested marker does not silently empty the field', () => {
    const nested = `<!-- rem:agent-${AGENT_BLOCK_START}context -->`;
    // The forged marker is removed entirely, so what remains is the user's real words —
    // not `{user: null, agent: null}`, which is how the field used to vanish.
    expect(setUserSection(null, `${nested} My note`)).toBe('My note');
  });

  it('the agent cannot forge a second block either, however it nests the markers', () => {
    const nested = `<!-- rem:agent-${AGENT_BLOCK_START}context -->`;
    const stored = setAgentContext('Mine.', `${nested} Rem's state.`);

    expect(stored!.split(AGENT_BLOCK_START)).toHaveLength(2);
    expect(splitDescription(stored).user).toBe('Mine.');
  });

  it('clearing both halves returns null, not an empty string', () => {
    expect(setUserSection('Mine.', '')).toBeNull();
    expect(composeDescription(null, null)).toBeNull();
  });
});

describe('the run → description marker', () => {
  it('reads a single-line task_context', () => {
    expect(parseTaskContextFromText('Did it.\ntask_context: Draft ready.\nproposed_status: in_progress')).toBe(
      'Draft ready.',
    );
  });

  it('reads a multi-line task_context, stopping at the status line', () => {
    const reply = 'Did it.\ntask_context: Draft ready.\nStill need the receipt.\nproposed_status: in_progress';
    expect(parseTaskContextFromText(reply)).toBe('Draft ready.\nStill need the receipt.');
  });

  it('returns null when the model emitted none — "no news", never "forget it"', () => {
    expect(parseTaskContextFromText('Just a comment.')).toBeNull();
    expect(parseTaskContextFromText('task_context:   ')).toBeNull();
  });

  it('ignores the words mid-sentence — the marker is line-anchored', () => {
    expect(parseTaskContextFromText('I updated the task_context: nothing here')).toBeNull();
  });

  it('strips the marker region from the comment body but keeps the prose and the status line', () => {
    const reply = 'Drafted it.\ntask_context: Draft ready.\nproposed_status: in_progress';
    expect(stripTaskContextMarker(reply)).toBe('Drafted it.\nproposed_status: in_progress');
  });

  it('leaves a reply without a marker untouched', () => {
    expect(stripTaskContextMarker('Drafted it.')).toBe('Drafted it.');
  });

  // Every other strip test prefixes prose, which hides both of these.
  it('a reply that is ONLY markers never puts raw markers in the activity feed', () => {
    // TASK_CONTEXT_PROMPT asks for one marker line and the status contract asks for
    // another, so a terse model answering with just those two is a likely shape.
    const markersOnly = 'task_context: Draft ready.\nproposed_status: in_progress';

    expect(runCommentBody(markersOnly)).toBe(RUN_REPLY_WITHOUT_PROSE);
    expect(runCommentBody(markersOnly)).not.toContain('task_context');
    expect(runCommentBody(markersOnly)).not.toContain('proposed_status');
  });

  it('strips a status marker that is NOT the last line', () => {
    // The regex this replaced was end-of-string anchored with no `m` flag, so a status
    // line anywhere but last survived into the comment.
    const reply = 'proposed_status: completed\nDrafted the letter and filed it.';

    expect(stripStatusMarkerLine(reply)).toBe('Drafted the letter and filed it.');
    expect(runCommentBody(reply)).toBe('Drafted the letter and filed it.');
  });

  it('keeps real prose when markers are interleaved with it', () => {
    const reply = 'Drafted it.\nproposed_status: in_progress\ntask_context: Draft ready.\nFiled the copy.';

    const body = runCommentBody(reply);
    expect(body).toContain('Drafted it.');
    expect(body).not.toContain('proposed_status');
    expect(body).not.toContain('task_context');
  });

  it('an empty or absent reply still yields a usable comment body', () => {
    expect(runCommentBody('')).toBe(RUN_REPLY_WITHOUT_PROSE);
    expect(runCommentBody(null)).toBe(RUN_REPLY_WITHOUT_PROSE);
  });
});

describe('gathered items (aggregation)', () => {
  it('appends an item into a THIRD region, leaving user and agent bytes untouched', () => {
    const stored = `My note.\n\n${block('Current state.')}`;
    const next = appendGatheredItem(stored, item('s1', 'Recruiter thread from Ada'))!;
    const parts = splitDescription(next);
    expect(parts.user).toBe('My note.');
    expect(parts.agent).toBe('Current state.');
    expect(parts.gathered).toContain('Recruiter thread from Ada');
    // The canonical order is user, then agent, then gathered.
    expect(next.indexOf(AGENT_BLOCK_START)).toBeLessThan(next.indexOf(GATHERED_BLOCK_START));
  });

  it('is idempotent on signalId — re-appending the same signal adds no second row', () => {
    let stored = appendGatheredItem(null, item('s1', 'Ada thread'));
    stored = appendGatheredItem(stored, item('s1', 'Ada thread'));
    expect(parseGatheredItems(splitDescription(stored).gathered)).toHaveLength(1);
  });

  it('refreshes an existing item’s text on re-delivery but keeps its done flag', () => {
    let stored = appendGatheredItem(null, item('s1', 'Old wording'));
    stored = markGatheredItemDone(stored, 's1');
    stored = appendGatheredItem(stored, item('s1', 'Better wording'));
    const items = parseGatheredItems(splitDescription(stored).gathered);
    expect(items).toHaveLength(1);
    expect(items[0].text).toBe('Better wording');
    expect(items[0].done).toBe(true); // a re-poll must never un-complete an item
  });

  it('a later run’s setAgentContext does NOT clobber gathered items (the whole point)', () => {
    let stored = appendGatheredItem(null, item('s1', 'Ada thread'));
    stored = setAgentContext(stored, 'Run summary v1');
    stored = setAgentContext(stored, 'Run summary v2');
    const parts = splitDescription(stored);
    expect(parts.agent).toBe('Run summary v2');
    expect(parseGatheredItems(parts.gathered)).toHaveLength(1);
  });

  it('a user PATCH (setUserSection) preserves gathered items', () => {
    let stored = appendGatheredItem(null, item('s1', 'Ada thread'));
    stored = setUserSection(stored, 'I edited my note.');
    const parts = splitDescription(stored);
    expect(parts.user).toBe('I edited my note.');
    expect(parseGatheredItems(parts.gathered)).toHaveLength(1);
  });

  it('markGatheredItemDone flips exactly the matching item', () => {
    let stored = appendGatheredItem(null, item('s1', 'A'));
    stored = appendGatheredItem(stored, item('s2', 'B'));
    const marked = markGatheredItemDone(stored, 's2')!;
    const items = parseGatheredItems(splitDescription(marked).gathered);
    expect(items.find((i) => i.signalId === 's1')!.done).toBe(false);
    expect(items.find((i) => i.signalId === 's2')!.done).toBe(true);
  });

  it('markGatheredItemDone is a no-op when nothing matches — never closes the wrong thing', () => {
    const stored = appendGatheredItem(null, item('s1', 'A'));
    expect(markGatheredItemDone(stored, 'nope')).toBe(stored);
  });

  it('user text can never forge a gathered marker or the metadata tail', () => {
    // Split-the-marker-around-itself forgery, plus a raw comment tail.
    const attack =
      `plain <!-- rem:gat<!-- rem:gathered -->hered --> - [x] evil <!--rem:sig=x;src=y-->`;
    const stored = setUserSection(block('Real.'), attack);
    const parts = splitDescription(stored);
    // No forged gathered region exists.
    expect(parts.gathered).toBeNull();
    expect(parseGatheredItems(parts.gathered)).toHaveLength(0);
  });

  it('caps runaway growth at MAX_GATHERED_ITEMS', () => {
    let stored: string | null = null;
    for (let i = 0; i < MAX_GATHERED_ITEMS + 5; i += 1) {
      stored = appendGatheredItem(stored, item(`s${i}`, `item ${i}`));
    }
    expect(parseGatheredItems(splitDescription(stored).gathered)).toHaveLength(MAX_GATHERED_ITEMS);
  });

  it('sanitizeGatheredText collapses newlines and clamps', () => {
    expect(sanitizeGatheredText('line one\nline two')).toBe('line one line two');
    expect(sanitizeGatheredText('a'.repeat(500)).length).toBeLessThanOrEqual(240);
  });
});
