import { beforeEach, describe, expect, it, vi } from 'vitest';

const gatewayServiceMock = vi.hoisted(() => ({
  getGatewayCredentials: vi.fn(),
  getSetupPassword: vi.fn(),
}));
const gatewayPairServiceMock = vi.hoisted(() => ({ patchGatewayConfig: vi.fn() }));
const timezoneServiceMock = vi.hoisted(() => ({ resolveStoredUserTimezone: vi.fn() }));

vi.mock('./gateway.service.js', () => gatewayServiceMock);
vi.mock('./gateway-pair.service.js', () => gatewayPairServiceMock);
vi.mock('./brief-authoring.service.js', () => timezoneServiceMock);

const {
  buildUserTimezoneConfigPatch,
  reconcileUserTimezoneAfterGatewaySave,
  syncUserTimezoneToGateway,
} = await import('./gateway-user-context.service.js');

const USER_ID = 'f8679a96-0000-4000-8000-000000000001';

beforeEach(() => {
  vi.clearAllMocks();
  gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
    gateway_url: 'https://remclaw-00000000.fly.dev',
    gateway_token: 'gateway-token',
  });
  gatewayServiceMock.getSetupPassword.mockResolvedValue('setup-password');
  gatewayPairServiceMock.patchGatewayConfig.mockResolvedValue(undefined);
  timezoneServiceMock.resolveStoredUserTimezone.mockResolvedValue('America/Los_Angeles');
});

describe('buildUserTimezoneConfigPatch', () => {
  it('uses OpenClaw agents.defaults.userTimezone without touching transcript text', () => {
    expect(buildUserTimezoneConfigPatch('Europe/Paris')).toEqual({
      agents: { defaults: { userTimezone: 'Europe/Paris' } },
    });
  });
});

describe('syncUserTimezoneToGateway', () => {
  it('patches an explicit freshly-written timezone into the configured gateway', async () => {
    await expect(syncUserTimezoneToGateway(USER_ID, 'Europe/Paris')).resolves.toBe('synced');

    expect(timezoneServiceMock.resolveStoredUserTimezone).not.toHaveBeenCalled();
    expect(gatewayPairServiceMock.patchGatewayConfig).toHaveBeenCalledWith(
      'https://remclaw-00000000.fly.dev',
      'gateway-token',
      { agents: { defaults: { userTimezone: 'Europe/Paris' } } },
      'setup-password',
    );
  });

  it('re-reads backend source-of-truth timezone during wake reconciliation', async () => {
    await syncUserTimezoneToGateway(USER_ID);

    expect(timezoneServiceMock.resolveStoredUserTimezone).toHaveBeenCalledWith(USER_ID);
    expect(gatewayPairServiceMock.patchGatewayConfig).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(String),
      { agents: { defaults: { userTimezone: 'America/Los_Angeles' } } },
      'setup-password',
    );
  });

  it('no-ops when the account has no gateway yet', async () => {
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(null);

    await expect(syncUserTimezoneToGateway(USER_ID)).resolves.toBe('no_gateway');
    expect(gatewayPairServiceMock.patchGatewayConfig).not.toHaveBeenCalled();
  });

  it('does not patch when the account has no persisted timezone', async () => {
    timezoneServiceMock.resolveStoredUserTimezone.mockResolvedValue(null);

    await expect(syncUserTimezoneToGateway(USER_ID)).resolves.toBe('no_timezone');
    expect(gatewayServiceMock.getGatewayCredentials).not.toHaveBeenCalled();
    expect(gatewayPairServiceMock.patchGatewayConfig).not.toHaveBeenCalled();
  });

  it('propagates lookup failures without patching a UTC fallback', async () => {
    timezoneServiceMock.resolveStoredUserTimezone.mockRejectedValue(new Error('db down'));

    await expect(syncUserTimezoneToGateway(USER_ID)).rejects.toThrow('db down');
    expect(gatewayServiceMock.getGatewayCredentials).not.toHaveBeenCalled();
    expect(gatewayPairServiceMock.patchGatewayConfig).not.toHaveBeenCalled();
  });

  it('falls back to token-only WebSocket auth when no setup password is stored', async () => {
    gatewayServiceMock.getSetupPassword.mockRejectedValue(new Error('missing'));

    await syncUserTimezoneToGateway(USER_ID, 'America/New_York');
    expect(gatewayPairServiceMock.patchGatewayConfig).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(String),
      expect.any(Object),
      undefined,
    );
  });
});

describe('reconcileUserTimezoneAfterGatewaySave', () => {
  it('repairs a timezone that was persisted before credentials existed', async () => {
    await expect(reconcileUserTimezoneAfterGatewaySave(USER_ID)).resolves.toBe('synced');

    expect(timezoneServiceMock.resolveStoredUserTimezone).toHaveBeenCalledWith(USER_ID);
    expect(gatewayPairServiceMock.patchGatewayConfig).toHaveBeenCalledOnce();
  });

  it('keeps credential creation best-effort when the follow-up patch fails', async () => {
    gatewayPairServiceMock.patchGatewayConfig.mockRejectedValue(new Error('gateway unavailable'));

    await expect(reconcileUserTimezoneAfterGatewaySave(USER_ID)).resolves.toBe('failed');
  });
});
