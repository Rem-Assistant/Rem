# OpenClawKit Integration Guide

## Phase 2: Local Xcode Setup

Open `RemClaw.xcodeproj` in Xcode and follow these steps.

### Step 1: Add OpenClawKit as a local SPM package

1. In Xcode, go to **File → Add Package Dependencies...**
2. Click **Add Local...** (bottom left)
3. Navigate to `openclaw/apps/shared/OpenClawKit/`
4. Select all three library products:
   - `OpenClawProtocol`
   - `OpenClawKit`
   - `OpenClawChatUI`
5. Add them to the **RemClaw** target

### Step 2: Add Swabble as a local SPM package (optional for now)

1. Same process: **File → Add Package Dependencies... → Add Local...**
2. Navigate to `openclaw/Swabble/`
3. Select `SwabbleKit`
4. Add to the **RemClaw** target

> **Note:** SwabbleKit is only needed if you enable voice wake detection.
> The current integration doesn't require it — skip if you want a minimal build.

### Step 3: Build & fix

After adding the packages, build (`Cmd+B`). Potential issues:

#### Swift 6.2 requirement
OpenClawKit requires `swift-tools-version: 6.2`. If your Xcode doesn't support
this yet, edit `openclaw/apps/shared/OpenClawKit/Package.swift` line 1:
```
// swift-tools-version: 6.0
```

#### ElevenLabsKit / Textual resolution
These are remote SPM dependencies declared in OpenClawKit's `Package.swift`.
Xcode will fetch them automatically. If there are version conflicts, check
that no other packages in your project depend on different versions.

#### Strict concurrency warnings
OpenClawKit enables `StrictConcurrency`. If you get warnings in your own
code, add `@Sendable`, `@MainActor`, or `nonisolated` as needed.

### Step 4: Test on simulator

1. Run on iPhone simulator
2. On first launch, you'll see the "Connect to Your Server" setup screen
3. Enter your Railway gateway URL (e.g. `https://your-app.up.railway.app`)
4. Enter your gateway token (from `/setup/api/credentials`)
5. Tap Connect — the app should switch to the Chat tab
6. Send a test message

## Architecture Overview

```
RemClawApp
  └─ RemGatewaySessionManager (@Observable, @MainActor)
       ├─ RemGatewayClient (actor)
       │    └─ GatewayNodeSession (from OpenClawKit)
       │         └─ GatewayChannelActor (WebSocket)
       └─ GatewayServerProvider (protocol)
            └─ RailwayProvider (current impl)

ContentView
  ├─ if !configured → ServerSetupFlow
  └─ if configured → RemMainTabView
       ├─ Tab: Chat → RemChatTab
       │    └─ OpenClawChatView (from OpenClawChatUI)
       │         └─ OpenClawChatViewModel
       │              └─ IOSGatewayChatTransport (from cloned iOS app)
       └─ Tab: Settings → RemSettingsTab
            └─ SharedSettingsView + iOS-specific settings sections
```

## Data flow

1. **Onboarding**: User enters URL + token → `RemGatewaySessionManager.configure()`
   → saves to UserDefaults → creates `RailwayProvider` → calls `RemGatewayClient.connect()`
2. **Connection**: `RemGatewayClient` → `GatewayNodeSession.connect()` → `GatewayChannelActor`
   → WebSocket to `wss://your-app.up.railway.app`
3. **Chat**: `OpenClawChatView` → `OpenClawChatViewModel` → `IOSGatewayChatTransport`
   → `GatewayNodeSession.request("chat.send", ...)` → WebSocket → gateway
4. **State**: `RemGatewayClient.onStateChange` → `RemGatewaySessionManager.connectionState`
   → SwiftUI `@Environment` → all views update

## Files changed from stubs

| File | Was | Now |
|------|-----|-----|
| `RemClawApp.swift` | Hello world | Gateway init + environment injection |
| `ContentView.swift` | Globe icon | Tabbed app (Chat + Settings) with onboarding gate |
| `GatewayClient.swift` | Empty sendMessage | `RemGatewayClient` actor wrapping `GatewayNodeSession` |
| `GatewayClientProtocol.swift` | 4-line protocol | `GatewayServerProvider` protocol + `RailwayProvider`; shared connection state now lives in `Shared/Protocols/GatewaySessionProviding.swift` |
| `GatewaySessionManager.swift` | Empty ObservableObject | `RemGatewaySessionManager` with credentials, lifecycle, chat transport |
| `ServerSettingsView.swift` | EmptyView | Full settings section with live state + actions |
| `ServerSetupFlow.swift` | EmptyView | Manual gateway entry form (placeholder for your custom onboarding) |
| `GatewayDisconnectedBanner.swift` | EmptyView | Real banner with reconnect button |

## Phase 3 Status

- [x] Voice pipeline (TalkModeManager, VoiceWakeManager)
- [x] Task CRUD (tasks.list, tasks.get, tasks.create, tasks.update, tasks.delete)
- [x] Notifications (system.notify)
- [x] Move gateway token from UserDefaults to Keychain
- [x] Custom onboarding (deploy wizard via backend)
- [x] Fly.io hosting (per-user gateways)
- [ ] Skills/tools settings UI (`SkillsUpdateParams` protocol models exist)
- [ ] Screen/camera capabilities
- [ ] Push notifications (`GatewayPush.swift` exists in OpenClawKit)
