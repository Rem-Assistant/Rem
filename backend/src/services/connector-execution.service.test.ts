import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// vi.mock factories are hoisted above every top-level statement, so the mock fns they close over
// must be created via vi.hoisted() (which runs first) — the house pattern for every service test in
// this folder (see composio.service.test.ts).
const mocks = vi.hoisted(() => ({
  toolsExecute: vi.fn(),
}));

// Mock ONLY the SDK boundary — mirrors composio.service.test.ts. `executeComposioTool` runs for real
// against this mock, so the exact `client().tools.execute(action, params, options)` call shape stays
// proven end to end. The error classes are the named imports composio.service.ts pulls at module top.
vi.mock('@composio/core', () => ({
  Composio: class {
    tools = { execute: (...args: unknown[]) => mocks.toolsExecute(...args) };
  },
  ComposioAuthConfigNotFoundError: class extends Error {},
  ComposioConnectedAccountNotFoundError: class extends Error {},
  ConnectionRequestFailedError: class extends Error {},
  ConnectionRequestTimeoutError: class extends Error {},
}));

// Insulate composio.service.js from the real gateway/DB modules (they import ../db/pool.js). We never
// exercise these paths — the ACTIVE-account source is injected — so bare stubs keep the vitest process
// free of open pg handles and let it terminate cleanly.
vi.mock('./gateway-pair.service.js', () => ({ withGatewayRequester: vi.fn() }));
vi.mock('./gateway-lifecycle-lock.service.js', () => ({
  tryWithUserGatewayConfigReconciliationLock: vi.fn(),
}));
vi.mock('./gateway.service.js', () => ({
  getGatewayCredentialsWithClient: vi.fn(),
  getLocalGatewayCredentials: vi.fn(),
  getSetupPasswordWithClient: vi.fn(),
}));

const GOOD_ENVELOPE = { successful: true, error: null, data: { messages: [{ id: 'm1' }], nextPageToken: null } };
const BASE_INPUT = {
  userId: 'user-1',
  toolkit: 'gmail',
  action: 'GMAIL_FETCH_EMAILS',
  actionVersion: '20260721_00',
  arguments: { max_results: 5, query: 'after:2026/08/08' },
} as const;

describe('executeConnectorRead (Rem-owned connector READ, no gateway)', () => {
  const ORIGINAL_KEY = process.env.COMPOSIO_API_KEY;

  beforeEach(() => {
    vi.clearAllMocks();
    process.env.COMPOSIO_API_KEY = 'test-key';
  });

  afterEach(() => {
    process.env.COMPOSIO_API_KEY = ORIGINAL_KEY;
  });

  it('(a) happy path: resolves the ACTIVE account THEN calls execute with the pinned shape, returns ok+data', async () => {
    mocks.toolsExecute.mockResolvedValue(GOOD_ENVELOPE);
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    const res = await executeConnectorRead({ ...BASE_INPUT, timeoutMs: 2_000 }, { listActiveAccountIds });

    // Account resolution uses the injected source with the toolkit + timeout.
    expect(listActiveAccountIds).toHaveBeenCalledWith('user-1', 'gmail', 2_000);
    // Execute is called with EXACTLY { userId, connectedAccountId, version, arguments } + a signal.
    expect(mocks.toolsExecute).toHaveBeenCalledWith(
      'GMAIL_FETCH_EMAILS',
      {
        userId: 'user-1',
        connectedAccountId: 'account-1',
        version: '20260721_00',
        arguments: { max_results: 5, query: 'after:2026/08/08' },
      },
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
    // ...and the account is resolved BEFORE execute is called (the ordering the flow guarantees).
    expect(listActiveAccountIds.mock.invocationCallOrder[0])
      .toBeLessThan(mocks.toolsExecute.mock.invocationCallOrder[0]);
    expect(res).toEqual({ kind: 'ok', data: { messages: [{ id: 'm1' }], nextPageToken: null } });
  });

  it('(b) no active account: returns no_active_connection and NEVER calls execute', async () => {
    mocks.toolsExecute.mockResolvedValue(GOOD_ENVELOPE);
    const listActiveAccountIds = vi.fn().mockResolvedValue([]);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    const res = await executeConnectorRead(BASE_INPUT, { listActiveAccountIds });

    expect(res).toEqual({ kind: 'no_active_connection' });
    expect(mocks.toolsExecute).not.toHaveBeenCalled();
  });

  it('(c) a not-explicitly-successful envelope becomes failed with a structured reason', async () => {
    mocks.toolsExecute.mockResolvedValue({ successful: false, error: 'quota', data: null });
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    const res = await executeConnectorRead(BASE_INPUT, { listActiveAccountIds });

    expect(res).toEqual({ kind: 'failed', reason: 'action_failed' });
  });

  it('(d) a non-allow-listed action (or wrong pinned version) is refused BEFORE any provider call', async () => {
    mocks.toolsExecute.mockResolvedValue(GOOD_ENVELOPE);
    // Resolves fine if reached — proving the gate short-circuits before account resolution + execute.
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    const write = await executeConnectorRead(
      { ...BASE_INPUT, action: 'GMAIL_SEND_EMAIL' },
      { listActiveAccountIds },
    );
    expect(write).toEqual({ kind: 'failed', reason: 'action_not_allowed' });

    // Same refusal for the allow-listed action at an unpinned version — the version is pinned too.
    const floated = await executeConnectorRead(
      { ...BASE_INPUT, actionVersion: '99999999_99' },
      { listActiveAccountIds },
    );
    expect(floated).toEqual({ kind: 'failed', reason: 'action_not_allowed' });

    expect(listActiveAccountIds).not.toHaveBeenCalled();
    expect(mocks.toolsExecute).not.toHaveBeenCalled();
  });

  it('(e) wires an AbortSignal into execute, merging the caller signal with the timeout', async () => {
    mocks.toolsExecute.mockResolvedValue(GOOD_ENVELOPE);
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    // No caller signal → execute still receives the timeout AbortSignal.
    await executeConnectorRead(BASE_INPUT, { listActiveAccountIds });
    const soloSignal = mocks.toolsExecute.mock.calls[0][2].signal as AbortSignal;
    expect(soloSignal).toBeInstanceOf(AbortSignal);

    // With a caller signal → the passed signal is a NEW merged signal (not the raw caller signal),
    // and aborting the caller's controller aborts the merged signal.
    mocks.toolsExecute.mockClear();
    const controller = new AbortController();
    await executeConnectorRead({ ...BASE_INPUT, signal: controller.signal }, { listActiveAccountIds });
    const mergedSignal = mocks.toolsExecute.mock.calls[0][2].signal as AbortSignal;
    expect(mergedSignal).toBeInstanceOf(AbortSignal);
    expect(mergedSignal).not.toBe(controller.signal);
    expect(mergedSignal.aborted).toBe(false);
    controller.abort();
    expect(mergedSignal.aborted).toBe(true);
  });

  it('(f) a successful-looking envelope that also carries an error is failed, not an empty read', async () => {
    mocks.toolsExecute.mockResolvedValue({ successful: true, error: 'rate_limited', data: { messages: [] } });
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    expect(await executeConnectorRead(BASE_INPUT, { listActiveAccountIds }))
      .toEqual({ kind: 'failed', reason: 'action_failed' });
  });

  it('(g) a non-object execute result is invalid_result', async () => {
    mocks.toolsExecute.mockResolvedValue('not an object');
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    expect(await executeConnectorRead(BASE_INPUT, { listActiveAccountIds }))
      .toEqual({ kind: 'failed', reason: 'invalid_result' });
  });

  it('(h) a successful envelope whose data is not an object is invalid_data', async () => {
    mocks.toolsExecute.mockResolvedValue({ successful: true, error: null, data: null });
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    expect(await executeConnectorRead(BASE_INPUT, { listActiveAccountIds }))
      .toEqual({ kind: 'failed', reason: 'invalid_data' });
  });

  it('(i) an execute throw maps to timeout (abort) or connector_unavailable (other), never silent success', async () => {
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    mocks.toolsExecute.mockRejectedValueOnce(Object.assign(new Error('aborted'), { name: 'AbortError' }));
    expect(await executeConnectorRead(BASE_INPUT, { listActiveAccountIds }))
      .toEqual({ kind: 'failed', reason: 'timeout' });

    mocks.toolsExecute.mockRejectedValueOnce(new Error('socket hang up'));
    expect(await executeConnectorRead(BASE_INPUT, { listActiveAccountIds }))
      .toEqual({ kind: 'failed', reason: 'connector_unavailable' });
  });

  it('(j) a throw from account resolution is a structured failed result, not an unhandled rejection', async () => {
    mocks.toolsExecute.mockResolvedValue(GOOD_ENVELOPE);
    const listActiveAccountIds = vi.fn().mockRejectedValue(new Error('composio down'));
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    expect(await executeConnectorRead(BASE_INPUT, { listActiveAccountIds }))
      .toEqual({ kind: 'failed', reason: 'connector_unavailable' });
    expect(mocks.toolsExecute).not.toHaveBeenCalled();
  });

  it('(k) fails CLOSED when action + version are both undefined (type violation): no account lookup, no execute', async () => {
    mocks.toolsExecute.mockResolvedValue(GOOD_ENVELOPE);
    const listActiveAccountIds = vi.fn().mockResolvedValue(['account-1']);
    const { executeConnectorRead } = await import('./connector-execution.service.js');

    const res = await executeConnectorRead(
      { ...BASE_INPUT, action: undefined as unknown as string, actionVersion: undefined as unknown as string },
      { listActiveAccountIds },
    );

    expect(res).toEqual({ kind: 'failed', reason: 'action_not_allowed' });
    expect(listActiveAccountIds).not.toHaveBeenCalled();
    expect(mocks.toolsExecute).not.toHaveBeenCalled();
  });
});
