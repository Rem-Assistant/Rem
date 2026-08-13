import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import {
  listMemories,
  getMemoryFreshness,
  addMemory,
  updateMemory,
  deleteMemory,
  normalizeFact,
  normalizeSource,
  MemoryValidationError,
  VolatileMemoryRejectedError,
} from '../services/user-memory.service.js';

/**
 * "What Rem remembers about you" — the user-managed + auto-extracted memory store ("Dreaming").
 *
 *   GET    /api/v1/memory       — list the user's facts (newest first) + "last refreshed" stamps
 *   POST   /api/v1/memory       — add a fact { fact, source? }
 *   PATCH  /api/v1/memory/:id   — edit a fact { fact }
 *   DELETE /api/v1/memory/:id   — delete a fact
 *
 * All routes are JWT-scoped to the authed user. Facts are either user-typed (source NULL/'user')
 * or written by the scheduled extractor with source='auto' (see scripts/extract-memories.ts).
 * GET returns lastUpdatedAt / lastAutoExtractedAt so the Memory screen can show when Rem last
 * refreshed the list automatically.
 */
const router = Router();

router.get('/memory', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const [memories, freshness] = await Promise.all([
      listMemories(userId),
      getMemoryFreshness(userId),
    ]);
    return res.json({
      memories,
      lastUpdatedAt: freshness.lastUpdatedAt,
      lastAutoExtractedAt: freshness.lastAutoExtractedAt,
    });
  } catch (error: any) {
    console.error('[MEMORY] Error listing memories:', error.message);
    res.status(500).json({ error: error.message || 'Failed to list memories' });
  }
});

router.post('/memory', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const fact = normalizeFact(req.body?.fact);
    const source = normalizeSource(req.body?.source);
    const memory = await addMemory(userId, fact, source);
    return res.status(201).json(memory);
  } catch (error: any) {
    if (error instanceof MemoryValidationError) {
      return res.status(400).json({ error: error.message });
    }
    // A machine-sourced write of a VOLATILE runtime fact (#1282/#1277) is a rejected request,
    // not a server fault — 400 so the caller sees the filter rather than a 500. The body carries
    // the category and the classifier's rule id; it must never carry the candidate fact.
    if (error instanceof VolatileMemoryRejectedError) {
      return res
        .status(400)
        .json({ error: error.message, category: error.category, rule: error.rule });
    }
    console.error('[MEMORY] Error adding memory:', error.message);
    res.status(500).json({ error: error.message || 'Failed to add memory' });
  }
});

router.patch('/memory/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const fact = normalizeFact(req.body?.fact);
    const memory = await updateMemory(userId, req.params.id, fact);
    if (!memory) return res.status(404).json({ error: 'Memory not found' });
    return res.json(memory);
  } catch (error: any) {
    if (error instanceof MemoryValidationError) {
      return res.status(400).json({ error: error.message });
    }
    console.error('[MEMORY] Error updating memory:', error.message);
    res.status(500).json({ error: error.message || 'Failed to update memory' });
  }
});

router.delete('/memory/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const deleted = await deleteMemory(userId, req.params.id);
    if (!deleted) return res.status(404).json({ error: 'Memory not found' });
    return res.status(204).send();
  } catch (error: any) {
    console.error('[MEMORY] Error deleting memory:', error.message);
    res.status(500).json({ error: error.message || 'Failed to delete memory' });
  }
});

export default router;
