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
import { blankToNull, setAgentContext } from './task-description.js';

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
