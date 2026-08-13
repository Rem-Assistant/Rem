/**
 * routine-schedule.service — CRUD for `routine_schedules` (migration 017).
 *
 * A routine is an existing task that does work on a cadence. This service owns the
 * persistence lifecycle (create / read / update / setEnabled / delete / stampLastRun);
 * the per-user-timezone due-check is the already-shipped pure resolver in
 * `routine-schedule.ts` (isDailyRoutineDue), and the runner that ties them together
 * is the next stage. See docs/rebuild/10-ROUTINES-DESIGN.md.
 *
 * Mirrors digest.service.ts conventions: raw parameterized SQL via the shared pool,
 * a RETURNING column list, and a row→domain `formatRoutine` projection. All pure
 * shaping helpers (formatRoutine, buildUpdateAssignments, buildRunReport) are exported
 * so they're unit-testable without a database.
 *
 * Scheduling is backend-driven (NOT gateway cron): the `routine_schedules` row is the
 * sole source of truth, and an external scheduler (Railway cron) runs
 * `src/scripts/run-routines.ts`, which selects due routines and calls
 * routine-runner.service.runRoutine. CRUD therefore performs NO gateway sync on write —
 * it just persists the canonical row. (Replaces the deleted routine-cron.service.ts,
 * which registered a per-routine job on the user's gateway.)
 */

import { pool } from '../db/pool.js';
import {
  AUTONOMY_MAX,
  type RoutineSchedule,
  type RunConfidence,
  type RunReport,
} from './routine.types.js';

/** Columns returned by every routine query, in RoutineSchedule order. */
export const ROUTINE_RETURNING =
  'id, user_id, task_id, cadence, delivery_hour, timezone, prompt, autonomy, model, enabled, last_run_at, created_at';

function toIso(value: unknown): string | null {
  if (!value) return null;
  const d = value instanceof Date ? value : new Date(value as string);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** Project a routine_schedules row into the camelCase domain shape. Pure. */
export function formatRoutine(row: any): RoutineSchedule {
  return {
    id: row.id.toString(),
    userId: row.user_id.toString(),
    taskId: row.task_id.toString(),
    cadence: row.cadence,
    deliveryHour: Number(row.delivery_hour),
    timezone: row.timezone,
    prompt: row.prompt ?? null,
    autonomy: Number(row.autonomy),
    model: row.model ?? null,
    enabled: Boolean(row.enabled),
    lastRunAt: toIso(row.last_run_at),
    createdAt: toIso(row.created_at),
  };
}

/** Fields accepted when creating a routine. Defaults are applied in createRoutine. */
export interface CreateRoutineInput {
  taskId: string;
  cadence?: RoutineSchedule['cadence'];
  deliveryHour: number;
  timezone: string;
  prompt?: string | null;
  autonomy?: number;
  model?: string | null;
  enabled?: boolean;
}

/** Fields that may be patched on an existing routine. All optional. */
export type UpdateRoutineInput = Partial<{
  cadence: RoutineSchedule['cadence'];
  deliveryHour: number;
  timezone: string;
  prompt: string | null;
  autonomy: number;
  model: string | null;
  enabled: boolean;
}>;

/** camelCase update field → column name. Order also defines the SET clause order. */
const UPDATE_COLUMNS: Array<[keyof UpdateRoutineInput, string]> = [
  ['cadence', 'cadence'],
  ['deliveryHour', 'delivery_hour'],
  ['timezone', 'timezone'],
  ['prompt', 'prompt'],
  ['autonomy', 'autonomy'],
  ['model', 'model'],
  ['enabled', 'enabled'],
];

/**
 * Build the `col = $n` assignments + ordered values for a dynamic UPDATE, starting
 * placeholders at `startIndex`. Skips fields not present in `updates` (undefined),
 * so `null` is a valid value (clears prompt/model). Pure — no DB.
 */
export function buildUpdateAssignments(
  updates: UpdateRoutineInput,
  startIndex = 1,
): { assignments: string[]; values: any[] } {
  const assignments: string[] = [];
  const values: any[] = [];
  for (const [key, column] of UPDATE_COLUMNS) {
    if (updates[key] === undefined) continue;
    values.push(updates[key]);
    assignments.push(`${column} = $${startIndex + values.length - 1}`);
  }
  return { assignments, values };
}

/**
 * Shape a structured RunReport for one routine execution. Pure. `needsReview` is
 * true when confidence is Low (the doc's confidence gate — Low never auto-acts) or
 * when the run wants to write above its autonomy level (L0–L1 are read-only/plan).
 */
export function buildRunReport(params: {
  routineId: string;
  timestamp: Date;
  sources: string[];
  writes: string[];
  confidence: RunConfidence;
  autonomyLevel: number;
}): RunReport {
  const wantsToWrite = params.writes.length > 0;
  const canExecute = params.autonomyLevel >= 3; // L3+ may execute pre-authorized categories
  const needsReview =
    params.confidence === 'low' || (wantsToWrite && !canExecute);
  return {
    timestamp: params.timestamp.toISOString(),
    routineId: params.routineId,
    sources: params.sources,
    writes: params.writes,
    confidence: params.confidence,
    autonomyLevel: params.autonomyLevel,
    needsReview,
  };
}

/** Create a routine for a user, applying column defaults. Returns the stored row. */
export async function createRoutine(
  userId: string,
  input: CreateRoutineInput,
): Promise<RoutineSchedule> {
  const result = await pool.query(
    `INSERT INTO routine_schedules
       (user_id, task_id, cadence, delivery_hour, timezone, prompt, autonomy, model, enabled)
     VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8, $9)
     RETURNING ${ROUTINE_RETURNING}`,
    [
      userId,
      input.taskId,
      input.cadence ?? 'daily',
      input.deliveryHour,
      input.timezone,
      input.prompt ?? null,
      Math.min(Math.max(input.autonomy ?? 1, 0), AUTONOMY_MAX),
      input.model ?? null,
      input.enabled ?? true,
    ],
  );
  // No gateway-cron sync: the backend scheduler (run-routines.ts) reads this row.
  return formatRoutine(result.rows[0]);
}

/** List a user's routines, newest first. */
export async function listRoutinesByUser(userId: string): Promise<RoutineSchedule[]> {
  const result = await pool.query(
    `SELECT ${ROUTINE_RETURNING} FROM routine_schedules
      WHERE user_id = $1::uuid
      ORDER BY created_at DESC`,
    [userId],
  );
  return result.rows.map(formatRoutine);
}

/** Fetch one routine scoped to the user, or null. */
export async function getRoutine(
  userId: string,
  id: string,
): Promise<RoutineSchedule | null> {
  const result = await pool.query(
    `SELECT ${ROUTINE_RETURNING} FROM routine_schedules
      WHERE id = $1::uuid AND user_id = $2::uuid`,
    [id, userId],
  );
  return result.rows.length ? formatRoutine(result.rows[0]) : null;
}

/**
 * Fetch one routine by id alone (NOT user-scoped), or null. Used by system-scoped
 * callers that hold no user JWT — the backend scheduler (run-routines.ts) and the
 * internal webhook (internal-routines.routes.ts), which carry only the routine id and
 * resolve the owning user from the row itself. Those callers are authenticated out of
 * band (scheduler runs in-process; webhook uses the shared secret); this loader performs
 * no authorization on its own.
 */
export async function getRoutineById(id: string): Promise<RoutineSchedule | null> {
  const result = await pool.query(
    `SELECT ${ROUTINE_RETURNING} FROM routine_schedules WHERE id = $1::uuid`,
    [id],
  );
  return result.rows.length ? formatRoutine(result.rows[0]) : null;
}

/** Patch a routine (scoped to the user). No-op patch returns the current row. */
export async function updateRoutine(
  userId: string,
  id: string,
  updates: UpdateRoutineInput,
): Promise<RoutineSchedule | null> {
  const { assignments, values } = buildUpdateAssignments(updates);
  if (assignments.length === 0) return getRoutine(userId, id);

  const idIndex = values.length + 1;
  const userIndex = values.length + 2;
  values.push(id, userId);

  const result = await pool.query(
    `UPDATE routine_schedules SET ${assignments.join(', ')}
      WHERE id = $${idIndex}::uuid AND user_id = $${userIndex}::uuid
      RETURNING ${ROUTINE_RETURNING}`,
    values,
  );
  if (!result.rows.length) return null;
  // No gateway-cron re-sync: the scheduler always reads the latest row at run time.
  return formatRoutine(result.rows[0]);
}

/** Enable/pause a routine (scoped to the user). */
export async function setRoutineEnabled(
  userId: string,
  id: string,
  enabled: boolean,
): Promise<RoutineSchedule | null> {
  const result = await pool.query(
    `UPDATE routine_schedules SET enabled = $3
      WHERE id = $1::uuid AND user_id = $2::uuid
      RETURNING ${ROUTINE_RETURNING}`,
    [id, userId, enabled],
  );
  if (!result.rows.length) return null;
  // enable → the scheduler starts running it; disable → the scheduler skips it
  // (run-routines.ts filters `enabled = TRUE`). No gateway-cron job to pause.
  return formatRoutine(result.rows[0]);
}

/** Delete a routine (scoped to the user). Returns true when a row was removed. */
export async function deleteRoutine(userId: string, id: string): Promise<boolean> {
  const result = await pool.query(
    `DELETE FROM routine_schedules WHERE id = $1::uuid AND user_id = $2::uuid RETURNING id`,
    [id, userId],
  );
  // Deleting the row is sufficient: the backend scheduler only sees existing rows.
  return result.rows.length > 0;
}

/**
 * Stamp last_run_at after the runner executes a routine. System-scoped (called by
 * the scheduler, not a user request), so it's keyed by id alone. Returns the
 * updated row, or null if the routine no longer exists.
 */
export async function stampLastRun(
  id: string,
  at: Date,
): Promise<RoutineSchedule | null> {
  const result = await pool.query(
    `UPDATE routine_schedules SET last_run_at = $2::timestamptz
      WHERE id = $1::uuid
      RETURNING ${ROUTINE_RETURNING}`,
    [id, at.toISOString()],
  );
  return result.rows.length ? formatRoutine(result.rows[0]) : null;
}
