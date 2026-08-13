# Rem (macOS)

Full macOS app for Rem -- connects to the same OpenClaw gateway as the iOS app with matching navigation structure.

The macOS product is a normal Dock app and also exposes a menu bar extra for quick gateway/chat access. The target remains named `RemClawMac` internally, but the user-facing app name and bundle display name are `Rem`.

## Navigation Structure

| Screen | Description |
|--------|-------------|
| Agenda | Tasks and events for the selected date (default view) |
| Inbox | Unscheduled tasks |
| Chat | AI chat via OpenClawChatUI |
| Settings | Account, gateway, permissions, skills, paired devices, about |

## Source Folders

| Folder | Description |
|--------|-------------|
| [Sources/App](Sources/App/) | App entry point and lifecycle management |
| [Sources/Data](Sources/Data/) | Data models and task store (MacTaskStore) |
| [Sources/Gateway](Sources/Gateway/) | Dual WebSocket sessions, credential storage, AI tool routing for macOS |
| [Sources/Managers](Sources/Managers/) | Navigation routing (MacRouter) and view state management |
| [Sources/Permissions](Sources/Permissions/) | macOS permission checking for gateway capabilities |
| [Sources/UI](Sources/UI/) | SwiftUI views: main window, agenda, inbox, chat, settings, paired devices, skills |

## Key Files

| File | Purpose |
|------|---------|
| `Sources/Data/MacTaskStore.swift` | Observable store fetching tasks from gateway via `tasks.list` |
| `Sources/UI/MacAgendaView.swift` | Agenda view with date navigation and task list |
| `Sources/UI/MacChatWindow.swift` | Chat window using OpenClawChatUI |
| `Sources/UI/MacFullSettingsView.swift` | Consolidated settings matching iOS structure |
| `Sources/UI/MainWindow.swift` | Main window with NavigationSplitView sidebar |
| `Sources/Managers/MacRouter.swift` | Sidebar navigation enum (Agenda, Inbox, Chat, Settings) |

## Updates

Sparkle is enabled only for non-Debug macOS builds. Local Debug builds do not start the updater at launch. This keeps local development builds from showing a scary startup alert when the production appcast/signature path is not available.

Release builds continue to use `SUFeedURL` from `Info.plist`; verify the appcast and signing path before shipping a public Mac build.
