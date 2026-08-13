/**
 * `tasks.description` — the co-authored "what I know NOW" surface (migration 120).
 *
 * THE PURE HALF: the markers, the split/merge, and the run→description reply contract.
 * No database import, so the prompt-building services can depend on it without dragging a
 * connection pool — and a `DATABASE_URL` requirement — into their tests. The writers that
 * touch Postgres live in `task-description.service.ts`, which re-exports everything here.
 *
 * docs/product/DECISIONS.md, "Task description vs comments vs chat":
 *   tasks.description  current state, updated in place   <- this file
 *   task_comments      append-only log of each run       (already exists)
 *   chat               the conversation                  (session_id)
 *
 * THE CLOBBER PROBLEM. Both the user and the agent write here. `task_comments` is
 * append-only and therefore safe; `description` is not. DECISIONS.md states the
 * constraint directly: "if the agent maintains it, user-authored text must not be
 * silently overwritten."
 *
 * THE MECHANISM: an agent-managed block delimiter. One column, stored as
 *
 *     <user's text>
 *
 *     <!-- rem:agent-context -->
 *     <the agent's current-state summary>
 *     <!-- /rem:agent-context -->
 *
 * and TWO one-sided writers, neither of which can touch the other's half:
 *
 *   setAgentContext(stored, text)  rewrites the block   , preserves the user's text
 *   setUserSection(stored, text)   rewrites user's text , preserves the block
 *
 * WHY A DELIMITER RATHER THAN THE ALTERNATIVES.
 *   - Two columns (`description` + `agent_context`) is the same idea with stronger
 *     enforcement, but it splits one product noun in two: DECISIONS.md's model is a
 *     single description that reads as one thing ("keeping things thin"), and every
 *     consumer that wants the whole picture would have to concatenate them anyway.
 *   - Last-writer-wins-with-the-user-winning (a `description_updated_by` flag, agent may
 *     only write if it wrote last) is simpler, but it freezes the agent out permanently
 *     the moment the user types one character — which brings back exactly the "every run
 *     starts from zero" failure this column exists to fix. The two authors have to be
 *     able to coexist indefinitely, not take turns.
 *
 * WHAT THE DELIMITER COSTS, AND HOW IT IS PAID.
 *   - A user could paste the marker text and forge/destroy a block. `setUserSection`
 *     strips every marker literal out of user input first, so user text is data, never
 *     structure. The strip iterates to a FIXED POINT — a single pass is bypassable by
 *     splitting the marker around itself, which forges a live one (see
 *     `stripAgentBlockMarkers`). This is the prompt-injection boundary: a task
 *     description is untrusted text that later goes into a model prompt, and on the
 *     autonomous sweep it is also screened by the deny list before any turn runs.
 *   - A hand-edited or legacy row might hold zero, two, or an unterminated block.
 *     `splitDescription` tolerates all of those — it lifts out EVERY block, joins the
 *     remainder as the user's text, and the next write re-emits the canonical form.
 */

export const AGENT_BLOCK_START = '<!-- rem:agent-context -->';
export const AGENT_BLOCK_END = '<!-- /rem:agent-context -->';

/**
 * Upper bound on the user's half. A description is a working note, not a document; the
 * cap exists so one task cannot grow without limit and so the text that lands in a model
 * prompt stays bounded. Exceeding it is a 400 (an honest rejection the client can show)
 * rather than a silent truncation of something the user typed.
 */
export const MAX_USER_DESCRIPTION_CHARS = 8000;

/**
 * Upper bound on the agent's half. Model output IS truncated rather than rejected —
 * failing a completed run because its summary ran long would throw away real work.
 */
export const MAX_AGENT_CONTEXT_CHARS = 4000;

export interface DescriptionParts {
  /** The user's own text, with the agent block lifted out. Null when empty. */
  user: string | null;
  /** The agent's current-state summary from inside the block. Null when absent. */
  agent: string | null;
}

/** Trim, and treat an all-whitespace value as absent rather than as an empty string. */
export function blankToNull(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

/**
 * Split a stored description into its two halves.
 *
 * Tolerant by design — it is the only reader, so it has to cope with whatever is actually
 * in the column: no block, one block, several blocks (a legacy or hand-edited row), or a
 * start marker with no end (a truncated write). Every block found is lifted out and joined
 * as the agent's half; everything else is the user's half, in order.
 */
export function splitDescription(stored: string | null | undefined): DescriptionParts {
  if (typeof stored !== 'string' || stored.trim().length === 0) {
    return { user: null, agent: null };
  }

  const userParts: string[] = [];
  const agentParts: string[] = [];
  let cursor = 0;

  for (;;) {
    const start = stored.indexOf(AGENT_BLOCK_START, cursor);
    if (start === -1) {
      userParts.push(stored.slice(cursor));
      break;
    }
    userParts.push(stored.slice(cursor, start));

    const bodyStart = start + AGENT_BLOCK_START.length;
    const end = stored.indexOf(AGENT_BLOCK_END, bodyStart);
    if (end === -1) {
      // Unterminated block (a truncated or hand-edited row): everything after the start
      // marker is the agent's, so we never re-emit a dangling marker.
      agentParts.push(stored.slice(bodyStart));
      cursor = stored.length;
      break;
    }
    agentParts.push(stored.slice(bodyStart, end));
    cursor = end + AGENT_BLOCK_END.length;
  }

  const user = userParts
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .join('\n\n');
  const agent = agentParts
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .join('\n\n');

  return { user: blankToNull(user), agent: blankToNull(agent) };
}

/** Re-emit the canonical stored form from the two halves. Null when both are empty. */
export function composeDescription(
  user: string | null | undefined,
  agent: string | null | undefined,
): string | null {
  const u = blankToNull(user);
  const a = blankToNull(agent);
  if (!u && !a) return null;
  if (!a) return u;
  const block = `${AGENT_BLOCK_START}\n${a}\n${AGENT_BLOCK_END}`;
  return u ? `${u}\n\n${block}` : block;
}

/**
 * Remove the block markers from text so user input can never forge, nest, or truncate an
 * agent block. The surrounding words are kept — the user typed them.
 *
 * ITERATES TO A FIXED POINT, and that is the whole point. A single pass is BYPASSABLE by
 * splitting the marker around itself:
 *
 *     '<!-- rem:agent-' + AGENT_BLOCK_START + 'context -->'
 *
 * One pass deletes the inner marker, the two outer fragments close up, and the result IS
 * a live marker. The user has then forged an agent block: `splitDescription` reclassifies
 * everything after it as AGENT text, so the next run's `setAgentContext` replaces it and
 * the user's own words are destroyed. (A description consisting of nothing but the forged
 * marker reads back as `{user: null, agent: null}` — the field silently empties.)
 *
 * THE LOOP IS UNBOUNDED, AND IT HAS TO BE. An earlier version capped it at 100 passes and
 * called the cap "belt-and-braces". It was not: nesting costs ~26 bytes and exactly ONE
 * pass per level, so an attacker buys a level for a handful of characters and the only
 * real ceiling is `MAX_USER_DESCRIPTION_CHARS`. Depth 201 fits in ~5.2k of the 8k budget
 * and defeated the 200 effective passes on the PATCH path (it strips twice); the agent
 * path strips once, so depth 101 was enough there. A capped loop is a single-pass bug with
 * extra steps — it just moves the price of the bypass, it does not remove it. The length
 * guard does not help either: it runs BEFORE the strip, on the un-stripped text.
 *
 * Termination is guaranteed by the shape of the operation, not by a counter: every pass
 * that changes the string strictly SHORTENS it (removal only), and we stop the moment a
 * pass is a no-op. So the worst case is bounded by the input length, which the route has
 * already capped.
 */
export function stripAgentBlockMarkers(text: string): string {
  let current = text;
  for (;;) {
    const next = current.split(AGENT_BLOCK_START).join('').split(AGENT_BLOCK_END).join('');
    if (next === current) return current;
    current = next;
  }
}

/**
 * THE AGENT'S WRITE. Replaces the agent block; the user's text survives byte-for-byte.
 * Passing null/blank REMOVES the block (used by tests and any future explicit clear) —
 * callers wiring a run must not pass a blank on "the model said nothing", because no news
 * means "keep what you knew", not "forget everything". `writeAgentTaskContext` enforces
 * that at the DB boundary.
 */
export function setAgentContext(
  stored: string | null | undefined,
  agentContext: string | null | undefined,
): string | null {
  const { user } = splitDescription(stored);
  const agent = blankToNull(agentContext)?.slice(0, MAX_AGENT_CONTEXT_CHARS) ?? null;
  return composeDescription(user, stripAgentBlockMarkers(agent ?? '') || null);
}

/**
 * THE USER'S WRITE. Replaces the user's text; the agent block survives byte-for-byte.
 * Passing null/blank clears the user's half only — a user emptying the field does not
 * erase what Rem knows.
 */
export function setUserSection(
  stored: string | null | undefined,
  userText: string | null | undefined,
): string | null {
  const { agent } = splitDescription(stored);
  const user = blankToNull(userText);
  return composeDescription(user ? blankToNull(stripAgentBlockMarkers(user)) : null, agent);
}

// ---------------------------------------------------------------------------
// The run → description contract
// ---------------------------------------------------------------------------

/**
 * The marker an agent reply uses to hand back its current-state summary. Same shape as
 * the existing `proposed_status:` marker the rest of the pipeline already parses
 * (principle 5 — a controlled machine marker, not free-prose scraping).
 */
export const TASK_CONTEXT_MARKER = 'task_context';

/**
 * Prompt fragment shared by every run path, so the manual run and the autonomous sweep
 * cannot drift into asking for different shapes.
 */
export const TASK_CONTEXT_PROMPT =
  'Before any status line, write a line starting `task_context:` followed by the ' +
  "CURRENT STATE of this task in 1-3 sentences: what is now known or done, and what is " +
  'still needed or blocking. Write it for the next run to read cold — it REPLACES the ' +
  'previous task_context, so restate anything still true rather than referring back to ' +
  'it. State facts only; do not include your reasoning or a greeting.';

const CONTEXT_LINE = /^[\s>*_#-]*task[_\s-]?context\s*[:=]\s*/i;
const STATUS_LINE = /^[\s>*_#-]*(?:proposed[_\s-]?status|status)\s*[:=]/i;

/**
 * Pull the agent's current-state summary out of a reply.
 *
 * Reads from the `task_context:` line up to the `proposed_status:` line (or the end), so
 * the summary may run to a few lines while the status marker stays parseable by the
 * existing single-line regexes. Returns null when the model did not emit one — which
 * callers must treat as "no news", never as "clear it".
 */
export function parseTaskContextFromText(text: string | null | undefined): string | null {
  if (typeof text !== 'string' || !text) return null;
  const lines = text.split('\n');
  const startIdx = lines.findIndex((line) => CONTEXT_LINE.test(line));
  if (startIdx === -1) return null;

  const collected: string[] = [lines[startIdx].replace(CONTEXT_LINE, '')];
  for (let i = startIdx + 1; i < lines.length; i += 1) {
    if (STATUS_LINE.test(lines[i]) || CONTEXT_LINE.test(lines[i])) break;
    collected.push(lines[i]);
  }
  const body = blankToNull(collected.join('\n'));
  return body ? body.slice(0, MAX_AGENT_CONTEXT_CHARS) : null;
}

/**
 * Remove the `task_context:` region from a reply so the persisted comment body reads as
 * prose. The comment says what happened this run; the description says what is true now —
 * repeating the machine marker in the activity feed would blur the two.
 */
export function stripTaskContextMarker(text: string | null | undefined): string {
  if (typeof text !== 'string' || !text) return '';
  const lines = text.split('\n');
  const startIdx = lines.findIndex((line) => CONTEXT_LINE.test(line));
  if (startIdx === -1) return text;

  let endIdx = lines.length;
  for (let i = startIdx + 1; i < lines.length; i += 1) {
    if (STATUS_LINE.test(lines[i]) || CONTEXT_LINE.test(lines[i])) {
      endIdx = i;
      break;
    }
  }
  return [...lines.slice(0, startIdx), ...lines.slice(endIdx)].join('\n').trim();
}

/**
 * Remove any `proposed_status:` MARKER LINE from a reply.
 *
 * Line-anchored on purpose. The regex this replaces (`/\n?\s*(?:proposed[_\s-]?status|
 * status)\s*[:=].*$/i`) had no `m` flag, so `$` meant end-of-STRING and it only matched
 * when the status marker happened to be the last line. A model that put it anywhere else —
 * which nothing prevents — left the raw marker sitting in the activity feed. Every call
 * site used a copy of that same regex, so the bug was in three places at once.
 */
export function stripStatusMarkerLine(text: string | null | undefined): string {
  if (typeof text !== 'string' || !text) return '';
  return text
    .split('\n')
    .filter((line) => !STATUS_LINE.test(line))
    .join('\n')
    .trim();
}

/**
 * What to show in the activity feed when a run's reply was NOTHING BUT machine markers.
 *
 * `TASK_CONTEXT_PROMPT` asks for a `task_context:` line and the status contract asks for a
 * `proposed_status:` line, so a terse model answering with only those two is a likely
 * shape, not an exotic one. Stripping both then leaves an empty string — and the previous
 * `stripped || rawText` fallback put the RAW MARKERS back into the feed the founder reads.
 * Falling back to a plain sentence keeps the two surfaces distinct: the comment says a run
 * happened, the description holds what it learned.
 */
export const RUN_REPLY_WITHOUT_PROSE = 'Rem updated what it knows about this task.';

/**
 * The comment body for a run: the model's prose with both machine markers removed, or an
 * honest placeholder when the reply carried no prose at all. Never returns marker text,
 * and never returns an empty body.
 */
export function runCommentBody(text: string | null | undefined): string {
  const prose = stripStatusMarkerLine(stripTaskContextMarker(text));
  return prose || RUN_REPLY_WITHOUT_PROSE;
}
