import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import { pool } from '../db/pool.js';
import {
  createDigestForUser,
  defaultKindForDate,
  formatDigest,
  DIGEST_RETURNING,
  DIGEST_KINDS,
  type DigestKind,
} from '../services/digest.service.js';

const router = Router();

/**
 * GET /api/v1/digests — list the user's digests, newest first.
 *   ?limit=20         — page size (1..100, default 20)
 *   ?kind=morning_brief|evening_recap — optional filter
 */
router.get('/digests', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const limit = Math.min(Math.max(parseInt(req.query.limit as string, 10) || 20, 1), 100);

    const conditions = ['user_id = $1::uuid'];
    const values: any[] = [userId];
    if (req.query.kind) {
      if (!DIGEST_KINDS.has(req.query.kind as string)) {
        return res.status(400).json({
          error: `Invalid kind. Must be one of: ${Array.from(DIGEST_KINDS).join(', ')}`,
        });
      }
      conditions.push(`kind = $${values.length + 1}`);
      values.push(req.query.kind);
    }

    values.push(limit);
    const result = await pool.query(
      `SELECT ${DIGEST_RETURNING} FROM digests
        WHERE ${conditions.join(' AND ')}
        ORDER BY created_at DESC
        LIMIT $${values.length}`,
      values,
    );
    return res.json({ digests: result.rows.map(formatDigest) });
  } catch (error: any) {
    console.error('[DIGESTS] Error listing digests:', error.message);
    res.status(500).json({ error: error.message || 'Failed to list digests' });
  }
});

/**
 * GET /api/v1/digests/:id — fetch a single digest (scoped to the user).
 */
router.get('/digests/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const result = await pool.query(
      `SELECT ${DIGEST_RETURNING} FROM digests WHERE id = $1::uuid AND user_id = $2::uuid`,
      [req.params.id, userId],
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Digest not found' });
    return res.json(formatDigest(result.rows[0]));
  } catch (error: any) {
    console.error('[DIGESTS] Error fetching digest:', error.message);
    res.status(500).json({ error: error.message || 'Failed to fetch digest' });
  }
});

/**
 * POST /api/v1/digests/run — generate a digest for the authed user right now and
 * return it. Used by the app's manual "refresh" and for testing; the scheduled
 * batch (src/scripts/run-digests.ts) calls the same service for all users.
 * Body: { kind? } — defaults to morning/evening by current UTC hour.
 * Always returns 201 with a digest — GMI failures fall back to a local summary.
 */
router.post('/digests/run', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;

    let kind: DigestKind;
    if (req.body?.kind !== undefined) {
      if (!DIGEST_KINDS.has(req.body.kind)) {
        return res.status(400).json({
          error: `Invalid kind. Must be one of: ${Array.from(DIGEST_KINDS).join(', ')}`,
        });
      }
      kind = req.body.kind;
    } else {
      kind = defaultKindForDate(new Date());
    }

    const digest = await createDigestForUser(userId, kind, new Date());
    return res.status(201).json(digest);
  } catch (error: any) {
    console.error('[DIGESTS] Error running digest:', error.message);
    res.status(500).json({ error: error.message || 'Failed to run digest' });
  }
});

/**
 * DELETE /api/v1/digests/:id — dismiss/delete a digest (scoped to the user).
 */
router.delete('/digests/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const result = await pool.query(
      `DELETE FROM digests WHERE id = $1::uuid AND user_id = $2::uuid RETURNING id`,
      [req.params.id, userId],
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Digest not found' });
    return res.status(204).send();
  } catch (error: any) {
    console.error('[DIGESTS] Error deleting digest:', error.message);
    res.status(500).json({ error: error.message || 'Failed to delete digest' });
  }
});

export default router;
