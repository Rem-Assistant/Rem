# Shared/ — Cross-platform code for iOS + macOS

> Code that runs on both iPhone and Mac without being duplicated. Defines the contracts (protocols) that both apps must honour, the shared data models, and the SwiftUI views that look and behave the same on both platforms — like Settings, Gateway list, Skills, paired Devices, Agenda, and Inbox.

This directory contains models, protocols, views, and services shared between the `RemClaw` (iOS) and `RemClawMac` targets. It is configured as a PBXFileSystemSynchronizedRootGroup targeting both platforms. `README.md` files are excluded from both targets via `membershipExceptions`.

## Architecture

```
┌─────────────┐     ┌─────────────────────────────┐     ┌─────────────┐
│   RemClaw   │     │          Shared/             │     │ RemClawMac  │
│   (iOS)     │────>│  GatewaySessionProviding     │<────│  (macOS)    │
│             │     │  TaskDisplayable             │     │             │
│  Session    │     │  GatewayConfig + ConfigStore  │     │  Session    │
│  Manager    │     │  SharedSettingsView          │     │  Manager    │
│  +Shared    │     │  SharedGatewayListView       │     │  +Shared    │
│             │     │  SharedAgendaView            │     │             │
│             │     │  SharedInboxView             │     │             │
└─────────────┘     └─────────────────────────────┘     └─────────────┘
```

Both session managers conform to `GatewaySessionProviding` via `+Shared.swift` extensions. Shared views are generic over `<Gateway: GatewaySessionProviding>` or `<Store: TaskStoreProviding>`, so they work with either platform's concrete types without casting.

## Directory Structure

```
Shared/
├── Automations/
│   ├── AutomationInputsPresentation.swift  # Pure rendering rules + store for derived Inputs
│   ├── AutomationOutputsPresentation.swift # Pure rendering rules + store for derived Outputs
│   └── DailyBriefAutomationPresentation.swift # Check-in → one Daily Brief projection + store
├── Protocols/
│   ├── GatewaySessionProviding.swift   # Core protocol + GatewayConnectionState enum
│   ├── TaskDisplayable.swift           # TaskDisplayable + TaskStoreProviding protocols
│   └── GatewaySessionConformance.swift # Backward-compat typealiases
├── Models/
│   ├── LinkedDevice.swift              # LinkedDevice, DevicePlatform, DeviceToken
│   ├── SkillModels.swift               # SkillEntry, SkillFilter, SkillsStatusResponse
│   └── GatewayConfig.swift             # GatewayConfig, GatewayProvider enum
├── Views/
│   ├── DesignTokens.swift              # Colors, spacing, typography, shimmer
│   ├── Gateway/                        # Gateway list/detail, deploy, recovery, devices, setup code
│   ├── Settings/                       # Root settings, about, delete account, settings fixtures/icons
│   ├── Skills/                         # Capabilities, installed skills, browse, MCP servers
│   ├── Chat/                           # Shared chat surface and tool cards
│   ├── OAuth/                          # Connected accounts / connector surfaces
│   └── Tasks/                          # Agenda, Inbox, shared task rows, previews
├── PreviewSupport/                     # DEBUG fixture stores and gateway states
└── Services/
    ├── GatewayConfigStore.swift        # Multi-gateway persistence (UserDefaults + Keychain)
    ├── AutomationInputsService.swift   # Derived automation inputs (see Services/README.md)
    └── AutomationOutputsService.swift  # Derived automation outputs (see Services/README.md)
```

## Do Not Hand-Write What The Server Can Observe

`Shared/Automations/AutomationContract.swift` used to declare the Daily Brief **inputs** and
**outputs** as Swift arrays with `.active` / `.planned` typed in by hand. A literal cannot observe
the runner, so it was wrong in both directions at once: it called connectors "planned" while a
Gmail collect was already running, and it would have kept saying "Included" while that collect
failed six times in a row.

The file is gone. Inputs moved server-side first; outputs followed, and the delay proved the point
twice over — the surviving `.planned` on "Suggested tasks" stayed wrong for the entire period that
`deriveSuggestions` was shipping tier-1 and tier-2 suggestions and `GET /api/v1/brief` was serving
them. Worse, a unit test asserted that literal was `.planned` and passed the whole time, because a
literal compared against a literal can only agree. If a test can pass without the product working,
it is not evidence.

Anything the app asserts about what the agent *can currently do* — inputs, capabilities, connected
sources — must be derived server-side and rendered, not authored in Swift. When the answer arrives
over the wire, decode enum-like fields as strings with an `unrecognized(String)` case: a newer
server must not break an older client, and an unknown value must never be coerced into a friendlier
known one.

## Key Protocols

### `GatewaySessionProviding` (`Protocols/GatewaySessionProviding.swift`)
Core contract for session managers. Declares connection state, authentication status, linked devices, skills RPC, reconnection, and configuration methods. Marked `@MainActor` and `Observable`.

### `TaskDisplayable` (`Protocols/TaskDisplayable.swift`)
Read-only protocol for task display across platforms. Both `TaskEvent` (iOS SwiftData) and `MacTask` (macOS) conform to it. Shared lists key rows explicitly by `displayId` rather than making this display protocol refine `Identifiable`; SwiftData already synthesizes `TaskEvent`'s identity conformance, and asking a cross-platform extension to synthesize it again produces duplicate linker metadata in clean builds. `TaskStoreProviding` provides task queries, filtering, and CRUD actions.

### `GatewaySessionConformance` (`Protocols/GatewaySessionConformance.swift`)
Backward-compatibility typealiases (`RemGatewayConnectionState`, `MacConnectionState`, `MacLinkedDevice`, etc.) to avoid mass refactoring when types were unified.

## Patterns & Conventions

- **Generics over protocols**: Views are generic over `GatewaySessionProviding` or `TaskStoreProviding` — compile-time type safety without type erasure.
- **Platform conditionals**: `#if os(iOS)` / `#if os(macOS)` used sparingly for genuinely platform-specific UI (swipe actions vs context menus, `List` vs `GroupBox` layouts, sheet sizing).
- **Design tokens**: `DesignTokens` centralizes platform-aware colors, spacing, typography, and corner radii. Avoids magic numbers.
- **Sendable models**: All shared data types (`LinkedDevice`, `SkillEntry`, `GatewayConfig`) are `Sendable` for concurrency safety.
- **Credential separation**: `GatewayConfigStore` stores metadata in UserDefaults and tokens in Keychain with platform-specific service names (`app.remclaw` vs `app.remclaw.mac`).
- **Legacy migration**: `GatewayConfigStore.migrateFromLegacy()` converts single-gateway credentials to multi-gateway format without data loss.
- **Per-gateway runtime controls**: Settings should route users from the OpenClaw row into active gateway detail first, keeping Devices & Pairing, Backup, Skills, MCP servers, updates, and connection actions scoped to the selected gateway.
- **Reusable components**: `SharedSettingsIcon`, `SharedTaskRow`, `SharedPillView`, `SharedOverduePillView` are used across multiple views.

## Adding New Shared Views

1. Create the view in the matching `Shared/Views/<Domain>/` folder and keep it generic over `<Gateway: GatewaySessionProviding>` when it depends on gateway state.
2. Use standard SwiftUI fonts (not `DesignTokens.Typography`) and `.primary`/`.secondary` colors for best cross-platform appearance.
3. If the view needs new session data, add it to `GatewaySessionProviding` protocol and implement in both `+Shared.swift` conformance extensions.
4. Use `#if os(iOS)` / `#if os(macOS)` only for genuinely platform-specific UI.
