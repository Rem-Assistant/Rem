# Managers (macOS)

> Tracks which surface is active in the macOS main window. The sidebar nav rows are Agenda, Inbox, Sessions, and Settings; Chat is reached via the distinct "Chat" primary button at the sidebar footer or by opening a past conversation from the Sessions tab. One file, one class — that's the whole folder.

Navigation and routing for the macOS app.

## Key Files

| File | Purpose |
|------|---------|
| `MacRouter.swift` | `@Observable` navigation router with `Screen` enum (agenda, inbox, sessions, chat, settings). `Screen.sidebarCases` returns the four nav rows actually shown in the sidebar (chat is intentionally excluded — it's a primary-action button at the sidebar footer, not a row). Each screen has an SF Symbol icon mapping. `selectedScreen` drives `NavigationSplitView` in `MainWindow`; `pendingSessionKey` + `openSession(_:)` route into a specific past chat; `startNewChat()` powers the sidebar-footer "Chat" button. See #305 (Mac chat parity epic). |

## Architecture

```
RemClawMacApp (@main)
  └── @State router = MacRouter()
        └── environment(router)
              └── MainWindow
                    ├── sidebar List(MacRouter.Screen.sidebarCases)
                    │     selection: $router.selectedScreen
                    │     ├── .agenda   → SharedAgendaView
                    │     ├── .inbox    → SharedInboxView
                    │     ├── .sessions → MacSessionsView
                    │     └── .settings → MacFullSettingsView
                    ├── sidebar footer
                    │     └── "Chat" Button → router.startNewChat()
                    └── detail (when router.selectedScreen == .chat)
                          → MacChatWindow (renders SharedRemChatView)
```

## Patterns

- **Enum-based navigation**: Type-safe `Screen` enum prevents invalid navigation states.
- **Environment injection**: Router instantiated in `RemClawMacApp`, consumed in `MainWindow` via `@Environment`.
- **`@Observable`**: Uses modern SwiftUI observation (not `ObservableObject`) for reactive binding with `@Bindable`.
