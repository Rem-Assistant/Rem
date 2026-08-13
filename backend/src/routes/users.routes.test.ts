import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
const gatewayUserContextMock = vi.hoisted(() => ({ syncUserTimezoneToGateway: vi.fn() }));
vi.mock('../db/pool.js', () => ({ pool: poolMock }));
vi.mock('../services/gateway-user-context.service.js', () => gatewayUserContextMock);

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = 'f8679a96-0000-4000-8000-000000000001';
    next();
  },
}));

const usersRoutes = (await import('./users.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', usersRoutes);
  return app;
}

describe('POST /api/v1/users/timezone', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    gatewayUserContextMock.syncUserTimezoneToGateway.mockResolvedValue('synced');
  });

  it('upserts a valid IANA timezone and returns it', async () => {
    poolMock.query.mockResolvedValueOnce({ rows: [] });
    const res = await request(testApp())
      .post('/api/v1/users/timezone')
      .send({ timezone: 'America/Los_Angeles' });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true, timezone: 'America/Los_Angeles' });
    expect(poolMock.query).toHaveBeenCalledTimes(1);
    expect(poolMock.query.mock.calls[0][1]).toEqual([
      'f8679a96-0000-4000-8000-000000000001',
      'America/Los_Angeles',
    ]);
    expect(gatewayUserContextMock.syncUserTimezoneToGateway).toHaveBeenCalledWith(
      'f8679a96-0000-4000-8000-000000000001',
      'America/Los_Angeles',
    );
  });

  it('rejects junk with 400 (not 500) and writes nothing', async () => {
    const res = await request(testApp())
      .post('/api/v1/users/timezone')
      .send({ timezone: 'Not/AZone' });
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
    expect(gatewayUserContextMock.syncUserTimezoneToGateway).not.toHaveBeenCalled();
  });

  it('rejects a missing timezone with 400', async () => {
    const res = await request(testApp()).post('/api/v1/users/timezone').send({});
    expect(res.status).toBe(400);
    expect(poolMock.query).not.toHaveBeenCalled();
  });
});
