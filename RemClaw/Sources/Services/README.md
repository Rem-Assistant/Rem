# Services (iOS)

> The backbone of the iOS app. All the business logic that isn't UI lives here — signing in with Apple or Google, reading and writing your calendar and reminders, syncing tasks with the backend, scheduling notifications, managing focus sessions, and tracking usage.

Business logic services for authentication, calendar, reminders, tasks, focus sessions, notifications, telemetry, and usage tracking.

## Directory Structure

```
Services/
├── Auth/
│   ├── AuthTypes.swift          # AuthProvider enum, AuthResponse, AuthUserInfo, AuthError
│   └── RemAuthService.swift     # Apple/Google sign-in, JWT refresh, credential restore
├── Usage/
│   ├── UsageModels.swift        # UsageSummary, PlanLimits, QuotaExceededError
│   └── UsageService.swift       # Backend quota API client with per-scope single-flight and opaque, durable reservation-to-accepted-run handoffs
├── AppConfig.swift              # Info.plist environment config reader
├── DailyBriefTranscriptReconciler.swift # Resolves durable brief delivery only when `/brief` advertises the canonical session authority and exact prose; projected timestamps remain optional
├── CalendarGatewayService.swift # Gateway command → EventKit adapter
├── CalendarSyncServiceProtocol.swift # Calendar operations protocol
├── RemCalendarService.swift     # Direct EKEventStore wrapper
├── RemindersService.swift       # EKReminder CRUD operations
├── DeviceStatusService.swift    # Battery, thermal, storage, device info
├── TaskStore.swift              # Single source of truth for all tasks
├── RemTaskApiService.swift      # HTTP client for /api/v1/tasks/*
├── RemTaskSyncService.swift     # Bidirectional task sync + offline queue
├── TaskSyncManager.swift        # Backend pull → SwiftData upsert
├── OrganizationApiService.swift # Backend Folder/List persistence and task filing
├── OrganizationSyncManager.swift # Backend Folder/List hierarchy → SwiftData cache
├── TaskApiServiceProtocol.swift # Task API protocol
├── TaskSyncServiceProtocol.swift # Task sync protocol
├── StubServices.swift           # Stub implementations for dev/testing
├── TaskNotificationService.swift # Local notification scheduling
├── TaskNotificationDelegate.swift # Task actions + artifact-safe Daily Brief tap routing
├── PushRegistrationService.swift # APNs token → POST /api/v1/push/register (remote push, #830)
├── FocusSessionManager.swift    # Focus session lifecycle + Live Activities
├── FocusSessionControl.swift    # Deep link/command routing for focus sessions
├── FocusSessionSharedState.swift # App Group UserDefaults bridge
├── FocusTimerProvider.swift     # Focus timer protocol
├── TelemetryService.swift       # PostHog event tracking wrapper
├── Environment+Services.swift   # SwiftUI environment keys for DI
└── WakeOnLAN.swift              # UDP magic packet sender
```

## Key Subsystems

### Authentication (`Auth/`)
- Apple Sign-In and Google Sign-In via federated OAuth
- JWT token refresh (`POST /api/v1/auth/refresh`)
- Keychain-based credential persistence (survives app reinstall)
- Returning user detection and gateway credential restoration
- Authenticated session restore best-effort reconciles only the backend's canonical gateway URL/token into the active local config; successful responses scrub the retired device-cached Voice provider key, while offline failures retain the cached gateway

### Calendar & Reminders
- `RemCalendarService` wraps EventKit for calendar CRUD with iOS 17+ full access handling
- `CalendarGatewayService` translates AI gateway commands (`calendar.events`, `calendar.add`, etc.) to EventKit calls
- `RemindersService` handles `EKReminder` CRUD with list filtering
- Lenient ISO 8601 parsing (with/without fractional seconds)

### Task Management
- **Task description (backend migration 120) is co-authored.** `TaskEvent.taskDescription` is
  the USER's half and is the only half the device ever writes; `TaskEvent.agentContext` is
  Rem's half and is read-only here. `RemTaskApiService.updateTask(description:)` sends the
  user's half under `description`, which the backend merges rather than overwrites — so a
  device sync can never clobber the context a run recorded, and a run can never clobber the
  user's text. Nothing on the client parses the block delimiter: the backend serializes the
  two halves pre-split (`description_user` / `description_agent`).

- Daily Brief suggestions arrive in one negotiated atomic `/brief` payload. Missing revision,
  snapshot, or action identities fail closed; create acceptance uses the stable backend action UUID
  as the local/offline task UUID instead of deduping mutable titles or scheduled times. Suggestion
  dismissal is fenced on a successful local save plus a confirmed scoped backend mutation.
  Suggestion HTTP writes capture immutable token/backend authority with the rendered account scope;
  the task mutation and final dismissal use that same authority without global token refresh and
  never enter the account-agnostic offline queue. A failed scoped write leaves the proposal visible,
  while a successful create immediately PATCHes the accepted payload to recover lost ACKs.
- `TaskStore` holds `allTasks` shared across Agenda and Inbox views
- `RemTaskSyncService` handles bidirectional sync: push to backend + pull from backend. Reconciliation compares parsed UUID values—not UUID string casing—so lowercase backend rows and tombstones correctly update/delete uppercase Swift UUID identities across devices.
- Offline queue via SwiftData (`PendingTaskOperation`) for failed operations
- Queue uploads use immutable snapshots and only remove an intent when its payload is unchanged,
  so edits made while a create/update request is in flight remain durable for the next sync.
- Queue snapshots include the task's `list_id` when the write owns organization; create/update
  replay sends that assignment in the same backend write instead of a best-effort follow-up PATCH.
  Retryable transport/5xx failures succeed only after the intent is durably queued, while terminal
  4xx validation failures surface.
- Unrelated task updates carry a private queue marker and omit `list_id` both immediately and on
  replay; only creates and explicit List moves own organization. This prevents a stale cached List
  assignment from rejecting completion, scheduling, snoozing, or another unrelated field edit.
- A successful authoritative Lists pull clears remotely deleted List references from live tasks
  and queued create/update snapshots, allowing those durable writes to replay explicitly unfiled.
- Replaying a client-owned create always reapplies that immutable payload, including its List
  assignment and explicit nulls for cleared schedule/alert/recurrence fields, before deleting the
  intent because a lost-acknowledgement retry may return an older already-committed row.
- Tasks synced to both backend API and local EventKit calendar
- `TaskNotificationService` schedules local notifications with "Mark Complete" and "Snooze 15 min" actions
- Folder → List organization is backend-owned and mirrored locally. Agent commands expose both levels by human-readable name and reject missing IDs rather than reporting a successful unfiled mutation.
- `/brief` carries the artifact's authored `headline` (`DailyBrief.briefHeadline`). It is the ONE
  title for the brief: the Agenda summary card header and the orchestrator chat title both render
  it. `AgendaViewModel` republishes it to `BriefContext.setOrchestratorHeadline` on every `brief`
  assignment, because the chat view has no `/brief` payload of its own. A nil headline restores
  each surface's prior fallback (time-of-day greeting on the card, "Rem" in chat).
- That published headline is **account-scoped and fails closed**. It is model-authored prose that
  can name a person or a company, and this device is shared between an Apple and a Google account,
  so `BriefContext` stamps it with `<backend JWT subject>|<local day>` and every reader must pass
  the account it is rendering for (`GatewaySessionProviding.authenticatedAccountIDForRecovery` —
  NOT `authService.currentUser?.id`, which is a different identifier). A read by another account,
  by a signed-out reader, or on a later day misses and falls back to "Rem". Sign-out on both
  platforms calls `BriefContext.clearOrchestratorHeadline()` so the prose does not outlive the
  session. Any new surface that titles the brief must pass an account; `displayTitle` deliberately
  has no default for it.
- Agenda renders its Daily Brief summary/open surface when `/brief` authorizes the durable
  `rem-orchestrator` route and supplies displayable canonical prose or legacy structured work.
  This keeps a delivered all-clear summary visible even when every count is zero and local history
  reconciliation is still catching up. The backend derives any missing summary from that same
  canonical markdown (or clears it), so deterministic fallback summary text cannot appear beside
  an authorized artifact. The card also derives a compact excerpt from canonical markdown when
  no summary is available, reserving synthesized count capsules for prose-less structured work.
  Fallback prose/counts without authority, or a route hint with no displayable content, remain hidden.
- Remote Daily Brief alerts use one collapse/thread identity. A tap never narrates notification
  payload prose; it enters the same explicit "Read latest brief" path as Agenda, which refetches,
  requires the backend's delivered `rem-orchestrator` authority, then anchors to and reads the
  exact canonical Today artifact. Deterministic `/brief` fallback markdown or a historical equality
  match cannot authorize narration. Agenda reconciliation applies the same authority gate before
  promoting an equality match into transcript/read-receipt state; a nil or legacy key remains only
  the deterministic card fallback. A newer notification tap cancels and
  request-ID-invalidates an older in-flight read and synchronously stops stale audible playback;
  the command stays router-owned unless its
  replacement playback request actually starts. Legacy `checkin` payloads resolve forward through
  this path only when the payload carries the currently authenticated account; stale or ownerless
  account notifications fail closed.
- Sign-out snapshots and unregisters both the last successfully registered APNs token and any
  newly rotated token whose registration may still be in flight, then advances the installation
  ownership generation so neither destination can continue notifying the previous account. The
  successful-registration cache includes that installation ID and generation; an older cache that
  only recorded token, environment, and user must perform one upgrade registration before it can
  suppress a POST. If a cold logout happens before that upgrade succeeds, the unregister payload
  explicitly retires the migrated legacy token in the same backend transaction as the new-install
   tombstone; the account's other legacy device tokens remain registered.

### Focus Sessions
- Timer-based lifecycle: warming up → running → paused → completed/cancelled
- Live Activities (iOS 16.1+) for active and pre-session states
- Deep link support (`remclaw://focus`) for widget/background invocation
- App Group shared state for cross-process communication

### Usage Tracking (`Usage/`)
- `GET /api/v1/usage/summary` for current usage and remaining quota
- `POST /api/v1/usage/consume` for tracking AI requests
- Quota exceeded error handling with UI presentation
- Failed quota authorization is fail-closed for both text and voice sends. A `/usage/consume` 200 is the committed reservation boundary even when its summary body cannot decode; transport, invalid-response, and 5xx ambiguity—including a lost response after a refreshed 401 retry—blocks further reservations rather than retrying and possibly charging twice. The blockade is persisted by account plus normalized backend URL, survives process relaunch, UI reset, sign-out, foreground reconciliation, and same-account reauthentication, and does not spill into a replacement account or backend. It remains until a future authoritative reservation-to-`chat.send` reconciliation can retire that exact scope. If a voice turn is cancelled by newer speech after the committed 200 but before gateway dispatch, the quota unit remains charged and the exact opaque reservation receives a durable terminal cancelled-before-dispatch disposition; that stale utterance is never sent or retried, while unrelated account reservations remain fenced. Each consume also carries immutable account/token/backend authority plus a reset generation, and bound refresh dedupe uses that exact account/backend/token scope. Concurrent summary and consume callers may retry with either their exact original authority or the exact token returned by the one shared bound refresh; cancellation, account/backend replacement, or any different newer same-account token suppresses the retry and is never overwritten. Usage-summary loads capture the same account/backend plus their own monotonic request generation, so delayed responses cannot authorize an old send, overwrite a newer summary, or publish into a replacement account. Caller-controlled idempotency remains forbidden.
- A confirmed StoreKit change invalidates only the plan/limit summary, preserving quota-exceeded and
  opaque reservation state until a fresh decoded summary becomes canonical. That fresh summary
  retires a stale 429 payload but never retires a pending dispatch handoff or ambiguity blockade.

## Patterns & Conventions

- **Protocol-first design**: Services define protocols (`CalendarSyncServiceProtocol`, `TaskApiServiceProtocol`, `TaskSyncServiceProtocol`, `FocusTimerProvider`) enabling testing and mocking via `StubServices`.
- **`@MainActor` isolation**: Most services use `@MainActor` for thread safety and SwiftUI reactivity.
- **`@Observable`**: Core state classes (`FocusSessionManager`, `UsageService`) use `@Observable` instead of `@Published`.
- **Async/await**: All async work uses structured concurrency (no Combine streams).
- **Keychain vs UserDefaults**: Sensitive tokens in Keychain, non-sensitive URLs/preferences in UserDefaults.
- **ISO 8601 date handling**: Always try fractional seconds first, fall back to non-fractional.
- **Environment injection**: Services injected via SwiftUI `@Environment` (see `Environment+Services.swift`).
- **Telemetry isolation**: No direct PostHog imports — all tracking through `TelemetryService` singleton.
- **Task sync reconciliation**: Push the durable offline queue before pulling. Queue one latest intent per task (including an explicit `list_id` key, where JSON null means unfile), preserve the task UUID on create retries, and treat task-list responses as upsert-only; absence is not a deletion tombstone. A successful direct create retires only matching preflight queue snapshots, preserving any newer edit. Legacy snapshots without `list_id` recover the current local List when available and otherwise omit the field on update, so replay cannot silently unfile an existing backend task. Each queued snapshot is revalidated immediately before upload and before deletion so an edit/delete that lands while an earlier request is in flight suppresses stale network work. Explicit deletes cancel older queued intents, backend `404` counts as already deleted for delete replay, and cross-device deletion is driven by the identity-bound `/tasks/deletions` tombstone feed (migration 103).
