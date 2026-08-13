/**
 * orchestrator-sweep — the "brief that ACTS" (#922). A backend-scheduled sweep that
 * finds tasks which are READY TO RUN and runs each one AUTONOMOUSLY through the user's
 * own OpenClaw gateway (Move-2 / AgentBox-drop, gateway-agent.service.ts), then applies
 * the resulting status and leaves an attributed Activity comment — so the brief/check-in
 * that reads `task_comments` reports "here's your state and I've already started handling
 * it" with no extra wiring.
 *
 * This is MULTI-CHAT, not multi-agent: ONE gateway 'main' agent, one SESSION per task
 * (a stable `sessionKey` = `rem-task-<taskId>`). We never spawn multiple agents.
 *
 * SAFETY — the sweep is deliberately reversible (mirrors #895):
 *   - The autonomous turn is RESTRICTED to read-only + drafting work (research, look up,
 *     summarize, draft/prepare). The prompt forbids any external/irreversible write —
 *     no sending email/messages, no create/modify/delete of calendar events, reminders,
 *     contacts or files, no money, no sharing changes. A task that REQUIRES such a write
 *     returns `proposed_status: blocked` and is left for the user to run with one tap.
 *     Because the turn performs no external writes, the ONLY state the sweep mutates is
 *     `tasks.status` (+ an attributed comment) — and that IS fully reversible by Undo.
 *   - Apply-with-Undo: when the agent decides a new status, we APPLY it to `tasks.status`
 *     and record the PRE-change value on the comment (`previous_status`, migration 028).
 *     The status change + the comment/Undo record are written in ONE transaction, so a
 *     comment-write failure can never leave the status changed with no record. The
 *     existing iOS/Mac UI renders "Applied: <status>" + Undo off that field with NO
 *     client change (Shared/Models/TaskCollaboration.swift `didApplyStatus`).
 *   - Deny-list screen: the same hard deny list the routine runner uses (routine-
 *     governance.ts) screens each task's title + DESCRIPTION + thread BEFORE any gateway
 *     turn — "send email", "wire money", "delete …" never auto-run; they're recorded
 *     blocked-for-review instead. This is defense-in-depth on top of the restricted
 *     prompt. The screen must cover EVERYTHING `buildSweepMessage` injects, including the
 *     agent's own prior `task_context`, or run 1 can write an instruction run 2 obeys.
 *   - Off by default: the sweep only runs when `ORCHESTRATOR_SWEEP_ENABLED` is truthy, so
 *     fleet-wide autonomous execution is behind an explicit opt-in kill-switch (M5).
 *   - The gateway session IS the transcript (Move-2): the run persists to a loadable chat
 *     the user can open — the comment carries the gateway `sessionKey` in `session_id`, so
 *     tapping the Activity row opens the REAL conversation (not an empty composer).
 *
 * DEGRADE GRACEFULLY: no gateway / wake failed / timeout / gateway error → the task's
 * claim is RELEASED (run_status back to NULL) and it is skipped, to be retried on a
 * later tick. Never throws past `sweepReadyTasks`, so a flaky gateway can't crash the
 * cron (mirrors run-routines.ts per-item isolation).
 *
 * Lifecycle / source of truth (principle 3):
 *   - Source of truth for status: `tasks.status`. Undo target: `task_comments.previous_status`.
 *   - claim   : `run_status` NULL → 'running' (atomic, so two ticks can't double-run one task).
 *   - apply   : gateway ok → terminal `run_status` (done/review/blocked) [+ `status` when the
 *               agent proposed a real change] + an attributed comment carrying `previous_status`,
 *               all in ONE transaction.
 *   - release : gateway failure (or a write error) → `run_status` back to NULL (retry next tick).
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

import { pool } from '../db/pool.js';
import type { PoolClient } from 'pg';
import { runAgentTurnOnGateway } from './gateway-agent.service.js';
import {
  TASK_VERDICT_PROMPT,
  readVerdictFromReply,
  readVerdictFromToolCalls,
  type ProposedStatus,
} from './task-verdict.js';
import { screenForDeniedAction, describeDenyCategory } from './routine-governance.js';
import { resolveModelRuntimeMode, type RunBlock } from './run-block.js';
import {
  TASK_CONTEXT_PROMPT,
  parseTaskContextFromText,
  runCommentBody,
  splitDescription,
  writeAgentTaskContext,
} from './task-description.service.js';

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
  | 'executed' // gateway ran the task autonomously; status applied + comment written
  | 'denied' // hard deny-list hit → recorded blocked-for-review, never dispatched
  | 'skipped_gateway' // no gateway / wake failed / timeout / error → claim released, retry later
  | 'skipped_claim'; // another worker already claimed this task this tick

export interface SweepTaskResult {
  taskId: string;
  userId: string;
  status: SweepTaskStatus;
  /** Applied task status (executed path with a real change), else null. */
  appliedStatus: ProposedStatus | null;
  /** id of the task_comment written this run, or null when none was written. */
  commentId: string | null;
  /** Structured reason on a non-executed path (gateway reason / deny categories). */
  reason: string | null;
}

export interface SweepReport {
  scanned: number;
  executed: number;
  denied: number;
  /** Total skipped (gateway failure + claim contention) — for the log summary. */
  skipped: number;
  /** Skipped because the gateway failed / a write errored — retryable, a real miss. */
  skippedGateway: number;
  /** Skipped because another worker already held the claim — NOT a failure (L8). */
  skippedClaim: number;
  /** Stale 'running' claims released at the top of this sweep (crashed prior ticks). */
  reaped: number;
  results: SweepTaskResult[];
}

/**
 * The gateway turn, behind an injectable seam so the sweep is testable without the
 * network. Returns the agent's prose reply + the structured status it marked (parsed
 * from the controlled `proposed_status:` marker line — the same machine marker #895's
 * GMI path uses, NOT free-prose scraping).
 */
export interface ReadyTaskAgentInput {
  task: ReadyTask;
  comments: ReadyTaskComment[];
  sessionKey: string;
}
export type ReadyTaskAgentResult =
  | {
      ok: true;
      reply: string;
      proposedStatus: ProposedStatus | null;
      /** Current-state summary for `tasks.description`'s agent block (migration 120).
       *  null = the run said nothing new, which means keep what was already known. */
      taskContext?: string | null;
    }
  | { ok: false; reason: string };
export interface ReadyTaskAgentRunner {
  run(input: ReadyTaskAgentInput): Promise<ReadyTaskAgentResult>;
}

export interface SweepDeps {
  agent?: ReadyTaskAgentRunner;
  screen?: typeof screenForDeniedAction;
}

/** Global cap per sweep tick — bounds gateway load if a backlog of tasks comes due. */
export const MAX_TASKS_PER_SWEEP = 100;
/** Per-user cap per tick — one noisy user can't monopolize the sweep. */
export const MAX_TASKS_PER_USER = 3;
/** How far back a due task stays eligible — avoids auto-running long-forgotten tasks. */
export const READY_LOOKBACK_DAYS = 7;
/**
 * A 'running' claim older than this is treated as ORPHANED (its tick crashed between
 * claim and terminal) and released back to NULL. Comfortably larger than a single run's
 * worst case (gateway wake + a 120s turn + writes), and larger than the 15-min cron
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
 * Execute-directive framing for the autonomous turn. Unlike the routine/agent-run PLAN
 * prompt ("what should happen next"), this tells the gateway agent to actually DO the
 * task now — but ONLY with read-only + drafting tools. It must NOT perform any external
 * or irreversible write (the sweep runs unattended, and the only reversal we have is a
 * status Undo), and it ends with the SAME machine verdict the manual run asks for —
 * `TASK_VERDICT_PROMPT`, one shared definition, so the two run paths cannot drift into
 * asking for different shapes (that drift is how `proposed_status:` ended up meaning three
 * things at once).
 */
const SWEEP_SYSTEM_PROMPT =
  'You are Rem running autonomously and UNATTENDED on the user\'s behalf. You are given a ' +
  'task the user scheduled and its prior comments. Work the task now using ONLY read-only ' +
  'and drafting tools — research, look things up, summarize, and draft or prepare content. ' +
  'You MUST NOT take any action that changes the outside world or that cannot be reversed ' +
  'by simply changing this task\'s status: do NOT send emails/messages, do NOT create, ' +
  'modify, or delete calendar events, reminders, contacts, or files, do NOT move money, and ' +
  'do NOT change sharing or permissions. If finishing the task REQUIRES any such external ' +
  'write, stop and report the status "blocked" so the user can run it themselves with one ' +
  'tap. Reply with 1-3 sentences describing exactly what you did or prepared (or why you are ' +
  'blocked). Choose "completed" when you fully finished it with read-only/drafting work, ' +
  '"in_progress" when you made progress but it is not done, and "blocked" when it needs an ' +
  'external write or an input only the user can provide. ' +
  TASK_CONTEXT_PROMPT +
  ' ' +
  TASK_VERDICT_PROMPT;

export function buildSweepMessage(task: ReadyTask, comments: ReadyTaskComment[]): string {
  const commentLines = comments.length
    ? comments
        .map((c) => `- [${c.author_label ?? c.author_kind ?? 'unknown'}]: ${c.body ?? ''}`)
        .join('\n')
    : '(no prior comments)';
  // The description (migration 120) is why an unattended run is not amnesiac. Its two
  // halves are labelled apart because only one is the agent's to rewrite.
  const description = splitDescription(task.description);
  return [
    SWEEP_SYSTEM_PROMPT,
    '',
    `TASK: ${task.title}`,
    `STATUS: ${task.status ?? 'pending'}`,
    task.priority ? `PRIORITY: ${task.priority}` : null,
    description.user
      ? `\nDESCRIPTION (written by the user — do not restate it as your own):\n${description.user}`
      : null,
    description.agent
      ? `\nCURRENT CONTEXT (what the last run recorded — your task_context REPLACES this):\n${description.agent}`
      : '\nCURRENT CONTEXT: (none recorded yet)',
    '',
    'PRIOR COMMENTS:',
    commentLines,
  ]
    .filter((l) => l !== null)
    .join('\n');
}

/** The stable gateway session key for a task's sweep run — a loadable chat (Move-2). */
export function taskSessionKey(taskId: string): string {
  // PostgreSQL UUID text is canonical lowercase, while a device can put an uppercase
  // UUID in the manual agent-run path. Gateway session keys are case-sensitive, so
  // normalize here or a pre-run device chat and the later cloud run split in two.
  return `rem-task-${taskId.trim().toLowerCase()}`;
}

/**
 * Default runner: one gateway turn per task via runAgentTurnOnGateway (Move-2). On any
 * gateway failure returns a structured `{ ok:false, reason }` so the caller releases the
 * claim and skips — it never falls back to a text-only path that cannot actually act.
 */
export const defaultReadyTaskAgentRunner: ReadyTaskAgentRunner = {
  async run({ task, comments, sessionKey }: ReadyTaskAgentInput): Promise<ReadyTaskAgentResult> {
    const result = await runAgentTurnOnGateway({
      userId: task.userId,
      sessionKey,
      message: buildSweepMessage(task, comments),
    });
    if (!result.ok) return { ok: false, reason: result.reason };
    // ONE verdict contract, shared with the manual run (`task-verdict.ts`): the agent's own
    // tool call when it made one, otherwise the versioned machine line. The regex this
    // replaced (`parseProposedStatusFromText`) matched `status:` anywhere in free prose, so
    // a sentence that merely discussed status was a status decision — on an AUTONOMOUS path
    // that then applied it to the user's task without anyone asking.
    // Both machine markers come out; a reply that was ONLY markers gets a plain sentence
    // rather than the raw text, which used to restore the markers into the activity feed.
    const fromEnvelope = readVerdictFromReply(result.text);
    const verdict = readVerdictFromToolCalls(result.toolCalls) ?? fromEnvelope.verdict;
    return {
      ok: true,
      reply: runCommentBody(fromEnvelope.body),
      proposedStatus: verdict?.status ?? null,
      // Read the legacy marker from the STRIPPED body: `parseTaskContextFromText` runs to
      // the next status marker or the end, so a verdict line below it would otherwise be
      // swallowed into the summary written to `tasks.description`.
      taskContext: verdict?.taskContext ?? parseTaskContextFromText(fromEnvelope.body),
    };
  },
};

/** Terminal run_status from the agent's proposed status (structured, not string-matched). */
function terminalRunStatus(proposed: ProposedStatus | null): 'done' | 'review' | 'blocked' {
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
    `UPDATE tasks
        SET run_status = NULL, run_id = NULL, run_started_at = NULL,
            run_last_heartbeat_at = NULL, updated_at = NOW()
      WHERE run_status = 'running'
        AND run_started_at IS NOT NULL
        AND run_started_at < $1::timestamptz - ($2 || ' minutes')::interval`,
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
 * gateway SESSION KEY (`rem-task-<taskId>`) — the real, loadable Move-2 chat — NOT the
 * backend claim runId, so tapping the Activity row opens the actual conversation the run
 * produced (the bug migration 025 documents). Runs on a caller-supplied client so it can
 * share a transaction with the status apply.
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
     VALUES ($1::uuid, $2::uuid, 'cloud_agent', $3, $4, $5, $6, 'gateway', $7, $8, $9)
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
 *   claim → deny-screen → gateway turn → apply-with-Undo (one txn) | release-and-skip.
 */
export async function runReadyTask(
  task: ReadyTask,
  now: Date,
  deps: SweepDeps = {},
): Promise<SweepTaskResult> {
  const agent = deps.agent ?? defaultReadyTaskAgentRunner;
  const screen = deps.screen ?? screenForDeniedAction;
  const runId =
    (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`);
  const sessionKey = taskSessionKey(task.id);
  const base = { taskId: task.id, userId: task.userId };

  // 1. Atomic claim: only ONE worker can flip run_status NULL → 'running'. The status
  //    guard also means a task that changed out of 'pending' since the scan is not run.
  const claim = await pool.query(
    `UPDATE tasks
        SET run_status = 'running', run_id = $1, run_started_at = NOW(),
            run_last_heartbeat_at = NOW(), updated_at = NOW()
      WHERE id = $2::uuid AND user_id = $3::uuid
        AND type = 'task' AND status = 'pending' AND run_status IS NULL`,
    [runId, task.id, task.userId],
  );
  if (claim.rowCount === 0) {
    return { ...base, status: 'skipped_claim', appliedStatus: null, commentId: null, reason: null };
  }

  // 2. Deny-list screen (SAFETY) — BEFORE any gateway turn. A task whose title/thread asks
  //    for a hard-denied action (send email, move money, delete data, change sharing) is
  //    NEVER auto-run; it's recorded blocked-for-review so the user handles it manually.
  //
  //    THE SCREEN MUST COVER EVERYTHING `buildSweepMessage` PUTS IN THE PROMPT. The
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
  const comments = await gatherComments(task.id);
  const screenText = [
    task.title,
    task.description ?? '',
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
    // tell it apart from a dead gateway without reading the sentence. The mode rides along for
    // contract uniformity even though this remedy ("run it yourself") does not depend on it.
    const denialBlock: RunBlock = {
      code: 'policy_blocked',
      mode: await resolveModelRuntimeMode(task.userId),
    };
    try {
      const commentId = await runInTransaction(async (db) => {
        await db.query(
          `UPDATE tasks SET run_status = 'blocked', run_block_code = $3, run_block_mode = $4,
                  run_last_heartbeat_at = NOW(), updated_at = NOW()
            WHERE id = $1::uuid AND user_id = $2::uuid`,
          [task.id, task.userId, denialBlock.code, denialBlock.mode],
        );
        return writeSweepComment(
          db, task, body, 'Rem Orchestrator (blocked)', null, null, sessionKey, denialBlock,
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
      await releaseClaim(task, runId).catch(() => {});
      const message = error instanceof Error ? error.message : String(error);
      return { ...base, status: 'skipped_gateway', appliedStatus: null, commentId: null, reason: `error: ${message}` };
    }
  }

  // 3. Run the task autonomously on the user's gateway.
  let agentResult: ReadyTaskAgentResult;
  try {
    agentResult = await agent.run({ task, comments, sessionKey });
  } catch (error: unknown) {
    // The runner is designed never to throw; guard anyway → treat as a gateway skip.
    const message = error instanceof Error ? error.message : String(error);
    agentResult = { ok: false, reason: `error: ${message}` };
  }

  // 4a. Gateway failure → RELEASE the claim (run_status back to NULL) and skip. No comment,
  //     no status change: the task is picked up again on a later tick when the gateway is up.
  if (!agentResult.ok) {
    await releaseClaim(task, runId);
    return { ...base, status: 'skipped_gateway', appliedStatus: null, commentId: null, reason: agentResult.reason };
  }

  // 4b. Gateway success → apply-with-Undo (#895). Only apply when the agent proposed a
  //     REAL change from the current 'pending'; re-affirming pending is a no-op, so
  //     previous_status stays null (no spurious Undo affordance).
  const previousStatus = task.status ?? 'pending';
  const willApply = agentResult.proposedStatus !== null && agentResult.proposedStatus !== previousStatus;
  const appliedStatus = willApply ? agentResult.proposedStatus : null;
  const commentPreviousStatus = willApply ? previousStatus : null;
  const runStatus = terminalRunStatus(agentResult.proposedStatus);

  // The terminal status apply AND the comment/Undo record are one transaction. If the
  // comment INSERT throws (e.g. a constraint), the status apply rolls back with it — so
  // we can never silently mutate status with no comment and no Undo record (C1).
  try {
    const commentId = await runInTransaction(async (db) => {
      // CLEAR the block pair (migration 121). Always NULL here, and that is not laziness:
      // this write is only reached when the gateway turn SUCCEEDED — a sweep whose turn fails
      // releases its claim and retries next tick (`releaseClaim`) rather than stamping a
      // terminal state, so there is no failure reason to record on this path.
      //
      // Clearing is nonetheless load-bearing, because the sweep can finish a run the MANUAL
      // dispatch started: `Run now` stamps a block, the process dies mid-flight,
      // `releaseStaleRunningClaims` resets `run_status` to NULL, and the sweep then picks the
      // task up and completes it. Without the NULL the task would report `done` while still
      // advertising "your runtime is unavailable" from the earlier attempt.
      await db.query(
        appliedStatus
          ? `UPDATE tasks
                SET run_status = $1, status = $2, run_block_code = NULL, run_block_mode = NULL,
                    run_last_heartbeat_at = NOW(), updated_at = NOW()
              WHERE id = $3::uuid AND user_id = $4::uuid`
          : `UPDATE tasks
                SET run_status = $1, run_block_code = NULL, run_block_mode = NULL,
                    run_last_heartbeat_at = NOW(), updated_at = NOW()
              WHERE id = $2::uuid AND user_id = $3::uuid`,
        appliedStatus
          ? [runStatus, appliedStatus, task.id, task.userId]
          : [runStatus, task.id, task.userId],
      );
      // THE RUN WRITES WHAT IT LEARNED (migration 120), in the SAME transaction as the
      // status apply and the comment — so an unattended run can never leave a description
      // claiming state the comment and status don't back up. Only the agent's delimited
      // block is rewritten; the user's own text is untouched, and a run that returned no
      // summary is a no-op rather than an erasure.
      await writeAgentTaskContext(db, task.id, task.userId, agentResult.taskContext);
      return writeSweepComment(
        db,
        task,
        agentResult.reply,
        'Rem Orchestrator',
        agentResult.proposedStatus,
        commentPreviousStatus,
        sessionKey,
      );
    });

    return {
      ...base,
      status: 'executed',
      appliedStatus: appliedStatus ?? null,
      commentId,
      reason: null,
    };
  } catch (error: unknown) {
    // Persisting the outcome failed atomically (nothing applied). Release the claim so the
    // task is retried next tick rather than stranded 'running' with no record.
    await releaseClaim(task, runId).catch(() => {});
    const message = error instanceof Error ? error.message : String(error);
    return { ...base, status: 'skipped_gateway', appliedStatus: null, commentId: null, reason: `error: ${message}` };
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
async function gatherComments(taskId: string): Promise<ReadyTaskComment[]> {
  const result = await pool.query(
    `SELECT author_kind, author_label, body
       FROM task_comments
      WHERE task_id = $1::uuid
      ORDER BY created_at ASC
      LIMIT 50`,
    [taskId],
  );
  return result.rows.map((r) => ({
    author_kind: r.author_kind ?? null,
    author_label: r.author_label ?? null,
    body: r.body ?? null,
  }));
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
        status: 'skipped_gateway',
        appliedStatus: null,
        commentId: null,
        reason: `error: ${message}`,
      });
    }
  }

  const skippedGateway = results.filter((r) => r.status === 'skipped_gateway').length;
  const skippedClaim = results.filter((r) => r.status === 'skipped_claim').length;
  return {
    scanned: tasks.length,
    executed: results.filter((r) => r.status === 'executed').length,
    denied: results.filter((r) => r.status === 'denied').length,
    skipped: skippedGateway + skippedClaim,
    skippedGateway,
    skippedClaim,
    reaped,
    results,
  };
}
