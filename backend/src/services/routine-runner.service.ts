/**
 * routine-runner.service — executes a routine: gather context → governance → shared
 * agent → attributed task_comment → RunReport → stamp last_run_at. Gateway-free
 * (no OpenClaw cron); the backend batch scheduler and authenticated manual trigger both call this
 * single governance path.
 *
 * Context gathering remains best-effort. A typed transient runtime failure releases the durable
 * occurrence for retry; a stable block settles one structured needs-attention comment.
 *
 * Governance is enforced server-side BEFORE any write (routine-governance.ts, #797):
 *   - no model selected (#808)  → do NOT run the agent; surface "select a model".
 *   - hard deny list hit        → do NOT execute; surface a blocked-for-review comment.
 *   - below the write threshold  → run, but the comment is a PLAN (needs review), not
 *                                  an executed write.
 *
 * Connectors (calendar/mail/etc.) are intentionally out of scope here — the context is
 * the task + its task_comments, exactly the seam digest.service.ts uses.
 */

import { pool } from '../db/pool.js';
import { runAgentOnTask, type AgentCommentInput, type AgentTaskInput } from './task-agent.service.js';
import { stampLastRun } from './routine-schedule.service.js';
import { buildRunReport } from './routine-schedule.service.js';
import { withRoutinePolicyLock } from './routine-policy-lock.service.js';
import { isDailyRoutineDue } from './routine-schedule.js';
import {
  PostgresRoutineRunOccurrenceStore,
  type RoutineRunOccurrenceStore,
  type StoredRoutineOccurrence,
} from './routine-run-occurrence.store.js';
import {
  canExecuteWrites,
  describeDenyCategory,
  screenForDeniedAction,
} from './routine-governance.js';
import type { RoutineSchedule, RunConfidence, RunReport } from './routine.types.js';
import type { RunBlock } from './run-block.js';

/** What a single run did. Drives the surfaced comment label and the route response. */
export type RoutineRunStatus =
  | 'executed' // L3+: the agent ran and its output is an executed write
  | 'planned' // below L3: the agent ran but the comment is a proposal, not an action
  | 'retrying' // shared runtime or settlement failed before any product effect committed
  | 'skipped' // this exact plan occurrence is already running or succeeded
  | 'needs_attention' // a stable runtime block was surfaced once and needs user action
  | 'needs_model' // no model selected (#808): the agent did not run
  | 'denied'; // hard deny list hit: blocked from executing, surfaced for review

export interface RoutineRunResult {
  status: RoutineRunStatus;
  report: RunReport;
  /** id of the task_comment written this run, or null if none was written. */
  commentId: string | null;
  /** Why the run took a non-executed path (model/deny), or null on a normal run. */
  reason: string | null;
}

/**
 * The shared agent, behind an injectable seam so the runner is testable without the
 * network and so the per-routine model can be threaded through later. The default
 * implementation wraps the task agent (`task-agent.service.ts`), which routes from the routine
 * owner's authenticated identity and an automation-policy capability grant.
 */
export interface AgentRunInput {
  task: AgentTaskInput;
  comments: AgentCommentInput[];
  instruction?: string;
  /** Non-null at this point — a null model is short-circuited before the agent runs. */
  model: string;
  /** Owner of the routine — the authenticated tenant used by the runtime router. */
  userId: string;
  /** Stable per-routine session key so repeat runs thread into one loadable chat (Move-2). */
  sessionKey: string;
  /** Stable for retries of this scheduled occurrence. */
  idempotencyKey: string;
  /** Product governance decision made before runtime selection. */
  mode: 'plan' | 'execute';
}

export interface AgentRunOutput {
  body: string;
  confidence: RunConfidence;
  runtime?: 'gateway' | 'rem_runtime';
  /** Structured runtime failure; never turn this into a completed plan occurrence. */
  errored?: boolean;
  runBlock?: RunBlock;
}

export interface AgentRunner {
  run(input: AgentRunInput): Promise<AgentRunOutput>;
}

/**
 * Default shared-agent runner. Reuses task-agent.service.runAgentOnTask (never throws).
 *
 * A routine is automation, so it supplies `trusted_automation` authority and a server-approved
 * acting policy rather than letting the prompt grant itself tools. Billing and attribution come
 * back as execution provenance from the selected runtime.
 *
 * The model is carried by the Rem contract. The transitional OpenClaw adapter cannot honor it;
 * the shared Rem runtime must.
 */
export const defaultAgentRunner: AgentRunner = {
  async run({
    task,
    comments,
    instruction,
    model,
    userId,
    sessionKey,
    idempotencyKey,
    mode,
  }: AgentRunInput): Promise<AgentRunOutput> {
    const baseOptions = {
      model,
      userId,
      sessionKey,
      authority: 'trusted_automation' as const,
      idempotencyKey,
    };
    const result = mode === 'execute'
      ? await runAgentOnTask(task, comments, instruction, {
          ...baseOptions,
          toolPolicy: {
            mode: 'act',
            // Acting routines stay on the transitional adapter until every allowed action has a
            // concrete Rem-owned capability. Do not weaken them into a text-only approximation.
            allowedTools: ['*'],
            approval: 'automation_policy',
          },
        })
      : await runAgentOnTask(task, comments, instruction, baseOptions);
    // Structured signal (principle 5): the shared agent sets `errored` on degraded
    // fallbacks; treat those as low confidence so they surface for review (the
    // confidence gate) instead of string-matching the leading ⚠️ glyph.
    return {
      body: result.reply,
      confidence: result.errored ? 'low' : 'medium',
      ...(result.errored ? { errored: true } : {}),
      ...(result.runBlock ? { runBlock: result.runBlock } : {}),
      ...(result.runtime ? { runtime: result.runtime.persistenceKind } : {}),
    };
  },
};

export interface RoutineRunnerDeps {
  agent?: AgentRunner;
  screen?: typeof screenForDeniedAction;
  occurrences?: RoutineRunOccurrenceStore;
}

export interface RoutineDispatch {
  kind: 'manual';
  /** Caller-owned identity. Manual runs use a fresh id; schedulers omit this for occurrence id. */
  idempotencyKey: string;
}

/**
 * Stable identity for the next scheduled occurrence after the last completed run.
 *
 * Mutable schedule fields cannot participate: replicas may hold old/new cadence, hour, or
 * timezone snapshots for the same due run. The prior completion is the durable boundary that
 * every such snapshot shares. Manual runs supply their own caller-owned identity.
 */
export function routineOccurrenceId(routine: RoutineSchedule, _now: Date): string {
  return `rem-routine-${routine.id}-after-${routine.lastRunAt ?? 'never'}`;
}

const NEEDS_MODEL_BODY =
  '⚠️ This routine has no model selected, so it did not run. Choose a model for the ' +
  'routine and run it again.';

const PLAN_NOTE =
  '📝 Plan (autonomy below the execute threshold — review before acting):';

/** Longer than the shared runtime's bounded provider timeout, without hiding dead workers long. */
const PLAN_OCCURRENCE_LEASE_MS = 2 * 60 * 1000;

function retryablePlanFailure(block: RunBlock | undefined): boolean {
  if (!block || block.mode !== 'rem_managed') return false;
  return block.code === 'runtime_unavailable'
    || block.code === 'runtime_timeout'
    || block.code === 'runtime_error';
}

/** Columns the runner reads to build the agent's task context. */
const TASK_CONTEXT_COLUMNS = 'id, title, status, priority';

interface RoutineContext {
  task: AgentTaskInput;
  comments: AgentCommentInput[];
  sources: string[];
}

/**
 * Gather the task + its comment thread for a routine. Read-only and never-throws: on a
 * DB error it degrades to an empty context (mirrors digest.service.ts), so the run can
 * still produce a comment rather than 500.
 */
async function gatherRoutineContext(routine: RoutineSchedule): Promise<RoutineContext> {
  try {
    const taskResult = await pool.query(
      `SELECT ${TASK_CONTEXT_COLUMNS} FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid`,
      [routine.taskId, routine.userId],
    );
    const taskRow = taskResult.rows[0];
    if (!taskRow) {
      return { task: { id: routine.taskId, title: '(task unavailable)' }, comments: [], sources: [] };
    }
    const task: AgentTaskInput = {
      id: taskRow.id.toString(),
      title: taskRow.title,
      status: taskRow.status ?? null,
      priority: taskRow.priority ?? null,
    };

    const commentsResult = await pool.query(
      `SELECT author_kind, author_label, body, proposed_status
         FROM task_comments
        WHERE task_id = $1::uuid AND user_id = $2::uuid
        ORDER BY created_at ASC
        LIMIT 50`,
      [routine.taskId, routine.userId],
    );
    const comments: AgentCommentInput[] = commentsResult.rows.map((r) => ({
      author_kind: r.author_kind,
      author_label: r.author_label,
      body: r.body,
      proposed_status: r.proposed_status ?? null,
    }));

    const sources = ['task'];
    if (comments.length) sources.push('comments');
    return { task, comments, sources };
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('[ROUTINE] context gather failed:', message);
    return { task: { id: routine.taskId, title: '(context unavailable)' }, comments: [], sources: [] };
  }
}

/**
 * Insert an attributed routine comment and return its id.
 *
 * Runtime attribution is supplied by the executed result. Non-executed policy/model comments
 * have no runtime because no engine produced them.
 */
async function writeRoutineComment(
  routine: RoutineSchedule,
  body: string,
  label: string,
  runtime: 'gateway' | 'rem_runtime' | null = null,
): Promise<string> {
  const result = await pool.query(
    `INSERT INTO task_comments (task_id, user_id, author_kind, author_label, body, runtime)
     SELECT task.id, $2::uuid, 'cloud_agent', $3, $4, $5
       FROM tasks task
      WHERE task.id = $1::uuid AND task.user_id = $2::uuid
     RETURNING id`,
    [routine.taskId, routine.userId, label, body, runtime],
  );
  return result.rows[0].id.toString();
}

/**
 * Run one routine. Policy outcomes land comments; transient plan-runtime failures do not.
 * Successful plan settlement commits its task_comment and last_run_at atomically. Acting and denied
 * paths retain their transitional writes. `needs_model` parks the scheduled occurrence until a
 * model is selected, without stamping a run that never happened or repeating the warning.
 */
async function runRoutineLocked(
  routine: RoutineSchedule,
  now: Date = new Date(),
  deps: RoutineRunnerDeps = {},
  dispatch?: RoutineDispatch,
): Promise<RoutineRunResult> {
  const agent = deps.agent ?? defaultAgentRunner;
  const screen = deps.screen ?? screenForDeniedAction;
  const occurrences = deps.occurrences ?? new PostgresRoutineRunOccurrenceStore();
  // Re-read every authority-bearing field from the same-tenant database row. A loaded scheduler
  // snapshot may predate an L3 -> L2 revocation; it must never retain wildcard acting authority.
  const currentPolicy = await occurrences.loadPolicy(routine.userId, routine.id, {
    autonomy: routine.autonomy,
    model: routine.model,
    prompt: routine.prompt,
    enabled: routine.enabled,
  });
  if (!currentPolicy) {
    const report = buildRunReport({
      routineId: routine.id,
      timestamp: now,
      sources: [],
      writes: [],
      confidence: 'low',
      autonomyLevel: routine.autonomy,
    });
    return {
      status: 'retrying', report, commentId: null,
      reason: 'routine task ownership unavailable',
    };
  }
  const currentRoutine: RoutineSchedule = {
    ...routine,
    ...currentPolicy,
    model: currentPolicy.model?.trim() || null,
  };
  const autonomyLevel = currentRoutine.autonomy;
  // A scheduler selection is only a snapshot. Pausing after selection must revoke even a queued
  // L3 wildcard run. Explicit Run Now supplies a caller-owned dispatch and remains intentional.
  if (!currentRoutine.enabled && !dispatch) {
    const report = buildRunReport({
      routineId: currentRoutine.id,
      timestamp: now,
      sources: [],
      writes: [],
      confidence: 'high',
      autonomyLevel,
    });
    return { status: 'skipped', report, commentId: null, reason: 'routine disabled' };
  }
  const execute = canExecuteWrites(autonomyLevel);
  const denial = screen(currentRoutine.prompt ?? '');
  const baseOccurrenceKey = dispatch?.idempotencyKey ?? routineOccurrenceId(currentRoutine, now);
  let planOccurrence: StoredRoutineOccurrence | null = null;

  // Every L0-L2 product outcome claims one durable occurrence before any comment or model call.
  // The key is independent of mutable policy/config snapshots so stale scheduler replicas cannot
  // publish two outcomes after the same durable prior completion. A user-triggered Run Now has its own
  // caller-provided key and remains available immediately after configuration changes.
  const scheduledTerminalOutcome = !dispatch && (!currentRoutine.model || denial.denied);
  if (!execute || scheduledTerminalOutcome) {
    const claim = await occurrences.claim({
      userId: routine.userId,
      routineId: routine.id,
      occurrenceKey: baseOccurrenceKey,
      leaseMs: PLAN_OCCURRENCE_LEASE_MS,
    });
    if (claim.kind === 'existing') {
      const report = buildRunReport({
        routineId: routine.id,
        timestamp: now,
        sources: [],
        writes: [],
        confidence: 'high',
        autonomyLevel,
      });
      return {
        status: 'skipped',
        report,
        commentId: claim.occurrence.commentId,
        reason: `occurrence already ${claim.occurrence.state}`,
      };
    }
    planOccurrence = claim.occurrence;
  }

  // 1. Model gate (#808): no hard default. Without a model, the agent does not run.
  if (!currentRoutine.model) {
    const report = buildRunReport({
      routineId: routine.id,
      timestamp: now,
      sources: [],
      writes: [],
      confidence: 'low',
      autonomyLevel,
    });
    const commentId = planOccurrence
      ? await occurrences.waitForModel({
          occurrence: planOccurrence,
          body: NEEDS_MODEL_BODY,
          label: 'Rem Routine',
          completedAt: now,
        })
      : await writeRoutineComment(currentRoutine, NEEDS_MODEL_BODY, 'Rem Routine');
    if (!commentId) {
      return {
        status: 'retrying', report, commentId: null,
        reason: 'occurrence ownership expired before settlement',
      };
    }
    return { status: 'needs_model', report, commentId, reason: 'select a model' };
  }

  // 2. Hard deny list — enforced BEFORE any agent run or external write (#797).
  if (denial.denied) {
    const labels = denial.categories.map(describeDenyCategory).join(', ');
    const body =
      `🚫 This routine asks to perform a blocked action (${labels}), which Rem never ` +
      'auto-executes regardless of autonomy level. It did not run. Review it manually.';
    const report = buildRunReport({
      routineId: routine.id,
      timestamp: now,
      sources: ['prompt'],
      writes: [],
      confidence: 'low',
      autonomyLevel,
    });
    const commentId = planOccurrence
      ? await occurrences.settle({
          occurrence: planOccurrence,
          body,
          label: 'Rem Routine (blocked)',
          runtime: null,
          completedAt: now,
          stampSchedule: true,
        })
      : await writeRoutineComment(currentRoutine, body, 'Rem Routine (blocked)');
    if (!commentId) {
      return {
        status: 'retrying', report, commentId: null,
        reason: 'occurrence ownership expired before settlement',
      };
    }
    if (!planOccurrence) await stampLastRun(currentRoutine.id, now);
    return { status: 'denied', report, commentId, reason: `denied: ${denial.categories.join(', ')}` };
  }

  // 3. Autonomy gate (SAFETY, not just labelling). L0-L2 stays on Rem's observe-only runtime;
  // its only registered tool is the side-effect-free rem_task_report proposal. L3+ retains the
  // transitional acting adapter until concrete Rem-owned capabilities replace its wildcard.
  // 4. Gather context (never-throw) and run the selected runtime on the routine's model.
  const { task, comments, sources } = await gatherRoutineContext(currentRoutine);

  let output: AgentRunOutput;
  try {
    output = await agent.run({
      task,
      comments,
      instruction: currentRoutine.prompt ?? undefined,
      model: currentRoutine.model,
      userId: currentRoutine.userId,
      sessionKey: `rem-routine-${currentRoutine.id}`,
      idempotencyKey: planOccurrence
        ? `${baseOccurrenceKey}:attempt:${planOccurrence.attemptCount}`
        : baseOccurrenceKey,
      mode: execute ? 'execute' : 'plan',
    });
  } catch (error: unknown) {
    // The shared agent is designed never to throw; guard anyway so we always comment.
    const message = error instanceof Error ? error.message : String(error);
    console.error('[ROUTINE] agent run failed:', message);
    output = {
      body: `⚠️ The routine agent could not complete this run (${message}). No changes were made.`,
      confidence: 'low',
      errored: true,
      runBlock: { code: 'runtime_error', mode: 'unknown' },
    };
  }

  // A degraded runtime result is not a plan. Release this occurrence for a fresh attempt key and
  // leave both task_comments and last_run_at untouched so the scheduler can retry it.
  if (planOccurrence && output.errored && retryablePlanFailure(output.runBlock)) {
    await occurrences.retry(planOccurrence);
    const report = buildRunReport({
      routineId: routine.id,
      timestamp: now,
      sources,
      writes: [],
      confidence: 'low',
      autonomyLevel,
    });
    return { status: 'retrying', report, commentId: null, reason: 'runtime error; will retry' };
  }

  if (planOccurrence && output.errored) {
    const report = buildRunReport({
      routineId: routine.id,
      timestamp: now,
      sources,
      writes: ['task_comment'],
      confidence: 'low',
      autonomyLevel,
    });
    const commentId = await occurrences.settle({
      occurrence: planOccurrence,
      body: output.body,
      label: 'Rem Routine (needs attention)',
      runtime: output.runtime ?? null,
      runBlock: output.runBlock ?? null,
      completedAt: now,
      stampSchedule: true,
    });
    if (!commentId) {
      return {
        status: 'retrying', report: { ...report, writes: [] }, commentId: null,
        reason: 'occurrence ownership expired before settlement',
      };
    }
    return {
      status: 'needs_attention', report, commentId,
      reason: output.runBlock?.code ?? 'runtime error',
    };
  }

  // 5. Autonomy gate: L3+ executes; below that the result is a plan, not an action.
  const label = execute ? 'Rem Routine' : 'Rem Routine (plan)';
  const body = execute ? output.body : `${PLAN_NOTE}\n\n${output.body}`;

  const report = buildRunReport({
    routineId: routine.id,
    timestamp: now,
    sources,
    // `writes` is the *proposed* write (the status-feed comment). buildRunReport flags
    // needsReview when a write is proposed below the execute threshold — that's the
    // plan path — and otherwise only on low confidence.
    writes: ['task_comment'],
    confidence: output.confidence,
    autonomyLevel,
  });

  if (planOccurrence) {
    const commentId = await occurrences.settle({
      occurrence: planOccurrence,
      body,
      label,
      runtime: output.runtime ?? null,
      completedAt: now,
      stampSchedule: true,
    });
    if (!commentId) {
      return {
        status: 'retrying',
        report: { ...report, writes: [], needsReview: true },
        commentId: null,
        reason: 'occurrence ownership expired before settlement',
      };
    }
    return { status: 'planned', report, commentId, reason: null };
  }

  const commentId = await writeRoutineComment(currentRoutine, body, label, output.runtime ?? null);
  await stampLastRun(currentRoutine.id, now);

  return { status: 'executed', report, commentId, reason: null };
}

/**
 * Serialize dispatch with pause, downgrade, prompt/model edits, and deletion. The authoritative
 * policy read and any wildcard acting turn occur while this lock is held, closing their TOCTOU gap.
 */
export async function runRoutine(
  routine: RoutineSchedule,
  now: Date = new Date(),
  deps: RoutineRunnerDeps = {},
  dispatch?: RoutineDispatch,
): Promise<RoutineRunResult> {
  return withRoutinePolicyLock(routine.id, () => runRoutineLocked(routine, now, deps, dispatch));
}

/**
 * Run every routine in `routines` that is currently due (per-user timezone via the
 * shipped pure resolver). The backend batch scheduler calls this gateway-free seam.
 */
export async function runDueRoutines(
  routines: RoutineSchedule[],
  now: Date = new Date(),
  deps: RoutineRunnerDeps = {},
): Promise<RoutineRunResult[]> {
  const results: RoutineRunResult[] = [];
  for (const routine of routines) {
    const lastRunAt = routine.lastRunAt ? new Date(routine.lastRunAt) : null;
    if (!isDailyRoutineDue(routine, now, lastRunAt)) continue;
    results.push(await runRoutine(routine, now, deps));
  }
  return results;
}
