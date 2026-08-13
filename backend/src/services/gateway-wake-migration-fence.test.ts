import { beforeEach, describe, expect, it, vi } from 'vitest';

const lifecycleLockMock = vi.hoisted(() => ({ tryWithUserGatewayLifecycleLock: vi.fn() }));
const poolMock = vi.hoisted(() => ({ query: vi.fn() }));
const flyServiceMock = vi.hoisted(() => ({
  getMachine: vi.fn(),
  startMachine: vi.fn(),
  waitForMachineReady: vi.fn(),
}));

vi.mock('./gateway-lifecycle-lock.service.js', () => lifecycleLockMock);
vi.mock('../db/pool.js', () => ({ pool: poolMock }));
vi.mock('./gateway/hosted-provisioning.js', () => ({
  getHostedGatewayProvisioning: () => flyServiceMock,
}));
vi.mock('../config/env.js', () => ({
  env: { GATEWAY_ENCRYPTION_KEY: 'test-encryption-key' },
}));

const {
  GATEWAY_WAKE_FLY_LOCK_TIMEOUT_MS,
  wakeGatewayForUser,
} = await import('./gateway.service.js');

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true }));
});

describe('wakeGatewayForUser migration fence', () => {
  it('does not read stale metadata or start the source while migration owns the lifecycle lock', async () => {
    poolMock.query.mockResolvedValue({
      rows: [{
        gateway_url: 'https://remclaw-pool-one.fly.dev',
        hosting_provider: 'fly',
        fly_app_name: 'remclaw-pool-one',
        fly_machine_id: 'machine-1',
      }],
    });
    lifecycleLockMock.tryWithUserGatewayLifecycleLock.mockResolvedValue({ acquired: false });

    await expect(wakeGatewayForUser('user-1')).resolves.toEqual({
      ok: true,
      provider: 'fly',
      action: 'noop',
      machineState: 'migration_fenced',
      gatewayReady: false,
    });
    expect(poolMock.query).toHaveBeenCalledTimes(1);
    expect(lifecycleLockMock.tryWithUserGatewayLifecycleLock).toHaveBeenCalledTimes(1);
  });

  it('does not wake a deleted user from stale metadata after acquiring the lifecycle lock', async () => {
    poolMock.query.mockResolvedValue({
      rows: [{
        gateway_url: 'https://remclaw-pool-one.fly.dev',
        hosting_provider: 'fly',
        fly_app_name: 'remclaw-pool-one',
        fly_machine_id: 'machine-1',
      }],
    });
    lifecycleLockMock.tryWithUserGatewayLifecycleLock.mockImplementation(
      async (_userId: string, callback: (client: { query: typeof poolMock.query }) => Promise<unknown>) => ({
        acquired: true,
        value: await callback({ query: vi.fn().mockResolvedValue({ rows: [] }) }),
      }),
    );

    await expect(wakeGatewayForUser('deleted-user')).resolves.toEqual({
      ok: true,
      provider: 'none',
      action: 'noop',
      machineState: 'missing_gateway',
      gatewayReady: false,
    });
    expect(flyServiceMock.getMachine).not.toHaveBeenCalled();
    expect(flyServiceMock.startMachine).not.toHaveBeenCalled();
  });

  it('does not reserve a lifecycle client for a non-Fly gateway', async () => {
    poolMock.query.mockResolvedValue({
      rows: [{
        gateway_url: 'https://manual.example.com',
        hosting_provider: 'manual',
        fly_app_name: null,
        fly_machine_id: null,
      }],
    });

    await expect(wakeGatewayForUser('user-1')).resolves.toMatchObject({
      provider: 'manual',
      action: 'noop',
      machineState: 'unsupported',
    });
    expect(lifecycleLockMock.tryWithUserGatewayLifecycleLock).not.toHaveBeenCalled();
  });

  it('wakes a dedicated Fly gateway under the lifecycle fence', async () => {
    const dedicatedRow = {
      gateway_url: 'https://remclaw-user-one.fly.dev',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-user-one',
      fly_machine_id: 'machine-1',
    };
    poolMock.query.mockResolvedValue({ rows: [dedicatedRow] });
    lifecycleLockMock.tryWithUserGatewayLifecycleLock.mockImplementation(
      async (_userId: string, callback: (client: { query: typeof poolMock.query }) => Promise<unknown>) => ({
        acquired: true,
        value: await callback({ query: vi.fn().mockResolvedValue({ rows: [dedicatedRow] }) }),
      }),
    );
    flyServiceMock.getMachine.mockResolvedValue({ state: 'started' });

    await expect(wakeGatewayForUser('user-1')).resolves.toMatchObject({
      provider: 'fly',
      action: 'noop',
      gatewayReady: true,
    });
    expect(lifecycleLockMock.tryWithUserGatewayLifecycleLock).toHaveBeenCalledTimes(1);
    expect(flyServiceMock.getMachine).toHaveBeenCalledTimes(2);
  });

  it('does not wake a deleted dedicated gateway from its pre-lock read', async () => {
    poolMock.query.mockResolvedValue({
      rows: [{
        gateway_url: 'https://remclaw-user-one.fly.dev',
        hosting_provider: 'fly',
        fly_app_name: 'remclaw-user-one',
        fly_machine_id: 'machine-1',
      }],
    });
    lifecycleLockMock.tryWithUserGatewayLifecycleLock.mockImplementation(
      async (_userId: string, callback: (client: { query: typeof poolMock.query }) => Promise<unknown>) => ({
        acquired: true,
        value: await callback({ query: vi.fn().mockResolvedValue({ rows: [] }) }),
      }),
    );

    await expect(wakeGatewayForUser('deleted-user')).resolves.toMatchObject({
      provider: 'none',
      machineState: 'missing_gateway',
      gatewayReady: false,
    });
    expect(flyServiceMock.getMachine).not.toHaveBeenCalled();
    expect(flyServiceMock.startMachine).not.toHaveBeenCalled();
  });

  it('releases the lifecycle client before dedicated readiness polling', async () => {
    const order: string[] = [];
    const dedicatedRow = {
      gateway_url: 'https://remclaw-user-one.fly.dev',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-user-one',
      fly_machine_id: 'machine-1',
    };
    poolMock.query.mockResolvedValue({ rows: [dedicatedRow] });
    lifecycleLockMock.tryWithUserGatewayLifecycleLock.mockImplementation(
      async (_userId: string, callback: (client: { query: typeof poolMock.query }) => Promise<unknown>) => {
        const value = await callback({ query: vi.fn().mockResolvedValue({ rows: [dedicatedRow] }) });
        order.push('lock-released');
        return { acquired: true, value };
      },
    );
    flyServiceMock.getMachine
      .mockResolvedValueOnce({ state: 'suspended' })
      .mockResolvedValueOnce({ state: 'started' });
    flyServiceMock.waitForMachineReady.mockImplementation(async () => {
      order.push('readiness-polled');
    });

    await expect(wakeGatewayForUser('user-1')).resolves.toMatchObject({
      provider: 'fly',
      action: 'start',
      gatewayReady: true,
    });
    expect(order).toEqual(['lock-released', 'readiness-polled']);
  });

  it('shares one short deadline across Fly work performed while holding the lifecycle lock', async () => {
    expect(GATEWAY_WAKE_FLY_LOCK_TIMEOUT_MS).toBe(5_000);
    const dedicatedRow = {
      gateway_url: 'https://remclaw-user-one.fly.dev',
      hosting_provider: 'fly',
      fly_app_name: 'remclaw-user-one',
      fly_machine_id: 'machine-1',
    };
    poolMock.query.mockResolvedValue({ rows: [dedicatedRow] });
    lifecycleLockMock.tryWithUserGatewayLifecycleLock.mockImplementation(
      async (_userId: string, callback: (client: { query: typeof poolMock.query }) => Promise<unknown>) => ({
        acquired: true,
        value: await callback({ query: vi.fn().mockResolvedValue({ rows: [dedicatedRow] }) }),
      }),
    );
    flyServiceMock.getMachine
      .mockResolvedValueOnce({ state: 'suspended' })
      .mockResolvedValueOnce({ state: 'started' });

    await wakeGatewayForUser('user-1');

    const getOptions = flyServiceMock.getMachine.mock.calls[0]?.[2];
    const startOptions = flyServiceMock.startMachine.mock.calls[0]?.[2];
    expect(getOptions?.signal).toBeInstanceOf(AbortSignal);
    expect(startOptions?.signal).toBe(getOptions?.signal);
  });
});
