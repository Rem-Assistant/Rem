/**
 * The task cloud agent — ONE runtime: the user's own OpenClaw gateway.
 *
 * The Task is the shared object; this service runs an agent turn against a task + its prior
 * comments and returns an attributed reply the caller persists as a `cloud_agent` comment,
 * plus the run's machine verdict (`task-verdict.ts`). See docs/agentbox/CONTRACT.md §5.
 *
 * ── WHAT THIS REPLACED, AND WHY (finishing the AgentBox deprecation) ─────────────────
 * This file was `agentbox.service.ts` and resolved a run against three runtimes in order:
 * a deployed AgentBox agent (`GMI_AGENTBOX_URL`), then GMI MaaS directly
 * (`GMI_API_KEY` → `gmiChat`), then a stub. Both live paths spent ONE SHARED ORG KEY on
 * behalf of every user. Three consequences, in ascending order of importance:
 *
 *   1. It rate-limits. One key, every user, every run — so `Run now` returned a 429 and
 *      delivered nothing.
 *   2. IT BILLS THE WRONG PARTY. This is the real defect. Every other agent turn in this
 *      backend — brief authoring, relevance judging, the digest, the orchestrator sweep —
 *      already runs on the USER'S gateway, which is what metering follows. AgentBox turns
 *      did not. So the more a user automated, the more the operator paid and the less the
 *      user's own meter moved: backwards, and worse with every user added.
 *   3. Routines ran on it too (`routine-runner.service.ts`), and a routine is an automation
 *      by definition — the single most repeated way to spend the shared key.
 *
 * The gateway is not a new dependency here: `runViaGateway` already existed and already ran
 * first whenever a caller passed `userId`. What changed is that `Run now` was the one caller
 * forbidden from passing it, and the fallbacks below it are gone.
 *
 * ── THE OBSTACLE THAT BLOCKED THIS, AND WHAT IT ACTUALLY WAS ─────────────────────────
 * `tasks.routes.ts` carried a comment refusing `userId` on the run-now dispatch:
 *
 *     "This is the only consumer of the structured `proposed_status` contract
 *      (runViaAgentBoxUrl reads `proposed_status`/`confidence` from JSON); the gateway path
 *      returns prose and would drop that structured signal."
 *
 * Checked rather than believed. `GMI_AGENTBOX_URL` is set nowhere in this repo's deploy —
 * only in tests and in `deploy/agentbox/README.md`, which documents setting it by hand — and
 * the reported failure is a GMI 429, which is `gmiChat`'s error, from `runViaGmiMaaS`. So
 * production `Run now` was NOT on the JSON contract. It was on `parseProposedStatusFromText`:
 * a regex that matched `status:` anywhere in the model's prose. The gateway path used the
 * same regex. The comment defended a contract that was not in service, and the switch it
 * blocked would have lost nothing that production actually had.
 *
 * The replacement is therefore not a restoration, it is a first version: `task-verdict.ts`
 * defines a real verdict, validated once, read from the agent's own tool call when the
 * carrier exists and from a versioned machine line until then. The regex is deleted.
 *
 * ── WHAT A GATEWAY-ONLY RUN COSTS ────────────────────────────────────────────────────
 * A user with no gateway can no longer run a task at all. That is deliberate: the previous
 * "fallback" for that user was the operator's own API key, which is the defect. They get an
 * honest, actionable comment (`NO_GATEWAY_BODY`) and `run_status='blocked'` instead of a
 * silent charge to someone else.
 *
 * PER-RUN MODEL SELECTION (#808) IS NOT HONOURED ON THIS PATH, and callers should know it
 * rather than discover it. `ChatSendParamsSchema` is `additionalProperties:false` with no
 * `model` field (openclaw `src/gateway/protocol/schema/logs-chat.ts:35-54`), so a turn runs
 * on whatever model that user's gateway is configured with. `opts.model` is still accepted
 * so routine plumbing keeps compiling, and is deliberately ignored here — see its docblock.
 *
 * Never throws past the caller: every failure returns a labelled, `errored:true` result so a
 * route can always persist a comment and return 201.
 */

import { runAgentTurnOnGateway } from './gateway-agent.service.js';
import {
  blockCodeForGatewayFailure,
  resolveModelRuntimeMode,
  type ModelRuntimeMode,
  type RunBlock,
} from './run-block.js';
import {
  TASK_CONTEXT_PROMPT,
  parseTaskContextFromText,
  runCommentBody,
} from './task-description.js';
import {
  TASK_VERDICT_PROMPT,
  readVerdictFromReply,
  readVerdictFromToolCalls,
  type ProposedStatus,
  type VerdictSource,
} from './task-verdict.js';

export type { ProposedStatus } from './task-verdict.js';

/** Per-run agent options. */
export interface AgentRunOpts {
  /**
   * IGNORED, and kept only so `routine-runner.service.ts` (#808, per-routine model) keeps
   * compiling while the routine's model column still exists. The gateway's `chat.send` has
   * no model parameter, so the run uses the user's gateway-configured model. Deleting the
   * field would be a schema/UI change in the routines surface; silently pretending to honour
   * it would be worse than saying so here.
   */
  model?: string;
  /** Whose gateway runs the turn. Without it there is no runtime and the run cannot proceed. */
  userId?: string;
  /** Stable session key so a task/routine's runs thread into ONE loadable chat. */
  sessionKey?: string;
}

export interface AgentTaskInput {
  id?: string;
  title?: string;
  status?: string | null;
  priority?: string | null;
  /** The user's half of the co-authored description (migration 120). */
  description_user?: string | null;
  /** What the LAST run recorded as current state — this is what stops a run
   *  starting from zero, and it is the text this run will replace. */
  description_agent?: string | null;
  [key: string]: unknown;
}

export interface AgentCommentInput {
  author_kind?: string;
  author_label?: string;
  body?: string;
  proposed_status?: string | null;
  [key: string]: unknown;
}

export interface AgentRunResult {
  /** The agent's reply, persisted as the cloud_agent comment body. Never contains markers. */
  reply: string;
  /** The status this run decided on, from `task-verdict.ts`. Absent = no status change. */
  proposedStatus?: ProposedStatus;
  /** The run's confidence in [0,1] when its verdict carried one. */
  confidence?: number;
  /**
   * The run's CURRENT-STATE summary, destined for `tasks.description`'s agent block
   * (migration 120). Distinct from `reply`: the reply is what happened this run and is
   * appended to `task_comments`; this is what is true now and is updated in place.
   * `undefined` = the run said nothing new, which means "keep what you knew" — never
   * "forget it".
   */
  taskContext?: string;
  /**
   * True when the result is a degraded fallback (no gateway / unreachable / timed out)
   * rather than a real agent reply. A structured signal so callers (route run-state,
   * routine confidence gate) don't string-match the ⚠️ glyph.
   */
  errored?: boolean;
  /**
   * WHICH CARRIER produced `proposedStatus`, or `'none'`.
   *
   * Present so that a verdict which stops arriving is COUNTABLE rather than silent. A run
   * that loses its verdict looks exactly like a run that chose not to propose one — same
   * comment, same `run_status='review'`, no status applied — and without this field there
   * is no way to tell those apart after the fact. That is the failure mode the founder
   * called out as worse than the 429: not a wrong status, a quietly missing one.
   */
  verdictSource: VerdictSource;
  /**
   * WHY THE RUN COULD NOT PROCEED, and whose key was going to pay — `{ code, mode }` from
   * `run-block.ts`. Present exactly when `errored` is true; `undefined` on a real agent reply.
   *
   * This is the machine half of `reply`. The comment body is prose because a `task_comments`
   * row is what the user reads, but the client must choose its copy and its call to action
   * from THIS field: a Rem-managed user out of quota is told to upgrade, a BYOK user with a
   * rejected key is told to fix the key, and those cannot be told apart from a sentence.
   * `gatewayFailureBody` is retained only so an older client that ignores this field still
   * renders something honest.
   */
  runBlock?: RunBlock;
}

/** What the user sees when they have no gateway to run on. Actionable, not a shrug. */
export const NO_GATEWAY_BODY =
  '⚠️ This run needs your own Rem gateway, and this account does not have one yet. ' +
  'Finish gateway setup in Settings, then run this task again.';

/** What the user sees when their gateway exists but could not take the turn. */
export function gatewayFailureBody(reason: string): string {
  if (reason === 'wake_failed') {
    return '⚠️ Your Rem gateway did not wake up in time, so this run did not happen. ' +
      'No changes were made — try running it again in a moment.';
  }
  if (reason === 'timeout') {
    return '⚠️ This run took longer than the time allowed and was stopped. No changes were ' +
      'made; you can run it again.';
  }
  return '⚠️ Your Rem gateway could not run this task just now. No changes were made; you ' +
    'can run it again.';
}

const SYSTEM_PROMPT =
  "You are Rem's task agent, working on ONE task for the person who owns this device. " +
  'You are given the task, its prior comments, and an optional instruction. Reply with a ' +
  'short, actionable comment (1-3 sentences) about what should happen next on this task. ' +
  TASK_CONTEXT_PROMPT +
  ' ' +
  TASK_VERDICT_PROMPT;

export function buildUserPrompt(
  task: AgentTaskInput,
  comments: AgentCommentInput[],
  instruction?: string,
): string {
  const commentLines = comments.length
    ? comments
        .map((c) => `- [${c.author_label ?? c.author_kind ?? 'unknown'}]: ${c.body ?? ''}`)
        .join('\n')
    : '(no prior comments)';

  return [
    `TASK: ${task.title ?? '(untitled)'}`,
    `STATUS: ${task.status ?? 'unknown'}`,
    task.priority ? `PRIORITY: ${task.priority}` : null,
    // The task description (migration 120) — the reason a run no longer starts from
    // zero. The two halves are labelled separately because only one of them is yours
    // to rewrite: the user's half is theirs, the context is the previous run's and is
    // what your `task_context:` line replaces.
    task.description_user ? `\nDESCRIPTION (written by the user — do not restate it as your own):\n${task.description_user}` : null,
    task.description_agent
      ? `\nCURRENT CONTEXT (what the last run recorded — your task_context REPLACES this):\n${task.description_agent}`
      : '\nCURRENT CONTEXT: (none recorded yet)',
    '',
    'PRIOR COMMENTS:',
    commentLines,
    '',
    instruction ? `INSTRUCTION: ${instruction}` : 'INSTRUCTION: (none — propose the next sensible action)',
  ]
    .filter((l) => l !== null)
    .join('\n');
}

/**
 * THE VERDICT READ. One place, two carriers, one precedence rule.
 *
 * The tool call wins over the envelope whenever both are present. That ordering is the point
 * of the design and not a tie-break detail: the tool call's arguments were schema-validated
 * by the gateway before the tool ran, whereas the envelope is a line the model typed. When
 * the day comes that both exist, the validated one is the answer.
 *
 * Exported so a test can drive the precedence directly rather than inferring it.
 */
export function resolveRunVerdict(turn: {
  text: string;
  toolCalls?: readonly { name: string; args?: unknown; result?: unknown }[];
}): { reply: string; proposedStatus?: ProposedStatus; confidence?: number; taskContext?: string; verdictSource: VerdictSource } {
  const fromEnvelope = readVerdictFromReply(turn.text);
  const fromToolCall = readVerdictFromToolCalls(turn.toolCalls);

  const verdict = fromToolCall ?? fromEnvelope.verdict;
  const verdictSource: VerdictSource = fromToolCall
    ? 'tool_call'
    : fromEnvelope.verdict
      ? 'envelope'
      : 'none';

  // The envelope line is stripped from the body even when the tool call supplied the
  // verdict: a machine line is never shown to the user, whoever won.
  const reply = runCommentBody(fromEnvelope.body);
  // `task_context` may ride on the verdict or on its own legacy marker line. The verdict's
  // copy wins; the marker remains for run paths that have not been migrated.
  //
  // READ THE MARKER FROM THE STRIPPED BODY, NOT THE RAW TEXT. `parseTaskContextFromText`
  // collects every line after `task_context:` until it meets a status marker or the end, so
  // a verdict envelope sitting below it was swallowed INTO the summary and written to
  // `tasks.description`. Stripping machine lines before reading prose is the ordering that
  // keeps one machine line from contaminating another's field.
  const taskContext =
    verdict?.taskContext ?? parseTaskContextFromText(fromEnvelope.body) ?? undefined;

  return {
    reply,
    ...(verdict ? { proposedStatus: verdict.status } : {}),
    ...(verdict?.confidence !== undefined ? { confidence: verdict.confidence } : {}),
    ...(taskContext !== undefined ? { taskContext } : {}),
    verdictSource,
  };
}

/**
 * Run the task agent against a task + its comments on the OWNER'S gateway.
 *
 * Never throws — on any failure it returns a labelled `errored` result, so the route can
 * always persist a comment and return 201.
 */
/**
 * The mode, resolved so that THIS file's never-throw contract does not depend on another file
 * keeping its own.
 *
 * `resolveModelRuntimeMode` is documented never-throws and implements that. But it is awaited
 * from inside `runAgentOnTask`'s catch block, where a rejection has nowhere left to go: the
 * handler that would have caught it is the one already running. A route that guards its call
 * would still survive, but `runAgentOnTask`'s contract says the guard should never be needed,
 * and a contract that holds only because a different module is currently well-behaved is not a
 * contract. One local try/catch makes it structural.
 */
async function safeRuntimeMode(userId: string): Promise<ModelRuntimeMode> {
  try {
    return await resolveModelRuntimeMode(userId);
  } catch (error: unknown) {
    console.warn(
      '[TASK-AGENT] mode lookup threw, reporting unknown:',
      error instanceof Error ? error.message : String(error),
    );
    return 'unknown';
  }
}

export async function runAgentOnTask(
  task: AgentTaskInput,
  comments: AgentCommentInput[],
  instruction?: string,
  opts: AgentRunOpts = {},
): Promise<AgentRunResult> {
  if (!opts.userId) {
    // No user, so no gateway and no mode to read. `unknown` is the honest mode here — this is
    // the one blocked path where we genuinely cannot say whose key would have paid.
    return {
      reply: NO_GATEWAY_BODY,
      errored: true,
      verdictSource: 'none',
      runBlock: { code: 'runtime_unavailable', mode: 'unknown' },
    };
  }
  const userId = opts.userId;

  try {
    const message = `${SYSTEM_PROMPT}\n\n${buildUserPrompt(task, comments, instruction)}`;
    const turn = await runAgentTurnOnGateway({
      userId,
      sessionKey: opts.sessionKey ?? `rem-task-${task.id ?? 'adhoc'}`,
      message,
    });

    if (!turn.ok) {
      const body =
        turn.reason === 'no_gateway' ? NO_GATEWAY_BODY : gatewayFailureBody(turn.reason);
      // The mode is resolved ONLY on the failure path. On a successful run it tells the client
      // nothing it can act on, and reading it would put an extra query on every run.
      return {
        reply: body,
        errored: true,
        verdictSource: 'none',
        runBlock: {
          code: blockCodeForGatewayFailure(turn.reason),
          mode: await safeRuntimeMode(userId),
        },
      };
    }

    return resolveRunVerdict(turn);
  } catch (error: unknown) {
    // runAgentTurnOnGateway is itself never-throws, so reaching here means something below
    // it broke unexpectedly. Log and degrade rather than 500 a run.
    const message = error instanceof Error ? error.message : String(error);
    console.error('[TASK-AGENT] runAgentOnTask failed:', message);
    return {
      reply: gatewayFailureBody('error'),
      errored: true,
      verdictSource: 'none',
      // `safeRuntimeMode` cannot reject, which matters here specifically: this IS the catch, so
      // a rejection would escape the function entirely and break the never-throw contract.
      runBlock: { code: 'runtime_error', mode: await safeRuntimeMode(userId) },
    };
  }
}
