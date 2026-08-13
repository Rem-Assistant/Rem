# Hosted gateway provisioning — the open-core boundary

This directory is the seam between the **open-core product code** (shipped in this
public seed) and the **hosted-orchestration implementation** (kept private).

## What lives here

- **`hosted-provisioning.ts`** — the interface `HostedGatewayProvisioning`, the
  provider-agnostic `HostedMachine` type, a `NotImplemented` default provider, and
  the `getHostedGatewayProvisioning()` / `setHostedGatewayProvisioning()` accessors.

## The contract

Open-core product code needs exactly four hosted operations:

| Purpose   | Method                                    | Called by |
|-----------|-------------------------------------------|-----------|
| lookup    | `getMachine(app, machine, opts?)`         | `gateway.service` (wake, setup-password read), `managed-talk-configuration.service` (inspect target) |
| wake      | `startMachine(app, machine, opts?)`       | `gateway.service` (wake) |
| wake      | `waitForMachineReady(app, machine, secs)` | `gateway.service` (finish wake) |
| teardown  | `destroyApp(app)`                         | `auth.service` (account deletion) |

Product code calls `getHostedGatewayProvisioning()` and uses the returned provider.
It never imports a concrete host (Fly, etc.) directly.

## What is NOT here (the private moat)

The concrete implementation — provisioning per-user machines on a cloud host,
volumes/snapshots, exec, the pre-warmed pool, image rollout — lives in the private
repo. It implements `HostedGatewayProvisioning` (plus whatever larger surface it
needs internally) and registers itself once at boot:

```ts
import { setHostedGatewayProvisioning } from './services/gateway/hosted-provisioning.js';
import { flyHostedProvisioning } from '@private/hosted'; // not in this repo
setHostedGatewayProvisioning(flyHostedProvisioning);
```

## What the public seed can do without it

- Build and typecheck (`tsc --noEmit`) and run.
- Run a **self-hosted / local gateway**: those code paths short-circuit before
  reaching hosted provisioning (they gate on `hosting_provider === 'fly'`), so a
  local single-gateway setup never calls into this interface.

## What it can't do without it

- **Cloud-managed gateways** (wake a suspended machine, inspect a managed-talk
  target, tear a Fly app down on account deletion). With no provider registered,
  the default throws `HostedProvisioningNotImplementedError` with a message
  pointing here — a loud, actionable failure rather than a silent one. Bring your
  own implementation, or stay self-hosted.
