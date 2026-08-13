/**
 * User memory — "What Rem remembers about you" (the simple "Dreaming" store).
 *
 * Each row is a single durable fact Rem keeps about the user. In this first slice the
 * list is entirely **user-managed**: the Settings screen adds / edits / deletes facts and
 * the backend Postgres `user_memory` table is the source of truth (same as tasks/digests),
 * so iOS and Mac render the identical list.
 *
 * Follow-up (NOT in this slice): auto-extraction — writing 2-3 facts after each chat/session
 * and stamping `source` (e.g. 'chat'/'session') for attribution. The schema and this service
 * already accept `source`, so the extractor only needs to call `addMemory(..., source)`.
 *
 * Mirrors the service-layer shape of digest.service.ts: a RETURNING column list, a `formatRow`
 * mapper, and thin functions that own the SQL. No ORM — raw parameterized queries.
 */

import { pool } from '../db/pool.js';
import {
  classifyVolatileFact,
  isMachineMemorySource,
  VolatileMemoryRejectedError,
} from './volatile-runtime-facts.service.js';

// Re-exported so callers keep importing memory errors from the memory service.
export { VolatileMemoryRejectedError } from './volatile-runtime-facts.service.js';

export interface MemoryRow {
  id: string;
  fact: string;
  source: string | null;
  created_at: string | null;
  updated_at: string | null;
}

/** Max length of a single fact — keeps the list scannable and bounds storage. */
export const MEMORY_FACT_MAX_LENGTH = 1000;

export const MEMORY_RETURNING = 'id, fact, source, created_at, updated_at';

export function formatMemory(row: any): MemoryRow {
  return {
    id: row.id.toString(),
    fact: row.fact,
    source: row.source ?? null,
    created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
    updated_at: row.updated_at ? new Date(row.updated_at).toISOString() : null,
  };
}

/** Validate + normalize a fact string. Returns the trimmed value or throws. */
export function normalizeFact(raw: unknown): string {
  if (typeof raw !== 'string') {
    throw new MemoryValidationError('fact is required and must be a string');
  }
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    throw new MemoryValidationError('fact cannot be empty');
  }
  if (trimmed.length > MEMORY_FACT_MAX_LENGTH) {
    throw new MemoryValidationError(`fact must be ${MEMORY_FACT_MAX_LENGTH} characters or fewer`);
  }
  return trimmed;
}

/** Normalize an optional source string (null when absent/blank). */
export function normalizeSource(raw: unknown): string | null {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== 'string') {
    throw new MemoryValidationError('source must be a string when provided');
  }
  const trimmed = raw.trim();
  return trimmed.length === 0 ? null : trimmed;
}

/** List a user's facts, newest first. */
export async function listMemories(userId: string): Promise<MemoryRow[]> {
  const result = await pool.query(
    `SELECT ${MEMORY_RETURNING} FROM user_memory
      WHERE user_id = $1::uuid
      ORDER BY created_at DESC`,
    [userId],
  );
  return result.rows.map(formatMemory);
}

/**
 * "Last refreshed" read-model for the Memory screen. The scheduled extractor (see
 * src/scripts/extract-memories.ts) writes facts with source='auto'; surfacing these timestamps
 * lets the app say "Rem last updated this on …" so the auto-schedule is visible to the user.
 *
 *  - lastUpdatedAt:       most recent change to ANY fact (created or edited), or null when empty.
 *  - lastAutoExtractedAt: most recent auto-extracted fact, or null if none yet — drives the
 *                         "Rem refreshes this automatically" affordance specifically.
 */
export interface MemoryFreshness {
  lastUpdatedAt: string | null;
  lastAutoExtractedAt: string | null;
}

export async function getMemoryFreshness(userId: string): Promise<MemoryFreshness> {
  const result = await pool.query(
    `SELECT
        MAX(GREATEST(created_at, updated_at)) AS last_updated_at,
        MAX(created_at) FILTER (WHERE source = 'auto') AS last_auto_extracted_at
       FROM user_memory
      WHERE user_id = $1::uuid`,
    [userId],
  );
  const row = result.rows[0] ?? {};
  return {
    lastUpdatedAt: row.last_updated_at ? new Date(row.last_updated_at).toISOString() : null,
    lastAutoExtractedAt: row.last_auto_extracted_at
      ? new Date(row.last_auto_extracted_at).toISOString()
      : null,
  };
}

/**
 * Add a fact for a user. Returns the stored row.
 *
 * Machine-written facts (`source` in MACHINE_MEMORY_SOURCES) are screened for VOLATILE runtime
 * claims and rejected — the surface/channel this conversation arrived on, what Rem can or
 * cannot do, connection or pairing state (#1282/#1277). Those are regenerated every session by
 * the gateway bootstrap hook; a stored copy outlives the truth and then overrides a correct
 * prompt indefinitely, which is exactly how Rem came to tell a native iOS user it was "WebChat".
 *
 * The screen lives at the STORE boundary, not only in the extractor, so it covers every machine
 * producer — the nightly pass, native OpenClaw dreaming, and anything added later — rather than
 * the one path that happens to exist today.
 *
 * User-typed facts (no source) are never screened. It is the user's list; if they want to write
 * something about the runtime down, that is their call.
 */
export async function addMemory(
  userId: string,
  fact: string,
  source: string | null = null,
): Promise<MemoryRow> {
  if (isMachineMemorySource(source)) {
    const verdict = classifyVolatileFact(fact);
    if (verdict.volatile) {
      throw new VolatileMemoryRejectedError(verdict.category ?? 'surface', verdict.rule ?? 'unknown');
    }
  }

  const result = await pool.query(
    `INSERT INTO user_memory (user_id, fact, source)
     VALUES ($1::uuid, $2, $3)
     RETURNING ${MEMORY_RETURNING}`,
    [userId, fact, source],
  );
  return formatMemory(result.rows[0]);
}

/**
 * Update a fact (scoped to the user). Returns the updated row, or null if no row with
 * that id belongs to the user.
 */
export async function updateMemory(
  userId: string,
  id: string,
  fact: string,
): Promise<MemoryRow | null> {
  const result = await pool.query(
    `UPDATE user_memory
        SET fact = $1, updated_at = NOW()
      WHERE id = $2::uuid AND user_id = $3::uuid
      RETURNING ${MEMORY_RETURNING}`,
    [fact, id, userId],
  );
  return result.rows.length ? formatMemory(result.rows[0]) : null;
}

/** Delete a fact (scoped to the user). Returns true if a row was deleted. */
export async function deleteMemory(userId: string, id: string): Promise<boolean> {
  const result = await pool.query(
    `DELETE FROM user_memory WHERE id = $1::uuid AND user_id = $2::uuid RETURNING id`,
    [id, userId],
  );
  return result.rows.length > 0;
}

export class MemoryValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'MemoryValidationError';
  }
}
