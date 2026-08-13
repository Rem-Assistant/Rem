import AVFoundation
import AppKit
import CoreAudio
import Foundation
import Observation
import OSLog
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import Speech

enum MacVoiceQuotaCaptureDecision: Equatable {
    case allowed
    case quotaExceeded(QuotaPresentation)
    case verificationUnavailable
    case reservationRetryBlocked
}

enum MacVoiceQuotaCapturePolicy {
    static func decision(
        serviceAttached: Bool,
        reservationRetryBlocked: Bool,
        latestRemaining: RemainingQuota?
    ) -> MacVoiceQuotaCaptureDecision {
        guard serviceAttached else { return .verificationUnavailable }
        guard !reservationRetryBlocked else { return .reservationRetryBlocked }
        if let presentation = QuotaPresentation.currentDenial(
            plan: nil,
            remaining: latestRemaining
        ) {
            return .quotaExceeded(presentation)
        }
        return .allowed
    }
}

enum MacTalkChatCompletionState: Equatable, Sendable {
    case final, aborted, error, timeout
}

/// macOS voice mode manager — a Mac-specific fork of iOS `RemTalkModeManager`.
///
/// Mirrors the iOS pipeline (`RemClaw/Sources/Voice/RemTalkModeManager.swift`)
/// but strips iOS-only dependencies:
///   - `AVAudioSession` (iOS only) → macOS relies on the system default
///     input/output device, no explicit session/category setup is required
///     for `AVAudioEngine`.
///   - `UsageService` quota → `MacQuotaService`, which uses Mac's account-generation
///     authority and blocks ambiguous reservation retries.
///   - `TelemetryService` (PostHog on iOS only) → noop on Mac.
///   - Live Activities / App Groups / Siri Shortcuts → iOS-only, omitted.
///
/// PR 2 scope (#321): STT (shipped in PR 1) plus TTS playback via the shared
/// authenticated gateway `talk.speak` + structured system fallback path, incremental speech
/// buffering, composer-triggered speech (`speakNextResponse`), and default
/// input device route handling via `CoreAudio`
/// (`kAudioHardwarePropertyDefaultInputDevice`) — the Mac equivalent of
/// iOS's `AVAudioSession.routeChangeNotification`.
///
/// Source of truth for voice state: the `@Observable` properties below. Views
/// read them via the `talkMode` reference passed through
/// `SharedRemChatView`.
///
/// State machine (#321 PR 2):
///   idle → (tap mic) → listening → (silence 1.5s) → transcribing →
///   (chat.send succeeds) → thinking → speaking → listening
///   any → (end button / stop) → idle
///   on error (mic/engine/network): return to idle, surface via `statusText`.
@MainActor
@Observable
// swiftlint:disable type_body_length
final class RemMacTalkModeManager: NSObject {
    typealias ChatLifecycleRequester = @Sendable (
        _ method: String,
        _ paramsJSON: String?,
        _ timeoutSeconds: Int
    ) async throws -> Data

    // MARK: - Voice transcription state (chat view bridge)

    /// Mirrors the iOS enum (see `RemTalkModeManager.VoiceTranscriptionState`).
    /// Kept here as a Mac-local type so the shared view's
    /// `SharedRemChatView.VoiceTranscriptionState` bridge can be populated
    /// without importing iOS types into Mac-only code.
    enum VoiceTranscriptionState: Equatable {
        case idle
        case transcribing(String)
        case sent(String)
    }

    // MARK: - Observable state

    var isEnabled: Bool = false
    var isListening: Bool = false
    var isMuted: Bool = false
    var isSpeaking: Bool = false
    var statusText: String = "Off"
    var responsePhase: VoiceResponsePhase = .idle
    /// 0..1 mic level for UI visualization.
    var micLevel: Double = 0
    /// Current voice transcription state for inline chat view rendering.
    var transcriptionState: VoiceTranscriptionState = .idle
    /// Texts of all voice-sent messages this session (persists for "Transcribed" label).
    var voiceTranscripts: Set<String> = []

    // MARK: - Voice input mode (#321 PR 3)
    //
    // Mac-only addition — iOS `RemTalkModeManager` is VAD-only and has no PTT
    // path. `inputMode` is the in-memory source of truth; it is seeded from
    // `UserDefaults.standard` via `VoiceInputMode.stored` on init and re-read
    // on each `start()` so a mid-session toggle takes effect on the next
    // voice turn without needing to tear down the whole session.
    //
    // `isHoldingPTT` drives the "Listening (hold)…" status copy in the
    // mini-bar so the user sees distinct feedback from VAD's "Listening…".

    var inputMode: VoiceInputMode = VoiceInputMode.stored
    /// True while the PTT key is physically held. Only meaningful when
    /// `inputMode == .pushToTalk`.
    var isHoldingPTT: Bool = false

    // MARK: - Configuration
    //
    // Mirrors `RemTalkModeManager`: the effective voice/model/output selection
    // is read from non-secret `talk.config`, while synthesis credentials and
    // provider dispatch remain exclusively on the authenticated gateway.

    private var defaultVoiceId: String?
    private var currentVoiceId: String?
    private var defaultModelId: String?
    private var currentModelId: String?
    private var defaultOutputFormat: String?
    private var interruptOnSpeech: Bool = true

    // MARK: - Audio engine & STT

    private let audioEngine = AVAudioEngine()
    private var inputTapInstalled = false
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?

    // MARK: - Silence detection

    private let silenceWindow: TimeInterval = 1.5
    private var lastHeard: Date?
    private var lastAudioActivity: Date?
    private var lastTranscript: String = ""
    private var preservedTranscriptSessionKey: String?
    private var noiseFloorSamples: [Double] = []
    private var noiseFloor: Double?
    private var noiseFloorReady: Bool = false

    /// Text chat and Talk Mode share one account/backend reservation ledger so neither path can
    /// replay an ambiguous consume request from the other.
    private var quotaService: MacQuotaService?

    // MARK: - TTS state
    //
    // Mirrors iOS `RemTalkModeManager` TTS fields (lines 82-106). Echo
    // detection (`spokenTextAccumulator`, `lastSpeakEndTime`) is preserved
    // because Mac users may play TTS through the built-in speaker while the
    // mic is live — the same echo path exists on Mac.

    private var lastSpokenText: String?
    private var spokenTextAccumulator: String = ""
    private var lastSpeakEndTime: Date?
    private var lastInterruptedAtSeconds: Double?
    private var lastPlaybackWasPCM: Bool = false
    private var lastPlaybackWasBufferedMP3: Bool = false
    var pcmPlayer: PCMStreamingAudioPlaying = PCMStreamingAudioPlayer.shared
    var mp3Player: StreamingAudioPlaying = StreamingAudioPlayer.shared
    var bufferedMP3Player: BufferedMP3AudioPlaying = BufferedMP3AudioPlayer.shared

    // MARK: - Incremental TTS
    //
    // Mirrors iOS `RemTalkModeManager` incremental TTS fields (lines 96-103).

    private var incrementalSpeechQueue: [String] = []
    private var incrementalSpeechTask: Task<Void, Never>?
    private var incrementalSpeechTaskOwner: UUID?
    private var incrementalSpeechGeneration: UInt64 = 0
    private var incrementalSpeechActive = false
    private var incrementalSpeechUsed = false
    private var incrementalSpeechLanguage: String?
    private var incrementalSpeechBuffer = MacIncrementalSpeechBuffer()
    private var incrementalSpeechContext: MacIncrementalSpeechContext?
    private var incrementalSpeechDirective: TalkDirective?
    /// Each response owns one immutable provider/model/voice snapshot. The next response clears
    /// this flag and re-reads gateway-owned `talk.config` without disturbing current playback.
    private var incrementalSpeechConfigurationResolved = false
    private var incrementalSpeechPrefetch: MacIncrementalSpeechPrefetchState?
    private var incrementalSpeechPrefetchMonitorTask: Task<Void, Never>?
    /// Last moment speech output genuinely progressed (turn start / segment queued / playback ended).
    /// Powers the stuck-flag watchdog in `isSpeechOutputActive` so a chat run that ends WITHOUT a
    /// `final` event can't leave `incrementalSpeechActive` pinned `true` forever. Mirrors iOS.
    private var lastSpeechProgressTime: Date?
    /// How long the incremental-speech flags may stay set with NO real playback/progress before the
    /// watchdog declares output inactive. Generous vs. normal inter-segment gaps; `isSpeaking`
    /// short-circuits it so active speech is never clipped. Mirrors iOS.
    private let speechStaleWindow: TimeInterval = 8

    /// Tracks the in-flight processTranscript task so stop() can cancel it.
    var activeTranscriptTask: Task<Void, Never>?
    private var displacedTranscriptResolutionTask: Task<Void, Never>?
    private var displacedTranscriptResolutionOwner: UUID?
    /// Streams assistant text for composer-initiated turns while voice is on.
    private var composerStreamingTask: Task<Void, Never>?
    private var composerStreamingTaskOwner: UUID?

    private struct PendingAcceptedVoiceAbort {
        let id: UUID
        let sessionKey: String
        let runID: String
        let gateway: GatewayNodeSession
        let requester: ChatLifecycleRequester?
    }
    private var pendingAcceptedVoiceAbort: PendingAcceptedVoiceAbort?

    // MARK: - Gateway

    private var gateway: GatewayNodeSession?
    private let gatewaySpeech = GatewayTalkSpeechService()
    @ObservationIgnored var talkConfigRequestForTesting: (@Sendable () async throws -> Data)?
    @ObservationIgnored var chatLifecycleRequester: ChatLifecycleRequester?
    @ObservationIgnored var beforeChatGatewayStart: (@Sendable () async -> Void)?
    @ObservationIgnored var chatCompletionWaiter: (@Sendable (String) async -> MacTalkChatCompletionState)?
    @ObservationIgnored var composerStreamOperation: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored var incrementalSegmentOperation: (@MainActor @Sendable (String) async -> Void)?
    private var gatewayConnected = false
    private var sessionKey: String = "main"
    private struct Attachment: Equatable {
        let sessionKey: String
        let generation: UInt64
    }
    private var attachmentGeneration: UInt64 = 0
    /// The conversation this voice session is attached to — callers scope the inline transcription
    /// bubble to it so the app-global manager's transcription doesn't render in every open chat.
    var attachedSessionKey: String { sessionKey }
    /// Whether this Talk Mode instance has successfully sent a turn in the current session.
    /// Used only for first-turn session naming; agent context is gateway-owned structured state.
    private var hasSentMessageInSession: Bool = false

    // MARK: - AppKit window observer

    private nonisolated(unsafe) var keyWindowObserver: NSObjectProtocol?
    private nonisolated(unsafe) var resignKeyObserver: NSObjectProtocol?

    // MARK: - Push-to-talk key monitor (#321 PR 3)
    //
    // Installed lazily when voice starts in PTT mode; removed on `stop()`.
    // The monitor is app-focus-scoped (`NSEvent.addLocalMonitorForEvents`)
    // not global — global hotkeys require Accessibility permission and are
    // out of scope per #321 PR 3 locked design #5.

    private let pttKeyMonitor = PushToTalkKeyMonitor()

    // MARK: - CoreAudio default input device listener
    //
    // Mac analog of iOS's `AVAudioSession.routeChangeNotification`. When the
    // default input device changes (AirPods plugged in, USB mic unplugged,
    // switched via System Settings), we tear down and restart recognition so
    // STT continues on the new device — mirrors
    // `RemTalkModeManager.handleRouteChange` (lines 155-183).

    // `nonisolated(unsafe)` so `deinit` can read/clear the flag while
    // removing the CoreAudio listener — same pattern as the AppKit window
    // observer flags above. Mutations stay on the MainActor in practice
    // (install/remove are called from `start()`/`stop()`).
    private nonisolated(unsafe) var defaultInputListenerInstalled: Bool = false

    private let logger = Logger(subsystem: "com.remapp.rem.mac", category: "TalkMode")

    override init() {
        super.init()
        self.observeWindowFocus()
        self.wirePushToTalkMonitor()
    }

    /// Connects the `PushToTalkKeyMonitor` callbacks to the manager's PTT
    /// entry points. Keeps the monitor class self-contained (no import of
    /// the manager) so it stays unit-testable.
    private func wirePushToTalkMonitor() {
        self.pttKeyMonitor.onKeyDown = { [weak self] in
            self?.beginPushToTalkCapture()
        }
        self.pttKeyMonitor.onKeyUp = { [weak self] in
            self?.endPushToTalkCapture()
        }
    }

    deinit {
        if let obs = keyWindowObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        // Symmetry with the NotificationCenter observers above: if `stop()`
        // wasn't reached before dealloc (low risk in practice — the manager
        // lives at app scope — but possible during teardown), the CoreAudio
        // listener block would otherwise leak.
        removeDefaultInputDeviceListener()
    }

    // MARK: - Window focus observer

    /// Logs window key/resign transitions. The current policy (per #321
    /// locked decision) is to keep listening across resign-key transitions
    /// for iOS parity. If we ever flip to Mac-native "pause on resign",
    /// this is where to do it.
    private func observeWindowFocus() {
        self.keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.debug("window became key")
        }
        self.resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.debug("window resigned key (continuing per #321 locked design #4)")
        }
    }

    // MARK: - CoreAudio default input device listener
    //
    // The iOS equivalent is `AVAudioSession.routeChangeNotification` (see
    // `RemTalkModeManager.observeAudioNotifications` / `handleRouteChange`).
    // macOS does not vend that notification. The Mac-native signal is
    // `kAudioHardwarePropertyDefaultInputDevice` on the global audio object.
    // We only react while `isEnabled && isListening` to avoid work while
    // voice is idle.

    private func installDefaultInputDeviceListener() {
        guard !defaultInputListenerInstalled else { return }
        let block = defaultInputDeviceListenerBlock ?? makeDefaultInputDeviceListenerBlock()
        defaultInputDeviceListenerBlock = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block)
        if status == noErr {
            defaultInputListenerInstalled = true
        } else {
            logger.warning("AudioObjectAddPropertyListenerBlock failed: \(status)")
        }
    }

    /// Remove the CoreAudio default-input listener. `nonisolated` so `deinit`
    /// can invoke it without hopping through MainActor (the underlying
    /// CoreAudio API is thread-safe; the storage flags are
    /// `nonisolated(unsafe)`).
    nonisolated private func removeDefaultInputDeviceListener() {
        guard defaultInputListenerInstalled, let block = defaultInputDeviceListenerBlock else {
            defaultInputListenerInstalled = false
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block)
        defaultInputListenerInstalled = false
    }

    // Lazily constructed by `installDefaultInputDeviceListener()` and held
    // here so `removeDefaultInputDeviceListener()` (and `deinit`) can pass
    // the same block reference back to CoreAudio. `@ObservationIgnored`
    // keeps the `@Observable` macro from synthesizing change tracking for
    // a non-UI value; `nonisolated(unsafe)` lets `deinit` clear it.
    @ObservationIgnored
    private nonisolated(unsafe) var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    private func makeDefaultInputDeviceListenerBlock() -> AudioObjectPropertyListenerBlock {
        return { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.isListening, !self.isMuted else { return }
                self.logger.info("default input device changed — restarting recognition")
                self.stopRecognition()
                // PTT mode: don't auto-restart. The next keyDown starts fresh
                // recognition on the new device. If the user was mid-hold
                // when the device changed, releasing and re-pressing picks up
                // the new device — the alternative (silent auto-restart mid-
                // hold) can partial-transcribe and garble the send.
                if self.inputMode == .pushToTalk {
                    self.isListening = false
                    self.isHoldingPTT = false
                    self.statusText = "Hold space to talk"
                    return
                }
                do {
                    try self.startRecognition()
                    self.statusText = "Listening"
                } catch {
                    self.logger.error("route change recovery failed: \(error.localizedDescription, privacy: .public)")
                    self.statusText = "Audio error"
                    self.isListening = false
                }
            }
        }
    }

    // MARK: - Gateway integration

    /// Attach the gateway session. Called from `MacChatWindow` when voice starts.
    func attachGateway(_ gateway: GatewayNodeSession) {
        self.gateway = gateway
        self.gatewaySpeech.attach(gateway)
    }

    func attachQuotaService(_ quotaService: MacQuotaService) {
        self.quotaService = quotaService
    }

    /// Update connection state. Kicks recognition when gateway becomes available.
    func updateGatewayConnected(_ connected: Bool) {
        self.gatewayConnected = connected
        if connected, self.isEnabled, !self.isListening {
            Task { await self.start() }
        } else if !connected, self.isEnabled, !self.isSpeaking {
            self.statusText = "Offline"
        }
    }

    /// Update the session key (shared with text chat).
    func updateSessionKey(_ sessionKey: String?) {
        self.cancelActiveTranscriptAndRetainResolution()
        self.composerStreamingTaskOwner = nil
        self.composerStreamingTask?.cancel()
        self.composerStreamingTask = nil
        self.attachmentGeneration &+= 1
        self.resetIncrementalSpeech()
        self.stopSpeaking()
        self.responsePhase = .idle
        self.statusText = self.isEnabled ? "Ready" : "Off"
        self.lastTranscript = ""
        self.lastHeard = nil
        self.preservedTranscriptSessionKey = nil
        self.transcriptionState = .idle
        let trimmed = (sessionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != self.sessionKey else { return }
        self.sessionKey = trimmed
        self.hasSentMessageInSession = false
        // Drop a lingering transcription from the previous conversation so it can't leak into the
        // newly-opened chat (the inline bubble follows the active session — see iOS RemChatView).
    }

    private var currentAttachment: Attachment {
        Attachment(sessionKey: sessionKey, generation: attachmentGeneration)
    }

    private func owns(_ attachment: Attachment) -> Bool {
        currentAttachment == attachment
    }

    private func owns(_ attachment: Attachment, speechGeneration: UInt64?) -> Bool {
        owns(attachment)
            && (speechGeneration == nil || speechGeneration == incrementalSpeechGeneration)
    }

    private func incrementalTaskCanMutate(
        owner: UUID,
        attachment: Attachment,
        generation: UInt64
    ) -> Bool {
        incrementalSpeechTaskOwner == owner
            && owns(attachment)
            && incrementalSpeechGeneration == generation
    }

    private func composerTaskCanMutate(
        owner: UUID,
        attachment: Attachment,
        generation: UInt64
    ) -> Bool {
        composerStreamingTaskOwner == owner
            && owns(attachment)
            && incrementalSpeechGeneration == generation
    }

    var hasIncrementalSpeechTask: Bool { incrementalSpeechTask != nil }
    var hasComposerStreamingTask: Bool { composerStreamingTask != nil }

    private func cancelActiveTranscriptAndRetainResolution() {
        guard let displaced = activeTranscriptTask else { return }
        displaced.cancel()
        activeTranscriptTask = nil

        let predecessor = displacedTranscriptResolutionTask
        let owner = UUID()
        displacedTranscriptResolutionOwner = owner
        displacedTranscriptResolutionTask = Task { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }
            await displaced.value
            guard let self, self.displacedTranscriptResolutionOwner == owner else { return }
            self.displacedTranscriptResolutionOwner = nil
            self.displacedTranscriptResolutionTask = nil
        }
    }

    func startTranscriptProcessing(_ transcript: String, restartAfter: Bool) {
        self.cancelActiveTranscriptAndRetainResolution()
        self.attachmentGeneration &+= 1
        let attachment = currentAttachment
        self.activeTranscriptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.processTranscript(
                transcript,
                restartAfter: restartAfter,
                attachment: attachment
            )
            guard self.owns(attachment) else { return }
            self.activeTranscriptTask = nil
        }
    }

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        self.isMuted = false
        if enabled {
            Task { await self.start() }
        } else {
            self.stop()
        }
    }

    /// Mute: pause listening but keep session alive (bar stays visible).
    ///
    /// PTT divergence: in PTT mode the recognizer isn't running between
    /// holds, but the key monitor is armed. Muting disarms the monitor so
    /// a held spacebar is a no-op, mirroring the VAD "don't capture" intent.
    func mute() {
        guard self.isEnabled else { return }
        let wasActive = self.isListening || self.inputMode == .pushToTalk
        guard wasActive else { return }
        self.isMuted = true
        self.pttKeyMonitor.isActive = false
        self.isHoldingPTT = false
        self.stopRecognition()
        self.statusText = "Muted"
    }

    /// Unmute: resume listening from muted state.
    func unmute() {
        guard self.isEnabled, self.isMuted else { return }
        guard self.applyQuotaCaptureGateIfNeeded() else {
            return
        }
        self.isMuted = false
        Task { await self.start() }
    }

    /// Toggle between muted and unmuted. Wired from the shared mini-bar.
    func toggleMute() {
        if self.isMuted {
            self.unmute()
        } else {
            self.mute()
        }
    }

    // MARK: - Input mode switching (#321 PR 3)

    /// Persists the chosen mode and reconfigures the live session. Wired from
    /// the shared mini-bar mode button. Safe to call whether voice is enabled
    /// or not — if disabled, only the UserDefaults write side-effect fires.
    ///
    /// Lifecycle: when switching mid-session we tear down the active capture
    /// path (VAD → stop recognition + silence task; PTT → disarm key monitor)
    /// and restart via `start()` on the new mode. The manager re-reads
    /// `VoiceInputMode.stored` inside `start()` so the switch takes effect
    /// even if the UI skips updating `inputMode` directly.
    func setInputMode(_ mode: VoiceInputMode) {
        guard mode != self.inputMode else {
            // Still hit the store in case caller wants to materialize a
            // default. Cheap idempotent write.
            mode.store()
            return
        }
        mode.store()
        self.inputMode = mode

        guard self.isEnabled else { return }

        // Restart the session on the new mode. Going VAD→PTT: stop recognition
        // + silence task, install monitor. Going PTT→VAD: uninstall monitor,
        // start continuous recognition. Routed through stop/start paths we
        // already trust.
        self.silenceTask?.cancel()
        self.silenceTask = nil
        self.stopRecognition()
        self.isListening = false
        self.isHoldingPTT = false
        self.pttKeyMonitor.isActive = false
        if mode == .vad {
            // Keep the monitor installed-but-inactive so the next PTT toggle
            // doesn't pay re-install cost. Install is idempotent so this is
            // equivalent to leaving it in place.
            self.pttKeyMonitor.uninstall()
        }
        Task { await self.start() }
    }

    /// Toggle between VAD and push-to-talk. Called from the mini-bar icon.
    func togglePushToTalkMode() {
        self.setInputMode(self.inputMode == .pushToTalk ? .vad : .pushToTalk)
    }

    // MARK: - Push-to-talk capture (#321 PR 3)
    //
    // Wired to the `PushToTalkKeyMonitor`. Spacebar keyDown → begin; keyUp →
    // end + send the in-flight transcript. The state machine is identical to
    // VAD from `processTranscript` onward — only the trigger for
    // `listening → transcribing` differs.

    /// Begin capturing on PTT key press. No-op unless enabled and in PTT mode.
    private func beginPushToTalkCapture() {
        guard self.isEnabled, self.inputMode == .pushToTalk, !self.isMuted else { return }
        // Don't start a new capture while we're still sending/thinking/speaking.
        if self.isSpeechOutputActive || self.activeTranscriptTask != nil { return }
        guard !self.isListening else { return }

        self.isHoldingPTT = true
        do {
            try self.startRecognition()
            self.isListening = true
            self.statusText = "Listening (hold)…"
            self.logger.info("ptt capture began")
        } catch {
            self.isListening = false
            self.isHoldingPTT = false
            self.statusText = "Start failed: \(error.localizedDescription)"
            self.logger.error("ptt start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// End capture on PTT key release. Flushes the current transcript to
    /// `processTranscript` (same send path as VAD) and returns the session
    /// to "Hold space to talk" once the assistant reply is in.
    private func endPushToTalkCapture() {
        guard self.isEnabled, self.inputMode == .pushToTalk else { return }
        guard self.isHoldingPTT else { return }
        self.isHoldingPTT = false

        let transcript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            // User tapped/released without speaking. Stop recognition and
            // return to idle. No send.
            self.stopRecognition()
            self.isListening = false
            self.statusText = "Hold space to talk"
            self.logger.info("ptt released with empty transcript — no send")
            return
        }

        // Hand off to the shared processing path. `processTranscript` cancels
        // any in-flight task, stops recognition itself, and calls `start()`
        // when done. Because `start()` re-reads `VoiceInputMode.stored` it
        // will land back on the PTT path (setting "Hold space to talk") on
        // completion, not re-open continuous recognition.
        self.startTranscriptProcessing(transcript, restartAfter: true)
    }

    func start() async {
        guard self.isEnabled, !self.isListening, !self.isMuted else { return }
        guard self.applyQuotaCaptureGateIfNeeded() else {
            return
        }
        guard self.gatewayConnected else {
            self.statusText = "Offline"
            return
        }

        // Re-read the persisted mode on every start() so a toggle from the
        // mini-bar applies to the next voice turn (#321 PR 3 locked design #3).
        self.inputMode = VoiceInputMode.stored

        self.statusText = "Requesting permissions..."
        let micOk = await Self.requestMicrophonePermission()
        guard micOk else {
            self.statusText = "Microphone permission denied"
            return
        }
        let speechOk = await Self.requestSpeechPermission()
        guard speechOk else {
            self.statusText = "Speech recognition permission denied"
            return
        }

        await self.reloadConfig()

        // Mode divergence (#321 PR 3):
        //   - `.vad`: existing behavior — start recognition + silence monitor.
        //     Send triggers on 1.5s of silence after last utterance.
        //   - `.pushToTalk`: do NOT start recognition yet. Install the key
        //     monitor and wait for the user to hold spacebar. `beginPushToTalkCapture`
        //     will start recognition on keyDown; `endPushToTalkCapture` stops
        //     it and sends immediately on keyUp.
        switch self.inputMode {
        case .vad:
            self.pttKeyMonitor.isActive = false
            do {
                try self.startRecognition()
                self.isListening = true
                self.statusText = "Listening"
                self.startSilenceMonitor()
                self.installDefaultInputDeviceListener()
                self.logger.info("Mac talk mode listening (vad)")
            } catch {
                self.isListening = false
                self.statusText = "Start failed: \(error.localizedDescription)"
                self.logger.error("start failed: \(error.localizedDescription, privacy: .public)")
            }
        case .pushToTalk:
            self.pttKeyMonitor.install()
            self.pttKeyMonitor.isActive = true
            self.installDefaultInputDeviceListener()
            self.isListening = false
            self.isHoldingPTT = false
            self.statusText = "Hold space to talk"
            self.logger.info("Mac talk mode ready (push-to-talk)")
        }
    }

    func stop() {
        // INVARIANT: `isEnabled = false` must come before `stopSpeaking()`
        // (and `stopRecognition()`). The route-change listener block guards
        // on `self.isEnabled` to decide whether to re-arm recognition; if
        // we tore down audio first, a CoreAudio device-change callback
        // racing on MainActor could observe `isEnabled == true` and try to
        // restart on top of a half-stopped engine. Setting the flag first
        // makes the guard a clean rejection.
        self.isEnabled = false
        self.isListening = false
        self.isMuted = false
        self.isHoldingPTT = false
        self.pttKeyMonitor.isActive = false
        self.pttKeyMonitor.uninstall()
        self.statusText = "Off"
        self.responsePhase = .idle
        self.lastTranscript = ""
        self.preservedTranscriptSessionKey = nil
        self.lastHeard = nil
        self.transcriptionState = .idle
        self.silenceTask?.cancel()
        self.silenceTask = nil
        self.cancelActiveTranscriptAndRetainResolution()
        self.attachmentGeneration &+= 1
        self.composerStreamingTaskOwner = nil
        self.composerStreamingTask?.cancel()
        self.composerStreamingTask = nil
        self.stopRecognition()
        self.stopSpeaking()
        self.lastInterruptedAtSeconds = nil
        TalkSystemSpeechSynthesizer.shared.stop()
        self.removeDefaultInputDeviceListener()
    }

    // MARK: - Speech recognition (STT)
    //
    // Mac differences from iOS (`RemTalkModeManager.startRecognition`):
    //   - No `AVAudioSession` setup — macOS `AVAudioEngine` uses the system
    //     default input device directly.
    //   - `setVoiceProcessingEnabled(true)` is still supported on macOS and
    //     provides the same echo-reduction benefit.

    private func startRecognition() throws {
        let recognizer = SFSpeechRecognizer(locale: .current)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "RemMacTalkMode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }
        self.speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        VoiceRecognitionRequestConfiguration.apply(to: request)
        self.recognitionRequest = request

        let input = self.audioEngine.inputNode

        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            self.logger.warning("voice processing unavailable: \(error.localizedDescription, privacy: .public)")
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "RemMacTalkMode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio input format invalid — no default input device?"])
        }

        if inputTapInstalled {
            input.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameCount {
                let sample = channelData[0][i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameCount))
            let raw = Double(rms)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let smoothed = 0.80 * self.micLevel + 0.20 * raw
                self.micLevel = smoothed

                if self.isListening, !self.isSpeaking, !self.noiseFloorReady {
                    self.noiseFloorSamples.append(raw)
                    if self.noiseFloorSamples.count >= 22 {
                        let sorted = self.noiseFloorSamples.sorted()
                        let take = max(6, sorted.count / 2)
                        let slice = sorted.prefix(take)
                        let avg = slice.reduce(0.0, +) / Double(slice.count)
                        self.noiseFloor = avg
                        self.noiseFloorReady = true
                        self.noiseFloorSamples.removeAll(keepingCapacity: true)
                    }
                }

                let threshold: Double = if let floor = self.noiseFloor, self.noiseFloorReady {
                    min(0.35, max(0.12, floor + 0.10))
                } else {
                    0.18
                }
                if raw >= threshold {
                    self.lastAudioActivity = Date()
                }
            }
        }
        self.inputTapInstalled = true

        self.audioEngine.prepare()
        try self.audioEngine.start()

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                let msg = error.localizedDescription
                if !self.isSpeaking {
                    let isTransient = msg.localizedCaseInsensitiveContains("cancel")
                        || msg.localizedCaseInsensitiveContains("no speech detected")
                    if !isTransient {
                        Task { @MainActor [weak self] in
                            self?.statusText = "Speech error: \(msg)"
                        }
                    }
                }
                if self.isEnabled, !self.isSpeaking, !self.isMuted {
                    self.stopRecognition()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard let self, self.isEnabled, !self.isMuted else { return }
                        // PTT mode: don't auto-restart continuous capture —
                        // the next keyDown is the only trigger. Surface the
                        // return to idle via statusText.
                        if self.inputMode == .pushToTalk {
                            self.isListening = false
                            self.statusText = "Hold space to talk"
                            return
                        }
                        try? self.startRecognition()
                        self.isListening = true
                        self.statusText = "Listening"
                    }
                }
            }
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            Task { @MainActor in
                await self.handleTranscript(transcript: transcript, isFinal: result.isFinal)
            }
        }
    }

    private func stopRecognition() {
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.recognitionRequest?.endAudio()
        self.recognitionRequest = nil
        self.micLevel = 0
        self.lastAudioActivity = nil
        self.noiseFloorSamples.removeAll(keepingCapacity: true)
        self.noiseFloor = nil
        self.noiseFloorReady = false
        if self.inputTapInstalled {
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.inputTapInstalled = false
        }
        self.audioEngine.stop()
        self.audioEngine.reset()
        self.speechRecognizer = nil
    }

    // MARK: - Transcript handling & silence detection
    //
    // Mirrors iOS `RemTalkModeManager.handleTranscript` (lines 541-573), plus
    // the TTS-interrupt-on-speech path from the iOS implementation.

    private func handleTranscript(transcript: String, isFinal: Bool) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if self.isSpeechOutputActive, self.interruptOnSpeech {
            if self.shouldInterrupt(with: trimmed) {
                self.stopSpeaking()
            }
            return
        }

        guard self.isListening else { return }

        if self.isLikelyEcho(trimmed) { return }

        if !trimmed.isEmpty {
            self.lastTranscript = trimmed
            self.lastHeard = Date()
            self.transcriptionState = .transcribing(trimmed)
        }
        if isFinal, !trimmed.isEmpty {
            self.lastTranscript = trimmed
            // PTT mode: the keyUp handler (`endPushToTalkCapture`) is the only
            // legitimate path to `processTranscript`. SFSpeech occasionally
            // reports `isFinal == true` mid-hold (e.g. after a long pause
            // while still holding), which would otherwise fire a double-send.
            if self.inputMode == .pushToTalk { return }
            if !self.isSpeechOutputActive {
                self.startTranscriptProcessing(trimmed, restartAfter: true)
            }
        }
    }

    private func startSilenceMonitor() {
        self.silenceTask?.cancel()
        self.silenceTask = Task { [weak self] in
            guard let self else { return }
            while self.isEnabled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self.checkSilence()
            }
        }
    }

    private func checkSilence() async {
        // PTT mode never auto-sends on silence — the keyUp handler drives the
        // transition. Short-circuit here so noise-floor drift can't trigger
        // a spurious send while the user is merely pausing between words
        // mid-hold.
        guard self.inputMode == .vad else { return }
        guard self.isListening, !self.isSpeechOutputActive else { return }
        let transcript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        let lastActivity = [self.lastHeard, self.lastAudioActivity].compactMap { $0 }.max()
        guard let lastActivity else { return }
        if Date().timeIntervalSince(lastActivity) < self.silenceWindow { return }
        self.startTranscriptProcessing(transcript, restartAfter: true)
    }

    /// Whether TTS output should count as active (gates silence detection + speech interruption).
    /// `isSpeaking` always counts (never clipped); the incremental flags count only until the
    /// stuck-flag watchdog trips, so a run that ends without a `final` event can't pin this `true`
    /// forever. Mirrors iOS. See `MacVoiceSpeechActivity`.
    private var isSpeechOutputActive: Bool {
        MacVoiceSpeechActivity.isActive(
            isSpeaking: self.isSpeaking,
            hasPendingSpeech: self.incrementalSpeechActive
                || self.incrementalSpeechTask != nil
                || !self.incrementalSpeechQueue.isEmpty,
            lastProgress: self.lastSpeechProgressTime,
            now: Date(),
            staleWindow: self.speechStaleWindow)
    }

    // MARK: - Echo detection (mirrors iOS lines 607-678)

    private func shouldInterrupt(with transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // On Mac we don't distinguish built-in speaker vs headphones —
        // AVAudioSession isn't available. Use the stricter built-in-speaker
        // bar universally so passive speaker echo doesn't trigger interrupts.
        let minLength = 10
        guard trimmed.count >= minLength else { return false }

        let transcriptWords = Self.strippedWords(trimmed)
        let spokenWords = Self.strippedWords(self.spokenTextAccumulator)
        guard !spokenWords.isEmpty else { return true }

        let novelWords = transcriptWords.subtracting(spokenWords)
        return novelWords.count >= 2
    }

    private static func strippedWords(_ text: String) -> Set<String> {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        return Set(
            text.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: punctuation) }
                .filter { !$0.isEmpty }
        )
    }

    private func isWordOverlapEcho(_ transcript: String) -> Bool {
        let transcriptWords = Self.strippedWords(transcript)
        guard !transcriptWords.isEmpty else { return false }
        let spokenWords = Self.strippedWords(self.spokenTextAccumulator)
        guard !spokenWords.isEmpty else { return false }
        let overlap = transcriptWords.intersection(spokenWords).count
        let overlapRatio = Double(overlap) / Double(transcriptWords.count)
        return overlapRatio >= 0.6
    }

    private func isLikelyEcho(_ transcript: String) -> Bool {
        guard let endTime = self.lastSpeakEndTime,
              Date().timeIntervalSince(endTime) < 2.5 else { return false }
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }
        let spokenLower = self.spokenTextAccumulator.lowercased()
        if !spokenLower.isEmpty {
            let cleanTranscript = lower.trimmingCharacters(in: .punctuationCharacters)
            if spokenLower.contains(cleanTranscript) { return true }
        }
        return self.isWordOverlapEcho(transcript)
    }

    // MARK: - Chat processing
    //
    // Mirrors iOS `RemTalkModeManager.processTranscript` (lines 682-863).
    // Differences: Mac uses its account-generation-bound quota service, with no telemetry
    // tracking or live activity updates. The TTS kickoff and assistant
    // streaming path is the same.

    private func processTranscript(
        _ transcript: String,
        restartAfter: Bool,
        attachment: Attachment
    ) async {
        guard owns(attachment) else { return }
        let preSpeechGeneration = incrementalSpeechGeneration
        var turnSpeechGeneration: UInt64?
        let turnSessionKey = attachment.sessionKey
        if pendingAcceptedVoiceAbort != nil {
            do {
                try await retryPendingAcceptedVoiceAbort()
            } catch {
                guard owns(attachment, speechGeneration: preSpeechGeneration),
                      !Task.isCancelled else { return }
                self.applyQuotaDenial(
                    transcript: transcript,
                    originSessionKey: turnSessionKey,
                    message: error.localizedDescription
                )
                return
            }
            guard owns(attachment, speechGeneration: preSpeechGeneration),
                  !Task.isCancelled else { return }
        }
        self.responsePhase = .thinking
        defer {
            let ownedGeneration = turnSpeechGeneration ?? preSpeechGeneration
            if self.owns(attachment, speechGeneration: ownedGeneration),
               self.responsePhase.isWorking {
                self.responsePhase = .idle
            }
        }
        self.isListening = false
        self.statusText = "Thinking..."
        self.stopRecognition()

        guard self.gatewayConnected, let gateway else {
            self.statusText = "Gateway not connected"
            self.transcriptionState = .idle
            if restartAfter, owns(attachment) { await self.start() }
            return
        }

        guard let quotaService else {
            self.applyQuotaDenial(
                transcript: transcript,
                originSessionKey: turnSessionKey,
                message: "Rem couldn't verify your plan right now. Check your connection and try again."
            )
            return
        }

        guard let dispatchContext = quotaService.makeDispatchContext() else {
            self.applyQuotaDenial(
                transcript: transcript,
                originSessionKey: turnSessionKey,
                message: "Rem couldn't verify your plan right now. Check your connection and try again."
            )
            return
        }

        let reservation: MacQuotaReservationToken
        do {
            reservation = try await quotaService.consumeRequestSlot(dispatchContext: dispatchContext)
        } catch {
            guard owns(attachment, speechGeneration: preSpeechGeneration),
                  !Task.isCancelled else { return }
            let message: String
            switch MacQuotaFailurePolicy.classify(error) {
            case .quotaExceeded(let quota):
                message = quota.message
            case .verificationUnavailable:
                message = "Rem couldn't verify your plan right now. Check your connection and try again."
            case .reservationRetryBlocked:
                message = "That voice request wasn't sent, but its quota check may have counted. "
                    + "To avoid counting it twice, don't retry it. Check Usage or contact support."
            }
            self.applyQuotaDenial(
                transcript: transcript,
                originSessionKey: turnSessionKey,
                message: message
            )
            return
        }

        guard owns(attachment, speechGeneration: preSpeechGeneration),
              !Task.isCancelled else {
            // The consume 200 already charged this slot, but composer takeover happened before
            // gateway dispatch. Retire only this exact local handoff so it cannot strand the scope.
            quotaService.markReservedRequestCancelledBeforeDispatch(reservation)
            return
        }

        let isFirstMessage = !self.hasSentMessageInSession
            || SessionDisplayNames.name(for: turnSessionKey) == nil

        // Hoisted out of the `do` so the `catch` can cancel it too — otherwise a throw leaves
        // `streamAssistant` orphaned on the still-open agent event stream, speaking the failed turn's
        // content over the next listening turn (cross-talk). Mirrors iOS.
        var streamingTask: Task<Void, Never>?
        do {
            let startedAt = Date().timeIntervalSince1970
            let runId = try await self.sendChat(
                transcript,
                sessionKey: turnSessionKey,
                gateway: gateway,
                reservation: reservation,
                quotaService: quotaService
            )
            guard owns(attachment, speechGeneration: preSpeechGeneration),
                  !Task.isCancelled else { return }
            // A committed quota reservation is not dispatch evidence. Publish the transcript only
            // after the gateway returns an exact accepted run and this turn still owns its route.
            self.lastTranscript = ""
            self.lastHeard = nil
            self.preservedTranscriptSessionKey = nil
            self.transcriptionState = .sent(transcript)
            self.voiceTranscripts.insert(transcript)
            self.hasSentMessageInSession = true
            self.logger.info("chat.send ok runId=\(runId)")
            SessionLastMessageTimes.touch(turnSessionKey)

            if isFirstMessage {
                let generatedName = SessionDisplayNames.generateName(from: transcript)
                SessionDisplayNames.setNameIfAbsent(generatedName, for: turnSessionKey)
                Task { [turnSessionKey] in
                    struct PatchParams: Codable {
                        var key: String
                        var label: String
                    }
                    let patch = PatchParams(key: turnSessionKey, label: generatedName)
                    if let patchData = try? JSONEncoder().encode(patch),
                       let patchJSON = String(data: patchData, encoding: .utf8) {
                        _ = try? await gateway.request(
                            method: "sessions.patch",
                            paramsJSON: patchJSON,
                            timeoutSeconds: 10)
                    }
                }
            }
            guard owns(attachment, speechGeneration: preSpeechGeneration),
                  !Task.isCancelled else { return }

            self.resetIncrementalSpeech()
            let speechGeneration = self.incrementalSpeechGeneration
            turnSpeechGeneration = speechGeneration
            streamingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.streamAssistant(
                    runId: runId,
                    gateway: gateway,
                    attachment: attachment,
                    expectedGeneration: speechGeneration
                )
            }

            let completion: MacTalkChatCompletionState
            if let chatCompletionWaiter {
                completion = await chatCompletionWaiter(runId)
            } else {
                completion = await self.waitForChatCompletion(
                    runId: runId, gateway: gateway, timeoutSeconds: 120)
            }
            guard owns(attachment), turnSpeechGeneration == incrementalSpeechGeneration else {
                streamingTask?.cancel()
                return
            }
            if Task.isCancelled || completion == .aborted || completion == .error {
                self.statusText = completion == .aborted ? "Aborted" : (Task.isCancelled ? "Off" : "Chat error")
                self.transcriptionState = .idle
                streamingTask?.cancel()
                await self.finishIncrementalSpeech(
                    attachment: attachment,
                    expectedGeneration: turnSpeechGeneration
                )
                guard owns(attachment), turnSpeechGeneration == incrementalSpeechGeneration else { return }
                if !Task.isCancelled, restartAfter {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard owns(attachment, speechGeneration: turnSpeechGeneration),
                          !Task.isCancelled else { return }
                    await self.start()
                }
                return
            }

            guard !Task.isCancelled else {
                streamingTask?.cancel()
                return
            }

            var assistantText = try await self.waitForAssistantText(
                gateway: gateway,
                since: startedAt,
                timeoutSeconds: completion == .final ? 12 : 25)
            guard owns(attachment), turnSpeechGeneration == incrementalSpeechGeneration else {
                streamingTask?.cancel()
                return
            }

            if assistantText == nil {
                let fallback = self.incrementalSpeechBuffer.latestText
                if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantText = fallback
                }
            }

            guard !Task.isCancelled else {
                streamingTask?.cancel()
                return
            }

            guard let assistantText else {
                self.statusText = "No reply"
                self.transcriptionState = .idle
                streamingTask?.cancel()
                await self.finishIncrementalSpeech(
                    attachment: attachment,
                    expectedGeneration: turnSpeechGeneration
                )
                guard owns(attachment), turnSpeechGeneration == incrementalSpeechGeneration else { return }
                if restartAfter {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard owns(attachment, speechGeneration: turnSpeechGeneration),
                          !Task.isCancelled else { return }
                    await self.start()
                }
                return
            }

            guard !Task.isCancelled else {
                streamingTask?.cancel()
                return
            }

            streamingTask?.cancel()
            await self.handleIncrementalAssistantFinal(
                text: assistantText,
                attachment: attachment,
                expectedGeneration: turnSpeechGeneration
            )
            guard owns(attachment), turnSpeechGeneration == incrementalSpeechGeneration else { return }
        } catch {
            let ownedGeneration = turnSpeechGeneration ?? preSpeechGeneration
            guard owns(attachment, speechGeneration: ownedGeneration) else {
                streamingTask?.cancel()
                return
            }
            self.statusText = "Talk failed: \(error.localizedDescription)"
            self.logger.error("processTranscript failed: \(error.localizedDescription, privacy: .public)")
            // A throw here is a run ending WITHOUT a `final` event. Cancel the streaming task FIRST
            // (mirroring every other termination branch) so the orphaned `streamAssistant` can't keep
            // ingesting later deltas and speak the failed turn over the next listening turn. THEN
            // finalize incremental speech so `incrementalSpeechActive` can't stay stuck `true`.
            // Mirrors iOS; the `isSpeechOutputActive` watchdog is the backstop.
            streamingTask?.cancel()
            await self.finishIncrementalSpeech(
                attachment: attachment,
                expectedGeneration: turnSpeechGeneration
            )
            guard owns(attachment, speechGeneration: ownedGeneration) else { return }
        }

        let ownedGeneration = turnSpeechGeneration ?? preSpeechGeneration
        guard owns(attachment, speechGeneration: ownedGeneration) else { return }
        self.transcriptionState = .idle

        if !Task.isCancelled, restartAfter {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard owns(attachment, speechGeneration: ownedGeneration),
                  !Task.isCancelled else { return }
            await self.start()
        }
    }

    private func applyQuotaCaptureGateIfNeeded() -> Bool {
        let decision = MacVoiceQuotaCapturePolicy.decision(
            serviceAttached: quotaService != nil,
            reservationRetryBlocked: quotaService?.reservationRetryBlocked ?? false,
            latestRemaining: quotaService?.latestRemaining
        )
        switch decision {
        case .allowed:
            return true
        case .quotaExceeded(let presentation):
            self.applyQuotaDenial(
                transcript: self.lastTranscript,
                originSessionKey: self.sessionKey,
                message: presentation.title
            )
        case .verificationUnavailable:
            self.applyQuotaDenial(
                transcript: self.lastTranscript,
                originSessionKey: self.sessionKey,
                message: "Rem couldn't verify your plan right now. Check your connection and try again."
            )
        case .reservationRetryBlocked:
            self.applyQuotaDenial(
                transcript: self.lastTranscript,
                originSessionKey: self.sessionKey,
                message: "A voice request's quota check may have counted. To avoid counting it "
                    + "twice, Talk Mode will stay muted. Check Usage or contact support."
            )
        }
        return false
    }

    func applyQuotaDenial(transcript: String, originSessionKey: String, message: String) {
        let preserved = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isListening = false
        self.isMuted = true
        self.isHoldingPTT = false
        self.pttKeyMonitor.isActive = false
        self.statusText = message
        self.responsePhase = .idle
        if !preserved.isEmpty, self.sessionKey == originSessionKey {
            self.lastTranscript = preserved
            self.preservedTranscriptSessionKey = originSessionKey
            self.transcriptionState = .transcribing(preserved)
        } else if self.sessionKey != originSessionKey {
            self.lastTranscript = ""
            self.lastHeard = nil
            self.preservedTranscriptSessionKey = nil
            self.transcriptionState = .idle
        }
    }

    func sendChat(
        _ message: String,
        sessionKey: String,
        gateway: GatewayNodeSession,
        reservation: MacQuotaReservationToken,
        quotaService: MacQuotaService
    ) async throws -> String {
        struct SendResponse: Decodable { let runId: String }

        let payload: [String: Any] = [
            "sessionKey": sessionKey,
            "message": message,
            "thinking": "low",
            "timeoutMs": 120_000,
            "idempotencyKey": UUID().uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw NSError(domain: "RemMacTalkMode", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode chat payload"])
        }
        try Task.checkCancellation()
        let requester = self.chatLifecycleRequester
        let beforeGatewayStart = self.beforeChatGatewayStart
        let acknowledgement = try await MacQuotaGatewayDispatch.run(
            dispatchContext: reservation.dispatchContext,
            beforeGatewayStart: beforeGatewayStart,
            onCancelledBeforeGatewayStart: {
                await MainActor.run {
                    quotaService.markReservedRequestCancelledBeforeDispatch(reservation)
                }
            },
            request: {
                if let requester {
                    return try await requester("chat.send", json, 125)
                }
                return try await gateway.request(
                    method: "chat.send",
                    paramsJSON: json,
                    timeoutSeconds: 125
                )
            },
            decodeRunID: { data in
                try JSONDecoder().decode(SendResponse.self, from: data).runId
            },
            onAcknowledged: { _ in
                await MainActor.run {
                    quotaService.markReservedRequestAcknowledged(reservation)
                }
            },
            abortAcceptedRun: { acknowledgement in
                try await self.abortAcceptedChatRun(
                    runID: acknowledgement.runID,
                    sessionKey: sessionKey,
                    gateway: gateway,
                    requester: requester
                )
            }
        )
        return acknowledgement.runID
    }

    var pendingAcceptedVoiceAbortRunID: String? {
        pendingAcceptedVoiceAbort?.runID
    }

    private func abortAcceptedChatRun(
        runID: String,
        sessionKey: String,
        gateway: GatewayNodeSession,
        requester: ChatLifecycleRequester?
    ) async throws {
        let pending = PendingAcceptedVoiceAbort(
            id: UUID(),
            sessionKey: sessionKey,
            runID: runID,
            gateway: gateway,
            requester: requester
        )
        pendingAcceptedVoiceAbort = pending
        try await performPendingAcceptedVoiceAbort(pending)
    }

    private func retryPendingAcceptedVoiceAbort() async throws {
        guard let pendingAcceptedVoiceAbort else { return }
        try await performPendingAcceptedVoiceAbort(pendingAcceptedVoiceAbort)
    }

    private func performPendingAcceptedVoiceAbort(
        _ pending: PendingAcceptedVoiceAbort
    ) async throws {
        try await Self.abortAcceptedChatRun(
            runID: pending.runID,
            sessionKey: pending.sessionKey,
            requester: { json in
                if let requester = pending.requester {
                    _ = try await requester("chat.abort", json, 10)
                } else {
                    _ = try await pending.gateway.request(
                        method: "chat.abort",
                        paramsJSON: json,
                        timeoutSeconds: 10
                    )
                }
            }
        )
        if pendingAcceptedVoiceAbort?.id == pending.id {
            pendingAcceptedVoiceAbort = nil
        }
    }

    static func abortAcceptedChatRun(
        runID: String,
        sessionKey: String,
        requester: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        struct AbortParams: Codable {
            let sessionKey: String
            let runId: String
        }
        let data = try JSONEncoder().encode(AbortParams(
            sessionKey: sessionKey,
            runId: runID
        ))
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let abortTask = Task.detached { try await requester(json) }
        do {
            _ = try await abortTask.value
        } catch {
            throw AcceptedChatRunAbortError(
                sessionKey: sessionKey,
                runID: runID,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    struct AcceptedChatRunAbortError: Error, LocalizedError, Sendable {
        let sessionKey: String
        let runID: String
        let underlyingDescription: String

        var errorDescription: String? {
            "The accepted voice run couldn't be stopped (\(underlyingDescription))."
        }
    }

    private func waitForChatCompletion(
        runId: String,
        gateway: GatewayNodeSession,
        timeoutSeconds: Int = 120
    ) async -> MacTalkChatCompletionState {
        let stream = await gateway.subscribeServerEvents(bufferingNewest: 200)
        return await withTaskGroup(of: MacTalkChatCompletionState.self) { group in
            group.addTask { [runId] in
                for await evt in stream {
                    if Task.isCancelled { return .timeout }
                    guard evt.event == "chat", let payload = evt.payload else { continue }
                    struct ChatEvent: Decodable {
                        let runId: String?
                        let state: OpenClawKit.AnyCodable?
                        enum CodingKeys: String, CodingKey {
                            case runId, runid, state
                        }
                        init(from decoder: Decoder) throws {
                            let c = try decoder.container(keyedBy: CodingKeys.self)
                            self.runId = try c.decodeIfPresent(String.self, forKey: .runId)
                                ?? c.decodeIfPresent(String.self, forKey: .runid)
                            self.state = try c.decodeIfPresent(OpenClawKit.AnyCodable.self, forKey: .state)
                        }
                    }
                    guard let chatEvent = try? GatewayPayloadDecoding.decode(payload, as: ChatEvent.self) else {
                        continue
                    }
                    guard chatEvent.runId == runId else { continue }
                    if let state = chatEvent.state?.value as? String {
                        switch state {
                        case "final": return .final
                        case "aborted": return .aborted
                        case "error": return .error
                        default: break
                        }
                    }
                }
                return .timeout
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                return .timeout
            }
            let result = await group.next() ?? .timeout
            group.cancelAll()
            return result
        }
    }

    private func waitForAssistantText(
        gateway: GatewayNodeSession,
        since: Double,
        timeoutSeconds: Int
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let text = try await self.fetchLatestAssistantText(gateway: gateway, since: since) {
                return text
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    private func fetchLatestAssistantText(gateway: GatewayNodeSession, since: Double? = nil) async throws -> String? {
        let res = try await gateway.request(
            method: "chat.history",
            paramsJSON: "{\"sessionKey\":\"\(self.sessionKey)\"}",
            timeoutSeconds: 15)
        guard let json = try JSONSerialization.jsonObject(with: res) as? [String: Any] else { return nil }
        guard let messages = json["messages"] as? [[String: Any]] else { return nil }
        for msg in messages.reversed() {
            guard (msg["role"] as? String) == "assistant" else { continue }
            if let since, let timestamp = msg["timestamp"] as? Double,
               TalkHistoryTimestamp.isAfter(timestamp, sinceSeconds: since) == false {
                continue
            }
            guard let content = msg["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - TTS playback
    //
    // Mirrors iOS `RemTalkModeManager.playAssistant` (lines 991-1083).
    // Differences:
    //   - No `AVAudioSession.configureAudioSession()` on Mac.
    //   - No local keychain fallback for the ElevenLabs API key (Mac has no
    //     `RemCredentialStore`) — config.get + env var are the only sources.

    private func playAssistant(text: String) async {
        let parsed = TalkDirectiveParser.parse(text)
        let directive = parsed.directive
        let cleaned = parsed.stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        self.applyDirective(directive)

        self.statusText = "Generating voice..."
        self.responsePhase = .generatingVoice
        self.isSpeaking = true
        self.lastSpokenText = cleaned
        self.spokenTextAccumulator += " " + cleaned

        do {
            let request = self.makeGatewayTalkSpeechRequest(text: cleaned, directive: directive)
            let audio = try await self.gatewaySpeech.synthesize(request)
            try Task.checkCancellation()
            await self.playGatewaySpeechAudio(audio)
        } catch {
            self.logger.error("tts failed: \(error.localizedDescription, privacy: .public)")
            if GatewayTalkSpeechFallbackPolicy.shouldUseSystemVoice(for: error) {
                if self.interruptOnSpeech {
                    try? self.startRecognition()
                }
                self.statusText = "Speaking (System)..."
                self.responsePhase = .speaking
                try? await TalkSystemSpeechSynthesizer.shared.speak(
                    text: cleaned,
                    language: ElevenLabsTTSClient.validatedLanguage(directive?.language))
            } else if !Task.isCancelled {
                self.statusText = "Speak failed: \(error.localizedDescription)"
            }
        }

        self.stopRecognition()
        self.isSpeaking = false
        self.responsePhase = .idle
        self.lastSpeakEndTime = Date()
    }

    private func makeGatewayTalkSpeechRequest(
        text: String,
        directive: TalkDirective?,
        outputFormat: String? = nil
    ) -> GatewayTalkSpeechRequest {
        GatewayTalkSpeechRequest(
            text: text,
            voiceId: directive?.voiceId ?? self.currentVoiceId ?? self.defaultVoiceId,
            modelId: directive?.modelId ?? self.currentModelId ?? self.defaultModelId,
            outputFormat: IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(
                for: outputFormat ?? directive?.outputFormat ?? self.defaultOutputFormat),
            speed: directive?.speed,
            rateWpm: directive?.rateWPM,
            stability: directive?.stability,
            similarity: directive?.similarity,
            style: directive?.style,
            speakerBoost: directive?.speakerBoost,
            seed: directive?.seed,
            normalize: directive?.normalize,
            language: directive?.language,
            latencyTier: directive?.latencyTier
        )
        // Read the store per request rather than caching it, so a Voice settings
        // change reaches the very next utterance without a reconnect or restart.
        // Both gateway synthesis entry points — explicit narration and the
        // incremental streaming path — funnel through this one builder.
        .applyingTuning(VoiceTuningStore.settings)
    }

    func playGatewaySpeechAudio(_ audio: GatewayTalkSpeechAudio) async -> Bool {
        guard let data = audio.data else { return false }
        if self.interruptOnSpeech {
            try? self.startRecognition()
        }
        self.statusText = "Speaking..."
        self.responsePhase = .speaking
        self.lastPlaybackWasPCM = false
        self.lastPlaybackWasBufferedMP3 = true
        let result = await self.bufferedMP3Player.play(data: data)
        if !result.finished, let interruptedAt = result.interruptedAt {
            self.lastInterruptedAtSeconds = interruptedAt
        }
        return result.finished
    }

    private func stopSpeaking(storeInterruption: Bool = true) {
        let hasIncremental = self.incrementalSpeechActive ||
            self.incrementalSpeechTask != nil ||
            !self.incrementalSpeechQueue.isEmpty
        if self.isSpeaking {
            let interruptedAt: Double?
            if self.lastPlaybackWasPCM {
                interruptedAt = self.pcmPlayer.stop()
            } else if self.lastPlaybackWasBufferedMP3 {
                interruptedAt = self.bufferedMP3Player.stop()
            } else {
                interruptedAt = self.mp3Player.stop()
            }
            if storeInterruption {
                self.lastInterruptedAtSeconds = interruptedAt
            }
            _ = self.pcmPlayer.stop()
            _ = self.mp3Player.stop()
            _ = self.bufferedMP3Player.stop()
        } else if !hasIncremental {
            return
        }
        TalkSystemSpeechSynthesizer.shared.stop()
        self.gatewaySpeech.cancelAll()
        self.cancelIncrementalSpeech()
        self.isSpeaking = false
        self.responsePhase = .idle
    }

    private func applyDirective(_ directive: TalkDirective?) {
        if let voice = directive?.voiceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !voice.isEmpty, directive?.once != true {
            self.currentVoiceId = voice
        }
        if let model = directive?.modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty, directive?.once != true {
            self.currentModelId = model
        }
    }

    // MARK: - Incremental TTS (real-time streaming)
    //
    // Mirrors iOS `RemTalkModeManager` incremental TTS (lines 1118-1237).

    func resetIncrementalSpeech() {
        if incrementalSpeechTask != nil {
            // Completion-backed players do not observe Task cancellation. Stop the currently owned
            // incremental asset before retiring its owner so it cannot remain audible under B.
            _ = bufferedMP3Player.stop()
            _ = mp3Player.stop()
            _ = pcmPlayer.stop()
            TalkSystemSpeechSynthesizer.shared.stop()
        }
        self.incrementalSpeechQueue.removeAll()
        self.incrementalSpeechGeneration &+= 1
        self.incrementalSpeechTaskOwner = nil
        self.incrementalSpeechTask?.cancel()
        self.incrementalSpeechTask = nil
        self.cancelIncrementalPrefetch()
        self.incrementalSpeechActive = true
        self.incrementalSpeechUsed = false
        self.incrementalSpeechLanguage = nil
        self.incrementalSpeechBuffer = MacIncrementalSpeechBuffer()
        self.incrementalSpeechContext = nil
        self.incrementalSpeechDirective = nil
        self.incrementalSpeechConfigurationResolved = false
        self.spokenTextAccumulator = ""
        self.lastSpeechProgressTime = Date() // turn started → watchdog clock begins now
    }

    private func cancelIncrementalSpeech() {
        self.incrementalSpeechQueue.removeAll()
        self.incrementalSpeechGeneration &+= 1
        self.incrementalSpeechTaskOwner = nil
        self.incrementalSpeechTask?.cancel()
        self.incrementalSpeechTask = nil
        self.cancelIncrementalPrefetch()
        self.incrementalSpeechActive = false
        self.incrementalSpeechContext = nil
        self.incrementalSpeechDirective = nil
        self.incrementalSpeechConfigurationResolved = false
        self.lastSpeechProgressTime = nil // flags cleared → no pending speech to keep alive
    }

    func enqueueIncrementalSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard self.isEnabled else { return }
        self.incrementalSpeechQueue.append(trimmed)
        self.incrementalSpeechUsed = true
        self.lastSpeechProgressTime = Date() // new audio queued → real progress
        if self.incrementalSpeechTask == nil {
            self.startIncrementalSpeechTask()
        }
    }

    private func startIncrementalSpeechTask() {
        if self.interruptOnSpeech {
            try? self.startRecognition()
        }

        let owner = UUID()
        let attachment = currentAttachment
        let generation = incrementalSpeechGeneration
        incrementalSpeechTaskOwner = owner
        self.incrementalSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.incrementalTaskCanMutate(
                    owner: owner,
                    attachment: attachment,
                    generation: generation
                ) {
                    self.cancelIncrementalPrefetch()
                    self.isSpeaking = false
                    self.responsePhase = .idle
                    self.lastSpeakEndTime = Date()
                    self.lastSpeechProgressTime = Date()
                    self.stopRecognition()
                    self.incrementalSpeechTaskOwner = nil
                    self.incrementalSpeechTask = nil
                }
            }
            while !Task.isCancelled && self.isEnabled
                    && self.incrementalTaskCanMutate(
                        owner: owner,
                        attachment: attachment,
                        generation: generation
                    ) {
                guard !self.incrementalSpeechQueue.isEmpty else { break }
                let segment = self.incrementalSpeechQueue.removeFirst()
                self.statusText = "Speaking..."
                self.responsePhase = .speaking
                self.isSpeaking = true
                self.lastSpokenText = segment
                self.spokenTextAccumulator += " " + segment
                if let incrementalSegmentOperation = self.incrementalSegmentOperation {
                    await incrementalSegmentOperation(segment)
                } else {
                    await self.updateIncrementalContextIfNeeded()
                    guard self.incrementalTaskCanMutate(
                        owner: owner,
                        attachment: attachment,
                        generation: generation
                    ) else { return }
                    let context = self.incrementalSpeechContext
                    let prefetchedAudio = await self.consumeIncrementalPrefetchedAudioIfAvailable(
                        for: segment,
                        context: context,
                        owner: owner,
                        attachment: attachment,
                        generation: generation)
                    guard self.incrementalTaskCanMutate(
                        owner: owner,
                        attachment: attachment,
                        generation: generation
                    ) else { return }
                    if let context {
                        self.startIncrementalPrefetchMonitor(context: context)
                    }
                    await self.speakIncrementalSegment(
                        segment,
                        context: context,
                        prefetchedAudio: prefetchedAudio,
                        owner: owner,
                        attachment: attachment,
                        generation: generation)
                }
                guard self.incrementalTaskCanMutate(
                    owner: owner,
                    attachment: attachment,
                    generation: generation
                ) else { return }
                self.cancelIncrementalPrefetchMonitor()
            }
        }
    }

    private func cancelIncrementalPrefetch() {
        self.cancelIncrementalPrefetchMonitor()
        self.incrementalSpeechPrefetch?.task.cancel()
        self.incrementalSpeechPrefetch = nil
    }

    private func cancelIncrementalPrefetchMonitor() {
        self.incrementalSpeechPrefetchMonitorTask?.cancel()
        self.incrementalSpeechPrefetchMonitorTask = nil
    }

    private func startIncrementalPrefetchMonitor(context: MacIncrementalSpeechContext) {
        self.cancelIncrementalPrefetchMonitor()
        self.incrementalSpeechPrefetchMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.ensureIncrementalPrefetchForUpcomingSegment(context: context) {
                    return
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func ensureIncrementalPrefetchForUpcomingSegment(
        context: MacIncrementalSpeechContext
    ) -> Bool {
        guard context.canUseGatewaySynthesis else {
            self.cancelIncrementalPrefetch()
            return false
        }
        guard let nextSegment = self.incrementalSpeechQueue.first else { return false }
        if let existing = self.incrementalSpeechPrefetch {
            if IncrementalSpeechPrefetchPolicy.canReuse(
                prefetchedSegment: existing.segment,
                prefetchedContext: existing.context,
                nextSegment: nextSegment,
                nextContext: context)
            {
                return true
            }
            existing.task.cancel()
            self.incrementalSpeechPrefetch = nil
        }
        self.startIncrementalPrefetch(segment: nextSegment, context: context)
        return self.incrementalSpeechPrefetch != nil
    }

    private func startIncrementalPrefetch(
        segment: String,
        context: MacIncrementalSpeechContext
    ) {
        guard context.canUseGatewaySynthesis else { return }
        let outputFormat = IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(
            for: context.outputFormat)
        let request = self.makeIncrementalTTSRequest(
            text: segment,
            context: context,
            outputFormat: outputFormat)
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.gatewaySpeech.synthesize(request)
                try Task.checkCancellation()
                self.completeIncrementalPrefetch(id: id, audio: audio)
            } catch is CancellationError {
                self.clearIncrementalPrefetch(id: id)
            } catch {
                self.failIncrementalPrefetch(id: id, error: error)
            }
        }
        self.incrementalSpeechPrefetch = MacIncrementalSpeechPrefetchState(
            id: id,
            segment: segment,
            context: context,
            outputFormat: outputFormat,
            chunks: nil,
            task: task)
    }

    private func completeIncrementalPrefetch(id: UUID, audio: GatewayTalkSpeechAudio) {
        guard var prefetch = self.incrementalSpeechPrefetch, prefetch.id == id else { return }
        prefetch.chunks = audio.data.map { [$0] }
        prefetch.outputFormat = audio.outputFormat
        self.incrementalSpeechPrefetch = prefetch
    }

    private func clearIncrementalPrefetch(id: UUID) {
        guard let prefetch = self.incrementalSpeechPrefetch, prefetch.id == id else { return }
        prefetch.task.cancel()
        self.incrementalSpeechPrefetch = nil
    }

    private func failIncrementalPrefetch(id: UUID, error: any Error) {
        guard let prefetch = self.incrementalSpeechPrefetch, prefetch.id == id else { return }
        self.logger.debug(
            "incremental prefetch failed: \(error.localizedDescription, privacy: .public)")
        prefetch.task.cancel()
        self.incrementalSpeechPrefetch = nil
    }

    private func consumeIncrementalPrefetchedAudioIfAvailable(
        for segment: String,
        context: MacIncrementalSpeechContext?,
        owner: UUID,
        attachment: Attachment,
        generation: UInt64
    ) async -> MacIncrementalPrefetchedAudio? {
        guard incrementalTaskCanMutate(
            owner: owner,
            attachment: attachment,
            generation: generation
        ) else { return nil }
        guard let context else {
            self.cancelIncrementalPrefetch()
            return nil
        }
        guard let prefetch = self.incrementalSpeechPrefetch else { return nil }
        guard prefetch.context == context else {
            prefetch.task.cancel()
            self.incrementalSpeechPrefetch = nil
            return nil
        }
        guard prefetch.segment == segment else { return nil }
        if let chunks = prefetch.chunks, !chunks.isEmpty {
            let audio = MacIncrementalPrefetchedAudio(
                chunks: chunks,
                outputFormat: prefetch.outputFormat)
            self.incrementalSpeechPrefetch = nil
            return audio
        }
        await prefetch.task.value
        guard incrementalTaskCanMutate(
            owner: owner,
            attachment: attachment,
            generation: generation
        ) else { return nil }
        guard let completed = self.incrementalSpeechPrefetch,
              completed.context == context,
              completed.segment == segment,
              let chunks = completed.chunks,
              !chunks.isEmpty
        else {
            return nil
        }
        let audio = MacIncrementalPrefetchedAudio(
            chunks: chunks,
            outputFormat: completed.outputFormat)
        self.incrementalSpeechPrefetch = nil
        return audio
    }

    private func finishIncrementalSpeech(
        authoritativeText: String? = nil,
        attachment: Attachment? = nil,
        expectedGeneration: UInt64? = nil
    ) async {
        if let attachment, !owns(attachment) { return }
        if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }
        guard self.incrementalSpeechActive else { return }
        let generation = incrementalSpeechGeneration
        // Reconcile the streamed buffer against the complete reply before finishing (#1092).
        // `streamAssistant` is cancelled the moment the chat run reports `final`, but that
        // completion arrives on a SEPARATE event subscription and can win the race against the
        // last assistant text delta — leaving the buffer short of the final sentence(s) even
        // though the on-screen text (fetched from history) is complete. Re-ingesting the
        // authoritative text advances the buffer to the true end. The buffer tracks a spoken
        // offset by prefix, so already-voiced text is not re-spoken when the streamed text is a
        // prefix of the final text (the common case).
        let finalSegments: [String]
        if let authoritativeText {
            finalSegments = self.incrementalSpeechBuffer.ingest(text: authoritativeText, isFinal: true)
        } else if let leftover = self.incrementalSpeechBuffer.flush() {
            finalSegments = [leftover]
        } else {
            finalSegments = []
        }
        for segment in finalSegments {
            self.enqueueIncrementalSpeech(segment)
        }
        if let task = self.incrementalSpeechTask {
            _ = await task.result
        }
        if let attachment, !owns(attachment) { return }
        guard generation == incrementalSpeechGeneration else { return }
        if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }
        self.incrementalSpeechActive = false
    }

    private func handleIncrementalAssistantFinal(
        text: String,
        attachment: Attachment? = nil,
        expectedGeneration: UInt64? = nil
    ) async {
        if let attachment, !owns(attachment) { return }
        if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }
        let parsed = TalkDirectiveParser.parse(text)
        self.applyDirective(parsed.directive)
        if let lang = parsed.directive?.language {
            self.incrementalSpeechLanguage = ElevenLabsTTSClient.validatedLanguage(lang)
        }
        await self.updateIncrementalContextIfNeeded()
        if let attachment, !owns(attachment) { return }
        if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }

        if self.incrementalSpeechUsed {
            // Reconcile against the complete (directive-stripped) reply so a final sentence
            // streaming missed still gets spoken (#1092). Passing the authoritative text keeps
            // prefix alignment with the streamed text, so already-spoken content is not
            // replayed in the common case.
            await self.finishIncrementalSpeech(
                authoritativeText: parsed.stripped,
                attachment: attachment,
                expectedGeneration: expectedGeneration
            )
        } else {
            let segments = self.incrementalSpeechBuffer.ingest(text: text, isFinal: true)
            for segment in segments {
                self.enqueueIncrementalSpeech(segment)
            }
            await self.finishIncrementalSpeech(
                attachment: attachment,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func streamAssistant(
        runId: String? = nil,
        gateway: GatewayNodeSession,
        attachment: Attachment? = nil,
        expectedGeneration: UInt64? = nil
    ) async {
        let stream = await gateway.subscribeServerEvents(bufferingNewest: 200)
        if let attachment, !owns(attachment) { return }
        if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }
        for await evt in stream {
            if Task.isCancelled { return }
            if let attachment, !owns(attachment) { return }
            if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }
            guard evt.event == "agent", let payload = evt.payload else { continue }
            guard let agentEvent = try? GatewayPayloadDecoding.decode(
                payload, as: OpenClawAgentEventPayload.self) else { continue }
            if let runId { guard agentEvent.runId == runId else { continue } }
            guard agentEvent.stream == "assistant" else { continue }
            guard let text = agentEvent.data["text"]?.value as? String else { continue }
            // Stamp progress on EVERY assistant delta, not only on a boundary enqueue, so a still-
            // generating reply (many deltas before its first sentence boundary) isn't misread as a
            // stuck flag and auto-closed mid-response. `isSpeaking` still short-circuits once audio
            // actually plays. Mirrors iOS.
            self.lastSpeechProgressTime = Date()
            let segments = self.incrementalSpeechBuffer.ingest(text: text, isFinal: false)
            if let lang = self.incrementalSpeechBuffer.directive?.language {
                self.incrementalSpeechLanguage = ElevenLabsTTSClient.validatedLanguage(lang)
            }
            await self.updateIncrementalContextIfNeeded()
            if let attachment, !owns(attachment) { return }
            if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }
            for segment in segments {
                self.enqueueIncrementalSpeech(segment)
            }
        }
    }

    // MARK: - Composer TTS (speak response for text-composed messages)
    //
    // Mirrors iOS `RemTalkModeManager.speakNextResponse` (lines 1241-1256).

    /// Call when a text message is sent via the composer while voice mode is
    /// active. Subscribes to the gateway event stream and speaks the next
    /// assistant response via TTS.
    func speakNextResponse() {
        guard self.isEnabled, let gateway else { return }
        // Composer speech takes ownership of the shared voice pipeline. Cancellation propagates
        // through the transcript's dispatch boundary: before start it prevents `chat.send` and
        // retires the exact handoff; after start it waits for acceptance and aborts that exact run.
        self.cancelActiveTranscriptAndRetainResolution()
        let displacedTranscriptTask = displacedTranscriptResolutionTask
        composerStreamingTaskOwner = nil
        composerStreamingTask?.cancel()
        self.resetIncrementalSpeech()
        let owner = UUID()
        let attachment = currentAttachment
        let generation = incrementalSpeechGeneration
        composerStreamingTaskOwner = owner
        composerStreamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A started voice dispatch owns the shared event stream until its accepted run has
            // been retired and exactly aborted. Do not let composer TTS consume those deltas.
            if let displacedTranscriptTask {
                await displacedTranscriptTask.value
            }
            guard self.composerTaskCanMutate(
                owner: owner,
                attachment: attachment,
                generation: generation
            ) else { return }
            if let composerStreamOperation = self.composerStreamOperation {
                await composerStreamOperation()
            } else {
                await self.streamAssistant(
                    gateway: gateway,
                    attachment: attachment,
                    expectedGeneration: generation
                )
            }
            guard self.composerTaskCanMutate(
                owner: owner,
                attachment: attachment,
                generation: generation
            ) else { return }
            await self.finishIncrementalSpeech(
                attachment: attachment,
                expectedGeneration: generation
            )
            guard self.composerTaskCanMutate(
                owner: owner,
                attachment: attachment,
                generation: generation
            ) else { return }
            self.composerStreamingTaskOwner = nil
            self.composerStreamingTask = nil
        }
    }

    private func updateIncrementalContextIfNeeded() async {
        if !incrementalSpeechConfigurationResolved {
            let generation = incrementalSpeechGeneration
            await reloadConfig(expectedIncrementalGeneration: generation)
            guard generation == incrementalSpeechGeneration else { return }
            incrementalSpeechConfigurationResolved = true
        }
        let directive = self.incrementalSpeechBuffer.directive
        if let existing = self.incrementalSpeechContext, directive == self.incrementalSpeechDirective {
            if existing.language != self.incrementalSpeechLanguage {
                self.incrementalSpeechContext = MacIncrementalSpeechContext(
                    voiceId: existing.voiceId,
                    modelId: existing.modelId,
                    outputFormat: existing.outputFormat,
                    language: self.incrementalSpeechLanguage,
                    directive: existing.directive,
                    canUseGatewaySynthesis: existing.canUseGatewaySynthesis)
            }
            return
        }
        let context = self.buildIncrementalSpeechContext(directive: directive)
        self.incrementalSpeechContext = context
        self.incrementalSpeechDirective = directive
    }

    private func buildIncrementalSpeechContext(directive: TalkDirective?) -> MacIncrementalSpeechContext {
        let voiceId = directive?.voiceId ?? self.currentVoiceId ?? self.defaultVoiceId
        let modelId = directive?.modelId ?? self.currentModelId ?? self.defaultModelId
        let outputFormatStr = (directive?.outputFormat ?? self.defaultOutputFormat)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = self.incrementalSpeechLanguage
        return MacIncrementalSpeechContext(
            voiceId: voiceId,
            modelId: modelId,
            outputFormat: outputFormatStr,
            language: language,
            directive: directive,
            canUseGatewaySynthesis: self.gateway != nil && self.gatewayConnected)
    }

    private func makeIncrementalTTSRequest(
        text: String,
        context: MacIncrementalSpeechContext,
        outputFormat: String?
    ) -> GatewayTalkSpeechRequest {
        let directive = context.directive
        return self.makeGatewayTalkSpeechRequest(
            text: text,
            directive: directive,
            outputFormat: outputFormat)
    }

    private func speakIncrementalSegment(
        _ text: String,
        context preferredContext: MacIncrementalSpeechContext? = nil,
        prefetchedAudio: MacIncrementalPrefetchedAudio? = nil,
        owner: UUID,
        attachment: Attachment,
        generation: UInt64
    ) async {
        guard incrementalTaskCanMutate(
            owner: owner,
            attachment: attachment,
            generation: generation
        ) else { return }
        let context: MacIncrementalSpeechContext
        if let preferredContext {
            context = preferredContext
        } else {
            await self.updateIncrementalContextIfNeeded()
            guard incrementalTaskCanMutate(
                owner: owner,
                attachment: attachment,
                generation: generation
            ) else { return }
            guard let resolvedContext = self.incrementalSpeechContext else {
                try? await TalkSystemSpeechSynthesizer.shared.speak(
                    text: text,
                    language: self.incrementalSpeechLanguage)
                return
            }
            context = resolvedContext
        }

        guard context.canUseGatewaySynthesis else { return }

        let request = self.makeIncrementalTTSRequest(
            text: text,
            context: context,
            outputFormat: IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(
                for: context.outputFormat))
        let audio: MacIncrementalPrefetchedAudio
        if let prefetchedAudio, !prefetchedAudio.chunks.isEmpty {
            audio = prefetchedAudio
        } else {
            do {
                let response = try await self.gatewaySpeech.synthesize(request)
                guard incrementalTaskCanMutate(
                    owner: owner,
                    attachment: attachment,
                    generation: generation
                ) else { return }
                guard let data = response.data else { return }
                audio = MacIncrementalPrefetchedAudio(
                    chunks: [data],
                    outputFormat: response.outputFormat)
            } catch {
                guard incrementalTaskCanMutate(
                    owner: owner,
                    attachment: attachment,
                    generation: generation
                ) else { return }
                if GatewayTalkSpeechFallbackPolicy.shouldUseSystemVoice(for: error) {
                    try? await TalkSystemSpeechSynthesizer.shared.speak(
                        text: text,
                        language: self.incrementalSpeechLanguage)
                } else if !Task.isCancelled {
                    self.statusText = "Speak failed: \(error.localizedDescription)"
                }
                return
            }
        }
        guard incrementalTaskCanMutate(
            owner: owner,
            attachment: attachment,
            generation: generation
        ) else { return }
        let data = audio.chunks.reduce(into: Data()) { combined, chunk in
            combined.append(chunk)
        }
        guard !data.isEmpty else { return }
        self.lastPlaybackWasPCM = false
        self.lastPlaybackWasBufferedMP3 = true
        let result = await self.bufferedMP3Player.play(data: data)
        guard incrementalTaskCanMutate(
            owner: owner,
            attachment: attachment,
            generation: generation
        ) else { return }
        if !result.finished, let interruptedAt = result.interruptedAt {
            self.lastInterruptedAtSeconds = interruptedAt
        }
    }

    // MARK: - Config loading
    //
    // Mirrors iOS `RemTalkModeManager.reloadConfig`. Voice Settings writes the
    // canonical provider-scoped Talk config, and `talk.config` returns that
    // effective selection without exposing the provider credential.

    private func reloadConfig(expectedIncrementalGeneration: UInt64? = nil) async {
        do {
            let res: Data
            if let talkConfigRequestForTesting {
                res = try await talkConfigRequestForTesting()
            } else {
                guard let gateway else { return }
                res = try await gateway.request(
                    method: "talk.config",
                    paramsJSON: "{}",
                    timeoutSeconds: 8)
            }
            guard let json = try JSONSerialization.jsonObject(with: res) as? [String: Any] else { return }
            guard let config = json["config"] as? [String: Any] else { return }
            let talk = config["talk"] as? [String: Any]
            let selection = try VoiceSettingsConfigParser.runtimeSelection(from: res)
            if let expectedIncrementalGeneration,
               expectedIncrementalGeneration != incrementalSpeechGeneration {
                return
            }
            self.defaultVoiceId = selection?.voiceID
            self.currentVoiceId = selection?.voiceID
            self.defaultModelId = selection?.modelID
            self.currentModelId = selection?.modelID
            self.defaultOutputFormat = selection?.outputFormat
            self.interruptOnSpeech = talk?["interruptOnSpeech"] as? Bool ?? true
        } catch {
            self.logger.warning("talk.config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deterministic response-boundary seam used by lifecycle tests. Production transcript and
    /// composer responses both enter through `resetIncrementalSpeech` and resolve this same snapshot.
    func beginIncrementalUtteranceForTesting() async -> String? {
        resetIncrementalSpeech()
        await updateIncrementalContextIfNeeded()
        return incrementalSpeechContext?.voiceId
    }

    func currentIncrementalUtteranceVoiceForTesting() async -> String? {
        await updateIncrementalContextIfNeeded()
        return incrementalSpeechContext?.voiceId
    }

    // MARK: - Permissions
    //
    // Mac uses `AVCaptureDevice.requestAccess(for: .audio)` — the iOS API
    // (`AVAudioSession.requestRecordPermission`) does not exist on macOS.
    // `SFSpeechRecognizer.requestAuthorization` is cross-platform.

    nonisolated static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    nonisolated static func requestSpeechPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: break
        @unknown default: return false
        }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                cont.resume(returning: authStatus == .authorized)
            }
        }
    }
}
// swiftlint:enable type_body_length

// MARK: - MacVoiceSpeechActivity

/// Pure "is TTS output active?" decision — mirrors iOS `VoiceSpeechActivity`. Extracted so the
/// stuck-flag watchdog is testable and shared in intent across platforms. `isSpeaking` short-circuits
/// `true` (never clips active speech); pending-but-silent incremental-speech flags time out after
/// `staleWindow` so a chat run that ends WITHOUT a `final` event can't pin output active forever.
enum MacVoiceSpeechActivity {
    static func isActive(
        isSpeaking: Bool,
        hasPendingSpeech: Bool,
        lastProgress: Date?,
        now: Date,
        staleWindow: TimeInterval
    ) -> Bool {
        if isSpeaking { return true }
        guard hasPendingSpeech else { return false }
        guard let lastProgress else { return false }
        return now.timeIntervalSince(lastProgress) < staleWindow
    }
}

// MARK: - MacIncrementalSpeechBuffer
//
// Mirrors iOS `IncrementalSpeechBuffer` (RemTalkModeManager.swift lines
// 1419-1532). Renamed to avoid symbol collision if iOS sources ever merge
// into a shared module. Behavior is identical — buffers streaming assistant
// text and extracts speakable segments at sentence boundaries, skipping
// code blocks and parsing any TalkDirective on the first line.

private struct MacIncrementalSpeechBuffer {
    private(set) var latestText: String = ""
    private(set) var directive: TalkDirective?
    private var spokenOffset: Int = 0
    private var inCodeBlock = false
    private var directiveParsed = false

    mutating func ingest(text: String, isFinal: Bool) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let usable = self.stripDirectiveIfReady(from: normalized) else { return [] }
        self.updateText(usable)
        return self.extractSegments(isFinal: isFinal)
    }

    mutating func flush() -> String? {
        guard !self.latestText.isEmpty else { return nil }
        let segments = self.extractSegments(isFinal: true)
        return segments.first
    }

    private mutating func stripDirectiveIfReady(from text: String) -> String? {
        guard !self.directiveParsed else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") {
            guard let newlineRange = text.range(of: "\n") else { return nil }
            let firstLine = text[..<newlineRange.lowerBound]
            let head = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.hasSuffix("}") else { return nil }
            let parsed = TalkDirectiveParser.parse(text)
            if let directive = parsed.directive {
                self.directive = directive
            }
            self.directiveParsed = true
            return parsed.stripped
        }
        self.directiveParsed = true
        return text
    }

    private mutating func updateText(_ newText: String) {
        // Content-anchored, provably no-replay tail selection (#1092 / #1112 + double-speech regression).
        //
        // `spokenOffset` is a RAW character index: it marks how many leading characters have already
        // been voiced, and we only ever speak the tail beyond it. That numeric index is only
        // trustworthy while the already-spoken region keeps the same LENGTH. During streaming, deltas
        // just grow the text (newText has the old text as a prefix), so the offset stays valid — the
        // fast path below.
        //
        // At the #1112 reconcile we instead ingest the AUTHORITATIVE history text, which can be
        // reformatted relative to what streamed: markdown emphasis (`**bold**`) inserted, or runs of
        // whitespace collapsed, INSIDE the already-spoken region. Any such length change before the
        // offset shifts every later character, so a numeric offset now points at different content —
        // it would replay a fragment of an already-voiced sentence (Codex P1) or clip the new one.
        // A raw count cannot survive a length change before it.
        //
        // So on divergence we re-anchor on CONTENT: take the text we already spoke and LOCATE it
        // inside the authoritative text, ignoring whitespace and markdown formatting, then set the
        // offset to the boundary just past it and speak only what follows. The absolute rule is NEVER
        // replay audio: if the already-spoken content cannot be confidently located (content
        // mismatch, or the authoritative text is shorter than what we already spoke), we treat the
        // whole authoritative text as already-spoken and emit nothing for the ambiguous region — a
        // tiny silent under-speak is an acceptable worst case; a replay is not. The #1092 win
        // survives: a clean extension (history == streamed prefix + new tail) still speaks that tail
        // exactly once, via either the fast path or an exact content anchor.
        if newText.hasPrefix(self.latestText) {
            self.latestText = newText
        } else {
            let spokenRaw = Array(self.latestText.prefix(self.spokenOffset))
            let authoritative = Array(newText)
            self.latestText = newText
            self.spokenOffset = Self.boundaryAfterSpoken(spokenRaw, in: authoritative) ?? authoritative.count
        }
        if self.spokenOffset > self.latestText.count {
            self.spokenOffset = self.latestText.count
        }
    }

    /// Locates the already-spoken content within `authoritative` and returns the raw index just
    /// past it, tolerant of whitespace and markdown-formatting differences (emphasis / code /
    /// heading markers) — the reformatting history can apply relative to the streamed text. Matches
    /// the significant (content) characters of `spokenRaw` in order, skipping ignorable characters on
    /// the authoritative side. Returns `nil` when the spoken content is not a formatting-insensitive
    /// prefix of `authoritative` (a content mismatch, or `authoritative` ran out first), so the
    /// caller under-speaks rather than risk replaying audio.
    private static func boundaryAfterSpoken(_ spokenRaw: [Character], in authoritative: [Character]) -> Int? {
        let spokenSignificant = spokenRaw.filter { Self.isSignificantForMatch($0) }
        if spokenSignificant.isEmpty { return 0 }
        var matched = 0
        var idx = 0
        while idx < authoritative.count {
            let ch = authoritative[idx]
            if Self.isSignificantForMatch(ch) {
                guard ch == spokenSignificant[matched] else { return nil }
                matched += 1
                idx += 1
                if matched == spokenSignificant.count { return idx }
            } else {
                idx += 1
            }
        }
        return nil
    }

    /// Characters that carry spoken CONTENT. Whitespace and the markdown markers history may add or
    /// remove around already-voiced text are ignored, so content re-anchoring survives reformatting.
    private static func isSignificantForMatch(_ ch: Character) -> Bool {
        if ch.isWhitespace { return false }
        switch ch {
        case "*", "_", "`", "~", "#": return false
        default: return true
        }
    }

    private mutating func extractSegments(isFinal: Bool) -> [String] {
        let chars = Array(self.latestText)
        guard self.spokenOffset < chars.count else { return [] }
        var idx = self.spokenOffset
        var lastBoundary: Int?
        var inCodeBlock = self.inCodeBlock
        var buffer = ""
        var bufferAtBoundary = ""
        var inCodeBlockAtBoundary = inCodeBlock

        while idx < chars.count {
            if idx + 2 < chars.count,
               chars[idx] == "`", chars[idx + 1] == "`", chars[idx + 2] == "`" {
                inCodeBlock.toggle()
                idx += 3
                continue
            }

            if !inCodeBlock {
                buffer.append(chars[idx])
                if Self.isBoundary(chars[idx]) {
                    lastBoundary = idx + 1
                    bufferAtBoundary = buffer
                    inCodeBlockAtBoundary = inCodeBlock
                }
            }
            idx += 1
        }

        // On a final flush, speak EVERYTHING still unspoken — not just up to the last
        // sentence boundary. The previous ordering returned text up to `lastBoundary` and
        // silently dropped any trailing fragment after it, truncating the spoken reply when
        // the final sentence contained an interior "." (e.g. a version like "26.2") or ended
        // without terminal punctuation (#1092).
        if isFinal {
            self.spokenOffset = chars.count
            self.inCodeBlock = inCodeBlock
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        if let boundary = lastBoundary {
            self.spokenOffset = boundary
            self.inCodeBlock = inCodeBlockAtBoundary
            let trimmed = bufferAtBoundary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        return []
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == "." || ch == "!" || ch == "?" || ch == "\n"
    }
}

// MARK: - MacIncrementalSpeechContext

private struct MacIncrementalSpeechContext: Equatable {
    let voiceId: String?
    let modelId: String?
    let outputFormat: String?
    let language: String?
    let directive: TalkDirective?
    let canUseGatewaySynthesis: Bool
}

private struct MacIncrementalSpeechPrefetchState {
    let id: UUID
    let segment: String
    let context: MacIncrementalSpeechContext
    var outputFormat: String?
    var chunks: [Data]?
    let task: Task<Void, Never>
}

private struct MacIncrementalPrefetchedAudio {
    let chunks: [Data]
    let outputFormat: String?
}
