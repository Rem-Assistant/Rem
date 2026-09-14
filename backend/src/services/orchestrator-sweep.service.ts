/**
 * orchestrator-sweep — the "brief that ACTS" (#922). A backend-scheduled sweep that
 * finds tasks which are READY TO RUN and runs each one AUTONOMOUSLY through Rem's hosted
 * observe runtime, then applies its proposal through the audited `tasks.update` adapter and
 * leaves an attributed Activity comment — so the brief/check-in
 * that reads `task_comments` reports "here's your state and I've already started handling
 * it" with no extra wiring.
 *
 * This is MULTI-CHAT, not multi-agent: one canonical `rem-task-<taskId>` session per task.
 * The model has observe authority only. A separate non-model act run receives one exact,
 * expiring automation-policy grant for the schema-validated proposal.
 *
 * SAFETY — the sweep is deliberately reversible (mirrors #895):
 *   - The autonomous turn is RESTRICTED to the supplied task context plus reasoning and drafting.
 *     The prompt forbids any external/irreversible write —
 *     no sending email/messages, no create/modify/delete of calendar events, reminders,
 *     contacts or files, no money, no sharing changes. A task that REQUIRES such a write
 *     returns `proposed_status: blocked` and is left for the user to run with one tap.
 *     Because the turn performs no external writes, its product mutations stay inside the task:
 *     status, context, attributed Activity/Undo, and replayable transcript.
 *   - Apply-with-Undo: when the agent decides a new status, we APPLY it to `tasks.status`
 *     and record the PRE-change value on the comment (`previous_status`, migration 028).
 *     The status change + the comment/Undo record are written in ONE transaction, so a
 *     comment-write failure can never leave the status changed with no record. The
 *     existing iOS/Mac UI renders "Applied: <status>" + Undo off that field with NO
 *     client change (Shared/Models/TaskCollaboration.swift `didApplyStatus`).
 *   - Deny-list screen: the same hard deny list the routine runner uses (routine-
 *     governance.ts) screens each task's title + DESCRIPTION + thread BEFORE any model
 *     turn — "send email", "wire money", "delete …" never auto-run; they're recorded
 *     blocked-for-review instead. This is defense-in-depth on top of the restricted
 *     prompt. The screen covers all stored Activity/chat text. The automation prompt itself admits
 *     only first-party user-authored fields/turns until durable external provenance exists.
 *   - Off by default: the sweep only runs when `ORCHESTRATOR_SWEEP_ENABLED` is truthy, so
 *     fleet-wide autonomous execution is behind an explicit opt-in kill-switch (M5).
 *   - The Rem session IS the transcript: the run serializes with task chat and persists to a loadable chat
 *     the user can open — the comment carries the canonical `sessionKey` in `session_id`, so
 *     tapping the Activity row opens the REAL conversation (not an empty composer).
 *
 * DEGRADE GRACEFULLY: a confirmed pre-effect runtime failure releases the claim for retry.
 * An admitted-but-pending or ambiguous effect holds the claim until stale recovery rather than
 * minting a second identity. Nothing throws past `sweepReadyTasks`, so a flaky provider can't
 * crash the cron (mirrors run-routines.ts per-item isolation).
 *
 * Lifecycle / source of truth (principle 3):
 *   - Source of truth for status: `tasks.status`. Undo target: `task_comments.previous_status`.
 *   - claim   : `run_status` NULL → 'running' (atomic, so two ticks can't double-run one task).
 *   - apply   : durable proposal + policy grant → audited effect + terminal `run_status`
 *               + attributed comment/Undo + task context, all in ONE transaction.
 *   - release : a confirmed pre-effect failure → `run_status` back to NULL (retry next tick).
 *   - reap    : a claim stranded 'running' past STALE_CLAIM_MINUTES (a crashed prior tick) is
 *               released back to NULL at the top of the next sweep, so a mid-run crash can't
 *               strand a task forever.
 *   - reverse : user taps Undo → PATCH /tasks/:id with `previous_status` (existing path).
 *
 * Non-goals (this change): no new UI, no new DB columns, and no external connector writes
 * (the restricted prompt forbids them). No re-run of a task that already carries a terminal
 * `run_status` (one autonomous attempt per task — the manual agent-run button remains the
 * way to run it again).
 */

import { pool, taskConversationPool } from '../db/pool.js';
import type { PoolClient } from 'pg';
import { runAgentOnTask } from './task-agent.service.js';
import type { ProposedStatus } from './task-verdict.js';
import { screenForDeniedAction, describeDenyCategory } from './routine-governance.js';
import { resolveModelRuntimeMode, type RunBlock } from './run-block.js';
import { splitDescription } from './task-description.js';
import {
  executeTrustedAutomationTaskStatusProposal,
  type TaskStatusExecutionResult,
  type TaskStatusProposal,
} from '../runtime/rem-task-tool-execution.js';

/** A task the sweep decided is ready to run, projected to the fields the agent needs. */
export interface ReadyTask {
  id: string;
  userId: string;
  title: string;
  status: string | null;
  priority: string | null;
  /**
   * The co-authored description as stored (migration 120). Carried raw and split at the
   * prompt, so the block delimiter is only ever parsed by task-description.service.ts.
   * This is what lets an autonomous run open with the last run's state.
   */
  description: string | null;
}

/** Prior comments passed to the agent as context (author + body only). */
export interface ReadyTaskComment {
  author_kind: string | null;
  author_label: string | null;
  body: string | null;
}

/** Outcome of running ONE ready task. */
export type SweepTaskStatus =
  | 'executed' // Rem ran the task autonomously; audited status effect + comment committed
  | 'denied' // hard deny-list hit → recorded blocked-for-review, never dispatched
  | 'skipped_runtime' // runtime/effect unavailable → released when retry is proven safe
  | 'skipped_claim'; // another worker already claimed this task this tick

export interface SweepTaskResult {
  taskId: string;
  userId: string;
  status: SweepTaskStatus;
  /** Applied task status (executed path with a real change), else null. */
  appliedStatus: ProposedStatus | null;
  /** id of the task_comment written this run, or null when none was written. */
  commentId: string | null;
  /** Structured reason on a non-executed path (runtime reason / deny categories). */
  reason: string | null;
}

export interface SweepReport {
  scanned: number;
  executed: number;
  denied: number;
  /** Total skipped (runtime/effect failure + claim contention) — for the log summary. */
  skipped: number;
  /** Skipped because runtime/effect execution did not complete — a real miss. */
  skippedRuntime: number;
  /** Skipped because another worker already held the claim — NOT a failure (L8). */
  skippedClaim: number;
  /** Stale 'running' claims released at the top of this sweep (crashed prior ticks). */
  reaped: number;
  results: SweepTaskResult[];
}

/**
 * The observe turn, behind an injectable seam so the sweep is testable without a provider.
 * Success includes the durable report call that the policy executor must verify.
 */
export interface ReadyTaskAgentInput {
  task: ReadyTask;
  comments: ReadyTaskComment[];
  sessionKey: string;
  idempotencyKey: string;
}
export type ReadyTaskAgentResult =
  | {
      ok: true;
      reply: string;
      proposedStatus: ProposedStatus;
      /** Current-state summary for `tasks.description`'s agent block (migration 120).
       *  null = the run said nothing new, which means keep what was already known. */
      taskContext?: string | null;
      /** Provenance computed by the runner from the exact content admitted to its prompt. */
      externalContentInfluenced: boolean;
      proposalRunId: string;
      toolCallId: string;
    }
  | { ok: false; reason: string };
export interface ReadyTaskAgentRunner {
  run(input: ReadyTaskAgentInput): Promise<ReadyTaskAgentResult>;
}

export interface ReadyTaskStatusExecutor {
  execute(input: TaskStatusProposal): Promise<TaskStatusExecutionResult>;
}

export interface SweepDeps {
  agent?: ReadyTaskAgentRunner;
  screen?: typeof screenForDeniedAction;
  statusExecutor?: ReadyTaskStatusExecutor;
}

/** Global cap per sweep tick — bounds hosted runtime load if a backlog of tasks comes due. */
export const MAX_TASKS_PER_SWEEP = 100;
/** Per-user cap per tick — one noisy user can't monopolize the sweep. */
export const MAX_TASKS_PER_USER = 3;
/** How far back a due task stays eligible — avoids auto-running long-forgotten tasks. */
export const READY_LOOKBACK_DAYS = 7;
/**
 * A 'running' claim older than this is treated as ORPHANED (its tick crashed between
 * claim and terminal) and released back to NULL. Comfortably larger than a single run's
 * worst case (provider turn + audited write), and larger than the 15-min cron
 * interval, so we never reap a claim the current sweep is legitimately still working.
 */
export const STALE_CLAIM_MINUTES = 30;

/**
 * Sweep-execution kill-switch (M5). Fleet-wide autonomous, side-effecting execution stays
 * OFF unless an operator explicitly opts in via `ORCHESTRATOR_SWEEP_ENABLED` (truthy:
 * 1/true/yes/on). Mirrors the deliberate gating other cloud-cost cron passes carry.
 */
export function isSweepEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return /^(1|true|yes|on)$/i.test((env.ORCHESTRATOR_SWEEP_ENABLED ?? '').trim());
}

/**
 * Execute-directive framing for the autonomous turn. This tells Rem to work the task now,
 * but ONLY with reasoning and drafting. It must NOT perform any external
 * or irreversible write (the sweep runs unattended, and the only reversal we have is a
 * status Undo). `runAgentOnTask` adds the shared schema-validated report contract.
 */
const SWEEP_INSTRUCTION =
  'You are Rem running autonomously and UNATTENDED on the user\'s behalf. You are given a ' +
  'task the user scheduled and its prior comments. Work the task now using ONLY the supplied ' +
  'context and drafting/reasoning — summarize, analyze, and draft or prepare content. ' +
  'You MUST NOT take any action that changes the outside world or that cannot be reversed ' +
  'by simply changing this task\'s status: do NOT send emails/messages, do NOT create, ' +
  'modify, or delete calendar events, reminders, contacts, or files, do NOT move money, and ' +
  'do NOT change sharing or permissions. If finishing the task REQUIRES any such external ' +
  'write, stop and report the status "blocked" so the user can run it themselves with one ' +
  'tap. Reply with 1-3 sentences describing exactly what you did or prepared (or why you are ' +
  'blocked). Choose "completed" when you fully finished it with read-only/drafting work, ' +
  '"in_progress" when you made progress but it is not done, and "blocked" when it needs an ' +
  'external write or an input only the user can provide.';

/** User-visible ask for the task transcript; never expose the internal automation directive. */
export function sweepTranscriptAsk(task: Pick<ReadyTask, 'title'>): string {
  const title = task.title.trim();
  return title ? `Work on "${title}" now.` : 'Work on this scheduled task now.';
}

/** The canonical Rem session key for every task turn, including unattended sweeps. */
export function taskSessionKey(taskId: string): string {
  // PostgreSQL UUID text is canonical lowercase, while a device can put an uppercase
  // UUID in the manual agent-run path. Session keys are case-sensitive, so
  // normalize here or a pre-run device chat and the later cloud run split in two.
  return `rem-task-${taskId.trim().toLowerCase()}`;
}

/**
 * Default runner: one trusted-automation observe turn on Rem's hosted runtime. The model can
 * only emit the report tool; the caller separately verifies and executes that proposal.
 */
export const defaultReadyTaskAgentRunner: ReadyTaskAgentRunner = {
  async run({ task, comments, sessionKey, idempotencyKey }): Promise<ReadyTaskAgentResult> {
    const description = splitDescription(task.description);
    // Automation-policy approval may only be influenced by first-party user instructions.
    // Agent-authored comments/context have no durable external-content provenance yet, so do
    // not admit them to this unattended prompt. User-authored task fields and comments are the
    // explicit instruction boundary; connector/browser outputs must remain user-approved until
    // the runtime persists provenance for them.
    const userComments = comments.filter((comment) => comment.author_kind === 'user');
    const result = await runAgentOnTask(
      {
        id: task.id,
        title: task.title,
        status: task.status,
        priority: task.priority,
        description_user: description.user,
        description_agent: null,
      },
      userComments.map((comment) => ({
        ...(comment.author_kind ? { author_kind: comment.author_kind } : {}),
        ...(comment.author_label ? { author_label: comment.author_label } : {}),
        ...(comment.body ? { body: comment.body } : {}),
      })),
      SWEEP_INSTRUCTION,
      {
        userId: task.userId,
        authority: 'trusted_automation',
        sessionKey,
        idempotencyKey,
      },
    );
    if (result.errored) return { ok: false, reason: result.runBlock?.code ?? 'runtime_error' };
    if (!result.proposedStatus || !result.taskUpdateProposal) {
      return { ok: false, reason: 'proposal_unverified' };
    }
    return {
      ok: true,
      reply: result.reply,
      proposedStatus: result.proposedStatus,
      taskContext: result.taskContext,
      externalContentInfluenced: false,
      proposalRunId: result.taskUpdateProposal.runtimeRunId,
      toolCallId: result.taskUpdateProposal.toolCallId,
    };
  },
};

const defaultReadyTaskStatusExecutor: ReadyTaskStatusExecutor = {
  execute: executeTrustedAutomationTaskStatusProposal,
};

/** Terminal run_status from the agent's proposed status (structured, not string-matched). */
function terminalRunStatus(proposed: ProposedStatus): 'done' | 'review' | 'blocked' {
  if (proposed === 'completed') return 'done';
  if (proposed === 'blocked') return 'blocked';
  return 'review';
}

/**
 * Release stale 'running' claims (H3). A tick that crashes between the atomic claim and
 * the terminal write leaves `run_status = 'running'` forever, so `findReadyTasks`
 * (which requires `run_status IS NULL`) would never pick that task up again. This resets
 * any claim older than STALE_CLAIM_MINUTES back to NULL so it is eligible next tick.
 * Bounded by an age well beyond a single run's worst case, so it never touches a claim
 * the current sweep is legitimately still holding. Returns how many it reaped.
 */
export async function reapStaleRunningClaims(now: Date): Promise<number> {
  const result = await pool.query(
    `UPDATE tasks AS task
        SET run_status = NULL, run_id = NULL, run_started_at = NULL,
            run_last_heartbeat_at = NULL, updated_at = NOW()
      WHERE task.run_status = 'running'
        AND task.run_started_at IS NOT NULL
        AND task.run_started_at < $1::timestamptz - ($2 || ' minutes')::interval
        AND NOT EXISTS (
          SELECT 1
            FROM rem_tool_effects AS effect
           WHERE effect.user_id = task.user_id
             AND effect.session_key = 'rem-task-' || LOWER(task.id::text)
             AND effect.connector = 'Rem Tasks'
             AND effect.capability_key = 'tasks.write'
             AND effect.tool_name = 'tasks.update'
             AND effect.state IN ('running', 'uncertain')
        )`,
    [now.toISOString(), String(STALE_CLAIM_MINUTES)],
  );
  return result.rowCount ?? 0;
}

/**
 * Find tasks that are READY TO RUN, conservatively defined so the sweep only acts on
 * work the user clearly scheduled and that Rem has not already touched:
 *
 *   - `type = 'task'`            — calendar events are not "run".
 *   - `status = 'pending'`       — not already in_progress/completed/cancelled/blocked.
 *   - `run_status IS NULL`       — never run/attempted. This is the idempotency + one-
 *                                  attempt guard: a manual agent-run OR a prior sweep run
 *                                  stamps run_status, so a task is auto-run at most once.
 *   - `start_date <= now`        — DUE (or overdue). This is the "ready" trigger; a task
 *                                  with no start_date is an unscheduled inbox item and is
 *                                  intentionally NOT auto-run.
 *   - `start_date >= now - 7d`   — not long-forgotten.
 *
 * The per-user cap is enforced IN SQL (ROW_NUMBER partitioned by user, keeping only the
 * top-N per user) BEFORE the global LIMIT — so one user's backlog can never starve the
 * fleet by consuming all 100 global slots (M4). Ordered high-priority + soonest-due
 * first. Read-only.
 */
export async function findReadyTasks(now: Date): Promise<ReadyTask[]> {
  const result = await pool.query(
    `WITH eligible AS (
        SELECT id, user_id, title, description, status, priority, start_date,
               ROW_NUMBER() OVER (
                 PARTITION BY user_id
                 ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END ASC,
                          start_date ASC
               ) AS user_rank
          FROM tasks
         WHERE type = 'task'
           AND status = 'pending'
           AND run_status IS NULL
           AND start_date IS NOT NULL
           AND start_date <= $1::timestamptz
           AND start_date >= $1::timestamptz - ($2 || ' days')::interval
     )
     SELECT id, user_id, title, description, status, priority
       FROM eligible
      WHERE user_rank <= $3
      ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END ASC,
               start_date ASC
      LIMIT $4`,
    [now.toISOString(), String(READY_LOOKBACK_DAYS), MAX_TASKS_PER_USER, MAX_TASKS_PER_SWEEP],
  );
  return result.rows.map((r) => ({
    id: r.id.toString(),
    userId: r.user_id.toString(),
    title: r.title,
    description: r.description ?? null,
    status: r.status ?? null,
    priority: r.priority ?? null,
  }));
}

/**
 * Enforce the per-user cap in memory. The SQL in `findReadyTasks` already caps per user,
 * so this is a defensive second layer (and keeps the pure function unit-testable).
 */
export function applyPerUserCap(tasks: ReadyTask[], cap = MAX_TASKS_PER_USER): ReadyTask[] {
  const seen = new Map<string, number>();
  const kept: ReadyTask[] = [];
  for (const task of tasks) {
    const count = seen.get(task.userId) ?? 0;
    if (count >= cap) continue;
    seen.set(task.userId, count + 1);
    kept.push(task);
  }
  return kept;
}

/**
 * Insert an attributed orchestrator comment and return its id. `session_id` carries the
 * canonical Rem session key (`rem-task-<taskId>`), so Activity opens the durable transcript.
 * Runs on a caller-supplied client so it can share a transaction with the status apply.
 */
async function writeSweepComment(
  db: PoolClient,
  task: ReadyTask,
  body: string,
  label: string,
  proposedStatus: ProposedStatus | null,
  previousStatus: string | null,
  sessionKey: string,
  runBlock: RunBlock | null = null,
): Promise<string> {
  const result = await db.query(
    `INSERT INTO task_comments
       (task_id, user_id, author_kind, author_label, body, proposed_status, previous_status, runtime, session_id, run_block_code, run_block_mode)
     VALUES ($1::uuid, $2::uuid, 'cloud_agent', $3, $4, $5, $6, 'rem_runtime', $7, $8, $9)
     RETURNING id`,
    [
      task.id,
      task.userId,
      label,
      body,
      proposedStatus,
      previousStatus,
      sessionKey,
      runBlock?.code ?? null,
      runBlock?.mode ?? null,
    ],
  );
  return result.rows[0].id.toString();
}

/** Release a claim we hold back to NULL so the task retries on a later tick. */
async function releaseClaim(task: ReadyTask, runId: string): Promise<void> {
  await pool.query(
    `UPDATE tasks SET run_status = NULL, run_id = NULL, run_started_at = NULL,
            run_last_heartbeat_at = NULL, updated_at = NOW()
      WHERE id = $1::uuid AND user_id = $2::uuid AND run_id = $3`,
    [task.id, task.userId, runId],
  );
}

/**
 * Run ONE ready task autonomously. Never throws. See the file header for the full
 * lifecycle; the short version:
 *   claim → deny-screen → Rem observe turn → policy-approved audited effect | safe release.
 */
export async function runReadyTask(
  task: ReadyTask,
  now: Date,
  deps: SweepDeps = {},
): Promise<SweepTaskResult> {
  const base = { taskId: task.id, userId: task.userId };
  const lock = await taskConversationPool.connect();
  try {
    await lock.query('BEGIN');
    const acquired = await lock.query(
      `SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0)) AS acquired`,
      [`task-chat:${task.userId}:${task.id.toLowerCase()}`],
    );
    if (acquired.rows[0]?.acquired !== true) {
      return { ...base, status: 'skipped_claim', appliedStatus: null, commentId: null, reason: null };
    }
    return await runReadyTaskUnderConversationLock(task, now, deps);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    return { ...base, status: 'skipped_runtime', appliedStatus: null, commentId: null, reason: `error: ${message}` };
  } finally {
    await lock.query('ROLLBACK').catch(() => undefined);
    lock.release();
  }
}

async function runReadyTaskUnderConversationLock(
  task: ReadyTask,
  now: Date,
  deps: SweepDeps = {},
): Promise<SweepTaskResult> {
  const agent = deps.agent ?? defaultReadyTaskAgentRunner;
  const statusExecutor = deps.statusExecutor ?? defaultReadyTaskStatusExecutor;
  const screen = deps.screen ?? screenForDeniedAction;
  const runId =
    (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const sessionKey = taskSessionKey(task.id);
  const idempotencyKey = `orchestrator-sweep:${runId}`;
  const base = { taskId: task.id, userId: task.userId };

  // 1. Atomic claim: only ONE worker can flip run_status NULL → 'running'. The status
  //    guard also means a task that changed out of 'pending' since the scan is not run.
  const claim = await pool.query(
    `UPDATE tasks
        SET run_status = 'running', run_id = $1, run_started_at = NOW(),
            run_last_heartbeat_at = NOW(), updated_at = NOW()
      WHERE id = $2::uuid AND user_id = $3::uuid
        AND type = 'task' AND status = 'pending' AND run_status IS NULL
      RETURNING title, status, priority, description, updated_at`,
    [runId, task.id, task.userId],
  );
  if (claim.rowCount === 0) {
    return { ...base, status: 'skipped_claim', appliedStatus: null, commentId: null, reason: null };
  }
  const claimRow = claim.rows?.[0];
  const observedTask: ReadyTask = claimRow
    ? {
        ...task,
        title: claimRow.title,
        status: claimRow.status,
        priority: claimRow.priority,
        description: claimRow.description,
      }
    : task;
  const expectedTaskUpdatedAt = claimRow?.updated_at
    ? new Date(claimRow.updated_at).toISOString()
    : undefined;

  // 2. Deny-list screen (SAFETY) — BEFORE any model turn. A task whose title/thread asks
  //    for a hard-denied action (send email, move money, delete data, change sharing) is
  //    NEVER auto-run; it's recorded blocked-for-review so the user handles it manually.
  //
  //    THE SCREEN MUST COVER EVERYTHING `runAgentOnTask` PUTS IN THE PROMPT. The
  //    description (migration 120) is injected into the unattended turn as both
  //    DESCRIPTION and CURRENT CONTEXT, so screening only the title and comments left a
  //    hole: a task titled "Follow up with Dana" passes the screen while its description
  //    says "send Dana the signed contract and delete the draft", and the agent is then
  //    told to act on it.
  //
  //    The agent's OWN prior `task_context` lives in that same column and is fed back in
  //    on the next run, so an unscreened description also lets run 1 write an instruction
  //    that run 2 executes — a self-reinforcing escalation with no human in the loop.
  //    Screening the raw column covers both halves at once (the marker literals in it are
  //    inert text to the deny list).
  let gathered: Awaited<ReturnType<typeof gatherComments>>;
  try {
    gathered = await gatherComments(observedTask.id, observedTask.userId);
  } catch (error: unknown) {
    await releaseClaim(observedTask, runId).catch(() => undefined);
    const message = error instanceof Error ? error.message : String(error);
    return { ...base, status: 'skipped_runtime', appliedStatus: null, commentId: null, reason: `error: ${message}` };
  }
  const comments = gathered.context;
  const screenText = [
    observedTask.title,
    observedTask.description ?? '',
    ...comments.map((c) => c.body ?? ''),
  ].join('\n');
  const denial = screen(screenText);
  if (denial.denied) {
    const labels = denial.categories.map(describeDenyCategory).join(', ');
    const body =
      `🚫 Rem did not auto-run this task because it asks to perform a blocked action ` +
      `(${labels}), which Rem never runs autonomously. Review and run it yourself.`;
    // No status APPLY (task stays pending); run_status='blocked' records the decision and
    // stops re-evaluation next tick. previous_status is null → no Undo (nothing changed).
    // The status flip + the record go in ONE transaction so we can't mark it blocked with
    // no comment explaining why.
    //
    // `policy_blocked` (migration 121) is the machine half of the 🚫 prose above. A deny is a
    // real blocked run — it is the sweep's most common one — so run history must be able to
    // tell it apart from a failed runtime without reading the sentence. The mode rides along for
    // contract uniformity even though this remedy ("run it yourself") does not depend on it.
    try {
      const denialBlock: RunBlock = {
        code: 'policy_blocked',
        mode: await resolveModelRuntimeMode(observedTask.userId),
      };
      const commentId = await runInTransaction(async (db) => {
        if (expectedTaskUpdatedAt) {
          const current = await db.query(
            `SELECT updated_at,
                    (SELECT COUNT(*)::int FROM task_comments
                      WHERE task_id = tasks.id AND user_id = tasks.user_id) AS comment_count,
                    (SELECT COUNT(*)::int FROM task_chat_messages
                      WHERE task_id = tasks.id AND user_id = tasks.user_id) AS chat_message_count
               FROM tasks
              WHERE id = $1::uuid AND user_id = $2::uuid AND run_id = $3
              FOR UPDATE`,
            [observedTask.id, observedTask.userId, runId],
          );
          const row = current.rows[0];
          const unchanged = row
            && new Date(row.updated_at).toISOString() === expectedTaskUpdatedAt
            && Number(row.comment_count) === gathered.totalCount
            && Number(row.chat_message_count) === gathered.chatMessageCount;
          if (!unchanged) throw new Error('task_observation_changed');
        }
        const terminal = await db.query(
          `UPDATE tasks SET run_status = 'blocked', run_block_code = $3, run_block_mode = $4,
                  run_last_heartbeat_at = NOW(), updated_at = NOW()
            WHERE id = $1::uuid AND user_id = $2::uuid AND run_id = $5
            RETURNING id`,
          [observedTask.id, observedTask.userId, denialBlock.code, denialBlock.mode, runId],
        );
        if (!terminal.rows[0]) throw new Error('task_observation_changed');
        return writeSweepComment(
          db, observedTask, body, 'Rem Orchestrator (blocked)', null, null, sessionKey, denialBlock,
        );
      });
      return {
        ...base,
        status: 'denied',
        appliedStatus: null,
        commentId,
        reason: `denied: ${denial.categories.join(', ')}`,
      };
    } catch (error: unknown) {
      // Recording the denial failed — release the claim so it is re-screened (and denied
      // again) next tick rather than stranded 'running'.
      await releaseClaim(observedTask, runId).catch(() => {});
      const message = error instanceof Error ? error.message : String(error);
      return { ...base, status: 'skipped_runtime', appliedStatus: null, commentId: null, reason: `error: ${message}` };
    }
  }

  // 3. Run one observe-only Rem turn. It may propose a task status but cannot apply it.
  let agentResult: ReadyTaskAgentResult;
  try {
    agentResult = await agent.run({ task: observedTask, comments, sessionKey, idempotencyKey });
  } catch (error: unknown) {
    // The runner is designed never to throw; guard anyway → treat as a runtime skip.
    const message = error instanceof Error ? error.message : String(error);
    agentResult = { ok: false, reason: `error: ${message}` };
  }

  // 4a. Observe failure means no effect was admitted, so release and retry later.
  if (!agentResult.ok) {
    await releaseClaim(observedTask, runId);
    return { ...base, status: 'skipped_runtime', appliedStatus: null, commentId: null, reason: agentResult.reason };
  }

  // 4b. A durable proposal goes through one policy grant and the audited tasks.update adapter.
  //     Only expose Undo when the agent proposed a real change from the current status.
  //     REAL change from the current 'pending'; re-affirming pending is a no-op, so
  //     previous_status stays null (no spurious Undo affordance).
  const previousStatus = observedTask.status ?? 'pending';
  const willApply = agentResult.proposedStatus !== previousStatus;
  const appliedStatus = willApply ? agentResult.proposedStatus : null;
  const commentPreviousStatus = willApply ? previousStatus : null;
  const runStatus = terminalRunStatus(agentResult.proposedStatus);

  try {
    const execution = await statusExecutor.execute({
      userId: observedTask.userId,
      taskId: observedTask.id,
      status: agentResult.proposedStatus,
      sessionKey,
      proposalRunId: agentResult.proposalRunId,
      toolCallId: agentResult.toolCallId,
      externalContentInfluenced: agentResult.externalContentInfluenced,
      productCompletion: {
        expectedStatus: previousStatus,
        expectedTaskUpdatedAt,
        expectedCommentCount: gathered.totalCount,
        expectedChatMessageCount: gathered.chatMessageCount,
        runStatus,
        runBlockCode: null,
        runBlockMode: null,
        commentBody: agentResult.reply,
        authorLabel: 'Rem Orchestrator',
        proposedStatus: agentResult.proposedStatus,
        previousStatus: commentPreviousStatus,
        runtime: 'rem_runtime',
        sessionId: sessionKey,
        taskContext: agentResult.taskContext,
        transcript: {
          runId,
          ask: sweepTranscriptAsk(observedTask),
          reply: agentResult.reply,
        },
      },
    });
    if (execution.kind !== 'succeeded') {
    // A pending/conflicting effect has an unresolved durable identity. Keep the claim; stale
    // recovery also checks the effect ledger and cannot release it until reconciliation reaches
    // a terminal state. Every other result proves no task mutation committed and is safe to retry.
      if (!['effect_pending', 'execution_conflict'].includes(execution.reason)) {
        await releaseClaim(observedTask, runId).catch(() => {});
      }
      return {
        ...base,
        status: 'skipped_runtime',
        appliedStatus: null,
        commentId: null,
        reason: execution.reason,
      };
    }
    return {
      ...base,
      status: 'executed',
      appliedStatus: appliedStatus ?? null,
      commentId: execution.comment?.id?.toString() ?? null,
      reason: null,
    };
  } catch (error: unknown) {
    // A transport error after effect admission can be ambiguous. Keep the task claim so the
    // next tick cannot create a second identity; stale recovery and effect reconciliation own it.
    const message = error instanceof Error ? error.message : String(error);
    return { ...base, status: 'skipped_runtime', appliedStatus: null, commentId: null, reason: `error: ${message}` };
  }
}

/** Run `fn` inside a BEGIN/COMMIT, rolling back (and rethrowing) on any error. */
async function runInTransaction<T>(fn: (db: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const value = await fn(client);
    await client.query('COMMIT');
    return value;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

/** Read a task's prior comments for agent context (read-only, capped). */
async function gatherComments(taskId: string, userId: string): Promise<{
  context: ReadyTaskComment[];
  totalCount: number;
  chatMessageCount: number;
}> {
  const result = await pool.query(
    `SELECT
       COALESCE((
         SELECT JSON_AGG(row_to_json(comment_rows) ORDER BY comment_rows.created_at)
           FROM (
             SELECT author_kind, author_label, body, created_at
               FROM task_comments
              WHERE task_id = $1::uuid AND user_id = $2::uuid
              ORDER BY created_at DESC
              LIMIT 50
           ) AS comment_rows
       ), '[]'::json) AS comments,
       (SELECT COUNT(*)::int FROM task_comments
         WHERE task_id = $1::uuid AND user_id = $2::uuid) AS comment_count,
       COALESCE((
         SELECT JSON_AGG(row_to_json(chat_rows) ORDER BY chat_rows.seq)
           FROM (
             SELECT role, content, seq, created_at
               FROM task_chat_messages
              WHERE task_id = $1::uuid AND user_id = $2::uuid
              ORDER BY seq DESC
              LIMIT 40
           ) AS chat_rows
       ), '[]'::json) AS chat_messages,
       (SELECT COUNT(*)::int FROM task_chat_messages
         WHERE task_id = $1::uuid AND user_id = $2::uuid) AS chat_message_count`,
    [taskId, userId],
  );
  const row = result.rows[0] ?? {};
  const comments = Array.isArray(row.comments) ? row.comments : [];
  const chatMessages = Array.isArray(row.chat_messages) ? row.chat_messages : [];
  const context = [
    ...comments.map((r: any, index: number) => ({
      author_kind: r.author_kind ?? null,
      author_label: r.author_label ?? null,
      body: r.body ?? null,
      occurredAt: r.created_at,
      tieBreak: index,
    })),
    ...chatMessages.map((r: any) => ({
      author_kind: r.role === 'user' ? 'user' : 'cloud_agent',
      author_label: r.role === 'user' ? 'You (task chat)' : 'Rem (task chat)',
      body: r.content ?? null,
      occurredAt: r.created_at,
      tieBreak: Number(r.seq ?? 0) + 10_000,
    })),
  ].sort((left, right) => {
    const byTime = new Date(left.occurredAt ?? 0).getTime() - new Date(right.occurredAt ?? 0).getTime();
    return byTime || left.tieBreak - right.tieBreak;
  });
  return {
    context: context.map(({ author_kind, author_label, body }) => ({
      author_kind,
      author_label,
      body,
    })),
    totalCount: Number(row.comment_count ?? 0),
    chatMessageCount: Number(row.chat_message_count ?? 0),
  };
}

/**
 * Sweep every ready task and run each autonomously. Never throws — a single task's
 * failure is isolated (mirrors run-routines.ts), so the cron always completes.
 */
export async function sweepReadyTasks(now: Date = new Date(), deps: SweepDeps = {}): Promise<SweepReport> {
  // Release any claim a crashed prior tick stranded 'running' before scanning, so a
  // mid-run crash can't keep a task out of `findReadyTasks` forever (H3).
  let reaped = 0;
  try {
    reaped = await reapStaleRunningClaims(now);
    if (reaped > 0) console.log(`[SWEEP] reaped ${reaped} stale running claim(s)`);
  } catch (error: unknown) {
    console.error('[SWEEP] reap failed (continuing):', error instanceof Error ? error.message : String(error));
  }

  const candidates = await findReadyTasks(now);
  const tasks = applyPerUserCap(candidates);

  const results: SweepTaskResult[] = [];
  for (const task of tasks) {
    try {
      results.push(await runReadyTask(task, now, deps));
    } catch (error: unknown) {
      // runReadyTask is never-throw by design; guard so one bad task can't abort the sweep.
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[SWEEP] task ${task.id} failed:`, message);
      results.push({
        taskId: task.id,
        userId: task.userId,
        status: 'skipped_runtime',
        appliedStatus: null,
        commentId: null,
        reason: `error: ${message}`,
      });
    }
  }

  const skippedRuntime = results.filter((r) => r.status === 'skipped_runtime').length;
  const skippedClaim = results.filter((r) => r.status === 'skipped_claim').length;
  return {
    scanned: tasks.length,
    executed: results.filter((r) => r.status === 'executed').length,
    denied: results.filter((r) => r.status === 'denied').length,
    skipped: skippedRuntime + skippedClaim,
    skippedRuntime,
    skippedClaim,
    reaped,
    results,
  };
}
