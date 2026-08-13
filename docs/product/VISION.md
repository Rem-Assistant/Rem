# Rem Product Vision

Rem is a personal AI app for conversational day planning and execution. A user
captures an intent in chat, voice, Agenda, or another low-friction surface; Rem
helps turn it into a task, event, note, connector action, or gateway-executed
step.

The intent behind every interaction is to **orient the human**: take the mess of
someone's life and turn it into structured, scheduled, worked tasks, then keep
them on track without making them manage it. The **task is the persistent
object**; the conversation that produced it is fleeting. Rem orients and offloads
the human — it organizes the work, does the work, and reports back — so the user
spends their attention deciding what matters, not administering a tool. This is
task-centric human–agent collaboration, and the rest of this document is how it
plays out interaction to interaction.

The iPhone is the primary user surface: fast capture, chat, voice, agenda, inbox,
settings, and permission control. The Mac is not merely a companion app. It is a
first-class Rem app and the preferred gateway host for local context and
computer control. The backend helps with identity, billing, gateway provisioning,
and metadata, but it should not become the user's computer, memory, or tool
runtime.

This document supersedes the older hackathon framing in
[architecture/system-design.md](../architecture/system-design.md). Keep the
hackathon docs for history and implementation archaeology; use this file for
product decisions. It was created from the product direction in
[issue #402](https://github.com/Rem-Assistant/RemClaw/issues/402).

## Product Promise

Rem should feel like one private assistant that can follow the user across phone
and Mac:

- Capture an intent quickly, then help the user organize or start the work
  instead of leaving it as a chat transcript.
- Use Calendar as timed context, Tasks as executable intent, and Agenda as the
  daily planning surface that makes both understandable.
- On the phone, ask for help in natural language without thinking about where a
  tool lives.
- At home or on a trusted network, let the phone route work to the Mac through
  explicit, permissioned capabilities: inspect local context, read/write allowed
  files, use the clipboard, run approved commands, and report results back.
- Away from home, keep working when the gateway is reachable through a cloud
  gateway, LAN, Wake-on-LAN plus reconnect, or a future tailnet path.
- Make integrations easy for normal users through Connectors first, while still
  exposing MCP as the advanced substrate for custom tools and open-source
  extension.
- Keep enough product and architecture context in the repo that future
  contributors can understand Rem without relying on chat history.

## Primary Surfaces

### iOS App

The iPhone app is the everyday command surface. It owns quick capture, chat,
voice, agenda and inbox workflows, account settings, permissions, gateway
selection, linked devices, and connector setup. It may advertise iOS-local
capabilities such as Calendar, Reminders, Tasks, notifications, device status,
and voice input to the gateway.

The phone should not need to know whether a capability is implemented locally, on
the Mac, in a cloud connector, or through MCP. It should show clear permission
and connection state, then route the request through the active gateway.

### Mac App

The Mac app is a first-class Rem app and gateway host. It should be usable on its
own, live comfortably in the menu bar, and expose Mac-only capabilities that make
remote control valuable: shell commands, file access, clipboard access, app and
screen context, local project state, and future visual investigation.

The Mac app also owns local gateway lifecycle for users who want their own Mac to
be the assistant runtime. It should make status, pairing, logs, restart, and
remote access setup understandable instead of hiding a fragile daemon behind the
scenes. See [MAC_GATEWAY_TROUBLESHOOTING.md](../MAC_GATEWAY_TROUBLESHOOTING.md)
for current dogfooding failure modes.

### Gateway

The gateway is the routing and agent runtime. It accepts operator sessions for
chat/control and node sessions for device capabilities. A Rem device connects as
a node when it can perform tools; it connects as an operator when it sends chat,
lists sessions, manages skills, or drives the agent.

Current implementation details are documented in
[CONNECTION-ANALYSIS.md](../CONNECTION-ANALYSIS.md) and
[RemClaw/Sources/Gateway/README.md](../../RemClaw/Sources/Gateway/README.md).
The important product idea is simpler: Rem devices pair with a gateway, advertise
what they are allowed to do, and receive invocations only for approved
capabilities.

### Backend

The backend exists for product infrastructure: authentication, user profile,
billing/subscription state, gateway provisioning, gateway metadata, connector
account metadata, pairing assistance, and other account-level APIs. It should not
proxy normal conversations or become the durable owner of local computer state.

The backend can help a user acquire or wake a cloud gateway, store encrypted
gateway credentials, and restore configuration after sign-in. User-visible
assistant work should still route through a gateway.

## Core Jobs To Be Done

- Capture a thought on the phone and turn it into a task, event, note, or action.
- Plan the day conversationally by combining Calendar context, Tasks, Agenda,
  and the user's current intent.
- Start execution from an intent: schedule it, draft it, route it to a
  Connector, or ask a gateway/device to perform the approved next step.
- Ask the assistant to use local personal context, with explicit permission and
  visible account/gateway state.
- From the phone, tell the Mac at home to do approved work and return a concise
  result.
- Continue a session across text and voice without losing context.
- Connect a new device or gateway without needing to understand OpenClaw internals.
- Recover from common network and pairing failures without manual terminal work.
- Let advanced users add custom capabilities without making the default product
  feel like a developer tool.

## The Operating Loop — Orient the Human

The product spine is not "chat with tools" by itself. It is the loop from real
life into organized, executable work — the mechanism by which Rem orients the
human:

```text
Capture intent
  -> orient: turn it into structure (tasks, sub-tasks, areas, schedule)
  -> work: create, do, close, and keep updating the task
  -> brief: roll the latest runs into one daily update
  -> repeat: routines run the loop on a cadence
```

The loop runs in five beats, and each beat is a deliberate product stance:

1. **Capture.** Rem learns the user's goals up front, through a conversational
   onboarding — "what should we call you," "what are you working on" — rather than
   a settings checklist. This is a deliberate divergence from OpenClaw's
   gateway-setup onboarding: the first conversation is about the human's life, not
   about wiring a daemon. Capture continues forever after onboarding, through
   every low-friction surface, but the goal is always the same — get real-life
   intent into Rem before it evaporates.

2. **Orient.** Captured input is turned into structure: tasks, sub-tasks, areas
   and grouping, scheduling, and time-blocking. This is where the mess becomes a
   plan. For it to work, the agent must know how to *use the app as a task
   manager* — not just answer questions, but file, schedule, and group work the
   way the product's own task model expects. Orienting the human is the job;
   structure is how it is delivered.

3. **Work.** The agent does not stop at creating a task. It works the task,
   closes it, and — critically — keeps updating it as it goes, recording progress
   in the task's Activity log. The persistent task carries its own history because
   the human does not come back to manage it. The point of offloading is that the
   user can stay gone; the task stays current without them.

4. **Brief.** Updates do not arrive as ten notifications. They roll up into **one
   daily brief** — a morning orientation and an end-of-day sign-off — that is the
   single update surface. The brief is dynamic: it reflects the latest runs at the
   moment it is read, not a queue of stale alerts. One dependable surface keeps the
   human oriented without making them triage their own assistant.

5. **Repeat.** Routines are the engine that runs this loop on a cadence. A small
   set of base-default habits — daily tracking, the morning and end-of-day
   sign-off — ship on by default so the loop delivers value on day one, before the
   user has configured anything. Routines are what make Rem proactive rather than
   merely responsive.

Calendar is timed context: what is happening, when the user is available, and
which moments should trigger reminders or proactive help. Tasks are executable
intent: what the user wants to do, what can be started now, and what needs a
future time or dependency. Agenda is the planning surface that brings those
together across iOS and Mac.

Capture surfaces can expand over time: voice, widgets, wearables, glasses,
camera/video, shared sheets, and future ambient contexts should all reduce the
friction of getting real-life intent into Rem. They should still land in the
same product loop rather than creating separate islands.

Calendar should be treated as a first-class Connector in Settings even when the
first implementation is native EventKit. The user-facing concept is: "Rem can
use the calendars available on this device." Provider calendars such as Google
Calendar belong with Provider Connectors so one Google connection can unlock
Gmail, Calendar, Drive, Docs, Sheets, Slides, and related Google capabilities
without repeating sign-in concepts inside the local Calendar permission view.

## Remote-Control Architecture

The north-star path is:

```text
iPhone request
  -> active gateway operator session
  -> agent chooses an approved capability
  -> Mac node session receives the invocation
  -> Mac performs the action locally
  -> result streams back through the gateway to the phone
```

Examples:

- "On my Mac, summarize the README in the project I was editing."
- "Copy the latest build log from the Mac and tell me the failure."
- "Wake the Mac, connect when it is reachable, then run the approved status check."
- "Look at the active window and help me debug what is on screen."

The capability boundary matters. The phone should never gain raw, ambient control
over the Mac. The desired model is that it asks the gateway to invoke specific
capabilities that the Mac advertised and the user approved. Mac capabilities
should have clear scopes, auditable logs, and product-level names that make sense
to a user.

Current safety gap: the Mac app already exposes powerful local capabilities such
as shell, files, and clipboard through the gateway path. Treat the stronger
approval, scoping, and audit UX as product work still required before Rem can
honestly claim phone-initiated Mac control is fully permissioned for normal
users.

The iOS/Mac capability split is audited in
[IOS_MAC_PARITY.md](../IOS_MAC_PARITY.md). Treat that file as an implementation
inventory; this vision doc owns product direction when the two drift. Remote Mac
access work is tracked from
the transport model introduced for
[issue #317](https://github.com/Rem-Assistant/RemClaw/issues/317), and connection
reliability dogfooding is tracked in
[issue #361](https://github.com/Rem-Assistant/RemClaw/issues/361).

## Local, Cloud, LAN, and Tailnet Gateways

Rem should support more than one way to reach a gateway because users have
different privacy, reliability, and networking needs.

| Model | Product meaning | Typical use |
|-------|-----------------|-------------|
| Local Mac gateway | The user's Mac hosts the gateway and local capabilities. | Best privacy and deepest Mac control when the Mac is reachable. |
| Cloud gateway | A Fly/Railway-style gateway reachable from anywhere. | Easiest onboarding and useful fallback for cloud/gateway-hosted work. It does not replace Mac-local shell, files, clipboard, or screen capabilities when the Mac node is offline. |
| LAN / Bonjour | The phone discovers a nearby gateway on Wi-Fi. | Home or office use without public exposure. |
| Wake-on-LAN | The phone sends a magic packet, then reconnects when the Mac wakes. | "My Mac is asleep at home; wake it and retry." Reliability varies, especially over Wi-Fi. |
| Tailnet / Tailscale | The Mac exposes the gateway on a private tailnet address. | Future away-from-home local-Mac access without a public gateway. |
| SSH tunnel / manual URL | Advanced escape hatches for custom routing. | Power users and development setups. |

The code models deployment and reachability separately:

- `GatewayProvider`: where the gateway lives, such as Fly, local Mac, or manual.
- `GatewayTransport`: how the client reaches it, such as Bonjour, Tailscale,
  SSH tunnel, or manual URL.

See [Shared/Gateway/GatewayTransport.swift](../../Shared/Gateway/GatewayTransport.swift)
for the current transport vocabulary.

## Settings, Connectors, and Gateways

Settings should teach the product hierarchy without exposing implementation
plumbing first.

The detailed IA decision for Connectors, Capabilities, Skills, MCP, Connected
Accounts, and Gateways lives in [CAPABILITIES_IA.md](CAPABILITIES_IA.md). When
there is ambiguity, use that file for implementation slicing and this section
for the product direction.

### Connected Accounts

Connected Accounts are user identity and account-linking relationships. Examples
include signing in with Apple or Google, subscription ownership, and OAuth
relationships that let Rem know which external account belongs to the user.

Connected Accounts answer: "Who is this user, and which services have they
authorized Rem to access?"

They are not the same as a gateway. They also are not the same as a specific tool
implementation.

Implementation note: a Connected Account can provide credentials that a Connector
uses, and those credentials may be stored or synced through gateway-owned state.
That does not make the account itself a capability. The product should keep
identity, authorization, execution, and tool UX visually distinct.

### Connectors

Connectors are the user-friendly integration product. A Connector should have a
name, icon, authorization state, permission summary, health state, and clear
actions like Connect, Disconnect, Refresh, or Manage. Google Calendar, Gmail,
Notion, GitHub, local files, and Mac capabilities should feel like Connectors to
the user even if their implementation differs.

Connectors answer: "What can Rem use for me?"

Default product work should be described and shipped as Connectors, not as raw
MCP configuration.

### MCP

MCP is the advanced/custom substrate for tools and context servers. It is useful
for developers, open-source contributors, and power users who need custom
capabilities. MCP can be how a Connector is implemented, but MCP should not be
the first concept a normal user sees.

MCP answers: "What protocol can advanced integrations use?"

Expose MCP where it helps inspect, debug, or extend Rem. Do not make a user learn
MCP just to connect a common app.

### Gateways

Gateways are the execution and routing homes for assistant sessions. A user can
have a cloud gateway, a Mac-hosted gateway, or both. Gateway settings should show
where each gateway lives, how it is reached, whether operator and node sessions
are healthy, which devices are paired, and which capabilities each device
advertises.

Gateways answer: "Where does Rem run this work, and which devices can it reach?"

A gateway is allowed to route requests to local nodes, cloud connectors, and
MCP-backed tools, but the user should understand routing in terms of gateway and
device health rather than raw protocol names.

The settings hierarchy should roughly be:

```text
Settings
  Account
    Connected Accounts
    Billing
  Connectors
    User-friendly integrations and permissions
    Advanced MCP/custom tools
  Gateways
    Cloud gateways
    Local Mac gateways
    Linked devices
    Reachability: LAN, Wake-on-LAN, tailnet, tunnel, manual URL
  Permissions and Privacy
```

## Visual QA and Visual Investigation

Visual QA is part of the engineering operating model, not an optional polish
pass. When a change affects Mac or iOS UI, agents should build/run the target and
capture evidence with the available simulator, Peekaboo, screenshot, or browser
tooling. Keep screenshots in task-specific folders when they are useful for
future debugging; see [PEEKABOO_SETUP.md](../PEEKABOO_SETUP.md) and
[ORCHESTRATION.md](../ORCHESTRATION.md).

Visual investigation is also a product capability. A remote Mac assistant should
eventually be able to inspect user-approved screen/app context, describe what it
sees, and use that context to help with debugging, document work, app workflows,
and setup tasks. This should be treated as a permissioned Mac Connector with
clear user controls, not as hidden surveillance.

## Open-Source and Community Posture

Rem should be understandable enough to open source later:

- Product decisions belong in docs, issues, and PRs, not private chat history.
- Local setup should converge toward one reliable path for iOS, Mac, backend,
  gateway, and connector development.
- Advanced extension points should be documented as MCP/custom Connector
  substrate, while default user paths stay productized.
- Security-sensitive behavior should have explicit scopes, logs, and docs before
  community contributors are expected to modify it.
- Hackathon-era docs should be preserved where useful, but new work should link
  back to current product docs instead of copying stale assumptions.

## Non-Goals

- Rem is not a generic remote desktop product. It should execute approved
  assistant capabilities, not stream arbitrary control by default.
- The backend should not become the normal conversation proxy or durable owner of
  local computer state.
- MCP should not be the primary user-facing integration model for common apps.
- The Mac app should not be treated as an invisible helper whose only job is to
  keep a daemon alive.
- Cloud gateways should not erase the local-first Mac path; they are onboarding,
  reliability, and fallback infrastructure. They keep cloud/gateway-hosted work
  reachable, but Mac-local capabilities degrade when the Mac node is offline.
- Wake-on-LAN should not be promised as universally reliable. It is one
  reachability tactic with hardware, network, and sleep-state constraints.

## Open Questions

- What is the minimum safe approval UX before enabling shell, file write, and
  screen inspection from phone-initiated requests?
- Which Mac capabilities should ship as default Connectors, and which should
  remain MCP/custom-only until trust and audit UX are stronger?
- How should Rem rank cloud vs local Mac gateways when both are reachable?
- What logs should users be able to inspect for remote-control actions?
- How much backend metadata should exist for Connectors without making the
  backend responsible for executing the connector's work?
- What is the first supported tailnet path: Tailscale Serve, another tailnet, or
  a generic manual URL flow?
- Should the Mac app expose a "home gateway" mode distinct from normal signed-in
  app usage?
- Which parts of the existing hackathon docs should be retired, rewritten, or
  explicitly marked historical?
