/**
 * The task cloud agent — product behavior above Rem's runtime boundary.
 *
 * The Task is the shared object; this service runs an agent turn against a task + its prior
 * comments and returns an attributed reply the caller persists as a `cloud_agent` comment,
 * plus the run's machine verdict (`task-verdict.ts`). See docs/agentbox/CONTRACT.md §5.
 *
 * Rem-managed task turns execute directly on the durable Rem shared runtime. They are deliberately
 * side-effect-free: the model may return a schema-validated task-report tool call; callers
 * own every task/comment mutation. That preserves the existing product behavior without
 * granting the model external capabilities or requiring a personal OpenClaw gateway. Proven
 * BYOK accounts temporarily retain their credential-owning gateway as a compatibility fallback.
 *
 * Per-run model selection, tenant identity, idempotency, quota ownership, cancellation,
 * persistence, and execution provenance all travel through the Rem runtime contract.
 *
 * Never throws past the caller: every failure returns a labelled, `errored:true` result so a
 * route can always persist a comment and return 201.
 */

import type {
  AgentRuntimeProvenance,
  RuntimeAuthority,
  RuntimeToolPolicy,
} from '../runtime/agent-runtime.js';
import {
  runAgentTurn,
  runAgentTurnOnSharedRuntime,
} from '../runtime/agent-runtime.service.js';
import {
  blockCodeForRuntimeFailure,
  type RunBlock,
} from './run-block.js';
import {
  TASK_CONTEXT_PROMPT,
  parseTaskContextFromText,
  runCommentBody,
} from './task-description.js';
import {
  TASK_VERDICT_PROMPT,
  TASK_VERDICT_TOOL_NAME,
  readVerdictFromReply,
  readVerdictFromToolCalls,
  readTaskVerdictToolCall,
  type ProposedStatus,
  type VerdictSource,
} from './task-verdict.js';

export type { ProposedStatus } from './task-verdict.js';

/** Per-run agent options. */
interface AgentRunSharedOpts {
  /**
   * Passed to the Rem runtime contract.
   */
  model?: string;
  /** Stable session key so a task/routine's runs thread into ONE loadable chat. */
  sessionKey?: string;
  /** Transitional escape hatch only for flows already authorized to act. */
  allowLegacyByokFallback?: boolean;
  /** Separate recovery namespace; legacy gateway turns must never write canonical Rem sessions. */
  legacyByokFallbackSessionKey?: string;
  /** Transitional callers that still require tools route directly to their existing adapter. */
  toolPolicy?: RuntimeToolPolicy;
}

export type AgentRunOpts = AgentRunSharedOpts & (
  | { userId?: undefined; authority?: never; idempotencyKey?: never; toolPolicy?: never }
  | {
      /** Authenticated owner used for tenant routing. */
      userId: string;
      /** Authority established by the caller, never inferred or minted here. */
      authority: RuntimeAuthority;
      /** Stable id of this logical dispatch. */
      idempotencyKey: string;
    }
);

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
   * True when the result is a degraded fallback (unavailable / cancelled / timed out)
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
   * `runtimeFailureBody` is retained so an older client that ignores this field still
   * renders something honest.
   */
  runBlock?: RunBlock;
  /** Runtime evidence returned by the implementation that actually handled the turn. */
  runtime?: AgentRuntimeProvenance;
  /** Exact Rem-runtime reporting call that proposed the status this route may apply. */
  taskUpdateProposal?: {
    runtimeRunId: string;
    toolCallId: string;
  };
}

/** What the user sees when no runtime can be selected for the account. */
export const NO_RUNTIME_BODY =
  '⚠️ Rem is not ready to run this task for this account yet. Try again after setup finishes.';

/** Transitional source compatibility for callers that still use the old symbol. */
export const NO_GATEWAY_BODY = NO_RUNTIME_BODY;

/** What the user sees when the selected runtime could not take the turn. */
export function runtimeFailureBody(reason: string): string {
  if (reason === 'quota_exhausted') {
    return '⚠️ You have used the model requests included in your current plan. Upgrade or wait for your allowance to reset, then run this task again.';
  }
  if (reason === 'credential_rejected') {
    return '⚠️ Rem’s model provider credential is temporarily unavailable, so this run did not happen. No changes were made — try again later.';
  }
  if (reason === 'startup_failed') {
    return '⚠️ Rem could not become ready in time, so this run did not happen. ' +
      'No changes were made — try again in a moment.';
  }
  if (reason === 'timeout') {
    return '⚠️ This run took longer than allowed and Rem confirmed it was stopped. You can run it again.';
  }
  if (reason === 'cancelled') return '⚠️ This run was cancelled before it completed.';
  return '⚠️ Rem could not confirm how this run ended. Check the task before trying again.';
}

/** Transitional source compatibility for routes not yet migrated to the runtime vocabulary. */
export const gatewayFailureBody = runtimeFailureBody;

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
 * by a tool-capable runtime before the tool ran, whereas the envelope is a line the model typed. When
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
  // A schema-validated report carries the activity-feed explanation itself. This also keeps
  // tool-only completions actionable; legacy status-only tool carriers retain their prose path.
  // Treat the comment as prose only: strip any embedded envelope line but never read its verdict,
  // because the already-normalized tool arguments remain the sole authoritative machine decision.
  const replySource = fromToolCall?.comment
    ? readVerdictFromReply(fromToolCall.comment).body
    : fromEnvelope.body;
  const reply = runCommentBody(replySource);
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
 * Run the task agent against a task + its comments on the owner's selected Rem runtime.
 *
 * Never throws — on any failure it returns a labelled `errored` result, so the route can
 * always persist a comment and return 201.
 */
export async function runAgentOnTask(
  task: AgentTaskInput,
  comments: AgentCommentInput[],
  instruction?: string,
  opts: AgentRunOpts = {},
): Promise<AgentRunResult> {
  if (!opts.userId) {
    // No user, so no runtime and no mode to read. `unknown` is the honest mode here — this is
    // the one blocked path where we genuinely cannot say whose key would have paid.
    return {
      reply: NO_RUNTIME_BODY,
      errored: true,
      verdictSource: 'none',
      runBlock: { code: 'runtime_unavailable', mode: 'unknown' },
    };
  }
  const userId = opts.userId;

  try {
    const message = `${SYSTEM_PROMPT}\n\n${buildUserPrompt(task, comments, instruction)}`;
    const baseTurnOptions = {
      principal: {
        userId,
        authority: opts.authority,
      },
      sessionKey: opts.sessionKey ?? `rem-task-${task.id ?? 'adhoc'}`,
      idempotencyKey: opts.idempotencyKey,
      message,
      ...(opts.model ? { model: opts.model } : {}),
    } as const;
    const sharedTurnOptions = {
      ...baseTurnOptions,
      // Reporting a verdict is structured output, not an external action. The route remains
      // the sole task mutator, so this observe turn needs neither a grant nor a gateway.
      toolPolicy: {
        mode: 'observe',
        allowedTools: [TASK_VERDICT_TOOL_NAME],
        approval: 'none',
      },
    } as const;
    let turn = opts.toolPolicy
      ? await runAgentTurn({ ...baseTurnOptions, toolPolicy: opts.toolPolicy })
      : await runAgentTurnOnSharedRuntime(sharedTurnOptions);
    // BYOK credentials are still gateway-owned during migration. Preserve that supported
    // path only when the shared runtime returns durable payer provenance proving this is a
    // BYOK account; generic/unattributed failures must never wake a gateway by accident.
    if (
      !opts.toolPolicy &&
      opts.allowLegacyByokFallback === true &&
      !turn.ok &&
      turn.reason === 'unavailable' &&
      turn.provenance.billingMode === 'byok'
    ) {
      turn = await runAgentTurn({
        ...baseTurnOptions,
        sessionKey: opts.legacyByokFallbackSessionKey ?? baseTurnOptions.sessionKey,
        toolPolicy: {
          mode: 'act',
          allowedTools: ['*'],
          approval: opts.authority === 'trusted_automation'
            ? 'automation_policy'
            : 'interactive_user',
        },
      });
    }

    if (!turn.ok) {
      const body = turn.userMessage ??
        (turn.reason === 'unavailable' ? NO_RUNTIME_BODY : runtimeFailureBody(turn.reason));
      return {
        reply: body,
        errored: true,
        verdictSource: 'none',
        runtime: turn.provenance,
        runBlock: {
          code: blockCodeForRuntimeFailure(turn.reason),
          mode: turn.provenance.billingMode,
        },
      };
    }

    const resolved = resolveRunVerdict(turn);
    const reportCall = readTaskVerdictToolCall(turn.toolCalls);
    return {
      ...resolved,
      runtime: turn.provenance,
      ...(turn.provenance.persistenceKind === 'rem_runtime' && reportCall
        ? {
            taskUpdateProposal: {
              runtimeRunId: turn.runId,
              toolCallId: reportCall.toolCallId ?? TASK_VERDICT_TOOL_NAME,
            },
          }
        : {}),
    };
  } catch (error: unknown) {
    // Runtime adapters are expected to contain transport errors. Keep this catch because a future
    // implementation must not be able to turn an adapter-contract violation into a route 500.
    const message = error instanceof Error ? error.message : String(error);
    console.error('[TASK-AGENT] runAgentOnTask failed:', message);
    return {
      reply: runtimeFailureBody('error'),
      errored: true,
      verdictSource: 'none',
      runBlock: { code: 'runtime_error', mode: 'unknown' },
    };
  }
}
