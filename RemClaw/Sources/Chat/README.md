# Chat (iOS)

> The chat screen you type in. Renders AI messages as speech bubbles, consolidates tool results (calendar events, reminders, device status) inside the turn's connected activity timeline rather than as raw JSON or detached sibling rows, manages your conversation history list, and strips hidden server metadata before displaying messages. As of #305 (Mac chat parity epic) the chat surface itself is shared with the Mac app and lives in `Shared/Views/Chat/`; this folder now only owns the iOS-specific wrapper and the session history screen.

iOS-specific glue around the shared Rem chat view.

## Directory Structure

```
Chat/
├── RemChatView.swift          # iOS wrapper — wires UsageService + RemTalkModeManager
│                              # into SharedRemChatView's optional hooks
└── ChatHistoryView.swift      # Session list with search and management (iOS-only)
```

## Shared Files (now under `Shared/Views/Chat/`)

These used to live here; they have moved to `Shared/Views/Chat/` so the Mac
chat surface can render the same custom UI as iOS:

- `SharedRemChatView.swift` — cross-platform chat surface (speech bubbles, contextual Thought/Worked activity timeline with consolidated tool results, Grok-style composer)
- `MessageCleaner.swift` — metadata stripping + `SessionDisplayNames` / `SessionLastMessageTimes` / `SessionLastMessagePreviews`
- `ToolResultCards/ToolResultParser.swift` — JSON → `ParsedToolResult` enum (22 cases)
- `ToolResultCards/ToolResultCardView.swift` — card router + built-in cards
- `ToolResultCards/CalendarCard.swift`, `RemindersCard.swift` — collapsible list cards

## Key Files

| File | Purpose |
|------|---------|
| `RemChatView.swift` | Thin iOS wrapper around `SharedRemChatView`. Wires `UsageService` into quota hooks, `RemTalkModeManager` into voice hooks, and injects the active `RemGatewaySessionManager` into Manage Models so its switches write gateway state rather than a local preference. Provider submenus load only from gateway model-auth runtime evidence. Loading/failure is distinct from verified empty; an older managed gateway's partial `models.authStatus` response contributes positive rows without treating omissions as unavailable or resetting an explicit selection. A refresh retains only same-session/candidate verified evidence, while an unknown new session blocks an unsafe explicit Send. The monotonic operator-session generation invalidates evidence before credential/socket replacement, including same-URL token swaps; foregrounding, gateway-event revisions, and a bounded 60-second refresh re-probe without destructively clearing a valid snapshot. Model repair and local dispatch acceptance finish before the quota hook runs, preventing a rejected reset or health check from consuming a request. Quota reset timers publish an observable invalidation so the banner, composer, and voice entry unlock at the UTC boundary; tapping a denial banner only presents still-current evidence and never recreates an expired zero from the retained summary. |
| `ChatHistoryView.swift` | Lists past sessions with search, swipe-to-delete, rename, pull-to-refresh. Session visibility rules filter out empty placeholders. Relative time formatting ("Just now", "5m", "Yesterday") |

Chat Sessions uses the shared `ChatConnectionRecoveryCard` whenever the operator is unavailable,
including the launch `Continue Anyway` path. The app-wide recovery banner yields ownership on the
Sessions tab, so exactly one card presents `Retry` and `Review Connection`; Retry repeats the launch
wake-plus-reconnect behavior and successful operator recovery resumes the normal session load.

## Patterns & Conventions

- **Shared view as source of truth**: Visual surface (speech bubbles, thinking blocks, cards, composer) lives in `Shared/Views/Chat/SharedRemChatView.swift`. iOS and Mac both render the same view; iOS adds voice + quota via optional hooks, Mac passes nil for those.
- **Manage Models destination**: Platform wrappers inject `SharedModelsSettingsScreen` with their
  active gateway session and the same tri-state provider evidence used by the composer. Unknown
  evidence shows loading/recovery instead of becoming a verified-empty provider list. The shared
  chat view's catalog-only fallback is for fixtures/previews; production chat must not present
  editable model switches without the gateway-backed destination.
- **Echo prevention in message cleaning**: `MessageCleaner.cleanAssistantMessageText` / `cleanUserMessageText` strip embedded timestamps, metadata blocks, TalkMode prompts, and legacy device-context preambles from displayed messages. New turns keep the user transcript raw and use gateway-owned structured context. Shared between platforms.
- **Local-first session metadata**: `SessionDisplayNames`, `SessionLastMessageTimes`, and `SessionLastMessagePreviews` (in `Shared/Views/Chat/MessageCleaner.swift`) take priority over server data for sorting and display.
- **Accepted server metadata stays request-scoped**: `derivedTitle` and
  `lastMessagePreview` decode on each session row and are displayed only after the
  view model accepts that authoritative list response. Conversation-backed accepted
  rows may then seed the set-once local title store so a cross-device reply is
  not mistaken for a first message. Never write raw transport responses into shared
  `UserDefaults` before request-order gating, and never treat a derived title alone as
  proof that an empty materialized session contains a conversation.
- **Gateway-backed history**: The canonical session list and transcript are
  fetched from the active gateway through `sessions.list` and `chat.history`.
  Local metadata only decorates those sessions. If a user switches gateways,
  previous chats may disappear from the current view because the new gateway has
  a different session store.
- **Bottom-toolbar clearance**: `ChatHistoryView` owns a non-interactive trailing
  clearance row because the app-wide floating toolbar overlays tab content.
  Preserve enough real list height for the final session row to clear that
  toolbar; a scroll-content margin alone does not reliably extend `List`'s scroll
  range when the conversations almost—but do not quite—fill the viewport.
- **Truthful session-list loading**: Cached rows paint immediately. When no rows are
  cached and the gateway is ready, both platforms keep the real-row shimmer stable from
  the scheduled first frame until the awaited `sessions.list` request completes; a
  disconnected gateway keeps its connection state instead. On iOS and Mac, reaching the
  final row grows the visible window in 100-row increments until `hasMore` is false. Transports fetch those
  windows as bounded 100-row keyset-cursor pages and combine an authoritative snapshot; older
  gateways use the cumulative-limit compatibility fallback. Search expands the window
  before filtering, so history and search are not capped at the gateway's default 100 rows.
- **Existing-session route contract**: Opening a row from `ChatHistoryView`
  must carry the row's known title into the destination and represent the first
  frame as pending history, before the asynchronous view model has entered its
  `isLoading` state. Keep the skeleton until the requested session is actually
  active and its load finishes; never paint the prior transcript, "New
  conversation", or starter state in between. If the route key already matches,
  call `load()` instead of assuming `switchSession(to:)` already ran. Existing
  routes without a row title (such as daily-summary entry) still count as pending
  when they carry a different requested session key, or the active session has
  no loaded messages yet. A matching session with an already-loaded transcript
  renders immediately—there is no minimum shimmer duration. The shared view uses
  a short maximum fallback only when an empty load has no observable loading
  transition, preventing the skeleton from getting stuck indefinitely. Both the
  iOS navigation destination and `MacChatWindow` pass this requested key before
  asking the shared view model to switch; an existing-session composer prefill
  never overrides the pending-history gate.
- **Warm chat re-entry**: `OpenClawChatViewModel.load()` is an idempotent appearance
  hook for the currently loaded session generation. Returning from Sessions to the
  same chat keeps its painted transcript and does not refetch history. Clearing the
  root `mainSessionKey` routing sentinel on Back does not discard that model: the iOS
  root reuses it only when session, gateway, and device binding still match. Session
  changes, failed initial loads or activation, failed post-run history reconciliation,
  reset/compact reloads, and explicit `refresh()` calls still bootstrap from the
  gateway. A session is marked warm only after activation, health, and history are
  usable; repeated appearances while that bootstrap is in flight coalesce onto the
  existing request.
- **Durable Summary conversation**: Only tapping the Agenda Summary/brief enters the
  backend-advertised brief conversation. Capability-aware clients receive `rem-orchestrator`; old
  clients keep receiving `rem-today-<yyyymmdd>` during the bridge. Every explicit New Chat—including
  the global/footer button—mints a fresh `chat-*` conversation. The durable surface derives compact
  day dividers from persisted message timestamps; legacy day sessions remain readable. The same
  attributed task suggestions Agenda owns render immediately after the exact canonical brief
  message (or its temporary delivery bridge), with one-tap Add/Move and durable Dismiss. They are
  local action UI, not synthetic gateway transcript messages, and never appear in unrelated chats.
  During the compatibility bridge the backend may materialize the same current artifact in both
  `rem-orchestrator` and `rem-today-<day>`. Chat Sessions collapses only the legacy row whose latest
  preview matches and whose zero-token metadata proves it is artifact-only. Local preview/timestamp
  evidence always preserves a locally replied thread even while server metadata is stale. Historical,
  used, malformed, or uncertain legacy conversations remain visible; the client never deletes their gateway history.
- **Structured device context**: First user messages stay byte-for-byte user-authored. Device
  routing uses `sessions.patch.execNode`, node registration supplies capabilities, and OpenClaw's
  `agents.defaults.userTimezone` supplies local-time context. Do not restore hidden `[System:
  Connected to …]` transcript prefixes; the legacy cleaner exists only for old history repair.
- **Runtime diagnostics display**: `SharedChatDiagnosticDisplay` is the single
  source of truth for recognizing gateway/runtime diagnostic text such as
  `agent=... gateway=... action=invoke` and "pairing required before node
  invoke". Message cleaning and visible thinking rows both use that helper so
  the collapsed state says `Error` instead of leaking transport IDs. Do not add
  new ad hoc `agent=` or `node=` checks in render paths.
- **Runtime pairing recovery**: When a runtime diagnostic says pairing is
  required, the shared chat view shows one `Approve Rem Agent` recovery CTA.
  iOS wires that CTA to the existing Device Connections screen; do not create a
  second approval screen or route from chat. If multiple historical diagnostics
  exist, only the newest diagnostic should own the visible recovery CTA.
  Recovery copy should use user-facing `machine` language; raw gateway/runtime
  terms stay in diagnostics.
- **Action lifecycle cards, not dumps**: Reminder, calendar, search, and
  gateway payloads are implementation data. Pending states should render through
  `Shared/Views/Chat/ActionLifecycleCard.swift`; final states should render
  through `Shared/Views/Chat/ToolResultCards/`. New render paths must pass
  assistant/tool text through `MessageCleaner` and use those shared components
  instead of rendering raw JSON. This includes truncated reminder arrays and
  mixed payload-plus-prose messages; the transcript should show prose and cards,
  never raw reminder identifiers or list dumps.
- **Historical lifecycle rows are not live work**: `pendingToolsBar` owns the
  active spinner at the scrollable transcript tail, never as composer-attached chrome. Tool-call rows restored from the transcript should render as
  static lifecycle rows without node IDs or progress spinners so old messages do
  not look like they are still running. Live labels stay in-progress
  (`Thinking`, `Updating agent instructions`); restored transcript labels use
  completed wording (`Thought`, `Updated agent instructions`).
- **Historical elapsed time starts with work**: A delayed user message can sit before the gateway
  begins processing, so the historical activity clock starts at the first persisted thinking/tool
  event rather than the user timestamp. Longer elapsed labels use compact human units instead of
  exposing a raw seconds counter.
- **One truthful activity timeline per turn**: emitted thought summaries, generic tool calls, and
  generic tool results share the same disclosure. The current run is expanded with connected step
  icons and reads `Working`; the live timeline starts expanded but remains explicitly collapsible.
  Expanded steps use a bounded internal scroll so activity cannot displace the answer. Persisted
  content items may carry both reasoning and final prose; project both fields independently so
  clearing the streaming handoff never leaves an orphaned Activity chevron. Structured live
  activity for the currently bound requested session selects the transcript even before an empty
  run has persisted its first message; retained activity from the prior route cannot override the
  history skeleton. Scroll follow occurs once when a run appears, not on later step reconciliation.
  Live ownership comes from the gateway's structured execution identity, never transcript order:
  both transports emit `(canonical sessionKey, raw execution runId)` before OpenClawChatUI rewrites
  agent run IDs for history routing. A local `chat.send` also registers its returned run ID, so the
  view correlates the local pending count to that exact execution instead of merging it with an
  unmatched voice or cross-device run. Ambiguous mixed ownership fails closed. Only a matching `chat.final`, `chat.error`, or
  `chat.aborted` event closes that run. Concurrent runs remain distinct, so terminal A cannot close
  run B. Terminal Activity collapses but stays visible until refreshed history contains matching
  completed rows; exact persisted tool-call IDs own recognized result cards, while ID-less rows use
  an occurrence-count increase beyond the pre-terminal history snapshot. An identical older turn
  therefore cannot clear the current run. This protects the Mac final-before-persistence window. A missing session/run
  identity fails closed within the conversation; changing sessions is the bounded cleanup, with no
  timestamp, array-position, or render-count fallback. Exact terminal tombstones are bounded to the
  authoritative transport connection epoch and a 120-second delayed-event window. Capacity pressure
  fails closed for that epoch until the window expires instead of evicting a still-live tombstone;
  a newer connection epoch resets the quarantine, so unrelated future run IDs are never permanently
  poisoned. An
  elapsed duration appears only when the refreshed turn contains a timestamped final assistant
  answer with no tool activity in the same message. Generic result payloads stay nested behind an expandable `Tool result` step rather than
  becoming inaccessible or reappearing as transcript dumps. Top-level result details pass through
  one privacy-safe projection before nesting: plain-language summaries survive, while diagnostic
  output and unknown structured envelopes are suppressed rather than exposing runtime IDs,
  commands, or payloads. Known error cards use this same privacy projection. Structured-container
  detection uses one 64 KB-bounded linear scan with bounded parse work rather than repeatedly parsing
  nested substrings on the render path. Independently balanced inner containers remain detectable
  behind a malformed outer opener, and JSON-like unbalanced candidates fail closed while ordinary
  brace prose remains visible. That same boundary extracts renderable images first, then rejects object,
  array, and fenced structured residual text so adjacent runtime payloads cannot ride along with an
  image. Both disclosure levels expose their
  expanded/collapsed state to assistive technology. Do not fabricate a reasoning stream when
  OpenClaw emits no thought summary, and do not expose private chain-of-thought.
  User-visible summaries already emitted inside a streaming `<think>` block join the same live
  Activity timeline instead of rendering a second Thinking row; both the accumulator and fallback
  row use the same identifier/JSON-redacting display value. Browser-card presentation is part of
  reconciliation identity, and durable gateway browser evidence supplies completed tool-call IDs,
  so a card becoming live explicitly evicts its previously accumulated browser step even after that
  call has left `pendingToolCalls`.
  Local sends may also use OpenClawChatUI's `pendingRunCount`; voice and cross-device Activity uses
  the exact transport run set. Cached tool observations alone cannot revive stale activity.
  Duplicate detail-bearing steps retain their visible `×N` count.
  `OpenClawChatViewModel` currently projects live tool lifecycle but not the gateway's `thinking`
  event stream, so persisted thought summaries join the disclosure after history refresh rather than
  being simulated in the client. Recognized user-facing result cards and image payloads stay outside
  the diagnostic timeline.
- **Quota validation**: iOS calls `UsageService` via `consumeSendSlot` only after model repair and local dispatch guards accept a synchronously captured input/attachment/browser snapshot. One unresolved reservation is allowed per account plus normalized backend. A decoded consume success or structured 429 supersedes every older in-flight usage-summary GET before publishing quota state, so a late snapshot cannot restore a pre-request balance or clear a newer denial. A committed 200 returns and persists an opaque reservation token; each concrete text transport carries its individual token directly to its acceptance callback, without session-string lookup, so same-key sends and mutable account state cannot retire another scope. The transport keeps that fence through `chat.send` acceptance and clears it only after decoding the accepted run ID. If preparation is cancelled after commit, it awaits that run and sends the exact `chat.abort` afterward. Definite pre-commit rejection may be retried, while ambiguous outcomes remain durably blocked.
