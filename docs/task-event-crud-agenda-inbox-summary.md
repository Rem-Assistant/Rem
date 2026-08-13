# Task and Event CRUD Agenda/Inbox Summary

## Implemented behavior

- Tasks with a date/time show in Agenda on that specific date.
- Tasks without a date/time stay Inbox-only.
- Connected calendar events render in Agenda.
- Tasks and events can be created, read, updated, and deleted through chat tooling.
- Text and voice both use the same chat transport, so the same task/event command path applies to both.

## App changes (RemClaw)

- `RemClaw/Sources/Gateway/DeviceCommandTypes.swift`
  - Added `tasks.list`, `tasks.get`, `tasks.create`, `tasks.update`, `tasks.delete` command definitions and request/response payload types.
- `RemClaw/Sources/Gateway/NodeInvocationRouter.swift`
  - Added task CRUD routing/handlers.
  - Added task access configuration via `configureTaskAccess(...)`.
  - Added create/update/delete sync behavior with local-first fallback.
- `RemClaw/ContentView.swift`
  - Wired task sync and API dependencies into Agenda/Inbox.
  - Configured router task access at startup.
  - Bound active session to current device node.
- `RemClaw/Sources/Gateway/GatewayClient.swift`
  - Exposed `tasks` capabilities/commands in gateway handshake.
  - Updated connection flow to establish operator session before marking fully connected.
- `RemClaw/Sources/Gateway/GatewaySessionManager.swift`
  - Added `bindSessionToCurrentDeviceNode(sessionKey:)` to patch session `execNode`.
- `RemClaw/Sources/Gateway/RemChatTransport.swift`
  - Added session patch defaults (`verboseLevel=on`, `execNode=<currentDeviceId>`) on session set and send.
- `RemClaw/Sources/ViewModels/AgendaViewModel.swift`
  - Added device calendar event loading for selected date.
  - Added calendar-only event projection and calendar metadata caching.
  - Added resolve/create flow so calendar-only rows open existing details UI model.
- `RemClaw/Sources/Screens/AgendaView.swift`
  - Rendered calendar-only rows in Agenda.
  - Hooked row navigation into existing `TaskEventView`.
  - Refreshed calendar events on selected date changes.

## Backend changes

- Gateway onboarding config patch (hosted provisioning, operated separately/private)
  - Added `tasks.create`, `tasks.update`, `tasks.delete` to the node command allowlist.

## OpenClaw submodule changes

- `openclaw/src/gateway/node-command-policy.ts`
  - Allowed task mutation commands.
- `openclaw/src/agents/tools/nodes-tool.ts`
  - Added node tool support for task CRUD command execution.
- `openclaw/src/agents/tools/nodes-utils.ts`
  - Added task command helper handling/normalization updates.

## Commits represented by this summary

- RemClaw commit: `5a5cca8`
- OpenClaw submodule commit: `b79cee88b`
