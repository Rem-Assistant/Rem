import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import {
  getCheckinSettings,
  upsertCheckin,
  isCheckinSlot,
  type UpsertCheckinInput,
} from '../services/checkin.service.js';

/**
 * Check-ins — the founder's simplified routines. A user has up to three GLOBAL daily
 * check-in times (morning / midday / night), each toggleable with its own delivery hour.
 * The backend scheduler (src/scripts/daily-checkins.ts) wakes at each enabled time,
 * builds the user's Daily Brief over ALL their tasks and fires a push. There is no
 * per-task schedule here — connectors are global and agent instructions live on tasks.
 *
 *   GET /api/v1/checkins        — all three slots (defaults filled for un-set slots)
 *   PUT /api/v1/checkins/:slot  — upsert one slot { enabled?, deliveryHour?, deliveryMinute?, timezone? }
 *
 * Both routes are JWT-scoped to the authed user. Idempotent: PUT collapses on the
 * (user_id, slot) unique key, so the client can re-send the full slot on every change.
 */
const router = Router();

router.get('/checkins', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    // GET carries no body; default un-set slots to UTC. The client overwrites timezone
    // the first time it enables a slot (it sends TimeZone.current).
    const checkins = await getCheckinSettings(userId, 'UTC');
    return res.json({ checkins });
  } catch (error: any) {
    console.error('[CHECKINS] Error listing check-ins:', error.message);
    res.status(500).json({ error: error.message || 'Failed to list check-ins' });
  }
});

router.put('/checkins/:slot', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const slot = req.params.slot;
    if (!isCheckinSlot(slot)) {
      return res.status(400).json({ error: 'Invalid slot. Use morning, midday or night.' });
    }

    const updates: UpsertCheckinInput = {};
    if (typeof req.body?.enabled === 'boolean') updates.enabled = req.body.enabled;
    if (req.body?.deliveryHour !== undefined) updates.deliveryHour = req.body.deliveryHour;
    if (req.body?.deliveryMinute !== undefined) updates.deliveryMinute = req.body.deliveryMinute;
    if (typeof req.body?.timezone === 'string' && req.body.timezone.trim()) {
      updates.timezone = req.body.timezone.trim();
    }

    const checkin = await upsertCheckin(userId, slot, updates);
    return res.json(checkin);
  } catch (error: any) {
    console.error('[CHECKINS] Error updating check-in:', error.message);
    res.status(500).json({ error: error.message || 'Failed to update check-in' });
  }
});

export default router;
