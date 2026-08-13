import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// vi.mock factories are hoisted above every top-level statement, so the mock fns they close over
// must be created via vi.hoisted() (which runs first) — the house pattern for every service test
// in this folder.
const mocks = vi.hoisted(() => ({
  sessionsCreate: vi.fn(),
  withGatewayRequester: vi.fn(),
  patchGatewayConfig: vi.fn(),
  tryWithUserGatewayConfigReconciliationLock: vi.fn(),
  getGatewayCredentialsWithClient: vi.fn(),
  getLocalGatewayCredentials: vi.fn(),
  getSetupPasswordWithClient: vi.fn(),
  toolkitsGet: vi.fn(),
  authConfigsList: vi.fn(),
  authConfigsCreate: vi.fn(),
  connectedAccountsLink: vi.fn(),
  connectedAccountsList: vi.fn(),
  connectedAccountsWaitForConnection: vi.fn(),
  // The RAW @composio/client delete reached via composio.client — the only path that carries
  // revoke_on_delete (the high-level connectedAccounts.delete hardcodes it undefined).
  rawConnectedAccountsDelete: vi.fn(),
  // High-level enable/disable (the pause path) — @composio/core forwards these correctly, so no
  // raw-client escape hatch is needed (unlike revoke).
  connectedAccountsEnable: vi.fn(),
  connectedAccountsDisable: vi.fn(),
  toolsExecute: vi.fn(),
}));

// composio.service.ts only ever calls the top-level `composio.create(...)` alias (see its module
// doc), which @composio/core's Composio class forwards to `sessions.create`. Mock just enough of
// the SDK surface for `client()` to construct successfully and for `getMcpConfig` to resolve.
vi.mock('@composio/core', () => ({
  Composio: class {
    create(...args: unknown[]) {
      return mocks.sessionsCreate(...args);
    }
    toolkits = { get: (...args: unknown[]) => mocks.toolkitsGet(...args) };
    authConfigs = {
      list: (...args: unknown[]) => mocks.authConfigsList(...args),
      create: (...args: unknown[]) => mocks.authConfigsCreate(...args),
    };
    connectedAccounts = {
      link: (...args: unknown[]) => mocks.connectedAccountsLink(...args),
      list: (...args: unknown[]) => mocks.connectedAccountsList(...args),
      waitForConnection: (...args: unknown[]) => mocks.connectedAccountsWaitForConnection(...args),
      enable: (...args: unknown[]) => mocks.connectedAccountsEnable(...args),
      disable: (...args: unknown[]) => mocks.connectedAccountsDisable(...args),
    };
    tools = { execute: (...args: unknown[]) => mocks.toolsExecute(...args) };
    // The underlying @composio/client — `protected` on the core type but present at runtime; this is
    // what disconnectToolkit reaches through to pass revoke_on_delete.
    client = {
      connectedAccounts: {
        delete: (...args: unknown[]) => mocks.rawConnectedAccountsDelete(...args),
      },
    };
  },
  ComposioAuthConfigNotFoundError: class extends Error {},
  ComposioConnectedAccountNotFoundError: class extends Error {},
  ConnectionRequestFailedError: class extends Error {},
  ConnectionRequestTimeoutError: class extends Error {},
}));

vi.mock('./gateway-pair.service.js', () => ({
  withGatewayRequester: (
    url: string,
    token: string,
    fn: (request: (method: string, params?: Record<string, unknown>) => Promise<any>, events: any) => Promise<any>,
    setupPassword?: string,
  ) => mocks.withGatewayRequester(url, token, async (request: any, events: any) => fn(
    async (method: string, params: Record<string, unknown> = {}) => {
      const response = await request(method, params);
      if (method === 'config.get' && response?.ok && response.result) {
        return { ...response, result: { hash: response.result.hash ?? 'test-config-hash', ...response.result } };
      }
      if (method === 'config.patch') {
        const patch = JSON.parse(String(params.raw ?? '{}'));
        await mocks.patchGatewayConfig(url, token, patch, setupPassword);
      }
      return response;
    },
    events,
  ), setupPassword),
}));

vi.mock('./gateway-lifecycle-lock.service.js', () => ({
  tryWithUserGatewayConfigReconciliationLock: (...a: unknown[]) =>
    mocks.tryWithUserGatewayConfigReconciliationLock(...a),
}));

vi.mock('./gateway.service.js', () => ({
  getGatewayCredentialsWithClient: (...a: unknown[]) => mocks.getGatewayCredentialsWithClient(...a),
  getLocalGatewayCredentials: (...a: unknown[]) => mocks.getLocalGatewayCredentials(...a),
  getSetupPasswordWithClient: (...a: unknown[]) => mocks.getSetupPasswordWithClient(...a),
}));

describe('composio MCP wiring (#1087)', () => {
  const ORIGINAL_KEY = process.env.COMPOSIO_API_KEY;

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.COMPOSIO_API_KEY = 'test-key';
    mocks.connectedAccountsList.mockResolvedValue({ items: [], nextCursor: null });
    mocks.tryWithUserGatewayConfigReconciliationLock.mockImplementation(
      async (_userId: string, work: (client: { query: ReturnType<typeof vi.fn> }) => Promise<unknown>) =>
        ({ acquired: true, value: await work({ query: vi.fn() }) }),
    );
    mocks.getGatewayCredentialsWithClient.mockResolvedValue({
      gateway_url: 'https://gw.example',
      gateway_token: 'tok',
      hosting_provider: 'fly',
    });
    mocks.getLocalGatewayCredentials.mockReturnValue(null);
    mocks.patchGatewayConfig.mockResolvedValue(undefined);
    mocks.getSetupPasswordWithClient.mockResolvedValue('current-setup');
  });

  afterEach(() => {
    process.env.COMPOSIO_API_KEY = ORIGINAL_KEY;
    vi.useRealTimers();
  });

  describe('buildComposioMcpConfigPatch', () => {
    it('shapes the merge-patch exactly like SharedMcpServersView\'s custom-server add, with no null anywhere', async () => {
      const {
        buildComposioMcpConfigPatch,
        COMPOSIO_SCOPE_CONFIG_KEY,
        COMPOSIO_SCOPE_VERSION,
      } = await import('./composio.service.js');
      const patch = buildComposioMcpConfigPatch({
        url: 'https://mcp.composio.dev/session/abc123',
        headers: { Authorization: 'Bearer secret-token' },
        transport: 'streamable-http',
      });
      expect(patch).toEqual({
        mcp: {
          servers: {
            composio: {
              url: 'https://mcp.composio.dev/session/abc123',
              transport: 'streamable-http',
              [COMPOSIO_SCOPE_CONFIG_KEY]: COMPOSIO_SCOPE_VERSION,
              headers: {
                Authorization: 'Bearer secret-token',
              },
            },
          },
        },
      });
      // A brand-new entry needs no deletion sentinels.
      expect(JSON.stringify(patch)).not.toContain('null');
    });

    it('nulls stale owned top-level and header keys while preserving the complete desired record', async () => {
      const { buildComposioMcpConfigPatch, COMPOSIO_SCOPE_CONFIG_KEY } =
        await import('./composio.service.js');

      const patch = buildComposioMcpConfigPatch(
        {
          url: 'https://mcp.composio.dev/session/current',
          transport: 'streamable-http',
          headers: { Authorization: 'Bearer current', 'X-New': 'new' },
        },
        'scope-current',
        {
          url: 'https://mcp.composio.dev/session/old',
          transport: 'sse',
          enabled: false,
          command: 'stale-command',
          extension: 'stale-extension',
          headers: {
            Authorization: '__OPENCLAW_REDACTED__',
            'X-Stale': '__OPENCLAW_REDACTED__',
          },
        },
      );

      expect(patch).toEqual({
        mcp: {
          servers: {
            composio: {
              url: 'https://mcp.composio.dev/session/current',
              transport: 'streamable-http',
              [COMPOSIO_SCOPE_CONFIG_KEY]: 'scope-current',
              headers: {
                Authorization: 'Bearer current',
                'X-New': 'new',
                'X-Stale': null,
              },
              enabled: null,
              command: null,
              extension: null,
            },
          },
        },
      });
    });

    it('explicitly removes every old header when the replacement has no headers', async () => {
      const { buildComposioMcpConfigPatch } = await import('./composio.service.js');
      const patch = buildComposioMcpConfigPatch(
        { url: 'https://mcp.composio.dev/s/current', transport: 'sse', headers: {} },
        'scope-current',
        { headers: { Authorization: '__OPENCLAW_REDACTED__', 'X-Stale': '__OPENCLAW_REDACTED__' } },
      ) as { mcp: { servers: { composio: { headers: Record<string, unknown> } } } };

      expect(patch.mcp.servers.composio.headers).toEqual({ Authorization: null, 'X-Stale': null });
    });

    it('changes the non-secret scope marker when a connected account lifecycle changes', async () => {
      const { buildComposioScopeMarker } = await import('./composio.service.js');
      const empty = buildComposioScopeMarker([]);
      const connected = buildComposioScopeMarker([
        { id: 'ca-discord', status: 'ACTIVE', toolkit: { slug: 'discordbot' } },
      ]);
      const paused = buildComposioScopeMarker([
        { id: 'ca-discord', status: 'INACTIVE', toolkit: { slug: 'discordbot' } },
      ]);
      const pendingAndTerminal = buildComposioScopeMarker([
        { id: 'ca-pending', status: 'INITIATED', toolkit: { slug: 'gmail' } },
        { id: 'ca-failed', status: 'FAILED', toolkit: { slug: 'slack' } },
        { id: 'ca-future', status: 'SOMETHING_NEW', toolkit: { slug: 'notion' } },
      ]);

      expect(connected).not.toBe(empty);
      expect(paused).not.toBe(connected);
      expect(pendingAndTerminal).toBe(empty);
      expect(connected).not.toContain('ca-discord');
    });
  });

  describe('getMcpConfig', () => {
    it('maps Composio session.mcp.type "http" -> gateway transport "streamable-http"', async () => {
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/1', headers: { Authorization: 'Bearer x' } },
      });
      const { getMcpConfig } = await import('./composio.service.js');
      const config = await getMcpConfig('user-1');
      expect(config).toEqual({
        url: 'https://mcp.composio.dev/s/1',
        headers: { Authorization: 'Bearer x' },
        transport: 'streamable-http',
      });
    });

    it('maps Composio session.mcp.type "sse" -> gateway transport "sse"', async () => {
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'sse', url: 'https://mcp.composio.dev/s/2' },
      });
      const { getMcpConfig } = await import('./composio.service.js');
      const config = await getMcpConfig('user-1');
      expect(config?.transport).toBe('sse');
      // Headers default to {} (never undefined/null) when Composio omits them.
      expect(config?.headers).toEqual({});
    });

    it('returns null when the session has no usable mcp endpoint', async () => {
      mocks.sessionsCreate.mockResolvedValue({ mcp: undefined });
      const { getMcpConfig } = await import('./composio.service.js');
      expect(await getMcpConfig('user-1')).toBeNull();
    });

    // #1099: the live symptom was the agent finding and calling a Gmail tool through the wired
    // session, but the tool reporting "No active Gmail connection found" despite Settings showing
    // Gmail Connected for the same userId. Root cause: the session was minted with `toolkits`
    // entirely unset, unlike Composio's own documented usage. This locks in that every session we
    // mint explicitly scopes to the toolkits Rem offers, and passes the EXACT SAME userId string
    // `getMcpConfig` was called with — no reformatting/prefixing on our side.
    it('scopes the session to both Discord toolkits and passes the exact userId string through, unmodified', async () => {
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/4' },
      });
      const { getMcpConfig, COMPOSIO_TOOLKITS } = await import('./composio.service.js');
      const userId = '30828033-d608-4f92-8315-091571ac258b';
      await getMcpConfig(userId);

      expect(mocks.sessionsCreate).toHaveBeenCalledWith(
        userId,
        expect.objectContaining({ mcp: true, toolkits: [...COMPOSIO_TOOLKITS] }),
      );
      const [, sessionConfig] = mocks.sessionsCreate.mock.calls[0] as [string, { toolkits: string[] }];
      expect(sessionConfig.toolkits.filter(slug => slug === 'discord')).toEqual(['discord']);
      expect(sessionConfig.toolkits.filter(slug => slug === 'discordbot')).toEqual(['discordbot']);
      // The exact same string as passed in — not reformatted, cased, or wrapped.
      const [passedUserId] = mocks.sessionsCreate.mock.calls[0];
      expect(passedUserId).toBe(userId);
    });
  });

  describe('createConnectSession messaging auth configs', () => {
    it.each(['slack', 'discord', 'discordbot', 'whatsapp'])('uses managed auth for OAuth toolkit %s', async (toolkit) => {
      mocks.authConfigsList.mockResolvedValue({ items: [] });
      mocks.toolkitsGet.mockResolvedValue({
        name: toolkit,
        authConfigDetails: [{ mode: 'OAUTH2' }],
      });
      mocks.authConfigsCreate.mockResolvedValue({ id: `ac_${toolkit}` });
      mocks.connectedAccountsLink.mockResolvedValue({
        id: `ca_${toolkit}`,
        redirectUrl: `https://connect.composio.dev/link/${toolkit}`,
      });

      const { createConnectSession } = await import('./composio.service.js');
      await expect(createConnectSession('user-1', toolkit)).resolves.toEqual({
        redirectUrl: `https://connect.composio.dev/link/${toolkit}`,
        connectionId: `ca_${toolkit}`,
        toolkit,
      });
      expect(mocks.authConfigsCreate).toHaveBeenCalledWith(toolkit, {
        type: 'use_composio_managed_auth',
        name: `${toolkit} Auth Config`,
      });
      expect(mocks.connectedAccountsLink).toHaveBeenCalledWith(
        'user-1',
        `ac_${toolkit}`,
        { allowMultiple: true },
      );
    });

    it.each(['slack', 'discord', 'discordbot', 'whatsapp'])(
      'skips an incompatible first auth config and reuses compatible managed OAuth for %s',
      async (toolkit) => {
        mocks.authConfigsList.mockResolvedValue({
          items: [
            {
              id: `ac_incompatible_api_key_${toolkit}`,
              authScheme: 'API_KEY',
              isComposioManaged: false,
            },
            {
              id: `ac_managed_oauth_${toolkit}`,
              authScheme: 'OAUTH2',
              isComposioManaged: true,
            },
          ],
        });
        mocks.connectedAccountsLink.mockResolvedValue({
          id: `ca_${toolkit}`,
          redirectUrl: `https://connect.composio.dev/link/${toolkit}`,
        });

        const { createConnectSession } = await import('./composio.service.js');
        await createConnectSession('user-1', toolkit);

        expect(mocks.authConfigsCreate).not.toHaveBeenCalled();
        expect(mocks.toolkitsGet).not.toHaveBeenCalled();
        expect(mocks.connectedAccountsLink).toHaveBeenCalledWith(
          'user-1',
          `ac_managed_oauth_${toolkit}`,
          { allowMultiple: true },
        );
        expect(mocks.connectedAccountsLink).not.toHaveBeenCalledWith(
          'user-1',
          `ac_incompatible_api_key_${toolkit}`,
          expect.anything(),
        );
      },
    );

    it('provisions managed OAuth for WhatsApp when only an incompatible API-key config exists', async () => {
      mocks.authConfigsList.mockResolvedValue({
        items: [{
          id: 'ac_whatsapp_api_key',
          authScheme: 'API_KEY',
          isComposioManaged: false,
        }],
      });
      mocks.toolkitsGet.mockResolvedValue({
        name: 'WhatsApp',
        authConfigDetails: [{ mode: 'OAUTH2' }],
      });
      mocks.authConfigsCreate.mockResolvedValue({ id: 'ac_whatsapp_managed_oauth' });
      mocks.connectedAccountsLink.mockResolvedValue({
        id: 'ca_whatsapp',
        redirectUrl: 'https://connect.composio.dev/link/whatsapp',
      });

      const { createConnectSession } = await import('./composio.service.js');
      await createConnectSession('user-1', 'whatsapp');

      expect(mocks.authConfigsCreate).toHaveBeenCalledWith('whatsapp', {
        type: 'use_composio_managed_auth',
        name: 'WhatsApp Auth Config',
      });
      expect(mocks.connectedAccountsLink).toHaveBeenCalledWith(
        'user-1',
        'ac_whatsapp_managed_oauth',
        { allowMultiple: true },
      );
    });

    it('creates a credential-less API_KEY schema for Telegram and leaves bot-token entry to the hosted link', async () => {
      mocks.authConfigsList.mockResolvedValue({ items: [] });
      mocks.authConfigsCreate.mockResolvedValue({ id: 'ac_telegram' });
      mocks.connectedAccountsLink.mockResolvedValue({
        id: 'ca_telegram',
        redirectUrl: 'https://connect.composio.dev/link/telegram',
      });

      const { createConnectSession } = await import('./composio.service.js');
      await expect(createConnectSession('user-1', 'telegram')).resolves.toEqual({
        redirectUrl: 'https://connect.composio.dev/link/telegram',
        connectionId: 'ca_telegram',
        toolkit: 'telegram',
      });
      expect(mocks.authConfigsCreate).toHaveBeenCalledWith('telegram', {
        type: 'use_custom_auth',
        name: 'Telegram Bot Auth Config',
        authScheme: 'API_KEY',
        credentials: {},
      });
      expect(mocks.toolkitsGet).not.toHaveBeenCalled();
      expect(mocks.connectedAccountsLink).toHaveBeenCalledWith(
        'user-1',
        'ac_telegram',
        { allowMultiple: true },
      );
      expect(JSON.stringify(mocks.authConfigsCreate.mock.calls)).not.toMatch(/bot[_ -]?token/i);
    });

    it('reuses an existing custom Telegram API_KEY auth config without attempting to provision another', async () => {
      mocks.authConfigsList.mockResolvedValue({
        items: [
          {
            id: 'ac_incompatible_first',
            authScheme: 'OAUTH2',
            isComposioManaged: true,
          },
          {
            id: 'ac_existing_telegram',
            authScheme: 'API_KEY',
            isComposioManaged: false,
          },
        ],
      });
      mocks.connectedAccountsLink.mockResolvedValue({
        id: 'ca_existing_telegram',
        redirectUrl: 'https://connect.composio.dev/link/existing-telegram',
      });

      const { createConnectSession } = await import('./composio.service.js');
      await createConnectSession('user-1', 'telegram');

      expect(mocks.authConfigsCreate).not.toHaveBeenCalled();
      expect(mocks.connectedAccountsLink).toHaveBeenCalledWith(
        'user-1',
        'ac_existing_telegram',
        { allowMultiple: true },
      );
    });

    it('does not reuse an incompatible existing Telegram config and provisions the required custom API_KEY schema', async () => {
      mocks.authConfigsList.mockResolvedValue({
        items: [{
          id: 'ac_managed_oauth_telegram',
          authScheme: 'OAUTH2',
          isComposioManaged: true,
        }],
      });
      mocks.authConfigsCreate.mockResolvedValue({ id: 'ac_custom_api_key_telegram' });
      mocks.connectedAccountsLink.mockResolvedValue({
        id: 'ca_custom_telegram',
        redirectUrl: 'https://connect.composio.dev/link/custom-telegram',
      });

      const { createConnectSession } = await import('./composio.service.js');
      await createConnectSession('user-1', 'telegram');

      expect(mocks.authConfigsCreate).toHaveBeenCalledWith('telegram', {
        type: 'use_custom_auth',
        name: 'Telegram Bot Auth Config',
        authScheme: 'API_KEY',
        credentials: {},
      });
      expect(mocks.connectedAccountsLink).toHaveBeenCalledWith(
        'user-1',
        'ac_custom_api_key_telegram',
        { allowMultiple: true },
      );
      expect(mocks.connectedAccountsLink).not.toHaveBeenCalledWith(
        'user-1',
        'ac_managed_oauth_telegram',
        expect.anything(),
      );
    });

    it('reports an API-key setup recovery when Telegram custom-auth provisioning is unavailable', async () => {
      mocks.authConfigsList.mockResolvedValue({ items: [] });
      mocks.authConfigsCreate.mockRejectedValue({ status: 400 });

      const { createConnectSession } = await import('./composio.service.js');
      await expect(createConnectSession('user-1', 'telegram')).rejects.toThrow(/API-key auth config/);
      expect(mocks.connectedAccountsLink).not.toHaveBeenCalled();
    });
  });

  describe('ensureComposioMcpWired', () => {
    it('holds the durable user lifecycle fence across account reads and the atomic gateway write', async () => {
      let insideFence = false;
      const lifecycleClient = { query: vi.fn() };
      mocks.tryWithUserGatewayConfigReconciliationLock.mockImplementation(async (_userId, work) => {
        insideFence = true;
        try {
          return { acquired: true, value: await work(lifecycleClient) };
        } finally {
          insideFence = false;
        }
      });
      mocks.getGatewayCredentialsWithClient.mockImplementation(async (client) => {
        expect(insideFence).toBe(true);
        expect(client).toBe(lifecycleClient);
        return { gateway_url: 'https://gw.example', gateway_token: 'tok', hosting_provider: 'fly' };
      });
      const accounts = [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }];
      mocks.connectedAccountsList.mockImplementation(async () => {
        expect(insideFence).toBe(true);
        return { items: accounts, nextCursor: null };
      });
      mocks.sessionsCreate.mockImplementation(async () => {
        expect(insideFence).toBe(true);
        return { mcp: { type: 'http', url: 'https://mcp.composio.dev/s/current', headers: {} } };
      });
      const rpcParams: Array<{ method: string; params?: Record<string, unknown> }> = [];
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        expect(insideFence).toBe(true);
        const request = vi.fn(async (method: string, params?: Record<string, unknown>) => {
          expect(insideFence).toBe(true);
          rpcParams.push({ method, params });
          if (method === 'config.get') {
            return {
              ok: true,
              result: {
                hash: 'snapshot-hash',
                config: {
                  mcp: {
                    servers: {
                      composio: {
                        url: 'https://mcp.composio.dev/s/old',
                        transport: 'sse',
                        remComposioScope: 'stale',
                        enabled: false,
                        headers: { Authorization: '__OPENCLAW_REDACTED__', 'X-Stale': '__OPENCLAW_REDACTED__' },
                      },
                    },
                  },
                },
              },
            };
          }
          return { ok: true, result: {} };
        });
        return fn(request, { onEvent: vi.fn() });
      });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      await expect(ensureComposioMcpWired('user-1', 'https://gw.example', 'tok')).resolves.toEqual({ wired: true });

      expect(mocks.tryWithUserGatewayConfigReconciliationLock).toHaveBeenCalledWith('user-1', expect.any(Function));
      expect(rpcParams.map(item => item.method)).toEqual(['config.get', 'config.patch']);
      expect(rpcParams[1]?.params?.baseHash).toBe('snapshot-hash');
      expect(JSON.parse(String(rpcParams[1]?.params?.raw))).toEqual(expect.objectContaining({
        mcp: {
          servers: {
            composio: expect.objectContaining({
              enabled: null,
              headers: expect.objectContaining({ 'X-Stale': null }),
            }),
          },
        },
      }));
      expect(insideFence).toBe(false);
    });

    it('uses the authoritative gateway target re-read after acquiring the lifecycle fence', async () => {
      mocks.getGatewayCredentialsWithClient.mockResolvedValue({
        gateway_url: 'https://current-gw.example',
        gateway_token: 'current-token',
        hosting_provider: 'fly',
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: { hash: 'current-hash', config: { mcp: { servers: {} } } },
        });
        return fn(request, { onEvent: vi.fn() });
      });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      await expect(
        ensureComposioMcpWired('user-1', 'https://stale-gw.example', 'stale-token', 'stale-setup'),
      ).resolves.toEqual({ wired: true, reason: 'already_wired' });

      expect(mocks.withGatewayRequester).toHaveBeenCalledWith(
        'https://current-gw.example',
        'current-token',
        expect.any(Function),
        'current-setup',
      );
      expect(mocks.getSetupPasswordWithClient).toHaveBeenCalledWith(expect.anything(), 'user-1');
    });

    it('re-reads managed setup auth even when the URL and token are unchanged', async () => {
      mocks.getGatewayCredentialsWithClient.mockResolvedValue({
        gateway_url: 'https://gw.example',
        gateway_token: 'tok',
        hosting_provider: 'fly',
      });
      mocks.getSetupPasswordWithClient.mockResolvedValue('replacement-machine-setup');
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => fn(
        vi.fn().mockResolvedValue({
          ok: true,
          result: { hash: 'current-hash', config: { mcp: { servers: {} } } },
        }),
        { onEvent: vi.fn() },
      ));

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      await expect(ensureComposioMcpWired(
        'user-1',
        'https://gw.example',
        'tok',
        'stale-machine-setup',
      )).resolves.toEqual({ wired: true, reason: 'already_wired' });

      expect(mocks.withGatewayRequester).toHaveBeenCalledWith(
        'https://gw.example',
        'tok',
        expect.any(Function),
        'replacement-machine-setup',
      );
    });

    it('returns retryable busy without touching Composio or the gateway when admission is unavailable', async () => {
      vi.useFakeTimers();
      mocks.tryWithUserGatewayConfigReconciliationLock.mockResolvedValue({ acquired: false });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const operation = ensureComposioMcpWired('busy-user', 'https://gw.example', 'tok');
      await vi.advanceTimersByTimeAsync(250);

      await expect(operation).resolves.toEqual({ wired: false, reason: 'busy' });
      expect(mocks.tryWithUserGatewayConfigReconciliationLock).toHaveBeenCalledTimes(2);
      expect(mocks.connectedAccountsList).not.toHaveBeenCalled();
      expect(mocks.withGatewayRequester).not.toHaveBeenCalled();
    });

    it('uses canonical local credentials rather than stale caller credentials when no DB target exists', async () => {
      const originalUrl = process.env.LOCAL_GATEWAY_URL;
      process.env.LOCAL_GATEWAY_URL = 'http://127.0.0.1:18789';
      mocks.getGatewayCredentialsWithClient.mockResolvedValue(null);
      mocks.getLocalGatewayCredentials.mockReturnValue({
        gateway_url: 'http://127.0.0.1:18789',
        gateway_token: 'canonical-local-token',
        hosting_provider: 'local',
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => fn(
        vi.fn().mockResolvedValue({ ok: true, result: { hash: 'local-hash', config: { mcp: { servers: {} } } } }),
        { onEvent: vi.fn() },
      ));

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      await expect(ensureComposioMcpWired(
        'local-user',
        'http://127.0.0.1:18789',
        'stale-caller-token',
      )).resolves.toEqual({ wired: true, reason: 'already_wired' });

      expect(mocks.withGatewayRequester).toHaveBeenCalledWith(
        'http://127.0.0.1:18789',
        'canonical-local-token',
        expect.any(Function),
        undefined,
      );
      expect(mocks.getSetupPasswordWithClient).not.toHaveBeenCalled();
      process.env.LOCAL_GATEWAY_URL = originalUrl;
    });

    it('rejects an unowned same-name MCP server without minting, deleting, or overwriting it', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      const request = vi.fn().mockResolvedValue({
        ok: true,
        result: {
          hash: 'collision-hash',
          config: { mcp: { servers: { composio: { url: 'https://user.example/custom-mcp' } } } },
        },
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) =>
        fn(request, { onEvent: vi.fn() }));

      const { ComposioMcpOwnershipConflictError, ensureComposioMcpWired } =
        await import('./composio.service.js');
      await expect(ensureComposioMcpWired('user-1', 'https://gw.example', 'tok'))
        .rejects.toBeInstanceOf(ComposioMcpOwnershipConflictError);

      expect(request).toHaveBeenCalledTimes(1);
      expect(request).toHaveBeenCalledWith('config.get', {});
      expect(mocks.sessionsCreate).not.toHaveBeenCalled();
      expect(mocks.patchGatewayConfig).not.toHaveBeenCalled();
    });

    it('replaces a current-marker server once when its redacted legacy scope header remains', async () => {
      const {
        COMPOSIO_SCOPE_CONFIG_KEY,
        buildComposioScopeMarker,
      } = await import('./composio.service.js');
      const accounts = [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }];
      mocks.connectedAccountsList.mockResolvedValue({ items: accounts, nextCursor: null });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/replacement', headers: { Authorization: 'new' } },
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: {
            config: {
              mcp: {
                servers: {
                  composio: {
                    url: 'https://already-there',
                    [COMPOSIO_SCOPE_CONFIG_KEY]: buildComposioScopeMarker(accounts),
                    // This is the actual config.get shape from the pinned gateway: every MCP header
                    // value is schema-sensitive, including the old generation header.
                    headers: {
                      Authorization: '__OPENCLAW_REDACTED__',
                      'x-rEm-CoMpOsIo-ScOpE': '__OPENCLAW_REDACTED__',
                    },
                  },
                },
              },
            },
          },
        });
        return fn(request, { onEvent: vi.fn() });
      });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const result = await ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', 'setup-pw');

      expect(result).toEqual({ wired: true });
      expect(mocks.sessionsCreate).toHaveBeenCalledOnce();
      expect(mocks.patchGatewayConfig).toHaveBeenCalledWith(
        'https://gw.example',
        'tok',
        expect.objectContaining({
          mcp: { servers: { composio: expect.objectContaining({
            headers: expect.objectContaining({ 'x-rEm-CoMpOsIo-ScOpE': null }),
          }) } },
        }),
        'current-setup',
      );
    });

    it('automatically rotates an existing session whose catalog scope is stale', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: { config: { mcp: { servers: { composio: { url: 'https://mcp.composio.dev/s/stale' } } } } },
        });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/current', headers: {} },
      });
      mocks.patchGatewayConfig.mockResolvedValue(undefined);

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      expect(await ensureComposioMcpWired('user-1', 'https://gw.example', 'tok')).toEqual({ wired: true });
      expect(mocks.sessionsCreate).toHaveBeenCalledTimes(1);
      expect(mocks.patchGatewayConfig).toHaveBeenCalledTimes(1);
    });

    it('rotates and hot-reloads when a newly connected account changes the runtime scope', async () => {
      const {
        COMPOSIO_SCOPE_CONFIG_KEY,
        buildComposioScopeMarker,
        ensureComposioMcpWired,
      } = await import('./composio.service.js');
      const priorMarker = buildComposioScopeMarker([]);
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'ca-discord', status: 'ACTIVE', toolkit: { slug: 'discordbot' } }],
        nextCursor: null,
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: {
            config: {
              mcp: {
                servers: { composio: { url: 'https://old-session', [COMPOSIO_SCOPE_CONFIG_KEY]: priorMarker } },
              },
            },
          },
        });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/with-discord', headers: {} },
      });
      mocks.patchGatewayConfig.mockResolvedValue(undefined);

      await expect(ensureComposioMcpWired('user-1', 'https://gw.example', 'tok')).resolves.toEqual({ wired: true });
      expect(mocks.sessionsCreate).toHaveBeenCalledTimes(1);
      expect(mocks.patchGatewayConfig).toHaveBeenCalledWith(
        'https://gw.example',
        'tok',
        expect.objectContaining({
          mcp: {
            servers: {
              composio: expect.objectContaining({
                [COMPOSIO_SCOPE_CONFIG_KEY]: buildComposioScopeMarker([
                  { id: 'ca-discord', status: 'ACTIVE', toolkit: { slug: 'discordbot' } },
                ]),
              }),
            },
          },
        }),
        'current-setup',
      );
    });

    // #1099 remediation: a user wired BEFORE the toolkits-scoping fix has a permanently-wrong
    // session sitting in mcp.servers.composio. The normal already-wired check can never detect or
    // self-heal that (it only checks presence, not correctness) — force is the explicit escape
    // hatch that skips the short-circuit and re-mints regardless.
    it('force:true skips the already-wired short-circuit and re-mints + re-patches', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: { config: { mcp: { servers: { composio: { url: 'https://mcp.composio.dev/s/stale' } } } } },
        });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'sse', url: 'https://mcp.composio.dev/s/fresh' },
      });
      mocks.patchGatewayConfig.mockResolvedValue(undefined);

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const result = await ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', 'setup-pw', { force: true });

      expect(result).toEqual({ wired: true });
      expect(mocks.sessionsCreate).toHaveBeenCalledTimes(1);
      expect(mocks.patchGatewayConfig).toHaveBeenCalledWith(
        'https://gw.example',
        'tok',
        expect.objectContaining({
          mcp: { servers: { composio: expect.objectContaining({ url: 'https://mcp.composio.dev/s/fresh' }) } },
        }),
        'current-setup',
      );
      // Force bypasses the marker short-circuit, but still inspects server presence so the same
      // lifecycle path can safely distinguish an absent server from one that needs replacement.
      expect(mocks.withGatewayRequester).toHaveBeenCalledTimes(1);
    });

    it('mints a session and patches the gateway when composio is absent from mcp.servers', async () => {
      const accounts = [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }];
      mocks.connectedAccountsList.mockResolvedValue({ items: accounts, nextCursor: null });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: { config: { mcp: { servers: {} } } },
        });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/new', headers: { Authorization: 'Bearer new-token' } },
      });
      mocks.patchGatewayConfig.mockResolvedValue(undefined);

      const {
        ensureComposioMcpWired,
        COMPOSIO_SCOPE_CONFIG_KEY,
        buildComposioScopeMarker,
      } = await import('./composio.service.js');
      const result = await ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', 'setup-pw');

      expect(result).toEqual({ wired: true });
      expect(mocks.patchGatewayConfig).toHaveBeenCalledWith(
        'https://gw.example',
        'tok',
        {
          mcp: {
            servers: {
              composio: {
                url: 'https://mcp.composio.dev/s/new',
                transport: 'streamable-http',
                [COMPOSIO_SCOPE_CONFIG_KEY]: buildComposioScopeMarker(accounts),
                headers: {
                  Authorization: 'Bearer new-token',
                },
              },
            },
          },
        },
        'current-setup',
      );
      // The auth header must reach the gateway config patch call and nowhere else — this test
      // asserts the ONLY place the secret header value appears is the patchGatewayConfig call args.
    });

    it('reports no_mcp_session (and never patches) when Composio has no MCP endpoint yet', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({ ok: true, result: { config: { mcp: { servers: {} } } } });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.sessionsCreate.mockResolvedValue({ mcp: undefined });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const result = await ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', undefined);

      expect(result).toEqual({ wired: false, reason: 'no_mcp_session' });
      expect(mocks.patchGatewayConfig).not.toHaveBeenCalled();
    });

    it('retries a failed config.get and proceeds from a fresh atomic snapshot', async () => {
      vi.useFakeTimers();
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.withGatewayRequester.mockImplementationOnce(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({ ok: false });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.withGatewayRequester.mockImplementationOnce(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({ ok: true, result: { config: { mcp: { servers: {} } } } });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'sse', url: 'https://mcp.composio.dev/s/3' },
      });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const resultPromise = ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', undefined);
      await vi.runAllTimersAsync();
      const result = await resultPromise;

      expect(result).toEqual({ wired: true });
      expect(mocks.patchGatewayConfig).toHaveBeenCalled();
      expect(mocks.withGatewayRequester).toHaveBeenCalledTimes(2);
      vi.useRealTimers();
    });

    it('retries failed inspection, then removes exactly from a fresh snapshot when no grant is retained', async () => {
      vi.useFakeTimers();
      mocks.connectedAccountsList.mockResolvedValue({ items: [], nextCursor: null });
      mocks.withGatewayRequester.mockImplementationOnce(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({ ok: false });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.withGatewayRequester.mockImplementationOnce(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: { config: { mcp: { servers: { composio: { url: 'https://mcp.composio.dev/s/stale' } } } } },
        });
        return fn(request, { onEvent: vi.fn() });
      });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const resultPromise = ensureComposioMcpWired('user-1', 'https://gw.example', 'tok');
      await vi.runAllTimersAsync();
      await expect(resultPromise).resolves.toEqual({ wired: true });

      expect(mocks.patchGatewayConfig).toHaveBeenCalledWith(
        'https://gw.example',
        'tok',
        { mcp: { servers: { composio: null } } },
        'current-setup',
      );
      expect(mocks.sessionsCreate).not.toHaveBeenCalled();
      expect(mocks.withGatewayRequester).toHaveBeenCalledTimes(2);
      vi.useRealTimers();
    });

    it('removes an existing server after the final disconnect, then restores it on reconnect', async () => {
      const {
        COMPOSIO_SCOPE_CONFIG_KEY,
        buildComposioScopeMarker,
        ensureComposioMcpWired,
      } = await import('./composio.service.js');
      const activeAccounts = [{ id: 'ca-gmail-new', status: 'ACTIVE', toolkit: { slug: 'gmail' } }];
      const activeMarker = buildComposioScopeMarker(activeAccounts);
      mocks.connectedAccountsList
        .mockResolvedValueOnce({ items: [], nextCursor: null })
        .mockResolvedValueOnce({ items: [], nextCursor: null })
        .mockResolvedValue({ items: activeAccounts, nextCursor: null });
      mocks.withGatewayRequester
        .mockImplementationOnce(async (_url, _token, fn) => {
          const request = vi.fn().mockResolvedValue({
            ok: true,
            result: {
              config: {
                mcp: {
                  servers: {
                    composio: {
                      url: 'https://mcp.composio.dev/s/old',
                      [COMPOSIO_SCOPE_CONFIG_KEY]: buildComposioScopeMarker([
                        { id: 'ca-gmail-old', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
                      ]),
                    },
                  },
                },
              },
            },
          });
          return fn(request, { onEvent: vi.fn() });
        })
        .mockImplementationOnce(async (_url, _token, fn) => {
          const request = vi.fn().mockResolvedValue({
            ok: true,
            result: {
              config: {
                mcp: {
                  servers: {},
                },
              },
            },
          });
          return fn(request, { onEvent: vi.fn() });
        });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/reconnected', headers: {} },
      });
      mocks.patchGatewayConfig.mockResolvedValue(undefined);

      await expect(ensureComposioMcpWired('user-1', 'https://gw.example', 'tok')).resolves.toEqual({ wired: true });
      expect(mocks.patchGatewayConfig).toHaveBeenNthCalledWith(1, 'https://gw.example', 'tok', {
        mcp: {
          servers: {
            composio: null,
          },
        },
      }, 'current-setup');
      expect(mocks.sessionsCreate).not.toHaveBeenCalled();

      await expect(ensureComposioMcpWired('user-1', 'https://gw.example', 'tok')).resolves.toEqual({ wired: true });
      expect(mocks.patchGatewayConfig).toHaveBeenNthCalledWith(
        2,
        'https://gw.example',
        'tok',
        expect.objectContaining({
          mcp: {
            servers: {
              composio: expect.objectContaining({
                [COMPOSIO_SCOPE_CONFIG_KEY]: activeMarker,
              }),
            },
          },
        }),
        'current-setup',
      );
      const reconnectPatch = mocks.patchGatewayConfig.mock.calls[1]?.[2] as {
        mcp?: { servers?: { composio?: Record<string, unknown> } };
      };
      expect(reconnectPatch.mcp?.servers?.composio).not.toHaveProperty('enabled');
      expect(mocks.sessionsCreate).toHaveBeenCalledTimes(1);
    });

    it('serializes opposing queued states so the later retained-account snapshot wins', async () => {
      const activeAccounts = [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }];
      mocks.connectedAccountsList
        .mockResolvedValueOnce({ items: activeAccounts, nextCursor: null })
        .mockResolvedValueOnce({ items: activeAccounts, nextCursor: null })
        .mockResolvedValueOnce({ items: [], nextCursor: null })
        .mockResolvedValueOnce({ items: [], nextCursor: null });
      mocks.sessionsCreate.mockResolvedValue({
        mcp: { type: 'http', url: 'https://mcp.composio.dev/s/active', headers: {} },
      });
      let gatewayServer: Record<string, unknown> | undefined;
      let hash = 0;
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn(async (method: string, params?: Record<string, unknown>) => {
          if (method === 'config.get') {
            return {
              ok: true,
              result: {
                hash: `hash-${++hash}`,
                config: { mcp: { servers: gatewayServer ? { composio: gatewayServer } : {} } },
              },
            };
          }
          const patch = JSON.parse(String(params?.raw ?? '{}')) as {
            mcp?: { servers?: { composio?: Record<string, unknown> | null } };
          };
          gatewayServer = patch.mcp?.servers?.composio ?? undefined;
          return { ok: true, result: {} };
        });
        return fn(request, { onEvent: vi.fn() });
      });

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const add = ensureComposioMcpWired('user-1', 'https://gw.example', 'tok');
      const remove = ensureComposioMcpWired('user-1', 'https://gw.example', 'tok');
      const results = await Promise.all([add, remove]);
      expect(results.every(result => result.wired)).toBe(true);

      expect(mocks.tryWithUserGatewayConfigReconciliationLock).toHaveBeenCalledTimes(2);
      expect(mocks.patchGatewayConfig).toHaveBeenCalledTimes(2);
      expect(mocks.patchGatewayConfig.mock.calls[1]?.[2]).toEqual({
        mcp: { servers: { composio: null } },
      });
      expect(gatewayServer).toBeUndefined();
    });

    it('collapses a same-user burst to one leading and at most one trailing reconciliation', async () => {
      let releaseLeading: (() => void) | undefined;
      let lockCalls = 0;
      mocks.tryWithUserGatewayConfigReconciliationLock.mockImplementation(async (_userId, work) => {
        lockCalls += 1;
        if (lockCalls === 1) await new Promise<void>(resolve => { releaseLeading = resolve; });
        return { acquired: true, value: await work({ query: vi.fn() }) };
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => fn(
        vi.fn().mockResolvedValue({ ok: true, result: { hash: 'h', config: { mcp: { servers: {} } } } }),
        { onEvent: vi.fn() },
      ));

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const calls = Array.from({ length: 12 }, () =>
        ensureComposioMcpWired('burst-user', 'https://gw.example', 'tok'));
      releaseLeading?.();
      await Promise.all(calls);

      expect(mocks.tryWithUserGatewayConfigReconciliationLock).toHaveBeenCalledTimes(2);
    });

    it('still runs the dirty trailing reconciliation when the leading lock attempt rejects', async () => {
      let rejectLeading: (() => void) | undefined;
      mocks.tryWithUserGatewayConfigReconciliationLock
        .mockImplementationOnce(async () => {
          await new Promise<void>(resolve => { rejectLeading = resolve; });
          throw new Error('leading lock failed');
        })
        .mockImplementationOnce(async (_userId, work) => ({
          acquired: true,
          value: await work({ query: vi.fn() }),
        }));
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => fn(
        vi.fn().mockResolvedValue({ ok: true, result: { hash: 'h', config: { mcp: { servers: {} } } } }),
        { onEvent: vi.fn() },
      ));

      const { ensureComposioMcpWired } = await import('./composio.service.js');
      const leading = ensureComposioMcpWired('reject-dirty-user', 'https://gw.example', 'tok');
      const trailing = ensureComposioMcpWired('reject-dirty-user', 'https://gw.example', 'tok');
      rejectLeading?.();

      await expect(Promise.all([leading, trailing])).resolves.toEqual([
        { wired: true, reason: 'already_wired' },
        { wired: true, reason: 'already_wired' },
      ]);
      expect(mocks.tryWithUserGatewayConfigReconciliationLock).toHaveBeenCalledTimes(2);
    });

    it.each([
      'INITIALIZING',
      'INITIATED',
      'FAILED',
      'EXPIRED',
      'REVOKED',
      'SOMETHING_NEW',
    ])('removes an existing server for a %s-only account snapshot', async (status) => {
      const { COMPOSIO_SCOPE_CONFIG_KEY, buildComposioScopeMarker, ensureComposioMcpWired } =
        await import('./composio.service.js');
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: `ca-${status}`, status, toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
        const request = vi.fn().mockResolvedValue({
          ok: true,
          result: {
            config: {
              mcp: {
                servers: {
                  composio: {
                    url: 'https://mcp.composio.dev/s/stale',
                    [COMPOSIO_SCOPE_CONFIG_KEY]: buildComposioScopeMarker([
                      { id: 'ca-live', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
                    ]),
                  },
                },
              },
            },
          },
        });
        return fn(request, { onEvent: vi.fn() });
      });
      mocks.patchGatewayConfig.mockResolvedValue(undefined);

      await expect(ensureComposioMcpWired('user-1', 'https://gw.example', 'tok')).resolves.toEqual({ wired: true });
      expect(mocks.patchGatewayConfig).toHaveBeenCalledWith(
        'https://gw.example',
        'tok',
        { mcp: { servers: { composio: null } } },
        'current-setup',
      );
      expect(mocks.sessionsCreate).not.toHaveBeenCalled();
    });

    // #1087 3rd layer: the live symptom after the protocol-version fix was a WebSocket timeout on
    // an already-woken (ready:true) but still-slow gateway. A bounded retry means a single
    // transient timeout doesn't permanently skip wiring until the next cold launch.
    describe('bounded retry (#1087)', () => {
      beforeEach(() => {
        vi.useFakeTimers();
      });

      afterEach(() => {
        vi.useRealTimers();
      });

      it('retries once and succeeds when the first attempt times out', async () => {
        mocks.connectedAccountsList.mockResolvedValue({
          items: [{ id: 'ca-gmail', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
          nextCursor: null,
        });
        mocks.withGatewayRequester.mockRejectedValueOnce(
          new Error('WebSocket timeout after 15000ms waiting for a response from https://gw.example'),
        );
        mocks.withGatewayRequester.mockImplementationOnce(async (_url: string, _token: string, fn: any) => {
          const request = vi.fn().mockResolvedValue({ ok: true, result: { config: { mcp: { servers: {} } } } });
          return fn(request, { onEvent: vi.fn() });
        });
        mocks.sessionsCreate.mockResolvedValue({
          mcp: { type: 'sse', url: 'https://mcp.composio.dev/s/retry' },
        });

        const { ensureComposioMcpWired } = await import('./composio.service.js');
        const resultPromise = ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', undefined);
        // Let the first (rejected) attempt's catch handler register its retry-delay timer, then
        // fast-forward past it instead of waiting the real 5s.
        await vi.runAllTimersAsync();
        const result = await resultPromise;

        expect(result).toEqual({ wired: true });
        expect(mocks.withGatewayRequester).toHaveBeenCalledTimes(2);
      });

      it('retries from a fresh snapshot when account scope changes during session mint', async () => {
        const {
          COMPOSIO_SCOPE_CONFIG_KEY,
          buildComposioScopeMarker,
          ensureComposioMcpWired,
        } = await import('./composio.service.js');
        const initialAccounts = [{ id: 'ca-old', status: 'ACTIVE', toolkit: { slug: 'gmail' } }];
        const latestAccounts = [{ id: 'ca-new', status: 'ACTIVE', toolkit: { slug: 'gmail' } }];
        mocks.connectedAccountsList
          .mockResolvedValueOnce({ items: initialAccounts, nextCursor: null })
          .mockResolvedValue({ items: latestAccounts, nextCursor: null });
        mocks.withGatewayRequester.mockImplementation(async (_url, _token, fn) => {
          const request = vi.fn().mockResolvedValue({ ok: true, result: { config: { mcp: { servers: {} } } } });
          return fn(request, { onEvent: vi.fn() });
        });
        mocks.sessionsCreate
          .mockResolvedValueOnce({ mcp: { type: 'http', url: 'https://mcp.composio.dev/s/stale', headers: {} } })
          .mockResolvedValueOnce({ mcp: { type: 'http', url: 'https://mcp.composio.dev/s/current', headers: {} } });
        mocks.patchGatewayConfig.mockResolvedValue(undefined);

        const resultPromise = ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', undefined);
        await vi.runAllTimersAsync();
        await expect(resultPromise).resolves.toEqual({ wired: true });

        expect(mocks.sessionsCreate).toHaveBeenCalledTimes(2);
        expect(mocks.patchGatewayConfig).toHaveBeenCalledTimes(1);
        expect(mocks.patchGatewayConfig).toHaveBeenCalledWith(
          'https://gw.example',
          'tok',
          expect.objectContaining({
            mcp: {
              servers: {
                composio: expect.objectContaining({
                  url: 'https://mcp.composio.dev/s/current',
                  [COMPOSIO_SCOPE_CONFIG_KEY]: buildComposioScopeMarker(latestAccounts),
                }),
              },
            },
          }),
          'current-setup',
        );
        expect(JSON.stringify(mocks.patchGatewayConfig.mock.calls)).not.toContain(
          buildComposioScopeMarker(initialAccounts),
        );
      });

      it('gives up after MAX_WIRE_ATTEMPTS and throws the last error', async () => {
        mocks.withGatewayRequester.mockRejectedValue(
          new Error('WebSocket timeout after 15000ms waiting for a response from https://gw.example'),
        );

        const { ensureComposioMcpWired } = await import('./composio.service.js');
        const resultPromise = ensureComposioMcpWired('user-1', 'https://gw.example', 'tok', undefined);
        const assertion = expect(resultPromise).rejects.toThrow('WebSocket timeout');
        await vi.runAllTimersAsync();
        await assertion;

        // Exactly 2 attempts (MAX_WIRE_ATTEMPTS) — bounded, not an unbounded retry loop.
        expect(mocks.withGatewayRequester).toHaveBeenCalledTimes(2);
      });
    });
  });

  // The catalog includes messaging toolkits through the same Composio account lifecycle as every
  // other connected app. More
  // toolkits means more chances for one single toolkit's logo lookup to fail (a renamed slug, a
  // transient Composio hiccup) — this locks in that ONE bad lookup only drops that toolkit's logo,
  // never the whole list.
  describe('listToolkitsSummary (#1069 catalog expansion)', () => {
    it('includes the full curated catalog, not just the original three toolkits', async () => {
      const { COMPOSIO_TOOLKITS } = await import('./composio.service.js');
      expect(COMPOSIO_TOOLKITS).toEqual([
        'gmail',
        'googlecalendar',
        'googledrive',
        'googledocs',
        'googlesheets',
        'github',
        'slack',
        'discord',
        'discordbot',
        'whatsapp',
        'telegram',
        'notion',
        'linear',
        'todoist',
        'asana',
      ]);
    });

    it('degrades only the one toolkit whose logo lookup fails, keeping logos for every other toolkit', async () => {
      const { listToolkitsSummary, COMPOSIO_TOOLKITS } = await import('./composio.service.js');
      mocks.toolkitsGet.mockImplementation(async (slug: string) => {
        if (slug === 'notion') throw new Error('Composio: toolkit temporarily unavailable');
        return { slug, meta: { logo: `https://logos.example/${slug}.png` } };
      });
      mocks.connectedAccountsList.mockResolvedValue({ items: [] });

      const summary = await listToolkitsSummary('user-1');

      expect(summary.configured).toBe(true);
      expect(summary.toolkits).toHaveLength(COMPOSIO_TOOLKITS.length);
      const bySlug = new Map(summary.toolkits.map(t => [t.slug, t]));
      // The failing toolkit is still present, and now falls back to the stable logo CDN instead of
      // going branding-less (#1069 icon fix) — a bad meta.logo fetch never blanks a row.
      expect(bySlug.get('notion')?.logoUrl).toBe('https://logos.composio.dev/api/notion');
      // Every other toolkit still got its meta.logo — one bad slug didn't blank out the whole batch.
      expect(bySlug.get('gmail')?.logoUrl).toBe('https://logos.example/gmail.png');
      expect(bySlug.get('asana')?.logoUrl).toBe('https://logos.example/asana.png');
      expect(bySlug.get('todoist')?.logoUrl).toBe('https://logos.example/todoist.png');
    });

    // #1069 icon fix: a toolkit whose meta.logo fetch fails (or returns no logo) must still get a
    // renderable logo URL, not `undefined` — the client can't tell "fetch failed" from "no logo",
    // so both blanked the row. The stable CDN fallback guarantees every row a logo.
    it('falls back to the stable logo CDN when a toolkit has no meta.logo', async () => {
      const { listToolkitsSummary } = await import('./composio.service.js');
      mocks.toolkitsGet.mockImplementation(async (slug: string) => {
        if (slug === 'gmail') return { slug, meta: { logo: 'https://logos.example/gmail.png' } };
        // notion has no meta.logo at all; slack's fetch throws — both must fall back to the CDN.
        if (slug === 'slack') throw new Error('transient');
        return { slug, meta: {} };
      });
      mocks.connectedAccountsList.mockResolvedValue({ items: [] });

      const summary = await listToolkitsSummary('user-1');
      const bySlug = new Map(summary.toolkits.map(t => [t.slug, t]));
      // meta.logo wins when present.
      expect(bySlug.get('gmail')?.logoUrl).toBe('https://logos.example/gmail.png');
      // Missing meta.logo → CDN fallback (never undefined).
      expect(bySlug.get('notion')?.logoUrl).toBe('https://logos.composio.dev/api/notion');
      // Failed fetch → CDN fallback too.
      expect(bySlug.get('slack')?.logoUrl).toBe('https://logos.composio.dev/api/slack');
    });

    it('returns authoritative account status with CDN logos when logo I/O stalls', async () => {
      const { listToolkitsSummary } = await import('./composio.service.js');
      mocks.toolkitsGet.mockImplementation(() => new Promise(() => {}));
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct-discord', status: 'ACTIVE', toolkit: { slug: 'discord' } }],
        nextCursor: null,
      });

      const startedAt = Date.now();
      const summary = await listToolkitsSummary('user-stalled-logos');
      expect(Date.now() - startedAt).toBeLessThan(1_000);
      expect(summary.toolkits.find(toolkit => toolkit.slug === 'discord')).toMatchObject({
        status: 'connected',
        enabled: true,
        logoUrl: 'https://logos.composio.dev/api/discord',
      });
    });

    it('rejects instead of synthesizing not-connected rows when account status cannot be read', async () => {
      const { listToolkitsSummary, ComposioStatusUnavailableError } = await import('./composio.service.js');
      mocks.toolkitsGet.mockImplementation(async (slug: string) => ({
        slug,
        meta: { logo: `https://logos.example/${slug}.png` },
      }));
      mocks.connectedAccountsList.mockRejectedValue(new Error('Composio status API unavailable'));

      await expect(listToolkitsSummary('user-with-existing-grants')).rejects.toBeInstanceOf(
        ComposioStatusUnavailableError,
      );
    });

    it('follows nextCursor and reports a live grant found on a later status page', async () => {
      const { listToolkitsSummary } = await import('./composio.service.js');
      mocks.toolkitsGet.mockImplementation(async (slug: string) => ({ slug, meta: {} }));
      mocks.connectedAccountsList.mockImplementation(async (params: { cursor?: string }) => {
        if (!params.cursor) {
          return {
            items: [{ id: 'failed-old', status: 'FAILED', toolkit: { slug: 'gmail' } }],
            nextCursor: 'status-page-2',
          };
        }
        return {
          items: [{ id: 'active-new', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
          nextCursor: null,
        };
      });

      const summary = await listToolkitsSummary('user-with-paginated-grants');

      const gmail = summary.toolkits.find(toolkit => toolkit.slug === 'gmail');
      expect(gmail).toMatchObject({ status: 'connected', enabled: true });
      expect(mocks.connectedAccountsList).toHaveBeenNthCalledWith(
        2,
        expect.objectContaining({ cursor: 'status-page-2' }),
        { signal: expect.anything() },
      );
    });

    it('rejects retryably when a later connected-account status page fails', async () => {
      const { listToolkitsSummary, ComposioStatusUnavailableError } = await import('./composio.service.js');
      mocks.toolkitsGet.mockImplementation(async (slug: string) => ({ slug, meta: {} }));
      mocks.connectedAccountsList
        .mockResolvedValueOnce({ items: [], nextCursor: 'status-page-2' })
        .mockRejectedValueOnce(new Error('later status page unavailable'));

      await expect(listToolkitsSummary('user-with-paginated-grants')).rejects.toBeInstanceOf(
        ComposioStatusUnavailableError,
      );
      expect(mocks.connectedAccountsList).toHaveBeenCalledTimes(2);
    });

    it('fails within the provider deadline when account pagination ignores abort', async () => {
      const { listToolkitsSummary, ComposioStatusUnavailableError } = await import('./composio.service.js');
      mocks.toolkitsGet.mockResolvedValue({ meta: {} });
      mocks.connectedAccountsList.mockImplementation(() => new Promise(() => {}));

      const startedAt = Date.now();
      await expect(listToolkitsSummary('user-stalled-catalog')).rejects.toBeInstanceOf(
        ComposioStatusUnavailableError,
      );
      expect(Date.now() - startedAt).toBeLessThan(1_000);
    });
  });

  // Disconnect / revoke (deliverable 3, hardened per review). Toolkit-based: revoke+delete EVERY
  // active account for the toolkit, actually revoke the upstream grant, and paginate the lookup.
  describe('disconnectToolkit', () => {
    it('actually revokes: reaches the raw client with revoke_on_delete:true (not the soft-delete wrapper)', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct_1', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.rawConnectedAccountsDelete.mockResolvedValue({ success: true, revoke_job_id: 'job_1' });

      const { disconnectToolkit } = await import('./composio.service.js');
      const result = await disconnectToolkit('user-1', 'gmail');

      expect(result).toEqual({ deleted: 1 });
      // The revoke param is the whole point — a bare delete would leave the provider grant live.
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledWith(
        'acct_1', { revoke_on_delete: true }, { signal: expect.anything() },
      );
      // Scoped to this user + toolkit + LIVE (ACTIVE or paused/INACTIVE) accounts.
      expect(mocks.connectedAccountsList).toHaveBeenCalledWith(
        expect.objectContaining({ userIds: ['user-1'], toolkitSlugs: ['gmail'], statuses: ['ACTIVE', 'INACTIVE'] }),
        { signal: expect.anything() },
      );
    });

    it('revokes a PAUSED (INACTIVE-only) toolkit — not a silent { deleted: 0 } no-op', async () => {
      // Regression for the pause/disconnect gap: a paused connector's row is still connected and
      // still offers Disconnect, but its account is INACTIVE. An ACTIVE-only revoke would find zero
      // and leave the OAuth grant live (the row would reappear as "Connected • Paused" on reload).
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct_paused', status: 'INACTIVE', toolkit: { slug: 'slack' } }],
        nextCursor: null,
      });
      mocks.rawConnectedAccountsDelete.mockResolvedValue({ success: true, revoke_job_id: 'job_p' });

      const { disconnectToolkit } = await import('./composio.service.js');
      const result = await disconnectToolkit('user-1', 'slack');

      // The paused account is actually revoked+deleted — deleted: 1, not a silent 0.
      expect(result).toEqual({ deleted: 1 });
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledWith(
        'acct_paused', { revoke_on_delete: true }, { signal: expect.anything() },
      );
    });

    it('revokes EVERY active account for the toolkit, not just the first (allowMultiple)', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [
          { id: 'acct_a', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
          { id: 'acct_b', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
        ],
        nextCursor: null,
      });
      mocks.rawConnectedAccountsDelete.mockResolvedValue({ success: true });

      const { disconnectToolkit } = await import('./composio.service.js');
      const result = await disconnectToolkit('user-1', 'gmail');

      expect(result).toEqual({ deleted: 2 });
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledWith(
        'acct_a', { revoke_on_delete: true }, { signal: expect.anything() },
      );
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledWith(
        'acct_b', { revoke_on_delete: true }, { signal: expect.anything() },
      );
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledTimes(2);
    });

    it('follows pagination — finds and revokes an active account on page 2', async () => {
      mocks.connectedAccountsList.mockImplementation(async (params: { cursor?: string }) => {
        if (!params.cursor) {
          return { items: [{ id: 'acct_page1', status: 'ACTIVE', toolkit: { slug: 'gmail' } }], nextCursor: 'cur2' };
        }
        return { items: [{ id: 'acct_page2', status: 'ACTIVE', toolkit: { slug: 'gmail' } }], nextCursor: null };
      });
      mocks.rawConnectedAccountsDelete.mockResolvedValue({ success: true });

      const { disconnectToolkit } = await import('./composio.service.js');
      const result = await disconnectToolkit('user-1', 'gmail');

      expect(result).toEqual({ deleted: 2 });
      // The page-2 account must be revoked too — the old first-page-only scan would have missed it.
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledWith(
        'acct_page2', { revoke_on_delete: true }, { signal: expect.anything() },
      );
      // Second list call carried the cursor from page 1.
      expect(mocks.connectedAccountsList).toHaveBeenNthCalledWith(
        2, expect.objectContaining({ cursor: 'cur2' }), { signal: expect.anything() },
      );
    });

    it('rejects a repeated pagination cursor before revoking a partial account set', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct_partial', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: 'loop',
      });

      const { disconnectToolkit } = await import('./composio.service.js');
      await expect(disconnectToolkit('user-1', 'gmail')).rejects.toThrow(
        'Composio connected-account mutation pagination repeated a cursor',
      );
      expect(mocks.connectedAccountsList).toHaveBeenCalledTimes(2);
      expect(mocks.rawConnectedAccountsDelete).not.toHaveBeenCalled();
    });

    it('rejects pagination that still has a next cursor after the maximum page count', async () => {
      let nextCursor = 0;
      mocks.connectedAccountsList.mockImplementation(async () => ({
        items: [],
        nextCursor: `cursor-${++nextCursor}`,
      }));

      const { disconnectToolkit } = await import('./composio.service.js');
      await expect(disconnectToolkit('user-1', 'gmail')).rejects.toThrow(
        'Composio connected-account mutation exceeded 50 pages',
      );
      expect(mocks.connectedAccountsList).toHaveBeenCalledTimes(50);
      expect(mocks.rawConnectedAccountsDelete).not.toHaveBeenCalled();
    });

    it('never revokes a terminal-state row (FAILED/EXPIRED/REVOKED) even if the API returns one', async () => {
      // Live accounts (ACTIVE or paused/INACTIVE) are revocable; a terminal-bad row is not — there's
      // no grant left to revoke, and the client-side re-check keeps it out of the delete set.
      mocks.connectedAccountsList.mockResolvedValue({
        items: [
          { id: 'acct_active', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
          { id: 'acct_failed', status: 'FAILED', toolkit: { slug: 'gmail' } },
        ],
        nextCursor: null,
      });
      mocks.rawConnectedAccountsDelete.mockResolvedValue({ success: true });

      const { disconnectToolkit } = await import('./composio.service.js');
      const result = await disconnectToolkit('user-1', 'gmail');

      expect(result).toEqual({ deleted: 1 });
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledWith(
        'acct_active', { revoke_on_delete: true }, { signal: expect.anything() },
      );
      expect(mocks.rawConnectedAccountsDelete).not.toHaveBeenCalledWith('acct_failed', expect.anything());
    });

    it('is idempotent — zero active accounts returns { deleted: 0 } and never deletes', async () => {
      mocks.connectedAccountsList.mockResolvedValue({ items: [], nextCursor: null });
      const { disconnectToolkit } = await import('./composio.service.js');
      const result = await disconnectToolkit('user-1', 'gmail');
      expect(result).toEqual({ deleted: 0 });
      expect(mocks.rawConnectedAccountsDelete).not.toHaveBeenCalled();
    });

    it('re-lists and revokes a grant that appears after an earlier zero-target revoke', async () => {
      mocks.connectedAccountsList
        .mockResolvedValueOnce({ items: [], nextCursor: null })
        .mockResolvedValueOnce({
          items: [{ id: 'acct_late', status: 'ACTIVE', toolkit: { slug: 'discord' } }],
          nextCursor: null,
        });
      mocks.rawConnectedAccountsDelete.mockResolvedValue({ success: true });
      const { disconnectToolkit } = await import('./composio.service.js');

      await expect(disconnectToolkit('user-1', 'discord')).resolves.toEqual({ deleted: 0 });
      await expect(disconnectToolkit('user-1', 'discord')).resolves.toEqual({ deleted: 1 });

      expect(mocks.connectedAccountsList).toHaveBeenCalledTimes(2);
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledWith(
        'acct_late', { revoke_on_delete: true }, { signal: expect.anything() },
      );
    });

    it('rejects an unknown toolkit slug with ComposioToolkitError (400), never touching the API', async () => {
      const { disconnectToolkit, ComposioToolkitError } = await import('./composio.service.js');
      await expect(disconnectToolkit('user-1', 'notarealtoolkit')).rejects.toBeInstanceOf(ComposioToolkitError);
      expect(mocks.connectedAccountsList).not.toHaveBeenCalled();
      expect(mocks.rawConnectedAccountsDelete).not.toHaveBeenCalled();
    });

    it('aborts a stalled revoke batch so a retry can re-list the unfinished accounts', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct_stalled', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.rawConnectedAccountsDelete.mockImplementation(() => new Promise(() => {}));
      const { disconnectToolkit } = await import('./composio.service.js');

      const startedAt = Date.now();
      await expect(disconnectToolkit('user-stalled-revoke', 'gmail')).rejects.toThrow('timed out');
      expect(Date.now() - startedAt).toBeLessThan(1_000);
    });

    it('rechecks repair generation after listing before revoking a newly connected account', async () => {
      let finishList!: (value: {
        items: Array<{ id: string; status: string; toolkit: { slug: string } }>;
        nextCursor: null;
      }) => void;
      let markListStarted!: () => void;
      const listStarted = new Promise<void>(resolve => { markListStarted = resolve; });
      let current = true;
      mocks.connectedAccountsList.mockImplementation(() => {
        markListStarted();
        return new Promise(resolve => { finishList = resolve; });
      });
      const { disconnectToolkit } = await import('./composio.service.js');

      const repair = disconnectToolkit('user-reconnected', 'gmail', {
        isCurrent: () => current,
        repairAccountIds: ['acct-old'],
      });
      await listStarted;
      // OAuth completion supersedes the repair while its broad ACTIVE/INACTIVE list is in flight.
      current = false;
      finishList({
        items: [{ id: 'acct-new-oauth', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });

      await expect(repair).resolves.toEqual({ deleted: 0 });
      expect(mocks.rawConnectedAccountsDelete).not.toHaveBeenCalled();
    });

    it('never expands a repair target set when generation changes during a revoke write', async () => {
      let finishOldRevoke!: () => void;
      let markOldRevokeStarted!: () => void;
      const oldRevokeStarted = new Promise<void>(resolve => { markOldRevokeStarted = resolve; });
      let current = true;
      mocks.connectedAccountsList.mockResolvedValue({
        items: [
          { id: 'acct-old', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
          { id: 'acct-new-oauth', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
        ],
        nextCursor: null,
      });
      mocks.rawConnectedAccountsDelete.mockImplementationOnce(() => {
        markOldRevokeStarted();
        return new Promise(resolve => { finishOldRevoke = () => resolve({}); });
      });
      const { disconnectToolkit } = await import('./composio.service.js');

      const repair = disconnectToolkit('user-reconnected', 'gmail', {
        isCurrent: () => current,
        repairAccountIds: ['acct-old'],
      });
      await oldRevokeStarted;
      // The replacement grant publishes while the already-authorized old-account write awaits.
      current = false;
      finishOldRevoke();

      await expect(repair).resolves.toEqual({ deleted: 1 });
      expect(mocks.rawConnectedAccountsDelete).toHaveBeenCalledTimes(1);
      expect(mocks.rawConnectedAccountsDelete.mock.calls[0]?.[0]).toBe('acct-old');
    });
  });

  // Enable / disable (pause) — the NON-destructive counterpart to disconnect. Flips ACTIVE↔INACTIVE
  // for EVERY matching account of the toolkit; keeps the OAuth grant (no revoke). Uses the high-level
  // connectedAccounts.enable/disable (correctly forwarded, unlike delete's revoke_on_delete).
  describe('setToolkitEnabled', () => {
    it('disable pauses EVERY active account for the toolkit (multi-account), never revoking', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [
          { id: 'acct_a', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
          { id: 'acct_b', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
        ],
        nextCursor: null,
      });
      mocks.connectedAccountsDisable.mockResolvedValue({ id: 'x', status: 'INACTIVE' });

      const { setToolkitEnabled } = await import('./composio.service.js');
      const result = await setToolkitEnabled('user-1', 'gmail', false);

      expect(result).toEqual({ updated: 2 });
      expect(mocks.connectedAccountsDisable).toHaveBeenCalledWith('acct_a', { signal: expect.anything() });
      expect(mocks.connectedAccountsDisable).toHaveBeenCalledWith('acct_b', { signal: expect.anything() });
      expect(mocks.connectedAccountsDisable).toHaveBeenCalledTimes(2);
      // Pause is non-destructive: the revoke path must never fire.
      expect(mocks.rawConnectedAccountsDelete).not.toHaveBeenCalled();
      expect(mocks.connectedAccountsEnable).not.toHaveBeenCalled();
      // Disable targets ACTIVE accounts, scoped to this user + toolkit.
      expect(mocks.connectedAccountsList).toHaveBeenCalledWith(
        expect.objectContaining({ userIds: ['user-1'], toolkitSlugs: ['gmail'], statuses: ['ACTIVE'] }),
        { signal: expect.anything() },
      );
    });

    it('enable resumes the PAUSED (INACTIVE) accounts — not the active ones', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct_paused', status: 'INACTIVE', toolkit: { slug: 'slack' } }],
        nextCursor: null,
      });
      mocks.connectedAccountsEnable.mockResolvedValue({ id: 'acct_paused', status: 'ACTIVE' });

      const { setToolkitEnabled } = await import('./composio.service.js');
      const result = await setToolkitEnabled('user-1', 'slack', true);

      expect(result).toEqual({ updated: 1 });
      expect(mocks.connectedAccountsEnable).toHaveBeenCalledWith(
        'acct_paused', { signal: expect.anything() },
      );
      expect(mocks.connectedAccountsDisable).not.toHaveBeenCalled();
      // Enable targets INACTIVE accounts (a paused row), scoped to this user + toolkit.
      expect(mocks.connectedAccountsList).toHaveBeenCalledWith(
        expect.objectContaining({ userIds: ['user-1'], toolkitSlugs: ['slack'], statuses: ['INACTIVE'] }),
        { signal: expect.anything() },
      );
    });

    it('follows pagination — pauses an active account found on page 2', async () => {
      mocks.connectedAccountsList.mockImplementation(async (params: { cursor?: string }) => {
        if (!params.cursor) {
          return { items: [{ id: 'acct_p1', status: 'ACTIVE', toolkit: { slug: 'gmail' } }], nextCursor: 'cur2' };
        }
        return { items: [{ id: 'acct_p2', status: 'ACTIVE', toolkit: { slug: 'gmail' } }], nextCursor: null };
      });
      mocks.connectedAccountsDisable.mockResolvedValue({ id: 'x', status: 'INACTIVE' });

      const { setToolkitEnabled } = await import('./composio.service.js');
      const result = await setToolkitEnabled('user-1', 'gmail', false);

      expect(result).toEqual({ updated: 2 });
      expect(mocks.connectedAccountsDisable).toHaveBeenCalledWith('acct_p2', { signal: expect.anything() });
      expect(mocks.connectedAccountsList).toHaveBeenNthCalledWith(
        2, expect.objectContaining({ cursor: 'cur2' }), { signal: expect.anything() },
      );
    });

    it('is idempotent — nothing in the source state returns { updated: 0 } and calls neither enable nor disable', async () => {
      mocks.connectedAccountsList.mockResolvedValue({ items: [], nextCursor: null });
      const { setToolkitEnabled } = await import('./composio.service.js');

      const disabled = await setToolkitEnabled('user-1', 'gmail', false);
      expect(disabled).toEqual({ updated: 0 });
      const enabled = await setToolkitEnabled('user-1', 'gmail', true);
      expect(enabled).toEqual({ updated: 0 });

      expect(mocks.connectedAccountsDisable).not.toHaveBeenCalled();
      expect(mocks.connectedAccountsEnable).not.toHaveBeenCalled();
    });

    it('re-lists and pauses a grant that appears after an earlier zero-target pause', async () => {
      mocks.connectedAccountsList
        .mockResolvedValueOnce({ items: [], nextCursor: null })
        .mockResolvedValueOnce({
          items: [{ id: 'acct_late', status: 'ACTIVE', toolkit: { slug: 'discord' } }],
          nextCursor: null,
        });
      mocks.connectedAccountsDisable.mockResolvedValue({ id: 'acct_late', status: 'INACTIVE' });
      const { setToolkitEnabled } = await import('./composio.service.js');

      await expect(setToolkitEnabled('user-1', 'discord', false)).resolves.toEqual({ updated: 0 });
      await expect(setToolkitEnabled('user-1', 'discord', false)).resolves.toEqual({ updated: 1 });

      expect(mocks.connectedAccountsList).toHaveBeenCalledTimes(2);
      expect(mocks.connectedAccountsDisable).toHaveBeenCalledWith(
        'acct_late', { signal: expect.anything() },
      );
    });

    it('rejects an unknown toolkit slug with ComposioToolkitError (400), never touching the API', async () => {
      const { setToolkitEnabled, ComposioToolkitError } = await import('./composio.service.js');
      await expect(setToolkitEnabled('user-1', 'notarealtoolkit', false)).rejects.toBeInstanceOf(ComposioToolkitError);
      expect(mocks.connectedAccountsList).not.toHaveBeenCalled();
      expect(mocks.connectedAccountsDisable).not.toHaveBeenCalled();
      expect(mocks.connectedAccountsEnable).not.toHaveBeenCalled();
    });

    it('aborts a stalled account status mutation so an idempotent retry can converge it', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct_stalled', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.connectedAccountsDisable.mockImplementation(() => new Promise(() => {}));
      const { setToolkitEnabled } = await import('./composio.service.js');

      const startedAt = Date.now();
      await expect(setToolkitEnabled('user-stalled-pause', 'gmail', false)).rejects.toThrow('timed out');
      expect(Date.now() - startedAt).toBeLessThan(1_000);
    });

    it('normalizes an abort-aware SDK rejection to ComposioMutationTimeoutError', async () => {
      mocks.connectedAccountsList.mockResolvedValue({
        items: [{ id: 'acct_abort_aware', status: 'ACTIVE', toolkit: { slug: 'gmail' } }],
        nextCursor: null,
      });
      mocks.connectedAccountsDisable.mockImplementation((_id: string, options: { signal: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          options.signal.addEventListener('abort', () => reject(new Error('plain SDK abort')), { once: true });
        }));
      const { setToolkitEnabled, ComposioMutationTimeoutError } = await import('./composio.service.js');

      await expect(setToolkitEnabled('user-abort-aware', 'gmail', false))
        .rejects.toBeInstanceOf(ComposioMutationTimeoutError);
    });
  });

  // The list summary must carry an `enabled` flag so the client can render the row's switch state on
  // load: a fully-active toolkit is available; a toolkit whose only account is disabled reads as
  // connected-but-paused (NOT "failed", the pre-pause behavior for a non-active row).
  describe('listToolkitsSummary enabled/paused status (switch state on load)', () => {
    it('reports ACTIVE discord as connected+enabled without conflating discordbot', async () => {
      mocks.toolkitsGet.mockImplementation(async (slug: string) => ({ slug, meta: { logo: `https://l/${slug}.svg` } }));
      mocks.connectedAccountsList.mockResolvedValue({
        items: [
          { id: 'a1', status: 'ACTIVE', toolkit: { slug: 'discord' } },
          { id: 'a2', status: 'INACTIVE', toolkit: { slug: 'slack' } },
        ],
      });

      const { listToolkitsSummary } = await import('./composio.service.js');
      const summary = await listToolkitsSummary('user-1');
      const bySlug = new Map(summary.toolkits.map(t => [t.slug, t]));

      // Active → available.
      expect(bySlug.get('discord')).toMatchObject({ status: 'connected', enabled: true });
      // The bot-oriented toolkit is a separate connection and must remain disconnected.
      expect(bySlug.get('discordbot')).toMatchObject({ status: 'not_connected', enabled: false });
      // Disabled-only → still connected (keeps its switch), but paused.
      expect(bySlug.get('slack')).toMatchObject({ status: 'connected', enabled: false });
      // Never-connected toolkit → not_connected + disabled.
      expect(bySlug.get('notion')).toMatchObject({ status: 'not_connected', enabled: false });
    });

    it('prefers ACTIVE over INACTIVE when a toolkit has both (multi-account) — reads as available', async () => {
      mocks.toolkitsGet.mockImplementation(async (slug: string) => ({ slug, meta: { logo: `https://l/${slug}.svg` } }));
      mocks.connectedAccountsList.mockResolvedValue({
        items: [
          { id: 'g1', status: 'INACTIVE', toolkit: { slug: 'gmail' } },
          { id: 'g2', status: 'ACTIVE', toolkit: { slug: 'gmail' } },
        ],
      });

      const { listToolkitsSummary } = await import('./composio.service.js');
      const summary = await listToolkitsSummary('user-1');
      const gmail = summary.toolkits.find(t => t.slug === 'gmail');
      expect(gmail).toMatchObject({ status: 'connected', enabled: true });
    });
  });
});

// getConnectionStatus used to hardcode toolkit:'gmail' in every branch, so a status poll for any
// non-Gmail connector misreported the toolkit. With the 3→11 catalog expansion that latent bug got
// riskier — these lock in that the RIGHT toolkit is threaded through, and that we say `null` (never
// a default) when we genuinely don't know.
describe('getConnectionStatus toolkit threading (#1103 follow-up)', () => {
  const ORIGINAL_KEY = process.env.COMPOSIO_API_KEY;

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.COMPOSIO_API_KEY = 'test-key';
  });

  afterEach(() => {
    process.env.COMPOSIO_API_KEY = ORIGINAL_KEY;
  });

  it('reports Composio\'s own discord slug on a connected account', async () => {
    const { getConnectionStatus } = await import('./composio.service.js');
    mocks.connectedAccountsWaitForConnection.mockResolvedValue({ id: 'acct_1', toolkit: { slug: 'discord' } });
    const state = await getConnectionStatus('user-1', 'conn_1', 'discord');
    expect(state).toEqual({ toolkit: 'discord', status: 'connected', connectedAccountId: 'acct_1', enabled: true });
  });

  it('falls back to the polled toolkit (NOT gmail) when the account omits a slug', async () => {
    const { getConnectionStatus } = await import('./composio.service.js');
    mocks.connectedAccountsWaitForConnection.mockResolvedValue({ id: 'acct_2', toolkit: undefined });
    const state = await getConnectionStatus('user-1', 'conn_2', 'slack');
    expect(state.toolkit).toBe('slack');
    expect(state.status).toBe('connected');
  });

  it('reports the polled toolkit (NOT gmail) on a pending timeout', async () => {
    const { getConnectionStatus } = await import('./composio.service.js');
    const { ConnectionRequestTimeoutError } = await import('@composio/core');
    mocks.connectedAccountsWaitForConnection.mockRejectedValue(new ConnectionRequestTimeoutError('pending'));
    const state = await getConnectionStatus('user-1', 'conn_3', 'notion');
    expect(state).toEqual({ toolkit: 'notion', status: 'pending', connectedAccountId: null, enabled: false });
  });

  it('reports the polled toolkit (NOT gmail) on a failed connection', async () => {
    const { getConnectionStatus } = await import('./composio.service.js');
    const { ConnectionRequestFailedError } = await import('@composio/core');
    mocks.connectedAccountsWaitForConnection.mockRejectedValue(new ConnectionRequestFailedError('failed'));
    const state = await getConnectionStatus('user-1', 'conn_4', 'linear');
    expect(state).toEqual({ toolkit: 'linear', status: 'failed', connectedAccountId: null, enabled: false });
  });

  it('returns toolkit null (never gmail) when the caller supplies no toolkit', async () => {
    const { getConnectionStatus } = await import('./composio.service.js');
    const { ConnectionRequestTimeoutError } = await import('@composio/core');
    mocks.connectedAccountsWaitForConnection.mockRejectedValue(new ConnectionRequestTimeoutError('pending'));
    const state = await getConnectionStatus('user-1', 'conn_5');
    expect(state.toolkit).toBeNull();
    expect(state.status).toBe('pending');
  });
});

describe('backend Gmail brief adapter', () => {
  beforeEach(() => vi.clearAllMocks());

  it('enumerates only ACTIVE, non-disabled Gmail accounts across pages', async () => {
    mocks.connectedAccountsList
      .mockResolvedValueOnce({
        items: [
          { id: 'active', status: 'ACTIVE', isDisabled: false },
          { id: 'paused-flag', status: 'ACTIVE', isDisabled: true },
          { id: 'inactive', status: 'INACTIVE', isDisabled: false },
        ],
        nextCursor: 'next',
      })
      .mockResolvedValueOnce({ items: [{ id: 'active-2', status: 'ACTIVE' }], nextCursor: null });
    // Bound through the shared toolkit-generic account source — the one binding the Daily Brief
    // collector and the signal ingester both use. There is no Gmail-specific wrapper any more.
    const { composioActiveAccountSource } = await import('./composio.service.js');
    await expect(composioActiveAccountSource.listActiveAccountIds('user-1', 'gmail', 2_500))
      .resolves.toEqual(['active', 'active-2']);
    expect(mocks.connectedAccountsList).toHaveBeenNthCalledWith(1, expect.objectContaining({
      userIds: ['user-1'], toolkitSlugs: ['gmail'], statuses: ['ACTIVE'], limit: 100,
    }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });

  it('strictly validates the success envelope and proven optional message fields', async () => {
    const { parseGmailFetchEmailsResult } = await import('./composio.service.js');
    expect(() => parseGmailFetchEmailsResult({ successful: false, error: 'denied', data: {} })).toThrow('gmail_action_failed');
    expect(parseGmailFetchEmailsResult({
      successful: true,
      error: null,
      data: {
        messages: [
          { messageId: 'm1', threadId: 't1', subject: 'Subject', sender: 'a@example.com', preview: 'Preview', messageTimestamp: '2026-08-09T16:30:00Z' },
        ],
        nextPageToken: 'page-2',
      },
    })).toEqual({
      items: [{ providerMessageId: 'm1', providerThreadId: 't1', subject: 'Subject', sender: 'a@example.com', snippet: 'Preview', timestamp: '2026-08-09T16:30:00Z' }],
      nextPageToken: 'page-2',
    });
  });

  it('rejects every malformed record on a nonempty page but preserves a valid empty page', async () => {
    const { parseGmailFetchEmailsResult } = await import('./composio.service.js');
    expect(parseGmailFetchEmailsResult({
      successful: true, error: null, data: { messages: [], nextPageToken: null },
    })).toEqual({ items: [], nextPageToken: null });

    for (const malformed of [
      null,
      { messageTimestamp: '2026-08-09T16:30:00Z' },
      { messageId: '   ', messageTimestamp: '2026-08-09T16:30:00Z' },
      { messageId: 'm1' },
      { messageId: 'm1', messageTimestamp: '08/09/2026 4:30 PM' },
      { messageId: 'm1', messageTimestamp: '2026-99-99T99:99:99Z' },
      { messageId: 'm1', messageTimestamp: '2026-02-30T12:00:00Z' },
    ]) {
      expect(() => parseGmailFetchEmailsResult({
        successful: true, error: null, data: { messages: [malformed] },
      })).toThrow('invalid_gmail_message');
    }
  });

  it('accepts real RFC3339 instants with offsets and fractional seconds', async () => {
    const { parseGmailFetchEmailsResult } = await import('./composio.service.js');
    const parsed = parseGmailFetchEmailsResult({
      successful: true,
      error: null,
      data: {
        messages: [
          { messageId: ' offset ', messageTimestamp: '2026-08-09T16:30:00.123456+05:30' },
          { messageId: 'leap', messageTimestamp: '2024-02-29T23:59:59-08:00' },
        ],
      },
    });
    expect(parsed.items.map((item) => [item.providerMessageId, item.timestamp])).toEqual([
      ['offset', '2026-08-09T16:30:00.123456+05:30'],
      ['leap', '2024-02-29T23:59:59-08:00'],
    ]);
  });

  it('turns a malformed nonempty provider page into retryable unavailable collection', async () => {
    mocks.toolsExecute.mockResolvedValue({
      successful: true,
      error: null,
      data: { messages: [{ messageId: 'm1', messageTimestamp: '2026-02-30T12:00:00Z' }] },
    });
    const { composioGmailBriefAdapter } = await import('./composio.service.js');
    const { collectGmailBriefInput } = await import('./brief-input.service.js');
    const snapshot = await collectGmailBriefInput(
      'user-1',
      new Date('2026-08-09T17:00:00Z'),
      { listActiveAccountIds: async () => ['account-1'] },
      composioGmailBriefAdapter,
    );
    expect(snapshot.gmail).toEqual([]);
    expect(snapshot.manifest[0]).toMatchObject({
      availability: 'unavailable',
      unavailableReason: 'connector_unavailable',
    });
  });

  it('executes the exact pinned read-only action with payload/body suppression', async () => {
    mocks.toolsExecute.mockResolvedValue({ successful: true, error: null, data: { messages: [] } });
    const { composioGmailBriefAdapter } = await import('./composio.service.js');
    await composioGmailBriefAdapter.fetchPage({
      userId: 'user-1', connectedAccountId: 'account-1', action: 'GMAIL_FETCH_EMAILS',
      version: '20260721_00', query: 'after:2026/08/08 before:2026/08/10',
      maxResults: 10, pageToken: 'next', timeoutMs: 2_500,
    });
    expect(mocks.toolsExecute).toHaveBeenCalledWith('GMAIL_FETCH_EMAILS', expect.objectContaining({
      userId: 'user-1', connectedAccountId: 'account-1', version: '20260721_00',
      arguments: {
        verbose: false, include_payload: false, ids_only: false, include_spam_trash: false,
        max_results: 10, query: 'after:2026/08/08 before:2026/08/10', page_token: 'next',
      },
    }), expect.objectContaining({ signal: expect.any(AbortSignal) }));
  });
});
