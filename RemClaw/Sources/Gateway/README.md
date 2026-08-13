# Gateway (iOS)

> The layer that keeps the iOS app connected to your personal AI server. It opens two persistent WebSocket connections — one so the AI can see and use your phone's capabilities (calendar, reminders, etc.), and one for chat. It handles reconnecting when you put your phone down, approving the device the first time, and routing tool calls to the right iOS handler.

Manages dual WebSocket connections to the OpenClaw gateway (node + operator sessions), credential storage, chat transport, and AI tool invocation routing.

## Architecture

The iOS app maintains **two** simultaneous WebSocket connections via `GatewayNodeSession` from OpenClawKit:

- **Node session** (`role: "node"`) — advertises device capabilities and handles AI tool invocations (calendar, reminders, tasks, etc.). Requires device pairing.
- **Operator session** (`role: "operator"`) — used for chat transport (`chat.send`, `chat.history`, `sessions.list`), skills config, and health checks. It advertises the upstream `tool-events` UI capability on both initial connect and reconnect so the same socket that sends a turn receives its live tool lifecycle; node capabilities cannot substitute for this connection-scoped handshake.

```
RemGatewaySessionManager (@Observable, @MainActor)
├── owns RemGatewayClient (actor, dual WebSocket)
│   ├── node session → NodeInvocationRouter (tool dispatch)
│   └── operator session → IOSGatewayChatTransport (chat UI)
├── persists credentials via RemCredentialStore
├── manages keepalive, reconnection, auto-approve flows
└── conforms to GatewaySessionProviding (via +Shared.swift)
```

## Device vs Runtime Pairing

The gateway can show more than one trust record. These are intentionally
separate, even though they both appear in Device Connections:

- **This iPhone / iOS device** — the Rem app's local node identity. This is the
  device that owns iOS permissions and can run phone-local actions such as
  reminders, calendar, notifications, microphone, and camera-backed flows.
- **Rem agent / runtime connection** — the gateway-side agent session that asks
  permission to invoke approved actions through the gateway. This can request
  pairing even when the iPhone row is already paired.

Copy rule: do not tell the user "your iPhone needs to be paired" when the
pending request is the runtime agent. Use "Rem agent" or "runtime connection"
for that row, and route the user to Device Connections so they can approve the
specific pending request. The iPhone row is still useful because it confirms the
phone itself is trusted; it does not prove that every runtime agent request has
also been approved.

## Key Files

| File | Purpose |
|------|---------|
| `GatewayClient.swift` | Actor managing dual WebSocket sessions with timeout handling, reconnection state, permissions snapshots, and health probing |
| `GatewaySessionManager.swift` | `@Observable` `@MainActor` class bridging the actor-based client to SwiftUI — connection lifecycle, keepalive, auto-approve pairing, exponential backoff reconnection |
| `GatewaySessionManager+Shared.swift` | `GatewaySessionProviding` conformance, enabling shared settings views across platforms |
| `NodeInvocationRouter.swift` | Central dispatcher routing gateway tool invocations to handlers for calendar, reminders, tasks, folders/lists, device status, notifications. Also the **single source of truth for advertised commands** (`advertisedCommands` / `advertisedCaps`) — `GatewayClient` advertises exactly what the registry implements (R1 / #810) |
| `Handlers/FoldersCommandHandler.swift` + `Handlers/ListsCommandHandler.swift` | Expose the same Folder → List hierarchy the human sees so the agent can discover and create durable task organization; creation IDs derive from the stable gateway invocation identity, and ambiguous/lost acknowledgements reconcile by exact ID before success |
| `Handlers/TasksCommandHandler.swift` | Validates List references and task status values before any managed-model mutation, single-flights concurrent redeliveries of the same stable task create, supports the advertised `completed` alias plus `blocked`, and conditionally rolls back only unchanged attempted fields after terminal update failure so newer local edits survive; results include human-readable List/Folder names. Also answers `tasks.search`, the read-only **name → task** lookup: the daily brief names tasks in prose and carries no ids, so without it `tasks.get` (UUID-only) and `tasks.list` (no title filter) leave the agent unable to account for an item in its own brief. Matching is title-only — never notes, which are untrusted in both halves — and tiered exact/prefix/contains/token so a title the brief reworded, decorated, or truncated still resolves, while a name the user does not have resolves to nothing |
| `RemChatTransport.swift` | `OpenClawChatTransport` conformance — handles chat send/history/sessions, event streaming, session key canonicalization, read-through merging of legacy and canonical task gateway histories, and emits exact raw execution lifecycle evidence before history run-ID rewriting. A quota-backed send acknowledges its opaque handoff only after gateway run acceptance. An active-dispatch registry keyed by session plus idempotency makes production `abortRun` wait for that acknowledgment and abort the exact accepted run, or suppress abort when send never starts; pending abort continuations have UUID ownership and unregister on cancellation so retired UI work cannot abort a later accepted run. A failed owner-cancellation abort propagates and retains the exact accepted mapping for a production retry. |
| `TaskChatTranscriptCoordinator.swift` | Resolves canonical `rem-task-<full UUID>` sessions to the backend task transcript, including after relaunch/session-list entry; task transcript failures propagate rather than rendering a valid-looking partial thread |
| `TaskChatHistoryMerge.swift` | Chronologically pairwise-merges cloud-run transcript turns plus legacy and canonical gateway continuation histories; handles epoch-second task turns, preserves stable source order for missing timestamps, and scrubs malformed timestamp metadata even when a directly opened legacy row has no merge partner. |
| `BrowserViewCoordinator.swift` | Owns the iOS cloud-browser session and gateway-token transport. Binds the minimal ended-card owner receipt to the authenticated account + normalized gateway, restores it on cold launch, and hard-tears down the socket and all retained runtime state at account/gateway/root boundaries. |

Browser takeover is asymmetric by design: taking control only aborts the active run, while giving
control back starts a hidden `chat.send` continuation. `ContentView` therefore asks
`BrowserHandBackCoordinator` to bind one opaque persisted reservation and one stable send idempotency key to the
captured account, gateway credentials, operator generation, and still-current browser-owning conversation.
The stable authority also carries monotonic account, gateway-credential, and browser-owner lifecycle
tickets, so an A -> B -> A replacement cannot compare equal and revive an old attempt.
`BrowserLiveSession` transfers control only after the hidden send is accepted. Quota denial,
unavailable authority, session replacement, and send failure keep the user in control with
truthful recovery. Gateway acceptance retires only that exact reservation. An authority change
before dispatch records the charged cancelled-before-dispatch disposition, while an ambiguous send
retains the token and retries only the same idempotent gateway dispatch instead of reserving again.
The wire-start callback occurs after transport preflight; an accepted run is terminal for that
hand-back even if cancellation, reconnect, or abort cleanup races with the normal return, so it
cannot reserve or dispatch again. A post-wire failure across an operator reconnect retains the
exact token and idempotency key under the stable account/gateway/browser-owner scope, then rebinds
only the fresh operator generation before retrying the same dispatch when every lifecycle ticket is
unchanged. Account, credential, or browser-owner replacement never inherits or retires that ambiguous attempt.
A hand-back waiting for an older takeover RPC has not claimed coordinator state; if its captured
authority expires during that wait, it returns without invalidating a newer hand-back attempt or tombstone.
| `RemCredentialStore.swift` | Credential management: connection tokens in Keychain (`app.remclaw` service), URLs in UserDefaults; successful authenticated gateway refreshes fail closed while scrubbing the retired device-cached Voice provider key |
| `KeychainStore.swift` | Thin Security framework wrapper for Keychain read/write/delete, including throwing deletion for security-boundary migrations |
| `GatewayClientProtocol.swift` | `GatewayServerProvider` protocol and concrete providers (Railway, Fly.io) for gateway URL resolution |
| `DeviceCommandTypes.swift` | Command enums and Codable payload structs for calendar, reminders, device, and task gateway commands |

## Patterns & Conventions

- **Actor isolation**: `RemGatewayClient` is an `actor` for thread-safe concurrent session management. `RemGatewaySessionManager` runs on `@MainActor` for SwiftUI reactivity.
- **Config activation acknowledgement**: managed config saves accept only backend responses with
  `ok: true` and `activated: true`. The backend/wrapper return that receipt after restart and
  authoritative readback; the legacy immediate `{restarting:true}` response is treated as failure.
- **Managed Voice recovery budget**: the shared 600-second client timeout outlives the backend's
  roughly 490 seconds of explicit Fly wake, health proof, activated config patch, fail-fast
  ownership checks, and Talk RPC work, with more than 100 seconds of scheduling margin.
  Never shorten one platform independently: abandoning the HTTP request does not prove the backend
  stopped mutating the gateway.
- **Managed Voice auth authority**: capture the initiating JWT/account before launching recovery.
  Navigation cancellation detaches only the UI waiter; if authentication changes while the retained
  request runs, its token refresh or failure must never publish into or sign out the new account.
- **Keepalive probing**: Periodic health probes detect silently-dropped WebSocket connections that don't fire disconnect callbacks. **Requires TWO consecutive missed probes before reconnecting** — a single slow `health` response under load is not proof the socket dropped, and reconnecting on the first miss turned transient blips into a reconnect feedback loop. The miss counters live inside the keepalive `Task`, so only one loop ever holds them (`stopKeepalive()` cancels the prior).
- **Operator RPC identity**: `operatorSessionGeneration` advances before replacing credentials or
  sockets and on ready-state edges, so async auth evidence cannot cross same-URL token/account swaps.
- **Model-catalog wire truth**: `catalogComplete` is tri-state. `true` is complete, `false` is
  incomplete, and a missing field from a legacy gateway remains unknown rather than being promoted
  to either claim.
- **Reconnect coalescing**: All reconnect triggers (foreground flap, keepalive, grace-period retry, backoff ladder) route through a single `ReconnectCoalescer` (`Shared/Gateway/`) so they can't stack N concurrent node+operator socket pairs — the mechanism behind the observed connection churn. It is self-expiring (a stuck in-flight flag can never wedge reconnection past `safetyExpiry`). Manual/foreground reconnects pass `debounce: true` (collapse rapid flaps); the ladder/keepalive path passes `debounce: false` (in-flight guard only, so a scheduled backoff isn't swallowed). **Escalation paths inside a held reconnect `await performReconnectAwaitingSettle()`** (which claims no coalescer slot of its own), so the owner keeps its token until the fallback reconnect *settles* — closing the free-slot window where a concurrent trigger could otherwise stack a second socket pair. Release is generation-token-guarded (`begin()` returns a token; `end(token)` frees the slot only if that token still owns it), so a stale post-settle release can't free a newly-claimed slot.
- **Close-before-open**: Every reconnect fully closes the existing node/operator socket(s) before opening replacements (`reconnectNode`/`reconnectOperator`/`disconnect` all `disconnect()` first; `connect()` tears down any live session on a connect-on-top path). This prevents accumulating orphaned sockets.
- **Connection-churn logging**: `RemGatewayClient` logs every WebSocket OPEN/CLOSE/DROP via an always-on `os.Logger` (`subsystem com.remclaw`, `category gateway-conn`) with the trigger label (`foreground`/`keepalive`/`backoff`/`grace`/`manual`/…), session role, and a running `live=` socket tally. Steady state is `live=2`; a persistent climb signals a socket leak. This is the evidence trail for diagnosing the next churn — filter device logs on `gateway-conn`.
- **Reconnection backoff**: 2s → 4s → 8s → 16s → max 30s with jitter. Counter resets on successful connection.
- **Auto-approve pairing**: On "pairing required" disconnect, calls `POST /api/v1/approve-device` then reconnects only after a successful backend result. Automatic recovery is bounded to one retry; hard request/setup failures stop and leave the visible manual recovery action available instead of creating an approval/reconnect storm.
- **Session key canonicalization**: `RemChatTransport` strips `agent:{id}:` prefixes from session keys for UI compatibility.
- **Task execution-thread identity**: Task chats write to `rem-task-<full task UUID>` before and after the first agent run, matching the backend stamp. On every canonical history load, the transport also directly reads and merges the deterministic legacy `task-<12>` gateway history; it never infers absence from the async/top-50 session-list cache. Selecting a visible legacy row redirects to the canonical conversation when exactly one loaded task matches its truncated key; deleted or ambiguous legacy rows remain directly readable. Fully-qualified `agent:main:` keys retain that namespace for the legacy read alias. The UUID remains reversible after relaunch, so transcript hydration never depends only on an in-memory session mapping.
- **Latency diagnostics route by run**: The Debug-only `--rem-chat-latency-sample` launch argument enables `[ChatLatency]`. OpenClaw captures preparation start synchronously so diagnostics never block the optimistic bubble, then reports markers separating optimistic append and pending model-patch wait from transport work. `chat.send` correlates its idempotency key to the acknowledged `runId`; chat and agent events must match both that run and the structured `sessionKey`. A bare app key may alias only the primary `agent:main:` canonical namespace; canonical identities for other agents fail closed even when their chat suffix matches. Bounded terminal tombstones stop deduplicated responses from reviving completed runs. A five-minute TTL is applied opportunistically on later store activity, while hard caps strictly bound orphaned traces. Final/aborted/error and explicit abort paths remove the exact run. Ordinary launches skip trace allocation and the secondary metadata decode.
- **Run lifecycle identity**: Activity ownership uses the raw gateway `(sessionKey, runId)` from
  structured agent/chat events. Emit activity evidence before rewriting agent run IDs to history
  session IDs; register the exact run ID returned by local `chat.send` before agent activity; only
  matching `final`, `error`, or `aborted` chat events terminate that execution. Each event-stream
  subscription advances a generation from the persistent lifecycle store's source. Transport
  replacement retires the old lease before suspension, so an old transport cannot issue a new
  subscription generation or rotate lifecycle authority back; delayed old evidence cannot restore
  or clear current lifecycle state.
  Missing identity fails closed until the user switches conversations—never infer completion from
  transcript ordering, timestamps, or view reconciliation.
- **Chat transport binding**: The chat view model must be recreated when the
  active gateway URL, main session key, or iOS device identity changes. A stale
  transport can make chat tools report "pairing required" even after the visible
  gateway detail appears connected. Async factory completion is commit-gated:
  only the latest desired binding may install while operator readiness remains
  true, and disconnect/operator loss invalidates any construction still awaiting.
- **Post-approval reconciliation**: After a pending runtime/device request is
  approved, force-refresh pending devices and reconnect gateway sessions. The
  gateway can accept approval while the existing chat transport still holds a
  pre-approval session. A user-facing completion message additionally requires
  a newer node connection generation plus operator readiness, so an old coarse
  `.connected` state cannot falsely complete **Finish Connection**.
- **Approval is not just list state**: Treat a successful approve action as
  three follow-up chores: refresh pending devices, refresh linked devices, and
  re-bind the active chat session's `execNode` to this phone before reconnecting.
  Otherwise Device Connections can look resolved while chat still reports
  `pairing required before node invoke` on the next message.
- **`@Sendable` callbacks**: Gateway callbacks use `@Sendable` closures; `RemChatTransport` uses `@unchecked Sendable` with `NSLock`.
- **Advertise from the registry**: The node's `commands`/`caps` are generated from `NodeInvocationRouter.advertisedCommands` (not a hand-maintained list), so the agent is only ever offered commands this device implements — no drift, no hallucinated "unknown command" path (R1 / #810).
- **Mutating organization commands are retry-idempotent**: `folders.create` and `lists.create` derive their resource UUID from `(command, invocation id)`. If a POST acknowledgement is lost, the API client reconciles the exact backend ID and the handler upserts that canonical row locally; it never guesses by name or creates a second resource on retry.
- **Task filing is part of task durability**: `list_id` travels in task POST/PATCH payloads and `PendingTaskOperation` snapshots only when create or update actually owns the assignment; unrelated updates omit it through replay so a stale cached List cannot poison another field's edit. Backend ownership validation is atomic with the task write; transient failures retain one replayable intent, while terminal 4xx failures conditionally roll back the attempted fields and surface an error without clobbering newer local edits.
- **Terminal vs retryable errors**: Unknown-command and permission-denied return `OpenClawNodeError` with `retryable: false` and an explicit "Do not retry" message, so the agent stops looping on calls that can never succeed (R2-A / #811). See `InvocationHelpers.unknownCommand` / `.permissionDenied`.
- **Permissions snapshot**: Permissions checked once at connection time, sent as static map. Must reconnect to refresh.
- **`clientId: "openclaw-ios"`**: Do not change — the gateway recognizes this client type.
- **Structured agent context**: Never prepend device metadata to chat text. The `openclaw-ios`
  handshake registers client/device identity, the nodes tool exposes live device capabilities,
  and the backend mirrors `users.timezone` into OpenClaw's `agents.defaults.userTimezone` so
  upstream can add time context to `BodyForAgent` without changing the visible transcript.
- **Shared connection state**: `GatewayConnectionState` lives in `Shared/Protocols/GatewaySessionProviding.swift`; iOS uses the `RemGatewayConnectionState` compatibility typealias from `Shared/Protocols/GatewaySessionConformance.swift`.
