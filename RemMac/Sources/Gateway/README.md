# Gateway (macOS)

> The macOS equivalent of the iOS Gateway. Connects Rem for Mac to your AI server with two WebSocket connections: one lets the AI run shell commands, read/write files, and access the clipboard on your Mac; the other powers the chat interface. Also handles Apple/Google sign-in and token refresh directly (unlike iOS where auth is in Services).

Manages dual WebSocket connections to the OpenClaw gateway for Rem for Mac, plus authentication, credential storage, and AI tool routing. The app is a normal Dock app with a menu bar extra; gateway lifecycle code should not assume a menu-bar-only agent.

## Architecture

The macOS app mirrors the iOS dual-session pattern with macOS-specific capabilities:

```
MacGatewaySessionManager (@Observable, @MainActor)
├── owns MacGatewayClient (dual WebSocket)
│   ├── node session → MacNodeInvocationRouter (shell, clipboard, files, calendar)
│   └── operator session → MacChatTransport (chat UI)
├── handles Apple Sign-In + Google OAuth (PKCE)
├── manages keepalive, sleep/wake reconnection, auto-approve
├── persists credentials: Keychain (app.remclaw.mac) + UserDefaults
└── conforms to GatewaySessionProviding (via +Shared.swift)

LocalGatewayManager (@Observable, @MainActor) [+ LocalGatewayLifecycle ext]
├── detects + installs the `openclaw` CLI binary (~/.openclaw/bin/openclaw)
├── spawns the gateway as a CHILD PROCESS bounded by app lifetime (post-#383)
│   └── stdout/stderr → ~/Library/Logs/RemClaw/local-gateway.log
├── reads/writes ~/.openclaw/openclaw.json (mode, bind, port, auth.token)
├── reads/writes ~/.openclaw/agents/main/agent/auth-profiles.json (BYOK)
└── runs LaunchAgentSecretsMigrator at app launch (defensive scrub of #383 plist)
```

## Key Files

| File | Purpose |
|------|---------|
| `MacGatewayClient.swift` | Dual-session gateway client — node session advertises shell, clipboard, files, screen capabilities; operator session handles chat |
| `MacGatewaySessionManager.swift` | Main session manager (~940 lines): Apple/Google auth, backend API calls, JWT refresh, auto-approve pairing, gateway deployment, exponential backoff reconnection, sleep/wake handling, linked devices, multi-gateway support |
| `MacQuotaService.swift` | Fail-closed text/Talk Mode request reservation. Captures the exact Mac auth authority, scopes current remaining quota and ambiguous retry blocks to account + backend, and never infers a Free plan from missing billing data. Cached zero evidence schedules an observable UTC reset invalidation; after expiry, its retained source summary cannot be used to locally re-lock text or voice. |
| `MacNodeInvocationRouter.swift` | Routes AI tool calls to macOS handlers: `system.notify` (UNUserNotificationCenter), `system.which`, `shell.exec` (zsh with timeout), `clipboard.read/write`, `files.read/write/list`, `calendar.events/add/update/delete` |
| `MacCalendarGatewayService.swift` | EventKit adapter for Mac node calendar commands, including permission-denied and read-only Calendar errors |
| `MacChatTransport.swift` | `OpenClawChatTransport` conformance — chat operations, model catalog and session model/thinking mutations, session key canonicalization, exact raw execution lifecycle evidence before history run-ID rewriting, request-scoped transcript-derived title/preview enrichment for cross-device Sessions parity, label→displayName mapping, event filtering, and DEBUG-only `[MacMemoryDiagnostics]` counters for #601 dogfood memory investigations. The model catalog feeds both the Mac composer and the bounded provider-auth availability probe; do not let the protocol's throwing default hide every non-managed provider. |
| `KeychainStore.swift` | Thin Security framework wrapper (same API as iOS version) |
| `MacBYOKKeychain.swift` | BYOK provider-key accessors (Keychain `app.remclaw.mac`); currently `byok.gmi.apiKey` for the GMI AgentBox runtime |
| `MacGatewaySessionManager+Shared.swift` | `GatewaySessionProviding` conformance for shared settings views |
| `LocalGatewayManager.swift` | Local-gateway lifecycle: CLI detect/install, child-process spawn, health checks, BYOK key writes, setup-code helpers |
| `LocalGatewayLifecycle.swift` | Consolidated state struct (`LocalGatewayLifecycleState`) + restart/configure/reset surface; `refreshState()` is the single read-side entry point |
| `LocalGatewayDiscovery.swift` | mDNS browse for `_openclaw-gw._tcp` so the iOS app can find this Mac's gateway on the LAN |
| `LocalGatewayEnvironment.swift` | SwiftUI `@Environment` key for the manager |
| `LaunchAgentSecretsMigrator.swift` | Migration that scrubs the legacy `app.remclaw.mac.gateway.plist` (#383, #384) whenever it is found — see "Lifecycle ownership" below |

## Patterns & Conventions

- **All types prefixed with `Mac`** to distinguish from iOS/shared variants.
- **Sleep/wake handling**: Observes `NSWorkspace.willSleepNotification` / `didWakeNotification` — stops keepalive on sleep, reconnects on wake (2s delay for network startup).
- **Authentication**: Supports both Apple Sign-In and Google OAuth with PKCE flow. JWT expiry detection decodes payload to check `exp` claim (60s buffer).
- **Billing truth**: Every Billing entry revalidates the usage summary. Loading replaces cached values with a layout skeleton; a failed refresh marks any retained payload stale and shows an unavailable/retry state instead of presenting it as current. Only a newly decoded backend `UsageSummary` may name the current plan or quota. Usage requests capture backend URL, token, and a monotonic generation, so a delayed response cannot republish the previous account after sign-out, token replacement, account change, or a newer retry. The session manager is also the single refresh-commit owner for its cache and Keychain: credential transitions persist first and publish cache/generation only after success, while save/delete failure leaves the prior authority coherent and surfaces recovery. The centralized HTTP client captures exact credential authority for refresh commits and a separate account generation for response publication: proactive and reactive refreshes deduplicate on the exact credential, a successful same-account refresh does not discard an already-authorized response, a late 401 reuses an already-refreshed same-account credential instead of refreshing the obsolete token, and sign-out/account/backend replacement still retires delayed responses. Profile publication uses the same gate before updating memory or its UserDefaults cache.
- **Request reservation truth**: Text chat and Talk Mode share `MacQuotaService`. Each user request consumes `/api/v1/usage/consume` before dispatch through an exact captured `MacBackendAuthAuthority`. A structured 429 is a quota denial; unavailable authority and definitely rejected auth/client responses fail closed with retry copy. Transport, 5xx, cancellation, or account replacement after a possibly committed response persist an account/backend-scoped ambiguity block so neither surface can replay and double-count it. Every accepted HTTP 200 also creates a durable UUID reservation token bound to its account, backend, and ordered dispatch context. Text transport and Talk Mode retain that token until `chat.send` returns the exact accepted run ID; if a Talk Mode turn loses speech authority after the committed 200 but before dispatch, it retires only that exact local handoff while the backend unit remains truthfully charged. Text `abortRun` joins the active `(sessionKey, idempotencyKey)` boundary: cancellation before the detached worker starts prevents a later send, while cancellation after it starts waits for run acceptance, retires the exact token, then aborts only that run. A bounded resolved tombstone aliases the local idempotency key and accepted gateway run ID to the same exact acknowledgement and abort disposition, so either identifier stays exact and deduplicated after outer send completion; failed abort attempts propagate and remain claimable for retry. Route/account replacement, relaunch, or process termination before run acceptance remains fenced. Unknown/stale summaries reach this backend gate and never authorize a Free-plan claim.
- **Shell execution**: `MacNodeInvocationRouter` uses `Process` API to run zsh commands with configurable timeout and stdout+stderr capture.
- **Credential storage**: Gateway token in Keychain (service `app.remclaw.mac`), gateway URL in UserDefaults. Includes migration from legacy UserDefaults token storage.
- **Managed Voice recovery budget**: managed-cloud reconciliation shares the 600-second request
  timeout with iOS so the client outlives the backend's roughly 490 seconds of explicit Fly wake,
  health, activated patch, fail-fast ownership, and Talk RPC work plus scheduling margin.
- **Managed Voice auth authority**: the retained recovery captures its JWT/account before task
  creation. Leaving the view detaches its waiter, while a later account change blocks that request
  from publishing refreshed credentials or signing out the new account.
- **Keepalive**: 20-second probe interval to detect silently-dropped connections.
- **Operator RPC identity**: `operatorSessionGeneration` advances before replacing credentials or
  sockets and on ready-state edges, so async auth evidence cannot cross same-URL token/account swaps.
- **Model-catalog wire truth**: `catalogComplete` is tri-state. `true` is complete, `false` is
  incomplete, and a missing field from a legacy gateway remains unknown rather than being promoted
  to either claim.
- **Provider-auth truth**: Cloud, manual, and local routes all use the active gateway's structured
  `models.authAvailability` resolver. Raw `auth-profiles.json` membership remains refresh/display
  inventory only: it cannot resolve env/config keys, AWS SDK or synthetic auth, and cannot prove a
  stored token is unexpired or its secret reference resolves. An older local runtime without the
  structured method therefore fails closed and asks the user to update/reconnect.
- **Reconnection backoff**: 1s → 2s → 4s → 8s → max 30s with jitter.
- **Menu bar icon updates**: Connection state changes drive menu bar icon appearance.
- **Chat memory diagnostics**: DEBUG builds log `[MacMemoryDiagnostics]` summaries from
  `MacChatTransport` on history refresh, bounded stream pressure, and dropped
  `AsyncStream` yields. The logs intentionally include counts and payload bytes
  only, not chat text.
- **Chat latency diagnostics**: The Debug-only `--rem-chat-latency-sample` launch argument enables
  `[ChatLatency]`. Upstream captures preparation start synchronously so diagnostics never block the
  optimistic bubble, then reports markers separating optimistic append and pending model-patch
  wait from transport work. The send idempotency key is correlated to the acknowledged `runId`, and
  events must match that run plus the structured `sessionKey`. A bare app key aliases only the
  primary `agent:main:` namespace; another canonical agent with the same chat suffix fails closed.
  This prevents overlapping or cross-agent runs from overwriting or terminating each other. Bounded terminal tombstones
  prevent deduplicated responses from reviving completed runs. A five-minute TTL is applied
  opportunistically on later store activity, while hard caps strictly bound orphaned traces.
  Final/aborted/error and explicit abort paths remove the exact trace; ordinary launches skip allocation and the secondary
  metadata decode. No content or persistent public identifier suffixes are logged. Provider-side
  request-start/first-token timestamps are not available at this layer.
- **Run lifecycle identity**: Preserve raw `(sessionKey, runId)` from structured agent/chat events
  before rewriting agent run IDs for history routing, and register the exact run ID returned by a
  local `chat.send` before agent activity. The shared Activity UI closes only on a
  matching `final`, `error`, or `aborted` event; absent identity fails closed until session switch.
  Event-stream subscriptions advance a generation from the persistent lifecycle store's source.
  Transport replacement retires the old lease before suspension, so an old transport cannot issue a
  new subscription generation or rotate lifecycle authority back; delayed old evidence is ignored.
- **Chat transport binding**: Async factory completion is commit-gated. Only the latest desired
  gateway/session binding may synchronously create and install a model while the operator remains
  usable; aggregate node+operator connection state is not a chat-readiness gate. The setup ticket
  and lifecycle lease are captured together before task creation, and operator loss or window
  teardown invalidates any construction still awaiting.
- **Cross-device session metadata**: `MacChatTransport` mirrors the iOS enriched
  `sessions.list` request (`derivedTitle` + `lastMessagePreview`), keeps those fields on
  the decoded response through canonical-key normalization, and falls back to minimal
  parameters only when an older gateway returns `INVALID_REQUEST`. The Sessions view
  seeds its set-once local title only after accepting a conversation-backed response row,
  keeping cross-device replies stable without letting stale transport responses mutate caches.
  Large requested windows are assembled from bounded 100-row keyset-cursor pages; gateways
  that predate cursor support fall back to the legacy cumulative request.
- **Structured agent context**: Chat text stays equal to what the user sent. The
  `openclaw-macos` handshake registers client/device identity, live node capabilities come from
  the nodes tool, and cloud accounts receive the device timezone through OpenClaw's
  `agents.defaults.userTimezone`. Local gateways naturally use the Mac host timezone.

## Lifecycle ownership (post-#383, #384)

The Rem Mac app **does not install a LaunchAgent** for the local gateway. The gateway is spawned as a child `Process()` from `LocalGatewayManager.start()`, owned by the manager, and torn down when the user clicks **Stop** or quits the app.

Why this changed:
- Pre-#275 builds wrote `~/Library/LaunchAgents/app.remclaw.mac.gateway.plist` with `KeepAlive=true`, `RunAtLoad=true`, AND the user's `OPENAI_API_KEY` + `OPENCLAW_AUTH_TOKEN` in plaintext under `EnvironmentVariables` (#383).
- Even after we stopped embedding secrets (#275 delegated install to the upstream CLI), the LaunchAgent itself was invisible state the user couldn't manage from the app and couldn't disable without manual `launchctl bootout` + file deletion (#384).
- The child-process model makes "what's running where" inspectable from the app, prevents respawn loops, avoids conflict with upstream's own `ai.openclaw.gateway` plist, and ensures secrets never touch disk via env vars.

Power users who want background lifetime (gateway runs even when the app is closed) can install upstream's LaunchAgent themselves via `openclaw gateway install` — that path is intentionally not driven from the app.

## What OS state this folder touches

- **`~/Library/LaunchAgents/app.remclaw.mac.gateway.plist`** — legacy. Scrubbed at app launch by `LaunchAgentSecretsMigrator.runIfNeeded()`. Should not exist after first launch on a patched build, but the migrator checks for it even after the migration sentinel is set and leaves it on disk if any secret write fails. The migrator also handles the `.DISABLED` variant (manually disabled via the troubleshooting runbook).
- **Mac Keychain (service `app.remclaw.mac`)** — accounts:
  - `gateway.auth.token` — redundant copy of the gateway auth token (canonical home is `~/.openclaw/openclaw.json` `gateway.auth.token`).
  - `byok.openai.apiKey`, `byok.anthropic.apiKey` — redundant copies of provider keys (canonical home is `~/.openclaw/agents/main/agent/auth-profiles.json`).
  - `byok.gmi.apiKey` — GMI AgentBox / MaaS BYOK key (frozen contract `docs/agentbox/CONTRACT.md` §2). Written/cleared by `MacBYOKKeychain.gmiApiKey`; surfaced in Settings → Tasks & Cloud. Keychain-only — never a plist/config file.
  - Plus accounts owned by `MacGatewaySessionManager` for the cloud gateway token.
  - Plus accounts owned by `OAuthAccountStore` (#377) for MCP integrations.
- **`~/.openclaw/openclaw.json`** — gateway config, owned by upstream CLI. We read/write `gateway.mode`, `gateway.bind`, `gateway.port`, `gateway.auth.token`, `auth.profiles.*`.
- **`~/.openclaw/agents/main/agent/auth-profiles.json`** — BYOK provider keys (upstream-canonical location, format owned by `openclaw/src/agents/auth-profiles/types.ts`).
- **`~/.openclaw/devices/paired.json`** — paired devices list, read by `LocalGatewayLifecycle.gatherLifecycleSnapshot` for the Settings UI.
- **`~/Library/Logs/RemClaw/local-gateway.log`** — child gateway's stdout/stderr (created on `start()`).
- **`UserDefaults` (`launchAgentSecretsMigrated.v1`)** — sentinel bit set after `LaunchAgentSecretsMigrator` runs successfully, so subsequent launches are quiet when no legacy plist is present. A reappearing plist is still scrubbed.
- **`UserDefaults` (`local_gateway_token`)** — legacy key, cleared by `stop()`. New code paths don't write it.
- **`UserDefaults` (`rem.mac.usage.ambiguous-reservation-scopes.v1`)** — account/backend scopes whose consume result may have committed. Retained to prevent a later app launch from replaying and double-counting an ambiguous request.
- **`UserDefaults` (`rem.mac.usage.pending-reservation-dispatches.v1`)** — exact accepted reservation tokens awaiting a gateway-acknowledged `chat.send` run ID. Tokens include their account/backend and transport/turn context and survive cancellation, termination, or relaunch.

## Quick state check (for pairing / lifecycle debugging)

When pairing or local-gateway flows misbehave, the live state is split across launchd, `~/.openclaw/`, and the running process. These commands surface enough to root-cause most bugs without reading code:

```bash
# 1. Anything Rem-installed left in LaunchAgents? (Should be empty post-fix.)
ls ~/Library/LaunchAgents/ | grep -i 'remclaw\|openclaw'

# 2. Gateway process actually running?
pgrep -fl 'openclaw gateway run' || echo 'no gateway process'
lsof -nP -iTCP:18789 -sTCP:LISTEN || echo 'no listener on 18789'
curl -s http://127.0.0.1:18789/health && echo

# 3. Live config (mode + bind + port + token presence).
cat ~/.openclaw/openclaw.json | jq '.gateway | {mode, bind, port, hasToken: (.auth.token != null and .auth.token != "")}'

# 4. Paired devices and BYOK providers (no secret values).
jq -r '.devices[]?.name // .[]?.name' ~/.openclaw/devices/paired.json 2>/dev/null
jq -r '.profiles | to_entries[].value.provider' ~/.openclaw/agents/main/agent/auth-profiles.json 2>/dev/null

# 5. Recent gateway stdout/stderr.
tail -50 ~/Library/Logs/RemClaw/local-gateway.log

# 6. Migration sentinel (UserDefaults). Nonzero means migrator already ran.
defaults read com.remapp.rem.mac launchAgentSecretsMigrated.v1 2>/dev/null
```

If a leaky `app.remclaw.mac.gateway.plist` is somehow back, the canonical recovery is to relaunch the Mac app — `LaunchAgentSecretsMigrator` will scrub it. The manual fallback is the workaround block in #384.
