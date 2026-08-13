import { describe, expect, it, vi } from 'vitest';
import {
  assertManagedGatewayOwnership,
  checkManagedGatewayOwnership,
  clearCrossEnvironmentGatewayPointer,
  repairCrossEnvironmentGatewayPointer,
} from './gateway-environment-ownership.service.js';

const expected = {
  userId: 'staging-user-id',
  backendUrl: 'https://staging.rem.example/api/v1',
};

describe('managed gateway environment ownership', () => {
  it('accepts the user and backend origin stamped by normal managed deploys', () => {
    expect(checkManagedGatewayOwnership({
      REMCLAW_USER_ID: 'staging-user-id',
      BACKEND_URL: 'https://staging.rem.example/',
    }, expected)).toEqual({
      owned: true,
      userId: 'staging-user-id',
      backendOrigin: 'https://staging.rem.example',
    });
  });

  it('rejects a gateway owned by the same person in another backend environment', () => {
    const result = checkManagedGatewayOwnership({
      REMCLAW_USER_ID: 'production-user-id',
      BACKEND_URL: 'https://api.rem.example',
    }, expected);

    expect(result).toMatchObject({
      owned: false,
      mismatches: ['user_id_mismatch', 'backend_origin_mismatch'],
      actualUserId: 'production-user-id',
      actualBackendOrigin: 'https://api.rem.example',
    });
    expect(() => assertManagedGatewayOwnership({
      REMCLAW_USER_ID: 'production-user-id',
      BACKEND_URL: 'https://api.rem.example',
    }, expected)).toThrow('user_id_mismatch, backend_origin_mismatch');
  });

  it('fails closed for legacy machines without ownership stamps', () => {
    expect(checkManagedGatewayOwnership({}, expected)).toMatchObject({
      owned: false,
      mismatches: ['missing_remclaw_user_id', 'missing_backend_url'],
    });
  });

  it('clears only the exact pointer that was inspected', async () => {
    const client = {
      query: vi.fn().mockResolvedValue({ rows: [{ id: 'staging-user-id' }] }),
    };
    await clearCrossEnvironmentGatewayPointer(client as never, {
      userId: 'staging-user-id',
      gatewayUrl: 'https://remclaw-production.fly.dev',
      flyAppName: 'remclaw-production',
      flyMachineId: 'machine-production',
    });

    expect(client.query).toHaveBeenCalledWith(
      expect.stringContaining('AND fly_machine_id = $4'),
      [
        'staging-user-id',
        'https://remclaw-production.fly.dev',
        'remclaw-production',
        'machine-production',
      ],
    );
  });

  it('refuses to erase a newer concurrent gateway assignment', async () => {
    const client = { query: vi.fn().mockResolvedValue({ rows: [] }) };
    await expect(clearCrossEnvironmentGatewayPointer(client as never, {
      userId: 'staging-user-id',
      gatewayUrl: 'https://old.fly.dev',
      flyAppName: 'old',
      flyMachineId: 'old-machine',
    })).rejects.toThrow('gateway pointer changed after inspection');
  });

  it('keeps a proven mismatch read-only until apply is explicit', async () => {
    const client = { query: vi.fn() };
    await expect(repairCrossEnvironmentGatewayPointer(client as never, {
      pointer: {
        userId: 'staging-user-id',
        gatewayUrl: 'https://prod.fly.dev',
        flyAppName: 'prod',
        flyMachineId: 'prod-machine',
      },
      machineEnv: {
        REMCLAW_USER_ID: 'production-user-id',
        BACKEND_URL: 'https://api.rem.example',
      },
      expected,
      apply: false,
    })).resolves.toMatchObject({
      state: 'mismatch_dry_run',
      mismatches: ['user_id_mismatch', 'backend_origin_mismatch'],
    });
    expect(client.query).not.toHaveBeenCalled();
  });

  it('releases a proven mismatch only in apply mode', async () => {
    const client = { query: vi.fn().mockResolvedValue({ rows: [{ id: 'staging-user-id' }] }) };
    await expect(repairCrossEnvironmentGatewayPointer(client as never, {
      pointer: {
        userId: 'staging-user-id',
        gatewayUrl: 'https://prod.fly.dev',
        flyAppName: 'prod',
        flyMachineId: 'prod-machine',
      },
      machineEnv: {
        REMCLAW_USER_ID: 'production-user-id',
        BACKEND_URL: 'https://api.rem.example',
      },
      expected,
      apply: true,
    })).resolves.toMatchObject({ state: 'released' });
    expect(client.query).toHaveBeenCalledOnce();
  });

  it('does not automatically release an unstamped legacy machine', async () => {
    const client = { query: vi.fn() };
    await expect(repairCrossEnvironmentGatewayPointer(client as never, {
      pointer: {
        userId: 'staging-user-id',
        gatewayUrl: 'https://legacy.fly.dev',
        flyAppName: 'legacy',
        flyMachineId: 'legacy-machine',
      },
      machineEnv: {},
      expected,
      apply: true,
    })).rejects.toThrow('ownership is unverifiable');
    expect(client.query).not.toHaveBeenCalled();
  });
});
