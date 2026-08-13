# Data (macOS)

> The macOS app's task data layer. Fetches tasks from the backend REST API (no local database — unlike iOS which uses SwiftData), and wraps them in the shared protocol so Agenda and Inbox views work the same on both platforms.

Lightweight task data layer for the macOS app — plain Swift structs backed by a backend HTTP API (no SwiftData dependency).

## Key Files

| File | Purpose |
|------|---------|
| `MacTaskStore.swift` | `@MainActor @Observable` task store with `allTasks` array. CRUD operations via REST API (`/api/v1/tasks/*`): fetch (paginated), complete, delete, snooze, create. `commitCollaborationStatus(_:for:)` PATCHes a collaboration-thread proposed status (mirrors iOS `TaskEventViewModel.commitCollaborationStatus`). Provides computed filters: `unscheduledTasks`, `tasks(for:)`, `completedTasks`. |
| `MacOrchestratorSuggestionStore.swift` | Window-owned Daily Brief suggestion state. Loads the negotiated atomic payload and requires its authored revision, snapshot ID, current day, and action UUID. Canonical `(scope, actionId)` mutation claims survive same-scope refreshes; effective local/cloud gateway identity prevents state crossing runtimes. |
| `MacTaskStore+TaskStoreProviding.swift` | `MacTaskStoreAdapter` wrapping `MacTaskStore` to conform to shared `TaskStoreProviding` protocol. Uses closure-based dependency injection for `backendURL` and `backendToken` (dynamic credentials). |
| `MacTask` co-authored description | `taskDescription` (the user's half) and `agentContext` (Rem's half) mirror backend migration 120, parsed from the pre-split `description_user` / `description_agent` keys — the block delimiter is never parsed on the client. **Read-only on Mac**: `MacTaskDetailView.descriptionSection` displays both, and iOS owns the editor, so there is no second writer for the same column. |
| `MacTask+TaskDisplayable.swift` | Extension conforming `MacTask` to `TaskDisplayable` protocol with `displayId`, `displayCategory`, `displayPriority`, and `formattedDuration` computed property. |

## Architecture

```
MacTask (struct: Identifiable, Hashable)
  └── conforms to TaskDisplayable (via extension)

MacTaskStore (@Observable)
  ├── manages [MacTask] in allTasks
  └── calls /api/v1/tasks REST endpoints

MacTaskStoreAdapter (@Observable)
  ├── wraps MacTaskStore
  ├── conforms to TaskStoreProviding protocol
  └── captures credential closures for dynamic auth
```

## Patterns & Conventions

- **No SwiftData**: Unlike iOS (`TaskEvent` is a SwiftData model), macOS uses plain `MacTask` structs — simpler, no persistent store.
- **Adapter pattern**: `MacTaskStoreAdapter` bridges the concrete `MacTaskStore` to the shared `TaskStoreProviding` protocol, enabling shared views (`SharedAgendaView`, `SharedInboxView`) to work with Mac task data.
- **Closure-based credentials**: Adapter captures `() -> String?` closures for `backendURL` and `backendToken` rather than storing static values, allowing credentials to change after initialization.
- **Flexible JSON parsing**: Handles both `{"tasks": [...]}` and bare `[...]` response formats. Dual ISO 8601 date parsing (with/without fractional seconds).
- **Same REST API**: Both iOS and macOS apps use identical `/api/v1/tasks` backend endpoints.
- **One suggestion owner**: `MainWindow` owns one `MacOrchestratorSuggestionStore` beside its one `MacTaskStore` and injects both into Chat. A backend action UUID is both the same-scope in-flight claim and create-task UUID, so refresh and retry cannot duplicate an accepted proposal. Accept captures immutable backend credentials for both task mutation and dismissal, a client-ID create must PATCH the accepted payload before dismissal so a lost-ACK retry cannot retain older title or schedule fields, and suggestion network helpers return unpublished tasks so the owner can revalidate its account/generation before updating the window cache. The window-level scope observer synchronously retires old actions across sign-out before the authenticated Chat subtree is removed.
