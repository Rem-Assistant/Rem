/**
 * Global last-run stamps for backend cron jobs that run as a SINGLE global batch.
 *
 * Per-entity jobs (routines, check-ins, digests) stamp `last_run_at` on their own row,
 * so the every-15-min Railway `cron-all` service re-runs them idempotently. A GLOBAL
 * batch (e.g. the nightly memory-extraction "Dreaming" pass) has no per-entity row, so
 * it needs a shared stamp to gate itself to once per day. See migration
 * 030_create_cron_job_runs.sql.
 */

import { pool } from '../db/pool.js';

/** Last time a global cron job ran, or null if it has never run. */
export async function getCronJobLastRun(jobName: string): Promise<Date | null> {
  const result = await pool.query<{ last_run_at: string }>(
    'SELECT last_run_at FROM cron_job_runs WHERE job_name = $1',
    [jobName],
  );
  const row = result.rows[0];
  return row ? new Date(row.last_run_at) : null;
}

/** Stamp a global cron job's last-run time (UPSERT). */
export async function stampCronJobRun(jobName: string, at: Date): Promise<void> {
  await pool.query(
    `INSERT INTO cron_job_runs (job_name, last_run_at)
       VALUES ($1, $2::timestamptz)
     ON CONFLICT (job_name)
       DO UPDATE SET last_run_at = EXCLUDED.last_run_at`,
    [jobName, at.toISOString()],
  );
}
