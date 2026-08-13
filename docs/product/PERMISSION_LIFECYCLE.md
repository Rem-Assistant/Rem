# Permission Lifecycle

Rem has three different permission surfaces. They can appear in the same user
journey, but they are not the same problem and should not share vague copy.

## Permission Surfaces

### 1. Runtime Machine Approval

This is the approval that lets a Rem agent or runtime use the user's active
private machine. It is not the same as the user's iPhone being linked to the
machine.

Use this language:

- `Rem needs permission to use your machine.`
- `Approve Rem Agent`
- `Open Machine Connections to review the pending runtime request, then retry your message.`

Avoid this language in app-owned surfaces:

- `Pair your iPhone with OpenClaw.`
- `Your phone is not paired.`
- Raw diagnostics such as `agent=main node=... action=invoke`.

The model can narrate what happened, but the app should render runtime approval
from structured gateway state or a structured diagnostic class. Assistant prose
is not the source of truth.

Expected lifecycle:

1. A machine/tool call returns a runtime pairing diagnostic.
2. Chat renders a compact `Error` diagnostic row and a Rem-first recovery card.
3. The recovery CTA opens Machine Connections.
4. Machine Connections shows the pending runtime request under pending machines.
5. The user approves or declines that specific request.
6. The app refreshes pending and paired devices, reconnects if needed, and retry
   becomes possible.

Log enough state to debug this without exposing secrets:

- conversation id and session id
- machine/gateway id or host hash
- pending request id, display name, role, and platform when available
- paired runtime/device summary after refresh
- action/tool id and sanitized error class
- user action: open recovery, approve, decline, retry
- retry result

### 2. Device OS Permissions

These are platform permissions owned by iOS, such as Reminders, Calendars,
Location, Microphone, Speech Recognition, Camera, and Notifications.

Use a pre-prompt before the OS prompt when the permission is requested from an
assistant flow. The pre-prompt should explain what Rem is about to ask for and
why, then trigger the native prompt only after the user chooses to continue.

Expected lifecycle:

1. An assistant action needs an OS permission.
2. Chat or the relevant surface shows a pending action card.
3. Rem shows a pre-prompt sheet with the requested permission and action reason.
4. The user chooses continue, then iOS shows the native permission prompt.
5. The action card updates to granted, denied, failed, or completed.
6. If denied, Rem shows repair guidance and links to Settings where possible.

The Claude permission audit is a useful reference: request rows can move from
`Requesting...` to a final result card after permission is granted and the action
finishes.

### 3. Connector And Account Permissions

These are permissions for external accounts, credentials, OAuth scopes, API
keys, and connector-backed actions. They may be broader than a single device OS
permission and may live in Settings, Connectors, or an inline chat approval.

Expected lifecycle:

1. An action needs a connector, scope, or credential.
2. Rem explains the account or tool access being requested.
3. If action-scoped, Rem shows the requested change before approval.
4. The user can allow once, always allow when supported, or deny.
5. The action card updates with the result and a clear next step.

Connector credentials should not be entered into chat unless the credential flow
explicitly supports secure capture and storage.

## Action Lifecycle Cards

The lifecycle pattern applies to tool and action progress too, not only explicit
permission prompts. Raw payloads, reminder arrays, truncated JSON, gateway
diagnostics, and backend tool dumps must never render as chat prose.

Use structured cards for visible state:

- Pending: `Searching through reminders...`, `Updating reminder...`, `Creating event...`
- Final: `Reminder Updated`, `Reminder Set`, `Created 1 event`
- Failure: a short failure card with the next recovery step

`MessageCleaner` suppresses accidental dumps as a backstop, but structured
parsers and cards own the visible lifecycle. Pending card styling lives in
`Shared/Views/Chat/ActionLifecycleCard.swift`; final action cards live in
`Shared/Views/Chat/ToolResultCards/`. The Claude audit pattern is useful here: a
requesting/checking row evolves into a final result card instead of leaving
intermediate payloads in the transcript.

This is not limited to permission prompts. Some actions, such as Reminders on a
device where access is already granted, may never show an OS permission request.
They still need the same UI lifecycle: a pending card while Rem searches or
updates, then a final card once the action completes.

## Status Placement

Status belongs where it helps the user decide what to do next.

Use Chat for AI-action status: runtime approval, tool progress, permission
repair, and final action results that affect the current conversation.

Use Agenda for agenda-specific status, such as Calendar access or calendar sync
repair. Avoid broad gateway-connection banners inside Agenda unless the agenda
screen itself is the recovery path.

Use launch, setup, or machine recovery screens for app-blocking runtime state.
Those surfaces should own "machine still connecting" and "machine unavailable"
moments before the user lands in normal content.

Prefer durable lifecycle cards over transient banners when the status is part of
an assistant action. A banner can call attention to ambient app state, but it
should not replace the visible action lifecycle in chat.

## Screen Ownership

Machine detail owns runtime health and connection status.

Machine Connections owns runtime/device approval, revocation, and reset of a
specific connection.

Chat owns contextual recovery cards and action lifecycle cards.

Permissions owns OS permission status and repair.

Settings owns account-level controls, privacy, and broad permission management.

Do not create a new screen when one of these owners can express the state with a
section, row, card, or sheet.

## Deterministic State Rule

The app must not rely on model inference to decide whether the user is paired,
authorized, or missing an OS permission. The model may infer and explain, but UI
state should come from:

- gateway pending and paired device records
- structured tool/action results
- platform permission APIs
- connector authorization state
- sanitized diagnostic classes

If the model says "not paired" but the gateway state says the runtime is paired,
the UI should trust gateway state and show the next real blocker.

## Portfolio Evidence Lanes

The relaunch evidence should show three related but separate flows:

1. New-user education: what Rem does and how to start.
2. Gateway recovery: how Rem explains and repairs a disconnected or unapproved
   cloud gateway.
3. Permission-to-action: how Rem asks for runtime approval, OS permission, or
   connector permission, then completes the action.

These flows can be demonstrated with fixtures when live accounts or gateways are
not reliable enough for repeatable recording.
