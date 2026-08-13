/**
 * Hosted gateway provisioning — the interface boundary between the open-core
 * product code and the (private) hosted-orchestration implementation.
 *
 * The public seed ships the RECIPE: this interface plus the product code that
 * calls it (gateway wake, managed-talk inspection, account-deletion teardown).
 * It does NOT ship the concrete hosted implementation — spinning up per-user
 * machines on a cloud host, reading/starting/destroying them — which lives in
 * the private repo and is registered at boot via {@link setHostedGatewayProvisioning}.
 *
 * With no implementation registered, the default provider throws
 * {@link HostedProvisioningNotImplementedError} so a self-hoster gets a clear,
 * actionable message instead of a mysterious crash. Self-hosters who run a
 * single local gateway never hit these paths (they short-circuit earlier on
 * `hosting_provider !== 'fly'`); they only fire for cloud-managed gateways.
 *
 * See ./README.md for the full boundary contract.
 */

/** A hosted compute instance backing one user's gateway (provider-agnostic shape). */
export interface HostedMachine {
  id: string;
  name: string;
  state: string;
  region: string;
  config?: {
    image?: string;
    env?: Record<string, string>;
    [key: string]: unknown;
  };
}

/** Options threaded through to the hosted provider for a single call. */
export interface HostedMachineCallOptions {
  signal?: AbortSignal;
}

/**
 * The surface of hosted provisioning that open-core product code depends on.
 *
 * - lookup:    {@link getMachine}
 * - wake/start:{@link startMachine} + {@link waitForMachineReady}
 * - teardown:  {@link destroyApp}
 *
 * The private implementation may expose a far larger surface (app/volume/
 * machine create, exec, snapshots, pool management); only these four methods
 * are part of the open-core contract.
 */
export interface HostedGatewayProvisioning {
  /** Read the current state/config of a hosted machine. */
  getMachine(
    appName: string,
    machineId: string,
    options?: HostedMachineCallOptions,
  ): Promise<HostedMachine>;

  /** Start (wake) a stopped/suspended hosted machine. */
  startMachine(
    appName: string,
    machineId: string,
    options?: HostedMachineCallOptions,
  ): Promise<void>;

  /** Block until the machine reports a ready state, or the timeout elapses. */
  waitForMachineReady(
    appName: string,
    machineId: string,
    timeoutSeconds: number,
  ): Promise<HostedMachine>;

  /** Permanently destroy the hosted app (used on account deletion). */
  destroyApp(appName: string): Promise<void>;
}

/** Thrown when hosted provisioning is invoked but no implementation is registered. */
export class HostedProvisioningNotImplementedError extends Error {
  constructor(operation: string) {
    super(
      `Hosted gateway provisioning ("${operation}") is not available in the open-core seed. ` +
        'The hosted implementation lives in the private repo — bring your own by calling ' +
        'setHostedGatewayProvisioning() at boot, or run a self-hosted local gateway instead.',
    );
    this.name = 'HostedProvisioningNotImplementedError';
  }
}

/**
 * Default provider: degrades gracefully by throwing a clear error on every
 * hosted operation. Keeps the public seed compiling and runnable — cloud-only
 * paths fail loudly with guidance instead of silently misbehaving.
 */
export const notImplementedHostedProvisioning: HostedGatewayProvisioning = {
  getMachine() {
    throw new HostedProvisioningNotImplementedError('getMachine');
  },
  startMachine() {
    throw new HostedProvisioningNotImplementedError('startMachine');
  },
  waitForMachineReady() {
    throw new HostedProvisioningNotImplementedError('waitForMachineReady');
  },
  destroyApp() {
    throw new HostedProvisioningNotImplementedError('destroyApp');
  },
};

let activeProvider: HostedGatewayProvisioning = notImplementedHostedProvisioning;

/**
 * Register the concrete hosted-provisioning implementation. The private repo
 * calls this once at boot; tests use it (or a module mock) to inject fakes.
 */
export function setHostedGatewayProvisioning(provider: HostedGatewayProvisioning): void {
  activeProvider = provider;
}

/** Reset back to the not-implemented default (primarily for tests). */
export function resetHostedGatewayProvisioning(): void {
  activeProvider = notImplementedHostedProvisioning;
}

/** The active hosted-provisioning provider. Product code calls this. */
export function getHostedGatewayProvisioning(): HostedGatewayProvisioning {
  return activeProvider;
}
