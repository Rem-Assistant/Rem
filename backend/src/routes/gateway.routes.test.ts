import express from 'express';
import crypto from 'node:crypto';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const gatewayServiceMock = vi.hoisted(() => ({
  setGatewayForUser: vi.fn(),
  setGatewayForUserWithClient: vi.fn(),
  setUserEnteredGatewayForUserWithClient: vi.fn(),
  getGatewayCredentials: vi.fn(),
  getFlyDeploymentMetadata: vi.fn(),
  getManagedTalkTargetWithClient: vi.fn(),
  setManagedTalkCredentialFingerprintWithClient: vi.fn(),
  promoteManagedTalkDesiredCredentialWithClient: vi.fn(),
  markManagedTalkReconciledWithClient: vi.fn(),
  getSetupPassword: vi.fn(),
  getGatewayUpdateReadinessForUser: vi.fn(),
  wakeGatewayForUser: vi.fn(),
}));

const flyServiceMock = vi.hoisted(() => ({
  getMachine: vi.fn(),
}));

const lifecycleLockMock = vi.hoisted(() => ({
  tryWithUserGatewayLifecycleMutationLock: vi.fn(),
  withUserGatewayLifecycleLock: vi.fn(),
  lifecycleClient: { query: vi.fn(), release: vi.fn() },
}));

const composioServiceMock = vi.hoisted(() => ({
  ensureComposioMcpWired: vi.fn(),
  isComposioConfigured: vi.fn(),
}));

const gatewayUserContextMock = vi.hoisted(() => ({
  reconcileUserTimezoneAfterGatewaySave: vi.fn(),
  syncUserTimezoneToGateway: vi.fn(),
}));

const entitlementProviderMock = vi.hoisted(() => ({
  getCanonicalEntitlement: vi.fn(),
}));

const gatewayPairServiceMock = vi.hoisted(() => ({
  autoApproveDevicesHttp: vi.fn(),
  NoPendingPairingRequestError: class NoPendingPairingRequestError extends Error {
    approved = 0;

    constructor() {
      super('no pending pairing request found');
      this.name = 'NoPendingPairingRequestError';
    }
  },
  ApprovalCheckTimeoutError: class ApprovalCheckTimeoutError extends Error {
    lastError?: string;

    constructor(lastError?: string) {
      super('auto-approve timed out before pending devices could be checked.');
      this.name = 'ApprovalCheckTimeoutError';
      this.lastError = lastError;
    }
  },
  ApprovalRetryFailedError: class ApprovalRetryFailedError extends Error {
    lastError?: string;

    constructor(lastError?: string) {
      super('auto-approve failed while checking pending devices.');
      this.name = 'ApprovalRetryFailedError';
      this.lastError = lastError;
    }
  },
  autoApproveDevices: vi.fn(),
  patchGatewayConfig: vi.fn(),
  withGatewayRequester: vi.fn(),
  patchGatewayConfigHttp: vi.fn(),
  listWorkspaceFilesHttp: vi.fn(),
  readWorkspaceFileHttp: vi.fn(),
  WorkspaceEndpointsUnavailableError: class WorkspaceEndpointsUnavailableError extends Error {
    constructor(detail: string) {
      super(`Gateway wrapper does not expose workspace endpoints (image update required): ${detail}`);
      this.name = 'WorkspaceEndpointsUnavailableError';
    }
  },
}));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (req: express.Request & { userId?: string }, _res: express.Response, next: express.NextFunction) => {
    req.userId = 'f8679a96-0000-4000-8000-000000000001';
    next();
  },
}));

vi.mock('../services/gateway.service.js', () => gatewayServiceMock);
vi.mock('../services/gateway/hosted-provisioning.js', () => ({
  getHostedGatewayProvisioning: () => flyServiceMock,
}));
vi.mock('../services/gateway-pair.service.js', () => gatewayPairServiceMock);
vi.mock('../services/composio.service.js', () => composioServiceMock);
vi.mock('../services/gateway-user-context.service.js', () => gatewayUserContextMock);
vi.mock('../services/gateway-lifecycle-lock.service.js', () => lifecycleLockMock);
vi.mock('../services/entitlement/entitlement-provider.js', () => ({
  getEntitlementProvider: () => entitlementProviderMock,
}));

const gatewayRoutes = (await import('./gateway.routes.js')).default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', gatewayRoutes);
  return app;
}

describe('gateway routes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    process.env.ELEVENLABS_API_KEY = 'test-elevenlabs-key';
    process.env.MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE = 'true';
    process.env.BACKEND_PUBLIC_URL = 'https://api.remclaw.test';
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://remclaw-00000000.fly.dev',
      gateway_token: 'gateway-token',
      hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup-password');
    gatewayServiceMock.getFlyDeploymentMetadata.mockResolvedValue({
      fly_app_name: 'remclaw-00000000',
      fly_machine_id: 'machine-id',
      fly_volume_id: 'volume-id',
    });
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
    gatewayServiceMock.setManagedTalkCredentialFingerprintWithClient.mockResolvedValue(undefined);
    gatewayServiceMock.promoteManagedTalkDesiredCredentialWithClient.mockResolvedValue({
      fingerprint: crypto.createHash('sha256').update('test-elevenlabs-key').digest('hex'),
      generation: 1,
    });
    gatewayServiceMock.markManagedTalkReconciledWithClient.mockResolvedValue(undefined);
    flyServiceMock.getMachine.mockResolvedValue({
      id: 'machine-id',
      name: 'remclaw-00000000',
      state: 'started',
      region: 'iad',
      config: {
        env: {
          REMCLAW_USER_ID: 'f8679a96-0000-4000-8000-000000000001',
          BACKEND_URL: 'https://api.remclaw.test',
          SETUP_PASSWORD: 'setup-password',
        },
      },
    });
    gatewayServiceMock.wakeGatewayForUser.mockResolvedValue({
      ok: true,
      provider: 'fly',
      action: 'none',
      machineState: 'started',
      gatewayReady: true,
    });
    entitlementProviderMock.getCanonicalEntitlement.mockResolvedValue({
      plan: 'pro',
      isActive: true,
      status: 'active',
      productId: 'app.remclaw.pro.monthly',
      expiresAt: null,
      originalTransactionId: 'transaction-id',
      environment: 'Sandbox',
      updatedAt: null,
    });
    composioServiceMock.isComposioConfigured.mockReturnValue(false);
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    gatewayUserContextMock.syncUserTimezoneToGateway.mockResolvedValue('synced');
    gatewayUserContextMock.reconcileUserTimezoneAfterGatewaySave.mockResolvedValue('synced');
    gatewayPairServiceMock.withGatewayRequester.mockImplementation(
      async (_url: string, _token: string, work: (request: (method: string) => Promise<unknown>) => Promise<unknown>) =>
        work(async () => ({
          ok: true,
          result: {
            config: {
              talk: {
                provider: 'elevenlabs',
                providers: { elevenlabs: { apiKey: 'test-elevenlabs-key' } },
              },
            },
          },
        })),
    );
    lifecycleLockMock.withUserGatewayLifecycleLock.mockImplementation(
      async (_userId: string, work: (client: typeof lifecycleLockMock.lifecycleClient) => Promise<unknown>) =>
        work(lifecycleLockMock.lifecycleClient),
    );
    lifecycleLockMock.tryWithUserGatewayLifecycleMutationLock.mockImplementation(
      async (_userId: string, work: (client: typeof lifecycleLockMock.lifecycleClient) => Promise<unknown>) => ({
        acquired: true,
        value: await work(lifecycleLockMock.lifecycleClient),
      }),
    );
  });

  afterEach(() => {
    delete process.env.ELEVENLABS_API_KEY;
    delete process.env.ELEVENLABS_API_KEY_GENERATION;
    delete process.env.MANAGED_TALK_FENCED_WRITER_ROLLOUT_COMPLETE;
    delete process.env.BACKEND_PUBLIC_URL;
  });

  describe('POST /gateway/voice/reconcile', () => {
    it('fails fast before wake when lifecycle ownership is busy', async () => {
      lifecycleLockMock.tryWithUserGatewayLifecycleMutationLock.mockResolvedValueOnce({ acquired: false });

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(409);
      expect(response.body).toEqual({
        error: 'Gateway lifecycle work is already in progress. Try again shortly.',
      });
      expect(gatewayServiceMock.wakeGatewayForUser).not.toHaveBeenCalled();
      expect(gatewayPairServiceMock.withGatewayRequester).not.toHaveBeenCalled();
    });

    it('fails fast before mutation when lifecycle ownership changes during wake', async () => {
      lifecycleLockMock.tryWithUserGatewayLifecycleMutationLock
        .mockImplementationOnce(
          async (_userId: string, work: (client: typeof lifecycleLockMock.lifecycleClient) => Promise<unknown>) => ({
            acquired: true,
            value: await work(lifecycleLockMock.lifecycleClient),
          }),
        )
        .mockResolvedValueOnce({ acquired: false });

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(409);
      expect(gatewayServiceMock.wakeGatewayForUser).toHaveBeenCalledOnce();
      expect(gatewayPairServiceMock.withGatewayRequester).not.toHaveBeenCalled();
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    });

    it('repairs missing managed Talk configuration with activated restart acknowledgement', async () => {
      gatewayPairServiceMock.withGatewayRequester.mockImplementationOnce(
        async (_url: string, _token: string, work: (request: (method: string) => Promise<unknown>) => Promise<unknown>) =>
          work(async () => ({ ok: true, result: { config: {} } })),
      );
      gatewayPairServiceMock.patchGatewayConfigHttp.mockResolvedValue({ activated: true });

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ outcome: 'repaired' });
      expect(entitlementProviderMock.getCanonicalEntitlement).toHaveBeenCalledWith(
        lifecycleLockMock.lifecycleClient,
        'f8679a96-0000-4000-8000-000000000001',
      );
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).toHaveBeenCalledWith(
        'https://remclaw-00000000.fly.dev',
        'gateway-token',
        expect.objectContaining({
          talk: expect.objectContaining({ provider: 'elevenlabs' }),
        }),
        'setup-password',
        { requireActivated: true, timeoutMs: 120_000 },
      );
    });

    it('revokes the exact Rem-managed provider key when entitlement is inactive', async () => {
      entitlementProviderMock.getCanonicalEntitlement.mockResolvedValueOnce({
        plan: 'free',
        isActive: false,
        status: 'none',
        productId: null,
        expiresAt: null,
        originalTransactionId: null,
        environment: null,
        updatedAt: null,
      });

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ outcome: 'subscription_required' });
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).toHaveBeenCalledWith(
        'https://remclaw-00000000.fly.dev',
        'gateway-token',
        { talk: { providers: { elevenlabs: { apiKey: null } } } },
        'setup-password',
        { requireActivated: true, timeoutMs: 120_000 },
      );
      expect(gatewayServiceMock.setManagedTalkCredentialFingerprintWithClient)
        .toHaveBeenCalledWith(lifecycleLockMock.lifecycleClient, 'f8679a96-0000-4000-8000-000000000001', null);
      expect(JSON.stringify(response.body)).not.toContain('test-elevenlabs-key');
    });

    it('rotates only a fingerprint-matched managed key and preserves Talk selections', async () => {
      const oldKey = 'old-managed-key';
      const oldFingerprint = crypto.createHash('sha256').update(oldKey).digest('hex');
      const currentFingerprint = crypto.createHash('sha256').update('test-elevenlabs-key').digest('hex');
      gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValue({
        gateway_url: 'https://remclaw-00000000.fly.dev',
        gateway_token: 'gateway-token',
        hosting_provider: 'fly',
        fly_app_name: 'remclaw-00000000',
        fly_machine_id: 'machine-id',
        fly_volume_id: 'volume-id',
        managed_talk_credential_fingerprint: oldFingerprint,
      });
      gatewayPairServiceMock.withGatewayRequester.mockImplementation(
        async (_url: string, _token: string, work: (request: (method: string) => Promise<unknown>) => Promise<unknown>) =>
          work(async () => ({
            ok: true,
            result: { config: { talk: { providers: { elevenlabs: { apiKey: oldKey } } } } },
          })),
      );

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ outcome: 'repaired' });
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).toHaveBeenCalledWith(
        'https://remclaw-00000000.fly.dev',
        'gateway-token',
        { talk: { providers: { elevenlabs: { apiKey: 'test-elevenlabs-key' } } } },
        'setup-password',
        { requireActivated: true, timeoutMs: 120_000 },
      );
      expect(gatewayServiceMock.setManagedTalkCredentialFingerprintWithClient)
        .toHaveBeenCalledWith(
          lifecycleLockMock.lifecycleClient,
          'f8679a96-0000-4000-8000-000000000001',
          currentFingerprint,
        );
    });

    it('preserves a user-owned replacement key and relinquishes stale managed ownership', async () => {
      entitlementProviderMock.getCanonicalEntitlement.mockResolvedValueOnce({
        plan: 'free', isActive: false, status: 'none', productId: null, expiresAt: null,
        originalTransactionId: null, environment: null, updatedAt: null,
      });
      gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValue({
        gateway_url: 'https://remclaw-00000000.fly.dev',
        gateway_token: 'gateway-token',
        hosting_provider: 'fly',
        fly_app_name: 'remclaw-00000000',
        fly_machine_id: 'machine-id',
        fly_volume_id: 'volume-id',
        managed_talk_credential_fingerprint: crypto.createHash('sha256').update('old-managed-key').digest('hex'),
      });
      gatewayPairServiceMock.withGatewayRequester.mockImplementation(
        async (_url: string, _token: string, work: (request: (method: string) => Promise<unknown>) => Promise<unknown>) =>
          work(async () => ({
            ok: true,
            result: {
              config: {
                talk: {
                  provider: 'elevenlabs',
                  providers: { elevenlabs: { apiKey: 'user-byok-key' } },
                },
              },
            },
          })),
      );

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ outcome: 'user_credentials_required' });
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
      expect(gatewayServiceMock.setManagedTalkCredentialFingerprintWithClient)
        .toHaveBeenCalledWith(lifecycleLockMock.lifecycleClient, 'f8679a96-0000-4000-8000-000000000001', null);
    });

    it('routes self-managed gateways to their gateway credential configuration', async () => {
      gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
        gateway_url: 'http://127.0.0.1:18789',
        gateway_token: 'local-token',
        hosting_provider: 'local',
      });

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(200);
      expect(response.body).toEqual({ outcome: 'user_credentials_required' });
      expect(entitlementProviderMock.getCanonicalEntitlement).not.toHaveBeenCalled();
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    });

    it('surfaces activation failure instead of claiming Voice is configured', async () => {
      gatewayPairServiceMock.withGatewayRequester.mockImplementationOnce(
        async (_url: string, _token: string, work: (request: (method: string) => Promise<unknown>) => Promise<unknown>) =>
          work(async () => ({ ok: true, result: { config: {} } })),
      );
      gatewayPairServiceMock.patchGatewayConfigHttp.mockRejectedValueOnce(
        new Error('config-patch was accepted but activation was not confirmed'),
      );

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(500);
      expect(response.body).toEqual({ error: 'Voice configuration repair failed' });
    });

    it('rejects a hostile repointed URL even when stale Fly metadata still looks owned', async () => {
      gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
        gateway_url: 'https://attacker.example',
        gateway_token: 'gateway-token',
        hosting_provider: 'fly',
        fly_app_name: 'remclaw-00000000',
        fly_machine_id: 'machine-id',
        fly_volume_id: 'volume-id',
        managed_talk_credential_fingerprint: null,
      });

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(500);
      expect(response.body).toEqual({ error: 'Voice configuration repair failed' });
      expect(gatewayServiceMock.wakeGatewayForUser).not.toHaveBeenCalled();
      expect(gatewayPairServiceMock.withGatewayRequester).not.toHaveBeenCalled();
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    });

    it('rejects a Fly machine owned by another backend environment before provider access', async () => {
      flyServiceMock.getMachine.mockResolvedValueOnce({
        id: 'machine-id',
        name: 'remclaw-00000000',
        state: 'started',
        region: 'iad',
        config: {
          env: {
            REMCLAW_USER_ID: 'f8679a96-0000-4000-8000-000000000001',
            BACKEND_URL: 'https://production.remclaw.test',
            SETUP_PASSWORD: 'setup-password',
          },
        },
      });

      const response = await request(testApp()).post('/api/v1/gateway/voice/reconcile');

      expect(response.status).toBe(500);
      expect(gatewayPairServiceMock.withGatewayRequester).not.toHaveBeenCalled();
      expect(gatewayPairServiceMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    });
  });

  it('never serializes the backend-owned Voice provider key in gateway credentials', async () => {
    const response = await request(testApp()).get('/api/v1/me/credentials');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      gatewayUrl: 'https://remclaw-00000000.fly.dev',
      gatewayToken: 'gateway-token',
      hostingProvider: 'fly',
    });
    expect(JSON.stringify(response.body)).not.toContain('test-elevenlabs-key');
    expect(response.body).not.toHaveProperty('elevenLabsApiKey');
  });

  it('acknowledges a config save only after activated readback is confirmed', async () => {
    gatewayPairServiceMock.patchGatewayConfigHttp.mockResolvedValue({ activated: true });

    const response = await request(testApp())
      .post('/api/v1/patch-config')
      .send({ config: { browser: { ssrfPolicy: { hostnameAllowlist: ['discord.com'] } } } });

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ ok: true, activated: true });
    expect(gatewayPairServiceMock.patchGatewayConfigHttp).toHaveBeenCalledWith(
      'https://remclaw-00000000.fly.dev',
      'gateway-token',
      { browser: { ssrfPolicy: { hostnameAllowlist: ['discord.com'] } } },
      'setup-password',
      { requireActivated: true, timeoutMs: 120_000 },
    );
  });

  it('surfaces activation or restart failure instead of returning success', async () => {
    gatewayPairServiceMock.patchGatewayConfigHttp.mockRejectedValue(
      new Error('config-patch was accepted but activation was not confirmed'),
    );

    const response = await request(testApp())
      .post('/api/v1/patch-config')
      .send({ config: { browser: { ssrfPolicy: { hostnameAllowlist: [] } } } });

    expect(response.status).toBe(500);
    expect(response.body.error).toMatch(/activation was not confirmed/);
  });

  it('starts timezone reconciliation without delaying newly saved gateway credentials', async () => {
    gatewayServiceMock.setUserEnteredGatewayForUserWithClient.mockResolvedValue({
      url: 'https://remclaw-00000000.fly.dev',
      hostingProvider: 'manual',
      isConnected: true,
    });
    let finishRepair: ((value: string) => void) | undefined;
    gatewayUserContextMock.reconcileUserTimezoneAfterGatewaySave.mockReturnValue(
      new Promise((resolve) => { finishRepair = resolve; }),
    );

    const response = await request(testApp())
      .patch('/api/v1/me/gateway')
      .send({
        gatewayUrl: 'https://remclaw-00000000.fly.dev',
        gatewayToken: 'gateway-token',
        hostingProvider: 'fly',
      });

    expect(response.status).toBe(200);
    expect(response.body.gateway.hostingProvider).toBe('manual');
    expect(lifecycleLockMock.withUserGatewayLifecycleLock).toHaveBeenCalledWith(
      'f8679a96-0000-4000-8000-000000000001',
      expect.any(Function),
    );
    expect(gatewayServiceMock.setUserEnteredGatewayForUserWithClient).toHaveBeenCalledWith(
      lifecycleLockMock.lifecycleClient,
      'f8679a96-0000-4000-8000-000000000001',
      'https://remclaw-00000000.fly.dev',
      'gateway-token',
      'fly',
    );
    expect(gatewayServiceMock.setGatewayForUserWithClient).not.toHaveBeenCalled();
    expect(gatewayServiceMock.setGatewayForUser).not.toHaveBeenCalled();
    expect(gatewayUserContextMock.reconcileUserTimezoneAfterGatewaySave).toHaveBeenCalledWith(
      'f8679a96-0000-4000-8000-000000000001',
    );
    finishRepair?.('synced');
  });

  it('returns read-only gateway update readiness for the authenticated user', async () => {
    gatewayServiceMock.getGatewayUpdateReadinessForUser.mockResolvedValue({
      canUpdate: false,
      status: 'managed_fly_preflight_required',
      hostingProvider: 'fly',
      gatewayUrl: 'https://remclaw-00000000.fly.dev',
      managedFlyAppName: 'remclaw-00000000',
      message: 'Gateway updates require a tested backup, same-gateway deploy target, health check, and rollback path before they can be enabled.',
      requiredChecks: ['same_gateway_target'],
      preflightChecks: [
        {
          id: 'same_gateway_target',
          label: 'Same Gateway Target',
          status: 'ready',
          message: 'Managed Fly app remclaw-00000000 is known.',
        },
      ],
      approvedTargets: [
        {
          id: 'openclaw-stable',
          label: 'OpenClaw stable',
          channel: 'stable',
          image: 'ghcr.io/rem-assistant/openclaw-gateway:stable',
          requiredCapabilities: ['skills.search'],
          enabled: false,
          disabledReason: 'Not installable yet. Safe in-app updates require backup/snapshot, same-gateway targeting, health check, and rollback preflight.',
        },
      ],
    });

    const response = await request(testApp())
      .get('/api/v1/gateway/update-readiness');

    expect(response.status).toBe(200);
    expect(gatewayServiceMock.getGatewayUpdateReadinessForUser).toHaveBeenCalledWith('f8679a96-0000-4000-8000-000000000001');
    expect(response.body.readiness).toMatchObject({
      canUpdate: false,
      status: 'managed_fly_preflight_required',
      hostingProvider: 'fly',
      managedFlyAppName: 'remclaw-00000000',
      preflightChecks: [
        {
          id: 'same_gateway_target',
          status: 'ready',
        },
      ],
      approvedTargets: [
        {
          id: 'openclaw-stable',
          enabled: false,
          requiredCapabilities: ['skills.search'],
        },
      ],
    });
  });

  it('returns explicit approved status when approval succeeds', async () => {
    gatewayPairServiceMock.autoApproveDevicesHttp.mockResolvedValue(1);

    const response = await request(testApp())
      .post('/api/v1/approve-device');

    expect(response.status).toBe(200);
    expect(gatewayPairServiceMock.autoApproveDevicesHttp).toHaveBeenCalledWith(
      'https://remclaw-00000000.fly.dev',
      'gateway-token',
      'setup-password',
      30_000,
      3_000
    );
    expect(response.body).toMatchObject({
      ok: true,
      status: 'approved',
      approved: 1,
    });
  });

  it('patches stale control UI config and retries approval when the gateway rejects control UI device identity', async () => {
    gatewayPairServiceMock.autoApproveDevicesHttp
      .mockRejectedValueOnce(
        new gatewayPairServiceMock.ApprovalRetryFailedError(
          'approve-all HTTP 500: {"ok":false,"error":"Error: Connect rejected: control ui requires device identity (use HTTPS or localhost secure context)"}'
        )
      )
      .mockResolvedValueOnce(1);
    gatewayPairServiceMock.patchGatewayConfigHttp.mockResolvedValue(undefined);

    const response = await request(testApp())
      .post('/api/v1/approve-device');

    expect(response.status).toBe(200);
    expect(gatewayPairServiceMock.patchGatewayConfigHttp).toHaveBeenCalledWith(
      'https://remclaw-00000000.fly.dev',
      'gateway-token',
      expect.objectContaining({
        gateway: expect.objectContaining({
          controlUi: expect.objectContaining({
            dangerouslyDisableDeviceAuth: true,
            dangerouslyAllowHostHeaderOriginFallback: true,
          }),
        }),
      }),
      'setup-password'
    );
    expect(gatewayPairServiceMock.patchGatewayConfigHttp.mock.calls[0]?.[2]).not.toHaveProperty('talk');
    expect(gatewayPairServiceMock.autoApproveDevicesHttp).toHaveBeenCalledTimes(2);
    expect(response.body).toMatchObject({
      ok: true,
      status: 'approved',
      approved: 1,
    });
  });

  it('does not patch unrelated hard approval failures', async () => {
    gatewayPairServiceMock.autoApproveDevicesHttp.mockRejectedValue(
      new gatewayPairServiceMock.ApprovalRetryFailedError('approve-all HTTP 401: bad setup password')
    );

    const response = await request(testApp())
      .post('/api/v1/approve-device');

    expect(response.status).toBe(502);
    expect(gatewayPairServiceMock.patchGatewayConfigHttp).not.toHaveBeenCalled();
    expect(response.body).toMatchObject({
      ok: false,
      status: 'approval_retry_failed',
      lastError: 'approve-all HTTP 401: bad setup password',
    });
  });

  it('returns no_pending_device when the gateway reports no pending approvals', async () => {
    gatewayPairServiceMock.autoApproveDevicesHttp.mockRejectedValue(
      new gatewayPairServiceMock.NoPendingPairingRequestError()
    );

    const response = await request(testApp())
      .post('/api/v1/approve-device');

    expect(response.status).toBe(409);
    expect(response.body).toMatchObject({
      ok: false,
      status: 'no_pending_device',
      approved: 0,
    });
  });

  it('returns approval_still_pending when approval cannot be checked before timeout', async () => {
    gatewayPairServiceMock.autoApproveDevicesHttp.mockRejectedValue(
      new gatewayPairServiceMock.ApprovalCheckTimeoutError('approve-all HTTP 503')
    );

    const response = await request(testApp())
      .post('/api/v1/approve-device');

    expect(response.status).toBe(504);
    expect(response.body).toMatchObject({
      ok: false,
      status: 'approval_still_pending',
      approved: 0,
      lastError: 'approve-all HTTP 503',
    });
  });

  it('returns approval_retry_failed for unexpected approval errors', async () => {
    gatewayPairServiceMock.autoApproveDevicesHttp.mockRejectedValue(new Error('setup auth rejected'));

    const response = await request(testApp())
      .post('/api/v1/approve-device');

    expect(response.status).toBe(500);
    expect(response.body).toMatchObject({
      ok: false,
      status: 'approval_retry_failed',
      approved: 0,
      error: 'setup auth rejected',
    });
  });

  it('returns approval_retry_failed for repeated hard approval failures', async () => {
    gatewayPairServiceMock.autoApproveDevicesHttp.mockRejectedValue(
      new gatewayPairServiceMock.ApprovalRetryFailedError('approve-all HTTP 401: bad setup password')
    );

    const response = await request(testApp())
      .post('/api/v1/approve-device');

    expect(response.status).toBe(502);
    expect(response.body).toMatchObject({
      ok: false,
      status: 'approval_retry_failed',
      approved: 0,
      lastError: 'approve-all HTTP 401: bad setup password',
    });
  });

  describe('workspace/memory files', () => {
    it('lists workspace files when the gateway wrapper supports the endpoints', async () => {
      gatewayPairServiceMock.listWorkspaceFilesHttp.mockResolvedValue([
        { path: 'IDENTITY.md', size: 120, mtime: '2026-07-01T00:00:00.000Z' },
        { path: 'memory/2026-07-01.md', size: 42, mtime: null },
      ]);

      const response = await request(testApp())
        .get('/api/v1/gateway/workspace/files');

      expect(response.status).toBe(200);
      expect(gatewayPairServiceMock.listWorkspaceFilesHttp).toHaveBeenCalledWith(
        'https://remclaw-00000000.fly.dev',
        'setup-password'
      );
      expect(response.body).toMatchObject({
        available: true,
        files: [{ path: 'IDENTITY.md' }, { path: 'memory/2026-07-01.md' }],
      });
    });

    it('returns available:false when there is no setup password (e.g. local gateway)', async () => {
      gatewayServiceMock.getSetupPassword.mockRejectedValue(new Error('no fly app'));

      const response = await request(testApp())
        .get('/api/v1/gateway/workspace/files');

      expect(response.status).toBe(200);
      expect(response.body).toMatchObject({ available: false, files: [] });
      expect(gatewayPairServiceMock.listWorkspaceFilesHttp).not.toHaveBeenCalled();
    });

    it('degrades to available:false + gateway-update-required when the wrapper image is stale', async () => {
      // Old wrappers fall through to the control-ui SPA and return 200 text/html
      // for /setup/api/workspace/list; the helper raises the typed error.
      gatewayPairServiceMock.listWorkspaceFilesHttp.mockRejectedValue(
        new gatewayPairServiceMock.WorkspaceEndpointsUnavailableError('workspace/list returned non-JSON (HTTP 200): <!doctype html>')
      );

      const response = await request(testApp())
        .get('/api/v1/gateway/workspace/files');

      expect(response.status).toBe(200);
      expect(response.body).toMatchObject({
        available: false,
        files: [],
        reason: 'gateway-update-required',
      });
    });

    it('returns a friendly 502 for other workspace list failures', async () => {
      gatewayPairServiceMock.listWorkspaceFilesHttp.mockRejectedValue(new Error('fetch failed'));

      const response = await request(testApp())
        .get('/api/v1/gateway/workspace/files');

      expect(response.status).toBe(502);
      expect(response.body.error).toMatch(/gateway/i);
      // Raw error detail is logged, not sent to the app.
      expect(response.body.error).not.toContain('fetch failed');
    });

    it('reads a single workspace file', async () => {
      gatewayPairServiceMock.readWorkspaceFileHttp.mockResolvedValue({
        path: 'USER.md',
        content: '# USER.md\n',
        size: 10,
        truncated: false,
      });

      const response = await request(testApp())
        .get('/api/v1/gateway/workspace/file')
        .query({ path: 'USER.md' });

      expect(response.status).toBe(200);
      expect(gatewayPairServiceMock.readWorkspaceFileHttp).toHaveBeenCalledWith(
        'https://remclaw-00000000.fly.dev',
        'setup-password',
        'USER.md'
      );
      expect(response.body).toMatchObject({ path: 'USER.md', content: '# USER.md\n' });
    });

    it('returns 503 with update copy when reading a file from a stale wrapper', async () => {
      gatewayPairServiceMock.readWorkspaceFileHttp.mockRejectedValue(
        new gatewayPairServiceMock.WorkspaceEndpointsUnavailableError('workspace/file returned non-JSON (HTTP 200): <!doctype html>')
      );

      const response = await request(testApp())
        .get('/api/v1/gateway/workspace/file')
        .query({ path: 'USER.md' });

      expect(response.status).toBe(503);
      expect(response.body.error).toMatch(/update/i);
    });
  });

  // #1087 follow-up: /gateway/wake fires on every app cold launch (RemClawApp.swift
  // wakeGatewayIfNeeded()), independent of whether the app ever hits a Composio-specific route —
  // the reliable trigger the live test found was missing.
  describe('derived gateway config sync on wake', () => {
    beforeEach(() => {
      gatewayServiceMock.wakeGatewayForUser.mockResolvedValue({
        ok: true,
        provider: 'fly',
        action: 'noop',
        machineState: 'started',
        gatewayReady: true,
      });
    });

    it('syncs composio mcp wiring when the gateway wakes ready and composio is configured', async () => {
      composioServiceMock.isComposioConfigured.mockReturnValue(true);

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      // Fire-and-forget: give the detached async IIFE a tick to run before asserting.
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(gatewayUserContextMock.syncUserTimezoneToGateway).toHaveBeenCalledWith(
        'f8679a96-0000-4000-8000-000000000001',
      );
      expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledWith(
        'f8679a96-0000-4000-8000-000000000001',
        'https://remclaw-00000000.fly.dev',
        'gateway-token',
        'setup-password',
      );
    });

    it('does not attempt to sync when composio is not configured on this backend', async () => {
      composioServiceMock.isComposioConfigured.mockReturnValue(false);

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(gatewayUserContextMock.syncUserTimezoneToGateway).toHaveBeenCalledWith(
        'f8679a96-0000-4000-8000-000000000001',
      );
      expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();
    });

    it('repairs missing managed Talk config once without delaying the wake response', async () => {
      gatewayPairServiceMock.withGatewayRequester.mockImplementationOnce(
        async (_url: string, _token: string, work: (request: (method: string) => Promise<unknown>) => Promise<unknown>) =>
          work(async () => ({ ok: true, result: { config: {} } })),
      );

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(gatewayPairServiceMock.patchGatewayConfig).toHaveBeenCalledWith(
        'https://remclaw-00000000.fly.dev',
        'gateway-token',
        expect.objectContaining({
          talk: expect.objectContaining({ provider: 'elevenlabs' }),
        }),
        'setup-password',
      );
    });

    it('does not write managed Talk credentials into a local gateway', async () => {
      gatewayServiceMock.getManagedTalkTargetWithClient.mockResolvedValueOnce({
        gateway_url: 'http://127.0.0.1:18789',
        gateway_token: 'local-token',
        hosting_provider: 'local',
      });

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(gatewayPairServiceMock.withGatewayRequester).not.toHaveBeenCalled();
      expect(gatewayPairServiceMock.patchGatewayConfig).not.toHaveBeenCalled();
    });

    it('preserves a configured non-ElevenLabs Talk provider using a secret reference', async () => {
      gatewayPairServiceMock.withGatewayRequester.mockImplementationOnce(
        async (_url: string, _token: string, work: (request: (method: string) => Promise<unknown>) => Promise<unknown>) =>
          work(async () => ({
            ok: true,
            result: {
              config: {
                talk: {
                  provider: 'openai',
                  providers: {
                    openai: {
                      apiKey: { source: 'env', provider: 'default', id: 'OPENAI_API_KEY' },
                    },
                  },
                },
              },
            },
          })),
      );

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(gatewayPairServiceMock.patchGatewayConfig).not.toHaveBeenCalled();
    });

    it('does not attempt to sync when the gateway did not report ready (still waking)', async () => {
      composioServiceMock.isComposioConfigured.mockReturnValue(true);
      gatewayServiceMock.wakeGatewayForUser.mockResolvedValue({
        ok: true,
        provider: 'fly',
        action: 'start',
        machineState: 'starting',
        gatewayReady: false,
      });

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(gatewayUserContextMock.syncUserTimezoneToGateway).not.toHaveBeenCalled();
      expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();
    });

    it('never fails the wake response when the composio sync throws', async () => {
      composioServiceMock.isComposioConfigured.mockReturnValue(true);
      composioServiceMock.ensureComposioMcpWired.mockRejectedValue(new Error('gateway unreachable'));

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalled();
    });

    it('continues to composio and never fails wake when timezone sync throws', async () => {
      composioServiceMock.isComposioConfigured.mockReturnValue(true);
      gatewayUserContextMock.syncUserTimezoneToGateway.mockRejectedValue(
        new Error('timezone patch unavailable'),
      );

      const response = await request(testApp()).post('/api/v1/gateway/wake');

      expect(response.status).toBe(200);
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalled();
    });
  });
});
