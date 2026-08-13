# RemClaw UI Developer Accessibility

This document maps the Wave 2 relaunch UI to editable SwiftUI files and Canvas
fixtures. The goal is to make design edits possible from Xcode without needing a
live account, Keychain state, or a running cloud gateway.

## Source Of Truth

- SwiftUI is the implementation source of truth.
- Xcode Canvas previews are the source of truth for implementation-state review.
- Figma is useful for alignment before building uncertain screens, but it should
  not replace previews for live gateway, authentication, or recovery states.
- Checkout and regression workflow belongs in `docs/WORKTREES.md`; use it before
  diagnosing missing folders, stale previews, or "this used to work" behavior.

## Preview Health Preflight

Run the preview health check before trusting Canvas, SwiftPM, or widget-cycle
errors:

```bash
./scripts/check-xcode-preview-health.sh
```

Xcode Canvas and SwiftPM still use the internal macOS data volume for temporary
files even when DerivedData is pointed at `/Volumes/SatechiSSD`. If the script
reports low internal disk space, free at least 15-20 GB, restart Xcode and
CoreSimulator, then run the script again before debugging UI code.

The script checks:

- internal temp volume free space
- `/Volumes/SatechiSSD` mount and external DerivedData writability
- `swiftc` discovery
- CoreSimulator availability
- SwiftPM package resolution once the environment preflight passes

## Gateway And Device Screens

Shared views are organized by product domain:

- `Shared/Views/Gateway/`
  contains gateway list/detail, deploy and repair flows, nearby discovery,
  setup-code entry, device connections, paired/current-device detail, and
  gateway screenshot fixtures.
- `Shared/Views/Settings/`
  contains the shared Settings root, About, delete-account confirmation, and
  settings fixtures/icons.
- `Shared/Views/Skills/`
  contains the Capabilities/Skills home, installed skills, ClawHub browse, and
  custom MCP server surfaces.
- `Shared/Views/Chat/` and `Shared/Views/OAuth/`
  keep their existing chat and connector ownership.

The old monolithic gateway file has been split by ownership:

- `Shared/Views/Gateway/SharedGatewayStatusHelpers.swift`
  owns gateway status copy, gateway setting-store helpers, resolver helpers, and
  shared status colors.
- `Shared/Views/Gateway/SharedOpenClawGatewayHomeView.swift`
  owns the gateway settings entrypoint.
- `Shared/Views/Gateway/SharedGatewayListView.swift`
  owns the list of configured gateway connections and the add-connection sheet.
- `Shared/Views/Gateway/SharedGatewayDetailView.swift`
  owns gateway detail, status, gateway setup rows, updates, and gateway actions.
- `Shared/Views/Gateway/SharedGatewayConnectionRecoveryView.swift`
  owns the focused connection recovery surface.
- `Shared/Views/Gateway/SharedGatewayRecoveryDestinationView.swift`
  routes launch/banner recovery into the existing gateway or device hierarchy.
- `Shared/Views/Gateway/SharedGatewayDeviceConnectionsView.swift`
  owns Device Connections list, current-device recovery, and the connection list
  modifiers.
- `Shared/Views/Gateway/SharedPendingDevicesView.swift`
  owns pending request rows and pending-device approval detail.
- `Shared/Views/Gateway/SharedLinkedDevicesView.swift`
  owns paired-device rows and paired-device detail.
- `Shared/Views/Gateway/SharedNearbyGatewaysView.swift`
  owns mDNS/Bonjour nearby gateway discovery states.
- `Shared/Views/Gateway/CloudGatewayDeploySheet.swift`
  owns cloud deploy, repair deploy, and post-deploy approval recovery.

Reuse existing screens before creating a new one:

- Pending approval belongs in the pending device detail screen.
- Current-device reset/re-pair belongs inside Device Connections.
- Gateway status and setup controls belong in Gateway Detail.
- Launch and global banners should route into those existing screens, not create
  duplicate recovery destinations.

## Preview Fixtures

Reusable DEBUG fixtures live in `Shared/PreviewSupport/`:

- `PreviewGatewaySession`
  is a fake `GatewaySessionProviding` object for Canvas and tests.
- `PreviewGatewayConfigs`
  creates cloud, local Mac, manual gateway configs, and fixture config stores.
- `PreviewDevices`
  creates pending and paired device records.
- `PreviewGatewayStates`
  defines named gateway scenarios such as connected, approval pending, cloud
  unreachable, local Mac unavailable, and device repair.
- `PreviewGatewayDiscovery`
  creates nearby-gateway discovery states without starting Bonjour or prompting
  for Local Network permission.

Use these fixtures for any view that depends on gateway state. Do not call live
gateway APIs, Keychain, or persisted user defaults from previews.

Colocate `#Preview` blocks with the view they preview whenever that file owns a
screen, stateful section, or drill-down destination. Central fixture routes such
as `SharedGatewayDetailFixtureView` remain useful for screenshots, but they are
not a substitute for previews in the editable source file.

## Preview Coverage

Current state previews cover:

- Gateway Detail:
  connected, cloud approval pending, checking approval, cloud unreachable,
  disconnected, update preflight, manual update, and refresh fallback.
- Gateway Home/List:
  empty, one cloud gateway, cloud plus local gateway, active cloud, inactive
  local, and backup-available list states.
- Device Connections:
  empty, pending request, paired devices, and current-device recovery.
- Pending Device Detail:
  idle, approving, declining, and action failed.
- Connection Recovery:
  cloud approval, cloud waking, cloud unreachable, and local Mac unavailable.
- Cloud Deploy:
  first deploy, repair deploy, and approval waiting.
- Nearby Gateways:
  empty, searching, one result, and permission denied.
- Gateway Disconnected Banner:
  cloud approval, cloud connecting, cloud unreachable, and local Mac unreachable.
- Onboarding:
  sign-in and deploy in light and dark modes.
- Privacy and NUX:
  privacy consent and post-setup education in light and dark modes.

## Design Enforcement Notes

- Prefer `.remPrimaryActionButton()` for full-width primary actions.
- Prefer `.remSettingsCTA(...)` for Settings/List section CTAs.
- Prefer `.remInlineRecoveryCTA(...)` for inline recovery/destructive actions.
- When a button is the main content of a section, remove default list edge
  insets so the button visually owns the row.
- If two UI components solve the same job, reuse or extend the existing
  component before adding another variant.

## Regression Traceability

When a previously working user path breaks, do not restart from a blank design
or fresh implementation attempt. First recover the last known-good state:

Start by confirming the active checkout with `docs/WORKTREES.md`. If Xcode is
open on the main `staging` checkout instead of `.worktrees/wave2-status-ui`, the
missing folders or previews may be a workspace-selection issue rather than a
product regression.

1. Identify the exact user route, for example "Settings -> Gateways -> Cloud
   Gateway -> Approve This Device" or "Chat History -> existing session".
2. Record the current branch, worktree path, simulator/device, gateway target,
   and account state before changing code.
3. Search existing evidence before editing:
   - `docs/screenshots/`
   - `docs/release/`
   - recent PR descriptions and review comments
   - colocated `#Preview` names
   - the relevant folder README
4. Name the last known-good evidence in the PR or commit notes.
5. Compare the files changed since that evidence before adding new UI. For
   navigation bugs, inspect route selection, view-model lifecycle, and persisted
   session keys before changing copy or layout.
6. After the fix, write down the new proof:
   - build command or focused test
   - simulator/browser route used for visual verification
   - screenshot path or runtime snapshot summary
   - whether the proof used a live gateway, fixture gateway, or preview fixture

If a fix depends on a live gateway state, add or update a fixture preview for the
same state when possible. A live fix without a fixture is easy to regress.

### Current Example: Existing Chat Reopened Empty

Symptom: selecting an existing chat from Chat History opened the right title but
rendered the empty first-chat state.

Cause: the session-route refactor recreated `OpenClawChatViewModel` after
`gateway.mainSessionKey` changed. Because the new view model already had the
selected key, the route task skipped `switchSession(to:)`, and nothing loaded
the transcript.

Fix pattern: view-model creation must load the selected session, and route entry
must load when the view model already has the requested key.

Regression proof to capture in future PRs: open Chat History, select a non-empty
session, and verify real transcript rows appear before claiming session
persistence is fixed.
