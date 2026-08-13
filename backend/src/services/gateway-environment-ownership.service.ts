import type { GatewayLifecycleDatabaseClient } from './gateway-lifecycle-lock.service.js';

export interface ManagedGatewayOwnershipExpectation {
  userId: string;
  backendUrl: string;
}

export type ManagedGatewayOwnershipMismatch =
  | 'missing_remclaw_user_id'
  | 'user_id_mismatch'
  | 'missing_backend_url'
  | 'backend_origin_mismatch';

export type ManagedGatewayOwnershipCheck =
  | {
      owned: true;
      userId: string;
      backendOrigin: string;
    }
  | {
      owned: false;
      mismatches: ManagedGatewayOwnershipMismatch[];
      actualUserId: string | null;
      actualBackendOrigin: string | null;
      expectedUserId: string;
      expectedBackendOrigin: string;
    };

function normalizedOrigin(raw: string): string | null {
  try {
    return new URL(raw.trim()).origin.toLowerCase();
  } catch {
    return null;
  }
}

/**
 * Fly's machine config is the external ownership record for a managed gateway.
 * Normal deploys stamp both values when the machine is created; a database pointer
 * alone is not proof that this backend environment owns the app or its volume.
 */
export function checkManagedGatewayOwnership(
  machineEnv: Record<string, string> | undefined,
  expected: ManagedGatewayOwnershipExpectation,
): ManagedGatewayOwnershipCheck {
  const expectedUserId = expected.userId.trim();
  const expectedBackendOrigin = normalizedOrigin(expected.backendUrl);
  if (!expectedUserId) throw new Error('expected managed gateway user id is empty');
  if (!expectedBackendOrigin) throw new Error('expected backend URL is invalid');

  const actualUserId = machineEnv?.REMCLAW_USER_ID?.trim() || null;
  const actualBackendOrigin = machineEnv?.BACKEND_URL
    ? normalizedOrigin(machineEnv.BACKEND_URL)
    : null;
  const mismatches: ManagedGatewayOwnershipMismatch[] = [];

  if (!actualUserId) mismatches.push('missing_remclaw_user_id');
  else if (actualUserId !== expectedUserId) mismatches.push('user_id_mismatch');

  if (!machineEnv?.BACKEND_URL?.trim() || !actualBackendOrigin) mismatches.push('missing_backend_url');
  else if (actualBackendOrigin !== expectedBackendOrigin) mismatches.push('backend_origin_mismatch');

  if (mismatches.length === 0) {
    return { owned: true, userId: expectedUserId, backendOrigin: expectedBackendOrigin };
  }
  return {
    owned: false,
    mismatches,
    actualUserId,
    actualBackendOrigin,
    expectedUserId,
    expectedBackendOrigin,
  };
}

export function assertManagedGatewayOwnership(
  machineEnv: Record<string, string> | undefined,
  expected: ManagedGatewayOwnershipExpectation,
): void {
  const result = checkManagedGatewayOwnership(machineEnv, expected);
  if (result.owned) return;
  throw new Error(
    `target Fly machine is not owned by this backend user/environment (${result.mismatches.join(', ')})`,
  );
}

export interface StoredManagedGatewayPointer {
  userId: string;
  gatewayUrl: string;
  flyAppName: string;
  flyMachineId: string;
}

export type GatewayPointerRepairOutcome =
  | { state: 'owned' }
  | { state: 'mismatch_dry_run'; mismatches: ManagedGatewayOwnershipMismatch[] }
  | { state: 'released'; mismatches: ManagedGatewayOwnershipMismatch[] };

/**
 * Release only the exact pointer that was inspected. The WHERE clause makes a
 * concurrent repoint/deploy win rather than allowing this repair to erase newer state.
 * No Fly app, volume, gateway secret, or Composio grant is copied or destroyed.
 */
export async function clearCrossEnvironmentGatewayPointer(
  client: GatewayLifecycleDatabaseClient,
  pointer: StoredManagedGatewayPointer,
): Promise<void> {
  const result = await client.query(
    `UPDATE users
        SET gateway_url = NULL,
            gateway_token_encrypted = NULL,
            fly_app_name = NULL,
            fly_machine_id = NULL,
            fly_volume_id = NULL
      WHERE id = $1::uuid
        AND gateway_url = $2
        AND fly_app_name = $3
        AND fly_machine_id = $4
      RETURNING id`,
    [pointer.userId, pointer.gatewayUrl, pointer.flyAppName, pointer.flyMachineId],
  );
  if (result.rows.length !== 1) {
    throw new Error('gateway pointer changed after inspection; refusing to clear newer state');
  }
}

export async function repairCrossEnvironmentGatewayPointer(
  client: GatewayLifecycleDatabaseClient,
  options: {
    pointer: StoredManagedGatewayPointer;
    machineEnv: Record<string, string> | undefined;
    expected: ManagedGatewayOwnershipExpectation;
    apply: boolean;
  },
): Promise<GatewayPointerRepairOutcome> {
  const ownership = checkManagedGatewayOwnership(options.machineEnv, options.expected);
  if (ownership.owned) return { state: 'owned' };

  const provenMismatch = ownership.mismatches.includes('user_id_mismatch')
    || ownership.mismatches.includes('backend_origin_mismatch');
  if (!provenMismatch) {
    throw new Error(
      `gateway ownership is unverifiable (${ownership.mismatches.join(', ')}); refusing automatic repair`,
    );
  }
  if (!options.apply) {
    return { state: 'mismatch_dry_run', mismatches: ownership.mismatches };
  }

  await clearCrossEnvironmentGatewayPointer(client, options.pointer);
  return { state: 'released', mismatches: ownership.mismatches };
}
