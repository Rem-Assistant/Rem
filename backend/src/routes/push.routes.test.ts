import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const pushMocks = vi.hoisted(() => {
  class DeviceTokenOwnershipConflictError extends Error {
    readonly code = 'device_token_ownership_conflict';
    readonly retryable = true;

    constructor() {
      super('APNs destination ownership changed; retry registration');
      this.name = 'DeviceTokenOwnershipConflictError';
    }
  }
  return {
    DeviceTokenOwnershipConflictError,
    registerDeviceToken: vi.fn(),
    unregisterDeviceToken: vi.fn(),
    disableDeviceToken: vi.fn(),
  };
});

vi.mock('../services/push.service.js', () => ({
  ...pushMocks,
  normalizeApnsEnvironment: (value: unknown) => value === 'sandbox' ? 'sandbox' : 'production',
  normalizeDevicePlatform: () => 'ios',
}));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request, _res: express.Response, next: express.NextFunction) => {
    (req as express.Request & { userId: string }).userId =
      'f8679a96-0000-4000-8000-000000000001';
    next();
  },
}));

import pushRoutes from './push.routes.js';

function app() {
  const server = express();
  server.use(express.json());
  server.use('/api/v1', pushRoutes);
  return server;
}

describe('push registration ownership responses', () => {
  beforeEach(() => vi.clearAllMocks());

  it('returns a retryable 409 instead of claiming another account row was registered', async () => {
    pushMocks.registerDeviceToken.mockRejectedValueOnce(
      new pushMocks.DeviceTokenOwnershipConflictError(),
    );

    const response = await request(app())
      .post('/api/v1/push/register')
      .send({ token: 'shared-token', environment: 'sandbox' });

    expect(response.status).toBe(409);
    expect(response.headers['retry-after']).toBe('1');
    expect(response.body).toEqual({
      error: 'APNs destination ownership changed; retry registration',
      code: 'device_token_ownership_conflict',
      retryable: true,
    });
    expect(pushMocks.registerDeviceToken).toHaveBeenCalledWith(
      'f8679a96-0000-4000-8000-000000000001',
      'shared-token',
      'sandbox',
      'ios',
      'legacy:f8679a96-0000-4000-8000-000000000001',
      0,
    );
  });

  it('returns 201 only for the row actually accepted for the caller', async () => {
    pushMocks.registerDeviceToken.mockResolvedValueOnce({
      id: 'row-1',
      apns_token: 'shared-token',
      environment: 'sandbox',
      platform: 'ios',
    });

    const response = await request(app())
      .post('/api/v1/push/register')
      .send({ token: 'shared-token', environment: 'sandbox' });

    expect(response.status).toBe(201);
    expect(response.body).toEqual({ id: 'row-1', platform: 'ios', environment: 'sandbox' });
  });

  it('passes cold-upgrade legacy retirement into the atomic installation disable', async () => {
    pushMocks.disableDeviceToken.mockResolvedValueOnce(true);

    const response = await request(app())
      .post('/api/v1/push/unregister')
      .send({
        token: 'migrated-token',
        installationId: 'new-install-after-upgrade',
        ownershipGeneration: 40,
        retireLegacyAuthority: true,
      });

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ removed: true });
    expect(pushMocks.disableDeviceToken).toHaveBeenCalledWith(
      'f8679a96-0000-4000-8000-000000000001',
      'migrated-token',
      'new-install-after-upgrade',
      40,
      true,
    );
  });

  it('does not infer legacy retirement from a truthy non-boolean body value', async () => {
    pushMocks.disableDeviceToken.mockResolvedValueOnce(true);

    await request(app())
      .post('/api/v1/push/unregister')
      .send({
        token: 'current-token',
        installationId: 'current-install',
        ownershipGeneration: 41,
        retireLegacyAuthority: 'true',
      });

    expect(pushMocks.disableDeviceToken).toHaveBeenCalledWith(
      'f8679a96-0000-4000-8000-000000000001',
      'current-token',
      'current-install',
      41,
      false,
    );
  });
});
