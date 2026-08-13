/**
 * Routine domain types — shared by the CRUD service (this stage) and the runner
 * job (next stage). A routine is an existing task that does work on a cadence;
 * see docs/rebuild/10-ROUTINES-DESIGN.md. The persisted shape lives in the
 * `routine_schedules` table (migration 017); `RoutineSchedule` is its camelCase
 * domain projection.
 */

/** Cadence a routine runs on. 'daily' is shipped; 'weekly'/'once' are reserved. */
export type RoutineCadence = 'daily' | 'weekly' | 'once';

/**
 * Autonomy ladder (the `autonomy` column). Mirrors the founder's Notion kernel
 * ladder + the OpenCode plan-vs-execute distinction (#797):
 *   L0 observe → L1 brief → L2 propose → L3 safe writes → L4 narrow auto-execute.
 * L0–L1 are read-only (plan); L3+ may execute pre-authorized categories.
 */
export const AUTONOMY_MIN = 0;
export const AUTONOMY_MAX = 4;

/** A routine_schedules row, projected to the camelCase domain shape. */
export interface RoutineSchedule {
  id: string;
  userId: string;
  taskId: string;
  cadence: RoutineCadence;
  /** Hour-of-day (0–23) in `timezone` when the routine should run. */
  deliveryHour: number;
  /** IANA timezone, e.g. "America/Los_Angeles". */
  timezone: string;
  /** Routine instruction; null = default Daily Context Farmer. */
  prompt: string | null;
  /** Autonomy ladder level (0–4). */
  autonomy: number;
  /** Explicitly-selected model (#808); null until one is chosen. */
  model: string | null;
  enabled: boolean;
  /** ISO-8601 of the last successful run, or null if never run. */
  lastRunAt: string | null;
  createdAt: string | null;
}

/** Confidence a run reached. High/Medium may act; Low surfaces to the user. */
export type RunConfidence = 'high' | 'medium' | 'low';

/**
 * Structured log emitted once per routine execution — Rem's AI Automation Log
 * (doc 10, "Governance"). The health-check for whether a run behaved: what it
 * read, what it wrote, how sure it was, and whether a human must review it.
 */
export interface RunReport {
  /** ISO-8601 of when the run executed. */
  timestamp: string;
  /** The routine that produced this report. */
  routineId: string;
  /** Context sources consulted (e.g. 'task', 'comments', 'calendar'). */
  sources: string[];
  /** Writes performed or proposed (e.g. 'task_comment'). Empty for read-only runs. */
  writes: string[];
  confidence: RunConfidence;
  /** Autonomy ladder level (0–4) the run operated at. */
  autonomyLevel: number;
  /** True when the result must be reviewed before acting (low confidence / above autonomy). */
  needsReview: boolean;
}
