# Gateway Update Flow

This note is the product and engineering contract for issue
[#631](https://github.com/Rem-Assistant/RemClaw/issues/631). It defines how Rem
should safely move a user's existing gateway to a newer approved runtime when a
feature needs a capability the gateway does not yet support.

## Decision

Treat **Update Gateway** as an in-place upgrade of the user's existing gateway
identity and data. It must never silently create a replacement gateway.

Expose automatic updates only for Rem-managed cloud gateways where Rem can
verify the target, take a backup or snapshot, restart the same gateway, and run
health checks. For Mac-local, self-managed, or unknown gateways, show manual
instructions and preserve the gateway record.

Use the word **Update** only when the existing gateway will be preserved. Use
separate actions for reconnect, re-pair, repair, deploy, and replace.

## Vocabulary

| Action | Meaning | Data boundary |
| --- | --- | --- |
| Reconnect | Try the same URL/token again. | No state mutation. |
| Re-pair | Mint or approve a device token for the same gateway. | Gateway and workspace stay unchanged. |
| Repair | Recover a broken managed gateway deployment in place. | Same Fly app/volume; no new gateway unless user explicitly chooses replace. |
| Update | Move the existing gateway to an approved runtime/version. | Same gateway identity, URL, workspace, chats, credentials, and volume data. |
| Deploy | Create a gateway when the user does not have one. | New gateway identity. |
| Replace | Intentionally abandon one gateway and create/use another. | Destructive or migratory; requires explicit confirmation and backup/export path. |

## Supported Update Targets

The app should not let users enter arbitrary commits, container images, or
OpenClaw revisions. Allowed targets should come from a Rem-controlled manifest
or backend response:

```json
{
  "channel": "stable",
  "gatewayKind": "fly-managed",
  "currentVersion": "2026.05.13",
  "targetVersion": "2026.05.14",
  "requiredCapabilities": ["skills.search"],
  "image": "registry.fly.io/remclaw-gateway:2026.05.14",
  "openclawRevision": "approved-sha",
  "minimumBackendApi": "2026.05.14"
}
```

The manifest must be treated as an allowlist, not a suggestion. If the active
gateway does not match the target's `gatewayKind`, current channel, or required
preflight shape, the app should show `Manual update required` instead of trying
to mutate it.

## Preflight

Before showing an enabled `Update Gateway` button, the app or backend must know:

- Gateway kind: managed Fly, Mac-local, self-managed URL, or unknown.
- Stable identity: existing Fly app name or canonical gateway ID.
- Current reachable URL and backend-owned gateway record.
- Current runtime/version and advertised capabilities when available.
- Required missing capability, such as `skills.search`.
- Backup/snapshot availability for the current gateway data volume.
- Config health: auth profile, workspace path, provider credentials, device
  trust, and disk/volume availability.
- Rollback target or recovery path.

If any preflight item is unknown for a managed cloud gateway, the CTA should
remain disabled with a specific explanation. If the gateway is not Rem-managed,
the CTA should become a manual guidance path.

## Update State Machine

```text
missing capability
  -> checking update
  -> update available
  -> preflight running
  -> backup/snapshot running
  -> applying update
  -> restarting gateway
  -> health checks running
  -> connected and capability verified
```

Failure states:

```text
preflight failed
backup failed
update failed
restart failed
health check failed
rollback running
rollback complete
manual recovery needed
```

The app should keep these states visible in Gateway Detail and in the blocked
feature surface that triggered the update. A user should be able to tell whether
Rem is checking, backing up, applying, reconnecting, or asking for manual help.

## Health Checks

An update is complete only after Rem verifies the gateway can still do the
minimum useful work:

- Auth/session check succeeds.
- Chat send or health endpoint succeeds.
- Session history is readable.
- Device pairing/trust state is still valid or recoverable.
- The required capability now works, e.g. `skills.search`.
- Gateway identity, URL, and selected gateway record did not change.

If the required capability still fails, the app should keep the missing
capability surface open and attach the health-check failure to update details.

## Rollback And Recovery

Managed cloud updates must have one of these before the app enables update:

- Volume snapshot plus previous image/revision.
- Verified backup/export plus restore procedure.
- Backend-managed rollback to the prior approved target.

If rollback succeeds, the app should say the gateway was restored and keep the
original missing capability guidance. If rollback fails, the app should preserve
the gateway record, show manual recovery details, and avoid offering deploy as
the primary action.

## UI Surfaces

### Skills Browse

When `skills.search` is missing:

- Main copy: `Skill browsing needs a gateway update.`
- Primary safe action when preflight allows it: `Update Gateway`.
- Secondary action: `View Gateway Options`.
- Manual/self-managed copy: `This gateway needs to be updated outside Rem.`

### Gateway Detail

Add an Update section only when update state is known:

- Current version or `Version unknown`.
- Update availability.
- Backup/snapshot readiness.
- Last update attempt and result.
- Health-check result for required capabilities.

### Chat Recovery

If the assistant hits a missing gateway method, keep the chat answer clean and
offer a gateway update detail card or deep link rather than dumping RPC errors
inline.

## Non-Goals For The First App Slice

- No arbitrary image/commit picker.
- No automatic update for self-managed URLs.
- No update button that creates a new Fly app.
- No hidden fallback from Mac-local work to cloud when the requested capability
  needs Mac-local state.
- No destructive replace flow without a separate migration/export design.

## Implementation Order

1. Add backend/update capability metadata and approved target manifest.
2. Add read-only update status to Gateway Detail.
3. Add managed-cloud preflight endpoint.
4. Add backup/snapshot creation.
5. Add update apply and restart health checks.
6. Add rollback/recovery path.
7. Enable `Update Gateway` from blocked feature surfaces.
8. Add visual fixtures for update available, updating, health-check failed,
   rollback complete, and manual update required.

## Relationship To Capabilities IA

Gateway update is a runtime-readiness action. It belongs with Gateways and
blocked capability surfaces, not as a root Connector concept. Connectors should
explain what Rem can use; Gateway Update explains why the selected runtime is
not yet capable of executing a needed action.
