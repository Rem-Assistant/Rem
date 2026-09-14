/**
 * `tasks.description` — the DATABASE writers for the co-authored surface (migration 120).
 *
 * The merge itself is pure and lives in `./task-description.js` (read that file first —
 * it explains why the column is split by a delimiter at all). This file is only the part
 * that touches Postgres, kept separate so the prompt-building services can import the
 * merge without pulling a connection pool into their module graph.
 *
 * ATOMICITY. Both sides of the co-authorship are read-modify-write, so both take the SAME
 * row lock (`SELECT ... FOR UPDATE`) inside a transaction — the agent here, and the user
 * in `PATCH /tasks/:id`. Without the lock, a PATCH that read the row before an agent run
 * finished would write back the stale block and lose the agent's update (and vice versa):
 * the merge would be correct and the outcome still wrong.
 *
 * STALENESS. Writing the agent block deliberately does NOT reset the brief's nag counter
 * (migration 116). Rem writing to itself is not the user acting on a task — the same
 * reason the sweep's own comments don't reset it.
 */

import type { PoolClient } from 'pg';
import { pool } from '../db/pool.js';
import {
  appendGatheredItem,
  blankToNull,
  parseGatheredItems,
  setAgentContext,
  splitDescription,
} from './task-description.js';

/** Re-exported so a caller needing both the merge and a writer imports one module. */
export * from './task-description.js';

/**
 * Write the agent's half of a task description, inside the caller's transaction.
 *
 * A blank `agentContext` is a NO-OP, not a clear: a run that produced no summary has no
 * news, and "no news" must not erase what a previous run learned. Returns the stored
 * description after the write, or null when the task does not exist / nothing was written.
 *
 * Bumps `updated_at`, so the device's `GET /tasks?since=` delta sync actually picks the
 * new context up. Does not touch `stale_at` / `brief_surface_count` — see the file header.
 */
export async function writeAgentTaskContext(
  db: PoolClient,
  taskId: string,
  userId: string,
  agentContext: string | null | undefined,
): Promise<string | null> {
  const incoming = blankToNull(agentContext);
  if (!incoming) return null;

  const current = await db.query(
    `SELECT description FROM tasks WHERE id = $1::uuid AND user_id = $2::uuid FOR UPDATE`,
    [taskId, userId],
  );
  if (current.rows.length === 0) return null;

  const merged = setAgentContext(current.rows[0].description, incoming);
  const updated = await db.query(
    `UPDATE tasks SET description = $1, updated_at = NOW()
      WHERE id = $2::uuid AND user_id = $3::uuid
      RETURNING description`,
    [merged, taskId, userId],
  );
  return updated.rows[0]?.description ?? null;
}

/**
 * `writeAgentTaskContext` in its own transaction, for callers that are not already in one.
 * Never throws: a run that succeeded must not be reported as failed because the
 * bookkeeping write lost a race — the comment is the durable record either way.
 */
export async function applyAgentTaskContext(
  taskId: string,
  userId: string,
  agentContext: string | null | undefined,
): Promise<string | null> {
  if (!blankToNull(agentContext)) return null;
  let client: PoolClient | undefined;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    const result = await writeAgentTaskContext(client, taskId, userId, agentContext);
    await client.query('COMMIT');
    return result;
  } catch (error: unknown) {
    await client?.query('ROLLBACK').catch(() => {});
    const message = error instanceof Error ? error.message : String(error);
    console.error('[TASK-DESCRIPTION] failed to write agent context:', message);
    return null;
  } finally {
    client?.release();
  }
}

// ---------------------------------------------------------------------------
// Aggregation writers (#1369, #1374) — the DB side of the gathered region
// ---------------------------------------------------------------------------

/** One aggregated item to fold into a parent's gathered region. */
export interface GatheredTaskItemInput {
  /** `channel_signals.id` — the idempotency + completion handle. */
  signalId: string;
  /** Source slug for attribution. */
  source: string;
  /** The human line. */
  text: string;
}

/** Transaction-owned variant used when signal fencing and the task mutation must commit together. */
export async function writeGatheredTaskItem(
  db: PoolClient,
  taskId: string,
  userId: string,
  input: GatheredTaskItemInput,
): Promise<boolean> {
  const signalId = String(input.signalId ?? '').replace(/[^A-Za-z0-9-]/g, '');
  if (!signalId) return false;
  const current = await db.query(
    `SELECT description, type FROM tasks
      WHERE id = $1::uuid AND user_id = $2::uuid FOR UPDATE`,
    [taskId, userId],
  );
  if (current.rows.length === 0 || current.rows[0].type !== 'task') return false;
  const stored: string | null = current.rows[0].description ?? null;
  const merged = appendGatheredItem(stored, {
    signalId,
    source: input.source,
    text: input.text,
    done: false,
  });
  const present = parseGatheredItems(splitDescription(merged).gathered).some(
    (it) => it.signalId === signalId,
  );
  if (merged !== stored) {
    await db.query(
      `UPDATE tasks SET description = $1, updated_at = NOW()
        WHERE id = $2::uuid AND user_id = $3::uuid`,
      [merged, taskId, userId],
    );
  }
  return present;
}

/**
 * Fold an aggregated item into a PARENT TASK's gathered region, inside its own transaction.
 * Never throws.
 *
 * PARENT-ELIGIBILITY GUARD, at the write boundary: only `type = 'task'` rows are parents. A
 * calendar event, a synced mirror, or a missing row is refused here even if the model named its
 * index — you cannot append to (or complete) something Rem does not own. Returns TRUE when the item
 * is present in the parent afterwards (a fresh append OR an idempotent no-op for a signal already
 * there), FALSE when the parent was ineligible or the gathered cap left no room. The relevance pass
 * reads FALSE as "fall back to a new task", so a refused append never loses the signal.
 *
 * Takes the SAME row lock as `writeAgentTaskContext` and the user PATCH, so a concurrent edit
 * cannot read-modify-write over the gathered region.
 */
export async function applyGatheredTaskItem(
  taskId: string,
  userId: string,
  input: GatheredTaskItemInput,
): Promise<boolean> {
  const signalId = String(input.signalId ?? '').replace(/[^A-Za-z0-9-]/g, '');
  if (!signalId) return false;
  let client: PoolClient | undefined;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    const present = await writeGatheredTaskItem(client, taskId, userId, input);
    if (!present) {
      await client.query('ROLLBACK');
      return false;
    }
    await client.query('COMMIT');
    return present;
  } catch (error: unknown) {
    await client?.query('ROLLBACK').catch(() => {});
    console.error(
      '[TASK-DESCRIPTION] failed to append gathered item:',
      error instanceof Error ? error.name : String(error),
    );
    return false;
  } finally {
    client?.release();
  }
}

/** What a completion signal supplies when it closes a parent task. */
export interface TaskCompletionInput {
  signalId: string;
  source: string;
  /** Why it closed — the model's "what was done". A default is used when null. */
  reason: string | null;
  /** Runtime that made the judgment; legacy callers retain gateway attribution by default. */
  runtime?: 'gateway' | 'rem_runtime';
}

/** Transaction-owned variant used when signal fencing and task completion must commit together. */
export async function writeTaskCompletionFromSignal(
  db: PoolClient,
  taskId: string,
  userId: string,
  input: TaskCompletionInput,
): Promise<boolean> {
  const current = await db.query(
    `SELECT status, type, description FROM tasks
      WHERE id = $1::uuid AND user_id = $2::uuid FOR UPDATE`,
    [taskId, userId],
  );
  if (current.rows.length === 0 || current.rows[0].type !== 'task') return false;
  const previousStatus: string = current.rows[0].status ?? 'pending';
  if (previousStatus === 'completed' || previousStatus === 'cancelled') return false;

  const stored: string | null = current.rows[0].description ?? null;
  const signalId = String(input.signalId ?? '').replace(/[^A-Za-z0-9-]/g, '');
  const withSubitemDone = signalId
    ? (await import('./task-description.js')).markGatheredItemDone(stored, signalId)
    : stored;
  await db.query(
    `UPDATE tasks SET status = 'completed', description = $3, updated_at = NOW()
      WHERE id = $1::uuid AND user_id = $2::uuid`,
    [taskId, userId, withSubitemDone],
  );
  const reason = blankToNull(input.reason);
  const body = reason
    ? `Closed automatically — ${reason} (from ${input.source}).`
    : `Closed automatically — a ${input.source} update showed this was handled.`;
  await db.query(
    `INSERT INTO task_comments
       (task_id, user_id, author_kind, author_label, body, proposed_status, previous_status, runtime)
     VALUES ($1::uuid, $2::uuid, 'cloud_agent', 'Rem', $3, 'completed', $4, $5)`,
    [taskId, userId, body, previousStatus, input.runtime ?? 'gateway'],
  );
  return true;
}

/**
 * Close a PARENT TASK a downstream signal shows was handled (#1374), inside its own transaction.
 * Never throws.
 *
 * STRICT ON THE CLOSING SIDE — a wrong auto-close hides work the user still owes, so every guard
 * fails toward "leave it open":
 *   - only `type = 'task'` rows close (a calendar event / mirror is refused);
 *   - a task already `completed`/`cancelled` is a no-op (never re-closes, never rewrites Undo);
 *   - a missing row is a no-op.
 * Returns TRUE only when it actually moved an open task to completed. On a real close it also marks
 * the matching gathered SUBITEM done (if the signal was previously appended) and writes an
 * attributed `task_comments` row stamping `previous_status` for one-tap Undo — the same Undo
 * contract the run verdict uses.
 */
export async function applyTaskCompletionFromSignal(
  taskId: string,
  userId: string,
  input: TaskCompletionInput,
): Promise<boolean> {
  let client: PoolClient | undefined;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    const completed = await writeTaskCompletionFromSignal(client, taskId, userId, input);
    if (!completed) {
      await client.query('ROLLBACK');
      return false;
    }
    await client.query('COMMIT');
    return true;
  } catch (error: unknown) {
    await client?.query('ROLLBACK').catch(() => {});
    console.error(
      '[TASK-DESCRIPTION] failed to close task from signal:',
      error instanceof Error ? error.name : String(error),
    );
    return false;
  } finally {
    client?.release();
  }
}
