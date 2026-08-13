import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { env } from '../config/env.js';
import { touchUserActive } from '../services/user.service.js';

export interface AuthPayload {
  sub: string;
}

export function requireJwt(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  const token = header?.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token) {
    return res.status(401).json({ error: 'Missing or invalid Authorization' });
  }
  try {
    const decoded = jwt.verify(token, env.JWT_SECRET) as AuthPayload;
    (req as Request & { userId: string }).userId = decoded.sub;
    // Stamp "recently active" for the gateway keep-warm cron (migration 102).
    // Fire-and-forget: the stamp is throttled in SQL and must never block or fail the
    // request it rides on, so we don't await it and swallow any DB error.
    void touchUserActive(decoded.sub).catch(() => {});
    next();
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}
