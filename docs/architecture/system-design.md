# Rem Private — System Design (Hackathon Target State)

> Historical reference. This was the Notion + Cartesia hackathon target state,
> not the current Rem runtime or source of truth. LiveKit/voice-worker details
> here are preserved for archaeology only. Start with `README.md`,
> `docs/README.md`, and `docs/product/VISION.md` for current guidance.

*Historical architecture reference for the Notion + Cartesia Hackathon, Feb 2026*
*All epics in `docs/hackathon/epics/` reference this document.*

---

## 1. Design Principles

1. **Your server, your data.** Every user runs their own OpenClaw gateway. Conversations, memory, and workspace live on the user's infrastructure — not ours.
2. **Single brain, two modalities.** Text chat and voice share the same OpenClaw session. Context carries across both.
3. **Backend is thin.** The Rem backend handles auth, user profiles, gateway metadata, and LiveKit token issuance. It never proxies or stores conversations.
4. **No new RAG.** Long-term memory lives in OpenClaw's workspace and sessions on the user's gateway. The backend does not own semantic memory for the hackathon.
5. **LiveKit is transport, not the brain.** LiveKit provides real-time audio between the iOS app and the voice worker. The voice worker relays to OpenClaw — it does not run its own LLM.

---

## 2. Component Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          User's Railway Project                        │
│                                                                        │
│  ┌──────────────────────────────────┐                                  │
│  │  OpenClaw Gateway (per user)     │                                  │
│  │  • openclaw gateway daemon       │                                  │
│  │  • Anthropic default; Venice opt│                                  │
│  │  • /data volume (state, workspace│                                  │
│  │    sessions, config)             │                                  │
│  │  • Auth token for access control │                                  │
│  │  • /setup page with QR code      │                                  │
│  └──────────┬───────────────────────┘                                  │
│             │ WS/HTTP                                                   │
└─────────────┼───────────────────────────────────────────────────────────┘
              │
    ┌─────────┴─────────────────────────────────┐
    │                                           │
    ▼                                           ▼
┌──────────────────┐                 ┌────────────────────┐
│  Rem iOS App     │                 │  Voice Worker      │
│  (Swift / MVVM)  │                 │  (Python agent)    │
│                  │                 │                    │
│  • GatewayClient │  LiveKit rooms  │  • Deepgram ASR    │
│    (WS/HTTP)     │◄───────────────►│  • Cartesia TTS    │
│  • GatewaySession│                 │  • OpenClaw client │
│    Manager       │                 │    (same session)  │
│  • Text chat UI  │                 │                    │
│  • Voice UI      │                 │  Reads gateway     │
│  • Settings      │                 │  metadata from     │
│  • First-run flow│                 │  LiveKit room      │
│                  │                 │  metadata           │
└────────┬─────────┘                 └────────────────────┘
         │
         │ Auth + metadata only
         ▼
┌──────────────────────┐
│  Rem Backend         │
│  (Node.js / Express) │
│                      │
│  • Auth (Apple/Google│
│    OAuth → JWT)      │
│  • GET /api/v1/me    │
│  • PATCH /me/gateway │
│  • POST /agent/token │
│    (LiveKit + gateway│
│     metadata)        │
│  • Task CRUD         │
│                      │
│  PostgreSQL:         │
│  users + gateway_url │
│  + gateway_token_enc │
│  + hosting_provider  │
└──────────────────────┘
```

---

## 3. Data Flows

### 3a. Text Chat (iOS → OpenClaw → Venice → iOS)

```
1. iOS app sends text via GatewayClient
   → WS/HTTP to user's OpenClaw gateway (gatewayUrl + gatewayToken)
   → OpenClaw routes to Venice
   → Venice generates response
   → OpenClaw streams response back
   → iOS renders in chat UI

2. Backend is NOT in this path (beyond initial auth + metadata at login).
```

**Key contract:**
- iOS holds `{ gatewayUrl, gatewayToken }` in Keychain.
- iOS holds `currentSessionId` in UserDefaults (persists across app restarts).
- `GatewayClient.sendMessage(sessionId, text) -> AsyncStream<String>`.

### 3b. Voice (iOS → LiveKit → Voice Worker → OpenClaw → Voice Worker → LiveKit → iOS)

```
1. iOS mic audio → LiveKit room
2. Voice worker subscribes to audio track
3. Voice worker → Deepgram ASR → transcript text
4. Voice worker → OpenClaw gateway (same sessionId as text chat)
   → Venice generates text response
5. Voice worker → Cartesia TTS → audio
6. Audio → LiveKit room → iOS speaker
```

**Session ID handshake:**
- When iOS requests a LiveKit token (`POST /api/v1/agent/token`), it includes its `currentSessionId`.
- Backend embeds `{ gateway_url, gateway_token, openclaw_session_id }` in LiveKit room/agent metadata.
- Voice worker reads metadata on room join and uses the same session for all OpenClaw calls.

### 3c. Auth + Metadata (one-time, at login)

```
1. iOS → POST /api/v1/auth/login → JWT
2. iOS → GET /api/v1/me → { gateway: { url, hostingProvider, isConnected } }
3. iOS stores gatewayUrl, reads gatewayToken from Keychain
4. GatewayClient.connect()
```

### 3d. First-Run Gateway Setup

```
1. User signs in → GET /api/v1/me → gateway.url is null
2. iOS shows "Where does Rem live?" onboarding
3. User deploys gateway on Railway (WebView / link)
4. User scans QR from gateway's /setup page
5. iOS → PATCH /api/v1/me/gateway { gatewayUrl, gatewayToken }
6. iOS stores token in Keychain, connects GatewayClient
7. Connection test → success → land on Agenda
```

---

## 4. Component Responsibilities

### 4a. iOS App (Swift / MVVM)

| Layer | Hackathon Additions |
|-------|-------------------|
| **Views** | `ServerSetupFlow` (first-run onboarding), `ServerSettingsView`, `VoiceAudioSettingsView`, `QRScannerView`, `GatewayDisconnectedBanner` |
| **ViewModels** | Integration of `GatewaySessionManager` into `RemAppViewModel` |
| **Services** | `GatewayClient` (WS/HTTP to OpenClaw), `GatewaySessionManager` (session lifecycle), `GatewayApiService` (calls `/api/v1/me`) |
| **Models** | `GatewayConnectionState` enum, gateway-related protocols |

**What stays the same:** Agenda, Inbox, task CRUD, calendar integration, focus sessions, existing auth flow.
**What changes:** Voice + chat now route through GatewayClient/OpenClaw instead of a generic LiveKit agent. Settings gets new sections. Onboarding gets a gateway setup step.

### 4b. Backend (Node.js / Express)

| Responsibility | Implementation |
|---------------|----------------|
| Auth & user profile | Existing — no changes |
| Gateway metadata storage | New columns on `users` table: `gateway_url`, `gateway_token_encrypted`, `hosting_provider` |
| Gateway config API | New: `GET /api/v1/me`, `PATCH /api/v1/me/gateway` |
| LiveKit token issuance | Extended: include `gateway_url`, `gateway_token`, `openclaw_session_id` in room metadata |
| Task CRUD | Existing — no changes |

**Explicitly NOT responsible for:** Chat transcripts, semantic memory, LLM inference, conversation proxying.

### 4c. Voice Worker (Python / livekit-agents)

| Responsibility | Implementation |
|---------------|----------------|
| Join LiveKit room | `livekit-agents` SDK, dispatched by LiveKit Cloud |
| ASR | Deepgram streaming (`livekit-plugins-deepgram`) |
| TTS | Cartesia streaming (`livekit-plugins-cartesia`) — hackathon sponsor signal |
| OpenClaw relay | Python HTTP/WS client sends transcripts to user's gateway, receives responses |
| Session handshake | Reads `gateway_url`, `gateway_token`, `openclaw_session_id` from room metadata |
| Transcript publishing | Publishes user transcripts + AI responses via LiveKit data channel for iOS chat UI |

### 4d. OpenClaw Gateway (per user, on Railway)

| Responsibility | Detail |
|---------------|--------|
| Agent runtime | Sessions + workspace, long-lived process |
| Model provider | Venice (configured in OpenClaw config) |
| Persistent state | `/data` volume: `.openclaw/` state, `workspace/`, sessions, config |
| Auth | Gateway token (generated on first boot or set via env) |
| Setup page | `/setup` endpoint serving QR code with `{ gatewayUrl, gatewayToken }` |
| Tool profile | Conservative by default (messaging only, no exec/browser) |

---

## 5. Unified Session Model

The core demo proof is that text and voice share context:

```
GatewaySessionManager (iOS)
  │
  ├── currentSessionId ──────→ GatewayClient.sendMessage(sessionId, text)
  │                             (text chat path)
  │
  └── currentSessionId ──────→ LiveKit room metadata { openclaw_session_id }
                                → Voice worker reads it
                                → Voice worker calls gateway with same sessionId
                                (voice path)
```

**Session lifecycle:**
1. Created on first chat message (or during first-run connection test).
2. Persisted as `currentSessionId` in UserDefaults.
3. Resumed on app restart (OpenClaw sessions are persistent on the gateway's `/data` volume).
4. Shared across text and voice — both send messages to the same OpenClaw session.
5. New session can be created manually (stretch goal — not required for hackathon).

---

## 6. Hackathon Base Structure

These are the new files/modules created for the hackathon. All epics reference these paths as their "files in scope."

### 6a. iOS App (new hackathon files)

```
VoiceAgent/Hackathon/
├── Gateway/
│   ├── GatewayClient.swift              # WS/HTTP client for OpenClaw gateway
│   ├── GatewayClientProtocol.swift      # Protocol for testability
│   ├── GatewaySessionManager.swift      # Session lifecycle, credentials, state
│   └── GatewayApiService.swift          # Calls GET /api/v1/me, PATCH /me/gateway
├── Onboarding/
│   ├── ServerSetupFlow.swift            # "Where does Rem live?" multi-step flow
│   └── QRScannerView.swift             # Camera QR scanner for gateway credentials
├── Settings/
│   ├── ServerSettingsView.swift         # Server connection status & config
│   ├── VoiceAudioSettingsView.swift     # Voice & audio preferences
│   └── MacHelperSettingsView.swift      # Mac helper placeholder (stub)
└── Components/
    └── GatewayDisconnectedBanner.swift  # Banner shown when gateway is offline
```

### 6b. Backend (new hackathon files)

```
backend/src/
├── routes/
│   └── gateway.routes.ts               # GET /api/v1/me, PATCH /api/v1/me/gateway
├── services/
│   └── gateway.service.ts              # Gateway metadata CRUD, token encryption
└── db/migrations/
    └── 005_add_gateway_fields.sql      # gateway_url, gateway_token_encrypted, hosting_provider
```

Existing files with minor modifications (reference only, not primary hackathon scope):
- `backend/src/server.ts` — register `gateway.routes`.
- `backend/src/config/env.ts` — add `GATEWAY_ENCRYPTION_KEY`.
- `backend/src/services/livekit.service.ts` — include gateway metadata in token.
- `backend/src/routes/agent.routes.ts` — accept `sessionId` in request body.

### 6c. Voice Worker (new hackathon directory)

```
voice-worker/
├── main.py                  # LiveKit agent entry point (livekit-agents SDK)
├── openclaw_client.py       # HTTP/WS client for user's OpenClaw gateway
├── requirements.txt         # Python dependencies
├── Dockerfile               # For Railway deployment
├── .env.example             # Required env vars
└── README.md                # Setup, handshake contract, architecture notes
```

### 6d. OpenClaw Deploy Artifacts (new hackathon directory)

> Historical layout. This hosted-deploy artifact tree is operated separately and
> is not part of the open-core repo (see the Open-Core Boundary in the top-level
> `README.md`).

```
deploy/openclaw-gateway/
├── Dockerfile               # Runs openclaw gateway daemon
├── railway.toml              # Railway deployment config
├── config/                   # OpenClaw config notes (Anthropic/Venice, tool profile)
├── setup-page/
│   └── index.html            # Static /setup page: QR, device approval, reset, optional keys
├── PROTOCOL.md               # Documented WS/HTTP API shapes (from protocol validation)
└── README.md                 # Deploy instructions, env var reference, shared-demo link
```

**Shared demo:** One gateway with team’s `ANTHROPIC_API_KEY`; users connect without their own key. See [shared-demo-gateway.md](shared-demo-gateway.md).

---

## 7. Environment Variables (All Components)

### Backend
| Variable | Purpose | Required |
|----------|---------|----------|
| `DATABASE_URL` | PostgreSQL connection | Yes |
| `JWT_SECRET` | Tija JWT signing | Yes |
| `LIVEKIT_URL` | LiveKit server URL | Yes |
| `LIVEKIT_API_KEY` | LiveKit API key | Yes |
| `LIVEKIT_API_SECRET` | LiveKit API secret | Yes |
| `GATEWAY_ENCRYPTION_KEY` | AES key for encrypting gateway tokens in DB | Yes (new) |
| `LIVEKIT_AGENT_NAME` | Agent dispatch name | Dev only |

### Voice Worker
| Variable | Purpose | Required |
|----------|---------|----------|
| `LIVEKIT_URL` | LiveKit server URL | Yes |
| `LIVEKIT_API_KEY` | LiveKit API key | Yes |
| `LIVEKIT_API_SECRET` | LiveKit API secret | Yes |
| `DEEPGRAM_API_KEY` | Deepgram ASR | Yes |
| `CARTESIA_API_KEY` | Cartesia TTS | Yes |

### OpenClaw Gateway (per user)
| Variable | Purpose | Required |
|----------|---------|----------|
| `OPENCLAW_AUTH_TOKEN` / `OPENCLAW_GATEWAY_TOKEN` | Gateway access token | Yes (or generated) |
| `ANTHROPIC_API_KEY` | Anthropic model provider (default for hackathon shared demo) | Yes for shared demo |
| `VENICE_API_KEY` | Venice model provider (optional) | No |

### iOS App
| Variable | Source | Purpose |
|----------|--------|---------|
| `gatewayUrl` | Keychain (via QR scan / backend) | OpenClaw gateway URL |
| `gatewayToken` | Keychain (via QR scan) | Gateway auth token |
| `currentSessionId` | UserDefaults | Active OpenClaw session |

---

## 8. Current Implementation (Reference Only)

This section briefly summarizes the pre-hackathon architecture. It is kept for context but is **not** the target design.

### iOS App (Pre-hackathon)
- **MVVM architecture** with SwiftUI views, ViewModels, Services, Infrastructure layers.
- **Navigation:** Agenda (home), Inbox, Settings tabs. Voice launches via mic button as a full-screen overlay (`ArcVoiceView`).
- **Voice path:** iOS → LiveKit SDK → LiveKit Cloud dispatches an external agent → agent handles ASR + LLM + TTS → audio returns via LiveKit.
- **Text chat:** No direct LLM path. `sendTextMessage()` on `LiveKitSessionImplementation` is a no-op placeholder.
- **RPC handlers:** iOS registers LiveKit RPC methods (`createTask`, `bookCalendarEvent`, etc.) that a server-side agent can invoke.
- **Key protocol:** `VoiceSessionProvider` — abstraction over LiveKit, Foundation Models, and mock implementations.

### Backend (Pre-hackathon)
- **Express/Node.js** with routes: `/api/v1/auth/login`, `/api/v1/agent/token`, `/api/v1/tasks/*`, `/api/v1/health`.
- **Auth:** Apple/Google OAuth → JWT (7-day expiry).
- **LiveKit tokens:** Room-isolated (`room-{userId}-{sessionId}`), E2EE key distribution.
- **DB:** PostgreSQL + pgvector. Tables: `users`, `auth_identities`, `chat_sessions` (unused), `chat_messages` (unused), `tasks`.
- **No gateway metadata:** No `gateway_url`, `gateway_token`, or `/api/v1/me` endpoint.

### Voice Agent (Pre-hackathon)
- **No agent code in this repo.** System assumes an external LiveKit agent is deployed separately.
- The agent was the "brain" — handling ASR, LLM, TTS, and tool calls internally.
- For the hackathon, this shifts to a relay model where the agent pipes through OpenClaw.

### What's explicitly removed/replaced for hackathon
- `chat_sessions` / `chat_messages` tables are not used. Memory lives on the OpenClaw gateway.
- The generic LiveKit agent (external, not in repo) is replaced by the voice worker relay (`voice-worker/`).
- pgvector RAG is not used. No new embeddings or vector search.
