# Rem App Architecture (Historical Pre-OpenClaw State)

> Historical reference. This document describes the February 2026 pre-OpenClaw
> app baseline for hackathon planning. It is not the current Rem architecture or
> source of truth. Start with `README.md`, `docs/README.md`, and
> `docs/product/VISION.md` for current guidance.

*Last updated: Feb 7, 2026*

This document describes the existing architecture of the Rem app prior to OpenClaw integration. It serves as the baseline for hackathon work.

---

## 1. System Overview

Rem is a productivity assistant with voice + text interaction, task/calendar management, and focus sessions. The system has three main components:

```
┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐
│   iOS App        │──────▶│   Backend        │──────▶│   LiveKit Cloud  │
│   (Swift/MVVM)   │       │   (Node/Express) │       │   (Media Server) │
│                  │◀──────│                  │◀──────│                  │
└──────────────────┘       └──────────────────┘       └──────────────────┘
                                    │
                                    ▼
                           ┌──────────────────┐
                           │   PostgreSQL     │
                           │   + pgvector     │
                           └──────────────────┘
```

**Data flows:**
- **Auth:** iOS → Backend (`POST /api/v1/auth/login`) → JWT issued → stored client-side.
- **Voice session:** iOS → Backend (`POST /api/v1/agent/token`) → LiveKit token returned → iOS connects directly to LiveKit Cloud → LiveKit dispatches an agent into the room.
- **Tasks:** iOS → Backend (`/api/v1/tasks/*`) → PostgreSQL CRUD.
- **Voice RPC:** LiveKit agent sends RPC calls to the iOS app (e.g., `createTask`, `bookCalendarEvent`), which the iOS app handles locally via registered RPC handlers.

**There is currently no direct iOS → LLM path.** All "smart" behavior routes through LiveKit's agent framework, where a server-side agent (not in this repo) handles ASR, LLM inference, TTS, and tool calls.

---

## 2. iOS App (Frontend)

### Architecture: MVVM

| Layer | Responsibility | Key Files |
|-------|---------------|-----------|
| **Views** | SwiftUI view hierarchy, presentation logic | `VoiceAgent/Views/Screens/` |
| **ViewModels** | State management, business logic, service orchestration | `VoiceAgent/ViewModels/` |
| **Models** | Data models, protocols, type definitions | `VoiceAgent/Models/` |
| **Services** | Auth, API calls, LiveKit, Calendar, Tasks, Voice | `VoiceAgent/Services/` |
| **Infrastructure** | RPC handlers, persistence, network monitoring, permissions | `VoiceAgent/Infrastructure/` |

### Navigation Structure

```
RemAppView (root)
├── Agenda tab (home)         → AgendaView + AgendaViewModel
├── Inbox tab                 → InboxView + InboxViewModel
└── Settings tab              → SettingsView
    ├── Profile
    ├── Notifications
    ├── Calendar Sync
    ├── About / Terms / Privacy
    └── Sign Out

Overlay / Full-screen covers:
├── ArcVoiceView (voice session - animated face + chat)
├── RemChatView (chat transcript during voice)
├── FocusTimerView (focus session)
└── MiniPlayer (bottom bar for active sessions)
```

**Tab bar** uses a bottom toolbar with a hamburger menu (left), mic button (center, Agenda/Inbox only), and plus button (right, Agenda/Inbox only).

**Voice entry point:** Tapping the mic button on Agenda or Inbox starts a voice session. This opens a full-screen `ArcVoiceView` with an animated face and a chat transcript (`RemChatView`). The session appears as a MiniPlayer when minimized.

### Key ViewModels

**`RemAppViewModel`** — Central app coordinator:
- Manages tab selection, navigation path, session lifecycle.
- Creates LiveKit `Session` + `LocalMedia` on mic tap.
- Fetches LiveKit token via `EndpointTokenSource` → `BackendTokenSource`.
- Manages MiniPlayer sessions (voice + focus).
- Observes voice provider session state for cleanup.

**`AgendaViewModel` / `InboxViewModel`** — Task list management:
- SwiftData `ModelContext` for local persistence.
- `TaskApiService` for backend CRUD.
- `TaskSyncService` for background sync with debouncing.
- `CalendarService` / `CalendarLazyLoadService` for calendar integration.

### Key Protocols

**`VoiceSessionProvider`** — abstraction over voice backends:
```swift
@MainActor
protocol VoiceSessionProvider: ObservableObject {
    var isSessionActive: Bool { get }
    var isMicrophoneEnabled: Bool { get }
    var messages: [RemMessageModel] { get }
    var audioLevel: Float { get }
    func startSession() async throws
    func endSession() async
    func toggleMicrophone() async
    func sendTextMessage(_ text: String) async throws
}
```

Three implementations exist:
- **`LiveKitSessionImplementation`** — production path via LiveKit SDK.
- **`FoundationModelsImplementation`** — on-device Apple Foundation Models (iOS 26+).
- **`MockVoiceImplementation`** — testing.

`VoiceProviderFactory` selects which implementation to use based on `VoiceProviderConfig`.

### Voice Session Flow (LiveKit)

```
1. User taps mic → RemAppViewModel.handleMicTap()
2. createSession() → EndpointTokenSource.fetch()
3.   → POST /api/v1/agent/token (with Tija JWT)
4.   ← { token, url, roomName, encryptionKey }
5. Session(tokenSource:, options:) created with E2EE
6. LiveKitSessionImplementation wraps Session + LocalMedia
7. provider.startSession() → session.start() → connects to LiveKit
8. RPC handlers registered: createTask, commitTask, listTasks, etc.
9. Agent joins room, handles voice interaction
10. Messages polled from session.messages → merged → displayed
```

### RPC Handlers (iOS-side)

The iOS app registers LiveKit RPC methods that the server-side agent can invoke:

| RPC Method | Handler | Purpose |
|------------|---------|---------|
| `createTask` | `TaskRpcHandler` | Create task draft from voice |
| `commitTask` | `TaskRpcHandler` | Confirm and save task |
| `clearDraft` | `TaskRpcHandler` | Clear task draft UI |
| `listTasks` / `listEvents` | `TaskRpcHandler` | Query local tasks |
| `getTask` / `getEvent` | `TaskRpcHandler` | Get specific task |
| `findTask` / `findEvent` | `TaskRpcHandler` | Search by title/date |
| `updateTask` / `updateEvent` | `TaskRpcHandler` | Update existing task |
| `bookCalendarEvent` | `CalendarRpcHandler` | Book calendar event |
| `endSession` | `SessionRpcHandler` | End voice session |
| `getCurrentTime` | `TimeRpcHandler` | Get device current time |

### Key Services

| Service | File | Purpose |
|---------|------|---------|
| `AuthService` | `Services/Auth/AuthService.swift` | Apple/Google OAuth, JWT storage |
| `TaskApiService` | `Services/Tasks/TaskApiService.swift` | Backend task CRUD |
| `TaskSyncService` | `Services/Tasks/TaskSyncService.swift` | Background sync, conflict resolution |
| `CalendarService` | `Services/Calendar/CalendarService.swift` | EventKit integration |
| `CalendarLazyLoadService` | `Services/Calendar/CalendarLazyLoadService.swift` | On-demand calendar loading |
| `FocusSessionManager` | `Services/Focus/FocusSessionManager.swift` | Focus timer lifecycle |
| `DraftManager` | `Services/DraftManager.swift` | Voice task creation drafts |
| `EncryptionKeyManager` | `Services/EncryptionKeyManager.swift` | E2EE key storage per room |
| `NetworkMonitor` | `Infrastructure/Network/NetworkMonitor.swift` | Connectivity observation |

### Data Models

**`TaskEvent`** (SwiftData `@Model`):
- Core fields: title, notes, priority, status, dates, repeat frequency.
- Calendar linking: `calendarEventIdentifier`, `calendarName`.
- Sync: `backendId`, `pendingOperations`.

**`RemMessageModel`**: Chat message (id, text, sender [.user/.ai], timestamp).

**`FocusSession`**: Timer session linked to a task.

---

## 3. Backend (Node.js / Express)

### API Routes

| Route | Method | Auth | Purpose |
|-------|--------|------|---------|
| `/api/v1/auth/login` | POST | None | OAuth login (Apple/Google) → JWT |
| `/api/v1/agent/token` | POST | JWT | Generate LiveKit room token + E2EE key |
| `/api/v1/tasks` | GET | JWT | List user's tasks |
| `/api/v1/tasks` | POST | JWT | Create task |
| `/api/v1/tasks/:id` | GET | JWT | Get task |
| `/api/v1/tasks/:id` | PATCH | JWT | Update task |
| `/api/v1/tasks/:id` | DELETE | JWT | Delete task |
| `/api/v1/health` | GET | None | Health check |

### Key Services

**`auth.service.ts`** — OAuth verification + user management:
- `verifyAppleToken()` / `verifyGoogleToken()` — validate provider tokens.
- `findOrCreateUser()` — upsert user + auth_identities in a transaction.
- `generateTijaToken()` / `verifyTijaToken()` — JWT issuance/verification.

**`livekit.service.ts`** — LiveKit token generation:
- Creates `AccessToken` with room grants (publish, subscribe, data).
- Room naming: `room-{userId}-{sessionId}` for session isolation.
- In development: explicit `RoomAgentDispatch` via `LIVEKIT_AGENT_NAME`.
- E2EE shared key from env or random generation.

**`telemetry.service.ts`** — PostHog analytics.

### Database Schema (PostgreSQL + pgvector)

```sql
users (id, email, full_name, first_name, last_name, profile_picture_url, locale, created_at)
auth_identities (id, user_id, provider, provider_sub, email, created_at)
chat_sessions (id, user_id, title, is_archived, created_at)  -- NOT ACTIVELY USED
chat_messages (id, session_id, role, content, embedding, created_at)  -- NOT ACTIVELY USED
tasks (id, user_id, title, notes, type, priority, status, ...)
```

**Note:** `chat_sessions` and `chat_messages` tables exist from an earlier RAG plan but are not currently written to. Chat/voice transcripts live only in LiveKit session memory and iOS client-side state.

### Configuration (`env.ts`)

Required env vars: `DATABASE_URL`, `JWT_SECRET`, `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`.
Optional: `LIVEKIT_AGENT_NAME`, `LIVEKIT_E2EE_SHARED_KEY`, `APPLE_CLIENT_ID`, `GOOGLE_CLIENT_ID`, `POSTHOG_API_KEY`.

---

## 4. Voice Agent (LiveKit Agent)

**Current state:** No agent code exists in this repository. The system assumes an external LiveKit agent (Python or Node.js) is deployed and dispatched by LiveKit Cloud into user rooms.

The agent is expected to:
1. Join the LiveKit room when dispatched.
2. Handle ASR (speech-to-text) from user audio tracks.
3. Run LLM inference for responses.
4. Produce TTS (text-to-speech) audio back into the room.
5. Use RPC to invoke iOS-side tool handlers (task creation, calendar, etc.).

For the hackathon, this agent role shifts to a **relay**: the agent becomes a voice pipeline worker that routes transcripts to the user's OpenClaw gateway and returns responses as speech.

---

## 5. Settings Structure (Current)

```
Settings
├── Profile section (avatar, name, email)
├── Preferences
│   ├── Notifications → NotificationSettingsView
│   └── Calendar Sync → CalendarSettingsView
├── About
│   ├── About Rem → AboutView
│   ├── Terms of Service → TermsOfServiceView
│   └── Privacy Policy → PrivacyPolicyView
└── Account
    └── Sign Out
```

`SettingsDestination` enum: `.profile`, `.notifications`, `.calendar`, `.about`, `.termsOfService`, `.privacyPolicy`.

**No server/gateway settings exist currently.**

---

## 6. Third-Party Dependencies

### iOS
- **LiveKit SDK** (`LiveKit`, `LiveKitComponents`) — real-time communication.
- **SwiftData** — local persistence for tasks.
- **EventKit** — calendar integration.
- **AVFoundation** — audio recording, microphone access.
- **ActivityKit** — Live Activities for voice/focus sessions.

### Backend
- **express** — HTTP server.
- **livekit-server-sdk** + **@livekit/protocol** — token generation, room config.
- **pg** — PostgreSQL client.
- **jsonwebtoken** — JWT auth.
- **google-auth-library** — Google OAuth verification.
- **posthog-node** — telemetry.
- **cors** — CORS middleware.

---

## 7. What Does Not Exist Yet (Hackathon Scope)

| Component | Status |
|-----------|--------|
| OpenClaw gateway integration | Not present |
| iOS → Gateway direct WS/HTTP path | Not present |
| Gateway metadata in backend (URL, token, provider) | Not present |
| `/api/v1/me` endpoint | Not present |
| Voice pipeline worker (ASR → OpenClaw → TTS) | Not present |
| Server/Gateway settings UI | Not present |
| First-run gateway setup flow | Not present |
| QR code scanning | Not present |
| Venice configuration | Not present |
| Mac helper node | Not present |
