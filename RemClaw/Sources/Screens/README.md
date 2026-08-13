# Screens

Main app screens for task and calendar management, plus focus sessions.

## Files

| File | Purpose |
|------|---------|
| `AgendaView.swift` | Daily agenda showing scheduled tasks and calendar events. Its Summary appears when `/brief` advertises the backend-authorized durable `rem-orchestrator` session with displayable prose (including an all-clear brief whose counts are all zero) or legacy structured work; a route hint without content and synthesized fallback prose/counts without canonical authority stay hidden. Suggestions render only from a negotiated atomic `/brief` snapshot and every Add/Dismiss carries that exact current-day snapshot ID back to the view model, so a stale row cannot act after refresh or midnight. The exact backend-authored artifact becomes the single summary, scroll-anchor, narration, and read-receipt artifact. |
| `InboxView.swift` | Unscheduled tasks inbox for triage and scheduling |
| `TaskEventView.swift` | Detail view for creating and editing tasks or calendar events |
| `FocusSessionSetupView.swift` | Focus session setup: choose task, duration, and optional warm-up |
| `FocusSessionTaskPickerSheet.swift` | Bottom sheet for selecting a task for a focus session |
| `FocusTimerView.swift` | Active focus timer display with pause, resume, and extend controls |
