import express from 'express';
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';

// Isolate the router from the DB/env: importing auth.service.js → db/pool.js reads
// env.DATABASE_URL (a throwing getter) at module load. Mock the service so this test
// exercises ONLY the route table, not auth logic. Mirrors push.routes.test.ts.
vi.mock('../services/auth.service.js', () => ({
  authenticateUser: vi.fn(),
  deleteUser: vi.fn(),
  generateToken: vi.fn(() => 'stub-token'),
  verifyTokenAllowExpired: vi.fn(() => ({ sub: 'stub-user' })),
}));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request, _res: express.Response, next: express.NextFunction) => {
    (req as express.Request & { userId: string }).userId = 'stub-user';
    next();
  },
}));

import authRoutes from './auth.routes.js';

function app() {
  const server = express();
  server.use(express.json());
  server.use('/api/v1/auth', authRoutes);
  return server;
}

describe('auth routes surface', () => {
  // Security regression guard for #1343. The unauthenticated device endpoint minted a
  // valid 7-day JWT for any device_id >= 8 chars, with no auth header and no rate limit.
  // It is deleted; this asserts it stays deleted.
  it('does NOT expose POST /api/v1/auth/device (deleted, unauthenticated JWT minter)', async () => {
    const response = await request(app())
      .post('/api/v1/auth/device')
      .send({ device_id: 'a-device-id-well-over-8-chars' });

    // Express returns 404 for an unregistered path. If the route is re-added, the handler
    // answers with 400 (bad body) / 200 (minted token) / 500 — never 404 — so this fails RED.
    expect(response.status).toBe(404);
  });

  // Control: prove the router IS mounted and routing works, so the 404 above reflects a
  // missing route rather than a broken test harness that 404s everything.
  it('still routes surviving auth endpoints (login is mounted, not 404)', async () => {
    const response = await request(app())
      .post('/api/v1/auth/login')
      .send({}); // empty body → handler answers 400, proving the route exists

    expect(response.status).not.toBe(404);
    expect(response.status).toBe(400);
  });
});
