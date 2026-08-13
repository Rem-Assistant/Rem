import crypto from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const gatewayServiceMock = vi.hoisted(() => ({
  getManagedTalkTargetWithClient: vi.fn(),
  setManagedTalkCredentialFingerprintWithClient: vi.fn(),
  promoteManagedTalkDesiredCredentialWithClient: vi.fn(),
  markManagedTalkReconciledWithClient: vi.fn(),
}));
const flyServiceMock = vi.hoisted(() => ({ getMachine: vi.fn() }));
const gatewayPairMock = vi.hoisted(() => ({
  withGatewayRequester: vi.fn(),
  patchGatewayConfig: vi.fn(),
  patchGatewayConfigHttp: vi.fn(),
}));
const entitlementMock = vi.hoisted(() => ({ getCanonicalEntitlement: vi.fn() }));

vi.mock('../config/env.js', () => ({ env: { BACKEND_PUBLIC_URL: 'https://api.remclaw.test' } }));
vi.mock('./gateway.service.js', () => gatewayServiceMock);
vi.mock('./gateway/hosted-provisioning.js', () => ({
  getHostedGatewayProvisioning: () => flyServiceMock,
}));
vi.mock('./gateway-pair.service.js', () => gatewayPairMock);
vi.mock('./entitlement/entitlement-provider.js', () => ({
  getEntitlementProvider: () => entitlementMock,
}));
vi.mock('./gateway-lifecycle-lock.service.js', () => ({
  tryWithUserGatewayLifecycleMutationLock: vi.fn(),
  withUserGatewayLifecycleLock: vi.fn(),
}));

const {
  managedTalkInitialInstallForEntitlement,
  reconcileManagedTalkConfigurationWithClient,
} =
  await import('./managed-talk-configuration.service.js');

describe('managed Talk ownership reconciliation', () => {
  const lifecycleClient = { query: vi.fn() };
  const userId = 'f8679a96-0000-4000-8000-000000000001';

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.ELEVENLABS_API_KEY = 'current-managed-key';
    process.env.MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE = 'true';
    gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValue({
      gateway_url: 'https://remclaw-00000000.fly.dev',
      gateway_token: 'gateway-token',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-00000000',
      fly_machine_id: 'machine-id',
      fly_volume_id: 'volume-id',
      managed_talk_credential_fingerprint: null,
      managed_talk_desired_credential_fingerprint: null,
      managed_talk_credential_generation: 0,
    });
    flyServiceMock.getMachine.mockResolvedValue({
      config: {
        env: {
          REMCLAW_USER_ID: userId,
          BACKEND_URL: 'https://api.remclaw.test',
          SETUP_PASSWORD: 'setup-password',
        },
      },
    });
    entitlementMock.getCanonicalEntitlement.mockResolvedValue({ isActive: true });
    gatewayServiceMock.promoteManagedTalkDesiredCredentialWithClient.mockResolvedValue({
      fingerprint: crypto.createHash('sha256').update('current-managed-key').digest('hex'),
      generation: 1,
    });
  });

  afterEach(() => {
    delete process.env.ELEVENLABS_API_KEY;
    delete process.env.ELEVENLABS_API_KEY_GENERATION;
    delete process.env.MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE;
  });

  it('never produces a fresh managed credential for an inactive entitlement', () => {
    const install = managedTalkInitialInstallForEntitlement(false);

    expect(install).toBeNull();
    expect(JSON.stringify(install)).not.toContain('current-managed-key');
  });

  it('produces the canonical initial Talk branch only for an active entitlement', () => {
    const install = managedTalkInitialInstallForEntitlement(true);

    expect(install?.talk).toHaveProperty(
      'providers.elevenlabs.apiKey',
      'current-managed-key',
    );
    expect(install?.credentialFingerprint).toBe(
      crypto.createHash('sha256').update('current-managed-key').digest('hex'),
    );
  });

  it('preserves an alternate provider and voice even when its credential is temporarily unavailable', async () => {
    gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
      gateway_url: 'https://remclaw-00000000.fly.dev',
      gateway_token: 'gateway-token',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-00000000',
      fly_machine_id: 'machine-id',
      fly_volume_id: 'volume-id',
      managed_talk_credential_fingerprint: crypto.createHash('sha256').update('former-managed-key').digest('hex'),
    });
    gatewayPairMock.withGatewayRequester.mockImplementation(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: {
            config: {
              talk: {
                provider: 'openai',
                providers: {
                  openai: {
                    voiceId: 'alloy',
                  },
                },
              },
            },
          },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient as never))
      .resolves.toBe('user_credentials_required');

    expect(gatewayPairMock.patchGatewayConfig).not.toHaveBeenCalled();
    expect(gatewayPairMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    expect(gatewayServiceMock.setManagedTalkCredentialFingerprintWithClient)
      .toHaveBeenCalledWith(lifecycleClient, userId, null);
  });

  it('rotates only the credential whose fingerprint is owned by Rem', async () => {
    const formerKey = 'former-managed-key';
    gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
      gateway_url: 'https://remclaw-00000000.fly.dev',
      gateway_token: 'gateway-token',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-00000000',
      fly_machine_id: 'machine-id',
      fly_volume_id: 'volume-id',
      managed_talk_credential_fingerprint: crypto.createHash('sha256').update(formerKey).digest('hex'),
    });
    gatewayPairMock.withGatewayRequester.mockImplementation(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: {
            config: {
              talk: {
                provider: 'elevenlabs',
                providers: { elevenlabs: { apiKey: formerKey, voiceId: 'keep-this-voice' } },
              },
            },
          },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(
      userId,
      lifecycleClient as never,
      { requireActivated: true },
    )).resolves.toBe('repaired');

    expect(gatewayPairMock.patchGatewayConfigHttp).toHaveBeenCalledWith(
      'https://remclaw-00000000.fly.dev',
      'gateway-token',
      { talk: { providers: { elevenlabs: { apiKey: 'current-managed-key' } } } },
      'setup-password',
      { requireActivated: true, timeoutMs: 120_000 },
    );
  });

  it('keeps an inactive managed key installed while legacy wake writers may still run', async () => {
    const managedFingerprint = crypto.createHash('sha256').update('current-managed-key').digest('hex');
    process.env.MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE = 'false';
    entitlementMock.getCanonicalEntitlement.mockResolvedValueOnce({ isActive: false });
    gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
      gateway_url: 'https://remclaw-00000000.fly.dev',
      gateway_token: 'gateway-token',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-00000000',
      fly_machine_id: 'machine-id',
      fly_volume_id: 'volume-id',
      managed_talk_credential_fingerprint: managedFingerprint,
      managed_talk_desired_credential_fingerprint: managedFingerprint,
      managed_talk_credential_generation: 1,
    });
    gatewayPairMock.withGatewayRequester.mockImplementationOnce(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: { config: { talk: { provider: 'elevenlabs', providers: { elevenlabs: { apiKey: 'current-managed-key' } } } } },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient as never))
      .resolves.toBe('subscription_required');
    expect(gatewayPairMock.patchGatewayConfig).not.toHaveBeenCalled();
    expect(gatewayPairMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    expect(gatewayServiceMock.setManagedTalkCredentialFingerprintWithClient).not.toHaveBeenCalled();
    expect(gatewayServiceMock.markManagedTalkReconciledWithClient).not.toHaveBeenCalled();
  });

  it('defers tracked-key rotation until every legacy writer has drained', async () => {
    const formerKey = 'former-managed-key';
    process.env.MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE = 'false';
    process.env.ELEVENLABS_API_KEY_GENERATION = '2';
    gatewayServiceMock.promoteManagedTalkDesiredCredentialWithClient.mockResolvedValueOnce({
      fingerprint: crypto.createHash('sha256').update('current-managed-key').digest('hex'),
      generation: 2,
    });
    gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
      gateway_url: 'https://remclaw-00000000.fly.dev', gateway_token: 'gateway-token', hosting_provider: 'fly',
      fly_app_name: 'remclaw-00000000', fly_machine_id: 'machine-id', fly_volume_id: 'volume-id',
      managed_talk_credential_fingerprint: crypto.createHash('sha256').update(formerKey).digest('hex'),
      managed_talk_desired_credential_fingerprint: crypto.createHash('sha256').update(formerKey).digest('hex'),
      managed_talk_credential_generation: 1,
    });
    gatewayPairMock.withGatewayRequester.mockImplementationOnce(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: { config: { talk: { provider: 'elevenlabs', providers: { elevenlabs: { apiKey: formerKey } } } } },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient as never))
      .rejects.toThrow('waiting for the fenced-writer rollout');
    expect(gatewayPairMock.patchGatewayConfig).not.toHaveBeenCalled();
    expect(gatewayPairMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    expect(gatewayServiceMock.markManagedTalkReconciledWithClient).not.toHaveBeenCalled();
  });

  it('repairs a missing managed credential without resetting the existing voice or model', async () => {
    gatewayPairMock.withGatewayRequester.mockImplementation(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: {
            config: {
              talk: {
                provider: 'elevenlabs',
                providers: {
                  elevenlabs: {
                    voiceId: 'user-owned-voice',
                    modelId: 'user-owned-model',
                    outputFormat: 'mp3_44100_128',
                  },
                },
              },
            },
          },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(
      userId,
      lifecycleClient as never,
      { requireActivated: true },
    )).resolves.toBe('repaired');

    expect(gatewayPairMock.patchGatewayConfigHttp).toHaveBeenCalledWith(
      'https://remclaw-00000000.fly.dev',
      'gateway-token',
      { talk: { providers: { elevenlabs: { apiKey: 'current-managed-key' } } } },
      'setup-password',
      { requireActivated: true, timeoutMs: 120_000 },
    );
    const serializedPatch = JSON.stringify(gatewayPairMock.patchGatewayConfigHttp.mock.calls[0]?.[2]);
    expect(serializedPatch).not.toContain('user-owned-voice');
    expect(serializedPatch).not.toContain('user-owned-model');
  });

  it('preserves a user-owned managed-provider secret reference even when no provider is selected', async () => {
    gatewayPairMock.withGatewayRequester.mockImplementation(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: {
            config: {
              talk: {
                providers: {
                  elevenlabs: {
                    apiKey: { source: 'env', id: 'USER_ELEVENLABS_KEY' },
                    voiceId: 'user-owned-voice',
                  },
                },
              },
            },
          },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient as never))
      .resolves.toBe('user_credentials_required');

    expect(gatewayPairMock.patchGatewayConfig).not.toHaveBeenCalled();
    expect(gatewayPairMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    expect(gatewayServiceMock.setManagedTalkCredentialFingerprintWithClient).not.toHaveBeenCalled();
  });

  it('lets a draining old replica acknowledge a newer converged generation without rolling it back', async () => {
    const newerKey = 'newer-managed-key';
    const newerFingerprint = crypto.createHash('sha256').update(newerKey).digest('hex');
    process.env.ELEVENLABS_API_KEY = 'older-managed-key';
    process.env.ELEVENLABS_API_KEY_GENERATION = '1';
    gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
      gateway_url: 'https://remclaw-00000000.fly.dev',
      gateway_token: 'gateway-token',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-00000000',
      fly_machine_id: 'machine-id',
      fly_volume_id: 'volume-id',
      managed_talk_credential_fingerprint: newerFingerprint,
      managed_talk_desired_credential_fingerprint: newerFingerprint,
      managed_talk_credential_generation: 2,
    });
    gatewayServiceMock.promoteManagedTalkDesiredCredentialWithClient.mockResolvedValueOnce({
      fingerprint: newerFingerprint,
      generation: 2,
    });
    gatewayPairMock.withGatewayRequester.mockImplementationOnce(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: { config: { talk: { provider: 'elevenlabs', providers: { elevenlabs: { apiKey: newerKey } } } } },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient as never))
      .resolves.toBe('already_configured');
    expect(gatewayPairMock.patchGatewayConfig).not.toHaveBeenCalled();
    expect(gatewayPairMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
  });

  it('rejects an old replica when a newer desired generation still needs repair', async () => {
    const oldKey = 'older-managed-key';
    const oldFingerprint = crypto.createHash('sha256').update(oldKey).digest('hex');
    const newerFingerprint = crypto.createHash('sha256').update('newer-managed-key').digest('hex');
    process.env.ELEVENLABS_API_KEY = oldKey;
    process.env.ELEVENLABS_API_KEY_GENERATION = '1';
    gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
      gateway_url: 'https://remclaw-00000000.fly.dev', gateway_token: 'gateway-token', hosting_provider: 'fly',
      fly_app_name: 'remclaw-00000000', fly_machine_id: 'machine-id', fly_volume_id: 'volume-id',
      managed_talk_credential_fingerprint: oldFingerprint,
      managed_talk_desired_credential_fingerprint: newerFingerprint,
      managed_talk_credential_generation: 2,
    });
    gatewayServiceMock.promoteManagedTalkDesiredCredentialWithClient.mockResolvedValueOnce({
      fingerprint: newerFingerprint,
      generation: 2,
    });
    gatewayPairMock.withGatewayRequester.mockImplementationOnce(
      async (_url: string, _token: string, work: (request: () => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: { config: { talk: { provider: 'elevenlabs', providers: { elevenlabs: { apiKey: oldKey } } } } },
        })),
    );

    await expect(reconcileManagedTalkConfigurationWithClient(userId, lifecycleClient as never))
      .rejects.toThrow('older managed Talk key generation');
    expect(gatewayPairMock.patchGatewayConfig).not.toHaveBeenCalled();
    expect(gatewayPairMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
  });
});
