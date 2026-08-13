import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import { resolveUserTimezone } from '../services/brief-authoring.service.js';
import {
  deriveSuggestions,
  dismissSuggestion,
  ingestSignal,
} from '../services/suggestions.service.js';

const router = Router();

/**
 * GET /api/v1/suggestions — the current suggested tasks for the authed user (WS2, doc 38).
 *
 * Derived live from signals we already have (upcoming calendar events, overdue tasks), minus
 * anything the user has dismissed. Idempotent read; never mutates. The user's LOCAL timezone
 * sets the "today"/"overdue" boundaries, mirroring GET /brief so the two agree on the day.
 */
router.get('/suggestions', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const now = new Date();
    const timezone = (await resolveUserTimezone(userId).catch(() => undefined)) ?? 'UTC';
    const suggestions = await deriveSuggestions(userId, now, timezone);
    return res.json({ suggestions });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('[SUGGESTIONS] list failed:', message);
    return res.status(500).json({ error: 'failed to load suggestions' });
  }
});

/**
 * POST /api/v1/suggestions/:key/dismiss — durably hide a suggestion (doc 38 §6).
 *
 * The app calls this both on an explicit Dismiss AND on Accept (after it creates/reschedules
 * the task locally), so an actioned suggestion never re-derives. Idempotent — re-dismissing is
 * a no-op. `:key` is the stable, source-prefixed suggestion key ("cal:<id>" / "overdue:<id>").
 */
router.post('/suggestions/:key/dismiss', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const key = req.params.key;
    if (!key || typeof key !== 'string') {
      return res.status(400).json({ error: 'missing suggestion key' });
    }
    await dismissSuggestion(userId, key);
    return res.status(204).send();
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('[SUGGESTIONS] dismiss failed:', message);
    return res.status(500).json({ error: 'failed to dismiss suggestion' });
  }
});

/**
 * POST /api/v1/suggestions/signals — ingest a connected-source signal (WS2 doc 38 §4, tier-2).
 *
 * The WS1 fill point: WS1's gateway `message_received` hook posts a message from a linked app
 * (Gmail, WhatsApp, …) here; the deriver turns it into an attributed suggestion. Idempotent on
 * (source, sourceRef) — re-delivering the same message updates rather than duplicates.
 *
 * Body: { source, sourceRef, summary, sender?, suggestedTitle?, receivedAt? }.
 */
router.post('/suggestions/signals', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const body = (req.body ?? {}) as Record<string, unknown>;
    const source = typeof body.source === 'string' ? body.source.trim() : '';
    const sourceRef = typeof body.sourceRef === 'string' ? body.sourceRef.trim() : '';
    const summary = typeof body.summary === 'string' ? body.summary.trim() : '';
    if (!source || !sourceRef || !summary) {
      return res.status(400).json({ error: 'source, sourceRef, and summary are required' });
    }
    const id = await ingestSignal(userId, {
      source,
      sourceRef,
      summary,
      sender: typeof body.sender === 'string' ? body.sender : undefined,
      suggestedTitle: typeof body.suggestedTitle === 'string' ? body.suggestedTitle : undefined,
      receivedAt: typeof body.receivedAt === 'string' ? body.receivedAt : undefined,
    });
    return res.status(201).json({ id });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('[SUGGESTIONS] signal ingest failed:', message);
    return res.status(500).json({ error: 'failed to ingest signal' });
  }
});

export default router;
