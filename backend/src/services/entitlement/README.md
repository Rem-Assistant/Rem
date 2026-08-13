# Entitlement provider — the open-core boundary

This directory is the seam between the **open-core product code** (shipped in this
public seed) and the **subscription/billing implementation** (kept private). It
mirrors `../gateway/hosted-provisioning.ts` exactly.

## What lives here

- **`entitlement-provider.ts`** — the `EntitlementProvider` interface, the minimal
  `EntitlementSnapshot` type product code reads, a fully-entitled default provider,
  and the `getEntitlementProvider()` / `setEntitlementProvider()` accessors.

## The contract

Open-core product code needs exactly one entitlement fact:

| Purpose | Method                                     | Called by |
|---------|--------------------------------------------|-----------|
| read    | `getCanonicalEntitlement(client, userId)`  | `managed-talk-configuration.service` (gates the backend-owned Voice credential on `isActive`) |

Product code calls `getEntitlementProvider()` and reads only `snapshot.isActive`.
It never imports a concrete billing backend (Apple IAP, etc.) directly.

## What is NOT here (the private moat)

The concrete implementation — Apple IAP identity, `apple_subscription_chains`,
App Store Server notifications, the product SKU, and the entitlement-status math —
lives in the private repo. It implements `EntitlementProvider` (over whatever
larger internal surface it needs) and registers itself once at boot:

```ts
import { setEntitlementProvider } from './services/entitlement/entitlement-provider.js';
import { iapEntitlementProvider } from '@private/billing'; // not in this repo
setEntitlementProvider(iapEntitlementProvider);
```

## What the public seed does without it

With no provider registered, the default returns `{ isActive: true }` for every
account: self-hosters and open-source users are not subscription-gated, so managed
features work out of the box. Bring your own billing backend by registering a
provider, or stay fully entitled.
