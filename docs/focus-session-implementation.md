# Focus Session Implementation

## Summary

Focus sessions let users start a timed focus block from an existing task in the Inbox or Agenda. The flow mirrors the OpenClawTestBed/Tija reference: a green "Start a focus session" button on the task detail view opens a setup sheet (duration, warm-up), then a full-screen timer runs until completion. When minimized, a capsule-shaped mini-player bar shows at the bottom with a countdown ring, task title, and pause/stop controls.

## Implemented Behavior

- **Entry point:** Green "Start a focus session" button in the bottom toolbar of `TaskEventView` — only for existing **tasks** (not events, not create mode).
- **Setup sheet:** Duration picker (15m, 25m, 45m, 1h, or task-specific duration with pencil icon for custom), optional warm-up toggle, and task selector.
- **Full-screen timer:** Circular progress ring, countdown, pause/resume, add time, skip warm-up (if enabled), end session.
- **Minimized bar:** Dark capsule mini-player with countdown ring, mode text, task title, time remaining, pause and stop buttons. Tap to re-expand.
- **Task integration:** Session start marks task as "In Progress"; completion dialog offers "Mark Task Complete" to set status to completed.
- **Persistence:** Completed sessions are stored as `StoredFocusSession` in SwiftData.

## App Changes (RemClaw)

### New Files

| File | Purpose |
|------|---------|
| `Sources/Services/FocusTimerProvider.swift` | Protocol for timer interface (`currentSession`, `timeRemaining`, `progress`, pause/resume/stop/extend) |
| `Sources/Services/FocusSessionManager.swift` | Timer engine: 1s tick, warm-up phase, pause/resume, completion, task status updates |
| `Sources/Screens/FocusTimerView.swift` | Full-screen countdown UI with circular ring, controls, completion dialog |
| `Sources/Screens/FocusSessionSetupView.swift` | Setup sheet: duration segmented picker, warm-up, task picker, custom duration sheet |
| `Sources/Screens/FocusSessionTaskPickerSheet.swift` | Bottom sheet to pick a different task for the focus session |
| `Sources/ViewModels/FocusSessionSetupViewModel.swift` | Setup state, dynamic duration options from task `estimatedDuration`/`duration` |
| `Sources/ViewModels/FocusSessionTaskPickerViewModel.swift` | Task filtering (All/In Progress/Recent), search, excludes events |
| `Sources/Components/CircularCountdownRing.swift` | Reusable progress ring for mini-player |

### Modified Files

| File | Change |
|------|--------|
| `Sources/Screens/TaskEventView.swift` | Added `showFocusSetup` state, `onStartFocusSession` callback, green bottom toolbar button, `FocusSessionSetupView` sheet |
| `ContentView.swift` | Added `FocusSessionManager`, `activeFocusSession`, `focusTimerMinimized`; `fullScreenCover` for timer; `minimizedFocusBar`; wiring in `.task` and `EditTaskDestination` |
| `Sources/Gateway/GatewayClient.swift` | Added `import Combine` (fixes `@Published`/`ObservableObject` build error) |

## Duration Picker Behavior

- **Presets:** 15m, 25m, 45m, 1h — tap to select.
- **Last segment:** Either "Custom" or the task's duration (e.g. "2h", "1h 30m") when the task has `estimatedDuration` or `duration`. Always shows a pencil icon (✏️) to indicate it's editable.
- **Editable segment:** Tapping the last segment always opens the custom duration picker sheet, regardless of current value.
- **Task context:** If the task has a non-preset duration, it replaces "Custom" and is pre-selected.

## Minimized Focus Bar

- **Layout:** Dark capsule (`Color(white: 0.1)`), 72pt height, matches reference MiniPlayerView.
- **Left:** `CircularCountdownRing` (44pt) — green when running, yellow when paused.
- **Center:** Mode ("FOCUSING" / "WARMING UP" / "PAUSED"), task title, time remaining ("25:00 left" or "1h 30m left").
- **Right:** Pause/Resume (green circle), Stop (red X circle).
- **Tap anywhere:** Re-expands full-screen `FocusTimerView`.

## Reference

- OpenClawTestBed: `VoiceAgent/Views/Screens/FocusSessionTaskPickerSheet.swift`, `FocusSessionSetupView.swift`, `FocusTimerView.swift`
- Tija: `VoiceAgent/Services/Focus/FocusSessionManager.swift`, `VoiceAgent/Views/Components/MiniPlayerView.swift`
