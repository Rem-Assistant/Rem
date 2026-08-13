/**
 * routines.routes — REST surface for routine_schedules (migration 017). Mirrors
 * digests.routes.ts: thin handlers over the service layer, JWT-scoped to the user,
 * raw errors logged + surfaced. CRUD exposes the stage-1 service; POST /routines/:id/run
 * is the stage-2 manual trigger that returns the run's RunReport.
 * See docs/rebuild/10-ROUTINES-DESIGN.md.
 */

import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import {
  createRoutine,
  deleteRoutine,
  getRoutine,
  listRoutinesByUser,
  updateRoutine,
  type CreateRoutineInput,
  type UpdateRoutineInput,
} from '../services/routine-schedule.service.js';
import { runRoutine } from '../services/routine-runner.service.js';
import { AUTONOMY_MAX, AUTONOMY_MIN, type RoutineCadence } from '../services/routine.types.js';

const router = Router();

const CADENCES: ReadonlySet<string> = new Set<RoutineCadence>(['daily', 'weekly', 'once']);

function userId(req: Request): string {
  return (req as Request & { userId: string }).userId;
}

function isValidHour(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= 0 && (value as number) <= 23;
}

/** POST /api/v1/routines — create a routine for the authed user. */
router.post('/routines', requireJwt, async (req: Request, res: Response) => {
  try {
    const body = req.body ?? {};
    if (typeof body.taskId !== 'string' || !body.taskId.trim()) {
      return res.status(400).json({ error: 'Missing required field: taskId' });
    }
    if (!isValidHour(body.deliveryHour)) {
      return res.status(400).json({ error: 'deliveryHour must be an integer 0–23' });
    }
    if (typeof body.timezone !== 'string' || !body.timezone.trim()) {
      return res.status(400).json({ error: 'Missing required field: timezone' });
    }
    if (body.cadence !== undefined && !CADENCES.has(body.cadence)) {
      return res.status(400).json({ error: `Invalid cadence. Must be one of: ${Array.from(CADENCES).join(', ')}` });
    }
    if (
      body.autonomy !== undefined &&
      (!Number.isInteger(body.autonomy) || body.autonomy < AUTONOMY_MIN || body.autonomy > AUTONOMY_MAX)
    ) {
      return res.status(400).json({ error: `autonomy must be an integer ${AUTONOMY_MIN}–${AUTONOMY_MAX}` });
    }

    const input: CreateRoutineInput = {
      taskId: body.taskId,
      deliveryHour: body.deliveryHour,
      timezone: body.timezone,
      cadence: body.cadence,
      prompt: body.prompt ?? undefined,
      autonomy: body.autonomy,
      model: body.model ?? undefined,
      enabled: body.enabled,
    };
    const routine = await createRoutine(userId(req), input);
    return res.status(201).json(routine);
  } catch (error: any) {
    console.error('[ROUTINES] Error creating routine:', error.message);
    res.status(500).json({ error: error.message || 'Failed to create routine' });
  }
});

/** GET /api/v1/routines — list the user's routines, newest first. */
router.get('/routines', requireJwt, async (req: Request, res: Response) => {
  try {
    const routines = await listRoutinesByUser(userId(req));
    return res.json({ routines });
  } catch (error: any) {
    console.error('[ROUTINES] Error listing routines:', error.message);
    res.status(500).json({ error: error.message || 'Failed to list routines' });
  }
});

/** GET /api/v1/routines/:id — fetch one routine (scoped to the user). */
router.get('/routines/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const routine = await getRoutine(userId(req), req.params.id);
    if (!routine) return res.status(404).json({ error: 'Routine not found' });
    return res.json(routine);
  } catch (error: any) {
    console.error('[ROUTINES] Error fetching routine:', error.message);
    res.status(500).json({ error: error.message || 'Failed to fetch routine' });
  }
});

/** PATCH /api/v1/routines/:id — update a routine (scoped to the user). */
router.patch('/routines/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const body = req.body ?? {};
    if (body.deliveryHour !== undefined && !isValidHour(body.deliveryHour)) {
      return res.status(400).json({ error: 'deliveryHour must be an integer 0–23' });
    }
    if (body.cadence !== undefined && !CADENCES.has(body.cadence)) {
      return res.status(400).json({ error: `Invalid cadence. Must be one of: ${Array.from(CADENCES).join(', ')}` });
    }
    if (
      body.autonomy !== undefined &&
      (!Number.isInteger(body.autonomy) || body.autonomy < AUTONOMY_MIN || body.autonomy > AUTONOMY_MAX)
    ) {
      return res.status(400).json({ error: `autonomy must be an integer ${AUTONOMY_MIN}–${AUTONOMY_MAX}` });
    }

    const updates: UpdateRoutineInput = {};
    if (body.cadence !== undefined) updates.cadence = body.cadence;
    if (body.deliveryHour !== undefined) updates.deliveryHour = body.deliveryHour;
    if (body.timezone !== undefined) updates.timezone = body.timezone;
    if (body.prompt !== undefined) updates.prompt = body.prompt;
    if (body.autonomy !== undefined) updates.autonomy = body.autonomy;
    if (body.model !== undefined) updates.model = body.model;
    if (body.enabled !== undefined) updates.enabled = body.enabled;

    const routine = await updateRoutine(userId(req), req.params.id, updates);
    if (!routine) return res.status(404).json({ error: 'Routine not found' });
    return res.json(routine);
  } catch (error: any) {
    console.error('[ROUTINES] Error updating routine:', error.message);
    res.status(500).json({ error: error.message || 'Failed to update routine' });
  }
});

/**
 * POST /api/v1/routines/:id/run — manually trigger a routine now and return the
 * RunReport. Governance (deny list + autonomy gate) is enforced inside the runner;
 * the run never throws — it always lands a status-feed comment.
 */
router.post('/routines/:id/run', requireJwt, async (req: Request, res: Response) => {
  try {
    const routine = await getRoutine(userId(req), req.params.id);
    if (!routine) return res.status(404).json({ error: 'Routine not found' });

    const result = await runRoutine(routine, new Date());
    return res.json(result);
  } catch (error: any) {
    console.error('[ROUTINES] Error running routine:', error.message);
    res.status(500).json({ error: error.message || 'Failed to run routine' });
  }
});

/** DELETE /api/v1/routines/:id — delete a routine (scoped to the user). */
router.delete('/routines/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const removed = await deleteRoutine(userId(req), req.params.id);
    if (!removed) return res.status(404).json({ error: 'Routine not found' });
    return res.status(204).send();
  } catch (error: any) {
    console.error('[ROUTINES] Error deleting routine:', error.message);
    res.status(500).json({ error: error.message || 'Failed to delete routine' });
  }
});

export default router;
