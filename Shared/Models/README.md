# Shared/Models

Shared data models used by both iOS and macOS targets.

## Files

| File | Purpose |
|------|---------|
| `BackgroundSessionFilter.swift` | Cross-platform classifier that hides internal gateway runs from chat history, including canonical `agent:<id>:` keys and upstream managed-memory sessions, while preserving user task, daily-brief, and automation chats. |
| `BriefSessionListDeduplicator.swift` | Shared presentation-only collapse for the current-day artifact-only `rem-today-*` rollout bridge when the identical durable `rem-orchestrator` row exists. Unknown token evidence, model-used or locally-replied legacy sessions, malformed/historical days, and unmatched previews remain visible and recoverable. |
| `DiscoveredGateway.swift` | Bonjour-discovered gateway record (id/name/host/port). Drives the Nearby Gateways UI. |
| `GatewayConfig.swift` | Persisted gateway record with `provider: GatewayProvider` discriminator. The cross-cloud-and-local lifeline. |
| `GatewaySetupCode.swift` | Pasteable / scannable pairing payload. Decodes both the Rem format (`{url, token, ...}`) and upstream's `openclaw qr` format (`{url, bootstrapToken}`). |
| `LinkedDevice.swift` | Shared LinkedDevice, DevicePlatform, DeviceToken models + LinkedDevicesResponse. Cross-platform device name resolution (UIDevice on iOS, Host on macOS). |
| `MacNativeSettingsTab.swift` | Legacy native Settings window-title list used only to hide old/native Settings windows that may be restored from earlier builds after routing to the canonical in-app Settings surface. |
| `MainWindowScreenRoute.swift` | Typed notification payloads for opening macOS main-window routes from auxiliary surfaces like app commands and the menu bar popover. |
| `PendingDevice.swift` | A pairing request the gateway is holding for approval. |
| `SessionListPagination.swift` | Shared authoritative-window policy for growing Chat Sessions through server pages, including filtered-only windows. |
| `SessionListEnrichmentFallback.swift` | Restricts enriched `sessions.list` compatibility fallback to structured `INVALID_REQUEST` schema rejections so outages and cancellation are never retried as legacy gateways. |
| `SessionsListViewState.swift` | Pure loading/error/empty-state resolver used by the Mac Sessions surface and unit tests. |
| `SkillModels.swift` | Shared SkillEntry, SkillFilter, SkillsStatusResponse and related types, including user-facing missing requirement copy. |
| `TaskDeemphasis.swift` | `TaskDeemphasisReason` (`blocked` / `stale`) plus the pure resolver that reads `status` and `stale_at` **together**. Staleness (migration 116) is a separate column, never a `status` value, so a task can be blocked *and* stale and the resolver returns BOTH — one visual de-emphasis, two distinct labels (the founder's decision). Timestamp and boolean overloads keep `GET /tasks` (`stale_at`) and `GET /brief` (`is_stale`) on one rule. Foundation-only and view-free, so it is unit-testable without a simulator. |
| `SuggestionBriefRelevance.swift` | Pure, deterministic ordering of `TaskSuggestion`s by lexical overlap with the brief they render beside — decides which ones make `SharedSuggestionSection`'s bounded inline set. Title matches weigh double; three classes of word are stop-listed so they cannot tie the whole list at the top — ordinary filler, deriver vocabulary ("overdue", "calendar"), and connected-source names ("gmail", "slack", #1302); a nil/empty/non-overlapping brief returns the deriver's order untouched. Ties keep source order, so a row never reshuffles between frames. |
| `TaskSuggestion.swift` | Shared attributed proposal models and current-day revision snapshot identity. Atomic snapshots require the backend brief revision and exact response ID; prose identity is optional only for truthful connected-source-only days. Every proposal has a backend-issued UUID action identity, reused as a create-task UUID so retries remain idempotent even when a refreshed proposed time moves. |
| `McpServerModels.swift` | Loose shared `config.get` response subtrees, MCP server config models + lifecycle enum, and the `JSONValue` helper. Model Settings reads only exact provider/model identity from `config.models.providers` when an older gateway cannot attest catalog completeness; unknown provider fields remain tolerated. Mirrors upstream `McpServerConfig` (`openclaw/src/config/types.mcp.ts`). #338. |
| `VoiceTuningSettings.swift` | User-chosen speech parameters (speed, stability, likeness) plus their persistence and the `GatewayTalkSpeechRequest.applyingTuning` merge. Device-local UserDefaults, deliberately **not** gateway config: a Talk `config.patch` queues a gateway restart, which is right for picking a voice and unusable for a slider. Values instead ride `talk.speak` params, which is also the only path the provider reads — ElevenLabs' `resolveTalkOverrides` consumes `params` and never the stored provider config. Ranges are copied from the upstream gate that runs immediately before the provider HTTP call (`assertElevenLabsVoiceSettings` → `requireInRange`), so a slider cannot produce an out-of-range synthesis failure. Fields are optional: unset means "the agent decides" and is omitted from the payload rather than sent as our idea of the default. A directive (`[[tts:...]]`) outranks the user setting, mirroring the existing voiceId precedence chain. `VoiceTuningProviderSupport` gates the ElevenLabs-only character parameters, because the OpenAI-compatible providers' `resolveTalkOverrides` maps only voiceId/modelId/speed and drops the rest. |
| `VoiceSettingsModels.swift` | Non-secret `talk.catalog` / `talk.config` / `talk.voices` response models, truthful older-gateway recovery for unsupported Voice methods, and a catalog policy that uses metadata/config to identify the provider while leaving actual readiness to `talk.voices` (older gateways can expose a stale `configured` hint). Also owns provider-aware readback matching, canonical `talk.providers.<provider>.voiceId` fresh-hash patches, and attempt-scoped preview command tokens. Runtime reads prefer the canonical selected provider and use flat Talk values only as an older-gateway fallback. Provider implementation names stay out of the user-facing Voice screen. |
| `ToolResultPayloads.swift` | JSON shapes returned by AI node commands (`calendar.events`, `reminders.list`, `device.status`, `device.info`). Consumed by the chat tool-result cards in `Shared/Views/Chat/ToolResultCards/`. |
| `UsageModels.swift` | Backend request-quota payloads plus shared plan/status, summary-state, UTC reset-deadline/freshness, and daily-vs-monthly exhaustion presentation policies. Platform quota services schedule observable invalidations from the shared deadline. Only exact Free/Pro evidence yields upgrade/manage actions; unknown plans use a neutral refresh action on both platforms. |
| `UserProfile.swift` | Authenticated user identity (Apple Sign-In / Google Sign-In). |

## Why local and cloud gateway data differ

Both kinds of gateway are represented by the same `GatewayConfig` struct (URL + token + provider + display name). That's the **app-facing model** — the user sees "a gateway" regardless of where it runs, like the system Wi-Fi list shows "a network" regardless of whether it's home or a cafe.

Underneath, the *fields* available diverge because the runtimes are different:

| Concept | Cloud (Fly.io) | Local Mac |
|--------|----------------|-----------|
| Where it runs | Per-user app `remclaw-{userId[:8]}` on Fly | `openclaw-gateway` child process owned by the Rem Mac app; upstream LaunchAgent only if the user installed it manually |
| Auth credential | Backend mints + holds the gateway token | CLI mints; lives in `~/.openclaw/openclaw.json` |
| Setup password | Backend stores it (Fly machine env var) | Not currently configured for local |
| Bind mode | Always `auto` (Fly assigns a public URL) | User-controlled: `loopback` / `lan` / `tailnet` / `custom` |
| Discoverability | Backend returns the URL after deploy | Bonjour `_openclaw-gw._tcp` advertises on LAN |
| Pairing approval | Backend auto-approves via `openclaw-control-ui` + setup password | Mac app approves locally; no backend involvement |
| Failure recovery | Re-pair via app or re-deploy via backend | Re-pair via app or `openclaw devices clear` from terminal |
| Lifecycle ops | Backend API endpoints (deploy, destroy, status) | Mac app child-process start/stop; CLI status/install only for externally managed upstream lifecycle |

## What this means for shared UI

When a Shared view renders a gateway (`SharedGatewayDetailView`, etc.), it should:

- **Read from `GatewayConfig`** for everything user-facing (name, URL, status).
- **Branch on `config.provider`** *only* for fields that genuinely don't exist on the other side (bind mode is local-only, Fly app name is cloud-only).
- **Avoid one-off `if isLocal` UI variants**. If both providers can express a concept (paired devices, BYOK, reset pairing), expose one component used by both.

The **pattern is "one model, conditional fields"** — the gateway is the gateway; some knobs are platform-conditioned.

## When fields are inherently cloud-only or local-only

- **Local-only** (no cloud equivalent): Bind mode, child-process / externally-managed lifecycle state, local config-file path, CLI-installed version
- **Cloud-only** (no local equivalent today): Fly app name, deployment status, backend-managed setup password, public Fly URL
- **Different shape, same concept**: Pairing approval (Mac-app-approves vs backend-auto-approves), recovery (Reset Pairing button vs re-deploy)
