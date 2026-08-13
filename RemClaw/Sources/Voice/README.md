# Voice (iOS)

> The voice mode engine. Listens to you via microphone, converts speech to text on-device, sends it to the AI through the same chat channel, then asks the authenticated gateway to synthesize the configured provider and voice. Includes echo detection so it doesn't hear itself, Siri Shortcuts integration, and a Dynamic Island display for active sessions.

Voice-to-text-to-voice pipeline with speech recognition, TTS playback, echo detection, and gateway chat integration.

## Directory Structure

```
Voice/
├── RemTalkModeManager.swift       # Core voice engine (1,440 lines)
├── CustomFaceShape.swift          # Voice RemAnimatedFaceView (outline shape now shared)
├── RemMessageModel.swift          # Protocol-independent message model
├── DraftManager.swift             # Staged task/event drafts during voice
├── VoiceSessionControl.swift      # Deep link & command routing
├── VoiceSessionIntent.swift       # Siri Shortcuts & Control Center intents
├── VoiceSessionLiveActivity.swift # Dynamic Island / Live Activity
├── VoiceSessionSharedState.swift  # App Group state for widgets
└── RPC/
    └── TaskRpcModels.swift        # Codable models for gateway RPC calls
```

## Key Files

| File | Purpose |
|------|---------|
| `RemTalkModeManager.swift` | Complete voice pipeline: AVAudioEngine capture → SFSpeechRecognizer STT → gateway chat RPC → authenticated gateway `talk.speak` synthesis and native playback. Includes noise floor calibration, silence detection (1.5s timeout), multi-layer echo prevention, quota-aware rate limiting, and generation-guarded Read/Stop/Retry app-prose playback. Explicit multi-paragraph narration uses a testable bounded sequential executor, exposes truthful completed/total chunk progress, and does not complete until every chunk finishes. Initial playback and failed retry both require the same full account + gateway + session + local-day + artifact-fingerprint context; changing it cancels active audio/generation and rejects the receipt, while teardown, nil session, intentional Stop, manual unmute/new playback, or success clear retained recovery state. Its effective voice/model/output settings come from normalized, non-secret `talk.config`, preferring the canonical selected-provider block with legacy flat fallback and replacing omitted values rather than retaining stale state. Each transcript or composer response resolves and pins a fresh configuration snapshot at its utterance boundary, so current audio drains unchanged and a newly saved voice applies to the next response in the same session. |
| `Shared/Services/BufferedMP3AudioPlayer.swift` | Shared iOS/macOS completion-backed playback for complete gateway MP3 assets; preserves large paragraphs and ordered segment drain. |
| `Shared/Services/VoiceRecognitionRequestConfiguration.swift` | Cross-platform Apple speech request policy. Uses dictation mode and recognizer-produced automatic punctuation for both iOS and macOS transcripts. |
| `CustomFaceShape.swift` | Voice-driven `RemAnimatedFaceView` — strokes the shared `CustomFaceShape` (now in `Shared/Views/RemFaceMark.swift`) with eyes that blink/pulse based on speaking/listening state. Stays iOS-only because it binds to `RemTalkModeManager`. |
| `DraftManager.swift` | Manages staged drafts (tasks/events) created during voice sessions. State machine: draft visibility → persistence → task creation. |
| `VoiceSessionControl.swift` | Deep link routing (`remclaw://voice/{command}`) with `VoiceSessionControlRouter` command queue and token-based deduplication. |
| `VoiceSessionIntent.swift` | AppIntent implementations for Siri Shortcuts: `ToggleVoiceSessionIntent`, `StartVoiceSessionIntent`, `StopVoiceSessionIntent`. Triggers via shared state + notification. |
| `VoiceSessionLiveActivity.swift` | ActivityKit integration for Dynamic Island display during active voice sessions (iOS 16.1+). |
| `VoiceSessionSharedState.swift` | App Group (`group.com.remapp.rem`) UserDefaults for cross-process state (widget/Control Center communication). |

## Architecture

```
RemChatView / ContentView (UI)
    ↓ bind to
RemTalkModeManager (core engine)
    ├── STT: AVAudioEngine → SFSpeechRecognizer
    ├── TTS: gateway-selected provider via `talk.speak`
    ├── Chat: gateway RPC via operator session
    ├── Drafts: DraftManager for staged tasks
    └── Messages: RemMessageModel array

VoiceSessionIntent (Siri/Shortcuts)
    → VoiceSessionSharedState (App Groups)
    → VoiceSessionControl (deep link router)
    → RemTalkModeManager

VoiceSessionLiveActivity (Dynamic Island)
    ← observes RemTalkModeManager state
```

## Patterns & Conventions

- **Gateway-first**: No separate voice server — reuses existing chat gateway infrastructure with RPC calls.
- **Gateway-backed voice choice and playback**: Agent Settings → Voice reads `talk.catalog`, normalized non-secret `talk.config`, and the active provider's dynamic `talk.voices` catalog over the operator leg. Preview and actual Talk playback both use attempt-scoped `talk.speak` plus `talk.speak.cancel`, so the saved provider/voice and credentials remain gateway-owned. Selection writes the canonical `talk.providers.<provider>.voiceId` merge patch with a fresh hash and confirms it after restart. System speech is used only when the gateway explicitly marks a provider/configuration failure as fallback-eligible.
- **Structured native context**: Before each Talk Mode `chat.send`, the session is patched with
  `verboseLevel=on` and this device's registered `execNode`; spoken text stays unmodified and no
  synthetic system preamble is added to the transcript.
- **Echo detection**: Multi-layered prevention — post-TTS silence window, word-level matching against recently spoken text, substring comparison, audio routing detection, and generation-owned speech-recognition callbacks. Cancelling a recognizer invalidates its generation before Apple can deliver a late final result, so assistant TTS captured by a retired barge-in recognizer cannot become a new user turn.
- **Noise floor calibration**: Statistical approach using first ~1 second of audio to set silence threshold.
- **Quota-aware**: Each voice turn proceeds only after the backend authoritatively reserves one chat quota slot, with one unresolved reservation per account plus normalized backend. A committed 200 persists an opaque token before mutable authority retirement and Talk Mode retains it through `chat.send` acceptance. If composer takeover retires the turn after that 200 but before dispatch, the exact token is terminally disposed while the already-consumed quota unit remains charged, so stale speech is neither sent nor retried and another account's reservation is untouched. Teardown awaits the accepted run ID, clears that exact token, then aborts that exact run; abort transport failure is surfaced with the exact accepted session/run identity and retained for retry before another voice turn instead of being swallowed. Recognized speech and every async tail are owned by an opaque attachment generation captured before task scheduling; cancellation and route authority are checked before any turn mutation or quota request. Navigation, same-key reattachment, empty detach, and Stop invalidate that authority. Transcript turns retain their entry generation through pending-abort recovery, quota reservation, and gateway acceptance, then carry their newly established speech generation through every stream delta, no-reply/catch tail, final handler, tail flush, defer, and restart. Thus same-route barge-in or composer takeover cannot let a suspended transcript reset, clear, idle, or pollute replacement speech. Incremental-speech and composer-stream task slots also carry UUID owners; composer streaming and finalization additionally capture the incremental generation, so an A→B→A stale task cannot clear or cancel the replacement A task, tail flush, or speech state.
- **Working status**: The shared chat indicator remains visible through `Thinking...` and `Generating voice...`, then clears when audible speech begins.
- **Brief-to-conversation continuity**: Agenda's `Read latest brief` opens the durable Today conversation and freshly resolves the exact backend-authored artifact that `/brief` reports as delivered. The client never guesses brief identity from message adjacency, headings, provider, or model; this prevents normal tool-assisted replies from becoming Agenda summaries or narration. Ordinary replies, mismatched injections, and stale Agenda cache cannot become narration. A newer notification Read command synchronously stops already-audible stale prose, then cancels and request-ID-invalidates the older in-flight read; cancellation cleanup explicitly stops continuation-backed players, so a failed replacement cannot strand playback state. Router ownership is acknowledged only after the replacement request actually starts. Reading begins with the microphone muted; the leading mic remains available for intentional barge-in, while the trailing control stops reading. Multi-paragraph prose is synthesized and played as ordered bounded chunks; intermediate chunk completion keeps the stop control and muted state. Final completion removes Stop, unmutes, resumes listening, and persists the account-, local-day-, and transcript-fingerprint-qualified completion receipt that changes Agenda to `Read again`. Intentional Stop also hands off to listening but never records a receipt. Synthesis/player failure remains muted and non-listening and exposes `Retry` in both mini bars. Retry validates the retained text and receipt callback against the current account, gateway URL, durable session, local day, and exact brief fingerprint before playback and again before receipt; a newer morning/midday/night artifact in the same `rem-orchestrator` session therefore invalidates the old recovery. Repeated failure remains recoverable only in the unchanged context.
- **Ordered playback + gap mitigation**: Gateway Talk playback has one buffered wire contract: canonical MP3. The client requests buffered MP3 for full-turn and prefetched segments, validates the response descriptor and MP3 signature before playback, and never routes WAV/generic PCM into the MP3 player. Every complete `talk.speak` asset uses completion-backed `AVAudioPlayer` playback so a large paragraph is retained intact and the ordered queue advances only after the audible file drains. While one segment plays, the next exact segment/request context is synthesized through `talk.speak` and consumed in order. Reset, interruption, context drift, and turn cancellation discard prefetched audio and send the exact provider-side cancellation. A complete audible multi-sentence turn remains required #1136 acceptance evidence.
- **Cross-process control**: App Group shared state + URL deep links enable Control Center and Siri Shortcuts integration.
- **Recognizer-owned punctuation**: Both platforms apply the shared speech request policy; transcript punctuation comes from Apple dictation rather than client-side guessing.
- **Codable RPC models**: `TaskRpcModels` use `CodingKeys` for snake_case ↔ camelCase JSON bridging with the gateway.
