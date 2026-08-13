# Voice (macOS)

> Mac voice pipeline — STT capture via `AVAudioEngine` → `SFSpeechRecognizer` → quota reservation → `chat.send`. Mirrors iOS (`RemClaw/Sources/Voice/`) minus the iOS-only AVAudioSession, Telemetry, and Live Activity plumbing. Ships incrementally under #321 (Voice on Mac parity mini-epic).

## Key Files

| File | Purpose |
|------|---------|
| `RemMacTalkModeManager.swift` | Mac voice engine. `@Observable @MainActor`. Owns `AVAudioEngine`, input tap, noise-floor calibration, silence detection (1.5s window in VAD mode), speech recognizer lifecycle, `VoiceInputMode` (VAD vs push-to-talk), quota-gated send, and the send-to-gateway path. A known exhausted balance or ambiguous prior reservation keeps capture muted; after capture, the transcript is cleared and published as sent only after quota reservation and an accepted gateway run. Its effective voice/model/output settings come from normalized, non-secret `talk.config`, preferring the canonical selected-provider block with legacy flat fallback and replacing omitted values rather than retaining stale state. Each transcript or composer response resolves and pins a fresh configuration snapshot at its utterance boundary, so current audio drains unchanged and a newly saved voice applies to the next response in the same session. Observes `NSWindow` key/resign transitions for future tuning (currently keeps listening across resign-key per #321 locked design #4 — matches iOS backgrounding behavior). |
| `Shared/Services/BufferedMP3AudioPlayer.swift` | Shared iOS/macOS completion-backed playback for complete gateway MP3 assets; preserves large paragraphs and ordered segment drain. |
| `Shared/Services/VoiceRecognitionRequestConfiguration.swift` | Shared iOS/macOS Apple speech request policy. Selects dictation mode and recognizer-produced automatic punctuation. |
| `VoiceInputMode.swift` | Structured enum (`vad` / `pushToTalk`) + `UserDefaults` persistence (`rem.voice.mode`). Mac-only — iOS voice is VAD-only. |
| `PushToTalkKeyMonitor.swift` | App-focus-scoped `NSEvent.addLocalMonitorForEvents` for spacebar `keyDown`/`keyUp`. Drives `RemMacTalkModeManager.beginPushToTalkCapture` / `endPushToTalkCapture`. Global hotkey is out of scope (requires Accessibility permission). |

## Scope by PR

- **PR 1**: STT only. Tap mic → capture → transcribe → silence detects end of utterance → `chat.send`. The shared chat view streams the assistant response back as text. No TTS playback, no echo detection.
- **PR 2**: TTS playback via the authenticated gateway's configured `talk.speak` provider, with structured system-speech fallback, incremental speech buffering, mini-bar mute toggle, and default input device route handling via CoreAudio. Mirrors iOS `RemTalkModeManager.playAssistant` + `streamAssistant` + `handleRouteChange`.
- **PR 3** (this file): Push-to-talk mode as an alternative to VAD. User holds spacebar → capture; release → send immediately. App-focus-scoped only (no global hotkey). Persisted per-user via `UserDefaults` (`rem.voice.mode`). Mini-bar exposes a mode-toggle button. iOS has no PTT equivalent — this is a Mac-first divergence, noted in the PR body.
- **Later**: Upstream's 71-ref prefetch pipeline port, menu bar indicators, configurable PTT key binding.

## Architecture Notes

- **Source of truth**: `RemMacTalkModeManager`'s `@Observable` properties. Views read them through the optional hooks on `SharedRemChatView` (`onVoiceTap`, `voiceTranscriptionState`, `onEndVoice`, `voiceStatusText`, `voiceIsMuted`).
- **Gateway wiring**: `MacChatWindow` owns the manager instance and injects `session.client.chatSession` (the operator WebSocket) into it on voice start. Chat messages sent via voice flow through the same session as text chat, so voice + text share conversation context.
- **Quota and route lifecycle**: `MacChatWindow` injects the same `MacQuotaService` used by text chat. Known exhaustion, persisted ambiguity, and an accepted reservation still awaiting gateway run acknowledgement block start/unmute. Unknown usage may capture, but the manager stays fail-closed at the request boundary: it preserves the captured transcript only for its originating session, mutes, and surfaces truthful recovery unless the backend reservation succeeds. An HTTP 200 yields an exact durable token; Talk Mode retains it until `chat.send` returns the captured session's run ID, and only that accepted run plus current route authority publishes the transcript as sent. Stop before the worker begins prevents a later send; stop after dispatch waits for that exact run, retires the token, then aborts it. Composer takeover uses the same boundary: before gateway start it prevents the stale voice send and records the exact pre-dispatch disposition; after start it waits for acceptance, retires the token, and aborts only that run before the composer subscriber may consume assistant deltas. A failed exact Stop abort remains typed pending state, is retried before any later quota reservation/send, and clears only after success. Every session update, including same-key reattachment, cancels the active turn, advances an opaque attachment generation, and retains one joinable resolution chain so a later session's composer cannot subscribe ahead of any older accepted-run abort. Quota, send, completion, history, and speech continuations must still own both the captured key and generation before publishing, while composer and incremental speech workers additionally require their UUID owner and incremental generation, so overlapping work and A→B→A cannot revive an old turn or clear its replacement.
- **Gateway-backed voice choice and playback**: Shared Agent Settings → Voice owns the cross-device selection. Dynamic names come from `talk.voices`; previews and actual Mac playback both use attempt-scoped `talk.speak`/`talk.speak.cancel`, so the saved provider, voice, and credentials remain gateway-owned.
- **Working status**: The shared chat indicator remains visible through `Thinking...` and `Generating voice...`, then clears when audible speech begins.
- **Ordered playback + gap mitigation**: Gateway Talk playback has one buffered wire contract: canonical MP3. Mac requests buffered MP3 for full-turn and prefetched segments, validates the response descriptor and MP3 signature before playback, and routes every complete asset through the shared completion-backed player so large paragraphs remain intact and the queue advances only after audible drain. The Mac manager mirrors iOS next-sentence prefetch: while one segment plays, the next exact segment/request context is synthesized through `talk.speak` and consumed in order; reset, interruption, context drift, and cancellation discard it and send exact provider-side cancellation. A complete audible multi-sentence turn remains required #1136 acceptance evidence.
- **Permissions**: macOS uses `AVCaptureDevice.requestAccess(for: .audio)` for the mic (NOT iOS's `AVAudioSession.requestRecordPermission`). Speech auth uses the same `SFSpeechRecognizer.requestAuthorization` as iOS. Usage descriptions live in the Mac target's build settings (`INFOPLIST_KEY_NSMicrophoneUsageDescription`, `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription`).
- **Hardened runtime**: `RemClawMac.entitlements` declares `com.apple.security.device.audio-input` — required for mic capture under hardened runtime even when sandbox is disabled.

## State Machine

```
idle
  ├─ (user taps Speak button)
  │  └─> start()
  │       ├─ inputMode == .vad      → listening
  │       └─ inputMode == .pushToTalk → ptt-armed
  └─ (gateway disconnects while enabled)
     └─> statusText = "Offline"

listening                      // VAD path
  ├─ (silence 1.5s after utterance)
  │  └─> processTranscript() → thinking
  ├─ (user taps mute)
  │  └─> mute() → muted
  ├─ (user taps hang up)
  │  └─> stop() → idle
  ├─ (user toggles mode to push-to-talk)
  │  └─> setInputMode(.pushToTalk) → ptt-armed
  ├─ (default input device changes, via CoreAudio listener)
  │  └─> restart recognition on new device
  └─ (recognizer error)
     └─> restart recognition inline

ptt-armed                      // PTT path, key monitor active, mic idle
  ├─ (spacebar keyDown, local monitor)
  │  └─> beginPushToTalkCapture() → ptt-holding
  ├─ (user taps mute)
  │  └─> mute() → muted (monitor disarmed)
  ├─ (user toggles mode to auto)
  │  └─> setInputMode(.vad) → listening
  └─ (user taps hang up)
     └─> stop() → idle

ptt-holding                    // spacebar held, recognizer running
  ├─ (spacebar keyUp, non-empty transcript)
  │  └─> endPushToTalkCapture() → processTranscript() → thinking
  ├─ (spacebar keyUp, empty transcript)
  │  └─> stopRecognition() → ptt-armed
  ├─ (default input device changes)
  │  └─> stopRecognition() → ptt-armed (release+repress picks up new device)
  └─ (recognizer error)
     └─> stopRecognition() → ptt-armed

muted
  └─ (user taps mute again)
     └─> unmute() → start() → listening | ptt-armed (mode-dependent)

thinking                      // chat.send in flight
  ├─ (chat.send returns runId)
  │  └─> streaming → speaking
  ├─ (chat state == "aborted" | "error")
  │  └─> statusText = "Chat error" → start() → listening | ptt-armed
  └─ (network/send failure)
     └─> statusText = "Talk failed: ..." → start() → listening | ptt-armed

speaking                      // ElevenLabs or system synthesizer
  ├─ (playback finishes)
  │  └─> start() → listening | ptt-armed
  ├─ (user starts talking, novel words) [VAD only]
  │  └─> stopSpeaking() → listening
  └─ (end voice)
     └─> stop() → idle
```

`processTranscript()` reserves quota before dispatch, but enters the sent-message portion of `thinking` only after `chat.send` returns an accepted run while the captured route still owns the turn. A 429 or unavailable authority preserves the transcript for its exact session and mutes Talk Mode; an ambiguous result or accepted slot without a gateway-acknowledged run additionally blocks retry across relaunch for that account/backend so it cannot be counted twice.

Source of truth: `RemMacTalkModeManager`. Mode persistence: `VoiceInputMode.stored` → `UserDefaults.standard` (`rem.voice.mode`). Recovery: any mic/engine/network error returns to the mode-appropriate idle state (`listening` for VAD, `ptt-armed` for PTT) with the failure surfaced through `statusText` — which the shared mini-bar displays.

## PTT trigger scoping

`PushToTalkKeyMonitor` uses `NSEvent.addLocalMonitorForEvents` — the monitor only observes events while Rem is the active app. When the user alt-tabs to another app, spacebar returns to that app's control. This is intentional (#321 PR 3 locked design #5): global hotkeys require Accessibility permission, which is out of scope for this PR. If the user is typing in a text field within Rem, the monitor also passes the space through so the composer remains usable.

## Non-goals for PR 3

- Global hotkey / system-wide PTT (requires Accessibility permission) — separate work.
- Configurable PTT key (always spacebar for now) — separate work.
- iOS PTT — iOS is VAD-only; no port in this PR.
- Upstream 71-ref prefetch pipeline — tracked separately in voice memory.
- Menu bar / Live Activity indicators — separate work.
- Telemetry events — Mac has no PostHog wiring yet.
- Device-context text injection — both native clients register identity/capabilities through the
  gateway protocol and keep transcript text raw; Mac Talk Mode intentionally follows that shared
  structured-context contract.
