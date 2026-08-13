/**
 * routine-runner.service — executes a routine: gather context → governance → shared
 * agent → attributed task_comment → RunReport → stamp last_run_at. Gateway-free
 * (no OpenClaw cron); the scheduler that wakes this is a deliberate follow-up (the
 * open Railway-cron vs GitHub-Actions decision — see docs/rebuild/10-ROUTINES-DESIGN.md,
 * "Build order" step 4). This stage exposes the runner behind a manual trigger only.
 *
 * Resolution order mirrors digest.service.ts's never-throw philosophy: a failure in
 * gathering or the agent degrades to a low-confidence comment rather than throwing,
 * so a routine run always lands a status-feed comment the user can see.
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
import { isDailyRoutineDue } from './routine-schedule.js';
import {
  canExecuteWrites,
  describeDenyCategory,
  screenForDeniedAction,
} from './routine-governance.js';
import type { RoutineSchedule, RunConfidence, RunReport } from './routine.types.js';

/** What a single run did. Drives the surfaced comment label and the route response. */
export type RoutineRunStatus =
  | 'executed' // L3+: the agent ran and its output is an executed write
  | 'planned' // below L3: the agent ran but the comment is a proposal, not an action
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
 * implementation wraps the task agent (task-agent.service.ts), which runs the turn on
 * the routine OWNER'S gateway — a routine is an automation, so it must spend their runtime.
 */
export interface AgentRunInput {
  task: AgentTaskInput;
  comments: AgentCommentInput[];
  instruction?: string;
  /** Non-null at this point — a null model is short-circuited before the agent runs. */
  model: string;
  /** Owner of the routine — routes the run through their gateway via chat.send (Move-2). */
  userId?: string;
  /** Stable per-routine session key so repeat runs thread into one loadable chat (Move-2). */
  sessionKey?: string;
}

export interface AgentRunOutput {
  body: string;
  confidence: RunConfidence;
}

export interface AgentRunner {
  run(input: AgentRunInput): Promise<AgentRunOutput>;
}

/**
 * Default shared-agent runner. Reuses task-agent.service.runAgentOnTask (never throws).
 *
 * A ROUTINE IS AN AUTOMATION BY DEFINITION, so it is the single most repeated way to spend
 * a runtime — which is precisely why it must spend the OWNER'S. It already passed `userId`,
 * so the routine path was already gateway-first; what changed is that the fallback beneath
 * it (the operator's shared GMI key) is gone, and a routine belonging to a gateway-less user
 * now reports that honestly instead of billing someone else.
 *
 * #808 (per-routine model) IS NOT HONOURED ANY MORE, and that is worth stating rather than
 * discovering: `chat.send` has no model parameter, so the turn uses the model that user's
 * gateway is configured with. `model` is still threaded through so the routine's own
 * "no model selected" short-circuit in `runRoutine` keeps its meaning; see `AgentRunOpts.model`.
 */
export const defaultAgentRunner: AgentRunner = {
  async run({ task, comments, instruction, model, userId, sessionKey }: AgentRunInput): Promise<AgentRunOutput> {
    const result = await runAgentOnTask(task, comments, instruction, { model, userId, sessionKey });
    // Structured signal (principle 5): the shared agent sets `errored` on degraded
    // fallbacks; treat those as low confidence so they surface for review (the
    // confidence gate) instead of string-matching the leading ⚠️ glyph.
    return { body: result.reply, confidence: result.errored ? 'low' : 'medium' };
  },
};

export interface RoutineRunnerDeps {
  agent?: AgentRunner;
  screen?: typeof screenForDeniedAction;
}

const NEEDS_MODEL_BODY =
  '⚠️ This routine has no model selected, so it did not run. Choose a model for the ' +
  'routine and run it again.';

const PLAN_NOTE =
  '📝 Plan (autonomy below the execute threshold — review before acting):';

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
    const task: AgentTaskInput = taskRow
      ? {
          id: taskRow.id.toString(),
          title: taskRow.title,
          status: taskRow.status ?? null,
          priority: taskRow.priority ?? null,
        }
      : { id: routine.taskId, title: '(task unavailable)' };

    const commentsResult = await pool.query(
      `SELECT author_kind, author_label, body, proposed_status
         FROM task_comments
        WHERE task_id = $1::uuid
        ORDER BY created_at ASC
        LIMIT 50`,
      [routine.taskId],
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
 * `runtime='gateway'` because that is where the run happened — the same value the
 * orchestrator sweep and the manual run record (migration 031). It said `'agentbox'` while
 * the routine already ran on the gateway, which made every routine comment a wrong stored
 * fact about which runtime did the work.
 */
async function writeRoutineComment(
  routine: RoutineSchedule,
  body: string,
  label: string,
): Promise<string> {
  const result = await pool.query(
    `INSERT INTO task_comments (task_id, user_id, author_kind, author_label, body, runtime)
     VALUES ($1::uuid, $2::uuid, 'cloud_agent', $3, $4, 'gateway')
     RETURNING id`,
    [routine.taskId, routine.userId, label, body],
  );
  return result.rows[0].id.toString();
}

/**
 * Run one routine. Never throws — every path lands a task_comment and a RunReport.
 * Stamps last_run_at on executed/planned/denied runs (the routine cycle completed);
 * does NOT stamp on `needs_model` so the user can fix the config and retry immediately.
 */
export async function runRoutine(
  routine: RoutineSchedule,
  now: Date = new Date(),
  deps: RoutineRunnerDeps = {},
): Promise<RoutineRunResult> {
  const agent = deps.agent ?? defaultAgentRunner;
  const screen = deps.screen ?? screenForDeniedAction;
  const autonomyLevel = routine.autonomy;

  // 1. Model gate (#808): no hard default. Without a model, the agent does not run.
  if (!routine.model) {
    const commentId = await writeRoutineComment(routine, NEEDS_MODEL_BODY, 'Rem Routine');
    const report = buildRunReport({
      routineId: routine.id,
      timestamp: now,
      sources: [],
      writes: [],
      confidence: 'low',
      autonomyLevel,
    });
    return { status: 'needs_model', report, commentId, reason: 'select a model' };
  }

  // 2. Hard deny list — enforced BEFORE any agent run or external write (#797).
  const denial = screen(routine.prompt ?? '');
  if (denial.denied) {
    const labels = denial.categories.map(describeDenyCategory).join(', ');
    const body =
      `🚫 This routine asks to perform a blocked action (${labels}), which Rem never ` +
      'auto-executes regardless of autonomy level. It did not run. Review it manually.';
    const commentId = await writeRoutineComment(routine, body, 'Rem Routine (blocked)');
    const report = buildRunReport({
      routineId: routine.id,
      timestamp: now,
      sources: ['prompt'],
      writes: [],
      confidence: 'low',
      autonomyLevel,
    });
    await stampLastRun(routine.id, now);
    return { status: 'denied', report, commentId, reason: `denied: ${denial.categories.join(', ')}` };
  }

  // 3. Gather context (never-throw) and run the shared agent on the routine's model.
  const { task, comments, sources } = await gatherRoutineContext(routine);

  // Autonomy gate (SAFETY, not just labelling): only an execute-allowed routine may route
  // through the GATEWAY, whose agent has real tools and could actually act (send the email,
  // add the event). Plan-only routines (below the execute threshold) stay on the text-only
  // GMI/AgentBox path, which physically cannot act — preserving "plan-only never acts". The
  // deny-list screen above already ran regardless of autonomy. Computed before the run so it
  // gates routing, then reused below for the plan-vs-executed labelling.
  const execute = canExecuteWrites(autonomyLevel);

  let output: AgentRunOutput;
  try {
    output = await agent.run({
      task,
      comments,
      instruction: routine.prompt ?? undefined,
      model: routine.model,
      // Only hand the gateway (acting) path to execute-allowed routines.
      ...(execute ? { userId: routine.userId, sessionKey: `rem-routine-${routine.id}` } : {}),
    });
  } catch (error: unknown) {
    // The shared agent is designed never to throw; guard anyway so we always comment.
    const message = error instanceof Error ? error.message : String(error);
    console.error('[ROUTINE] agent run failed:', message);
    output = {
      body: `⚠️ The routine agent could not complete this run (${message}). No changes were made.`,
      confidence: 'low',
    };
  }

  // 4. Autonomy gate: L3+ executes; below that the result is a plan, not an action.
  const label = execute ? 'Rem Routine' : 'Rem Routine (plan)';
  const body = execute ? output.body : `${PLAN_NOTE}\n\n${output.body}`;
  const commentId = await writeRoutineComment(routine, body, label);

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
  await stampLastRun(routine.id, now);

  return { status: execute ? 'executed' : 'planned', report, commentId, reason: null };
}

/**
 * Run every routine in `routines` that is currently due (per-user timezone via the
 * shipped pure resolver). The seam a gateway-free scheduler will call once the
 * Railway-cron-vs-GitHub-Actions decision is made — NOT wired to a scheduler here.
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
