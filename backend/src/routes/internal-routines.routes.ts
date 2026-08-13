/**
 * internal-routines.routes — an inbound webhook that runs a single routine by id. This
 * was originally the gateway-cron → runRoutine bridge; routines are now BACKEND-scheduled
 * (src/scripts/run-routines.ts selects due routines and calls runRoutine in-process), so
 * this endpoint is NO LONGER the scheduled path. It is kept as a harmless manual /
 * programmatic trigger seam (e.g. "run this routine now"). On call, the handler loads the
 * routine and invokes the existing `runRoutine` path — the SINGLE execution + governance
 * gate (model-gate + deny-list + attributed comment + RunReport + stampLastRun all live in
 * routine-runner.service.ts) — then returns the RunReport.
 *
 * --- Auth (NOT requireJwt) ---
 * The caller is a system actor, not a signed-in user, so there is no JWT. Instead the
 * handler requires a shared secret (`ROUTINE_WEBHOOK_SECRET`) presented as a bearer
 * token / `x-routine-webhook-secret` header. The URL carries the routine id in the path;
 * it does NOT carry a user identity, so the handler resolves the owning user from the
 * routine row (getRoutineById).
 *
 * --- Source of truth / fail-closed ---
 * Canonical routine state is the `routine_schedules` row. If `ROUTINE_WEBHOOK_SECRET`
 * is unset, EVERY call is rejected (401) — we never run a routine from an
 * unauthenticated webhook. Mismatched/missing token → 401. Unknown routine → 404.
 */

import { Router, Request, Response } from 'express';
import { timingSafeEqual } from 'node:crypto';
import { env } from '../config/env.js';
import { getRoutineById } from '../services/routine-schedule.service.js';
import { runRoutine } from '../services/routine-runner.service.js';

const router = Router();

/** Pull the presented secret from Authorization: Bearer … or x-routine-webhook-secret. */
function presentedSecret(req: Request): string | null {
  const header = req.get('x-routine-webhook-secret');
  if (header && header.trim()) return header.trim();
  const auth = req.get('authorization');
  if (auth && /^Bearer\s+/i.test(auth)) return auth.replace(/^Bearer\s+/i, '').trim();
  return null;
}

/** Constant-time compare; false on any length mismatch (avoids leaking length). */
function secretMatches(presented: string, expected: string): boolean {
  const a = Buffer.from(presented);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * Authenticate the gateway→backend webhook. Fail-closed: if the secret is not
 * configured, reject (never run a routine from an unauthenticated caller).
 */
function authorizeWebhook(req: Request, res: Response): boolean {
  const expected = env.ROUTINE_WEBHOOK_SECRET;
  if (!expected) {
    console.warn('[INTERNAL-ROUTINES] ROUTINE_WEBHOOK_SECRET unset; rejecting webhook');
    res.status(401).json({ error: 'Routine webhook secret not configured' });
    return false;
  }
  const presented = presentedSecret(req);
  if (!presented || !secretMatches(presented, expected)) {
    res.status(401).json({ error: 'Invalid routine webhook secret' });
    return false;
  }
  return true;
}

/**
 * POST /api/v1/internal/routines/:id/run — gateway cron webhook entrypoint. Runs the
 * routine now and returns the RunReport. The run itself never throws (every governance
 * path lands a status-feed comment), so a 200 here means the routine cycle completed.
 */
router.post('/internal/routines/:id/run', async (req: Request, res: Response) => {
  if (!authorizeWebhook(req, res)) return;

  try {
    const routine = await getRoutineById(req.params.id);
    if (!routine) return res.status(404).json({ error: 'Routine not found' });

    // Paused-routine guard: the gateway cron job is paused (enabled:false) when the
    // routine is disabled, but a job that was already firing — or whose pause patch
    // never reached the gateway (best-effort sync) — can still hit this webhook. The
    // routine row is the source of truth, so mirror isDailyRoutineDue's enabled check
    // and no-op: do NOT run the agent, write a comment, or stamp last_run_at.
    if (!routine.enabled) {
      return res.json({ skipped: 'disabled', routineId: routine.id });
    }

    const result = await runRoutine(routine, new Date());
    return res.json(result);
  } catch (error: any) {
    console.error('[INTERNAL-ROUTINES] Error running routine from webhook:', error.message);
    res.status(500).json({ error: error.message || 'Failed to run routine' });
  }
});

export default router;
