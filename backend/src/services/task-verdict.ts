/**
 * THE RUN VERDICT CONTRACT — how a task run's machine decision reaches the backend.
 *
 * A task run produces two different things and they must not be confused:
 *
 *   PROSE     what happened this run. The user reads it. Persisted as a `task_comments` row.
 *   VERDICT   what the run DECIDED. The backend acts on it: it applies `tasks.status`,
 *             stamps `previous_status` for Undo, and picks the terminal `run_status`
 *             (done / review / blocked). Nobody reads it; it is machine input.
 *
 * This module owns the verdict. It is the ONLY place a verdict is read out of a run, and
 * `TaskVerdict` is the only shape the rest of the pipeline sees.
 *
 * ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────────────
 * `tasks.routes.ts` used to carry a comment forbidding the run-now dispatch from moving to
 * the user's gateway, on the grounds that the AgentBox JSON path was "the only consumer of
 * the structured proposed_status contract". Two facts about that:
 *
 *   1. That structured path (`GMI_AGENTBOX_URL` → `{ body, proposed_status, confidence }`)
 *      is not configured in this repo's deploy. Nothing outside tests and
 *      `deploy/agentbox/README.md` sets the variable, and the failure the founder sees is a
 *      GMI 429 — i.e. production has been running `runViaGmiMaaS`, whose status signal was
 *      `parseProposedStatusFromText`: a regex over the model's prose. The contract the
 *      comment defended was not the one in use.
 *   2. The regex was the actual contract, on BOTH the GMI path and the gateway path, and
 *      on the autonomous sweep. It matched `status:` anywhere in free prose, so a sentence
 *      like "the status: pending question is still open" was a status decision.
 *
 * So the replacement is not "recover a structured field we lost" — there was no structured
 * field upstream to find. It is "CREATE the structured field, at the one boundary we own,
 * and make every consumer read the field instead of the prose". That is what principle 5
 * asks for once you notice the signal has no upstream structured form:
 * `docs/rebuild/19-TASKS-VS-WORKBOARD.md`, CLAUDE.md "Structured signals over string parsing".
 *
 * ── UPSTREAM PATTERN MIRRORED (principle 1) ──────────────────────────────────────────
 * OpenClaw already solves "an agent hands its orchestrator a typed verdict about a run":
 * the heartbeat tool. Pinned runtime `/Volumes/SatechiSSD/rem-wt/oc-fb3a259`:
 *
 *   - `src/agents/tools/heartbeat-response-tool.ts` — a TypeBox-schema'd tool
 *     (`heartbeat_respond`) whose ARGUMENTS are the verdict: an `outcome` string-enum, a
 *     `summary`, an optional `priority`. The tool's whole job is to be called.
 *   - `src/auto-reply/heartbeat-tool-response.ts:60` — `normalizeHeartbeatToolResponse`,
 *     one normalizer, enum-checked, returning `undefined` rather than guessing.
 *   - `src/agents/pi-embedded-subscribe.handlers.tools.ts:998` — the orchestrator reads the
 *     verdict from the TOOL RESULT, keyed on the tool name. It never reads the model's prose.
 *
 * `TaskVerdict` is the same shape and `normalizeTaskVerdict` is the same discipline: one
 * normalizer, enum-checked, `undefined` on anything it does not recognise.
 *
 * ── THE TWO CARRIERS ─────────────────────────────────────────────────────────────────
 * The verdict is the same typed object either way; only the carrier differs.
 *
 *   `tool_call`  PRIMARY. The agent invokes a `rem_task_report` tool and the gateway
 *                delivers its arguments to us as a structured `agent`/`stream:"tool"` event
 *                (`gateway-agent.service.ts` `ObservedToolCall`). Schema-validated by the
 *                gateway before we ever see it — a real typed round trip, exactly the shape
 *                a node command has.
 *
 *                ⚠️ NOT LIVE ON THE DEPLOYED FLEET YET, AND THIS FILE DOES NOT PRETEND IT
 *                IS. No `rem_task_report` tool exists on the pinned gateway image: a hook
 *                cannot register a tool (the hosted gateway's bootstrap hook, operated
 *                separately, is `agent:bootstrap` prompt injection only), so the tool has to arrive as
 *                either a node command served by a node the backend controls, or an MCP
 *                tool wired the way `ensureComposioMcpWired` wires Composio's. Both are
 *                fleet operations with their own release step — see the PR body. The reader
 *                ships now so that landing the tool is a config change, not a code change,
 *                and so the path is under test before it carries traffic.
 *
 *   `envelope`   TRANSITIONAL, and what actually carries the verdict today. One line the
 *                model emits, `<id> <json>`, extracted and REMOVED before the prose is
 *                persisted. Versioned, strictly validated, and fail-closed.
 *
 * ── FAIL-CLOSED, AND WHY THAT IS THE SAFE DIRECTION ──────────────────────────────────
 * Every reader here returns `undefined` rather than a guess. A run with no readable verdict
 * is `verdictSource:'none'`, which means: persist the comment, apply NO status change, land
 * `run_status='review'`. That is the same outcome a run has always had when the model chose
 * not to propose anything — the user sees Rem's reply and the task is untouched. So the
 * failure mode of this contract is "Rem commented and proposed nothing", never "Rem moved
 * your task to the wrong status". `verdictSource` is returned to the caller precisely so a
 * verdict that stops arriving is COUNTABLE rather than silent.
 *
 * Deliberately NOT here: any regex over prose. `parseProposedStatusFromText` is deleted.
 */

/** The statuses a run may decide on. Mirrors the `proposed_status` column's domain. */
export type ProposedStatus = 'pending' | 'in_progress' | 'completed' | 'blocked';

const ALLOWED_STATUS: ReadonlySet<string> = new Set<ProposedStatus>([
  'pending',
  'in_progress',
  'completed',
  // 'blocked' — the agent cannot proceed (needs info / waiting on an input). A real
  // proposal the agent emits, not an error: it is the right status when the agent says
  // e.g. "I need the filing details before I can continue".
  'blocked',
]);

/**
 * The tool name the agent calls to report a verdict, once such a tool exists on the
 * gateway. Named for the agent's tool namespace (`heartbeat_respond`, `update_plan`,
 * `session_status` are all snake_case in `src/agents/tools/`).
 */
export const TASK_VERDICT_TOOL_NAME = 'rem_task_report';

/**
 * Aliases accepted for the same verdict tool. A node command carrying this verdict would be
 * dotted (`task.report`, mirroring `calendar.add` / `device.status`), and the gateway names
 * a node invocation by its command id — so accept both spellings rather than let the
 * carrier's naming convention decide whether a verdict is read.
 */
const TASK_VERDICT_TOOL_ALIASES: ReadonlySet<string> = new Set([
  TASK_VERDICT_TOOL_NAME,
  'rem.task.report',
  'task.report',
]);

/**
 * The envelope's schema id. VERSIONED ON PURPOSE: a future change to the verdict's shape
 * bumps this to `.v2`, and a v1 reader then declines a v2 envelope instead of
 * half-understanding it. An unversioned marker cannot do that — which is exactly how
 * `proposed_status:` ended up meaning different things on three different paths.
 */
export const TASK_VERDICT_ENVELOPE_ID = 'rem.task_verdict.v1';

/** Cap on the free-text half of a verdict, matching `MAX_AGENT_CONTEXT_CHARS`. */
const MAX_TASK_CONTEXT_CHARS = 4000;

/** A run's machine decision. Every field is validated; nothing here is raw model output. */
export interface TaskVerdict {
  /** The status the run decided on. Always one of the four; never a free string. */
  status: ProposedStatus;
  /** The run's own confidence in [0,1], when the carrier reported one. */
  confidence?: number;
  /**
   * The run's CURRENT-STATE summary for `tasks.description`'s agent block (migration 120).
   * Optional here: the legacy `task_context:` marker still carries it on paths that have
   * not moved, and `undefined` means "no news", never "clear it".
   */
  taskContext?: string;
}

/** Which carrier produced the verdict. `'none'` makes a missing verdict countable. */
export type VerdictSource = 'tool_call' | 'envelope' | 'none';

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Read `key`, then its snake/camel twin, so a carrier's casing never loses a field. */
function readField(source: Record<string, unknown>, ...keys: string[]): unknown {
  for (const key of keys) {
    if (source[key] !== undefined) return source[key];
  }
  return undefined;
}

function normalizeStatus(value: unknown): ProposedStatus | undefined {
  if (typeof value !== 'string') return undefined;
  const v = value.trim().toLowerCase().replace(/[\s-]+/g, '_');
  return ALLOWED_STATUS.has(v) ? (v as ProposedStatus) : undefined;
}

/** Clamp a confidence to [0,1]; `undefined` when it is not a finite number. */
function normalizeConfidence(value: unknown): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value)) return undefined;
  return Math.min(1, Math.max(0, value));
}

function normalizeTaskContext(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, MAX_TASK_CONTEXT_CHARS) : undefined;
}

/**
 * THE ONE NORMALIZER. Both carriers funnel through this, so a verdict read from a tool call
 * and a verdict read from an envelope cannot diverge in what they accept.
 *
 * Mirrors `normalizeHeartbeatToolResponse` (`src/auto-reply/heartbeat-tool-response.ts:60`):
 * an unrecognised value is `undefined`, never a default and never a partial object. In
 * particular a payload with a `confidence` but no valid `status` yields NOTHING — a
 * confidence with no decision attached is not half a verdict, it is noise.
 */
export function normalizeTaskVerdict(value: unknown): TaskVerdict | undefined {
  if (!isRecord(value)) return undefined;
  const status = normalizeStatus(readField(value, 'status', 'proposed_status', 'proposedStatus'));
  if (!status) return undefined;
  const confidence = normalizeConfidence(readField(value, 'confidence'));
  const taskContext = normalizeTaskContext(readField(value, 'task_context', 'taskContext'));
  return {
    status,
    ...(confidence !== undefined ? { confidence } : {}),
    ...(taskContext !== undefined ? { taskContext } : {}),
  };
}

/** A tool invocation observed on the run's gateway event stream. */
export interface ObservedToolCallLike {
  name: string;
  args?: unknown;
  result?: unknown;
}

/**
 * PRIMARY READER — the verdict as the agent's own tool call.
 *
 * Reads the LAST matching call, so an agent that reports, keeps working, then re-reports
 * lands on its final decision rather than its first. `args` first (what the model decided),
 * falling back to `result` (what the tool echoed back) so a carrier that only surfaces the
 * result — a node invoke reply, for instance — still round-trips.
 */
export function readVerdictFromToolCalls(
  calls: readonly ObservedToolCallLike[] | undefined,
): TaskVerdict | undefined {
  if (!calls?.length) return undefined;
  for (let i = calls.length - 1; i >= 0; i -= 1) {
    const call = calls[i];
    if (typeof call?.name !== 'string') continue;
    if (!TASK_VERDICT_TOOL_ALIASES.has(call.name.trim().toLowerCase())) continue;
    const verdict = normalizeTaskVerdict(call.args) ?? normalizeTaskVerdict(call.result);
    if (verdict) return verdict;
  }
  return undefined;
}

/**
 * Matches an envelope line: the schema id at the start of a line, then the JSON object.
 *
 * Line-anchored with `m`, not `$`-anchored on the whole string — the bug
 * `stripStatusMarkerLine` was written to fix was exactly a marker regex that only matched
 * when the marker happened to land on the last line.
 *
 * Leading AND trailing markdown decoration is tolerated because models wrap machine lines in
 * markdown unprompted (a backticked line is the common one). The capture is greedy to the
 * LAST `}` on the line, which both keeps nested objects intact and leaves any trailing
 * backtick/asterisk outside the JSON — matching to end-of-line instead fed that decoration
 * to `JSON.parse` and silently dropped the verdict.
 */
const ENVELOPE_LINE = new RegExp(
  `^[\\s>*_\`#-]*${TASK_VERDICT_ENVELOPE_ID.replace(/\./g, '\\.')}\\s*(\\{.*\\})`,
  'gim',
);

/** Same match, used only to decide whether a line is a machine line worth removing. */
const ENVELOPE_LINE_ANY = new RegExp(
  `^[\\s>*_\`#-]*${TASK_VERDICT_ENVELOPE_ID.replace(/\./g, '\\.')}\\b`,
  'i',
);

/** A run's reply split into the prose the user reads and the verdict the backend acts on. */
export interface ReplyVerdictRead {
  /** The verdict, or `undefined` when the reply carried none that validates. */
  verdict?: TaskVerdict;
  /** The reply with every envelope line removed. Never contains the machine line. */
  body: string;
}

/**
 * TRANSITIONAL READER — the verdict as one machine line in the reply.
 *
 * Strict on purpose, in all three directions:
 *   - the line must start with the VERSIONED id, so a v2 envelope is not read by a v1 reader;
 *   - the remainder must `JSON.parse` to an object — no "find the first {", no brace
 *     balancing, no repair of nearly-JSON;
 *   - the object must normalize, and a payload whose `status` is not one of the four yields
 *     NO verdict rather than a partial one.
 *
 * The LAST valid envelope wins, matching `readVerdictFromToolCalls`. EVERY envelope line is
 * stripped from `body` regardless of whether any of them parsed — a malformed machine line
 * is still a machine line, and it must not reach the activity feed. That is the failure the
 * `RUN_REPLY_WITHOUT_PROSE` fallback in `task-description.ts` was added for.
 */
export function readVerdictFromReply(text: string | null | undefined): ReplyVerdictRead {
  if (typeof text !== 'string' || !text) return { body: '' };

  let verdict: TaskVerdict | undefined;
  ENVELOPE_LINE.lastIndex = 0;
  for (const match of text.matchAll(ENVELOPE_LINE)) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(match[1].trim());
    } catch {
      continue;
    }
    const candidate = normalizeTaskVerdict(parsed);
    if (candidate) verdict = candidate;
  }

  // Strip on the LOOSER match: a machine line that failed to parse is still a machine line,
  // and letting a malformed one through to the activity feed is the failure
  // `RUN_REPLY_WITHOUT_PROSE` exists to catch.
  const body = text
    .split('\n')
    .filter((line) => !ENVELOPE_LINE_ANY.test(line))
    .join('\n')
    .trim();

  return { ...(verdict ? { verdict } : {}), body };
}

/**
 * The instruction fragment that asks for a verdict. ONE definition, shared by the manual run
 * and the autonomous sweep, so the two run paths cannot drift into asking for different
 * shapes — the drift that let `proposed_status:` mean three things at once.
 *
 * It names both carriers because the model may or may not have the tool: with the tool it is
 * a schema-validated call, without it the envelope line. Asking for both is not redundancy,
 * it is what makes landing the tool a no-op for this prompt.
 */
export const TASK_VERDICT_PROMPT =
  'When — and only when — you are confident this task\'s status should change, report it as a ' +
  `MACHINE VERDICT. If you have a \`${TASK_VERDICT_TOOL_NAME}\` tool, call it. Otherwise end ` +
  `your reply with one line, exactly: \`${TASK_VERDICT_ENVELOPE_ID} {"status":"<value>"}\`, ` +
  'where <value> is exactly one of pending, in_progress, completed, or blocked, optionally ' +
  'with a "confidence" between 0 and 1. Use "blocked" when you cannot make progress because ' +
  'you are missing information or are waiting on an input the user must provide. Omit the ' +
  'verdict entirely if you are not proposing a status change — a wrong verdict is worse than ' +
  'none. The verdict line is machine-read and removed before anyone sees your reply, so do ' +
  'not explain it and do not repeat its contents in your prose.';
