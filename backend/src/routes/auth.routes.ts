import { Router, Request, Response } from 'express';
import { authenticateUser, deleteUser, generateToken, verifyTokenAllowExpired } from '../services/auth.service.js';
import { requireJwt } from '../middleware/auth.js';

const router = Router();

/**
 * POST /api/v1/auth/login
 * Federated login with Apple or Google ID token.
 * Returns a Rem JWT + user profile.
 */
router.post('/login', async (req: Request, res: Response) => {
  try {
    const { provider, id_token, profile, apple_authorization_code } = req.body ?? {};

    if (!provider || !id_token) {
      return res.status(400).json({ error: 'provider and id_token are required' });
    }
    if (!['apple', 'google'].includes(provider)) {
      return res.status(400).json({ error: 'provider must be "apple" or "google"' });
    }

    const result = await authenticateUser(provider, id_token, profile, apple_authorization_code);

    return res.json({
      access_token: result.accessToken,
      user: {
        id: result.user.id,
        email: result.user.email,
        full_name: result.user.full_name,
        first_name: result.user.first_name,
        last_name: result.user.last_name,
        profile_picture_url: result.user.profile_picture_url,
        locale: result.user.locale,
      },
      is_new_user: result.isNewUser,
    });
  } catch (error: any) {
    console.error('[AUTH] Login error:', error.message);
    res.status(401).json({ error: error.message || 'Authentication failed' });
  }
});

/**
 * POST /api/v1/auth/refresh
 * Silent token refresh. Accepts an expired-but-validly-signed JWT in the
 * Authorization header and returns a fresh JWT. No identity provider
 * interaction required.
 */
router.post('/refresh', async (req: Request, res: Response) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader?.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'Bearer token required' });
    }

    const token = authHeader.slice(7);
    const { sub } = verifyTokenAllowExpired(token);
    const freshToken = generateToken(sub);

    return res.json({ access_token: freshToken });
  } catch (error: any) {
    console.error('[AUTH] Refresh error:', error.message);
    res.status(401).json({ error: error.message || 'Token refresh failed' });
  }
});

/**
 * DELETE /api/v1/auth/me
 * Permanently deletes the authenticated user's account, gateway, and all data.
 */
router.delete('/me', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    await deleteUser(userId);
    return res.json({ ok: true });
  } catch (error: any) {
    console.error('[AUTH] Delete account error:', error.message);
    res.status(500).json({ error: error.message || 'Account deletion failed' });
  }
});

export default router;
