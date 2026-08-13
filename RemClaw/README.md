# RemClaw (iOS)

iOS app target for Rem -- AI-powered device control via OpenClaw gateway.

The built app keeps its internal `RemClaw` product, executable, and Swift module names for
compatibility, while `Info.plist` and the target build settings set both user-visible bundle name
keys to `Rem`. Permission usage descriptions must also use the user-facing `Rem` name.

The global New Chat affordance always creates a fresh general conversation. Daily Orchestrator
sessions are entered only from their Agenda summary so those two destinations do not silently
collapse into the same chat.

## Source Folders

| Folder | Description |
|--------|-------------|
| [Sources/Gateway](Sources/Gateway/) | Dual WebSocket sessions (node + operator), credential storage, AI tool routing |
| [Sources/Onboarding](Sources/Onboarding/) | First-launch sign-in, gateway deploy, permissions, data-sharing consent |
| [Sources/Screens](Sources/Screens/) | Main app screens: agenda, inbox, task detail, focus sessions |
| [Sources/Services](Sources/Services/) | Business logic: auth, calendar, reminders, tasks, focus, notifications, IAP |
| [Sources/Settings](Sources/Settings/) | Settings views: gateway, billing, permissions, paired devices, skills |
| [Sources/ViewModels](Sources/ViewModels/) | View models for agenda, inbox, task detail, and focus session screens |
