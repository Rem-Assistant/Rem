import express from 'express';
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const composioServiceMock = vi.hoisted(() => {
  class ComposioNotConfiguredError extends Error {}
  class ComposioToolkitError extends Error {}
  class ComposioStatusUnavailableError extends Error {
    constructor(message = "Couldn't verify existing Composio connections. Try again in a moment.") {
      super(message);
    }
  }
  class ComposioMutationTimeoutError extends Error {
    constructor(message: string) { super(message); }
  }
  return {
    COMPOSIO_TOOLKITS: ['gmail', 'slack', 'discord'],
    createConnectSession: vi.fn(),
    getConnectionStatus: vi.fn(),
    listToolkitsSummary: vi.fn(),
    disconnectToolkit: vi.fn(),
    setToolkitEnabled: vi.fn(),
    ensureComposioMcpWired: vi.fn(),
    ComposioNotConfiguredError,
    ComposioToolkitError,
    ComposioStatusUnavailableError,
    ComposioMutationTimeoutError,
  };
});

const gatewayServiceMock = vi.hoisted(() => ({
  getGatewayCredentials: vi.fn(),
  getLocalGatewayCredentials: vi.fn(),
  getSetupPassword: vi.fn(),
}));

vi.mock('../middleware/auth.js', () => ({
  requireJwt: (
    req: express.Request & { userId?: string },
    _res: express.Response,
    next: express.NextFunction,
  ) => {
    req.userId = 'user-1';
    next();
  },
}));
vi.mock('../services/composio.service.js', () => composioServiceMock);
vi.mock('../services/gateway.service.js', () => gatewayServiceMock);

const composioRoutesModule = await import('./composio.routes.js');
const composioRoutes = composioRoutesModule.default;

function testApp() {
  const app = express();
  app.use(express.json());
  app.use('/api/v1', composioRoutes);
  return app;
}

type MockMutationScope = { captureRepairAccountIds?: (ids: string[]) => void };
function captureRepairScope(scope?: MockMutationScope): void {
  scope?.captureRepairAccountIds?.(['acct-original']);
}

async function admitConnectCompletion(toolkit: string, connectionId: string): Promise<void> {
  composioServiceMock.createConnectSession.mockResolvedValueOnce({
    redirectUrl: 'https://connect.example/session', connectionId, toolkit,
  });
  await request(testApp())
    .post('/api/v1/composio/connect')
    .send({ toolkit })
    .expect(200);
}

describe('composio routes', () => {
  beforeEach(() => {
    composioRoutesModule.resetComposioRouteStateForTests();
    vi.clearAllMocks();
    gatewayServiceMock.getLocalGatewayCredentials.mockReturnValue(null);
  });

  it('returns a retryable error instead of a false not-connected catalog when status is unavailable', async () => {
    composioServiceMock.listToolkitsSummary.mockRejectedValue(
      new composioServiceMock.ComposioStatusUnavailableError(
        "Couldn't verify existing Composio connections. Try again in a moment.",
      ),
    );

    const response = await request(testApp()).get('/api/v1/composio/toolkits');

    expect(response.status).toBe(503);
    expect(response.body).toEqual({
      error: "Couldn't verify existing Composio connections. Try again in a moment.",
    });
    expect(response.body).not.toHaveProperty('toolkits');
  });

  it('preserves the successful catalog response', async () => {
    const summary = {
      configured: true,
      toolkits: [
        { slug: 'gmail', status: 'connected', enabled: true },
        { slug: 'slack', status: 'not_connected', enabled: false },
      ],
    };
    composioServiceMock.listToolkitsSummary.mockResolvedValue(summary);
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    const response = await request(testApp()).get('/api/v1/composio/toolkits');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ ...summary, runtimeReady: false, runtimeSyncing: false });
  });

  it('reconciles a configured catalog against the canonical local gateway fallback', async () => {
    composioServiceMock.listToolkitsSummary.mockResolvedValue({ configured: true, toolkits: [] });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);
    gatewayServiceMock.getLocalGatewayCredentials.mockReturnValue({
      gateway_url: 'http://127.0.0.1:18789',
      gateway_token: 'local-token',
      hosting_provider: 'local',
    });
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });

    await request(testApp()).get('/api/v1/composio/toolkits').expect(200);

    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledWith(
      'user-1',
      'http://127.0.0.1:18789',
      'local-token',
      undefined,
    );
    expect(gatewayServiceMock.getSetupPassword).not.toHaveBeenCalled();
  });

  it('reconciles a configured empty catalog so a stale MCP server can be removed', async () => {
    const summary = {
      configured: true,
      toolkits: [
        { slug: 'gmail', status: 'not_connected', enabled: false },
        { slug: 'slack', status: 'not_connected', enabled: false },
      ],
    };
    composioServiceMock.listToolkitsSummary.mockResolvedValue(summary);
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example',
      gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    const response = await request(testApp()).get('/api/v1/composio/toolkits');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ ...summary, runtimeReady: true, runtimeSyncing: false });
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledWith(
      'user-1',
      'https://gw.example',
      'token',
      'setup',
    );
  });

  it('awaits failed reconciliation and reports an ACTIVE grant as runtime-not-ready', async () => {
    composioServiceMock.listToolkitsSummary.mockResolvedValue({
      configured: true,
      toolkits: [{ slug: 'discord', status: 'connected', enabled: true }],
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example',
      gateway_token: 'token',
      hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockRejectedValue(new Error('config.patch failed'));

    const response = await request(testApp()).get('/api/v1/composio/toolkits');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      configured: true,
      toolkits: [{ slug: 'discord', status: 'connected', enabled: true }],
      runtimeReady: false,
      runtimeSyncing: false,
    });
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce();
  });

  it('returns the catalog before the client deadline while slow reconciliation keeps syncing', async () => {
    composioServiceMock.listToolkitsSummary.mockResolvedValue({
      configured: true,
      toolkits: [{ slug: 'discord', status: 'connected', enabled: true }],
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token', hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockImplementation(() => new Promise(() => {}));

    const startedAt = Date.now();
    const response = await request(testApp()).get('/api/v1/composio/toolkits');
    const elapsedMs = Date.now() - startedAt;

    expect(elapsedMs).toBeLessThan(1_000); // Safely below the clients' 30-second timeout.
    expect(response.body).toMatchObject({ runtimeReady: false, runtimeSyncing: true });
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce();
  });

  it('fails retryably before the client deadline when the catalog summary itself stalls', async () => {
    composioServiceMock.listToolkitsSummary
      .mockImplementationOnce(() => new Promise(() => {}))
      .mockResolvedValueOnce({ configured: true, toolkits: [] });

    const startedAt = Date.now();
    const response = await request(testApp()).get('/api/v1/composio/toolkits');
    const elapsedMs = Date.now() - startedAt;

    expect(elapsedMs).toBeLessThan(1_000);
    expect(response.status).toBe(503);
    expect(response.body.error).toContain("Couldn't verify existing Composio connections");
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();

    const retry = await request(testApp()).get('/api/v1/composio/toolkits');
    expect(retry.status).toBe(200);
    expect(composioServiceMock.listToolkitsSummary).toHaveBeenCalledTimes(2);
  });

  it('reports OAuth completion reconciliation as syncing within the bounded observation window', async () => {
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-1', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token', hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: false, reason: 'busy' });

    await admitConnectCompletion('discord', 'connection-1');
    const response = await request(testApp())
      .get('/api/v1/composio/status/connection-1?toolkit=discord');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-1', enabled: true,
      runtimeReady: false,
      runtimeSyncing: true,
    });
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledWith(
      'user-1', 'discord', true, expect.any(Object),
    );
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce();
  });

  it('does not let a stale connected status supersede a pause admitted while status awaits', async () => {
    let finishStatus!: (state: {
      toolkit: string; status: string; connectedAccountId: string; enabled: boolean;
    }) => void;
    composioServiceMock.getConnectionStatus.mockImplementationOnce(
      () => new Promise(resolve => { finishStatus = resolve; }),
    );
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-old');
    const staleStatus = request(testApp())
      .get('/api/v1/composio/status/connection-old?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledOnce());
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    finishStatus({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-old', enabled: true,
    });

    const response = await staleStatus;
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({ status: 'connected', enabled: false });
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2]))
      .toEqual([false, false]);
  });

  it('does not let a stale connected status supersede a revoke admitted while status awaits', async () => {
    let finishStatus!: (state: {
      toolkit: string; status: string; connectedAccountId: string; enabled: boolean;
    }) => void;
    composioServiceMock.getConnectionStatus.mockImplementationOnce(
      () => new Promise(resolve => { finishStatus = resolve; }),
    );
    composioServiceMock.disconnectToolkit.mockResolvedValue({ deleted: 1 });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-old');
    const staleStatus = request(testApp())
      .get('/api/v1/composio/status/connection-old?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledOnce());
    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(200);
    finishStatus({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-old', enabled: true,
    });

    const response = await staleStatus;
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({
      status: 'not_connected', connectedAccountId: null, enabled: false,
    });
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.setToolkitEnabled).not.toHaveBeenCalled();
  });

  it('re-pauses a new grant when Connect completes after a zero-target pause', async () => {
    let finishConnect!: (session: {
      redirectUrl: string; connectionId: string; toolkit: string;
    }) => void;
    let finishRepause!: (result: { updated: number }) => void;
    composioServiceMock.createConnectSession.mockImplementationOnce(
      () => new Promise(resolve => { finishConnect = resolve; }),
    );
    composioServiceMock.setToolkitEnabled
      .mockResolvedValueOnce({ updated: 0 })
      .mockImplementationOnce(() => new Promise(resolve => { finishRepause = resolve; }));
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-new', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    const connect = request(testApp())
      .post('/api/v1/composio/connect')
      .send({ toolkit: 'discord' })
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.createConnectSession).toHaveBeenCalledOnce());
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    finishConnect({
      redirectUrl: 'https://connect.example/session', connectionId: 'connection-new', toolkit: 'discord',
    });
    expect((await connect).status).toBe(200);
    const status = await request(testApp())
      .get('/api/v1/composio/status/connection-new?toolkit=discord')
      .expect(200);

    expect(status.body).toMatchObject({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-new', enabled: false,
      runtimeReady: false, runtimeSyncing: true,
    });
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2]))
      .toEqual([false, false]);
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();
    finishRepause({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
  });

  it('re-lists after a second stale completion arrives behind an already-listed convergence', async () => {
    let finishFirstConvergence!: (result: { updated: number }) => void;
    let finishSecondConvergence!: (result: { updated: number }) => void;
    let firstConvergenceListed!: () => void;
    const firstConvergenceHasListed = new Promise<void>(resolve => {
      firstConvergenceListed = resolve;
    });
    composioServiceMock.setToolkitEnabled
      .mockResolvedValueOnce({ updated: 0 })
      .mockImplementationOnce((_userId, _toolkit, _enabled, scope: MockMutationScope) => {
        scope.captureRepairAccountIds?.(['acct-a']);
        firstConvergenceListed();
        return new Promise(resolve => { finishFirstConvergence = resolve; });
      })
      .mockImplementationOnce((_userId, _toolkit, _enabled, scope: MockMutationScope) => {
        scope.captureRepairAccountIds?.(['acct-a', 'acct-b']);
        return new Promise(resolve => { finishSecondConvergence = resolve; });
      });
    composioServiceMock.getConnectionStatus.mockImplementation(
      (_userId, connectionId: string) => Promise.resolve({
        toolkit: 'discord',
        status: 'connected',
        connectedAccountId: connectionId === 'connection-a' ? 'acct-a' : 'acct-b',
        enabled: true,
      }),
    );
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-a');
    await admitConnectCompletion('discord', 'connection-b');
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });

    const statusA = request(testApp())
      .get('/api/v1/composio/status/connection-a?toolkit=discord')
      .then(response => response);
    await firstConvergenceHasListed;

    // Grant B becomes ACTIVE only after the shared convergence pass has already listed grant A.
    // Its stale status must dirty that worker and force a post-coalescing provider re-list.
    const statusB = request(testApp())
      .get('/api/v1/composio/status/connection-b?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledTimes(2));
    finishFirstConvergence({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(3));
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();

    finishSecondConvergence({ updated: 1 });
    const [responseA, responseB] = await Promise.all([statusA, statusB]);
    expect(responseA.body).toMatchObject({ status: 'connected', enabled: false });
    expect(responseB.body).toMatchObject({ status: 'connected', enabled: false });
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
  });

  it('fences a dirty pause worker before a newer revoke and syncs only the revoke', async () => {
    let finishPauseConvergence!: (result: { updated: number }) => void;
    let finishRevoke!: (result: { deleted: number }) => void;
    composioServiceMock.setToolkitEnabled
      .mockResolvedValueOnce({ updated: 0 })
      .mockImplementationOnce(() => new Promise(resolve => {
        finishPauseConvergence = resolve;
      }))
      // A stale dirty pass would consume this fallback and expose the regression as call 3.
      .mockResolvedValue({ updated: 1 });
    composioServiceMock.disconnectToolkit.mockImplementationOnce(
      () => new Promise(resolve => { finishRevoke = resolve; }),
    );
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-stale', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-a');
    await admitConnectCompletion('discord', 'connection-b');
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);

    const statusA = request(testApp())
      .get('/api/v1/composio/status/connection-a?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2));
    const statusB = request(testApp())
      .get('/api/v1/composio/status/connection-b?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledTimes(2));

    // Status B dirtied the running pause worker. Revoke now owns the lane before that first pass
    // settles, so the worker must not enqueue its requested trailing pause behind the revoke.
    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(503);
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });

    finishPauseConvergence({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledOnce());
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();

    finishRevoke({ deleted: 1 });
    await Promise.all([statusA, statusB]);
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
    await new Promise(resolve => setTimeout(resolve, 150));
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledOnce();
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce();
  });

  it('fences a dirty revoke worker before a newer resume and syncs only the resume', async () => {
    let finishRevokeConvergence!: (result: { deleted: number }) => void;
    let finishResume!: (result: { updated: number }) => void;
    composioServiceMock.disconnectToolkit
      .mockResolvedValueOnce({ deleted: 0 })
      .mockImplementationOnce(() => new Promise(resolve => {
        finishRevokeConvergence = resolve;
      }))
      // A stale dirty pass would consume this fallback and expose the regression as call 3.
      .mockResolvedValue({ deleted: 1 });
    composioServiceMock.setToolkitEnabled.mockImplementationOnce(
      () => new Promise(resolve => { finishResume = resolve; }),
    );
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-stale', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-a');
    await admitConnectCompletion('discord', 'connection-b');
    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(200);

    const statusA = request(testApp())
      .get('/api/v1/composio/status/connection-a?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2));
    const statusB = request(testApp())
      .get('/api/v1/composio/status/connection-b?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledTimes(2));

    // Status B dirtied the running revoke worker. Resume is the new lane owner and must run next;
    // the old worker cannot append a second revoke behind it and delete the resumed grant.
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: true })
      .expect(503);
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });

    finishRevokeConvergence({ deleted: 1 });
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledOnce());
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();

    finishResume({ updated: 1 });
    await Promise.all([statusA, statusB]);
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
    await new Promise(resolve => setTimeout(resolve, 150));
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2])).toEqual([true]);
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce();
  });

  it('retargets a settled pause convergence to newer revoke intent before runtime sync', async () => {
    let finishPauseConvergence!: (result: { updated: number }) => void;
    let finishInitialRevoke!: (result: { deleted: number }) => void;
    let finishRevokeConvergence!: (result: { deleted: number }) => void;
    composioServiceMock.setToolkitEnabled
      .mockResolvedValueOnce({ updated: 0 })
      .mockImplementationOnce(() => new Promise(resolve => {
        finishPauseConvergence = resolve;
      }));
    composioServiceMock.disconnectToolkit
      .mockImplementationOnce(() => new Promise(resolve => { finishInitialRevoke = resolve; }))
      .mockImplementationOnce(() => new Promise(resolve => { finishRevokeConvergence = resolve; }));
    composioServiceMock.getConnectionStatus.mockImplementation(
      (_userId, connectionId: string) => Promise.resolve({
        toolkit: 'discord',
        status: 'connected',
        connectedAccountId: connectionId === 'connection-a' ? 'acct-a' : 'acct-b',
        enabled: true,
      }),
    );
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-a');
    await admitConnectCompletion('discord', 'connection-b');
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    const statusA = request(testApp())
      .get('/api/v1/composio/status/connection-a?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2));

    // Revoke becomes the retained generation while the older pause worker is still awaiting its
    // provider write. The route times out, but admission already made revoke authoritative.
    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(503);
    const statusB = request(testApp())
      .get('/api/v1/composio/status/connection-b?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledTimes(2));

    finishPauseConvergence({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledOnce());
    finishInitialRevoke({ deleted: 0 });
    await vi.waitFor(() => expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2));

    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();

    finishRevokeConvergence({ deleted: 1 });
    const [responseA, responseB] = await Promise.all([statusA, statusB]);
    expect(responseA.body).toMatchObject({ status: 'connected', enabled: false });
    expect(responseB.body).toMatchObject({
      status: 'not_connected', connectedAccountId: null, enabled: false,
    });
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
  });

  it('never syncs a rejected stale worker and syncs exactly once after its delayed repair', async () => {
    let finishRepair!: (result: { updated: number }) => void;
    composioServiceMock.setToolkitEnabled
      .mockResolvedValueOnce({ updated: 0 })
      .mockImplementationOnce((_userId, _toolkit, _enabled, scope: MockMutationScope) => {
        scope.captureRepairAccountIds?.(['acct-late']);
        return Promise.reject(new composioServiceMock.ComposioMutationTimeoutError(
          'stale convergence timed out',
        ));
      })
      .mockImplementationOnce(() => new Promise(resolve => { finishRepair = resolve; }));
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-late', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-late');
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });

    const response = await request(testApp())
      .get('/api/v1/composio/status/connection-late?toolkit=discord')
      .expect(200);
    expect(response.body).toMatchObject({
      status: 'connected', enabled: false, runtimeReady: false, runtimeSyncing: true,
    });
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2);

    // Test cadence mirrors production ordering at smaller scale: quarantine is 25ms, but the
    // first authoritative repair is not admitted until 100ms. The rejected worker must not use
    // that gap to wire the still-ACTIVE grant.
    await new Promise(resolve => setTimeout(resolve, 60));
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2);
    await vi.waitFor(
      () => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(3),
      { timeout: 500 },
    );
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();

    finishRepair({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
    await new Promise(resolve => setTimeout(resolve, 250));
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(3);
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce();
  });

  it('re-revokes a new grant when Connect completes after a zero-target revoke', async () => {
    let finishConnect!: (session: {
      redirectUrl: string; connectionId: string; toolkit: string;
    }) => void;
    let finishRerevoke!: (result: { deleted: number }) => void;
    composioServiceMock.createConnectSession.mockImplementationOnce(
      () => new Promise(resolve => { finishConnect = resolve; }),
    );
    composioServiceMock.disconnectToolkit
      .mockResolvedValueOnce({ deleted: 0 })
      .mockImplementationOnce(() => new Promise(resolve => { finishRerevoke = resolve; }));
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-new', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    const connect = request(testApp())
      .post('/api/v1/composio/connect')
      .send({ toolkit: 'discord' })
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.createConnectSession).toHaveBeenCalledOnce());
    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(200);
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    finishConnect({
      redirectUrl: 'https://connect.example/session', connectionId: 'connection-new', toolkit: 'discord',
    });
    expect((await connect).status).toBe(200);
    const status = await request(testApp())
      .get('/api/v1/composio/status/connection-new?toolkit=discord')
      .expect(200);

    expect(status.body).toMatchObject({
      toolkit: 'discord', status: 'not_connected', connectedAccountId: null, enabled: false,
      runtimeReady: false, runtimeSyncing: true,
    });
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.setToolkitEnabled).not.toHaveBeenCalled();
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();
    finishRerevoke({ deleted: 1 });
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
  });

  it('does not publish ACTIVE from status admitted while pause is already authoritative', async () => {
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-old', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    const response = await request(testApp())
      .get('/api/v1/composio/status/connection-old?toolkit=discord')
      .expect(200);

    expect(response.body).toMatchObject({ status: 'connected', enabled: false });
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2]))
      .toEqual([false, false]);
  });

  it('does not publish ACTIVE from status admitted while revoke is already authoritative', async () => {
    composioServiceMock.disconnectToolkit.mockResolvedValue({ deleted: 1 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-old', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(200);
    const response = await request(testApp())
      .get('/api/v1/composio/status/connection-old?toolkit=discord')
      .expect(200);

    expect(response.body).toMatchObject({
      status: 'not_connected', connectedAccountId: null, enabled: false,
    });
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.setToolkitEnabled).not.toHaveBeenCalled();
  });

  it('keeps pending Connect authority stale after a newer pause intent cache expires', async () => {
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-new', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-delayed');
    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    // Desired-operation details expire after 1s in tests; the monotonic lane generation must not.
    await new Promise(resolve => setTimeout(resolve, 1_100));
    const response = await request(testApp())
      .get('/api/v1/composio/status/connection-delayed?toolkit=discord')
      .expect(200);

    expect(response.body).toMatchObject({ status: 'connected', enabled: false });
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2]))
      .toEqual([false, false]);
  });

  it('keeps pending Connect authority stale after a newer revoke intent cache expires', async () => {
    composioServiceMock.disconnectToolkit.mockResolvedValue({ deleted: 1 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-new', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await admitConnectCompletion('discord', 'connection-delayed');
    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(200);
    await new Promise(resolve => setTimeout(resolve, 1_100));
    const response = await request(testApp())
      .get('/api/v1/composio/status/connection-delayed?toolkit=discord')
      .expect(200);

    expect(response.body).toMatchObject({
      status: 'not_connected', connectedAccountId: null, enabled: false,
    });
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2);
    expect(composioServiceMock.setToolkitEnabled).not.toHaveBeenCalled();
  });

  it('does not restore ACTIVE after markers and generations expire, including a slow Connect create', async () => {
    await admitConnectCompletion('discord', 'connection-expired-pause');
    await admitConnectCompletion('slack', 'connection-expired-revoke');

    let finishSlowConnect!: (session: {
      redirectUrl: string; connectionId: string; toolkit: string;
    }) => void;
    composioServiceMock.createConnectSession.mockImplementationOnce(
      () => new Promise(resolve => { finishSlowConnect = resolve; }),
    );
    const slowConnect = request(testApp())
      .post('/api/v1/composio/connect')
      .send({ toolkit: 'gmail' })
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.createConnectSession).toHaveBeenCalledTimes(3));

    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    composioServiceMock.disconnectToolkit.mockResolvedValue({ deleted: 1 });
    composioServiceMock.getConnectionStatus.mockImplementation(
      (_userId: string, _connectionId: string, toolkit: string) => Promise.resolve({
        toolkit, status: 'connected', connectedAccountId: `acct-${toolkit}`, enabled: true,
      }),
    );
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    await request(testApp())
      .delete('/api/v1/composio/toolkit/slack/connections')
      .expect(200);
    await request(testApp())
      .post('/api/v1/composio/toolkit/gmail/enabled')
      .send({ enabled: false })
      .expect(200);

    // Test bounds: Connect observation 200ms, marker 5s, generation 6s. The slow Gmail request
    // releases its admission token at the observation deadline; all three generations then expire.
    await new Promise(resolve => setTimeout(resolve, 6_200));
    finishSlowConnect({
      redirectUrl: 'https://connect.example/session',
      connectionId: 'connection-slow-create',
      toolkit: 'gmail',
    });
    expect((await slowConnect).status).toBe(503);

    await request(testApp())
      .get('/api/v1/composio/status/connection-expired-pause?toolkit=discord')
      .expect(200);
    await request(testApp())
      .get('/api/v1/composio/status/connection-expired-revoke?toolkit=slack')
      .expect(200);
    await request(testApp())
      .get('/api/v1/composio/status/connection-slow-create?toolkit=gmail')
      .expect(200);

    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => [call[1], call[2]]))
      .toEqual([['discord', false], ['gmail', false]]);
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledOnce();
  }, 10_000);

  it('bounds never-settling Connect admissions and ignores every late session resolution', async () => {
    const timeoutSpy = vi.spyOn(globalThis, 'setTimeout');
    const finishConnects: Array<(session: {
      redirectUrl: string; connectionId: string; toolkit: string;
    }) => void> = [];
    composioServiceMock.createConnectSession.mockImplementation(
      () => new Promise(resolve => { finishConnects.push(resolve); }),
    );
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-late', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    const stalledConnects = [0, 1, 2].map(() => request(testApp())
      .post('/api/v1/composio/connect')
      .send({ toolkit: 'discord' })
      .then(response => response));
    await vi.waitFor(() => expect(composioServiceMock.createConnectSession).toHaveBeenCalledTimes(3));

    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(200);
    const timedOutResponses = await Promise.all(stalledConnects);
    expect(timedOutResponses.map(response => response.status)).toEqual([503, 503, 503]);

    // Generation retention is 6s in tests. Each HTTP timeout must release its admission token, so
    // the one retention callback can clean the lane without leaving another cleanup handle behind.
    await new Promise(resolve => setTimeout(resolve, 6_200));
    expect(timeoutSpy.mock.calls.filter(call => call[1] === 6_000)).toHaveLength(1);

    finishConnects.forEach((finish, index) => finish({
      redirectUrl: 'https://connect.example/session',
      connectionId: `connection-late-${index}`,
      toolkit: 'discord',
    }));
    await Promise.resolve();

    await request(testApp())
      .get('/api/v1/composio/status/connection-late-0?toolkit=discord')
      .expect(200);
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2])).toEqual([false]);
    timeoutSpy.mockRestore();
  }, 10_000);

  it('reconciles the cached MCP runtime after pausing or resuming a connector', async () => {
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example',
      gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    const response = await request(testApp())
      .post('/api/v1/composio/toolkit/slack/enabled')
      .send({ enabled: false });

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      updated: 1,
      mutationStatus: 'completed',
      mutationAccepted: true,
      mutationCompleted: true,
      runtimeReady: true,
      runtimeSyncing: false,
    });
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledWith(
      'user-1',
      'https://gw.example',
      'token',
      'setup',
    );
  });

  it('keeps a successful enable grant but reports runtime-not-ready when reconciliation fails', async () => {
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    composioServiceMock.ensureComposioMcpWired.mockRejectedValue(new Error('config.patch failed'));
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token', hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    const response = await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: true });

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      updated: 1,
      mutationStatus: 'completed',
      mutationAccepted: true,
      mutationCompleted: true,
      runtimeReady: false,
      runtimeSyncing: false,
    });
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledWith(
      'user-1', 'discord', true, expect.any(Object),
    );
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce();
  });

  it('returns a committed pause before the client deadline while runtime cleanup keeps syncing', async () => {
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 1 });
    composioServiceMock.ensureComposioMcpWired.mockImplementation(() => new Promise(() => {}));
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token', hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    const startedAt = Date.now();
    const response = await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false });
    const elapsedMs = Date.now() - startedAt;

    expect(elapsedMs).toBeLessThan(1_000); // Mutation success cannot cross the 30-second client deadline.
    expect(response.body).toEqual({
      updated: 1,
      mutationStatus: 'completed',
      mutationAccepted: true,
      mutationCompleted: true,
      runtimeReady: false,
      runtimeSyncing: true,
    });
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledWith(
      'user-1', 'discord', false, expect.any(Object),
    );
  });

  it('acknowledges a stalled grant mutation before the client deadline without claiming completion', async () => {
    let finish!: (value: { updated: number }) => void;
    composioServiceMock.setToolkitEnabled.mockImplementation(() => new Promise(resolve => { finish = resolve; }));

    const startedAt = Date.now();
    const response = await request(testApp())
      .post('/api/v1/composio/toolkit/gmail/enabled')
      .send({ enabled: false });
    const elapsedMs = Date.now() - startedAt;

    expect(elapsedMs).toBeLessThan(1_000);
    expect(response.status).toBe(503);
    expect(response.body).toEqual({
      error: 'Composio is still applying this change. Refresh Connections to confirm the final state.',
      mutationStatus: 'unknown',
      mutationCompleted: false,
      runtimeReady: false,
      runtimeSyncing: true,
    });

    const retry = await request(testApp())
      .post('/api/v1/composio/toolkit/gmail/enabled')
      .send({ enabled: false });
    expect(retry.status).toBe(503);
    expect(retry.body.mutationCompleted).toBe(false);
    // The retry joins the same desired-state job instead of starting a second partial batch.
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledOnce();
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();
    finish({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
  });

  it('waits for an in-flight mutation before publishing a refreshed catalog', async () => {
    let finish!: (value: { updated: number }) => void;
    let enabled = true;
    const order: string[] = [];
    composioServiceMock.setToolkitEnabled.mockImplementation(() => {
      order.push('mutation-start');
      return new Promise(resolve => { finish = resolve; });
    });
    composioServiceMock.listToolkitsSummary.mockImplementation(() => {
      order.push('catalog-read');
      return Promise.resolve({
        configured: true,
        toolkits: [{ slug: 'discord', status: 'connected', enabled }],
      });
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    const mutation = request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledOnce());

    // Scaled test equivalent of a 5-second provider mutation with refresh requested at 3 seconds.
    await new Promise(resolve => setTimeout(resolve, 30));
    const refresh = request(testApp()).get('/api/v1/composio/toolkits').then(response => response);
    await new Promise(resolve => setTimeout(resolve, 15));
    expect(composioServiceMock.listToolkitsSummary).not.toHaveBeenCalled();

    enabled = false;
    order.push('mutation-finish');
    finish({ updated: 1 });
    const [mutationResponse, refreshResponse] = await Promise.all([mutation, refresh]);

    expect(mutationResponse.status).toBe(503);
    expect(refreshResponse.status).toBe(200);
    expect(refreshResponse.body.toolkits[0]).toMatchObject({ slug: 'discord', enabled: false });
    expect(order).toEqual(['mutation-start', 'mutation-finish', 'catalog-read']);
  });

  it('does not reuse a pre-mutation catalog read after waiting for the mutation lane', async () => {
    let finishOldRead!: (value: unknown) => void;
    let finishMutation!: (value: { updated: number }) => void;
    composioServiceMock.listToolkitsSummary
      .mockImplementationOnce(() => new Promise(resolve => { finishOldRead = resolve; }))
      .mockResolvedValueOnce({
        configured: true,
        toolkits: [{ slug: 'discord', status: 'connected', enabled: false }],
      });
    composioServiceMock.setToolkitEnabled.mockImplementation(
      () => new Promise(resolve => { finishMutation = resolve; }),
    );
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    const staleLoad = request(testApp()).get('/api/v1/composio/toolkits').then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.listToolkitsSummary).toHaveBeenCalledOnce());
    const mutation = request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledOnce());
    const refresh = request(testApp()).get('/api/v1/composio/toolkits').then(response => response);

    finishMutation({ updated: 1 });
    const [mutationResponse, refreshResponse] = await Promise.all([mutation, refresh]);
    expect([200, 503]).toContain(mutationResponse.status);
    expect(refreshResponse.body.toolkits[0]).toMatchObject({ slug: 'discord', enabled: false });
    expect(composioServiceMock.listToolkitsSummary).toHaveBeenCalledTimes(2);

    finishOldRead({
      configured: true,
      toolkits: [{ slug: 'discord', status: 'connected', enabled: true }],
    });
    await staleLoad;
  });

  it('serializes alternating grant intents so the newest desired state runs last', async () => {
    const finishes: Array<(value: { updated: number }) => void> = [];
    composioServiceMock.setToolkitEnabled.mockImplementation(() => new Promise(resolve => finishes.push(resolve)));

    await request(testApp()).post('/api/v1/composio/toolkit/slack/enabled').send({ enabled: false }).expect(503);
    const resume = request(testApp()).post('/api/v1/composio/toolkit/slack/enabled').send({ enabled: true });
    const latestPause = request(testApp()).post('/api/v1/composio/toolkit/slack/enabled').send({ enabled: false });
    await Promise.all([resume, latestPause]);
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(1);

    finishes[0]({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2));
    finishes[1]({ updated: 1 });
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(3));
    finishes[2]({ updated: 1 });
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2])).toEqual([false, true, false]);
  });

  it('quarantines an immediately rejected timeout before reconverging the newest intent', async () => {
    let rejectFirst!: (error: Error) => void;
    composioServiceMock.setToolkitEnabled
      .mockImplementationOnce(
        (_userId: string, _toolkit: string, _enabled: boolean, scope?: MockMutationScope) => {
          captureRepairScope(scope);
          return new Promise((_resolve, reject) => { rejectFirst = reject; });
        },
      )
      .mockImplementationOnce(
        (_userId: string, _toolkit: string, _enabled: boolean, scope?: MockMutationScope) => {
          captureRepairScope(scope);
          return Promise.resolve({ updated: 1 });
        },
      );

    await request(testApp()).post('/api/v1/composio/toolkit/discord/enabled').send({ enabled: false }).expect(503);
    const resume = request(testApp()).post('/api/v1/composio/toolkit/discord/enabled').send({ enabled: true });
    rejectFirst(new composioServiceMock.ComposioMutationTimeoutError('provider timed out'));
    await resume.expect(503);
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledOnce();

    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2));
    expect(composioServiceMock.setToolkitEnabled.mock.calls.map(call => call[2])).toEqual([false, true]);
    // Continued authoritative repair passes re-list/reapply the latest intent in case the aborted
    // remote pause commits after the first post-quarantine resume.
    await vi.waitFor(
      () => expect(composioServiceMock.setToolkitEnabled.mock.calls.length).toBeGreaterThanOrEqual(3),
      { timeout: 750 },
    );
    expect(composioServiceMock.setToolkitEnabled.mock.calls.at(-1)?.[2]).toBe(true);
  });

  it('reconciles the gateway again after a late idempotent provider repair', async () => {
    let rejectInitial!: (error: Error) => void;
    composioServiceMock.setToolkitEnabled
      .mockImplementationOnce(
        (_userId: string, _toolkit: string, _enabled: boolean, scope?: MockMutationScope) => {
          captureRepairScope(scope);
          return new Promise((_resolve, reject) => { rejectInitial = reject; });
        },
      )
      .mockResolvedValue({ updated: 0 });
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token', hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    await request(testApp())
      .post('/api/v1/composio/toolkit/discord/enabled')
      .send({ enabled: false })
      .expect(503);
    rejectInitial(new composioServiceMock.ComposioMutationTimeoutError('provider timed out'));

    // The timeout path performs its initial post-quarantine reconciliation first.
    await vi.waitFor(() => expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledOnce());
    // A later repair returning updated:0 still represents authoritative provider convergence and
    // must trigger a second gateway scope reconciliation.
    await vi.waitFor(
      () => expect(composioServiceMock.ensureComposioMcpWired.mock.calls.length).toBeGreaterThanOrEqual(2),
      { timeout: 750 },
    );
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(2);
    await expect(composioServiceMock.setToolkitEnabled.mock.results[1]?.value).resolves.toEqual({ updated: 0 });
  });

  it('continues all provider repair passes while gateway reconciliation is stalled', async () => {
    let rejectInitial!: (error: Error) => void;
    composioServiceMock.setToolkitEnabled
      .mockImplementationOnce(
        (_userId: string, _toolkit: string, _enabled: boolean, scope?: MockMutationScope) => {
          captureRepairScope(scope);
          return new Promise((_resolve, reject) => { rejectInitial = reject; });
        },
      )
      .mockResolvedValue({ updated: 0 });
    composioServiceMock.ensureComposioMcpWired.mockImplementation(() => new Promise(() => {}));
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token', hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    await request(testApp())
      .post('/api/v1/composio/toolkit/slack/enabled')
      .send({ enabled: false })
      .expect(503);
    rejectInitial(new composioServiceMock.ComposioMutationTimeoutError('provider timed out'));

    await vi.waitFor(
      () => expect(composioServiceMock.setToolkitEnabled.mock.calls
        .filter(call => call[1] === 'slack')).toHaveLength(4),
      { timeout: 750 },
    );
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalled();
  });

  it('supersedes a timed-out pause repair when a newer OAuth connection is observed ACTIVE', async () => {
    let rejectPause!: (error: Error) => void;
    composioServiceMock.setToolkitEnabled.mockImplementation(
      (_userId: string, _toolkit: string, enabled: boolean, scope?: MockMutationScope) => {
        captureRepairScope(scope);
        return enabled
          ? Promise.resolve({ updated: 0 })
          : new Promise((_resolve, reject) => { rejectPause = reject; });
      },
    );
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'gmail', status: 'connected', connectedAccountId: 'acct-new', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await request(testApp())
      .post('/api/v1/composio/toolkit/gmail/enabled')
      .send({ enabled: false })
      .expect(503);
    rejectPause(new composioServiceMock.ComposioMutationTimeoutError('pause timed out'));

    await admitConnectCompletion('gmail', 'acct-new');
    await request(testApp())
      .get('/api/v1/composio/status/acct-new?toolkit=gmail')
      .expect(200);
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled.mock.calls
      .some(call => call[1] === 'gmail' && call[2] === true)).toBe(true));
    await new Promise(resolve => setTimeout(resolve, 250));

    const gmailIntents = composioServiceMock.setToolkitEnabled.mock.calls
      .filter(call => call[1] === 'gmail')
      .map(call => call[2]);
    expect(gmailIntents[0]).toBe(false);
    expect(gmailIntents.slice(1).every(enabled => enabled === true)).toBe(true);
  });

  it('supersedes a timed-out revoke repair when a newer OAuth connection is observed ACTIVE', async () => {
    let rejectRevoke!: (error: Error) => void;
    composioServiceMock.disconnectToolkit.mockImplementation(
      () => new Promise((_resolve, reject) => { rejectRevoke = reject; }),
    );
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 0 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'slack', status: 'connected', connectedAccountId: 'acct-new', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await request(testApp())
      .delete('/api/v1/composio/toolkit/slack/connections')
      .expect(503);
    rejectRevoke(new composioServiceMock.ComposioMutationTimeoutError('revoke timed out'));

    await admitConnectCompletion('slack', 'acct-new');
    await request(testApp())
      .get('/api/v1/composio/status/acct-new?toolkit=slack')
      .expect(200);
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled)
      .toHaveBeenCalledWith('user-1', 'slack', true, expect.any(Object)));
    await new Promise(resolve => setTimeout(resolve, 250));

    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(1);
    expect(composioServiceMock.setToolkitEnabled.mock.calls
      .filter(call => call[1] === 'slack').every(call => call[2] === true)).toBe(true);
  });

  it('fences a broad revoke repair whose account list returns after OAuth reconnect', async () => {
    let rejectInitial!: (error: Error) => void;
    let finishRepairList!: (ids: string[]) => void;
    const deletedIds: string[] = [];
    composioServiceMock.disconnectToolkit
      .mockImplementationOnce(
        (_userId: string, _toolkit: string, scope?: { captureRepairAccountIds?: (ids: string[]) => void }) => {
          scope?.captureRepairAccountIds?.(['acct-old']);
          return new Promise((_resolve, reject) => { rejectInitial = reject; });
        },
      )
      .mockImplementationOnce(
        (_userId: string, _toolkit: string, scope?: {
          isCurrent?: () => boolean;
          repairAccountIds?: readonly string[];
        }) =>
          new Promise<{ deleted: number }>(resolve => {
            finishRepairList = ids => {
              const repairIds = new Set(scope?.repairAccountIds ?? []);
              for (const id of ids.filter(candidate => repairIds.has(candidate))) {
                if (scope?.isCurrent?.() === false) break;
                deletedIds.push(id);
              }
              resolve({ deleted: deletedIds.length });
            };
          }),
      );
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 0 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-new-oauth', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(503);
    rejectInitial(new composioServiceMock.ComposioMutationTimeoutError('revoke timed out'));
    await vi.waitFor(() => expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledTimes(2));

    // The repair is admitted and waiting on its broad list. Publishing the new ACTIVE grant must
    // supersede its generation before that list returns containing the replacement account.
    await admitConnectCompletion('discord', 'acct-new-oauth');
    const connected = request(testApp())
      .get('/api/v1/composio/status/acct-new-oauth?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledOnce());
    await new Promise(resolve => setTimeout(resolve, 15));
    finishRepairList(['acct-new-oauth']);

    expect((await connected).status).toBe(200);
    expect(deletedIds).toEqual([]);
    await vi.waitFor(() => expect(composioServiceMock.setToolkitEnabled)
      .toHaveBeenCalledWith('user-1', 'discord', true, expect.any(Object)));
  });

  it('fences the original revoke when its abort-ignoring list returns after OAuth reconnect', async () => {
    let finishOriginalList!: (ids: string[]) => void;
    const deletedIds: string[] = [];
    composioServiceMock.disconnectToolkit.mockImplementationOnce(
      (_userId: string, _toolkit: string, scope?: {
        isCurrent?: () => boolean;
        captureRepairAccountIds?: (ids: string[]) => void;
      }) => new Promise<{ deleted: number }>(resolve => {
        finishOriginalList = ids => {
          scope?.captureRepairAccountIds?.(ids);
          for (const id of ids) {
            if (scope?.isCurrent?.() === false) break;
            deletedIds.push(id);
          }
          resolve({ deleted: deletedIds.length });
        };
      }),
    );
    composioServiceMock.setToolkitEnabled.mockResolvedValue({ updated: 0 });
    composioServiceMock.getConnectionStatus.mockResolvedValue({
      toolkit: 'discord', status: 'connected', connectedAccountId: 'acct-new-oauth', enabled: true,
    });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue(undefined);

    await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections')
      .expect(503);

    // OAuth completion publishes a newer desired generation while the original provider list is
    // still ignoring its abort. Its late response contains only the replacement grant.
    await admitConnectCompletion('discord', 'acct-new-oauth');
    const connected = request(testApp())
      .get('/api/v1/composio/status/acct-new-oauth?toolkit=discord')
      .then(response => response);
    await vi.waitFor(() => expect(composioServiceMock.getConnectionStatus).toHaveBeenCalledOnce());
    finishOriginalList(['acct-new-oauth']);

    expect((await connected).status).toBe(200);
    expect(deletedIds).toEqual([]);
  });

  it('caps continued convergence when every repair attempt also times out', async () => {
    let rejectInitial!: (error: Error) => void;
    composioServiceMock.setToolkitEnabled
      .mockImplementationOnce(
        (_userId: string, _toolkit: string, _enabled: boolean, scope?: MockMutationScope) => {
          captureRepairScope(scope);
          return new Promise((_resolve, reject) => { rejectInitial = reject; });
        },
      )
      .mockRejectedValue(new composioServiceMock.ComposioMutationTimeoutError('repair timed out'));

    await request(testApp()).post('/api/v1/composio/toolkit/gmail/enabled').send({ enabled: false }).expect(503);
    rejectInitial(new composioServiceMock.ComposioMutationTimeoutError('initial timed out'));

    await vi.waitFor(
      () => expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(4),
      { timeout: 750 },
    );
    await new Promise(resolve => setTimeout(resolve, 250));
    expect(composioServiceMock.setToolkitEnabled).toHaveBeenCalledTimes(4);
  });

  it('reconciles the cached MCP runtime after disconnecting the final connector', async () => {
    composioServiceMock.disconnectToolkit.mockResolvedValue({ deleted: 1 });
    composioServiceMock.ensureComposioMcpWired.mockResolvedValue({ wired: true });
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example',
      gateway_token: 'token',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    const response = await request(testApp())
      .delete('/api/v1/composio/toolkit/slack/connections');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      deleted: 1,
      mutationStatus: 'completed',
      mutationAccepted: true,
      mutationCompleted: true,
      runtimeReady: true,
      runtimeSyncing: false,
    });
    expect(composioServiceMock.ensureComposioMcpWired).toHaveBeenCalledWith(
      'user-1',
      'https://gw.example',
      'token',
      'setup',
    );
  });

  it('returns a committed revoke before the client deadline while runtime cleanup keeps syncing', async () => {
    composioServiceMock.disconnectToolkit.mockResolvedValue({ deleted: 1 });
    composioServiceMock.ensureComposioMcpWired.mockImplementation(() => new Promise(() => {}));
    gatewayServiceMock.getGatewayCredentials.mockResolvedValue({
      gateway_url: 'https://gw.example', gateway_token: 'token', hosting_provider: 'fly',
    });
    gatewayServiceMock.getSetupPassword.mockResolvedValue('setup');

    const startedAt = Date.now();
    const response = await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections');
    const elapsedMs = Date.now() - startedAt;

    expect(elapsedMs).toBeLessThan(1_000);
    expect(response.body).toEqual({
      deleted: 1,
      mutationStatus: 'completed',
      mutationAccepted: true,
      mutationCompleted: true,
      runtimeReady: false,
      runtimeSyncing: true,
    });
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledWith(
      'user-1', 'discord', expect.any(Object),
    );
  });

  it('acknowledges a stalled revoke before the client deadline without claiming completion', async () => {
    let finish!: (value: { deleted: number }) => void;
    composioServiceMock.disconnectToolkit.mockImplementation(() => new Promise(resolve => { finish = resolve; }));

    const startedAt = Date.now();
    const response = await request(testApp())
      .delete('/api/v1/composio/toolkit/discord/connections');
    const elapsedMs = Date.now() - startedAt;

    expect(elapsedMs).toBeLessThan(1_000);
    expect(response.status).toBe(503);
    expect(response.body).toEqual({
      error: 'Composio is still applying this disconnect. Refresh Connections to confirm the final state.',
      mutationStatus: 'unknown',
      mutationCompleted: false,
      runtimeReady: false,
      runtimeSyncing: true,
    });
    expect(composioServiceMock.disconnectToolkit).toHaveBeenCalledOnce();
    expect(composioServiceMock.ensureComposioMcpWired).not.toHaveBeenCalled();
    finish({ deleted: 1 });
  });
});
