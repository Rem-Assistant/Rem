import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import {
  DeviceTokenOwnershipConflictError,
  disableDeviceToken,
  registerDeviceToken,
  unregisterDeviceToken,
  normalizeApnsEnvironment,
  normalizeDevicePlatform,
} from '../services/push.service.js';

const router = Router();

/**
 * POST /api/v1/push/register — register/refresh this device's APNs token.
 * Body: { token, platform?, environment?, installationId?, ownershipGeneration? }.
 * The iOS app calls this from didRegisterForRemoteNotificationsWithDeviceToken
 * (wiring is a follow-up PR — backend foundation only here).
 */
router.post('/push/register', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const token = typeof req.body?.token === 'string' ? req.body.token.trim() : '';
    if (!token) {
      return res.status(400).json({ error: 'Missing required field: token' });
    }
    const environment = normalizeApnsEnvironment(req.body?.environment);
    const platform = normalizeDevicePlatform(req.body?.platform);
    const installationId = typeof req.body?.installationId === 'string'
      ? req.body.installationId.trim().slice(0, 100)
      : '';
    const rawGeneration = Number(req.body?.ownershipGeneration);
    const ownershipGeneration = Number.isSafeInteger(rawGeneration) && rawGeneration >= 0
      ? rawGeneration
      : 0;

    const row = await registerDeviceToken(
      userId,
      token,
      environment,
      platform,
      installationId || `legacy:${userId}`,
      ownershipGeneration,
    );
    return res.status(201).json({
      id: row.id.toString(),
      platform: row.platform,
      environment: row.environment,
    });
  } catch (error: any) {
    if (error instanceof DeviceTokenOwnershipConflictError) {
      res.setHeader('Retry-After', '1');
      return res.status(409).json({
        error: error.message,
        code: error.code,
        retryable: error.retryable,
      });
    }
    console.error('[PUSH] Error registering device token:', error.message);
    res.status(500).json({ error: error.message || 'Failed to register device token' });
  }
});

/**
 * POST /api/v1/push/unregister — drop this device's APNs token (logout, opt-out).
 * Body: { token, installationId?, ownershipGeneration?, retireLegacyAuthority? }.
 * Idempotent: returns 200 even if the token was already gone. Current clients set the strict
 * boolean retirement flag only when their persisted success cache predates installation authority.
 */
router.post('/push/unregister', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const token = typeof req.body?.token === 'string' ? req.body.token.trim() : '';
    if (!token) {
      return res.status(400).json({ error: 'Missing required field: token' });
    }
    const installationId = typeof req.body?.installationId === 'string'
      ? req.body.installationId.trim().slice(0, 100)
      : '';
    const rawGeneration = Number(req.body?.ownershipGeneration);
    const ownershipGeneration = Number.isSafeInteger(rawGeneration) && rawGeneration >= 0
      ? rawGeneration
      : 0;
    const retireLegacyAuthority = req.body?.retireLegacyAuthority === true;
    const removed = installationId
      ? await disableDeviceToken(
        userId,
        token,
        installationId,
        ownershipGeneration,
        retireLegacyAuthority,
      )
      : await unregisterDeviceToken(userId, token);
    return res.json({ removed });
  } catch (error: any) {
    console.error('[PUSH] Error unregistering device token:', error.message);
    res.status(500).json({ error: error.message || 'Failed to unregister device token' });
  }
});

export default router;
