import AVFAudio
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import Foundation
import Observation
import OSLog
import Speech

struct VoiceQuotaDeniedPresentation: Equatable {
    let isListening: Bool
    let isMuted: Bool
    let statusText: String

    static func recoverable(message: String) -> VoiceQuotaDeniedPresentation {
        VoiceQuotaDeniedPresentation(
            isListening: false,
            isMuted: true,
            statusText: message
        )
    }
}

enum VoiceQuotaRetryPolicy {
    static func allowsUnmute(reservationRetryBlocked: Bool) -> Bool {
        !reservationRetryBlocked
    }
}

/// Ownership check for asynchronous `SFSpeechRecognitionTask` callbacks.
///
/// Speech cancels are not a callback barrier: Apple may still deliver a final result after
/// `cancel()` returns. Talk Mode deliberately keeps recognition alive during TTS for barge-in, so a
/// late result from that retired recognizer can otherwise arrive after speech output becomes idle
/// and be submitted as a brand-new user turn. The voice pipeline already generation-guards chat and
/// synthesis work; recognition uses the same fail-closed ownership rule.
enum VoiceRecognitionCallbackAuthority {
    static func canHandle(capturedGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        capturedGeneration == currentGeneration
    }
}

struct TalkSessionBindingPayload: Codable, Equatable {
    let key: String
    let verboseLevel: String
    let execNode: String

    static func currentDevice(sessionKey: String) -> TalkSessionBindingPayload? {
        let key = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodeID = DeviceIdentityStore.loadOrCreate().deviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !nodeID.isEmpty else { return nil }
        return TalkSessionBindingPayload(key: key, verboseLevel: "on", execNode: nodeID)
    }
}

/// Deterministic narration plan for authored prose. Provider speech requests are deliberately
/// bounded and sequential: treating a multi-paragraph brief as one opaque request allowed a
/// provider/player completion after paragraph one to end the whole reading session.
enum ExplicitSpeechPlaybackPlan {
    static func chunks(from text: String, maximumCharacters: Int = 1_800) -> [String] {
        guard maximumCharacters > 0 else { return [] }
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.flatMap { split($0, maximumCharacters: maximumCharacters) }
    }

    private static func split(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var remainder = text
        var result: [String] = []
        while remainder.count > maximumCharacters {
            let boundary = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
            let prefix = remainder[..<boundary]
            let cut = prefix.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" || $0.isWhitespace })
                ?? prefix.index(before: prefix.endIndex)
            let chunk = String(remainder[...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remainder = String(remainder[remainder.index(after: cut)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }
}

struct ExplicitSpeechPlaybackProgress: Equatable {
    let totalChunks: Int
    private(set) var completedChunks = 0
    private(set) var wasInterrupted = false

    var isComplete: Bool {
        totalChunks > 0 && completedChunks == totalChunks && !wasInterrupted
    }

    mutating func completeNextChunk() {
        guard !wasInterrupted, completedChunks < totalChunks else { return }
        completedChunks += 1
    }

    mutating func interrupt() {
        wasInterrupted = true
    }
}

enum ExplicitSpeechPlaybackOutcome: Equatable {
    case completed
    case stoppedByUser
    case failed
}

enum ExplicitSpeechPlaybackExecutor {
    static func run(
        chunks: [String],
        shouldContinue: () -> Bool,
        play: (String) async -> Bool,
        onChunkCompleted: (Int, Int) -> Void = { _, _ in }
    ) async -> ExplicitSpeechPlaybackOutcome {
        guard !chunks.isEmpty else { return .failed }
        for (index, chunk) in chunks.enumerated() {
            guard shouldContinue() else { return .stoppedByUser }
            guard await play(chunk) else { return .failed }
            onChunkCompleted(index + 1, chunks.count)
        }
        return shouldContinue() ? .completed : .stoppedByUser
    }
}

enum ExplicitSpeechPlaybackCompletionPolicy {
    static func shouldResumeListening(
        after outcome: ExplicitSpeechPlaybackOutcome,
        voiceSessionEnabled: Bool
    ) -> Bool {
        guard voiceSessionEnabled else { return false }
        return outcome == .completed || outcome == .stoppedByUser
    }

    static func shouldRecordReadReceipt(after outcome: ExplicitSpeechPlaybackOutcome) -> Bool {
        outcome == .completed
    }
}

struct ExplicitSpeechPlaybackPresentationState: Equatable {
    let isReading: Bool
    let isMuted: Bool
    let isListening: Bool
    let canRetry: Bool

    static func resolve(after outcome: ExplicitSpeechPlaybackOutcome?) -> Self {
        switch outcome {
        case nil:
            return Self(isReading: true, isMuted: true, isListening: false, canRetry: false)
        case .completed, .stoppedByUser:
            return Self(isReading: false, isMuted: false, isListening: true, canRetry: false)
        case .failed:
            return Self(isReading: false, isMuted: true, isListening: false, canRetry: true)
        }
    }
}

struct ExplicitSpeechRetryToken: Equatable {
    let text: String
    let context: ExplicitSpeechRetryContext
    let generation: UInt
}

struct ExplicitSpeechRetryContext: Equatable {
    let accountID: String
    let gatewayID: String
    let sessionKey: String
    let localDayKey: String
    let briefKey: String
}

enum ExplicitSpeechRetryPolicy {
    static func canRetry(
        _ token: ExplicitSpeechRetryToken?,
        expectedContext: ExplicitSpeechRetryContext?,
        currentGeneration: UInt,
        voiceSessionEnabled: Bool
    ) -> Bool {
        guard let token, let expectedContext, voiceSessionEnabled else { return false }
        return token.context == expectedContext && token.generation == currentGeneration
    }
}

enum ExplicitSpeechPlaybackContextPolicy {
    static func shouldCancel(
        expected: ExplicitSpeechRetryContext?,
        current: ExplicitSpeechRetryContext?,
        playbackIsActive: Bool
    ) -> Bool {
        playbackIsActive && expected != nil && expected != current
    }

    static func canRecordReceipt(
        expected: ExplicitSpeechRetryContext?,
        current: ExplicitSpeechRetryContext?,
        outcome: ExplicitSpeechPlaybackOutcome
    ) -> Bool {
        outcome == .completed && expected != nil && expected == current
    }
}

/// Voice mode manager for RemClaw using the TalkMode pattern:
/// Apple SFSpeechRecognizer (STT) → silence detection → chat.send → gateway Talk synthesis.
///
/// Shares the same gateway session and session key as text chat, so voice and text
/// conversations flow into the same context. No separate server infrastructure needed.
///
/// Adapted from OpenClaw's TalkModeManager with RemClaw-specific gateway integration.
// swiftlint:disable type_body_length
@MainActor
@Observable
final class RemTalkModeManager: NSObject {
    struct VoiceRouteAuthority: Equatable, Sendable {
        let sessionKey: String
        fileprivate let attachmentGeneration: UInt64
    }

    private typealias SpeechRequest = SFSpeechAudioBufferRecognitionRequest

    // MARK: - Voice transcription state (chat view bridge)

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
    private(set) var isReadingAloud: Bool = false
    private(set) var canRetryReadingAloud: Bool = false
    private(set) var explicitPlaybackCompletedChunks = 0
    private(set) var explicitPlaybackTotalChunks = 0
    var statusText: String = "Off"
    var responsePhase: VoiceResponsePhase = .idle
    /// 0..1 mic level for UI visualization.
    var micLevel: Double = 0
    /// Transcript messages for the voice session UI.
    var messages: [RemMessageModel] = []
    /// Current voice transcription state for inline chat view rendering.
    var transcriptionState: VoiceTranscriptionState = .idle
    /// Texts of all voice-sent messages this session (persists for "Transcribed" label).
    var voiceTranscripts: Set<String> = []
    /// Latest user utterance for external surfaces (e.g. Live Activity).
    var latestUserPreview: String?
    /// Latest assistant text preview, including incremental streaming updates.
    var latestAssistantPreview: String?
    /// When non-nil, the voice session is idle and counting down to an automatic close at this
    /// instant. The UI shows a draining progress line at the top edge of the voice bar plus a
    /// "keep open" control; any new activity (or that tap) clears it. Nil = actively in use.
    var autoCloseAt: Date?

    // MARK: - Inactivity auto-close

    /// Idle duration after which an untouched voice session begins closing itself (O request).
    /// DEBUG: pass `-voiceIdleTimeout <seconds>` as a launch arg to trigger the countdown quickly
    /// for visual verification instead of waiting the full 5 minutes.
    private var voiceIdleTimeout: TimeInterval {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-voiceIdleTimeout"), i + 1 < args.count,
           let seconds = Double(args[i + 1]) {
            return seconds
        }
        #endif
        return 300 // 5 minutes
    }
    /// Visible countdown once idle is reached — long enough to notice and cancel before it closes.
    private let voiceAutoCloseCountdown: TimeInterval = 30
    /// Full window the top progress line represents, so the view can render `remaining / duration`.
    var voiceAutoCloseCountdownDuration: TimeInterval { voiceAutoCloseCountdown }
    private var inactivityTask: Task<Void, Never>?

    // MARK: - Configuration

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
    /// Invalidates callbacks from a recognizer synchronously before its cancellation can emit a
    /// final result. Wrapping is intentional and follows the manager's other generation counters.
    private var recognitionCallbackGeneration: UInt64 = 0
    private var silenceTask: Task<Void, Never>?

    // MARK: - Silence detection

    private let silenceWindow: TimeInterval = 1.5
    private var lastHeard: Date?
    private var lastAudioActivity: Date?
    private var lastTranscript: String = ""
    private var deniedUtteranceRoute: VoiceRouteAuthority?
    private var attachmentGeneration: UInt64 = 0
    private var noiseFloorSamples: [Double] = []
    private var noiseFloor: Double?
    private var noiseFloorReady: Bool = false

    // MARK: - TTS state

    private var lastSpokenText: String?
    /// Accumulates ALL text spoken during one AI response (across incremental segments).
    /// Used for echo detection — prevents TTS audio feeding back as user input.
    private var spokenTextAccumulator: String = ""
    /// Timestamp when TTS playback last finished. Used with spokenTextAccumulator
    /// to detect post-TTS echo in the brief window after playback ends.
    private var lastSpeakEndTime: Date?
    private var lastInterruptedAtSeconds: Double?
    private var lastPlaybackWasPCM: Bool = false
    private var lastPlaybackWasBufferedMP3: Bool = false
    var pcmPlayer: PCMStreamingAudioPlaying = PCMStreamingAudioPlayer.shared
    var mp3Player: StreamingAudioPlaying = StreamingAudioPlayer.shared
    var bufferedMP3Player: BufferedMP3AudioPlaying = BufferedMP3AudioPlayer.shared

    // MARK: - Incremental TTS

    private var incrementalSpeechQueue: [String] = []
    private var incrementalSpeechTask: Task<Void, Never>?
    private var incrementalSpeechTaskOwner: UUID?
    private var incrementalSpeechGeneration: UInt64 = 0
    private var incrementalSpeechActive = false
    private var incrementalSpeechUsed = false
    private var incrementalSpeechLanguage: String?
    private var incrementalSpeechBuffer = IncrementalSpeechBuffer()
    private var incrementalSpeechContext: IncrementalSpeechContext?
    private var incrementalSpeechDirective: TalkDirective?
    /// Each response owns one immutable provider/model/voice snapshot. The next response clears
    /// this flag and re-reads gateway-owned `talk.config` without disturbing current playback.
    private var incrementalSpeechConfigurationResolved = false
    private var incrementalSpeechPrefetch: IncrementalSpeechPrefetchState?
    private var incrementalSpeechPrefetchMonitorTask: Task<Void, Never>?
    /// Last moment speech output genuinely progressed: a turn/stream started (`resetIncrementalSpeech`),
    /// a new segment was queued (`enqueueIncrementalSpeech`), or a segment finished playing. Powers the
    /// stuck-flag watchdog in `isSpeechOutputActive` — if the incremental-speech flags stay set but
    /// nothing has actually progressed for `speechStaleWindow`, we treat output as inactive so the
    /// inactivity clock can advance even when a chat run ends WITHOUT a `final` event (stream error,
    /// abnormal turn end, #1092-style race) and `finishIncrementalSpeech` never clears the flag.
    private var lastSpeechProgressTime: Date?
    /// How long the incremental-speech flags may stay set with NO real playback/progress before the
    /// watchdog declares output inactive. Generous vs. normal inter-segment gaps (sub-second to a
    /// couple seconds) so an actively-streaming reply is never mistaken for stuck — and `isSpeaking`
    /// short-circuits the watchdog the instant real audio resumes, so active speech is never clipped.
    private let speechStaleWindow: TimeInterval = 8

    /// Tracks the in-flight processTranscript task so stop() can cancel it.
    private var activeTranscriptTask: Task<Void, Never>?
    private var activeTranscriptTaskOwner: UUID?
    private struct PendingAcceptedVoiceAbort {
        let sessionKey: String
        let runID: String
        let gateway: GatewayNodeSession
    }
    private var pendingAcceptedVoiceAbort: PendingAcceptedVoiceAbort?

    // MARK: - Telemetry

    private var voiceSessionStartTime: Date?
    private var hasTrackedFirstCapture: Bool = false
    private var hasTrackedFirstResponse: Bool = false

    // MARK: - Gateway

    private var gateway: GatewayNodeSession?
    private let gatewaySpeech = GatewayTalkSpeechService()
    var talkConfigRequestForTesting: (@Sendable () async throws -> Data)?
    private var gatewayConnected = false
    private var sessionKey: String = "main"
    /// The conversation this voice session is attached to. The manager is app-global, so callers use
    /// this to scope voice UI (e.g. the inline transcription bubble) to the owning conversation —
    /// otherwise the shared transcription state renders in EVERY open chat.
    var attachedSessionKey: String { sessionKey }
    private weak var usageService: UsageService?
    var afterVoiceQuotaReservationForTesting: (() async -> Void)?
    private(set) var voiceChatDispatchCountForTesting = 0
    /// Whether this Talk Mode instance has successfully sent a turn in the current session.
    /// Used only for first-turn session naming; agent context is gateway-owned structured state.
    private var hasSentMessageInSession: Bool = false

    private let logger = Logger(subsystem: "com.remclaw", category: "TalkMode")

    /// Whether voice was active before an audio interruption began (phone call, alarm, etc.).
    /// Used to decide whether to resume after the interruption ends.
    private var wasActiveBeforeInterruption = false

    override init() {
        super.init()
        self.observeAudioNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio route & interruption observers

    /// Observe audio route changes (headphone plug/unplug, Bluetooth connect/disconnect)
    /// and audio interruptions (phone calls, alarms, Siri).
    private func observeAudioNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil)
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            // Audio route changed — reconfigure session and restart the engine tap
            // so STT continues with the new input device.
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.isListening else { return }
                self.logger.info("audio route changed while listening — restarting recognition")
                self.stopRecognition()
                do {
                    try Self.configureAudioSession()
                    try self.startRecognition()
                    self.statusText = "Listening"
                } catch {
                    self.logger.error("route change recovery failed: \(error.localizedDescription, privacy: .public)")
                    self.statusText = "Audio error"
                    self.isListening = false
                }
            }
        case .categoryChange, .wakeFromSleep, .noSuitableRouteForCategory, .unknown:
            break
        @unknown default:
            break
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.info("audio interruption began (phone call, alarm, etc.)")
                self.wasActiveBeforeInterruption = self.isEnabled && (self.isListening || self.isSpeaking)
                if self.wasActiveBeforeInterruption {
                    _ = self.suspendForBackground()
                    self.statusText = "Interrupted"
                }
            }
        case .ended:
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
                ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.info("audio interruption ended, shouldResume=\(shouldResume)")
                if self.wasActiveBeforeInterruption, shouldResume {
                    await self.start()
                }
                self.wasActiveBeforeInterruption = false
            }
        @unknown default:
            break
        }
    }

    // MARK: - Gateway integration

    /// Attach the gateway session. Called once from RemGatewaySessionManager.
    func attachGateway(_ gateway: GatewayNodeSession) {
        self.gateway = gateway
        self.gatewaySpeech.attach(gateway)
    }

    /// Attach usage service for quota checks before chat.send in voice mode.
    func attachUsageService(_ usageService: UsageService) {
        self.usageService = usageService
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
        let trimmed = (sessionKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearFailedExplicitReading()
            attachmentGeneration &+= 1
            cancelTranscriptProcessing()
            stopSpeaking()
            deniedUtteranceRoute = nil
            lastTranscript = ""
            lastHeard = nil
            transcriptionState = .idle
            latestUserPreview = nil
            return
        }
        clearFailedExplicitReading()
        cancelTranscriptProcessing()
        stopSpeaking()
        // Attachment identity is intentionally stronger than the reusable session string. A new
        // voice attachment to the same key invalidates every continuation owned by the prior one.
        attachmentGeneration &+= 1
        self.sessionKey = trimmed
        self.hasSentMessageInSession = false
        // Drop any lingering transcription from the PREVIOUS conversation. The inline bubble is gated
        // on attachedSessionKey==viewModel.sessionKey, which follows the active session — so without
        // this, switching to another chat (e.g. tapping one in History) while a `.sent` transcription
        // is still around would re-show that stale bubble in the new chat, and it would never
        // self-clear (the new chat's history never contains that text). Reset so it can't leak across.
        self.transcriptionState = .idle
        if deniedUtteranceRoute != currentVoiceRoute() {
            deniedUtteranceRoute = nil
            lastTranscript = ""
            lastHeard = nil
            latestUserPreview = nil
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
    func mute() {
        guard self.isEnabled else { return }
        self.isMuted = true
        if self.isReadingAloud {
            // The reading mic is independent from playback. After intentional barge-in, muting
            // again must stop only recognition; Stop Reading remains the explicit playback action.
            self.isListening = false
            self.silenceTask?.cancel()
            self.silenceTask = nil
            self.stopRecognition()
            self.statusText = "Microphone muted"
            return
        }
        guard self.isListening else { return }
        _ = self.suspendForBackground()
        self.statusText = "Muted"
    }

    /// Unmute: resume listening from muted state.
    func unmute() {
        guard self.isEnabled, self.isMuted else { return }
        guard VoiceQuotaRetryPolicy.allowsUnmute(
            reservationRetryBlocked: usageService?.reservationRetryBlocked == true
        ) else {
            applyQuotaDeniedPresentation(message: Self.ambiguousQuotaCopy)
            return
        }
        clearFailedExplicitReading()
        self.isMuted = false
        Task { await self.start() }
    }

    func start(reloadConfiguration: Bool = true) async {
        guard self.isEnabled, !self.isListening, !self.isMuted else { return }
        guard VoiceQuotaRetryPolicy.allowsUnmute(
            reservationRetryBlocked: usageService?.reservationRetryBlocked == true
        ) else {
            applyQuotaDeniedPresentation(message: Self.ambiguousQuotaCopy)
            return
        }
        guard self.gatewayConnected else {
            self.statusText = "Offline"
            return
        }

        self.statusText = "Requesting permissions..."
        let micOk = await Self.requestMicrophonePermission()
        guard self.isEnabled, !self.isMuted else { return }
        guard micOk else {
            self.statusText = "Microphone permission denied"
            return
        }
        let speechOk = await Self.requestSpeechPermission()
        guard self.isEnabled, !self.isMuted else { return }
        guard speechOk else {
            self.statusText = "Speech recognition permission denied"
            return
        }

        if reloadConfiguration {
            await self.reloadConfig()
        }
        guard self.isEnabled, !self.isMuted, !self.isListening else { return }
        do {
            try Self.configureAudioSession()
            guard self.isEnabled, !self.isMuted else { return }
            try self.startRecognition()
            guard self.isEnabled, !self.isMuted else {
                self.stopRecognition()
                return
            }
            self.isListening = true
            self.statusText = "Listening"
            self.startSilenceMonitor()
            self.startInactivityMonitor()
            self.logger.info("talk mode listening")
            self.voiceSessionStartTime = Date()
            self.hasTrackedFirstCapture = false
            self.hasTrackedFirstResponse = false
            TelemetryService.shared.track(eventName: TelemetryEvent.voiceSessionStarted)
        } catch {
            self.isListening = false
            // Provide concise user-facing messages for common failures
            let desc = error.localizedDescription
            if desc.lowercased().contains("session activation failed") || desc.lowercased().contains("setactive") {
                self.statusText = "Audio unavailable"
            } else {
                self.statusText = "Start failed: \(desc)"
            }
            self.logger.error("start failed: \(desc, privacy: .public)")
        }
    }

    func stop() {
        attachmentGeneration &+= 1
        cancelTranscriptProcessing()
        clearFailedExplicitReading()
        if let startTime = voiceSessionStartTime {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            TelemetryService.shared.track(eventName: TelemetryEvent.voiceSessionEnded, properties: [
                "duration_ms": durationMs,
            ])
        }
        self.voiceSessionStartTime = nil
        self.isEnabled = false
        self.isListening = false
        self.isMuted = false
        self.statusText = "Off"
        self.responsePhase = .idle
        self.lastTranscript = ""
        self.deniedUtteranceRoute = nil
        self.lastHeard = nil
        self.transcriptionState = .idle
        self.latestUserPreview = nil
        self.latestAssistantPreview = nil
        self.silenceTask?.cancel()
        self.silenceTask = nil
        self.inactivityTask?.cancel()
        self.inactivityTask = nil
        self.autoCloseAt = nil
        self.composerStreamingTaskOwner = nil
        self.composerStreamingTask?.cancel()
        self.composerStreamingTask = nil
        self.stopRecognition()
        self.stopSpeaking()
        self.lastInterruptedAtSeconds = nil
        TalkSystemSpeechSynthesizer.shared.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            self.logger.warning("audio session deactivate: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Suspend when app enters background without disabling.
    func suspendForBackground() -> Bool {
        guard self.isEnabled else { return false }
        let wasActive = self.isListening || self.isSpeaking
        self.isListening = false
        self.statusText = "Paused"
        self.lastTranscript = ""
        self.deniedUtteranceRoute = nil
        self.lastHeard = nil
        self.silenceTask?.cancel()
        self.silenceTask = nil
        self.stopRecognition()
        self.stopSpeaking()
        self.lastInterruptedAtSeconds = nil
        TalkSystemSpeechSynthesizer.shared.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            self.logger.warning("audio session deactivate: \(error.localizedDescription, privacy: .public)")
        }
        return wasActive
    }

    func resumeAfterBackground(wasSuspended: Bool) async {
        guard wasSuspended, self.isEnabled else { return }
        await self.start()
    }

    // MARK: - Audio session

    static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
            .allowBluetoothHFP,
            .defaultToSpeaker,
        ])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.02)

        // Activation can fail if another session is active. Retry once after
        // deactivating cleanly, which nudges the system to release the route.
        do {
            try session.setActive(true, options: [])
        } catch {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            Thread.sleep(forTimeInterval: 0.1)
            try session.setActive(true, options: [])
        }
    }

    // MARK: - Speech recognition (STT)

    private func startRecognition() throws {
        let recognizer = SFSpeechRecognizer(locale: .current)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "RemTalkMode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }
        self.speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        VoiceRecognitionRequestConfiguration.apply(to: request)
        self.recognitionRequest = request

        let input = self.audioEngine.inputNode

        // Enable voice processing before reading format — VP changes the input node's format
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            self.logger.warning("voice processing unavailable: \(error.localizedDescription, privacy: .public)")
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "RemTalkMode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio input format invalid"])
        }

        // Remove any existing tap before installing (prevents crash:
        // "required condition is false: nullptr == Tap()")
        if inputTapInstalled {
            input.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        // Audio tap: feed STT + compute mic level + detect audio activity
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
            let smoothed = 0.80 * self.micLevel + 0.20 * raw
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.micLevel = smoothed

                // Noise floor calibration
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

        self.recognitionCallbackGeneration &+= 1
        let callbackGeneration = self.recognitionCallbackGeneration
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            guard VoiceRecognitionCallbackAuthority.canHandle(
                capturedGeneration: callbackGeneration,
                currentGeneration: self.recognitionCallbackGeneration
            ) else { return }
            if let error {
                let msg = error.localizedDescription
                if !self.isSpeaking {
                    // "canceled" and "no speech detected" are expected transient states —
                    // don't flash them as errors in the voice bar.
                    let isTransient = msg.localizedCaseInsensitiveContains("cancel")
                        || msg.localizedCaseInsensitiveContains("no speech detected")
                    if !isTransient {
                        self.statusText = "Speech error: \(msg)"
                    }
                }
                // Restart on transient errors in continuous mode
                if self.isEnabled, self.isListening, !self.isSpeaking, !self.isMuted,
                   !self.isReadingAloud {
                    self.stopRecognition()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard let self, self.isEnabled, self.isListening, !self.isMuted,
                              !self.isReadingAloud else { return }
                        try? Self.configureAudioSession()
                        try? self.startRecognition()
                        self.isListening = true
                        self.statusText = "Listening"
                    }
                }
                // An error is terminal for this recognizer generation. Speech can deliver a
                // result alongside the error; accepting it after the restart above would let a
                // canceled recognizer submit a stale transcript as a new user turn.
                return
            }
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The callback can be current before this actor hop and retire while queued.
                // Revalidate immediately before mutating the active voice turn.
                guard VoiceRecognitionCallbackAuthority.canHandle(
                    capturedGeneration: callbackGeneration,
                    currentGeneration: self.recognitionCallbackGeneration
                ) else { return }
                await self.handleTranscript(transcript: transcript, isFinal: result.isFinal)
            }
        }
    }

    private func stopRecognition() {
        // Invalidate first. `SFSpeechRecognitionTask.cancel()` may synchronously or asynchronously
        // produce one last callback; neither is allowed to mutate the replacement voice turn.
        self.recognitionCallbackGeneration &+= 1
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

    private func handleTranscript(transcript: String, isFinal: Bool) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Interrupt TTS if user starts talking
        if self.isSpeechOutputActive, self.interruptOnSpeech {
            if self.shouldInterrupt(with: trimmed) {
                self.stopSpeaking()
            }
            return
        }

        guard self.isListening else { return }

        // Post-TTS echo guard: ignore transcripts that match recently spoken text.
        // After TTS finishes, the mic may pick up residual speaker audio.
        if self.isLikelyEcho(trimmed) { return }

        if !trimmed.isEmpty {
            self.lastTranscript = trimmed
            self.lastHeard = Date()
            self.transcriptionState = .transcribing(trimmed)
        }
        if isFinal, !trimmed.isEmpty {
            self.lastTranscript = trimmed
            if !self.isSpeechOutputActive {
                self.startTranscriptProcessing(trimmed)
            }
        }
    }

    private func cancelTranscriptProcessing() {
        activeTranscriptTaskOwner = nil
        let task = activeTranscriptTask
        activeTranscriptTask = nil
        task?.cancel()
    }

    private func startTranscriptProcessing(_ transcript: String) {
        cancelTranscriptProcessing()
        let owner = UUID()
        let route = currentVoiceRoute()
        let turnGeneration = incrementalSpeechGeneration
        activeTranscriptTaskOwner = owner
        activeTranscriptTask = Task { @MainActor [weak self] in
            await self?.processTranscript(
                transcript,
                restartAfter: true,
                route: route,
                owner: owner,
                turnGeneration: turnGeneration
            )
            guard let self, Self.taskOwnerCanMutate(
                capturedOwner: owner,
                currentOwner: self.activeTranscriptTaskOwner,
                capturedRoute: route,
                currentRoute: self.currentVoiceRoute()
            ) else { return }
            self.activeTranscriptTaskOwner = nil
            self.activeTranscriptTask = nil
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

    /// The most recent moment ANYTHING happened in the session — the user was heard, the mic
    /// picked up audio, the agent finished speaking, or the session just started. Drives the
    /// inactivity clock so we only auto-close a genuinely untouched session.
    private var lastVoiceActivity: Date {
        [lastHeard, lastAudioActivity, lastSpeakEndTime, voiceSessionStartTime]
            .compactMap { $0 }
            .max() ?? Date()
    }

    /// Poll for inactivity. After `voiceIdleTimeout` with no activity we begin a visible
    /// `voiceAutoCloseCountdown`; fresh activity during the countdown cancels it; if it runs out,
    /// we `stop()`. Mirrors `startSilenceMonitor`'s cheap poll loop (2s cadence is plenty here).
    private func startInactivityMonitor() {
        self.inactivityTask?.cancel()
        self.autoCloseAt = nil
        self.inactivityTask = Task { [weak self] in
            guard let self else { return }
            while self.isEnabled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.checkInactivity()
            }
        }
    }

    @MainActor
    private func checkInactivity() {
        // NOTE: a MUTED session still auto-closes. Muted means the mic is off, so no activity can
        // ever register — a muted-and-abandoned session is exactly the "walked away" case this
        // feature targets. The user still gets the visible countdown + "Keep open" to extend it.
        guard self.isEnabled else { return }

        // ACTIVE SPEECH OUTPUT keeps the session alive even while MUTED: `speakNextResponse()` speaks
        // a reply to a TEXT message without checking mute, so a muted session can legitimately be
        // reading a reply aloud — that must never be cut off mid-sentence. `mute()` clears
        // `isSpeechOutputActive` (via `stopSpeaking`), and `isSpeechOutputActive` now times out stuck
        // incremental-speech flags (see `VoiceSpeechActivity`), so when it IS `true` speech is either
        // genuinely playing or was progressing within the last few seconds — never a stuck flag that
        // would pin this clock open forever and prevent the 5-min auto-close.
        if self.isSpeechOutputActive {
            self.lastAudioActivity = Date()
            self.autoCloseAt = nil
            return
        }

        // A turn IN PROGRESS (still speaking/transcribing/handling the user's utterance) is never idle
        // — refresh the clock so an active session can't auto-close mid-reply (review finding).
        //
        // BUT skip this while MUTED: the mic is off, so `isSpeaking`/`transcriptionState` can only be
        // STALE (e.g. a lingering `.sent` that nothing resets while muted). Without this exception the
        // stale flag re-arms the idle clock every poll, so a muted-and-abandoned session runs PAST the
        // timeout and never auto-closes.
        if !self.isMuted, self.isSpeaking || self.transcriptionState != .idle {
            self.lastAudioActivity = Date()
            self.autoCloseAt = nil
            return
        }

        let idle = Date().timeIntervalSince(self.lastVoiceActivity)

        // Founder preference: auto-dismiss SILENTLY on inactivity — no visible countdown, no
        // "Keep open" CTA. When the session has been idle past the timeout, just end it; the bar
        // disappears on its own. (Previously we armed a 30s visible countdown here; removed.)
        if idle >= voiceIdleTimeout {
            self.logger.info("voice auto-closing after inactivity")
            self.stop() // stop() emits the voiceSessionEnded telemetry
        }
    }

    /// User chose to keep the session open (tapped the cancel control during the countdown), or a
    /// caller wants to defer the close. Clears the countdown and resets the inactivity clock.
    func keepVoiceOpen() {
        self.autoCloseAt = nil
        self.lastAudioActivity = Date()
    }

    private func checkSilence() async {
        guard self.isListening, !self.isSpeechOutputActive else { return }
        let transcript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        let lastActivity = [self.lastHeard, self.lastAudioActivity].compactMap { $0 }.max()
        guard let lastActivity else { return }
        if Date().timeIntervalSince(lastActivity) < self.silenceWindow { return }
        self.startTranscriptProcessing(transcript)
    }

    /// Whether TTS output should count as active for the inactivity clock (and silence/interrupt
    /// gating). Genuinely-playing audio (`isSpeaking`) always counts — never clipped. The incremental
    /// flags (`incrementalSpeechActive`/task/queue) also count, BUT only until the stuck-flag watchdog
    /// trips: if a chat run ends without a `final` event, `finishIncrementalSpeech` never runs and
    /// `incrementalSpeechActive` stays `true` forever, which used to pin this `true` on every poll so
    /// the 5-min idle auto-close was NEVER reached (voice bar hung past 5 min). See `VoiceSpeechActivity`.
    private var isSpeechOutputActive: Bool {
        VoiceSpeechActivity.isActive(
            isSpeaking: self.isSpeaking,
            hasPendingSpeech: self.incrementalSpeechActive
                || self.incrementalSpeechTask != nil
                || !self.incrementalSpeechQueue.isEmpty,
            lastProgress: self.lastSpeechProgressTime,
            now: Date(),
            staleWindow: self.speechStaleWindow)
    }

    private func shouldInterrupt(with transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBuiltInSpeaker = self.isUsingBuiltInSpeaker()
        let minLength = isBuiltInSpeaker ? 10 : 3
        guard trimmed.count >= minLength else { return false }

        // Check for novel words that aren't in TTS output.
        // STT picks up both user speech and TTS echo — interrupt only when
        // the user says something genuinely new.
        let transcriptWords = Self.strippedWords(trimmed)
        let spokenWords = Self.strippedWords(self.spokenTextAccumulator)
        guard !spokenWords.isEmpty else { return true }

        let novelWords = transcriptWords.subtracting(spokenWords)
        let minNovelWords = isBuiltInSpeaker ? 2 : 1
        return novelWords.count >= minNovelWords
    }

    /// Strips punctuation and lowercases words for comparison.
    /// STT transcripts often lack punctuation while TTS text has it,
    /// so raw comparison produces false mismatches.
    private static func strippedWords(_ text: String) -> Set<String> {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        return Set(
            text.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: punctuation) }
                .filter { !$0.isEmpty }
        )
    }

    /// Word-level echo detection. Returns true if the majority of words in the transcript
    /// appear in recently spoken text (TTS echo via built-in speaker).
    private func isWordOverlapEcho(_ transcript: String) -> Bool {
        let transcriptWords = Self.strippedWords(transcript)
        guard !transcriptWords.isEmpty else { return false }
        let spokenWords = Self.strippedWords(self.spokenTextAccumulator)
        guard !spokenWords.isEmpty else { return false }
        let overlap = transcriptWords.intersection(spokenWords).count
        let overlapRatio = Double(overlap) / Double(transcriptWords.count)
        return overlapRatio >= 0.6
    }

    /// Check if the current audio route is using built-in speaker/receiver.
    private func isUsingBuiltInSpeaker() -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        return route.outputs.contains { output in
            switch output.portType {
            case .builtInSpeaker, .builtInReceiver:
                return true
            default:
                return false
            }
        }
    }

    /// Detect TTS echo: after TTS finishes, the mic may pick up residual speaker audio.
    /// Returns true if the transcript likely came from the speaker, not the user.
    private func isLikelyEcho(_ transcript: String) -> Bool {
        guard let endTime = self.lastSpeakEndTime,
              Date().timeIntervalSince(endTime) < 2.5 else { return false }
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }
        // Substring check (strip punctuation for comparison)
        let spokenLower = self.spokenTextAccumulator.lowercased()
        if !spokenLower.isEmpty {
            let cleanTranscript = lower.trimmingCharacters(in: .punctuationCharacters)
            if spokenLower.contains(cleanTranscript) { return true }
        }
        // Word-level check
        return self.isWordOverlapEcho(transcript)
    }

    // MARK: - Chat processing

    func currentVoiceRoute() -> VoiceRouteAuthority {
        VoiceRouteAuthority(
            sessionKey: sessionKey,
            attachmentGeneration: attachmentGeneration
        )
    }

    func isCurrentVoiceRoute(_ route: VoiceRouteAuthority) -> Bool {
        route == currentVoiceRoute()
    }

    static func taskOwnerCanMutate(
        capturedOwner: UUID,
        currentOwner: UUID?,
        capturedRoute: VoiceRouteAuthority,
        currentRoute: VoiceRouteAuthority
    ) -> Bool {
        capturedOwner == currentOwner && capturedRoute == currentRoute
    }

    static func incrementalTaskCanMutate(
        capturedOwner: UUID,
        currentOwner: UUID?,
        capturedRoute: VoiceRouteAuthority,
        currentRoute: VoiceRouteAuthority,
        capturedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        taskOwnerCanMutate(
            capturedOwner: capturedOwner,
            currentOwner: currentOwner,
            capturedRoute: capturedRoute,
            currentRoute: currentRoute
        ) && capturedGeneration == currentGeneration
    }

    static func composerTaskCanMutate(
        capturedOwner: UUID,
        currentOwner: UUID?,
        capturedRoute: VoiceRouteAuthority,
        currentRoute: VoiceRouteAuthority,
        capturedIncrementalGeneration: UInt64,
        currentIncrementalGeneration: UInt64
    ) -> Bool {
        taskOwnerCanMutate(
            capturedOwner: capturedOwner,
            currentOwner: currentOwner,
            capturedRoute: capturedRoute,
            currentRoute: currentRoute
        ) && capturedIncrementalGeneration == currentIncrementalGeneration
    }

    func transcriptTurnCanMutate(
        owner: UUID?,
        route: VoiceRouteAuthority,
        expectedGeneration: UInt64? = nil
    ) -> Bool {
        Self.transcriptTurnCanMutate(
            capturedOwner: owner,
            currentOwner: activeTranscriptTaskOwner,
            capturedRoute: route,
            currentRoute: currentVoiceRoute(),
            expectedGeneration: expectedGeneration,
            currentGeneration: incrementalSpeechGeneration
        )
    }

    static func transcriptTurnCanMutate(
        capturedOwner: UUID?,
        currentOwner: UUID?,
        capturedRoute: VoiceRouteAuthority,
        currentRoute: VoiceRouteAuthority,
        expectedGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        guard capturedRoute == currentRoute else { return false }
        if let capturedOwner, capturedOwner != currentOwner { return false }
        if let expectedGeneration, expectedGeneration != currentGeneration { return false }
        return true
    }

    func processTranscript(
        _ transcript: String,
        restartAfter: Bool,
        route: VoiceRouteAuthority? = nil,
        owner: UUID? = nil,
        turnGeneration: UInt64? = nil
    ) async {
        // One captured utterance belongs to the conversation that was attached when processing
        // began. Navigation may update `self.sessionKey` while gateway requests are suspended.
        let turnRoute = route ?? currentVoiceRoute()
        let preSpeechGeneration = turnGeneration ?? incrementalSpeechGeneration
        guard !Task.isCancelled,
              transcriptTurnCanMutate(
                  owner: owner,
                  route: turnRoute,
                  expectedGeneration: preSpeechGeneration
              ) else { return }
        if pendingAcceptedVoiceAbort != nil {
            do {
                try await retryPendingAcceptedVoiceAbort()
            } catch {
                guard transcriptTurnCanMutate(
                    owner: owner,
                    route: turnRoute,
                    expectedGeneration: preSpeechGeneration
                ) else { return }
                statusText = error.localizedDescription
                preserveDeniedUtterance(transcript, route: turnRoute)
                return
            }
            guard !Task.isCancelled,
                  transcriptTurnCanMutate(
                      owner: owner,
                      route: turnRoute,
                      expectedGeneration: preSpeechGeneration
                  ) else { return }
        }
        let turnSessionKey = turnRoute.sessionKey
        var turnSpeechGeneration: UInt64?
        self.responsePhase = .thinking
        defer {
            if self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration ?? preSpeechGeneration
            ),
               self.responsePhase.isWorking {
                self.responsePhase = .idle
            }
        }
        if !hasTrackedFirstCapture {
            hasTrackedFirstCapture = true
            TelemetryService.shared.track(eventName: TelemetryEvent.voiceCaptureStarted, properties: [
                "session_key": turnSessionKey,
            ])
        }
        self.isListening = false
        self.statusText = "Thinking..."
        self.lastTranscript = ""
        self.lastHeard = nil
        self.stopRecognition()

        guard self.gatewayConnected, let gateway else {
            self.statusText = "Gateway not connected"
            self.preserveDeniedUtterance(transcript, route: turnRoute)
            if restartAfter {
                await self.start()
            }
            return
        }

        // Match text chat behavior: consume one quota slot for each voice turn.
        guard let usageService else {
            self.applyQuotaDeniedPresentation(message: "Couldn't verify your plan. Check your connection and try again.")
            self.preserveDeniedUtterance(transcript, route: turnRoute)
            self.logger.error("voice quota service unavailable; denying the turn")
            return
        }
        let reservation: UsageService.RequestSlotReservation
        do {
            reservation = try await usageService.consumeRequestSlot()
            if let afterVoiceQuotaReservationForTesting {
                await afterVoiceQuotaReservationForTesting()
            }
            guard !Task.isCancelled,
                  self.transcriptTurnCanMutate(
                      owner: owner,
                      route: turnRoute,
                      expectedGeneration: preSpeechGeneration
                  ) else {
                // The consume 200 already charged this slot, but takeover happened before any
                // gateway dispatch. Persist the exact terminal disposition before releasing the
                // stale continuation so this utterance cannot retry and future turns stay usable.
                usageService.markReservedRequestCancelledBeforeDispatch(reservation)
                return
            }
            usageService.dismissQuotaError()
        } catch {
            guard !Task.isCancelled,
                  self.transcriptTurnCanMutate(
                      owner: owner,
                      route: turnRoute,
                      expectedGeneration: preSpeechGeneration
                  ) else { return }
            switch UsageSlotFailurePolicy.classify(error) {
            case .quotaExceeded(let quota):
                usageService.handleQuotaExceeded(quota)
                self.applyQuotaDeniedPresentation(message: quota.message)
            case .verificationUnavailable:
                self.applyQuotaDeniedPresentation(message: "Couldn't verify your plan. Check your connection and try again.")
            case .reservationRetryBlocked:
                self.applyQuotaDeniedPresentation(message: Self.ambiguousQuotaCopy)
            }
            self.preserveDeniedUtterance(transcript, route: turnRoute)
            self.logger.warning("voice quota consume denied the turn: \(error.localizedDescription, privacy: .public)")
            return
        }

        let prompt = self.buildPrompt(transcript: transcript)
        let isFirstMessage = !self.hasSentMessageInSession || SessionDisplayNames.name(for: turnSessionKey) == nil

        #if DEBUG
        print("[VoiceSTT] transcript: \(transcript.prefix(200))")
        #endif

        // Hoisted out of the `do` so the `catch` can cancel it too — otherwise a throw (e.g.
        // `waitForAssistantText`) leaves `streamAssistant` orphaned on the still-open agent event
        // stream, where it keeps ingesting later deltas, re-arms the speech task, and speaks content
        // from the FAILED turn on top of the next listening turn (cross-talk).
        var streamingTask: Task<Void, Never>?
        do {
            let startedAt = Date().timeIntervalSince1970
            let runId = try await self.sendChat(
                prompt,
                sessionKey: turnSessionKey,
                gateway: gateway,
                usageService: usageService,
                reservation: reservation
            )
            guard !Task.isCancelled,
                  self.transcriptTurnCanMutate(
                      owner: owner,
                      route: turnRoute,
                      expectedGeneration: preSpeechGeneration
                  ) else { return }
            self.hasSentMessageInSession = true

            // Publish speech/history only after the captured route's run is accepted. Navigation
            // during quota/send leaves the replacement route untouched.
            self.deniedUtteranceRoute = nil
            self.transcriptionState = .sent(transcript)
            self.voiceTranscripts.insert(transcript)
            self.latestUserPreview = transcript
            self.latestAssistantPreview = nil
            self.messages.append(RemMessageModel(
                text: transcript, sender: .user, timestamp: Date()))
            print("[RemTalkMode] chat.send ok runId=\(runId)")
            SessionLastMessageTimes.touch(turnSessionKey)

            // Name the voice session from the first transcript
            if isFirstMessage {
                let generatedName = SessionDisplayNames.generateName(from: transcript)
                SessionDisplayNames.setNameIfAbsent(generatedName, for: turnSessionKey)
                // Persist to gateway (fire-and-forget)
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
                        #if DEBUG
                        print("[RemTalkMode] sessions.patch label=\(generatedName) for \(turnSessionKey)")
                        #endif
                    }
                }
            }

            guard !Task.isCancelled,
                  self.transcriptTurnCanMutate(
                      owner: owner,
                      route: turnRoute,
                      expectedGeneration: preSpeechGeneration
                  ) else { return }

            // Start incremental TTS streaming
            self.resetIncrementalSpeech()
            let speechGeneration = self.incrementalSpeechGeneration
            turnSpeechGeneration = speechGeneration
            streamingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.streamAssistant(
                    runId: runId,
                    gateway: gateway,
                    route: turnRoute,
                    expectedGeneration: speechGeneration,
                    transcriptOwner: owner
                )
            }

            let completion = await self.waitForChatCompletion(runId: runId, gateway: gateway, timeoutSeconds: 120)
            guard self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration ?? preSpeechGeneration
            ) else {
                streamingTask?.cancel()
                return
            }
            if Task.isCancelled || completion == .aborted || completion == .error {
                self.statusText = completion == .aborted ? "Aborted" : (Task.isCancelled ? "Off" : "Chat error")
                self.transcriptionState = .idle
                streamingTask?.cancel()
                await self.finishIncrementalSpeech(
                    route: turnRoute,
                    expectedGeneration: turnSpeechGeneration
                )
                guard self.transcriptTurnCanMutate(
                    owner: owner,
                    route: turnRoute,
                    expectedGeneration: turnSpeechGeneration
                ) else { return }
                if !Task.isCancelled, restartAfter {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard self.transcriptTurnCanMutate(
                        owner: owner,
                        route: turnRoute,
                        expectedGeneration: turnSpeechGeneration
                    ) else { return }
                    await self.start()
                }
                return
            }

            guard !Task.isCancelled else {
                streamingTask?.cancel()
                return
            }

            // Fetch the full assistant text from history
            var assistantText = try await self.waitForAssistantText(
                gateway: gateway,
                sessionKey: turnSessionKey,
                since: startedAt,
                timeoutSeconds: completion == .final ? 12 : 25)
            guard self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration ?? preSpeechGeneration
            ) else {
                streamingTask?.cancel()
                return
            }

            // Fallback to incremental buffer if history fetch fails
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
                    route: turnRoute,
                    expectedGeneration: turnSpeechGeneration
                )
                guard self.transcriptTurnCanMutate(
                    owner: owner,
                    route: turnRoute,
                    expectedGeneration: turnSpeechGeneration
                ) else { return }
                if restartAfter {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard self.transcriptTurnCanMutate(
                        owner: owner,
                        route: turnRoute,
                        expectedGeneration: turnSpeechGeneration
                    ) else { return }
                    await self.start()
                }
                return
            }

            // Add assistant message to transcript
            let parsed = TalkDirectiveParser.parse(assistantText)
            let cleanText = parsed.stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            #if DEBUG
            print("[VoiceTTS] response: \(assistantText.prefix(200))")
            #endif
            if !cleanText.isEmpty {
                self.messages.append(RemMessageModel(
                    text: cleanText, sender: .ai, timestamp: Date()))
                self.latestAssistantPreview = cleanText

                if let startTime = voiceSessionStartTime, !hasTrackedFirstResponse {
                    hasTrackedFirstResponse = true
                    let delayMs = Int(Date().timeIntervalSince(startTime) * 1000)
                    TelemetryService.shared.track(eventName: TelemetryEvent.voiceFirstResponseReceived, properties: [
                        "session_key": turnSessionKey,
                        "delay_ms": max(delayMs, 0),
                        "response_length": cleanText.count,
                    ])
                }
            }

            guard !Task.isCancelled else {
                streamingTask?.cancel()
                return
            }

            streamingTask?.cancel()
            guard self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration
            ) else { return }
            await self.handleIncrementalAssistantFinal(
                text: assistantText,
                route: turnRoute,
                owner: owner,
                expectedGeneration: turnSpeechGeneration
            )
            guard self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration
            ) else { return }
        } catch {
            guard self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration ?? preSpeechGeneration
            ) else {
                streamingTask?.cancel()
                return
            }
            self.statusText = "Talk failed: \(error.localizedDescription)"
            self.logger.error("processTranscript failed: \(error.localizedDescription, privacy: .public)")
            // A throw here (e.g. `waitForAssistantText`) is the run ending WITHOUT a `final` event.
            // Cancel the streaming task FIRST (mirroring every other termination branch) so the
            // orphaned `streamAssistant` can't keep ingesting later deltas and speak the failed turn's
            // content over the next listening turn. THEN finalize incremental speech — the other
            // branches already do this; falling through here used to leave `incrementalSpeechActive`
            // stuck `true` forever → the idle clock never advanced → the bar hung past the 5-min
            // auto-close. The `isSpeechOutputActive` watchdog is the backstop if playback ever hangs.
            streamingTask?.cancel()
            if let turnSpeechGeneration {
                await self.finishIncrementalSpeech(
                    route: turnRoute,
                    expectedGeneration: turnSpeechGeneration
                )
            }
            guard self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration ?? preSpeechGeneration
            ) else { return }
        }

        guard self.transcriptTurnCanMutate(
            owner: owner,
            route: turnRoute,
            expectedGeneration: turnSpeechGeneration ?? preSpeechGeneration
        ) else { return }
        self.transcriptionState = .idle

        if !Task.isCancelled, restartAfter {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard self.transcriptTurnCanMutate(
                owner: owner,
                route: turnRoute,
                expectedGeneration: turnSpeechGeneration ?? preSpeechGeneration
            ) else { return }
            await self.start()
        }
    }

    private static let ambiguousQuotaCopy = "That turn wasn't sent, but its quota check may have counted. End Talk Mode and check Usage; Unmute can't retry it."

    private func applyQuotaDeniedPresentation(message: String) {
        let presentation = VoiceQuotaDeniedPresentation.recoverable(message: message)
        self.isListening = presentation.isListening
        self.isMuted = presentation.isMuted
        self.statusText = presentation.statusText
    }

    /// A denied pre-dispatch turn is still the user's recognized speech. Keep it visible and
    /// available to the silence monitor after an allowed Unmute retry; only `.sent` and transcript
    /// history imply that `chat.send` actually accepted it.
    func preserveDeniedUtterance(
        _ transcript: String,
        route: VoiceRouteAuthority? = nil
    ) {
        let owner = route ?? currentVoiceRoute()
        guard isCurrentVoiceRoute(owner) else { return }
        self.deniedUtteranceRoute = owner
        self.lastTranscript = transcript
        self.lastHeard = Date()
        self.transcriptionState = .transcribing(transcript)
        self.latestUserPreview = transcript
    }

    private func buildPrompt(transcript: String) -> String {
        let interrupted = self.lastInterruptedAtSeconds
        self.lastInterruptedAtSeconds = nil
        return TalkPromptBuilder.build(transcript: transcript, interruptedAtSeconds: interrupted)
    }

    private func sendChat(
        _ message: String,
        sessionKey: String,
        gateway: GatewayNodeSession,
        usageService: UsageService,
        reservation: UsageService.RequestSlotReservation
    ) async throws -> String {
        struct SendResponse: Decodable { let runId: String }

        // A brand-new Talk Mode conversation bypasses RemChatTransport.sendMessage, so it must
        // perform the same structured session binding before its first chat.send. Keep this
        // best-effort like text chat: a transient sessions.patch failure must not discard speech.
        if let binding = TalkSessionBindingPayload.currentDevice(sessionKey: sessionKey),
           let bindingData = try? JSONEncoder().encode(binding),
           let bindingJSON = String(data: bindingData, encoding: .utf8) {
            do {
                _ = try await gateway.request(
                    method: "sessions.patch",
                    paramsJSON: bindingJSON,
                    timeoutSeconds: 10
                )
            } catch {
                // Gateway RPC cancellation is cooperative. Ending Talk Mode must never fall through
                // and transmit the captured speech after a slow/failed patch returns.
                try Task.checkCancellation()
                self.logger.warning(
                    "Talk Mode sessions.patch failed before chat.send: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        try Task.checkCancellation()

        let payload: [String: Any] = [
            "sessionKey": sessionKey,
            // Match text chat: the registered native client/device identity and gateway-owned
            // userTimezone are structured context; the transcript remains exactly user speech.
            "message": message,
            "thinking": "low",
            "timeoutMs": 120_000,
            "idempotencyKey": UUID().uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw NSError(domain: "RemTalkMode", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode chat payload"])
        }
        // The slot is already committed. Cancellation must await the gateway's accepted run ID,
        // retire this exact opaque reservation, then abort that run in wire order.
        try Task.checkCancellation()
        voiceChatDispatchCountForTesting += 1
        let requestTask = Task.detached {
            try await gateway.request(method: "chat.send", paramsJSON: json, timeoutSeconds: 125)
        }
        let res = try await requestTask.value
        let decoded = try JSONDecoder().decode(SendResponse.self, from: res)
        usageService.markReservedRequestAccepted(reservation)
        if Task.isCancelled {
            try await self.abortAcceptedChatRun(
                runID: decoded.runId,
                sessionKey: sessionKey,
                gateway: gateway
            )
            throw CancellationError()
        }
        return decoded.runId
    }

    private func abortAcceptedChatRun(
        runID: String,
        sessionKey: String,
        gateway: GatewayNodeSession
    ) async throws {
        pendingAcceptedVoiceAbort = PendingAcceptedVoiceAbort(
            sessionKey: sessionKey,
            runID: runID,
            gateway: gateway
        )
        do {
            try await Self.abortAcceptedChatRun(
                runID: runID,
                sessionKey: sessionKey,
                requester: { json in
                    _ = try await gateway.request(
                        method: "chat.abort",
                        paramsJSON: json,
                        timeoutSeconds: 10
                    )
                }
            )
            if pendingAcceptedVoiceAbort?.sessionKey == sessionKey,
               pendingAcceptedVoiceAbort?.runID == runID {
                pendingAcceptedVoiceAbort = nil
            }
        } catch {
            throw error
        }
    }

    private func retryPendingAcceptedVoiceAbort() async throws {
        guard let pendingAcceptedVoiceAbort else { return }
        try await abortAcceptedChatRun(
            runID: pendingAcceptedVoiceAbort.runID,
            sessionKey: pendingAcceptedVoiceAbort.sessionKey,
            gateway: pendingAcceptedVoiceAbort.gateway
        )
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
        let abortTask = Task.detached {
            try await requester(json)
        }
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

    private enum ChatCompletionState {
        case final, aborted, error, timeout
    }

    private func waitForChatCompletion(
        runId: String,
        gateway: GatewayNodeSession,
        timeoutSeconds: Int = 120
    ) async -> ChatCompletionState {
        let stream = await gateway.subscribeServerEvents(bufferingNewest: 200)
        return await withTaskGroup(of: ChatCompletionState.self) { group in
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
        sessionKey: String,
        since: Double,
        timeoutSeconds: Int
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            try Task.checkCancellation()
            if let text = try await self.fetchLatestAssistantText(
                gateway: gateway,
                sessionKey: sessionKey,
                since: since
            ) {
                return text
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        try Task.checkCancellation()
        return nil
    }

    private func fetchLatestAssistantText(
        gateway: GatewayNodeSession,
        sessionKey: String,
        since: Double? = nil
    ) async throws -> String? {
        let res = try await gateway.request(
            method: "chat.history",
            paramsJSON: "{\"sessionKey\":\"\(sessionKey)\"}",
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

    private func playAssistant(text: String, explicitGeneration: UInt? = nil) async -> Bool {
        guard isCurrentExplicitPlayback(explicitGeneration) else { return false }
        let parsed = TalkDirectiveParser.parse(text)
        let directive = parsed.directive
        let cleaned = parsed.stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        self.applyDirective(directive)

        self.statusText = "Generating voice..."
        self.responsePhase = .generatingVoice
        self.isSpeaking = true
        self.lastSpokenText = cleaned
        self.spokenTextAccumulator += " " + cleaned

        let chunks = explicitGeneration == nil
            ? [cleaned]
            : ExplicitSpeechPlaybackPlan.chunks(from: cleaned)
        if explicitGeneration != nil {
            explicitPlaybackCompletedChunks = 0
            explicitPlaybackTotalChunks = chunks.count
            logger.info(
                "explicit narration planned chars=\(cleaned.count, privacy: .public) chunks=\(chunks.count, privacy: .public)"
            )
        }
        let playChunk: (String) async -> Bool = { chunk in
            do {
                let request = self.makeGatewayTalkSpeechRequest(text: chunk, directive: directive)
                let audio = try await self.gatewaySpeech.synthesize(request)
                try Task.checkCancellation()
                guard self.isCurrentExplicitPlayback(explicitGeneration) else { return false }
                return await self.playGatewaySpeechAudio(audio)
            } catch {
                guard !Task.isCancelled, self.isCurrentExplicitPlayback(explicitGeneration) else {
                    return false
                }
                self.logger.error("tts failed: \(error.localizedDescription, privacy: .public)")
                if GatewayTalkSpeechFallbackPolicy.shouldUseSystemVoice(for: error) {
                    if self.interruptOnSpeech, !self.isMuted {
                        try? Self.configureAudioSession()
                        try? self.startRecognition()
                    }
                    self.statusText = "Speaking (System)..."
                    self.responsePhase = .speaking
                    do {
                        try await TalkSystemSpeechSynthesizer.shared.speak(
                            text: chunk,
                            language: ElevenLabsTTSClient.validatedLanguage(directive?.language))
                        return true
                    } catch {
                        return false
                    }
                } else if !Task.isCancelled {
                    self.statusText = "Speak failed: \(error.localizedDescription)"
                    return false
                }
                return false
            }
        }
        let outcome = await ExplicitSpeechPlaybackExecutor.run(
            chunks: chunks,
            shouldContinue: {
                !Task.isCancelled && self.isCurrentExplicitPlayback(explicitGeneration)
            },
            play: playChunk,
            onChunkCompleted: { completed, total in
                guard explicitGeneration != nil else { return }
                self.explicitPlaybackCompletedChunks = completed
                self.explicitPlaybackTotalChunks = total
                self.statusText = "Reading \(completed) of \(total)"
                self.logger.info(
                    "explicit narration completed chunk=\(completed, privacy: .public) total=\(total, privacy: .public)"
                )
            }
        )

        guard !Task.isCancelled, isCurrentExplicitPlayback(explicitGeneration) else { return false }
        if explicitGeneration != nil {
            self.logger.info(
                "explicit narration finished outcome=\(String(describing: outcome), privacy: .public) completed=\(self.explicitPlaybackCompletedChunks, privacy: .public) total=\(self.explicitPlaybackTotalChunks, privacy: .public)"
            )
        }
        self.stopRecognition()
        self.isSpeaking = false
        self.responsePhase = .idle
        self.lastSpeakEndTime = Date()
        return outcome == .completed
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
        if self.interruptOnSpeech, !self.isMuted {
            try? Self.configureAudioSession()
            try? self.startRecognition()
        }
        self.statusText = "Speaking..."
        self.responsePhase = .speaking
        self.lastPlaybackWasPCM = false
        self.lastPlaybackWasBufferedMP3 = true
        self.logger.info("buffered MP3 playback starting bytes=\(data.count, privacy: .public)")
        let result = await self.bufferedMP3Player.play(data: data)
        self.logger.info(
            "buffered MP3 playback finished success=\(result.finished, privacy: .public)"
        )
        if !result.finished, let interruptedAt = result.interruptedAt {
            self.lastInterruptedAtSeconds = interruptedAt
        }
        return result.finished
    }

    private func stopSpeaking(storeInterruption: Bool = true) {
        clearFailedExplicitReading()
        explicitPlaybackTask?.cancel()
        explicitPlaybackTask = nil
        explicitPlaybackGeneration &+= 1
        isReadingAloud = false
        explicitPlaybackCompletedChunks = 0
        explicitPlaybackTotalChunks = 0
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

    private func resetIncrementalSpeech() {
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
        self.incrementalSpeechBuffer = IncrementalSpeechBuffer()
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

    private func enqueueIncrementalSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard self.isEnabled else { return } // Don't enqueue after session ended
        self.incrementalSpeechQueue.append(trimmed)
        self.incrementalSpeechUsed = true
        self.lastSpeechProgressTime = Date() // new audio queued → real progress
        if self.incrementalSpeechTask == nil {
            self.startIncrementalSpeechTask()
        }
    }

    private func startIncrementalSpeechTask() {
        if self.interruptOnSpeech {
            try? Self.configureAudioSession()
            try? self.startRecognition()
        }

        let owner = UUID()
        let route = currentVoiceRoute()
        let generation = incrementalSpeechGeneration
        incrementalSpeechTaskOwner = owner
        self.incrementalSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if Self.incrementalTaskCanMutate(
                    capturedOwner: owner,
                    currentOwner: self.incrementalSpeechTaskOwner,
                    capturedRoute: route,
                    currentRoute: self.currentVoiceRoute(),
                    capturedGeneration: generation,
                    currentGeneration: self.incrementalSpeechGeneration
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
            while !Task.isCancelled && self.isEnabled && Self.incrementalTaskCanMutate(
                capturedOwner: owner,
                currentOwner: self.incrementalSpeechTaskOwner,
                capturedRoute: route,
                currentRoute: self.currentVoiceRoute(),
                capturedGeneration: generation,
                currentGeneration: self.incrementalSpeechGeneration
            ) {
                guard !self.incrementalSpeechQueue.isEmpty else { break }
                let segment = self.incrementalSpeechQueue.removeFirst()
                self.statusText = "Speaking..."
                self.responsePhase = .speaking
                self.isSpeaking = true
                self.lastSpokenText = segment
                self.spokenTextAccumulator += " " + segment
                await self.updateIncrementalContextIfNeeded()
                guard Self.incrementalTaskCanMutate(
                    capturedOwner: owner,
                    currentOwner: self.incrementalSpeechTaskOwner,
                    capturedRoute: route,
                    currentRoute: self.currentVoiceRoute(),
                    capturedGeneration: generation,
                    currentGeneration: self.incrementalSpeechGeneration
                ) else { return }
                let context = self.incrementalSpeechContext
                let prefetchedAudio = await self.consumeIncrementalPrefetchedAudioIfAvailable(
                    for: segment,
                    context: context)
                guard Self.incrementalTaskCanMutate(
                    capturedOwner: owner,
                    currentOwner: self.incrementalSpeechTaskOwner,
                    capturedRoute: route,
                    currentRoute: self.currentVoiceRoute(),
                    capturedGeneration: generation,
                    currentGeneration: self.incrementalSpeechGeneration
                ) else { return }
                if let context {
                    self.startIncrementalPrefetchMonitor(context: context)
                }
                await self.speakIncrementalSegment(
                    segment,
                    context: context,
                    prefetchedAudio: prefetchedAudio,
                    owner: owner,
                    route: route,
                    generation: generation)
                guard Self.incrementalTaskCanMutate(
                    capturedOwner: owner,
                    currentOwner: self.incrementalSpeechTaskOwner,
                    capturedRoute: route,
                    currentRoute: self.currentVoiceRoute(),
                    capturedGeneration: generation,
                    currentGeneration: self.incrementalSpeechGeneration
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

    /// The next sentence can arrive while the current sentence is playing. Mirror OpenClaw's
    /// upstream prefetch loop so ElevenLabs synthesis overlaps playback instead of creating an
    /// audible network wait at every sentence boundary.
    private func startIncrementalPrefetchMonitor(context: IncrementalSpeechContext) {
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
        context: IncrementalSpeechContext
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
        context: IncrementalSpeechContext
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
        self.incrementalSpeechPrefetch = IncrementalSpeechPrefetchState(
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
        context: IncrementalSpeechContext?
    ) async -> IncrementalPrefetchedAudio? {
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
            let audio = IncrementalPrefetchedAudio(
                chunks: chunks,
                outputFormat: prefetch.outputFormat)
            self.incrementalSpeechPrefetch = nil
            return audio
        }
        await prefetch.task.value
        guard let completed = self.incrementalSpeechPrefetch,
              completed.context == context,
              completed.segment == segment,
              let chunks = completed.chunks,
              !chunks.isEmpty
        else {
            return nil
        }
        let audio = IncrementalPrefetchedAudio(
            chunks: chunks,
            outputFormat: completed.outputFormat)
        self.incrementalSpeechPrefetch = nil
        return audio
    }

    private func finishIncrementalSpeech(
        authoritativeText: String? = nil,
        route: VoiceRouteAuthority? = nil,
        expectedGeneration: UInt64? = nil
    ) async {
        if let route, !isCurrentVoiceRoute(route) { return }
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
        guard generation == incrementalSpeechGeneration else { return }
        if let expectedGeneration, expectedGeneration != incrementalSpeechGeneration { return }
        if let route, !isCurrentVoiceRoute(route) { return }
        self.incrementalSpeechActive = false
    }

    private func handleIncrementalAssistantFinal(
        text: String,
        route: VoiceRouteAuthority,
        owner: UUID?,
        expectedGeneration: UInt64?
    ) async {
        guard transcriptTurnCanMutate(
            owner: owner,
            route: route,
            expectedGeneration: expectedGeneration
        ) else { return }
        let parsed = TalkDirectiveParser.parse(text)
        self.applyDirective(parsed.directive)
        if let lang = parsed.directive?.language {
            self.incrementalSpeechLanguage = ElevenLabsTTSClient.validatedLanguage(lang)
        }
        await self.updateIncrementalContextIfNeeded()
        guard transcriptTurnCanMutate(
            owner: owner,
            route: route,
            expectedGeneration: expectedGeneration
        ) else { return }

        if self.incrementalSpeechUsed {
            // Streaming already fed text to the buffer. Finish by reconciling against the
            // complete (directive-stripped) reply so a final sentence streaming missed still
            // gets spoken (#1092). Passing the authoritative text — rather than blindly
            // re-ingesting raw history — keeps prefix alignment with the streamed text, so
            // already-spoken content is not replayed in the common case.
            await self.finishIncrementalSpeech(
                authoritativeText: parsed.stripped,
                route: route,
                expectedGeneration: expectedGeneration
            )
        } else {
            // No streaming events received — ingest the full text and play it
            let segments = self.incrementalSpeechBuffer.ingest(text: text, isFinal: true)
            for segment in segments {
                self.enqueueIncrementalSpeech(segment)
            }
            await self.finishIncrementalSpeech(
                route: route,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func streamAssistant(
        runId: String? = nil,
        gateway: GatewayNodeSession,
        route: VoiceRouteAuthority? = nil,
        expectedGeneration: UInt64? = nil,
        transcriptOwner: UUID? = nil,
        composerOwner: UUID? = nil
    ) async {
        let stream = await gateway.subscribeServerEvents(bufferingNewest: 200)
        guard streamAssistantCanMutate(
            route: route,
            expectedGeneration: expectedGeneration,
            transcriptOwner: transcriptOwner,
            composerOwner: composerOwner
        ) else { return }
        for await evt in stream {
            if Task.isCancelled { return }
            guard streamAssistantCanMutate(
                route: route,
                expectedGeneration: expectedGeneration,
                transcriptOwner: transcriptOwner,
                composerOwner: composerOwner
            ) else { return }
            guard evt.event == "agent", let payload = evt.payload else { continue }
            guard let agentEvent = try? GatewayPayloadDecoding.decode(
                payload, as: OpenClawAgentEventPayload.self) else { continue }
            if let runId { guard agentEvent.runId == runId else { continue } }
            guard agentEvent.stream == "assistant" else { continue }
            guard let text = agentEvent.data["text"]?.value as? String else { continue }
            // Stamp progress on EVERY assistant delta, not only when a delta crosses a sentence
            // boundary and enqueues audio. A still-generating reply streams many deltas before its
            // first boundary (slow first sentence / long reasoning / slow synthesis); without this, no
            // audio is queued for >staleWindow, `isSpeechOutputActive` would read the actively-
            // streaming turn as stuck, and `checkInactivity` could auto-close mid-response — worst on
            // the composer path, which never sets `transcriptionState` so the turn-in-progress guard
            // doesn't protect it. `isSpeaking` still short-circuits once audio actually plays.
            self.lastSpeechProgressTime = Date()
            let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                self.latestAssistantPreview = preview
            }
            let segments = self.incrementalSpeechBuffer.ingest(text: text, isFinal: false)
            if let lang = self.incrementalSpeechBuffer.directive?.language {
                self.incrementalSpeechLanguage = ElevenLabsTTSClient.validatedLanguage(lang)
            }
            await self.updateIncrementalContextIfNeeded()
            guard streamAssistantCanMutate(
                route: route,
                expectedGeneration: expectedGeneration,
                transcriptOwner: transcriptOwner,
                composerOwner: composerOwner
            ) else { return }
            for segment in segments {
                self.enqueueIncrementalSpeech(segment)
            }
        }
    }

    private func streamAssistantCanMutate(
        route: VoiceRouteAuthority?,
        expectedGeneration: UInt64?,
        transcriptOwner: UUID?,
        composerOwner: UUID?
    ) -> Bool {
        Self.streamAssistantCanMutate(
            route: route,
            currentRoute: currentVoiceRoute(),
            expectedGeneration: expectedGeneration,
            currentGeneration: incrementalSpeechGeneration,
            transcriptOwner: transcriptOwner,
            currentTranscriptOwner: activeTranscriptTaskOwner,
            composerOwner: composerOwner,
            currentComposerOwner: composerStreamingTaskOwner
        )
    }

    static func streamAssistantCanMutate(
        route: VoiceRouteAuthority?,
        currentRoute: VoiceRouteAuthority,
        expectedGeneration: UInt64?,
        currentGeneration: UInt64,
        transcriptOwner: UUID?,
        currentTranscriptOwner: UUID?,
        composerOwner: UUID?,
        currentComposerOwner: UUID?
    ) -> Bool {
        if let route, route != currentRoute { return false }
        if let expectedGeneration, expectedGeneration != currentGeneration { return false }
        if let transcriptOwner, transcriptOwner != currentTranscriptOwner { return false }
        if let composerOwner, composerOwner != currentComposerOwner { return false }
        return true
    }

    // MARK: - Composer TTS (speak response for text-composed messages)

    private var composerStreamingTask: Task<Void, Never>?
    private var composerStreamingTaskOwner: UUID?
    private var explicitPlaybackTask: Task<Void, Never>?
    private var explicitPlaybackGeneration: UInt = 0
    private var failedExplicitReading: ExplicitSpeechRetryToken?

    private func clearFailedExplicitReading() {
        failedExplicitReading = nil
        canRetryReadingAloud = false
    }

    func invalidateFailedReadingAloud() {
        clearFailedExplicitReading()
    }

    /// Cancels an in-flight exact brief generation when its external account/gateway/artifact
    /// context changes. Manual Talk Mode remains enabled but safely muted and non-listening.
    func invalidateExplicitBriefPlayback() {
        clearFailedExplicitReading()
        guard isReadingAloud else { return }
        isListening = false
        isMuted = true
        stopSpeaking(storeInterruption: false)
        stopRecognition()
        responsePhase = .idle
        statusText = "Brief changed. Read the latest brief to continue."
    }

    private func isCurrentExplicitPlayback(_ generation: UInt?) -> Bool {
        guard let generation else { return true }
        return generation == explicitPlaybackGeneration
    }

    private func cancelExplicitPlaybackTask(generation: UInt) {
        guard generation == explicitPlaybackGeneration else { return }
        isListening = false
        isMuted = true
        stopSpeaking(storeInterruption: false)
        stopRecognition()
        responsePhase = .idle
        statusText = "Brief reading stopped."
    }

    /// Read user-requested app prose (such as the Daily Brief) without starting a
    /// listening session. This deliberately reuses the configured Talk provider
    /// and its system-voice fallback instead of creating a second TTS path.
    func readAloud(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        clearFailedExplicitReading()
        stopReadingAloud()
        let generation = explicitPlaybackGeneration
        isReadingAloud = true
        explicitPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.playAssistant(text: trimmed, explicitGeneration: generation)
            if !Task.isCancelled, self.isCurrentExplicitPlayback(generation) {
                self.explicitPlaybackTask = nil
                self.isReadingAloud = false
            }
        }
    }

    /// Starts a voice conversation by reading already-authored prose, then resumes listening so
    /// the user can answer in the same chat. Reading begins muted: starting recognition first adds
    /// latency and lets the user or the speaker interrupt narration before it has even settled.
    /// The visible mic control may still explicitly unmute for intentional barge-in.
    func startByReadingAloud(
        _ text: String,
        retryContext: ExplicitSpeechRetryContext? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clearFailedExplicitReading()
        guard !trimmed.isEmpty else {
            setEnabled(true)
            return false
        }

        if !isEnabled {
            isEnabled = true
        }
        stopSpeaking(storeInterruption: false)
        let generation = explicitPlaybackGeneration
        isMuted = true
        isReadingAloud = true
        isListening = false
        statusText = "Microphone muted"
        stopRecognition()
        // Resolve the saved voice without paying the microphone permission/recognition startup
        // cost before speech. Listening starts only after narration completes or is stopped.
        await reloadConfig()
        guard isEnabled, isCurrentExplicitPlayback(generation) else { return false }
        let completed = await withTaskCancellationHandler {
            await playAssistant(text: trimmed, explicitGeneration: generation)
        } onCancel: {
            // AVAudioPlayer is continuation-backed and does not observe Task cancellation itself.
            // Hop to the main actor and stop it explicitly so teardown or a failed replacement
            // cannot leave stale prose audible or strand isSpeaking/isReadingAloud.
            Task { @MainActor [weak self] in
                self?.cancelExplicitPlaybackTask(generation: generation)
            }
        }
        guard !Task.isCancelled,
              isCurrentExplicitPlayback(generation)
        else { return false }
        explicitPlaybackTask = nil
        isReadingAloud = false

        if ExplicitSpeechPlaybackCompletionPolicy.shouldResumeListening(
            after: completed ? .completed : .failed,
            voiceSessionEnabled: isEnabled
        ) {
            isMuted = false
            await start(reloadConfiguration: false)
        } else if isEnabled {
            // Failed/partial narration is not a listening session. Keep the microphone safely
            // muted and leave a visible recoverable status instead of pretending the user can
            // reply or granting the caller a completion receipt.
            isMuted = true
            isListening = false
            responsePhase = .idle
            statusText = "Couldn't finish reading. Try again."
            if let retryContext, retryContext.sessionKey == sessionKey {
                failedExplicitReading = ExplicitSpeechRetryToken(
                    text: trimmed,
                    context: retryContext,
                    generation: generation
                )
                canRetryReadingAloud = true
            }
        }
        return ExplicitSpeechPlaybackCompletionPolicy.shouldRecordReadReceipt(
            after: completed ? .completed : .failed
        )
    }

    /// Retries only the failed authored prose bound to this exact voice session/generation.
    /// Session switches, teardown, manual playback, intentional Stop, or another generation clear
    /// the retained text before this can be called, preventing stale account/chat narration.
    func retryFailedReadingAloud(expectedContext: ExplicitSpeechRetryContext?) async -> Bool {
        guard let failed = failedExplicitReading,
              canRetryReadingAloud,
              ExplicitSpeechRetryPolicy.canRetry(
                  failed,
                  expectedContext: expectedContext,
                  currentGeneration: explicitPlaybackGeneration,
                  voiceSessionEnabled: isEnabled
              )
        else {
            clearFailedExplicitReading()
            return false
        }
        let text = failed.text
        let context = failed.context
        clearFailedExplicitReading()
        return await startByReadingAloud(text, retryContext: context)
    }

    func stopReadingAloud(continueListening: Bool = false) {
        clearFailedExplicitReading()
        isListening = false
        stopSpeaking(storeInterruption: false)
        stopRecognition()
        guard continueListening,
              ExplicitSpeechPlaybackCompletionPolicy.shouldResumeListening(
                  after: .stoppedByUser,
                  voiceSessionEnabled: isEnabled
              )
        else { return }
        isMuted = false
        Task { @MainActor [weak self] in
            guard let self, self.isEnabled else { return }
            await self.start(reloadConfiguration: false)
        }
    }

    /// Call when a text message is sent via the composer while voice mode is
    /// active. Subscribes to the gateway event stream and speaks the next
    /// assistant response via TTS.
    func speakNextResponse() {
        guard self.isEnabled, let gateway else { return }
        let takeover = beginComposerSpeechTakeover()
        composerStreamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.streamAssistant(
                gateway: gateway,
                route: takeover.route,
                expectedGeneration: takeover.generation,
                composerOwner: takeover.owner
            )
            guard Self.composerTaskCanMutate(
                capturedOwner: takeover.owner,
                currentOwner: self.composerStreamingTaskOwner,
                capturedRoute: takeover.route,
                currentRoute: self.currentVoiceRoute(),
                capturedIncrementalGeneration: takeover.generation,
                currentIncrementalGeneration: self.incrementalSpeechGeneration
            ) else { return }
            await self.finishIncrementalSpeech(
                route: takeover.route,
                expectedGeneration: takeover.generation
            )
            guard Self.composerTaskCanMutate(
                capturedOwner: takeover.owner,
                currentOwner: self.composerStreamingTaskOwner,
                capturedRoute: takeover.route,
                currentRoute: self.currentVoiceRoute(),
                capturedIncrementalGeneration: takeover.generation,
                currentIncrementalGeneration: self.incrementalSpeechGeneration
            ) else { return }
            self.composerStreamingTaskOwner = nil
            self.composerStreamingTask = nil
        }
    }

    private func beginComposerSpeechTakeover() -> (
        owner: UUID,
        route: VoiceRouteAuthority,
        generation: UInt64
    ) {
        clearFailedExplicitReading()
        composerStreamingTaskOwner = nil
        composerStreamingTask?.cancel()
        self.resetIncrementalSpeech()
        let owner = UUID()
        let route = currentVoiceRoute()
        let generation = incrementalSpeechGeneration
        composerStreamingTaskOwner = owner
        return (owner, route, generation)
    }

    func beginComposerSpeechTakeoverForTesting() {
        _ = beginComposerSpeechTakeover()
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
                self.incrementalSpeechContext = IncrementalSpeechContext(
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

    private func buildIncrementalSpeechContext(directive: TalkDirective?) -> IncrementalSpeechContext {
        let voiceId = directive?.voiceId ?? self.currentVoiceId ?? self.defaultVoiceId
        let modelId = directive?.modelId ?? self.currentModelId ?? self.defaultModelId
        let outputFormatStr = (directive?.outputFormat ?? self.defaultOutputFormat)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = self.incrementalSpeechLanguage
        return IncrementalSpeechContext(
            voiceId: voiceId,
            modelId: modelId,
            outputFormat: outputFormatStr,
            language: language,
            directive: directive,
            canUseGatewaySynthesis: self.gateway != nil && self.gatewayConnected)
    }

    private func makeIncrementalTTSRequest(
        text: String,
        context: IncrementalSpeechContext,
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
        context preferredContext: IncrementalSpeechContext? = nil,
        prefetchedAudio: IncrementalPrefetchedAudio? = nil,
        owner: UUID,
        route: VoiceRouteAuthority,
        generation: UInt64
    ) async {
        guard Self.incrementalTaskCanMutate(
            capturedOwner: owner,
            currentOwner: incrementalSpeechTaskOwner,
            capturedRoute: route,
            currentRoute: currentVoiceRoute(),
            capturedGeneration: generation,
            currentGeneration: incrementalSpeechGeneration
        ) else { return }
        let context: IncrementalSpeechContext
        if let preferredContext {
            context = preferredContext
        } else {
            await self.updateIncrementalContextIfNeeded()
            guard Self.incrementalTaskCanMutate(
                capturedOwner: owner,
                currentOwner: incrementalSpeechTaskOwner,
                capturedRoute: route,
                currentRoute: currentVoiceRoute(),
                capturedGeneration: generation,
                currentGeneration: incrementalSpeechGeneration
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
        let audio: IncrementalPrefetchedAudio
        if let prefetchedAudio, !prefetchedAudio.chunks.isEmpty {
            audio = prefetchedAudio
        } else {
            do {
                let response = try await self.gatewaySpeech.synthesize(request)
                guard Self.incrementalTaskCanMutate(
                    capturedOwner: owner,
                    currentOwner: incrementalSpeechTaskOwner,
                    capturedRoute: route,
                    currentRoute: currentVoiceRoute(),
                    capturedGeneration: generation,
                    currentGeneration: incrementalSpeechGeneration
                ) else { return }
                guard let data = response.data else { return }
                audio = IncrementalPrefetchedAudio(
                    chunks: [data],
                    outputFormat: response.outputFormat)
            } catch {
                guard Self.incrementalTaskCanMutate(
                    capturedOwner: owner,
                    currentOwner: incrementalSpeechTaskOwner,
                    capturedRoute: route,
                    currentRoute: currentVoiceRoute(),
                    capturedGeneration: generation,
                    currentGeneration: incrementalSpeechGeneration
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
        let data = audio.chunks.reduce(into: Data()) { combined, chunk in
            combined.append(chunk)
        }
        guard !data.isEmpty else { return }
        self.lastPlaybackWasPCM = false
        self.lastPlaybackWasBufferedMP3 = true
        let result = await self.bufferedMP3Player.play(data: data)
        guard Self.incrementalTaskCanMutate(
            capturedOwner: owner,
            currentOwner: incrementalSpeechTaskOwner,
            capturedRoute: route,
            currentRoute: currentVoiceRoute(),
            capturedGeneration: generation,
            currentGeneration: incrementalSpeechGeneration
        ) else { return }
        if !result.finished, let interruptedAt = result.interruptedAt {
            self.lastInterruptedAtSeconds = interruptedAt
        }
    }

    // MARK: - Config loading

    /// Load the gateway's effective, normalized Talk configuration.
    ///
    /// Voice Settings writes `talk.providers.<provider>`. `talk.config` resolves
    /// that canonical structure for the active provider and redacts secrets, so
    /// the runtime and settings screen share one source of truth without asking
    /// the gateway to return provider credentials.
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
            self.logger.info("[TTS] talk.config keys: \(talk?.keys.sorted().joined(separator: ", ") ?? "nil")")

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

    nonisolated static func requestMicrophonePermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: break
        @unknown default: return false
        }
        return await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
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

// MARK: - VoiceSpeechActivity

/// Pure decision for "is TTS output active?" — extracted from `RemTalkModeManager.isSpeechOutputActive`
/// so the stuck-flag watchdog can be unit-tested without the audio engine / gateway.
///
/// The bug this guards: the incremental-speech flags (`incrementalSpeechActive` / task / queue) are
/// cleared only when a chat run reports `final` (via `finishIncrementalSpeech`). If `final` never
/// fires — a stream error, an abnormally-ended turn, the #1092 race — the flags stay set forever, so
/// `isSpeechOutputActive` stayed `true` on every 2s inactivity poll, `lastAudioActivity` was re-armed
/// each time, `idle` never grew, and the 300s auto-close was NEVER reached (the voice bar hung past
/// 5 min). This helper makes pending-but-silent speech time out so the idle clock can advance, while
/// `isSpeaking` short-circuits `true` the instant real audio plays so active speech is never clipped.
enum VoiceSpeechActivity {
    /// - Parameters:
    ///   - isSpeaking: real TTS audio is playing right now. Short-circuits `true` — never clipped.
    ///   - hasPendingSpeech: any incremental-speech flag/task/queue is set (a turn is "in flight").
    ///   - lastProgress: last moment speech genuinely progressed (turn start / segment queued /
    ///     playback ended). `nil` ⇒ no real pending speech to keep alive.
    ///   - now: current time (injected for tests).
    ///   - staleWindow: how long pending-but-silent may persist before it's treated as stuck.
    static func isActive(
        isSpeaking: Bool,
        hasPendingSpeech: Bool,
        lastProgress: Date?,
        now: Date,
        staleWindow: TimeInterval
    ) -> Bool {
        // Genuinely playing audio → always active. This is the guarantee that a real, still-playing
        // multi-sentence reply keeps the session alive and is never truncated.
        if isSpeaking { return true }
        // Nothing playing and no pending-speech flags → definitively inactive.
        guard hasPendingSpeech else { return false }
        // Pending flags set but nothing playing. Normal for a brief moment (between streamed segments,
        // or just after a turn starts). Only keep it "active" while progress is recent; once it goes
        // stale the flags are stuck and must not pin the idle clock open.
        guard let lastProgress else { return false }
        return now.timeIntervalSince(lastProgress) < staleWindow
    }
}

// MARK: - IncrementalSpeechBuffer

/// Buffers streaming assistant text and extracts speakable segments at sentence boundaries.
/// Skips code blocks (```) and parses TalkDirective from the first line if present.
///
/// Internal (not `private`) so `IncrementalSpeechBufferTests` can exercise the pure
/// segment/flush logic that guards against spoken-reply truncation (#1092).
struct IncrementalSpeechBuffer {
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

// MARK: - IncrementalSpeechContext

private struct IncrementalSpeechContext: Equatable {
    let voiceId: String?
    let modelId: String?
    let outputFormat: String?
    let language: String?
    let directive: TalkDirective?
    let canUseGatewaySynthesis: Bool
}

private struct IncrementalSpeechPrefetchState {
    let id: UUID
    let segment: String
    let context: IncrementalSpeechContext
    var outputFormat: String?
    var chunks: [Data]?
    let task: Task<Void, Never>
}

private struct IncrementalPrefetchedAudio {
    let chunks: [Data]
    let outputFormat: String?
}
