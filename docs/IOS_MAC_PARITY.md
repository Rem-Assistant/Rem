# iOS / Mac 1:1 Parity Audit

Comparison of features between the iOS app (`RemClaw/`) and Rem for Mac (`RemClawMac/`).

This is a parity audit, not the product source of truth. If priority or role
language here conflicts with `docs/product/VISION.md`, prefer the vision doc and
update this audit as stale.

## Feature Parity Matrix

### Gateway & Connection

| Feature | iOS | Mac | Gap |
|---------|-----|-----|-----|
| Dual WebSocket sessions (node + operator) | Yes | Yes | Parity |
| Auto-approve pairing | Yes | Yes | Parity |
| Auto-reconnect with exponential backoff | Yes | Yes | Parity |
| Foreground reconnect (scenePhase) | Yes | Yes | Parity |
| Credential storage (Keychain + UserDefaults) | Yes | Yes | Different keys/service names |
| Chat transport (OpenClawChatUI) | Yes | Yes | Parity |
| Device context preamble | Yes | Yes (shared file) | Parity |
| Permissions snapshot on connect | Yes | Yes | Different permission sets per platform |

### Authentication

| Feature | iOS | Mac | Gap |
|---------|-----|-----|-----|
| Apple Sign-In | Yes | Yes | Parity |
| Google Sign-In | Yes | Yes | Parity |
| Token refresh | Yes | Yes | Parity |
| Sign out | Yes | Yes | Parity |
| Credential restore on launch | Yes | Yes | Parity |

### AI Node Commands (Invocation Router)

| Feature | iOS | Mac | Gap |
|---------|-----|-----|-----|
| system.notify | Yes | Yes | Parity |
| system.which | No | Yes | Mac-only (checks binary paths) |
| system.run / shell.exec | No (unavailable on iOS) | Yes | Mac-only by design |
| clipboard.read | No | Yes | Mac-only by design |
| clipboard.write | No | Yes | Mac-only by design |
| files.read | No | Yes | Mac-only by design |
| files.write | No | Yes | Mac-only by design |
| files.list | No | Yes | Mac-only by design |
| screen.record | No | Yes (stub) | Mac-only by design |
| calendar.events | Yes | No | iOS-only -- Mac could benefit from this |
| calendar.add | Yes | No | iOS-only |
| calendar.update | Yes | No | iOS-only |
| calendar.delete | Yes | No | iOS-only |
| reminders.list | Yes | No | iOS-only |
| reminders.add | Yes | No | iOS-only |
| reminders.update | Yes | No | iOS-only |
| reminders.delete | Yes | No | iOS-only |
| device.status | Yes | No | iOS-only (battery, thermal) |
| device.info | Yes | No | iOS-only |
| tasks.list | Yes | No | iOS-only (SwiftData tasks) |
| tasks.get | Yes | No | iOS-only |
| tasks.search | Yes | No | iOS-only (name → task lookup, read-only) |
| tasks.create | Yes | No | iOS-only |
| tasks.update | Yes | No | iOS-only |
| tasks.delete | Yes | No | iOS-only |

### UI & Screens

| Feature | iOS | Mac | Gap |
|---------|-----|-----|-----|
| Chat view | Yes | Yes | Parity |
| Settings (general) | Yes | Yes | In-app Settings is canonical on both platforms; Mac does not expose a separate native Settings scene |
| Server/connection settings | Yes | Yes (in General tab) | Parity |
| Permissions view | Yes (in Settings) | Yes (dedicated tab) | Parity |
| Skills management | Yes (in Settings) | Yes (dedicated view) | Parity |
| Paired devices list | Yes | Yes | Parity |
| Agenda view (daily schedule) | Yes | No | iOS-only -- core productivity feature |
| Inbox view (unscheduled tasks) | Yes | No | iOS-only -- core productivity feature |
| Task/event detail editor | Yes | No | iOS-only |
| Focus sessions | Yes | No | iOS-only |
| Billing / subscription | Yes | No | Mac has no IAP; may not need it |
| Quota exceeded sheet | Yes | No | Tied to billing -- add when billing is added |
| Onboarding flow | Yes | Yes (sign-in only) | Mac lacks permissions onboarding + AI consent |
| Menu bar popover | No | Yes | Mac-only UI pattern |
| Delete account | Yes | No | Mac should add this |

### Services

| Feature | iOS | Mac | Gap |
|---------|-----|-----|-----|
| RemAuthService (shared auth logic) | Yes | Inline in SessionManager | Could extract to shared module |
| TaskStore (SwiftData) | Yes | No | iOS-only |
| Task sync (backend API) | Yes | No | iOS-only |
| Calendar service (EKEventStore) | Yes | Partial | Settings now exposes Calendar as a native Connector with macOS usage copy; Mac command handlers still need an EventKit adapter. |
| Reminders service (EKEventStore) | Yes | No | Could add to Mac (EventKit works on macOS) |
| Focus session manager | Yes | No | iOS-only |
| Task notifications (local) | Yes | No | iOS-only |
| Telemetry service | Yes | No | Mac has no analytics |
| IAP service (StoreKit) | Yes | No | Mac has no in-app purchases |
| Usage tracking | Yes | No | Mac has no usage/quota tracking |
| App config (xcconfig) | Yes | No | Mac uses hardcoded/inline config |

## What iOS Has That Mac Is Missing

The most impactful gaps, ordered by priority:

1. **Delete account** -- required for App Store compliance on both platforms
2. **Calendar/Reminders commands** -- Calendar is now first-class in Connectors, but Mac still needs EventKit command handlers; Reminders remains iOS-only.
3. **Telemetry** -- no analytics on Mac makes it harder to track usage
4. **Onboarding (permissions + AI consent)** -- Mac skips these screens
5. **Task management (Agenda, Inbox, TaskStore)** -- core iOS feature, lower priority for the Mac app while gateway capabilities are the focus
6. **Focus sessions** -- iOS-specific productivity feature
7. **Billing/IAP** -- only needed if Mac becomes a standalone product

## What Mac Has That iOS Is Missing

1. **Shell execution** (system.run, shell.exec) -- by design, not applicable to iOS
2. **File system access** (files.read, files.write, files.list) -- by design
3. **Clipboard access** (clipboard.read, clipboard.write) -- by design
4. **system.which** -- binary path checking, macOS-only
5. **Menu bar popover** -- macOS UI pattern

## Shared Code Opportunities

| Code | Currently | Recommendation |
|------|-----------|----------------|
| `KeychainStore.swift` | Duplicated (identical logic, different files) | Extract to shared Swift package |
| Agent device/time context | Native `openclaw-ios` registration + gateway `userTimezone` | Native `openclaw-macos` registration + gateway `userTimezone` |
| Auth logic | iOS: `RemAuthService`, Mac: inline in `MacGatewaySessionManager` | Extract shared auth service |
| Chat transport | iOS: `RemChatTransport`, Mac: `MacChatTransport` | Near-identical; extract shared protocol |
| Command types | iOS: `DeviceCommandTypes.swift` | Share for any commands Mac adopts |
| Credential store | iOS: `RemCredentialStore` enum, Mac: inline | Extract shared credential abstraction |
| Skills settings | Shared `SkillModels` plus shared skills views | Core skills management is already shared; track future gaps as feature-level parity issues |
