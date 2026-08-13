# Rem - Claude Code Context

> **Also read [`AGENTS.md`](AGENTS.md)** — the shared, tool-neutral working agreement: delivery
> discipline (review-before-merge, both-platform builds), deploy safety, and the iOS/macOS build
> & tooling gotchas. This file (`CLAUDE.md`) covers architecture, decision principles, and
> per-feature gotchas; `AGENTS.md` covers *how we work*.

## Project Overview

Rem is an iOS + macOS app that connects to an OpenClaw gateway to provide AI-powered device control — calendar, reminders, contacts, location, notifications, and more. Per-user gateways are deployed to Fly.io (one `remclaw-{userId[:8]}` app per user), built from a shared Docker image. The gateway image and managed cloud infrastructure are operated separately and are not part of this repo (see the Open-Core Boundary in the top-level `README.md`). The backend (Node.js/Express on Railway) handles auth, gateway deployment orchestration, and credential management.

## Tech Stack

- **iOS app**: Swift, SwiftUI, @Observable, OpenClawKit, OpenClawChatUI, OpenClawProtocol
- **macOS app**: Swift, SwiftUI, AppKit (menu bar), same OpenClawKit dependency
- **Backend**: Node.js, Express, TypeScript, PostgreSQL (Railway)
- **Gateway**: OpenClaw binary (deployed to Fly.io, one app per user: `remclaw-{userId[:8]}`)
- **Auth**: Apple Sign-In (iOS + Mac), Google Sign-In (iOS only), JWT

## Folder READMEs

Per-folder `README.md` files capture architecture, key files, and conventions. They live alongside the code (e.g. `RemClaw/Sources/Gateway/README.md`) — read the relevant one before changing files in a folder, and update it when changes affect the folder's purpose, key files, or patterns.

## Shared Code (DRY Rule)

All new UI views **must** go in `Shared/Views/` unless they depend on platform-specific APIs (UIKit, AppKit). The pattern:

- **Shared views** are generic over `<Gateway: GatewaySessionProviding>` — they work with both `RemGatewaySessionManager` (iOS) and `MacGatewaySessionManager` (Mac) without casting.
- **Platform root views** are thin wrappers that inject the concrete session manager via `@Environment` and pass it to shared views.
- Use `#if os(iOS)` / `#if os(macOS)` sparingly and only for genuinely platform-specific UI.
- Adding to `GatewaySessionProviding` protocol: if a shared view needs new session data, add it to the protocol and implement in both `+Shared.swift` conformance extensions.

## Architecture Pattern

Both apps follow a **protocol-oriented service coordinator** pattern with SwiftUI observation:

- **Session managers** (`RemGatewaySessionManager`, `MacGatewaySessionManager`) act as central coordinators — they own business logic services and bridge them to SwiftUI via `@Observable`. Not strict ViewModels per view.
- **Protocol layer** (`GatewaySessionProviding`, `TaskStoreProviding`, `TaskDisplayable`) enables shared views to work with both platforms via generics — no type erasure, no casting.
- **Shared views** are generic over the protocol, so iOS and macOS inject different concrete types but use identical view code.
- **Services** (`RemAuthService`, `FocusSessionManager`, etc.) use `@MainActor` isolation and are injected via SwiftUI `@Environment`.
- **Backend** uses classic service-layer: routes → services → database. No ORM — raw parameterized SQL queries.

## Product decisions (read before proposing product changes)

[`docs/product/DECISIONS.md`](docs/product/DECISIONS.md) records the founder's standing decisions
**with the reasoning that produced them** — memory stays thin and why three attempts at it failed;
the task / note / folder / list model; description vs comments vs chat and why no fourth surface;
stale means stop-nagging not delete; an empty brief is fine; every connector should ingest without
per-connector descriptors; and which GMI is kept versus retired.

Most entries were written after an attempt in the opposite direction failed, so the failure is the
useful part. Read it before proposing a change in those areas, and if you reverse a decision, say
you are reversing it and why rather than quietly doing something else.

## Decision Principles

These four principles take priority over speed. Apply them before writing code, opening a PR, or filing an issue.

### 1. Mirror upstream before inventing

Before introducing a new abstraction, file, protocol shape, state model, or recovery flow, check whether **OpenClaw upstream** (under `openclaw/`) or the **reference iOS app** (`openclaw/apps/ios/`) already has a pattern we should mirror. If an upstream pattern exists, use it unless there is a documented Rem-specific reason not to.

This is how we avoid re-litigating problems upstream has already solved (setup-code format, scope handshakes, paired-device storage, gateway lifecycle, control-ui flow, etc). Citations to upstream files belong in code comments and PR bodies.

### 2. Think in full lifecycles, not just happy paths

For any feature, bug, or flow involving a user-manageable resource (gateway, device, pairing, API key, session, agent, model, channel), explicitly think through the full lifecycle:

- **create**
- **read / list**
- **update / reconfigure**
- **delete / unlink / reset**
- **recover** from failure or partial state

Do not stop at the happy path. Test the reverse path too. If pairing works, test unpairing. If setup works, test reset. If a device can be added, verify it can be renamed, removed, rediscovered, and recovered after an error. The bug we hit in v1 is almost always in the path we didn't think to write down.

### 3. Define stateful flows explicitly

For any change involving state across more than one user step or one network call, write down:

- **Source of truth** — which file / property / API holds the canonical value
- **State transitions** — what causes each transition, what side effects fire
- **Recovery path** — what happens when the transition fails or is interrupted
- **User-visible status / copy** — what the user sees during, after success, after failure
- **Non-goals** — what's intentionally out of scope for this change

Drift between client cache, gateway state, and config file is the source of most bugs we ship. Naming the source of truth up front catches it.

### 4. Pre-coding summary

Before writing code on any non-trivial task (issue with a number, multi-file change, anything that touches the gateway, pairing, or storage), summarize in 4 lines:

- **Upstream pattern found** (or "none — Rem-specific because X")
- **User outcome being fixed** (in user words, not implementation words)
- **In scope** for this change
- **Out of scope** for this change

This lives in the PR body. It also lives in your reasoning before the first edit. If you can't write the summary, you don't yet have enough context to start.

### 5. Structured signals over string parsing

When classifying an upstream signal for a machine decision (routing, telemetry, recovery flow), find the structured field. If you're parsing a human-readable string for a machine decision, you're on the wrong layer. Use upstream's own classifiers (e.g. `GatewayConnectionProblemMapper`) when they exist — they've already solved cases you'd otherwise miss. If the upstream type drops the structured field on the way through OpenClawKit, fix the plumbing rather than string-matching downstream.

### 6. Native macOS design reference (required for design-system / Mac polish work)

The **local Native reference app** at `/Volumes/SatechiSSD/Developer/DesignSystem/Native` (not in this repo) is the **mandatory compare target** for any change that claims **macOS UI parity**, **token accuracy**, or **Settings / sheet** alignment with the team’s **Native** system.

**Before the first edit** on that class of task:

1. **Inspect** the relevant screens or components in the Native Xcode project (typography, spacing, grouping, `GroupBox` / list styles, control sizes).
2. **Reconcile** `Shared/Views/DesignTokens.swift` (and any color assets) with what Native actually uses; adjust tokens in RemClaw, not only call sites, when the target is “match Native.”
3. **PR body** must name what was opened in Native (e.g. “Settings → row density compared to `Native` Settings screen X”) and include **in-app** before/after screenshots. Saying “uses `DesignTokens`” is **not** sufficient without step 1.

iOS work still follows **Apple HIG**; this step is in addition, not a substitute, when the deliverable is **Native-aligned Mac** or **shared** surfaces that are explicitly being matched to that reference.

## Common Gotchas

### ISO 8601 Date Parsing

AI agents send dates in varying formats. Always parse with **both** fractional and non-fractional seconds:
```swift
// WRONG: fails on "2026-02-15T01:00:00Z"
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

// RIGHT: try with fractional first, fall back to without
if let d = withFrac.date(from: s) { return d }
return withoutFrac.date(from: s)
```

On the backend connector-signal path that is only half the story — connectors also send bare epoch
numbers, in different units: Slack `ts` is epoch *seconds* with a fractional part, Gmail
`internalDate` is epoch *milliseconds*, both as strings. Read every provider-supplied instant with
**`parseConnectorInstant`** (`backend/src/services/connector-signals.registry.ts`), the union of
strict ISO and epoch-number parsing, rather than reinventing a unit guess per descriptor:
`1e9 ≤ n < 1e11` is seconds, `1e11 ≤ n < 1e14` is milliseconds, outside that band is refused. The
threshold is safe rather than arbitrary because 1e11 is the year 5138 read as seconds but 1973-03-03
read as milliseconds — the ambiguous band contains no timestamp a real message could carry.

### BridgeInvokeRequest

Uses `.command` property, NOT `.method`. The gateway protocol calls it "command".

### OpenClawKit API

- `GatewayNodeSession` is an `actor` — all access is async
- `GatewayConnectOptions` has `includeDeviceIdentity: Bool` (default `true`). Both node and operator use `true`; if pairing is required, auto-approve handles both roles.
- The `connect()` callbacks (`onConnected`, `onDisconnected`, `onInvoke`) should return quickly — don't `await` long operations inside them.

### Permissions Lifecycle

Permissions are checked **once at connection time** and sent as a static map in `GatewayConnectOptions`. The gateway has no API to update permissions after connection — you must **reconnect** to refresh them.

### clientId vs clientDisplayName

- `clientId` — the gateway identity. **iOS sends `openclaw-ios`; Mac sends `openclaw-macos`.** Both
  are upstream-defined (`GATEWAY_CLIENT_IDS`, `openclaw/src/gateway/protocol/client-info.ts`). Use
  the id matching the platform — do not invent one, and do not reuse the iOS id on Mac. It shipped
  that way until 2026-08-10, which made the gateway's stored client record claim the Mac was an
  iPhone.
- `clientDisplayName` — the human-readable label. Node session: `nil` (device name shows through). Operator session: `"Rem"`.

**What `clientId` does and does not control.** This replaces an earlier blanket *"Do NOT change
this — the gateway recognizes this client type"*, which was over-broad and blocked a correct fix.
Verified 2026-08-10:

- It does **not** set the paired-node id. That is `connect.device?.id ?? connect.client.id`
  (`openclaw/src/gateway/node-registry.ts:72`), and `includeDeviceIdentity` defaults to `true`
  (`GatewayChannel.swift:125`), so the **device id wins**. Empirically: the live gateway lists 9+
  paired devices that all send `openclaw-ios`, each holding its own row — if `client.id` were the
  key they would collapse into one. **Changing `clientId` does not re-pair a device or strand a
  paired record.**
- It does **not** drive the agent's "what app am I on" answer. That resolves from the node's
  `platform` string (`InstanceIdentity.platformString`, e.g. `"macOS 15.3.0"`), prefix-matched.
- It does **not** drive the Paired Devices row icon. `LinkedDevice.inferredPlatform` reads
  `platform` first and only falls back to `clientId`; `platform` is always present.
- It **is** persisted as the gateway's record of the client type (`node-registry.ts:89`), so a
  wrong value is a wrong stored fact for every future consumer.

Upstream treats `MACOS_APP` and `IOS_APP` identically at both special-case sites
(`ws-connection/message-handler.ts:554-555`, `agents/tools/sessions-resolution.ts:27-28`) — which is
why the Mac worked at all while mislabelled, and why the fix is low-risk rather than free.

### Gateway Command Allowlist

The gateway uses a **hardcoded platform-based allowlist** for node commands. "Dangerous" commands (`calendar.add`, `contacts.add`, `reminders.add`) are excluded by default. You must use **`allowCommands`** to explicitly add them:

```json
{ "gateway": { "nodes": { "allowCommands": ["calendar.add", "contacts.add", "reminders.add", "system.which"] } } }
```

This is patched via `config.patch` included in the gateway onboarding call (hosted provisioning, operated separately/private).

### Foreground Reconnection

iOS aggressively suspends WebSocket connections when backgrounded. The app observes `scenePhase` in `RemClawApp.swift` and calls `gateway.reconnect()` when returning to foreground.

### Mac app must NOT write secrets to disk except via Keychain

**Never** write provider API keys, gateway auth tokens, or other secrets into a file the Mac app produces directly — most importantly NOT into a `LaunchAgent` plist's `EnvironmentVariables`. The plist sits at default Unix perms in `~/Library/LaunchAgents/` and is readable by any process with disk access. This was the leak in #383.

Allowed homes for Mac-side secrets:

- **Mac Keychain** (service `app.remclaw.mac`) — preferred for anything the Mac app reads at runtime (gateway tokens, BYOK provider keys, OAuth refresh tokens).
- **`~/.openclaw/openclaw.json`** — gateway config including `gateway.auth.token`. Owned by the upstream CLI; we read/write through it. The file gets `0600` perms when we touch it, but rely on Keychain as the redundant source of truth.
- **`~/.openclaw/agents/main/agent/auth-profiles.json`** — upstream-canonical home for BYOK provider keys (format owned by `openclaw/src/agents/auth-profiles/types.ts`).

If you find yourself reaching for a `Process.environment` dictionary to pass a secret to a child process, check first whether the child can read it from Keychain or one of the upstream-canonical files instead. Env vars are fine for a *short-lived* in-memory child (gateway runs as our child post-#383, so its env never touches disk), but the moment that env crosses a launchd plist or a config file you've reintroduced the leak.

When migrating users off a legacy plaintext file, scrub it via `LaunchAgentSecretsMigrator` (or an equivalent one-shot) and set a UserDefaults sentinel so the migration is idempotent across launches.

## Deploy

- **Managed cloud infrastructure** (gateway image, Fly provisioning, deployment runbooks) is operated separately and is not part of this repo (see the Open-Core Boundary in the top-level `README.md`).
- **Backend**: `cd backend && railway up --detach` (Railway)
- **Pre-warmed gateway pool**: Maintains 2 ready-to-assign gateways for <30s first deploy. Falls back to full pipeline (~100s) if pool is empty.

## Key Files (Quick Reference)

| File | Purpose |
|------|---------|
| `Shared/Views/DesignTokens.swift` | Rem shared typography/spacing/colors; must be reconciled with `/Volumes/.../DesignSystem/Native` for Native-claims (see principle 6). |
| `RemClaw/Sources/Gateway/GatewayClient.swift` | iOS dual-session gateway client |
| `RemClaw/Sources/Gateway/GatewaySessionManager.swift` | iOS observable UI state, auto-approve, reconnection |
| `RemClaw/Sources/Gateway/NodeInvocationRouter.swift` | Routes AI tool calls to iOS device handlers |
| `RemClawMac/Sources/Gateway/MacGatewaySessionManager.swift` | Mac session manager with auth + auto-approve |
| `backend/src/services/gateway-pair.service.ts` | WebSocket helpers: auto-approve, config patch |
