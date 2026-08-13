import { beforeAll, describe, expect, it, vi } from 'vitest';

describe('user-entered gateway ownership lifecycle', () => {
  beforeAll(() => {
    process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:5432/remclaw_test';
    process.env.GATEWAY_ENCRYPTION_KEY = 'test-encryption-key';
  });

  it('demotes an unverified Fly label and clears stale managed deployment metadata atomically', async () => {
    const { setUserEnteredGatewayForUserWithClient } = await import('./gateway.service.js');
    const query = vi.fn().mockResolvedValue({
      rows: [{
        gateway_url: 'https://different-app.fly.dev',
        hosting_provider: 'manual',
      }],
    });

    const result = await setUserEnteredGatewayForUserWithClient(
      { query } as never,
      'user-id',
      'https://different-app.fly.dev',
      'gateway-token',
      'fly',
    );

    const [sql, params] = query.mock.calls[0];
    expect(sql).toContain('fly_app_name = NULL');
    expect(sql).toContain('fly_machine_id = NULL');
    expect(sql).toContain('fly_volume_id = NULL');
    expect(sql).toContain('managed_talk_credential_fingerprint = NULL');
    expect(params[2]).toBe('manual');
    expect(result.hostingProvider).toBe('manual');
  });

  it('preserves an explicitly local provider while still clearing Fly metadata', async () => {
    const { setUserEnteredGatewayForUserWithClient } = await import('./gateway.service.js');
    const query = vi.fn().mockResolvedValue({
      rows: [{ gateway_url: 'http://mac.local:18789', hosting_provider: 'local' }],
    });

    const result = await setUserEnteredGatewayForUserWithClient(
      { query } as never,
      'user-id',
      'http://mac.local:18789',
      'gateway-token',
      'local',
    );

    expect(query.mock.calls[0][1][2]).toBe('local');
    expect(result.hostingProvider).toBe('local');
  });
});
