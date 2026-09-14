# ViewModels

View models that drive the main app screens, handling data filtering, state management, and user interactions.

## Files

| File | Purpose |
|------|---------|
| `AgendaViewModel.swift` | Manages agenda data and durable brief reconciliation. Backend fallback prose remains internal until exact backend-authorized Today history installs the canonical transcript used by Agenda; same-artifact refreshes retain that reconciled transcript through transient history failures, while artifact or session changes fail closed. Suggestions come only from the negotiated atomic brief payload; accept/dismiss requires the exact current-day snapshot plus account/backend/gateway scope. Acceptance dismisses only after SwiftData save and backend-or-offline-queue durability, and create acceptance reuses the backend action UUID so recovery cannot duplicate after schedule drift. |
| `InboxViewModel.swift` | Manages unscheduled task filtering and calendar info for the inbox |
| `TaskEventViewModel.swift` | Handles task/event detail editing, validation, and persistence |
| `FocusSessionSetupViewModel.swift` | Manages focus session duration, warm-up options, and task selection |
| `FocusSessionTaskPickerViewModel.swift` | Filters and presents tasks for focus session picker (excludes calendar events) |
