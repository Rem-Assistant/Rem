/**
 * Entitlement provider — the interface boundary between the open-core product
 * code and the (private) subscription/billing implementation.
 *
 * The public seed ships the RECIPE: this interface plus the product code that
 * calls it. Managed-Talk reconciliation gates the backend-owned Voice credential
 * on whether the account holds an active entitlement — that gate is all product
 * code needs to know. It does NOT ship the concrete billing implementation —
 * Apple IAP identity, subscription chains, App Store Server notifications, the
 * product SKU, and the entitlement-status math — which lives in the private repo
 * and is registered at boot via {@link setEntitlementProvider}.
 *
 * With no implementation registered, the default provider returns a FULL, active
 * entitlement: self-hosters and open-source users are not subscription-gated, so
 * the app works out of the box (no throw). The private repo registers the real
 * IAP-backed provider, mirroring `setHostedGatewayProvisioning`
 * (../gateway/hosted-provisioning.ts), the sibling open-core boundary this file
 * is modelled on.
 *
 * See ./README.md for the full boundary contract.
 */

import type { PoolClient } from 'pg';

/**
 * The minimal entitlement fact open-core product code depends on.
 *
 * The private IAP implementation computes far more internally (plan, status,
 * product id, expiry, originating transaction chain, environment); only
 * `isActive` crosses the open-core boundary, so that is all this type carries.
 */
export interface EntitlementSnapshot {
  /** Whether the account currently holds an active entitlement to managed features. */
  isActive: boolean;
}

/**
 * Database client an entitlement read may run on. Product code threads its
 * existing transaction or lifecycle-lock session through so the read stays on
 * the same bounded session as the mutations it guards.
 */
export type EntitlementDatabaseClient = Pick<PoolClient, 'query'>;

/** The surface of entitlement lookups open-core product code depends on. */
export interface EntitlementProvider {
  /**
   * Read the canonical entitlement for a user on a caller-supplied client, so the
   * read can stay on an existing transaction or lifecycle-lock session.
   */
  getCanonicalEntitlement(
    client: EntitlementDatabaseClient,
    userId: string,
  ): Promise<EntitlementSnapshot>;
}

/**
 * Default provider: every account is fully entitled. Keeps the public seed
 * runnable out of the box — self-hosters and open-source users are not
 * subscription-gated, so managed features stay available without any billing
 * backend registered.
 */
export const fullyEntitledProvider: EntitlementProvider = {
  async getCanonicalEntitlement(): Promise<EntitlementSnapshot> {
    return { isActive: true };
  },
};

let activeProvider: EntitlementProvider = fullyEntitledProvider;

/**
 * Register the concrete entitlement implementation. The private repo calls this
 * once at boot; tests use it (or a module mock) to inject fakes.
 */
export function setEntitlementProvider(provider: EntitlementProvider): void {
  activeProvider = provider;
}

/** Reset back to the fully-entitled default (primarily for tests). */
export function resetEntitlementProvider(): void {
  activeProvider = fullyEntitledProvider;
}

/** The active entitlement provider. Product code calls this. */
export function getEntitlementProvider(): EntitlementProvider {
  return activeProvider;
}
