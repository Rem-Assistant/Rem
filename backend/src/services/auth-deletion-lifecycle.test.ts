import { beforeEach, describe, expect, it, vi } from 'vitest';

const clientMock = vi.hoisted(() => ({
  connect: vi.fn(),
  query: vi.fn(),
  end: vi.fn(),
}));
const poolMock = vi.hoisted(() => ({ connect: vi.fn(), query: vi.fn() }));
const createDedicatedDatabaseClientMock = vi.hoisted(() => vi.fn());
const flyServiceMock = vi.hoisted(() => ({ destroyApp: vi.fn() }));
const envMock = vi.hoisted(() => ({ gatewayMutationsDisabled: false }));
const jwtMock = vi.hoisted(() => ({ sign: vi.fn().mockReturnValue('apple-client-secret') }));
let interruptedRows: Array<{
  source_app_name: string;
  target_app_name: string;
  target_ownership_state: string;
}> = [];
let retainedRows: Array<{ id: string; fly_app_name: string; status: string }> = [];
let appleAuthCode: string | null = null;
let userFlyApp: { fly_app_name: string | null; fly_machine_id: string | null; hosting_provider: string | null };

vi.mock('../db/pool.js', () => ({
  pool: poolMock,
  createDedicatedDatabaseClient: createDedicatedDatabaseClientMock,
}));
vi.mock('./gateway/hosted-provisioning.js', () => ({
  getHostedGatewayProvisioning: () => flyServiceMock,
}));
vi.mock('jsonwebtoken', () => ({ default: jwtMock }));
vi.mock('../config/env.js', () => ({
  env: {
    JWT_SECRET: 'test-jwt-secret',
    GATEWAY_ENCRYPTION_KEY: 'test-encryption-key',
    APPLE_TEAM_ID: 'apple-team',
    APPLE_KEY_ID: 'apple-key',
    APPLE_CLIENT_ID: 'com.remapp.rem',
    APPLE_PRIVATE_KEY: 'fake-private-key',
    get GATEWAY_MUTATIONS_DISABLED() { return envMock.gatewayMutationsDisabled; },
  },
}));

const { deleteUser } = await import('./auth.service.js');

beforeEach(() => {
  vi.clearAllMocks();
  envMock.gatewayMutationsDisabled = false;
  interruptedRows = [];
  retainedRows = [{ id: 'pool-row-1', fly_app_name: 'remclaw-pool-one', status: 'migrated' }];
  appleAuthCode = null;
  userFlyApp = { fly_app_name: null, fly_machine_id: null, hosting_provider: null };
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true }));
  clientMock.connect.mockResolvedValue(undefined);
  clientMock.end.mockResolvedValue(undefined);
  createDedicatedDatabaseClientMock.mockReturnValue(clientMock);
  clientMock.query.mockImplementation(async (sql: string) => {
    if (sql.includes('SELECT fly_app_name, fly_machine_id, hosting_provider FROM users')) {
      return { rows: [userFlyApp], rowCount: 1 };
    }
    if (sql.includes('INSERT INTO gateway_fly_app_ownership')) {
      return { rows: [{ fly_app_name: userFlyApp.fly_app_name }], rowCount: 1 };
    }
    if (sql.includes('SELECT fly_app_name FROM gateway_fly_app_ownership')) {
      return {
        rows: userFlyApp.fly_app_name ? [{ fly_app_name: userFlyApp.fly_app_name }] : [],
        rowCount: userFlyApp.fly_app_name ? 1 : 0,
      };
    }
    if (sql.includes('SELECT id, fly_app_name') && sql.includes('FROM gateway_pool')) {
      return {
        rows: retainedRows,
        rowCount: retainedRows.length,
      };
    }
    if (sql.includes('SELECT apple_auth_code')) {
      return { rows: appleAuthCode ? [{ apple_auth_code: appleAuthCode }] : [], rowCount: appleAuthCode ? 1 : 0 };
    }
    if (sql.includes('FROM gateway_pool_migrations')) {
      return { rows: interruptedRows, rowCount: interruptedRows.length };
    }
    if (sql.includes('pg_advisory_lock')) return { rows: [{}], rowCount: 1 };
    if (sql.includes('pg_advisory_unlock')) return { rows: [{ unlocked: true }], rowCount: 1 };
    return { rows: [], rowCount: 1 };
  });
  flyServiceMock.destroyApp.mockResolvedValue(undefined);
});

describe('account deletion retained gateway lifecycle', () => {
  it('refuses before opening a transaction when Fly mutations are disabled', async () => {
    envMock.gatewayMutationsDisabled = true;

    await expect(deleteUser('user-1')).rejects.toThrow('Account deletion is unavailable');

    expect(poolMock.connect).not.toHaveBeenCalled();
    expect(clientMock.query).not.toHaveBeenCalled();
    expect(flyServiceMock.destroyApp).not.toHaveBeenCalled();
  });

  it('keeps the migrated row when retained Fly app deletion fails', async () => {
    flyServiceMock.destroyApp.mockRejectedValue(new Error('Fly API 500: unavailable'));

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    const sqlCalls = clientMock.query.mock.calls.map(([sql]) => String(sql));
    expect(sqlCalls.filter((sql) => sql.includes('DELETE FROM gateway_pool'))).toEqual([]);
    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-pool-one');
  });

  it('retains durable canonical Fly ownership when remote deletion fails', async () => {
    userFlyApp = {
      fly_app_name: 'remclaw-user-canonical',
      fly_machine_id: 'machine-1',
      hosting_provider: 'fly',
    };
    retainedRows = [];
    flyServiceMock.destroyApp.mockRejectedValue(new Error('Fly API 500: unavailable'));

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    const sqlCalls = clientMock.query.mock.calls.map(([sql]) => String(sql));
    const ownershipInsert = sqlCalls.findIndex((sql) => sql.includes('INSERT INTO gateway_fly_app_ownership'));
    const userDelete = sqlCalls.findIndex((sql) => sql.includes('DELETE FROM users'));
    expect(ownershipInsert).toBeGreaterThan(-1);
    expect(ownershipInsert).toBeLessThan(userDelete);
    expect(sqlCalls.some((sql) => sql.includes('DELETE FROM gateway_fly_app_ownership'))).toBe(false);
    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-user-canonical');
  });

  it('removes durable canonical ownership only after Fly confirms deletion', async () => {
    userFlyApp = {
      fly_app_name: 'remclaw-user-canonical',
      fly_machine_id: 'machine-1',
      hosting_provider: 'fly',
    };
    retainedRows = [];

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    const ownershipDelete = clientMock.query.mock.calls.find(([sql]) =>
      String(sql).includes('DELETE FROM gateway_fly_app_ownership'));
    expect(ownershipDelete?.[1]).toEqual(['remclaw-user-canonical']);
    expect(clientMock.query.mock.invocationCallOrder[clientMock.query.mock.calls.indexOf(ownershipDelete!)])
      .toBeGreaterThan(flyServiceMock.destroyApp.mock.invocationCallOrder[0]);
  });

  it('releases lifecycle ownership before bounded Apple revocation', async () => {
    appleAuthCode = 'apple-auth-code';

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    expect(fetch).toHaveBeenCalledWith(
      'https://appleid.apple.com/auth/revoke',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    );
    expect(clientMock.end.mock.invocationCallOrder[0])
      .toBeLessThan(vi.mocked(fetch).mock.invocationCallOrder[0]);
  });

  it('removes the migrated row only after retained Fly app deletion succeeds', async () => {
    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    const cleanupIndex = clientMock.query.mock.calls.findIndex(([sql]) =>
      String(sql).includes('DELETE FROM gateway_pool'));
    const cleanupCall = clientMock.query.mock.calls[cleanupIndex];
    expect(cleanupCall?.[1]).toEqual(['remclaw-pool-one']);
    expect(clientMock.query.mock.invocationCallOrder[cleanupIndex])
      .toBeGreaterThan(flyServiceMock.destroyApp.mock.invocationCallOrder[0]);
  });

  it('destroys and removes an unconsumed claimed app after deleting its user', async () => {
    retainedRows = [{ id: 'pool-claim-1', fly_app_name: 'remclaw-pool-claimed', status: 'claimed' }];

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-pool-claimed');
    const retainedSelect = clientMock.query.mock.calls.find(([sql]) =>
      String(sql).includes("status IN ('claimed', 'migrated')"));
    expect(retainedSelect?.[1]).toEqual(['user-1']);
    const cleanup = clientMock.query.mock.calls.find(([sql]) =>
      String(sql).includes('DELETE FROM gateway_pool') && String(sql).includes("'claimed'"));
    expect(cleanup?.[1]).toEqual(['remclaw-pool-claimed']);
  });

  it('retains an interrupted checkpoint when either owned app deletion fails', async () => {
    interruptedRows = [{
      source_app_name: 'remclaw-pool-interrupted',
      target_app_name: 'remclaw-user-partial',
      target_ownership_state: 'owned',
    }];
    flyServiceMock.destroyApp.mockImplementation(async (appName: string) => {
      if (appName === 'remclaw-pool-interrupted') {
        throw new Error('Fly API 500: unavailable');
      }
    });

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    const checkpointDeletes = clientMock.query.mock.calls.filter(([sql]) =>
      String(sql).includes('DELETE FROM gateway_pool_migrations'));
    expect(checkpointDeletes).toEqual([]);
    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-user-partial');
  });

  it('removes an interrupted checkpoint only after both owned apps are deleted', async () => {
    interruptedRows = [{
      source_app_name: 'remclaw-pool-interrupted',
      target_app_name: 'remclaw-user-partial',
      target_ownership_state: 'owned',
    }];

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    const checkpointDelete = clientMock.query.mock.calls.find(([sql]) =>
      String(sql).includes('DELETE FROM gateway_pool_migrations'));
    expect(checkpointDelete?.[1]).toEqual([
      'user-1',
      'remclaw-pool-interrupted',
      'remclaw-user-partial',
    ]);
    expect(String(checkpointDelete?.[0])).toContain('DELETE FROM gateway_pool');
    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-pool-interrupted');
    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-user-partial');
  });

  it('preserves a disproven migration target while removing owned source cleanup', async () => {
    interruptedRows = [{
      source_app_name: 'remclaw-pool-interrupted',
      target_app_name: 'remclaw-collision',
      target_ownership_state: 'disproven',
    }];

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-pool-interrupted');
    expect(flyServiceMock.destroyApp).not.toHaveBeenCalledWith('remclaw-collision');
    expect(clientMock.query.mock.calls.some(([sql]) =>
      String(sql).includes('DELETE FROM gateway_pool_migrations'))).toBe(true);
  });

  it('retains an unclaimed checkpoint after deleting the known source', async () => {
    interruptedRows = [{
      source_app_name: 'remclaw-pool-interrupted',
      target_app_name: 'remclaw-ambiguous',
      target_ownership_state: 'unclaimed',
    }];

    await expect(deleteUser('user-1')).resolves.toBeUndefined();

    expect(flyServiceMock.destroyApp).toHaveBeenCalledWith('remclaw-pool-interrupted');
    expect(flyServiceMock.destroyApp).not.toHaveBeenCalledWith('remclaw-ambiguous');
    expect(clientMock.query.mock.calls.some(([sql]) =>
      String(sql).includes('DELETE FROM gateway_pool_migrations'))).toBe(false);
  });
});
