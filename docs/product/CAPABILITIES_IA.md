# Connectors, Capabilities, Skills, MCP, and Gateways

This note is the product IA decision for issue
[#530](https://github.com/Rem-Assistant/RemClaw/issues/530). It turns the
broader direction in [VISION.md](VISION.md) into rules agents can use when
slicing Settings, gateway detail, and integration work.

For trust boundaries, approval rules, and security posture, see
[SECURITY_MODEL.md](SECURITY_MODEL.md).
For Mac-local capability scopes and action logs, see
[MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md). For the in-app session
preview boundary, see
[SESSION_PREVIEW_CONTRACT.md](SESSION_PREVIEW_CONTRACT.md).

## Decision

Use **Connectors** as the primary user-facing integration surface.

Use **Capabilities** as the product model for what Rem can do once something is
connected or available. Capabilities are useful in detail views, permission copy,
logs, and agent planning, but they should not replace Connectors as the root
Settings label.

Keep **Gateways / Private Machines** separate. Private Machines are where work
runs and which devices or runtimes can execute it. They are not the same as an
integration account. In Wave 2 user-facing surfaces should prefer "Machine" or
"Private Machine" when describing where AI runs, while code and advanced docs
may still use "gateway" for the implementation object.

Keep **Skills** and **MCP** as implementation/setup surfaces. Show them when a
user needs to understand readiness or advanced customization, but do not make
normal users learn those concepts before they can connect Calendar, Gmail,
Notion, Files, browser, or Mac capabilities.

## Vocabulary

| Term | User question | Product role | Scope |
|------|---------------|--------------|-------|
| Connector | What can Rem use for me? | User-friendly integration or local capability surface. | Usually account-level, sometimes device-backed. |
| Capability | What can Rem do with this? | A permissioned action/context Rem can plan around. | Account, gateway, or device depending on implementation. |
| Private Machine / Gateway | Where does Rem run this work? | Runtime, routing, pairing, reachability, and health. | Gateway-scoped. |
| Device | Which phone or Mac can perform this? | Node that advertises local capabilities. | Gateway-scoped and user-owned. |
| Skill | Which OpenClaw tool bundle enables this? | OpenClaw-managed implementation package and readiness state. | Gateway-scoped today. |
| MCP server | Which custom tool server is configured? | Advanced/custom tool substrate. | Gateway-scoped today. |
| Connected Account | Which external account did the user authorize? | Identity/token relationship used by one or more Connectors. | User/account-level, stored via gateway-canonical config where needed. |
| Binary/tool requirement | What needs installing? | Setup/readiness detail for a Skill or MCP-backed Connector. | Device or gateway scoped. |

## Current State

- Root Settings shows `Connectors` through `SharedComposioConnectionsView`
  (Composio-hosted connect: redirect link + status poll), replacing the
  in-app `OAuthClient` + `SharedConnectedAccountsView` surface.
- `Connectors` lists Composio toolkits (Gmail, Google Calendar, GitHub first).
- Machine detail shows `Machine Connections`, `Skills`, and `Custom MCP Servers`
  under `Configuration`.
- Skills use upstream `skills.status`, `skills.search`, `skills.detail`, and
  `skills.update` through the active gateway.
- MCP server management reads and patches gateway config under `mcp.servers`.
- Connected Account tokens are gateway-canonical with local Keychain as a warm
  cache; see [Shared/Services/OAuth/README.md](../../Shared/Services/OAuth/README.md).

That current split is technically honest but product-heavy. It exposes
implementation objects in three places before the user has a clear mental model.

## Target Hierarchy

```text
Settings
  Account
    Profile
    Billing & Usage
    Sign-in & identity
  Connectors
    Calendar
      Source: This Device
      Capabilities: read events, create events, reschedule
    Google (umbrella auth model)
      Providers: Google OAuth
      Capabilities: Gmail, Calendar, Drive, Docs, Sheets, Slides
    Gmail (first-wave visible provider row)
      Providers: Google OAuth
      Capabilities: search mail, draft replies, summarize threads
    Notion
      Providers: Notion OAuth
      Capabilities: search pages, create notes, update tasks
    Mac
      Sources: already-paired Mac devices
      Capabilities: files, clipboard, shell, screen/app context
      Pairing/trust: deep-link to Machines > Machine Connections
    Files / Browser / GitHub / Linear / Slack / ...
    Advanced
      Custom MCP Servers
      Skill readiness
  Machines
    Cloud machine
    Mac machine
    Machine connections
    Reachability and repair
    Runtime health and logs
  Permissions & Privacy
    Device permissions
    Connector permission summaries
    Future: capability scopes
    Future: audit/log controls
```

The important product move: root Settings should teach "connect useful things";
gateway detail should teach "this runtime is healthy and can reach these
devices/tools"; advanced setup should explain Skills/MCP only when needed.
OAuth/provider accounts for integrations belong inside Connector detail screens.
Keep `Connected Account` as a data/implementation term unless the product needs
an account-identity screen that is clearly separate from integrations.

## Scope Rules

- **Account-level Connector**: external service authorization or cloud service
  state that should follow the user across devices. Examples: Gmail, Notion,
  GitHub, Linear, Google Calendar OAuth.
- **Device-level Connector**: local permission or local context only available
  on a specific device. Examples: iOS Calendar via EventKit, Mac Files, Mac
  Clipboard, screen/app context.
- **Gateway-level setup**: runtime configuration required for the active
  gateway to execute a capability. Examples: installed OpenClaw Skill, MCP
  server entry, missing binary, gateway auth profile, tool health.
- **Permission-level state**: user approval for a device or capability scope.
  Examples: Calendar permission, shell approval, file write scope, screen
  inspection approval.

If a feature crosses scopes, show the user-facing Connector first and nest the
scope explanation in detail:

```text
Calendar
  This Device: Connected
Google
  Calendar capability: Not Connected
  Gateway readiness: ready for scheduling tools when local or provider context exists
```

## Gateway Capability Matrix

Cloud gateway fallback is useful only when the work is cloud-capable. It should
not be described as a backup Mac, because it cannot replace Mac-local shell,
files, clipboard, screen/app context, browser state, or local project state
while the Mac node is offline.

| Capability / workflow | Mac gateway | Cloud gateway | Product rule |
|-----------------------|-------------|---------------|--------------|
| Chat continuity and gateway-hosted workspace state | Yes | Yes | Route to whichever selected gateway is healthy. Show which gateway is active. |
| Backend-owned tasks, agenda sync, and account data | Yes | Yes | Cloud can keep these reachable when the Mac is offline if backend/account state is available. |
| Remote MCP / provider-backed Connectors | Yes, if configured | Yes, if configured | Treat as cloud-capable only when auth and server reachability are confirmed. |
| OpenClaw Skills that only need cloud-safe tools | Yes | Yes, if installed | Show missing skill, binary, or auth requirements on the active gateway. |
| Calendar through local EventKit | Yes on the device that has permission | No | Keep this in the native Calendar connector as device-local access; provider calendars route through Provider Connectors such as Google. |
| Mac shell, local files, clipboard, screen/app context | Yes, when the Mac node is paired and reachable | No | Never silently fall back to cloud. Explain that Mac is required for local computer actions. |
| Browser/app automation on the user's Mac | Yes, when explicitly approved | No | Gate behind Mac permissions and audit UX before presenting as a finished Connector. |
| Wake or reconnect a sleeping Mac | Yes, as a reachability tactic | No direct local control | Cloud can explain or coordinate retry state, but Wake-on-LAN/tailnet/manual routing still owns reachability. |
| Backup/restore of gateway state | Yes for local gateway state | Yes for managed gateway volume state | Keep backup scope explicit: gateway config/state is not the same as copying a user's Mac. |
| Managed cloud repair/redeploy | Not applicable | Yes | Repair the canonical managed cloud gateway; do not create multiple managed gateways unless #480 changes direction. |

Fallback routing should start as user-visible and conservative:

1. Prefer the user's selected healthy gateway.
2. If the selected Mac gateway is offline, offer cloud only for capabilities in
   the cloud-capable rows above.
3. If the request needs Mac-local context, say the Mac is required and offer
   reachability actions such as reconnect, wake, setup code, LAN, tailnet, or
   manual URL.
4. Do not implement automatic cloud failover until the approval model, audit
   logs, and connector/account state ownership are explicit.

### Cloud Machine Tool Installation And Mac-Local Capabilities

Wave 2 should treat cloud machine setup as **capability readiness**, not as a
general-purpose package manager. If an OpenClaw Skill declares a safe manifest
installer for a missing binary, Rem can show `Not installed` with an
`Install on Machine` action and run it through OpenClaw's `skills.install`
safety path. This is realistic for declared installer kinds such as `brew`,
`node`, `uv`, `go`, or `download`, but the UI should still describe the action
as installing a requirement for the active machine and re-checking readiness
afterward.

If a requirement is macOS-only, show `Requires macOS` or `Needs Mac` instead of
offering cloud installation. Streaming a user's Mac-local files, clipboard,
screen/app context, browser session, or shell into a cloud machine is a
separate Mac Connector capability lane. It needs the approval and action-log
model in [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md) before it can be
presented as an available cloud-machine fallback.

Chat can route setup when the user is already trying to complete a task:
"This needs `remindctl` on your private machine. Install it now?" That chat CTA
should deep-link to the same Skill/Connector setup sheet rather than inventing
a second install flow. For Wave 2, use:

- `Installed`: requirements are satisfied on the active machine.
- `Not installed`: a declared installer or connector/setup action exists.
- `Requires macOS` / `Needs Mac`: the capability depends on Mac-local APIs or
  macOS-only tools and should not be offered on a cloud machine.
- `Unavailable`: the product has not designed the approval/logging model yet.

Non-goals for this pass: arbitrary `brew install` or `go install` from chat,
persisting ad-hoc packages outside OpenClaw's installer model, automatic
cloud-to-Mac capability streaming, and treating a cloud machine as a replacement
for a paired Mac.

## Implementation Guidance

1. Keep `Connectors` as the root Settings row.
2. Do not add a root `Capabilities` row yet. It is too abstract for normal users.
3. Move common integration setup toward Connector detail screens over time.
4. Keep `Custom MCP Servers` available, but nest it under `Connectors >
   Advanced` or retain it in gateway detail only as an advanced runtime setting.
5. Keep `Skills` visible while gateway readiness is immature, but treat the
   long-term target as `Connector detail > Requirements` rather than a primary
   product destination.
   Do not collapse Skills browse/install/manage into Connector requirements
   until each Skill can be mapped to a specific user-facing Connector and
   gateway context.
6. Use capability language in copy when describing what the assistant can do:
   "Calendar can read events and create events" is better than "Calendar skill
   installed."
7. When a missing binary blocks a Skill, phrase the UI as a requirement for a
   Connector or capability: "Install `gh` to enable GitHub actions on this Mac."
8. When OAuth blocks a Skill, route users to the Connector authorization path
   instead of making them understand where the token is stored.
9. Gateway detail should keep runtime controls: connect, repair, pair devices,
   machine connections, logs, health, and reachability. Gateway switching is
   descoped for Wave 2 user-facing UI; do not advertise switcher CTAs until the
   product model is supported end to end.
10. Product issues should use this vocabulary in titles and acceptance criteria.
11. Do not move Mac pair/unpair/trust management into a Mac Connector. A Mac
    Connector can summarize capabilities for already-paired Macs and deep-link
    to `Machines > Machine Connections` for trust, repair, and reachability.
12. Use [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md) as the approval
    model for shell, files, clipboard, screen/app context, browser automation,
    gateway config mutation, and action logs.
13. Treat gateway updates as runtime-readiness work under Gateways and blocked
    capability surfaces. Follow [GATEWAY_UPDATE_FLOW.md](GATEWAY_UPDATE_FLOW.md)
    before exposing an enabled `Update Gateway` action.

## Follow-Up Slices

Product decomposition, not execution order:

- Root Connectors IA: group `Native Connectors`, `Provider Connectors`, and
  `Advanced` with clear empty states.
- Calendar detail: keep local EventKit separate from provider calendars; route
  Google Calendar through the Google provider connector and shared Google auth.
- Mac Connector concept: introduce Mac as a Connector/capability group for
  files, clipboard, shell, screen/app context, and local project state, while
  keeping runtime health and pairing in Machines.
- Advanced setup: decide whether `Skills` and `Custom MCP Servers` move from
  gateway detail into `Connectors > Advanced`, or remain duplicated until the
  Connector detail model is complete.
- Requirements UI: map missing binaries, missing auth, and missing OS support to
  human-readable requirement rows on Connector/Skill detail.
- Skills-to-Connector mapping inventory: identify which OpenClaw Skills support
  first-party Connectors and which stay advanced/custom.
- Permissions/privacy approval model: implement the Mac approval UX in
  [MAC_CAPABILITY_SCOPES.md](MAC_CAPABILITY_SCOPES.md) before presenting those
  rows as finished Settings surfaces.
- Capability logs: implement where users inspect what Rem used, on which
  gateway, and with which device permission.

## Operating Queue

Use the existing tracker issues as the queue instead of creating a new tracker
for every product thought. Create a new issue only when the work can be owned,
reviewed, and closed independently.

| Order | Lane | Owning issue | Exit criteria |
|-------|------|--------------|---------------|
| 1 | Skill requirement actions | [#313](https://github.com/Rem-Assistant/RemClaw/issues/313), [#600](https://github.com/Rem-Assistant/RemClaw/issues/600) | Missing skill requirements lead to the right action: installer execution, Connector authorization, gateway recovery, or manual gateway setup. |
| 2 | Connector catalog and detail IA | [#377](https://github.com/Rem-Assistant/RemClaw/issues/377), [#446](https://github.com/Rem-Assistant/RemClaw/issues/446) | Calendar, Gmail, GitHub, and Notion have user-facing Connector rows with provider/status/capability copy. Mac, Files, and Browser can appear as IA placeholders here, but their real capability behavior is owned by the Mac-local lane below. |
| 3 | Connection and pairing recovery pattern | [#445](https://github.com/Rem-Assistant/RemClaw/issues/445), [#284](https://github.com/Rem-Assistant/RemClaw/issues/284) | Launch, banners, Machine Detail, and Machine Connections reuse one recovery pattern for "not paired", "Mac offline", "approval pending", and "continue anyway". |
| 4 | Custom MCP as Advanced Connector | [#338](https://github.com/Rem-Assistant/RemClaw/issues/338), [#377](https://github.com/Rem-Assistant/RemClaw/issues/377) | Custom MCP management remains available to advanced users but is framed as an advanced Connector route, not a separate everyday concept. |
| 5 | Mac-local capability UX | [#317](https://github.com/Rem-Assistant/RemClaw/issues/317), [#495](https://github.com/Rem-Assistant/RemClaw/issues/495), [#659](https://github.com/Rem-Assistant/RemClaw/issues/659) | Remote Mac control, sidebar hierarchy, and Mac task/detail flows feel like one desktop product instead of mobile screens wrapped in a shell. |
| 6 | Gateway version/update selection | [#631](https://github.com/Rem-Assistant/RemClaw/issues/631), [#658](https://github.com/Rem-Assistant/RemClaw/issues/658) | Users can see available OpenClaw versions, understand supported/unsupported targets, and upgrade only through tested backup/health/rollback checks. |

Do not treat this order as a freeze. App-readiness regressions such as auth,
keychain, pairing, data loss, or broken gateway reachability can preempt it.
When that happens, update the owning tracker with why the queue was paused and
which lane should resume next.

## Supersedes / Clarifies

- Clarifies issue
  [#313](https://github.com/Rem-Assistant/RemClaw/issues/313): Skills and OAuth
  are implementation/readiness pieces of Connectors, not a competing root IA.
- Clarifies issue
  [#338](https://github.com/Rem-Assistant/RemClaw/issues/338): MCP remains the
  advanced/custom substrate, not the default integration label.
- Clarifies issue
  [#446](https://github.com/Rem-Assistant/RemClaw/issues/446): Mac Settings IA
  should keep common user paths in-app and avoid exposing gateway configuration
  as the only route to everyday integrations.
- Clarifies issue
  [#448](https://github.com/Rem-Assistant/RemClaw/issues/448): Mac/iOS parity is
  about matching product concepts, not necessarily identical implementation
  rows on every platform.
