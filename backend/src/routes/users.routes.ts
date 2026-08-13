import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import { updateUserTimezone } from '../services/user.service.js';
import { syncUserTimezoneToGateway } from '../services/gateway-user-context.service.js';

/**
 * User-profile routes for the authed user (JWT-scoped).
 *
 *   POST /api/v1/users/timezone  — persist the device IANA timezone { timezone }
 *
 * The app posts `TimeZone.current.identifier` best-effort on launch/foreground/login so the
 * daily brief cron (which can't read a live device) resolves the user's LOCAL day + greeting
 * + authoring slot correctly (issue #1097). Invalid values are rejected with 400 — never a
 * 500 — so a garbage tz can't crash the write and the client's next launch just retries.
 *
 * NOTE: a manual account-level timezone-override SETTING is a deliberate follow-up; it would
 * write this same `users.timezone` column, so no new route is needed for it.
 */
const router = Router();

router.post('/users/timezone', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const result = await updateUserTimezone(userId, req.body?.timezone);
    if (!result.ok) {
      return res.status(400).json({ error: 'Invalid IANA timezone' });
    }
    // OpenClaw owns agent timestamp injection. Reconcile its userTimezone asynchronously so this
    // profile write stays fast even when a Fly Machine is asleep. `/gateway/wake` repeats the same
    // reconciliation after the machine is ready, which is the recovery path for this attempt.
    void syncUserTimezoneToGateway(userId, result.timezone).catch((error) => {
      console.error(`[users] gateway timezone sync failed for user ${userId}:`, error);
    });
    return res.json({ ok: true, timezone: result.timezone });
  } catch (error: any) {
    console.error('[USERS] Error updating timezone:', error.message);
    res.status(500).json({ error: error.message || 'Failed to update timezone' });
  }
});

export default router;
