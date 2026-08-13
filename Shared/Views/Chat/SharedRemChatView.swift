import Foundation
import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum VoiceResponsePhase: Equatable {
    case idle
    case thinking
    case generatingVoice
    case speaking

    var isWorking: Bool {
        self == .thinking || self == .generatingVoice
    }
}

/// Pure shared policy for composer authorization. Session-management commands are control-plane
/// operations: the chat view model executes them before model repair, health, and quota, so the UI
/// must not strand them behind provider-auth evidence or request quota either.
enum ChatComposerSendPolicy {
    private static let sessionCommands: Set<String> = ["/new", "/reset", "/clear", "/compact"]

    static func isSessionCommand(_ input: String) -> Bool {
        sessionCommands.contains(input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func canSend(
        input: String,
        hasAuthoritativeProviderEvidence: Bool,
        requiresProviderEvidence: Bool,
        isPreparingSend: Bool,
        viewModelCanSend: Bool,
        browserCapabilityAttached: Bool
    ) -> Bool {
        guard !isPreparingSend else { return false }
        if isSessionCommand(input) { return viewModelCanSend }
        guard !requiresProviderEvidence || hasAuthoritativeProviderEvidence else { return false }
        return viewModelCanSend || browserCapabilityAttached
    }

    static func hasRequiredQuota(input: String, hasQuota: Bool) -> Bool {
        isSessionCommand(input) || hasQuota
    }

    /// The menu always contains the safe Automatic escape hatch. Unknown provider evidence hides
    /// explicit provider groups, but must not disable the whole menu and strand a persisted
    /// explicit selection on an upstream/local gateway that lacks Rem's optional auth probe.
    static func canOpenModelPicker(isPreparingSend: Bool, isSending: Bool) -> Bool {
        !isPreparingSend && !isSending
    }
}

/// `OpenClawChatMessage` adapter over `ChatTimeSeparatorPolicy`.
///
/// OpenClaw already persists a timestamp on each chat message, so the grouping is presentation
/// derived from canonical history rather than stored in a second client-side timeline. The rules
/// themselves live in `ChatTimeSeparatorPolicy` (pure, Foundation-only, directly testable); this
/// only unwraps message timestamps.
///
/// Applies to every transcript, not just the durable daily thread: a gap is as disorienting in a
/// task chat resumed the next morning as it is between two briefs.
enum ChatMessageSeparatorPolicy {
    static func isToday(
        _ message: OpenClawChatMessage,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let messageDate = ChatTimeSeparatorPolicy.date(from: message.timestamp) else {
            return false
        }
        return ChatTimeSeparatorPolicy.isSameDay(messageDate, as: now, calendar: calendar)
    }

    static func label(
        for message: OpenClawChatMessage,
        previous: OpenClawChatMessage?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let messageDate = ChatTimeSeparatorPolicy.date(from: message.timestamp) else {
            return nil
        }
        return ChatTimeSeparatorPolicy.label(
            at: messageDate,
            previous: previous.flatMap { ChatTimeSeparatorPolicy.date(from: $0.timestamp) },
            now: now,
            calendar: calendar,
            locale: locale
        )
    }
}

struct VoiceAssistantTailPolicy: Equatable {
    let showsStreamingBubble: Bool
    let showsWorkingIndicator: Bool
    let rendersStreamingBeforeVoicePlaceholder: Bool

    static func resolve(
        sentTurnIsPending: Bool,
        isVoiceModeActive: Bool,
        phase: VoiceResponsePhase,
        hasStreamingAssistantText: Bool,
        hasPendingRun: Bool
    ) -> Self {
        let showsWorking = isVoiceModeActive && phase.isWorking && sentTurnIsPending
        let showsGenericPending = hasPendingRun
            && !hasStreamingAssistantText
            && !(isVoiceModeActive && sentTurnIsPending)
        return Self(
            showsStreamingBubble: hasStreamingAssistantText,
            showsWorkingIndicator: showsWorking || showsGenericPending,
            rendersStreamingBeforeVoicePlaceholder: isVoiceModeActive
                && hasStreamingAssistantText
                && !sentTurnIsPending
        )
    }
}

/// Keeps the last streamed assistant prose visible while the gateway's terminal event and
/// authoritative history refresh cross. Tool/result rows can persist before the final assistant
/// message, so a generic message-count change is not authority to remove the handoff bubble.
enum StreamingAssistantHandoffPolicy {
    struct UserTurnAnchor: Equatable {
        let fingerprint: String
    }

    struct MessageSnapshot: Equatable {
        let role: String
        let userFingerprint: String?
        let hasFinalAssistantContent: Bool
    }

    static func latestUserAnchor(in messages: [MessageSnapshot]) -> UserTurnAnchor? {
        messages.last(where: { $0.role == "user" && $0.userFingerprint != nil })
            .flatMap(\.userFingerprint)
            .map(UserTurnAnchor.init(fingerprint:))
    }

    static func shouldClearCachedText(
        originatingUserAnchor: UserTurnAnchor?,
        messages: [MessageSnapshot]
    ) -> Bool {
        guard let originatingUserAnchor else { return true }
        guard let originIndex = messages.lastIndex(where: { $0.role == "user" }) else {
            // An authoritative refresh removed or ambiguously truncated the turn anchor. Retaining
            // the cache would risk presenting old prose beneath an unrelated turn.
            return true
        }
        guard messages[originIndex].userFingerprint == originatingUserAnchor.fingerprint else {
            return true
        }

        let turnMessages = messages.suffix(from: messages.index(after: originIndex))
        guard let terminalMessage = turnMessages.last else { return false }
        return (terminalMessage.role == "assistant" || terminalMessage.role == "model")
            && terminalMessage.hasFinalAssistantContent
    }

    /// The legacy Today transport adds brief context only to the canonical wire row. Pinned
    /// OpenClaw may therefore retain that row beside the plain optimistic user row even though both
    /// display as the same prompt. Match only this sentinel-owned pair; two genuinely repeated
    /// plain prompts remain separate turns.
    static func isHiddenBriefEchoPair(_ lhsRawText: String, _ rhsRawText: String) -> Bool {
        let lhsHasContext = lhsRawText.contains(BriefContext.startSentinel)
        let rhsHasContext = rhsRawText.contains(BriefContext.startSentinel)
        guard lhsHasContext != rhsHasContext else { return false }

        let lhsVisible = MessageCleaner.cleanUserMessageText(lhsRawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsVisible = MessageCleaner.cleanUserMessageText(rhsRawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !lhsVisible.isEmpty && lhsVisible == rhsVisible
    }

    /// `session.message` appends cross-device turns before any capped authoritative refresh. Compare
    /// the previous transcript's longest suffix with the current transcript's prefix so a 200-row
    /// history window may drop old rows without hiding the genuinely appended tail. The caller
    /// supplies the display-canonical history (attachment echoes collapsed and hidden brief context
    /// removed), so optimistic replacement cannot masquerade as a new user turn.
    static func appendedUserTurn(
        from previous: [MessageSnapshot],
        to current: [MessageSnapshot]
    ) -> Bool {
        guard !previous.isEmpty, !current.isEmpty else { return false }

        let maximumOverlap = min(previous.count, current.count)
        let overlap = stride(from: maximumOverlap, through: 1, by: -1).first { count in
            previous.suffix(count).elementsEqual(current.prefix(count))
        } ?? 0
        guard overlap > 0 else { return false }

        return current.dropFirst(overlap).contains(where: { $0.role == "user" })
    }
}

/// Cross-platform Rem custom chat view used by iOS and macOS.
///
/// Replaces the default `OpenClawChatView` from `OpenClawChatUI` with Rem's
/// custom surface: speech bubbles, thinking blocks, inline tool result cards,
/// Grok-style composer. Voice and quota hooks are optional so Mac (which
/// currently has neither) can drop them in as `nil`.
///
/// Source of truth: this view. The iOS `RemChatView` wrapper and Mac
/// `MacChatWindow` both delegate to this type. See
/// `RemClaw/Sources/Chat/RemChatView.swift` for iOS-specific glue (voice,
/// quota) and `RemClawMac/Sources/UI/MacChatWindow.swift` for Mac gating.
struct SharedRemChatView: View {
    struct FirstChatPrompt: Identifiable, Equatable {
        let id: String
        let text: String
        /// The WHY / source attribution for a personalized starter ("Ada asked… · Gmail · 2h ago").
        /// Nil for the generic fallback set. Shown so a personalized starter can't be mistaken for
        /// something Rem invented (doc 38 §6 — same principle as the Agenda's SuggestedTaskRow).
        var subtitle: String? = nil
    }

    /// Generic fallback starters, shown when there are no personalized suggestions to draw from
    /// (new user, no connected sources, or the suggestion deriver hasn't run yet).
    static let firstChatPrompts: [FirstChatPrompt] = [
        FirstChatPrompt(id: "plan-day", text: "Help me plan the rest of my day."),
        FirstChatPrompt(id: "turn-into-tasks", text: "Turn this into tasks: follow up with Alex, schedule my dentist appointment, and prep for Friday."),
        FirstChatPrompt(id: "reminder", text: "Remind me to send the investor update tomorrow morning.")
    ]

    /// Turn suggestion signals into first-person chat starters. This is WS2's third "surface":
    /// the same deriver that feeds the Agenda cards and the brief (doc 38) also seeds the empty
    /// chat, so the starters reflect what's actually on the user's plate rather than a fixed script.
    ///
    /// Phrasing is deliberately conservative — we only surface `createTask` suggestions, whose
    /// backend-authored `title` already reads as a clean request to Rem ("Reply to Ada", "Prep for
    /// Standup"). Reschedule-type suggestions are contextless as a standalone utterance
    /// ("Reschedule to today" — reschedule what?) so we skip them here rather than invent phrasing.
    /// If nothing qualifies, the caller falls back to `firstChatPrompts`.
    static func starters(from suggestions: [TaskSuggestion]) -> [FirstChatPrompt] {
        suggestions
            .filter { $0.action.kind == "createTask" }
            .prefix(3)
            .map { FirstChatPrompt(id: $0.key, text: $0.title, subtitle: $0.subtitle) }
    }

    @Bindable var viewModel: OpenClawChatViewModel

    /// Starter prompts shown on an empty conversation. The platform wrapper injects personalized
    /// starters (via `SharedRemChatView.starters(from:)`); when it passes the generic fallback (or
    /// nothing), the user still gets useful prompts. Persistent by design — shown on every empty
    /// chat, not just the first one ever (WS2: "personalized + persistent starters").
    var starterPrompts: [FirstChatPrompt] = SharedRemChatView.firstChatPrompts
    /// Current task proposals from the same source as Agenda. These render only after the exact
    /// canonical Daily Brief message in the durable orchestrator conversation; they are never
    /// injected into gateway history or shown in unrelated chats.
    var orchestratorSuggestionSnapshot: OrchestratorSuggestionSnapshot? = nil
    var onAcceptSuggestion: ((TaskSuggestion) -> Void)?
    var onDismissSuggestion: ((TaskSuggestion) -> Void)?
    /// Agenda's current prose, shown as a temporary assistant bridge only while the durable Today
    /// transcript has no assistant content from today. It disappears as soon as history lands.
    var briefPreviewMarkdown: String? = nil
    /// Exact durable artifact resolved after navigation. A Binding keeps an existing navigation
    /// destination subscribed instead of relying on the destination closure to be rebuilt.
    var resolvedBriefMarkdown: Binding<String?> = .constant(nil)
    /// When opened from "Read latest brief", restore at the exact authored brief delivery instead
    /// of the usual bottom position. Subsequent turns resume normal bottom-following behavior.
    var scrollToLatestBrief: Bool = false

    /// The live view of Rem's cloud browser (doc 37). Optional: a platform that hasn't wired one
    /// up simply doesn't show the card. Injected rather than owned so the same session backs the
    /// card here and the expanded sheet at the app root.
    @Environment(BrowserLiveSession.self) private var browserSession: BrowserLiveSession?
    /// Tracks the previous in-flight-run state so `reconcileBrowserCardState` can detect a run
    /// STARTING (rising edge) and lift a prior user End for a fresh re-browse.
    /// Returns true when the platform's current quota evidence allows sending.
    /// Unknown evidence may still reach `consumeSendSlot` for an authoritative backend decision.
    var hasQuota: () -> Bool = { true }

    /// Called before a message is sent. Return `true` to proceed, `false` to
    /// cancel (e.g. quota exceeded). Platform wrappers inject their authenticated quota authority.
    var consumeSendSlot: (@MainActor () async -> Bool)?

    /// Optional banner shown above the composer when the user has no quota.
    var showsQuotaExceededBanner: Bool = false
    var quotaExceededBannerText: String = "Daily limit reached. Upgrade or come back tomorrow."
    var onQuotaExceededBannerTap: (() -> Void)?

    /// Voice mode integration. All optional — pass nil on platforms without voice.
    var isVoiceModeActive: Bool = false
    /// The gateway's real connection state. Drives the in-chat status card + skeleton + composer
    /// disable STATEFULLY: connected → nothing (chat is ready, even mid-load); connecting → "waking
    /// up"; pairing/unauthorized/unreachable → the matching copy. Deliberately NOT tied to
    /// `viewModel.isLoading` — that's a generic busy flag (also true during a normal send and a
    /// sub-second history load on a healthy gateway), so gating the card on it made "Waiting for your
    /// gateway" fire falsely on every chat open. The platform root passes `gateway.connectionState`.
    var gatewayConnectionState: GatewayConnectionState = .connected
    /// Backend JWT subject of the signed-in account, passed by the platform root
    /// (`gateway.authenticatedAccountIDForRecovery`). Used ONLY to scope the brief headline that
    /// titles the durable orchestrator session: the headline is model-authored prose that can name
    /// a person, so it must never render for a different account than the one that authored it.
    /// Defaults to nil, which fails closed to the plain "Rem" title.
    var briefAccountID: String?
    /// Structured auth evidence from the exact operator session that will execute the turn.
    /// Unknown-without-prior blocks Send so it cannot be mistaken for verified unavailability and
    /// destructively reset an explicit model to Automatic.
    var runtimeProviderAuthEvidence: RuntimeProviderAuthEvidence = .verified([])
    /// Gateway-backed Models destination supplied by the thin platform wrapper. Keeping the
    /// gateway itself outside this view preserves the shared chat protocol boundary while ensuring
    /// Manage Models never falls back to device-local cosmetic switches.
    var modelsSettingsDestination: (() -> AnyView)?
    /// True when this conversation was JUST created (a "New conversation" tap, a starter, or a
    /// skill/capability hand-off) and therefore has NO server-side history to fetch. The platform
    /// root sets it from the navigation action that minted the session key. It gates the loading
    /// skeleton: a brand-new conversation drops straight to the starter/empty state instead of
    /// shimmering through the whole bootstrap/"Can't reach Rem" window (founder: "every new convo
    /// even the started shows loading… no need to show loading, just go straight to starter"). The
    /// skeleton is reserved for an EXISTING conversation whose history is still loading — see
    /// `ChatEmptyStateGate`. Defaults to `false` (treat as existing) so unmarked entry points keep
    /// the pre-existing skeleton behavior; a missed `true` only costs a brief skeleton, never a flash.
    var isFreshConversation: Bool = false
    /// Title captured from the Chat Sessions row that opened this existing conversation. Its
    /// presence is also the explicit first-frame loading intent: `viewModel.isLoading` is set by an
    /// asynchronous task and can still be false during the destination's initial render.
    var initialExistingSessionTitle: String? = nil
    /// Navigation's requested session. During the async view-model rebind this can differ from
    /// `viewModel.sessionKey`; treating that interval as pending prevents old/empty UI from leaking.
    var requestedSessionKey: String? = nil
    var autoStartVoice: Bool = false
    var onVoiceTap: (() -> Void)?
    var voiceTranscriptionState: VoiceTranscriptionState?
    var voiceTranscripts: [String]?
    var onEndVoice: (() -> Void)?
    var voiceStatusText: String?
    var voiceResponsePhase: VoiceResponsePhase = .idle
    var voiceIsReadingAloud: Bool = false
    var voiceCanRetryReadingAloud: Bool = false
    var voiceMuteState: VoiceMuteState?
    var voiceIsMuted: Bool = false
    /// Toggle mic mute/unmute from the mini-bar. Optional so platforms that
    /// don't yet surface a mute control can drop this hook.
    var onToggleMute: (() -> Void)?
    /// Stops explicit prose playback while preserving the active voice conversation.
    var onStopReadingAloud: (() -> Void)?
    var onRetryReadingAloud: (() -> Void)?
    /// Push-to-talk toggle (#321 PR 3). Mac-only for now — iOS passes nil
    /// because it has no PTT path. When non-nil, the mini-bar shows a small
    /// mode-toggle button next to the mute button. `voiceInputModeIsPTT`
    /// flags which state is currently active so the icon can switch.
    var voiceInputModeIsPTT: Bool = false
    var onToggleVoiceInputMode: (() -> Void)?
    var voiceStartDate: Date?
    /// When set, the voice session is idle and auto-closing at this instant (the mini-bar shows a
    /// draining top line + "Keep open"). Nil = not closing.
    var voiceAutoCloseAt: Date?
    /// The full auto-close countdown window (so the top line drains proportionally).
    var voiceAutoCloseCountdownDuration: TimeInterval = 30
    /// Tapped "Keep open" — cancel the pending auto-close.
    var onKeepVoiceOpen: (() -> Void)?
    var onSendResponseSpeech: (() -> Void)?
    /// Called after a message is sent so platform glue can kick off post-send
    /// side effects (e.g. voice TTS).
    var onAfterSend: (() -> Void)?
    var sessionPreviewContext: SessionPreviewContext = SessionPreviewContext()
    var onOpenDeviceConnections: (() -> Void)?
    var onRetryConnection: (() -> Void)?
    /// Exact gateway execution lifecycle, captured by the platform transport
    /// before OpenClawChatUI rewrites execution IDs for history routing.
    var runLifecycleEvidenceStore: RunLifecycleEvidenceStore?

    /// Session name refresh nudge. Some platforms want to force a redraw
    /// after the transport auto-names a new session on the first message.
    var sessionNameRefreshToken: Int = 0

    /// Looks up a local display name for the active session. iOS uses the
    /// shared `SessionDisplayNames` store; Mac may layer its own store on
    /// top. Returns nil when no local name is set.
    var localSessionName: (String) -> String? = { SessionDisplayNames.name(for: $0) }

    /// Writes a user-edited session display name. iOS uses the shared
    /// `SessionDisplayNames` store; Mac may additionally persist to the
    /// gateway via `sessions.patch`.
    var setSessionName: (String, String) -> Void = { name, key in
        SessionDisplayNames.setName(name, for: key)
    }

    @FocusState private var isInputFocused: Bool
    /// Single source of truth for disclosure expansion — live "Working" and completed "Activity"
    /// alike, keyed by section id. Nothing writes to it except a user tap and the run-boundary
    /// reset in `reconcileLiveRunActivityExpansion` (#1278).
    @State private var expandedSections: Set<String> = []
    @State private var runActivityAccumulator = RunActivityAccumulator()

    /// Presents the Models page from the picker's "Manage models" footer.
    @State private var showsModelsSheet = false
    /// Photos chosen via the composer's `PhotosPicker`. Cleared after each
    /// selection is loaded into the view model's pending attachments. The picker
    /// is the only *new* affordance here — the attachments strip, removable
    /// chips, base64 encoding, and `chat.send` plumbing already exist upstream
    /// (`OpenClawChatViewModel.addImageAttachment` → `OpenClawChatAttachmentPayload`).
    @State private var pickedPhotoItems: [PhotosPickerItem] = []
    /// "+" composer sheet (ChatGPT/Claude "Add to Chat" pattern). Holds the
    /// decluttered affordances — attach rows (Camera/Photos/Files), Thinking
    /// level, and the model picker — so the composer itself stays minimal:
    /// `[+] [text field] [Speak] [send]`.
    @State private var showsAddSheet = false
    /// The "Cloud browser" capability is attached to the next turn — rendered as a removable chip in
    /// the composer's attachment strip. On send it injects a VISIBLE browser directive (there's no
    /// hidden per-turn channel) and clears. It does NOT open or warm the browser itself: the agent
    /// opens it in response to the directive, and the live view's own `present()` warms the stream
    /// when the user taps the card — so an unsent or non-browsing turn never leaves a stream running.
    @State private var browserCapabilityAttached = false
    /// Distinguishes the chip captured by an in-flight send from a later detach/reattach action.
    @State private var browserCapabilityRevision: UInt64 = 0
    /// Files attach row (`.fileImporter`) presentation.
    @State private var showsFileImporter = false
    #if os(iOS)
    /// Camera capture presentation (iOS only — `UIImagePickerController`).
    @State private var showsCamera = false
    #endif
    /// A sent image tapped open for full-screen zoom viewing.
    @State private var zoomedImage: ZoomedImage?
    /// Mirrors the sessionNameRefreshToken so the nav title re-evaluates.
    @State private var localSessionNameRefresh: Int = 0
    /// Caches streaming text between `streamingAssistantText = nil` and the
    /// history refresh completing, preventing flash on final chunk.
    @State private var cachedStreamingText: String?
    /// Tail-relative user-turn anchor captured with the latest stream fragment. History can append an
    /// assistant preamble and tool/result plumbing first; only the terminal persisted assistant
    /// answer for this exact turn is allowed to retire the cache. It intentionally avoids a forward
    /// occurrence ordinal because OpenClaw's capped history can truncate prefix rows on refresh.
    @State private var cachedStreamingOriginUserAnchor: StreamingAssistantHandoffPolicy.UserTurnAnchor?
    /// Keeps an opened existing conversation on its real-layout skeleton from the first frame until
    /// the matching history request has actually entered and exited loading (or messages arrive).
    @State private var observedInitialHistoryLoading = false
    @State private var completedInitialHistoryLoad = false
    /// Latches a first-frame mismatch/empty snapshot across `sessionKey` changing before the view
    /// model replaces its old messages. Without the latch, those stale non-empty messages could be
    /// mistaken for the requested transcript for one frame.
    @State private var initialHistoryLoadWasRequired = false
    /// Covers a load that starts and finishes between SwiftUI observation passes. It is cancelled
    /// as soon as a real loading transition is observed, so slow network history never times out to
    /// a false starter state.
    @State private var initialHistoryCompletionFallbackTask: Task<Void, Never>?
    /// Restored-history snapshots that have been bottom-scrolled.
    /// Opening old sessions can render enough content that the immediate
    /// `messages.count` scroll fires before SwiftUI has laid out the bottom
    /// row, leaving the transcript at the top.
    @State private var restoredHistoryScrollState = RestoredHistoryScrollState()
    @State private var restoredHistoryScrollTask: Task<Void, Never>?
    @State private var didApplyLatestBriefScroll = false
    @State private var latestBriefAnchorMessageIdentity: String?
    /// History can settle through several independent observation callbacks. Keep all of those
    /// callbacks from undoing the brief anchor; a real user send (or voice transcription change)
    /// resumes the normal bottom-following conversation behavior.
    @State private var briefAnchorAllowsBottomFollowing = false
    @State private var stableSessionTitle: String?
    /// Gates the "Response interrupted — Retry" card. Set true only after the
    /// interrupted-turn shape has been stable for a short debounce (see
    /// `.task(id: interruptedTurnSignature)`), so the brief idle window between a
    /// healthy run finishing and its history refresh landing can't flash the card.
    @State private var interruptedAffordanceVisible = false

    /// Rename alert triggered from the nav bar menu.
    @State private var isRenamingSession = false
    @State private var renameText: String = ""
    @State private var sessionPreviewPresentation: SessionPreviewPresentation?
    /// Owned by the chat root rather than by `SharedSuggestionSection`, which renders inside the
    /// transcript's `LazyVStack`. An inbound message arriving while the sheet is open can scroll
    /// that row out of the realized range; a presenter living there would go with it.
    @State private var isShowingAllSuggestions = false

    // MARK: - Voice Types
    //
    // These mirror the iOS `TranscriptionState` / talk-mode flags but stay in
    // Shared so the view does not depend on iOS-only voice types.

    enum VoiceTranscriptionState: Equatable {
        case idle
        case transcribing(partial: String)
        case sent(text: String)
    }

    enum VoiceMuteState: Equatable { case muted, unmuted }

    #if DEBUG
    private static let showsSessionPreviewMenu =
        ProcessInfo.processInfo.environment["REM_SESSION_PREVIEW_MENU"] == "1"

    /// Dedup state so streaming chunks don't spam identical [ChatSanitize] logs.
    nonisolated(unsafe) static var lastLoggedSanitizeInput: String = ""
    /// Dedup per-call-site entry logs so streaming chunk spam doesn't drown the
    /// console. Keyed by "\(site)|\(text.hashValue)" — a new value clears the
    /// dedup on the prior site. Only used when `chatSanitizeVerbose` is on.
    nonisolated(unsafe) static var lastTracedEntry: String = ""
    #endif

    #if DEBUG
    /// Phase 1 diagnostic switch for #260 (Chat sanitization gaps: shell
    /// command output and tool errors leak into AI bubbles). When true, every
    /// entry into `preprocessMarkdown` and every assistant-text branch of
    /// `splitContent` emits a `[ChatSanitize]` log tagged with its call site,
    /// regardless of whether the cleaner changed the input. Used to prove
    /// which render path (history replay vs. streaming vs. other) bypasses
    /// the cleaner for leaked tool errors and CLI help dumps.
    ///
    /// Opt-in DEBUG diagnostic switch for #260 (Chat sanitization gaps). Keep
    /// disabled by default because this view's render paths can be re-evaluated
    /// many times over long transcripts; logging raw/cleaned previews from each
    /// pass can balloon debug memory during dogfood sessions.
    static let chatSanitizeVerbose: Bool =
        ProcessInfo.processInfo.environment["REM_CHAT_SANITIZE_VERBOSE"] == "1"
    #endif

    var body: some View {
        ZStack(alignment: .bottom) {
            messageList
            bottomControls
        }
        .navigationTitle(sessionDisplayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !BriefContext.isBriefSession(viewModel.sessionKey) {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) { renameMenu }
                #else
                ToolbarItem(placement: .primaryAction) { renameMenu }
                #endif
            }
        }
        .alert("Rename Conversation", isPresented: $isRenamingSession) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    setSessionName(trimmed, viewModel.sessionKey)
                    localSessionNameRefresh += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $sessionPreviewPresentation) { presentation in
            NavigationStack {
                SharedSessionPreviewFeedView(model: presentation.model)
            }
        }
        .suggestionOverflowSheet(
            isPresented: $isShowingAllSuggestions,
            suggestions: currentOrchestratorSuggestionSnapshot?.suggestions ?? [],
            briefMarkdown: currentOrchestratorSuggestionSnapshot?.briefMarkdown,
            onAccept: { onAcceptSuggestion?($0) },
            onDismiss: { onDismissSuggestion?($0) }
        )
        .task { viewModel.load() }
        .onAppear {
            // Start voice right away when requested. While the gateway is still waking, the voice
            // mini-bar renders its "connecting" state (thinking-dots, no controls); the real
            // controls/timer animate in once the session is live. See voiceMiniBar(isConnecting:).
            if autoStartVoice && !isVoiceModeActive {
                onVoiceTap?()
            }
        }
        .onChange(of: sessionNameRefreshToken) { _, _ in
            localSessionNameRefresh += 1
            captureStableSessionTitleIfNeeded()
        }
        .onChange(of: viewModel.sessionKey) { _, _ in
            stableSessionTitle = nil
            runActivityAccumulator.reset()
            runLifecycleEvidenceStore?.retainOnly(sessionKey: viewModel.sessionKey)
            expandedSections.remove(Self.liveRunActivitySectionID)
            // Transient composer state is per-conversation: an unsent "Cloud browser" chip must not
            // bleed into the chat we just switched to (the VM carries input/attachments across the
            // switch; this view-local flag doesn't, so reset it here like the title above).
            setBrowserCapabilityAttached(false)
            captureStableSessionTitleIfNeeded()
        }
        .onChange(of: viewModel.sessionChoices) { _, _ in
            captureStableSessionTitleIfNeeded()
        }
        .onChange(of: runActivityReconciliationIdentity, initial: true) { oldIdentity, newIdentity in
            // A new run is the only non-tap writer of the live disclosure's expansion. Ticks *within*
            // a run leave it untouched, so an expansion the user opened mid-stream survives every
            // subsequent streaming update instead of being collapsed out from under them (#1278).
            let reconciledSections = Self.reconcileLiveRunActivityExpansion(
                expandedSections: expandedSections,
                previousEffectiveRunCount: oldIdentity.effectiveRunCount,
                currentEffectiveRunCount: newIdentity.effectiveRunCount
            )
            if reconciledSections != expandedSections {
                expandedSections = reconciledSections
            }
            synchronizeRunActivityAccumulator()
        }
        #if os(iOS)
        .fullScreenCover(item: $zoomedImage) { item in
            FullScreenImageViewer(image: item.image) { zoomedImage = nil }
        }
        #else
        .sheet(item: $zoomedImage) { item in
            FullScreenImageViewer(image: item.image) { zoomedImage = nil }
        }
        #endif
    }

    /// This conversation OWNS the single global browser session (it was the last to browse). Only
    /// the owner shows a card — otherwise the shared session's retained frame/URL would leak into an
    /// unrelated chat.
    private var browserOwnedHere: Bool {
        guard let s = browserSession else { return false }
        return s.lastConversationKey == viewModel.sessionKey
    }

    /// Explicit user/agent teardown ended this conversation's actual browser session. Agent-run
    /// completion and viewer dismissal deliberately do not set this marker.
    private var browserSessionEndedHere: Bool {
        guard let s = browserSession else { return false }
        return browserOwnedHere && s.hasEnded
    }

    /// The card to show, computed by the pure, unit-tested resolver. Ownership prevents another
    /// conversation's history from claiming the one global browser; explicit lifecycle state
    /// distinguishes active from ended.
    private var activeBrowserRunEvidences: [BrowserRunEvidence] {
        browserSession?.browserRunEvidences(for: viewModel.sessionKey) ?? []
    }

    private var browserCardPresentation: BrowserCardPresentation {
        return BrowserCardStateResolver.resolve(
            messages: viewModel.messages,
            pendingRunCount: viewModel.pendingRunCount,
            isOwner: browserOwnedHere,
            isSessionEnded: browserSessionEndedHere,
            activeRunEvidences: activeBrowserRunEvidences
        )
    }

    /// This conversation has a LIVE browser to watch right now. Drives the pinned card above the
    /// composer.
    private var browserLiveHere: Bool { browserCardPresentation == .live }

    private var browserReadyToPresentHere: Bool {
        // Once this conversation owns an explicitly active session, run completion does not make
        // its viewer unsafe or unavailable. The evidence gate below is only for pre-ownership
        // attachment intent, where opening could expose another conversation's retained page.
        if browserOwnedHere && !browserSessionEndedHere { return true }
        return BrowserCardStateResolver.canPresentLiveBrowser(
            messages: viewModel.messages,
            pendingRunCount: viewModel.pendingRunCount,
            activeRunEvidences: activeBrowserRunEvidences
        )
    }

    /// This conversation's browser session explicitly ENDED. Drives the historical card inline in
    /// the transcript, which reopens the frozen last frame without waking the browser.
    private var browserEndedHere: Bool { browserCardPresentation == .ended }

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 0) {
            // The browser is the one tool whose work is worth WATCHING rather than reading a
            // one-line summary of, and the only one the user may need to reach into. So it gets
            // a card with a picture. (Living inside pendingToolsBar meant it vanished the instant it
            // became useful.) Shown while Rem is genuinely browsing in THIS conversation — see
            // `browserCardPresentation` / `BrowserCardStateResolver`. Deliberately conversation-scoped
            // so another chat's history can never expose the shared browser. The pinned card above the
            // composer belongs there while the session is active — a reach-for-it affordance. Once
            // Rem explicitly stops it, the card moves INTO the transcript as
            // the review card (see `messageList`), anchored below its message, so it scrolls away as
            // history rather than hanging over the chat and remains the user's way back in.
            if let browserSession, browserLiveHere {
                // No outer backdrop: the card carries its own rounded OPAQUE container, so it reads as
                // a contained element over the chat (like the composer) rather than a full-width white
                // strip. Read-through isn't an issue: message rows share the card's horizontal inset
                // (Spacing.lg), so no message text sits in the outer side margins, and the card body
                // itself is opaque (backgroundSecondary). (Only the ~8pt gap to the composer is
                // uncovered — transient during a fling, acceptable.)
                BrowserLiveCard(
                    session: browserSession,
                    ended: false,
                    isReadyToPresent: browserReadyToPresentHere
                )
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.sm)
            }

            if let error = viewModel.errorText {
                errorBanner(error)
            }

            if showsQuotaExceededBanner {
                quotaExceededBanner
            }

            // While the gateway isn't connected, sit a calm, STATE-AWARE status message above a
            // disabled composer so the input reads as "not yet, hang on" rather than silently
            // swallowing a send. Copy reflects the real state (waking vs pairing vs unreachable).
            if isWaking {
                ChatConnectionRecoveryCard(
                    connectionState: gatewayConnectionState,
                    onRetry: onRetryConnection,
                    onReviewConnection: onOpenDeviceConnections
                )
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.sm)
            }

            composerBar
                .disabled(isWaking)

            // Voice bar below composer (only when platform provides voice hooks). Always shown when
            // a voice session is active — never hide the End/Mute controls of a live mic. Voice
            // simply doesn't START during waking (deferred to !isLoading), so there's normally no
            // bar over the skeleton anyway.
            if isVoiceModeActive, let onEndVoice {
                voiceMiniBar(onEndVoice: onEndVoice)
            }
        }
        // Re-run the reconcile whenever anything that can change the card state changes: the
        // conversation, transcript, in-flight run count, or transport-captured browser activity.
        // `initial: true` also establishes the correct cold-open state.
        .onChange(of: browserCardKey, initial: true) { _, _ in reconcileBrowserCardState() }
    }

    /// Changes when the conversation, transcript length, in-flight-run state, or browser activity
    /// change — every input that can produce a different browser-card answer.
    private var browserCardKey: String {
        let revision = browserSession?.browserActivityRevision ?? 0
        let lastMessageID = viewModel.messages.last?.id.uuidString ?? "none"
        let lastUserID = viewModel.messages.last(where: { $0.role == "user" })?.id.uuidString ?? "none"
        let lastBrowserID = viewModel.messages
            .last(where: BrowserCardStateResolver.isBrowserMessage)?.id.uuidString ?? "none"
        return "\(viewModel.sessionKey)#\(viewModel.messages.count)#\(lastMessageID)#\(lastUserID)#\(lastBrowserID)#\(viewModel.pendingRunCount)#\(revision)"
    }

    /// Keeps the SESSION's ownership + sticky ended-marker in step with the derived card state, so the
    /// expanded review sheet (which reads `session.hasEnded`) and the single-global-browser ownership
    /// stay consistent. Display itself is derived (`browserLiveHere` / `browserEndedHere`); this only
    /// mirrors that into the session object's side-effecting state.
    ///
    /// LIVE uses structured browser starts captured by the transport before it yields the event to
    /// the chat view model; persisted transcript tool calls remain the historical/review source.
    private func reconcileBrowserCardState() {
        guard let session = browserSession else { return }
        let key = viewModel.sessionKey

        if session.browserTranscriptAnchorState(for: key) != nil {
            let baselineIndex = visibleMessages.indices.last
            let baselineMessage = baselineIndex.map { visibleMessages[$0] }
            session.captureBrowserTranscriptBaselineIfNeeded(
                messageID: baselineMessage?.id,
                messageIndex: baselineIndex,
                messageSignature: baselineMessage.map(Self.browserTranscriptBoundarySignature),
                for: key
            )
            if let state = session.browserTranscriptAnchorState(for: key),
               let resolved = Self.resolveStructuredBrowserAnchor(
                   messages: visibleMessages,
                   baselineMessageID: state.baselineMessageID,
                   baselineMessageIndex: state.baselineMessageIndex,
                   baselineMessageSignature: state.baselineMessageSignature,
                   existingResolvedMessageID: state.resolvedMessageID,
                   evidenceIsLive: state.runIsActive,
                   structuredToolCallIDs: state.structuredToolCallIDs
               )
            {
                session.noteBrowserResolvedAnchor(resolved, for: key)
            }
        }

        if browserLiveHere {
            // Rem is genuinely browsing in THIS chat right now (guarded by local run state or
            // transport-captured external-run evidence — see `browserLiveHere`). Real browser
            // activity owns the single global browser and clears a prior explicit ended marker.
            if browserReadyToPresentHere {
                session.agentHasBrowsed = true
                session.noteBrowsingConversation(key)
                session.noteAgentBrowsing()
            }
            return
        }

        session.agentHasBrowsed = false
        // A run becoming idle is not a browser lifecycle transition. Explicit browser stop/close
        // events and the user's End action update `session.hasEnded` at their source.
    }

    /// The transcript id the ended browser card anchors to: the LAST browser/canvas call. The card
    /// renders right after it, so it sits at the browser's chronological place in the history and
    /// later messages scroll below it — instead of the card chasing the bottom of the transcript.
    private var browserAnchorMessageID: OpenClawChatMessage.ID? {
        let resolvedStructuredAnchor = browserSession?
            .browserTranscriptAnchorState(for: viewModel.sessionKey)?.resolvedMessageID
        return Self.browserAnchorMessageID(
            messages: visibleMessages,
            activeRunEvidences: activeBrowserRunEvidences,
            structuredResolvedAnchor: resolvedStructuredAnchor
        )
    }

    /// Prefer the exact persisted browser row. Some gateways deliver structured `agent/tool`
    /// activity live but omit the corresponding tool call from the immediate history refresh; in
    /// that case anchor the review card to the final row of the same turn. This keeps the browser
    /// card visible after completion and lets it remain the canonical presentation instead of
    /// leaving a generic browser step inside Activity.
    static func browserAnchorMessageID(
        messages: [OpenClawChatMessage],
        activeRunEvidences: [BrowserRunEvidence],
        structuredResolvedAnchor: OpenClawChatMessage.ID? = nil
    ) -> OpenClawChatMessage.ID? {
        if activeRunEvidences.contains(where: \.containsBrowserActivity) {
            guard let structuredResolvedAnchor,
                  messages.contains(where: { $0.id == structuredResolvedAnchor }) else { return nil }
            return structuredResolvedAnchor
        }
        return messages.last(where: BrowserCardStateResolver.isBrowserMessage)?.id
    }

    static func resolveStructuredBrowserAnchor(
        messages: [OpenClawChatMessage],
        baselineMessageID: OpenClawChatMessage.ID?,
        baselineMessageIndex: Int?,
        baselineMessageSignature: String?,
        existingResolvedMessageID: OpenClawChatMessage.ID?,
        evidenceIsLive: Bool,
        structuredToolCallIDs: Set<String> = []
    ) -> OpenClawChatMessage.ID? {
        let baselineIndexByID = baselineMessageID.flatMap { baseline in
            messages.lastIndex(where: { $0.id == baseline })
        }
        let baselineIndexBySignature = baselineMessageSignature.flatMap { signature in
            messages.indices.min { lhs, rhs in
                let lhsMatches = Self.browserTranscriptBoundarySignature(messages[lhs]) == signature
                let rhsMatches = Self.browserTranscriptBoundarySignature(messages[rhs]) == signature
                if lhsMatches != rhsMatches { return lhsMatches }
                let target = baselineMessageIndex ?? messages.startIndex
                return abs(lhs - target) < abs(rhs - target)
            }.flatMap { index in
                Self.browserTranscriptBoundarySignature(messages[index]) == signature ? index : nil
            }
        }
        let baselineIndex = baselineIndexByID
            ?? baselineIndexBySignature
            ?? baselineMessageIndex.flatMap { messages.indices.contains($0) ? $0 : nil }
        if baselineMessageID != nil || baselineMessageSignature != nil || baselineMessageIndex != nil {
            guard baselineIndex != nil else { return nil }
        }
        if let baselineIndex,
           messageMatchesStructuredToolCall(
               messages[baselineIndex],
               toolCallIDs: structuredToolCallIDs
           )
        {
            return messages[baselineIndex].id
        }
        let searchStart = baselineIndex.map { $0 + 1 } ?? 0
        let baselineIsProducingUser = baselineIndex.map { messages[$0].role == "user" } ?? false
        let producingUserIndex = baselineIsProducingUser
            ? baselineIndex
            : messages.indices.dropFirst(searchStart).first(where: { messages[$0].role == "user" })
        let turnStart = producingUserIndex.map { $0 + 1 } ?? searchStart
        let turnEnd = producingUserIndex.flatMap { producingUser in
            messages.indices.dropFirst(producingUser + 1)
                .first(where: { messages[$0].role == "user" })
        } ?? messages.endIndex
        guard turnStart <= turnEnd else { return nil }
        let turnIndices = turnStart..<turnEnd

        if let exactIndex = turnIndices.last(where: {
            BrowserCardStateResolver.isBrowserMessage(messages[$0])
        }) {
            return messages[exactIndex].id
        }
        if let existingResolvedMessageID,
           turnIndices.contains(where: { messages[$0].id == existingResolvedMessageID })
        {
            return existingResolvedMessageID
        }
        guard !evidenceIsLive else { return nil }
        return turnIndices.last(where: { messages[$0].role != "user" })
            .map { messages[$0].id }
    }

    static func browserTranscriptBoundarySignature(_ message: OpenClawChatMessage) -> String {
        let content = message.content.map { item in
            [item.type ?? "", item.name ?? "", item.text ?? ""]
                .joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return "\(message.role.lowercased())\u{1D}\(content)"
    }

    static func messageMatchesStructuredToolCall(
        _ message: OpenClawChatMessage,
        toolCallIDs: Set<String>
    ) -> Bool {
        guard !toolCallIDs.isEmpty else { return false }
        if let toolCallID = message.toolCallId, toolCallIDs.contains(toolCallID) { return true }
        return message.content.contains { item in
            item.id.map(toolCallIDs.contains) ?? false
        }
    }

    private var browserCardTurnMessageIDs: Set<OpenClawChatMessage.ID> {
        switch browserCardPresentation {
        case .live:
            // Agent evidence can make the card live before the matching browser tool call (or even
            // its user boundary for voice/cross-device runs) is persisted. Suppress activity only
            // after the transcript contains the exact active tool-call identity; guessing from the
            // latest user/browser row can temporarily hide a completed older turn.
            let activeToolCallIDs = Set(activeBrowserRunEvidences
                .filter(\.runIsActive)
                .flatMap(\.observedToolCallIDs))
            return Self.messageIDsFromMatchedToolCall(
                toolCallIDs: activeToolCallIDs,
                messages: visibleMessages
            )
        case .ended:
            return Self.messageIDsInAssistantTurn(
                containing: browserAnchorMessageID,
                messages: visibleMessages
            )
        case .none:
            return []
        }
    }

    static func messageIDsFromMatchedToolCall(
        toolCallIDs: Set<String>,
        messages: [OpenClawChatMessage]
    ) -> Set<OpenClawChatMessage.ID> {
        guard !toolCallIDs.isEmpty,
              let anchorIndex = messages.firstIndex(where: { message in
                  if let id = message.toolCallId, toolCallIDs.contains(id) { return true }
                  return message.content.contains { item in
                      item.id.map(toolCallIDs.contains) ?? false
                  }
              }) else { return [] }

        var upperBound = anchorIndex
        while messages.index(after: upperBound) < messages.endIndex,
              messages[messages.index(after: upperBound)].role
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "user" {
            upperBound = messages.index(after: upperBound)
        }
        return Set(messages[anchorIndex...upperBound].map(\.id))
    }

    static func messageIDsInAssistantTurn(
        containing anchorID: OpenClawChatMessage.ID?,
        messages: [OpenClawChatMessage]
    ) -> Set<OpenClawChatMessage.ID> {
        guard let anchorID,
              let anchorIndex = messages.firstIndex(where: { $0.id == anchorID }) else { return [] }

        var lowerBound = anchorIndex
        while lowerBound > messages.startIndex,
              messages[messages.index(before: lowerBound)].role
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "user" {
            lowerBound = messages.index(before: lowerBound)
        }

        var upperBound = anchorIndex
        while messages.index(after: upperBound) < messages.endIndex,
              messages[messages.index(after: upperBound)].role
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "user" {
            upperBound = messages.index(after: upperBound)
        }

        return Set(messages[lowerBound...upperBound].map(\.id))
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var renameMenu: some View {
        Menu {
            Button {
                renameText = sessionDisplayName
                isRenamingSession = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            #if DEBUG
            if Self.showsSessionPreviewMenu, sessionPreviewModel != nil {
                Button {
                    if let model = sessionPreviewModel {
                        sessionPreviewPresentation = SessionPreviewPresentation(model: model)
                    }
                } label: {
                    Label("Session Preview", systemImage: "eye")
                }
            }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
    }

    // MARK: - Session Display Name

    private var sessionDisplayName: String {
        _ = localSessionNameRefresh
        _ = sessionNameRefreshToken
        // Navigation can render before the async view-model switch begins. During that interval the
        // view model still describes the previously open session, so its local title is stale;
        // prefer the title captured from the row the user actually tapped until history settles.
        if isInitialHistoryPending,
           let name = MessageCleaner.usableSessionTitle(initialExistingSessionTitle) {
            return name
        }
        if let dailyTitle = BriefContext.displayTitle(
            for: viewModel.sessionKey,
            accountID: briefAccountID
        ) {
            return dailyTitle
        }
        // The title comes from the conversation, never the device the chat was
        // opened on — `usableSessionTitle` rejects generic client + device names
        // ("iPhone 17 Pro") so we fall through to a meaningful title.
        if let name = MessageCleaner.usableSessionTitle(localSessionName(viewModel.sessionKey)) {
            return name
        }
        let current = viewModel.sessionChoices.first { $0.key == viewModel.sessionKey }
        if let name = MessageCleaner.usableSessionTitle(current?.displayName) {
            return name
        }
        if let stableSessionTitle {
            return stableSessionTitle
        }
        // The row title is authoritative only for the pending first frame. After history/session
        // metadata arrives, keep it as the last fallback so a rename from another device or a newly
        // generated server title can replace stale list text.
        if let name = MessageCleaner.usableSessionTitle(initialExistingSessionTitle) {
            return name
        }
        return "New conversation"
    }

    private func captureStableSessionTitleIfNeeded() {
        guard stableSessionTitle == nil else { return }
        guard localSessionName(viewModel.sessionKey) == nil else { return }
        let current = viewModel.sessionChoices.first { $0.key == viewModel.sessionKey }
        guard let name = MessageCleaner.usableSessionTitle(current?.displayName) else { return }
        stableSessionTitle = name
    }

    private struct SessionPreviewPresentation: Identifiable {
        let id = UUID()
        let model: SessionPreviewFeedModel
    }

    private var sessionPreviewModel: SessionPreviewFeedModel? {
        let completedEntries = completedSessionPreviewEntries
        let pendingEntries = liveSessionPreviewEntries
        let entries = completedEntries + pendingEntries
        guard !entries.isEmpty else { return nil }

        return SessionPreviewFeedModel(
            state: pendingEntries.isEmpty ? .logged : .running,
            gatewayName: sessionPreviewContext.gatewayName,
            deviceName: sessionPreviewContext.deviceName,
            entries: entries
        )
    }

    private var liveSessionPreviewEntries: [SessionPreviewEntry] {
        viewModel.pendingToolCalls.map { toolCall in
            SessionPreviewEntry.fromPendingTool(
                name: toolCall.name,
                args: toolCall.args,
                toolCallId: toolCall.toolCallId,
                sessionId: viewModel.sessionId ?? viewModel.sessionKey,
                gatewayId: sessionPreviewContext.gatewayId,
                gatewayProvider: sessionPreviewContext.gatewayProvider,
                deviceId: sessionPreviewContext.deviceId
            )
        }
    }

    private var completedSessionPreviewEntries: [SessionPreviewEntry] {
        Array(viewModel.messages
            .flatMap(completedSessionPreviewEntries(from:))
            .suffix(12))
    }

    private func completedSessionPreviewEntries(from message: OpenClawChatMessage) -> [SessionPreviewEntry] {
        let role = message.role.lowercased()
        let timestamp = message.timestamp.flatMap { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

        if role == "toolresult" || role == "tool_result" {
            return [
                completedSessionPreviewEntry(
                    name: message.toolName,
                    resultStatus: toolResultStatus(from: message),
                    toolCallId: message.toolCallId,
                    timestamp: timestamp
                ),
            ]
        }

        return message.content.compactMap { item in
            let kind = (item.type ?? "").lowercased()
            guard kind == "toolresult" || kind == "tool_result" else {
                return nil
            }
            return completedSessionPreviewEntry(
                name: item.name ?? message.toolName,
                resultStatus: toolResultStatus(from: item),
                toolCallId: item.id ?? message.toolCallId,
                timestamp: timestamp
            )
        }
    }

    private func completedSessionPreviewEntry(
        name: String?,
        resultStatus: String?,
        toolCallId: String?,
        timestamp: Date
    ) -> SessionPreviewEntry {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionPreviewEntry.fromCompletedTool(
            name: trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? "tool",
            resultStatus: resultStatus,
            toolCallId: toolCallId,
            sessionId: viewModel.sessionId ?? viewModel.sessionKey,
            gatewayId: sessionPreviewContext.gatewayId,
            gatewayProvider: sessionPreviewContext.gatewayProvider,
            deviceId: sessionPreviewContext.deviceId,
            now: timestamp
        )
    }

    private func toolResultStatus(from message: OpenClawChatMessage) -> String? {
        for item in message.content {
            if let status = toolResultStatus(from: item) {
                return status
            }
        }
        return nil
    }

    private func toolResultStatus(from item: OpenClawChatMessageContent) -> String? {
        if let status = statusValue(in: item.content) {
            return status
        }
        if let text = item.text,
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let status = statusValue(in: AnyCodable(json)) {
            return status
        }
        return nil
    }

    private func statusValue(in content: AnyCodable?) -> String? {
        guard let content else { return nil }
        if let dict = content.value as? [String: Any] {
            if let status = dict["status"] as? String {
                return status
            }
            return dict.keys.contains { $0.lowercased() == "error" } ? "error" : nil
        }
        if let dict = content.value as? [String: AnyCodable] {
            if let status = dict["status"]?.value as? String {
                return status
            }
            return dict.keys.contains { $0.lowercased() == "error" } ? "error" : nil
        }
        return nil
    }

    private var sentVoiceTurnIsPending: Bool {
        guard let state = voiceTranscriptionState else { return false }
        if case .sent = state { return true }
        return false
    }

    private var assistantTailPolicy: VoiceAssistantTailPolicy {
        VoiceAssistantTailPolicy.resolve(
            sentTurnIsPending: sentVoiceTurnIsPending,
            isVoiceModeActive: isVoiceModeActive,
            phase: voiceResponsePhase,
            hasStreamingAssistantText: hasStreamingAssistantText,
            hasPendingRun: viewModel.pendingRunCount > 0
        )
    }

    /// Voice-initiated run is processing until audio playback begins.
    private var isVoiceThinking: Bool {
        voiceResponsePhase.isWorking && sentVoiceTurnIsPending
    }

    /// True when voice transcription is active — used to suppress the empty-state
    /// placeholder so the voice UI shows.
    private var hasActiveVoiceContent: Bool {
        guard let state = voiceTranscriptionState else { return false }
        if case .idle = state { return false }
        return true
    }

    // MARK: - Visible Messages (empty-text attachment de-duplication)

    /// The transcript messages to render. Collapses the optimistic + server-echo
    /// pair the upstream send path produces for an attachment send with EMPTY
    /// text: both user messages carry the identical image payload (Rem sends the
    /// base64; the gateway echoes it back), but only the optimistic copy holds
    /// the synthesized "See attached." placeholder text. The submodule reconcile
    /// keys on a text+filename fingerprint (`ChatViewModel.userRefreshIdentityKey`,
    /// read-only), so the divergent placeholder defeats the merge and the image
    /// renders twice. We keep the later (server) copy. No-op for normal text
    /// sends, which the submodule already de-duplicates.
    private var visibleMessages: [OpenClawChatMessage] {
        var result: [OpenClawChatMessage] = []
        result.reserveCapacity(viewModel.messages.count)
        for message in viewModel.messages {
            if message.role == "user",
               let previous = result.last,
               previous.role == "user",
               (Self.userMessagesShareAttachmentPayload(previous, message)
                || Self.userMessagesShareHiddenBriefEcho(previous, message)) {
                result[result.count - 1] = message
                continue
            }
            result.append(message)
        }
        return result
    }

    /// Synthesized empty-text attachment body injected by the upstream send path.
    private static func isSyntheticAttachmentPlaceholder(_ text: String) -> Bool {
        MessageCleaner.cleanUserMessageText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "See attached."
    }

    /// True when two user messages share the same NON-empty set of inline image
    /// payloads — i.e. one is the optimistic copy of the other's attachment send.
    private static func userMessagesShareAttachmentPayload(
        _ lhs: OpenClawChatMessage,
        _ rhs: OpenClawChatMessage
    ) -> Bool {
        let lhsKeys = attachmentContentKeys(lhs)
        guard !lhsKeys.isEmpty else { return false }
        return lhsKeys == attachmentContentKeys(rhs)
    }

    private static func userMessagesShareHiddenBriefEcho(
        _ lhs: OpenClawChatMessage,
        _ rhs: OpenClawChatMessage
    ) -> Bool {
        let lhsText = lhs.content.compactMap(\.text).joined(separator: "\n")
        let rhsText = rhs.content.compactMap(\.text).joined(separator: "\n")
        return StreamingAssistantHandoffPolicy.isHiddenBriefEchoPair(lhsText, rhsText)
    }

    private static func attachmentContentKeys(_ message: OpenClawChatMessage) -> Set<String> {
        var keys = Set<String>()
        for item in message.content {
            guard let base64 = attachmentBase64(item), !base64.isEmpty else { continue }
            keys.insert(base64)
        }
        return keys
    }

    // MARK: - Message List

    #if DEBUG
    /// DEBUG-only: `-forceChatWaking` pins the waking/skeleton state so it can be screenshotted on a
    /// warm gateway (the real `isLoading` window is sub-second). Never true in release builds.
    private static let forceWakingPreview = ProcessInfo.processInfo.arguments.contains("-forceChatWaking")
    #else
    private static let forceWakingPreview = false
    #endif

    /// The transcript shows the waking skeleton + a status card over a disabled composer while this
    /// is true — i.e. whenever the gateway is NOT connected (connecting/pairing/unauthorized/
    /// unreachable/offline), never for a normal message load on a healthy (connected) gateway.
    private var isWaking: Bool { !gatewayConnectionState.isConnected || Self.forceWakingPreview }

    /// A pending inbound prompt = the composer already carries unsent text: a skill/capability
    /// prefill (`openSkillSetupChat`), a task-continuation seed, or the user's own draft. Intent is
    /// already stated, so the "Start a conversation" starters are noise — hide them and let the
    /// always-visible composer carry the prompt (FIX 2: arriving from Capabilities with a prompt
    /// should not re-offer starters). The composer lives outside `messageList`, so suppressing the
    /// empty state just leaves an empty transcript above the prefilled composer.
    private var hasPendingInboundPrompt: Bool {
        !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isInitialHistoryPending: Bool {
        guard !completedInitialHistoryLoad else { return false }
        return initialHistoryLoadWasRequired || ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: isFreshConversation,
            initialExistingSessionTitle: initialExistingSessionTitle,
            requestedSessionKey: requestedSessionKey,
            currentSessionKey: viewModel.sessionKey,
            messagesEmpty: viewModel.messages.isEmpty,
            isLoading: viewModel.isLoading,
            completedInitialHistoryLoad: completedInitialHistoryLoad
        )
    }

    private var isShowingRequestedSession: Bool {
        requestedSessionKey == nil || requestedSessionKey == viewModel.sessionKey
    }

    /// `OpenClawChatViewModel.load()` runs in a Task. A warm/cached request can toggle `isLoading`
    /// entirely between SwiftUI observation passes, so waiting only for an observed true→false edge
    /// can strand the shimmer forever. Give the outer route task one short window to begin; if the
    /// requested session is still active and idle afterward, its history is settled (including a
    /// legitimately empty transcript). A real loading transition cancels this fallback immediately.
    private func scheduleInitialHistoryCompletionFallback() {
        initialHistoryCompletionFallbackTask?.cancel()
        guard isInitialHistoryPending else { return }
        initialHistoryCompletionFallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  isShowingRequestedSession,
                  !viewModel.isLoading
            else { return }
            completedInitialHistoryLoad = true
            initialHistoryLoadWasRequired = false
        }
    }

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Decide the scroll body's empty/loading content from a single pure classifier so the
                // rule is testable in isolation (see ChatEmptyStateGateTests). The skeleton is reserved
                // for an EXISTING conversation whose history is still loading. A brand-new conversation
                // (`isFreshConversation`) goes straight to the starter/composer; an existing-session
                // prefill still waits for its requested history so it cannot reveal the prior transcript.
                switch ChatEmptyStateGate.resolve(
                    messagesEmpty: !isShowingRequestedSession || viewModel.messages.isEmpty,
                    isLoading: viewModel.isLoading,
                    isWaking: isWaking,
                    isFreshConversation: isFreshConversation,
                    isInitialHistoryPending: isInitialHistoryPending,
                    hasPendingInboundPrompt: hasPendingInboundPrompt,
                    hasActiveVoiceContent: hasActiveVoiceContent,
                    hasLiveActivity: ChatEmptyStateGate.hasRenderableLiveActivity(
                        isShowingRequestedSession: isShowingRequestedSession,
                        activitySessionKey: runActivityAccumulator.sessionKey,
                        currentSessionKey: viewModel.sessionKey,
                        hasActivityDisplays: !runActivityAccumulator.displays.isEmpty
                    )
                ) {
                case .skeleton:
                    ChatWakingSkeleton()
                case .starters:
                    if showsBriefPreviewBridge {
                        VStack(spacing: DesignTokens.Spacing.md) {
                            briefPreviewBridge
                            if shouldShowSuggestionsAfterPreview {
                                orchestratorSuggestionBlock
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                    } else if shouldShowStandaloneSuggestions {
                        VStack(spacing: DesignTokens.Spacing.md) {
                            // Drop only the starters that are already on screen as suggestion rows.
                            // A derived starter carries its suggestion's key as its id, so showing
                            // both put the same createTask proposal on screen twice in two visual
                            // languages — a filled tap-to-prefill card above, a dashed Add/Dismiss
                            // row below. The rows win: they are the ones that can be actioned.
                            // Generic starters share no id with any suggestion and survive, which
                            // is what keeps Mac (always generic) from losing its starters entirely.
                            emptyStateBody(suppressingStarterIDs: starterIDsShownAsSuggestions)
                            // Padded here rather than on the VStack: `emptyStateBody` already
                            // insets itself by `.lg`, so a wrapper inset double-padded it to 32pt
                            // while the plain `else { emptyState }` branch below sat at 16pt.
                            orchestratorSuggestionBlock
                                .padding(.horizontal, DesignTokens.Spacing.lg)
                        }
                    } else {
                        emptyState
                    }
                case .transcript:
                    let turnActivities = historicalTurnActivities
                    let briefPreviewInsertionIndex = showsBriefPreviewBridge
                        ? Self.briefPreviewInsertionIndex(
                            in: visibleMessages,
                            matching: effectiveBriefPreviewMarkdown ?? ""
                        )
                        : nil
                    let briefSuggestionAnchorMessageID = Self.briefSuggestionAnchorMessageID(
                        sessionKey: viewModel.sessionKey,
                        messages: visibleMessages,
                        briefMarkdown: effectiveBriefPreviewMarkdown,
                        suggestionCount: currentOrchestratorSuggestionSnapshot?.suggestions.count ?? 0
                    )
                    let separatorLabels = Self.separatorLabels(
                        in: visibleMessages,
                        briefPreviewInsertionIndex: briefPreviewInsertionIndex
                    )
                    LazyVStack(spacing: DesignTokens.Spacing.md) {
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                            if briefPreviewInsertionIndex == index {
                                briefPreviewBridge
                                if shouldShowSuggestionsAfterPreview {
                                    orchestratorSuggestionBlock
                                }
                            }
                            if let separatorLabel = separatorLabels[index] {
                                ChatTimeSeparator(label: separatorLabel)
                            }
                            messageRow(message, turnActivity: turnActivities[message.id])
                                .id(message.id)
                            if message.id == briefSuggestionAnchorMessageID {
                                orchestratorSuggestionBlock
                            }
                            // Ended browser session: the historical card sits INLINE at the browser's
                            // place in the transcript (right after the last browser call), not pinned
                            // to the bottom — so later messages scroll below it in chronological order.
                            if let browserSession, browserEndedHere, message.id == browserAnchorMessageID {
                                BrowserLiveCard(session: browserSession, ended: true)
                                    .id("browser-ended-card")
                            }
                        }
                        // Connected-source signals can be the only actionable state on an otherwise
                        // empty day. With no authored brief prose there is no truthful assistant
                        // message to attach to, so render the revision-bound block standalone at the
                        // current transcript tail rather than fabricating an all-clear message.
                        if shouldShowStandaloneSuggestions {
                            orchestratorSuggestionBlock
                        }
                        if briefPreviewInsertionIndex == visibleMessages.endIndex {
                            briefPreviewBridge
                            if shouldShowSuggestionsAfterPreview {
                                orchestratorSuggestionBlock
                            }
                        }

                        // Live activity belongs to the chronological conversation tail. Keeping it
                        // in the transcript prevents Working from becoming composer-attached chrome
                        // and keeps the eventual response adjacent to the work that produced it.
                        if !runActivityAccumulator.displays.isEmpty {
                            pendingToolsBar
                                .id("live-run-activity")
                        }

                        if shouldRenderStreamingBeforeVoicePlaceholder {
                            assistantTailContent
                        }

                        voiceTranscriptionPlaceholder

                        if !shouldRenderStreamingBeforeVoicePlaceholder {
                            assistantTailContent
                        }

                        // The assistant turn ended abnormally (gateway dropped mid-stream, no
                        // finish signal, or only a reasoning trace with no final content). Surface
                        // it inline where the answer would have been, so an orphaned Thought block
                        // no longer masquerades as the reply — with a Retry that re-sends the
                        // preserved prompt. Debounced via `interruptedAffordanceVisible`.
                        if interruptedAffordanceVisible, let prompt = interruptedRetryPrompt {
                            interruptedTurnCard(prompt: prompt)
                                .id("interrupted-turn")
                        }

                        Color.clear.frame(height: bottomTranscriptInset)
                            .id("chat-bottom")
                    }
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.vertical, DesignTokens.Spacing.md)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        restoredHistoryScrollTask?.cancel()
                        restoredHistoryScrollTask = nil
                    }
            )
            .onAppear {
                initialHistoryLoadWasRequired = isInitialHistoryPending
                if isShowingRequestedSession, viewModel.isLoading, isInitialHistoryPending {
                    observedInitialHistoryLoading = true
                } else {
                    scheduleInitialHistoryCompletionFallback()
                }
                scrollRestoredHistoryToBottomIfNeeded(proxy: proxy)
            }
            .onChange(of: viewModel.sessionKey) { _, _ in
                initialHistoryCompletionFallbackTask?.cancel()
                initialHistoryLoadWasRequired = initialHistoryLoadWasRequired || isInitialHistoryPending
                observedInitialHistoryLoading = false
                completedInitialHistoryLoad = false
                restoredHistoryScrollTask?.cancel()
                restoredHistoryScrollTask = nil
                restoredHistoryScrollState.reset()
                didApplyLatestBriefScroll = false
                latestBriefAnchorMessageIdentity = nil
                briefAnchorAllowsBottomFollowing = false
                cachedStreamingText = nil
                cachedStreamingOriginUserAnchor = nil
                scrollRestoredHistoryToBottomIfNeeded(proxy: proxy)
                scheduleInitialHistoryCompletionFallback()
            }
            .onChange(of: requestedSessionKey) { _, _ in
                initialHistoryCompletionFallbackTask?.cancel()
                observedInitialHistoryLoading = false
                completedInitialHistoryLoad = false
                initialHistoryLoadWasRequired = ChatEmptyStateGate.isInitialHistoryPending(
                    isFreshConversation: isFreshConversation,
                    initialExistingSessionTitle: initialExistingSessionTitle,
                    requestedSessionKey: requestedSessionKey,
                    currentSessionKey: viewModel.sessionKey,
                    messagesEmpty: viewModel.messages.isEmpty,
                    isLoading: viewModel.isLoading,
                    completedInitialHistoryLoad: false
                )
                scheduleInitialHistoryCompletionFallback()
            }
            .onChange(of: viewModel.isLoading) { _, isLoading in
                if isLoading, isShowingRequestedSession, isInitialHistoryPending {
                    initialHistoryCompletionFallbackTask?.cancel()
                    observedInitialHistoryLoading = true
                } else if !isLoading, observedInitialHistoryLoading {
                    initialHistoryCompletionFallbackTask?.cancel()
                    completedInitialHistoryLoad = true
                    initialHistoryLoadWasRequired = false
                } else if !isLoading {
                    scheduleInitialHistoryCompletionFallback()
                }
                if !isLoading {
                    scrollRestoredHistoryToBottomIfNeeded(proxy: proxy)
                }
            }
            .onChange(of: streamingAssistantHandoffHistory) { previousHistory, history in
                guard cachedStreamingText != nil else { return }
                if StreamingAssistantHandoffPolicy.appendedUserTurn(
                    from: previousHistory,
                    to: history
                ) || StreamingAssistantHandoffPolicy.shouldClearCachedText(
                    originatingUserAnchor: cachedStreamingOriginUserAnchor,
                    messages: history
                ) {
                    cachedStreamingText = nil
                    cachedStreamingOriginUserAnchor = nil
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if isShowingRequestedSession,
                   !viewModel.isLoading,
                   isInitialHistoryPending {
                    initialHistoryCompletionFallbackTask?.cancel()
                    completedInitialHistoryLoad = true
                    initialHistoryLoadWasRequired = false
                }
                if applyLatestBriefScrollIfNeeded(proxy: proxy) {
                    // The Summary doorway intentionally opens at the brief, not the newest reply.
                } else if !protectsLatestBriefAnchor, let last = viewModel.messages.last {
                    scrollToBottom(proxy: proxy, fallbackMessageId: last.id, animated: true)
                }
            }
            .onChange(of: effectiveBriefPreviewMarkdown) { _, _ in
                guard scrollToLatestBrief else { return }
                didApplyLatestBriefScroll = false
                latestBriefAnchorMessageIdentity = nil
                _ = applyLatestBriefScrollIfNeeded(proxy: proxy)
            }
            .onDisappear {
                initialHistoryCompletionFallbackTask?.cancel()
            }
            .onChange(of: viewModel.streamingAssistantText) { _, newText in
                if let newText {
                    briefAnchorAllowsBottomFollowing = true
                    cachedStreamingText = newText
                    cachedStreamingOriginUserAnchor = StreamingAssistantHandoffPolicy.latestUserAnchor(
                        in: streamingAssistantHandoffHistory
                    )
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                } else {
                    if cachedStreamingText != nil,
                       StreamingAssistantHandoffPolicy.shouldClearCachedText(
                           originatingUserAnchor: cachedStreamingOriginUserAnchor,
                           messages: streamingAssistantHandoffHistory
                       ) {
                        cachedStreamingText = nil
                        cachedStreamingOriginUserAnchor = nil
                    }
                    guard let last = viewModel.messages.last else { return }
                    scrollToBottom(proxy: proxy, fallbackMessageId: last.id, animated: false)
                }
            }
            .onChange(of: voiceTranscriptionState) { _, state in
                guard state != nil else { return }
                if case .idle? = state {
                    // Starting voice for brief playback is not a new conversational turn.
                    if protectsLatestBriefAnchor { return }
                } else {
                    briefAnchorAllowsBottomFollowing = true
                    if case .sent? = state {
                        // Talk Mode dispatches chat.send directly instead of using the composer
                        // acceptance closure. Its accepted transcript is the equivalent new-turn
                        // boundary, so an earlier handoff answer cannot attach to this voice turn.
                        cachedStreamingText = nil
                        cachedStreamingOriginUserAnchor = nil
                    }
                }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.pendingRunCount) { _, newCount in
                if newCount > 0 {
                    briefAnchorAllowsBottomFollowing = true
                }
            }
            .onChange(of: runActivityReconciliationIdentity) { previous, current in
                guard Self.shouldScrollToLiveActivity(
                    previousEffectiveRunCount: previous.effectiveRunCount,
                    currentEffectiveRunCount: current.effectiveRunCount
                ) else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            // Debounce the interrupted-turn card: only reveal it once the interrupted
            // SHAPE has held for ~1.2s. A healthy turn briefly looks idle-with-no-reply
            // in the window between the final event clearing the pending run and the
            // history refresh landing the assistant message — the sleep is cancelled
            // (id changes) before it can flash the card. When the shape clears, hide
            // immediately.
            .task(id: interruptedTurnSignature) {
                guard interruptedRetryPrompt != nil else {
                    interruptedAffordanceVisible = false
                    return
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                interruptedAffordanceVisible = true
            }
        }
    }

    private var bottomTranscriptInset: CGFloat {
        var inset: CGFloat = isVoiceModeActive ? 168 : 116
        // The pinned "Rem is using a browser" card sits above the composer and eats into the
        // transcript's visible bottom — add its height so the last messages aren't tucked under it.
        if browserLiveHere { inset += 72 }
        return inset
    }

    private var shouldRenderStreamingBeforeVoicePlaceholder: Bool {
        assistantTailPolicy.rendersStreamingBeforeVoicePlaceholder
    }

    private var hasStreamingAssistantText: Bool {
        guard let streaming = viewModel.streamingAssistantText ?? cachedStreamingText else {
            return false
        }
        return !streaming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Content-aware observation surface for the stream/history handoff. Message count alone is
    /// insufficient because authoritative refreshes can replace, deduplicate, reorder, or shrink
    /// rows without changing the count.
    private var streamingAssistantHandoffHistory: [StreamingAssistantHandoffPolicy.MessageSnapshot] {
        visibleMessages.map { message in
            StreamingAssistantHandoffPolicy.MessageSnapshot(
                role: message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                userFingerprint: Self.userRefreshFingerprint(message),
                hasFinalAssistantContent: Self.assistantHasFinalContent(message)
            )
        }
    }

    /// Mirrors pinned OpenClaw's timestamp-free `userRefreshIdentityKey`. History replaces the
    /// optimistic user row with a canonical timestamp (and therefore a new UUID), but this content
    /// fingerprint remains stable across that reconciliation. The handoff policy anchors it as the
    /// latest user turn rather than assigning a prefix-sensitive occurrence ordinal.
    private static func userRefreshFingerprint(_ message: OpenClawChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role == "user" else { return nil }
        let content = message.content.map { item in
            let type = (item.type ?? "text").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawText = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedText = MessageCleaner.cleanUserMessageText(rawText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = isSyntheticAttachmentPlaceholder(cleanedText) ? "" : cleanedText
            let id = (item.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = (item.fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [type, text, id, name, fileName].joined(separator: "\u{001F}")
        }.joined(separator: "\u{001E}")
        let toolCallID = (message.toolCallId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = (message.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !toolCallID.isEmpty || !toolName.isEmpty else { return nil }
        return [role, toolCallID, toolName, content].joined(separator: "|")
    }

    @ViewBuilder
    private var assistantTailContent: some View {
        if assistantTailPolicy.showsStreamingBubble,
           let streaming = viewModel.streamingAssistantText ?? cachedStreamingText {
            streamingBubble(streaming)
                .id("streaming")
        }
        if assistantTailPolicy.showsWorkingIndicator {
            typingIndicator
                .id("typing")
        }
    }

    // MARK: - Interrupted Turn

    /// The prompt to re-send when the trailing turn looks INTERRUPTED, or nil when
    /// the conversation is healthy / still working. Two gates combine:
    ///  1. The session is IDLE and quiescent — no pending run, not sending, not
    ///     loading, no live stream, no voice activity, gateway connected. A healthy
    ///     in-flight turn (pending run, streaming dots, or cached final chunk) never
    ///     reaches the shape check, so it can't be mislabeled.
    ///  2. The message SHAPE of the trailing turn is incomplete — see
    ///     `Self.interruptedTurnRetryPrompt`, the pure, unit-tested predicate.
    private var interruptedRetryPrompt: String? {
        guard !viewModel.isSending,
              viewModel.pendingRunCount == 0,
              !viewModel.isLoading,
              !hasStreamingAssistantText,
              !isVoiceThinking,
              voiceTranscriptionState == nil,
              !isWaking
        else { return nil }
        return Self.interruptedTurnRetryPrompt(viewModel.messages)
    }

    /// Stable key for the debounce `.task(id:)`. Changes whenever the interrupted
    /// verdict or the trailing turn changes, so the debounce restarts (and its
    /// pending reveal is cancelled) exactly when it should.
    private var interruptedTurnSignature: String {
        "\(viewModel.sessionKey)|\(viewModel.messages.count)|\(interruptedRetryPrompt ?? "∅")"
    }

    private func interruptedTurnCard(prompt: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(DesignTokens.Color.systemYellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Response interrupted")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                Text("Rem didn't finish replying.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Button {
                retryInterruptedTurn(prompt: prompt)
            } label: {
                Text("Retry")
                    .font(DesignTokens.Typography.caption1Bold)
                    .foregroundStyle(DesignTokens.Color.brandBlue)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("interrupted-turn-retry")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.Color.systemYellow.opacity(0.15),
            in: .rect(cornerRadius: DesignTokens.CornerRadius.medium)
        )
    }

    /// Re-send the preserved prompt through the normal send path so the retry works
    /// even if the gateway persisted nothing of the interrupted turn. Clears the
    /// stale error + hides the card first so the state doesn't linger under the new run.
    private func retryInterruptedTurn(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        interruptedAffordanceVisible = false
        viewModel.errorText = nil
        viewModel.input = trimmed
        sendIfReady()
    }

    @ViewBuilder
    private var voiceTranscriptionPlaceholder: some View {
        if let state = voiceTranscriptionState {
            switch state {
            case .transcribing(let partial):
                VStack(alignment: .trailing, spacing: 4) {
                    voiceLabel(isLive: true)
                    speechBubble(texts: [partial], isUser: true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .id("voice-transcription")
            case .sent(let text):
                // Compare against the *cleaned* user-message text so the
                // placeholder disappears as soon as the real message arrives
                // via history refresh. The raw `$0.text` carries gateway
                // metadata + Talk Mode prompt prefixes, which never equal the
                // raw transcript — matching without cleaning left a sticky
                // placeholder bubble with a fixed `voice-transcription` id
                // that visually "updated in place" across turns instead of
                // yielding to each turn's real bubble (#253).
                if !viewModel.messages.contains(where: { message in
                    guard message.role == "user" else { return false }
                    return message.content.contains(where: { content in
                        guard let raw = content.text else { return false }
                        return MessageCleaner.cleanUserMessageText(raw) == text
                    })
                }) {
                    VStack(alignment: .trailing, spacing: 4) {
                        voiceLabel(isLive: false)
                        speechBubble(texts: [text], isUser: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .id("voice-transcription")
                }
            case .idle:
                EmptyView()
            }
        }
    }

    private func scrollRestoredHistoryToBottomIfNeeded(proxy: ScrollViewProxy) {
        guard !protectsLatestBriefAnchor else { return }
        guard restoredHistoryScrollState.shouldStartScroll(
            isLoading: viewModel.isLoading,
            sessionKey: viewModel.sessionKey,
            messageCount: viewModel.messages.count,
            lastMessageIdentity: viewModel.messages.last.map { "\($0.id)" }
        ) else { return }

        restoredHistoryScrollTask?.cancel()
        let sessionKey = viewModel.sessionKey
        restoredHistoryScrollTask = Task { @MainActor in
            let delays: [UInt64] = [0, 80_000_000, 250_000_000]
            for delay in delays {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      viewModel.sessionKey == sessionKey,
                      !viewModel.isLoading
                else { return }
                if applyLatestBriefScrollIfNeeded(proxy: proxy) { return }
                scrollToBottom(proxy: proxy, fallbackMessageId: viewModel.messages.last?.id, animated: false)
            }
        }
    }

    private var protectsLatestBriefAnchor: Bool {
        scrollToLatestBrief && didApplyLatestBriefScroll && !briefAnchorAllowsBottomFollowing
    }

    @discardableResult
    private func applyLatestBriefScrollIfNeeded(proxy: ScrollViewProxy) -> Bool {
        guard scrollToLatestBrief,
              let briefPreviewMarkdown = effectiveBriefPreviewMarkdown,
              let messageID = Self.latestExactBriefMessageID(
                  in: visibleMessages,
                  matching: briefPreviewMarkdown,
                  requiresCurrentDay: resolvedBriefMarkdown.wrappedValue == nil
              )
        else { return false }
        let candidateIdentity = "\(messageID)"
        guard latestBriefAnchorMessageIdentity != candidateIdentity else { return false }
        didApplyLatestBriefScroll = true
        latestBriefAnchorMessageIdentity = candidateIdentity
        proxy.scrollTo(messageID, anchor: .top)
        return true
    }

    static func latestExactBriefMessageID(
        in messages: [OpenClawChatMessage],
        matching expectedMarkdown: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        requiresCurrentDay: Bool = true
    ) -> OpenClawChatMessage.ID? {
        let expected = MessageCleaner.cleanAssistantMessageText(expectedMarkdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return nil }
        let candidates = messages.filter { message in
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isToday = ChatMessageSeparatorPolicy.isToday(
                message,
                now: now,
                calendar: calendar
            )
            // `requiresCurrentDay == false` is used only after `/brief` authorized the exact
            // canonical durable artifact. Its account-local day may differ from this device's
            // calendar on a late tap, so timestamp presentation cannot override that authority.
            let timestampIsEligible = !requiresCurrentDay || isToday
            return (role == "assistant" || role == "model")
                && timestampIsEligible
                && assistantTextForBriefAnchor(message) == expected
        }
        // A resolved `/brief` can be projected into the visible transcript before refreshed
        // history supplies its timestamp. Prefer that authorized visible projection over an
        // older timestamped artifact with identical prose. Otherwise choose the newest authored
        // timestamp rather than trusting transport array order; equal/nil candidates keep the
        // latest visible occurrence.
        if let projected = candidates.last(where: { $0.timestamp == nil }) {
            return projected.id
        }
        return candidates.enumerated().max { lhs, rhs in
            let leftTimestamp = lhs.element.timestamp ?? -.infinity
            let rightTimestamp = rhs.element.timestamp ?? -.infinity
            if leftTimestamp == rightTimestamp {
                return lhs.offset < rhs.offset
            }
            return leftTimestamp < rightTimestamp
        }?.element.id
    }

    static func briefSuggestionAnchorMessageID(
        sessionKey: String,
        messages: [OpenClawChatMessage],
        briefMarkdown: String?,
        suggestionCount: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> OpenClawChatMessage.ID? {
        guard BriefContext.isDurableOrchestratorSession(sessionKey),
              suggestionCount > 0,
              let briefMarkdown,
              !briefMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return latestExactBriefMessageID(
            in: messages,
            matching: briefMarkdown,
            now: now,
            calendar: calendar
        )
    }

    private var shouldShowSuggestionsAfterPreview: Bool {
        Self.shouldShowSuggestionsAfterPreview(
            sessionKey: viewModel.sessionKey,
            snapshot: orchestratorSuggestionSnapshot,
            showsBriefPreviewBridge: showsBriefPreviewBridge
        )
    }

    private var shouldShowStandaloneSuggestions: Bool {
        Self.shouldShowStandaloneSuggestions(
            sessionKey: viewModel.sessionKey,
            snapshot: orchestratorSuggestionSnapshot
        )
    }

    static func shouldShowStandaloneSuggestions(
        sessionKey: String,
        snapshot: OrchestratorSuggestionSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let snapshot = validatedOrchestratorSuggestionSnapshot(
            sessionKey: sessionKey,
            snapshot: snapshot,
            now: now,
            calendar: calendar
        ) else { return false }
        return snapshot.briefMarkdown == nil
    }

    static func shouldShowSuggestionsAfterPreview(
        sessionKey: String,
        snapshot: OrchestratorSuggestionSnapshot?,
        showsBriefPreviewBridge: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        validatedOrchestratorSuggestionSnapshot(
            sessionKey: sessionKey,
            snapshot: snapshot,
            now: now,
            calendar: calendar
        ) != nil && showsBriefPreviewBridge
    }

    static func validatedOrchestratorSuggestionSnapshot(
        sessionKey: String,
        snapshot: OrchestratorSuggestionSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> OrchestratorSuggestionSnapshot? {
        guard BriefContext.isDurableOrchestratorSession(sessionKey),
              let snapshot,
              snapshot.isCurrentLocalDay(now: now, calendar: calendar)
        else { return nil }
        return snapshot
    }

    private var currentOrchestratorSuggestionSnapshot: OrchestratorSuggestionSnapshot? {
        Self.validatedOrchestratorSuggestionSnapshot(
            sessionKey: viewModel.sessionKey,
            snapshot: orchestratorSuggestionSnapshot
        )
    }

    @ViewBuilder
    private var orchestratorSuggestionBlock: some View {
        if let snapshot = currentOrchestratorSuggestionSnapshot,
           let onAcceptSuggestion,
           let onDismissSuggestion {
            // One shared component with the Agenda's two suggestion surfaces. The bespoke header
            // this used to carry is gone: its subtext restated what the row's own ✕ and Add button
            // already say, and its title differed from the Agenda's, which made the same list read
            // as a different feature per screen.
            //
            // `briefMarkdown` is what makes the bounded inline set *contextual to the brief* rather
            // than the first three the deriver emitted — see `SuggestionBriefRelevance`.
            SharedSuggestionSection(
                suggestions: snapshot.suggestions,
                briefMarkdown: snapshot.briefMarkdown,
                isShowingAll: $isShowingAllSuggestions,
                onAccept: onAcceptSuggestion,
                onDismiss: onDismissSuggestion
            )
        }
    }

    private static func assistantTextForBriefAnchor(_ message: OpenClawChatMessage) -> String {
        let raw = message.content.compactMap { item -> String? in
            let type = (item.type ?? "text").lowercased()
            guard type == "text" else { return nil }
            return item.text
        }.joined(separator: "\n")
        return MessageCleaner.cleanAssistantMessageText(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scrollToBottom(
        proxy: ScrollViewProxy,
        fallbackMessageId: OpenClawChatMessage.ID?,
        animated: Bool
    ) {
        let action = {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
    }

    // MARK: - Empty State

    private var effectiveBriefPreviewMarkdown: String? {
        resolvedBriefMarkdown.wrappedValue
            ?? currentOrchestratorSuggestionSnapshot?.briefMarkdown
            ?? briefPreviewMarkdown
    }

    private var showsBriefPreviewBridge: Bool {
        guard BriefContext.isBriefSession(viewModel.sessionKey),
              let preview = effectiveBriefPreviewMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty
        else { return false }
        let requiresCurrentDay = resolvedBriefMarkdown.wrappedValue == nil
        return Self.latestExactBriefMessageID(
            in: viewModel.messages,
            matching: preview,
            requiresCurrentDay: requiresCurrentDay
        ) == nil
    }

    static func hasExactBriefToday(
        _ messages: [OpenClawChatMessage],
        matching expectedMarkdown: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        latestExactBriefMessageID(
            in: messages,
            matching: expectedMarkdown,
            now: now,
            calendar: calendar
        ) != nil
    }

    static func briefPreviewInsertionIndex(
        in messages: [OpenClawChatMessage],
        matching expectedMarkdown: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        guard !hasExactBriefToday(
            messages,
            matching: expectedMarkdown,
            now: now,
            calendar: calendar
        ) else { return nil }
        return messages.firstIndex {
            ChatMessageSeparatorPolicy.isToday($0, now: now, calendar: calendar)
        } ?? messages.endIndex
    }

    /// Separator labels for the whole transcript, keyed by message index.
    ///
    /// Resolved as one pass rather than per row so an untimestamped message cannot break a group:
    /// comparing each row against only `messages[index - 1]` would treat a `nil` timestamp as "no
    /// previous message" and open a spurious group on the row after it. The fold carries the last
    /// timestamp it trusts, which is also the behaviour the policy tests pin.
    static func separatorLabels(
        in messages: [OpenClawChatMessage],
        briefPreviewInsertionIndex: Int?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [Int: String] {
        var labels = ChatTimeSeparatorPolicy.separators(
            for: messages.map { ChatTimeSeparatorPolicy.date(from: $0.timestamp) },
            now: now,
            calendar: calendar,
            locale: locale
        )
        // The brief-preview bridge already carries its own "Today" heading at this index; a
        // separator immediately above it would state the same boundary twice.
        if let briefPreviewInsertionIndex {
            labels[briefPreviewInsertionIndex] = nil
        }
        return labels
    }

    @ViewBuilder
    private var briefPreviewBridge: some View {
        if let preview = effectiveBriefPreviewMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Today")
                    .font(DesignTokens.Typography.chatMeta.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                    .frame(maxWidth: .infinity)
                speechBubble(texts: [preview], isUser: false)
            }
            .padding(.vertical, DesignTokens.Spacing.md)
            .accessibilityIdentifier("TodayBriefPreviewBridge")
        }
    }

    private var emptyState: some View {
        emptyStateBody(suppressingStarterIDs: [])
    }

    /// Starter IDs already on screen as suggestion rows, so the empty state can drop exactly those
    /// and keep the rest.
    ///
    /// Not "suppress all starters": a derived starter carries its suggestion's `key` as its id
    /// (`starters(from:)`), but the **generic fallback set is not derived from anything** and its
    /// ids are `plan-day` / `turn-into-tasks` / `reminder`. Blanket suppression stripped the
    /// starters from every Mac chat — `MacChatWindow` never passes `starterPrompts`, so Mac always
    /// gets the generic set — and from iOS too whenever a snapshot holds only reschedule
    /// suggestions, since `starters(from:)` filters to `createTask` and `StarterObserver` falls
    /// back to the generic set. Matching on id suppresses the actual duplicates and nothing else.
    private var starterIDsShownAsSuggestions: Set<String> {
        Set(currentOrchestratorSuggestionSnapshot?.suggestions.map(\.key) ?? [])
    }

    /// Starters that are not already on screen as suggestion rows.
    ///
    /// Static and pure so the rule is executable in a plain test — a blanket "hide the starters"
    /// silently emptied the Mac chat's empty state, and that class of regression should be caught
    /// by running the rule, not by grepping for it.
    static func visibleStarters(
        from starters: [FirstChatPrompt],
        suppressingIDs suppressed: Set<String>
    ) -> [FirstChatPrompt] {
        guard !suppressed.isEmpty else { return starters }
        return starters.filter { !suppressed.contains($0.id) }
    }

    @ViewBuilder
    private func emptyStateBody(suppressingStarterIDs suppressed: Set<String>) -> some View {
        let visibleStarters = Self.visibleStarters(from: starterPrompts, suppressingIDs: suppressed)
        let showsStarters = !visibleStarters.isEmpty
        VStack(spacing: DesignTokens.Spacing.md) {
            RemFaceMark(mode: .idle, tint: DesignTokens.Color.brandBlue, size: 72)
            Text("Start a conversation")
                .font(DesignTokens.Typography.title3Bold)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Text(showsStarters ? Self.emptyStateSubtitleWithStarters : Self.emptyStateSubtitlePlain)
                // Bumped caption1 -> subheadline: the empty-state subtitle read too small under
                // the title. Subheadline keeps it secondary to the title but comfortably legible.
                .font(DesignTokens.Typography.subheadline)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .multilineTextAlignment(.center)

            if showsStarters {
                VStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(visibleStarters) { prompt in
                        Button {
                            viewModel.input = prompt.text
                            isInputFocused = true
                        } label: {
                            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                                // Leading sparkle removed: the brand-blue Rem face at the top of
                                // the empty state is now the mark, so each suggestion row is just
                                // its label (no per-row icon).
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(prompt.text)
                                        // Body size (was caption1): starters are the first thing in an
                                        // empty chat, so they read as prominent, branded prompts — with
                                        // the caption1 subtitle below giving a clear size hierarchy.
                                        .font(DesignTokens.Typography.body)
                                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                                        .multilineTextAlignment(.leading)
                                    // WHY/source line for personalized starters (nil on the generic set).
                                    if let subtitle = prompt.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(DesignTokens.Typography.caption1)
                                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(DesignTokens.Spacing.sm)
                            .background(DesignTokens.Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("FirstChatPrompt-\(prompt.id)")
                    }
                }
                .padding(.top, DesignTokens.Spacing.sm)
                .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, 80)
        .accessibilityIdentifier("FirstChatEmptyState")
    }

    private static let emptyStateSubtitlePlain = "Say what you want Rem to help organize."
    private static let emptyStateSubtitleWithStarters =
        "Try one of these, or say what you want Rem to help organize."

    // MARK: - Message Row

    /// True when a transcript message is a tool RESULT (tool output), which must
    /// render as a collapsed artifact via `ToolResultCardView` — never as an
    /// assistant speech bubble.
    ///
    /// OpenClaw's agent transcript stores tool results as a *separate* top-level
    /// message whose canonical role is `"toolResult"` (camelCase — see
    /// `openclaw/src/agents/*` and the gateway's `chat-display-projection.ts`
    /// preserve list: `toolresult | tool_result | tool | function`). The gateway
    /// preserves that role verbatim in `chat.history`. The old check compared the
    /// role to the lowercase literal `"toolresult"`, so a `"toolResult"` message
    /// never matched: it fell through to `splitContent`, and because a file-read
    /// payload (YAML frontmatter + markdown body) is not a JSON object, it landed
    /// in `textBlocks` and was dumped as a raw chat bubble (e.g. reading a
    /// `SKILL.md`). Match all tool-result role variants case-insensitively so the
    /// result is routed to the collapsible tool-result renderer instead.
    static func isToolResultRole(_ role: String) -> Bool {
        switch role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "toolresult", "tool_result", "tool", "function":
            return true
        default:
            return false
        }
    }

    // MARK: - Interrupted Turn Detection (pure)

    /// Best-effort terminal stop reasons that mean a turn was cut off rather than
    /// finished. Consulted ONLY as a secondary tiebreaker for a content-less turn —
    /// see `assistantTurnCompleted` — never to veto a turn that produced content.
    static let abortedStopReasons: Set<String> = [
        "aborted", "cancelled", "canceled", "interrupted", "error", "timeout",
    ]

    /// Classifies the SHAPE of the trailing turn and returns the user prompt to
    /// re-send when it looks INTERRUPTED, or nil when it looks complete. Pure over
    /// the transcript — the view ANDs this with idle/quiescent gating
    /// (`interruptedRetryPrompt`) so a healthy in-flight turn never reaches here.
    ///
    /// Detection is HEURISTIC, keyed on content presence (see `assistantTurnCompleted`).
    /// It is NOT a structured-signal classifier: `OpenClawChatMessage.stopReason` is
    /// only populated when the gateway's `chat.history` JSON happens to carry it
    /// per-message — the live chat-event path (`OpenClawChatEventPayload`) has no
    /// stop reason and building it in would require editing the read-only `openclaw`
    /// submodule — so it is frequently nil and used only as a best-effort secondary.
    ///
    /// Interrupted shapes:
    ///  - trailing message is a `user` turn with no assistant reply at all; or
    ///  - trailing message is an `assistant`/`model` turn that produced no final
    ///    content (only reasoning / empty) and carries no terminal stop reason.
    /// Complete shapes (return nil): empty transcript; a trailing tool-result
    /// message (the agent legitimately ended on an action); an assistant turn with
    /// any visible final content — text OR media — or a terminal stop reason.
    static func interruptedTurnRetryPrompt(_ messages: [OpenClawChatMessage]) -> String? {
        guard let last = messages.last else { return nil }

        if isToolResultRole(last.role) { return nil }

        let role = last.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch role {
        case "user":
            return lastUserPromptText(messages)
        case "assistant", "model":
            if assistantTurnCompleted(last) { return nil }
            return lastUserPromptText(messages)
        default:
            return nil
        }
    }

    /// Whether the trailing assistant turn produced an answer.
    ///
    /// PRIMARY, robust signal: content presence — any visible text OR produced media
    /// (image/file/attachment). A content-bearing turn is ALWAYS complete, so a
    /// healthy media-only reply (a text-free image, nil stop reason) is never flagged.
    /// SECONDARY, best-effort: for a content-LESS turn (reasoning-only / empty), a
    /// terminal non-aborted `stopReason` also marks it complete. The stop reason can
    /// only ADD completions here, never veto a content-bearing turn — so a frequently
    /// nil stop reason (see `interruptedTurnRetryPrompt`) can't cause a false positive.
    static func assistantTurnCompleted(_ message: OpenClawChatMessage) -> Bool {
        if assistantHasFinalContent(message) { return true }
        if let stop = message.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !stop.isEmpty,
           !abortedStopReasons.contains(stop) {
            return true
        }
        return false
    }

    /// True when the message carries at least one visible, non-reasoning, non-tool
    /// piece of FINAL content — real text OR produced media (image/file/attachment).
    /// A text-free image/attachment reply counts as an answer, so a healthy media-only
    /// turn is never mistaken for an interruption.
    static func assistantHasFinalContent(_ message: OpenClawChatMessage) -> Bool {
        for item in message.content {
            switch (item.type ?? "text").lowercased() {
            case "thinking", "toolcall", "tool_call", "tooluse", "tool_use",
                 "toolresult", "tool_result":
                continue
            default:
                // A tool-call carrier (name+args) is plumbing, not an answer.
                if item.name != nil, item.arguments != nil { continue }
                // Any visible text is an answer.
                if let text = item.text,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                // Any produced media payload (file/attachment/image) is an answer too.
                if item.content != nil || item.fileName != nil || item.mimeType != nil {
                    return true
                }
            }
        }
        return false
    }

    static func terminalAssistantTimestamp(_ message: OpenClawChatMessage) -> Double? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (role == "assistant" || role == "model"),
              assistantHasFinalContent(message),
              !messageCarriesActivityEvidence(message)
        else { return nil }
        return message.timestamp
    }

    static func updatedCompletedRunElapsedSeconds(
        current: Int?,
        turnStartedAt: Double?,
        message: OpenClawChatMessage,
        carriesActivity: Bool
    ) -> Int? {
        var resolved = carriesActivity ? nil : current
        if !carriesActivity,
           let terminalTimestamp = terminalAssistantTimestamp(message),
           let elapsed = ActionLifecycleDisclosure.resolvedElapsedSeconds(
               from: turnStartedAt,
               through: terminalTimestamp
           ) {
            resolved = elapsed
        }
        return resolved
    }

    /// The persisted user timestamp marks when intent arrived, not when the agent started work.
    /// Delayed delivery, suspension, or an overnight gateway wake can put hours between those two
    /// events. Start historical elapsed time at the first activity-bearing message instead.
    static func historicalActivityStartTimestamp(
        current: Double?,
        messageTimestamp: Double?,
        carriesActivity: Bool
    ) -> Double? {
        if let current { return current }
        guard carriesActivity,
              let messageTimestamp,
              messageTimestamp.isFinite,
              messageTimestamp > 0
        else { return nil }
        return messageTimestamp
    }

    /// The cleaned text of the most recent `user` message — the prompt Retry
    /// re-sends. Cleaning mirrors the display path so hidden preambles
    /// (device-context, brief, cloud-browser directive) never leak into the resend.
    static func lastUserPromptText(_ messages: [OpenClawChatMessage]) -> String? {
        for message in messages.reversed()
        where message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" {
            for item in message.content {
                guard let raw = item.text else { continue }
                let cleaned = MessageCleaner.cleanUserMessageText(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    struct RunActivityReconciliationIdentity: Equatable {
        let effectiveRunCount: Int
        let pendingToolCallIDs: [String]
        let browserCardPresentation: BrowserCardPresentation
        let streamingThinkingSummaries: [String]
        let activeTransportRunIDs: [String]
        let localRegisteredRunIDs: [String]
        let historyOwnedObservationIDs: [String]
        let historyOwnershipCounts: [String: Int]
        let transportLifecycleRevision: Int
    }

    private var currentRunActivityReducerInput: RunActivityAccumulator.Input {
        return Self.makeRunActivityReducerInput(
            runCount: viewModel.pendingRunCount,
            sessionKey: viewModel.sessionKey,
            observations: pendingRunActivityObservations,
            suppressedObservationIDs: suppressedPendingRunActivityIDs,
            activeTransportRunIDs: runLifecycleEvidenceStore?.activeRunIDs(
                for: viewModel.sessionKey
            ) ?? [],
            localRegisteredRunIDs: runLifecycleEvidenceStore?.localRunIDs(
                for: viewModel.sessionKey
            ) ?? [],
            historyOwnedObservationIDs: historicalActivityObservationIDs,
            historyOwnershipCounts: historicalActivityOwnershipCounts
        )
    }

    static func makeRunActivityReducerInput(
        runCount: Int,
        sessionKey: String,
        observations: [RunActivityAccumulator.Observation],
        suppressedObservationIDs: Set<String> = [],
        activeTransportRunIDs: Set<String> = [],
        localRegisteredRunIDs: Set<String> = [],
        historyOwnedObservationIDs: Set<String> = [],
        historyOwnershipCounts: [String: Int] = [:]
    ) -> RunActivityAccumulator.Input {
        RunActivityAccumulator.Input(
            runCount: runCount,
            sessionKey: sessionKey,
            observations: observations,
            suppressedObservationIDs: suppressedObservationIDs,
            activeTransportRunIDs: activeTransportRunIDs,
            localRegisteredRunIDs: localRegisteredRunIDs,
            historyOwnedObservationIDs: historyOwnedObservationIDs,
            historyOwnershipCounts: historyOwnershipCounts
        )
    }

    private var runActivityReconciliationIdentity: RunActivityReconciliationIdentity {
        let input = currentRunActivityReducerInput
        return Self.runActivityReconciliationIdentity(
            effectiveRunCount: input.effectiveRunCount,
            pendingToolCallIDs: viewModel.pendingToolCalls.map(\.toolCallId),
            browserCardPresentation: browserCardPresentation,
            streamingThinkingSummaries: streamingThinkingActivityObservations.map {
                $0.display.liveText
            },
            activeTransportRunIDs: input.activeTransportRunIDs.sorted(),
            localRegisteredRunIDs: input.localRegisteredRunIDs.sorted(),
            historyOwnedObservationIDs: input.historyOwnedObservationIDs.sorted(),
            historyOwnershipCounts: input.historyOwnershipCounts,
            transportLifecycleRevision: runLifecycleEvidenceStore?.revision ?? 0
        )
    }

    static func runActivityReconciliationIdentity(
        effectiveRunCount: Int,
        pendingToolCallIDs: [String],
        browserCardPresentation: BrowserCardPresentation,
        streamingThinkingSummaries: [String],
        activeTransportRunIDs: [String] = [],
        localRegisteredRunIDs: [String] = [],
        historyOwnedObservationIDs: [String] = [],
        historyOwnershipCounts: [String: Int] = [:],
        transportLifecycleRevision: Int = 0
    ) -> RunActivityReconciliationIdentity {
        RunActivityReconciliationIdentity(
            effectiveRunCount: effectiveRunCount,
            pendingToolCallIDs: pendingToolCallIDs.sorted(),
            browserCardPresentation: browserCardPresentation,
            streamingThinkingSummaries: streamingThinkingSummaries,
            activeTransportRunIDs: activeTransportRunIDs.sorted(),
            localRegisteredRunIDs: localRegisteredRunIDs.sorted(),
            historyOwnedObservationIDs: historyOwnedObservationIDs.sorted(),
            historyOwnershipCounts: historyOwnershipCounts,
            transportLifecycleRevision: transportLifecycleRevision
        )
    }

    private var historicalActivityOwnershipCounts: [String: Int] {
        historicalTurnActivities.values.reduce(into: [String: Int]()) { counts, activity in
            for display in activity.displays {
                counts[RunActivityAccumulator.ownershipKey(for: display), default: 0]
                    += display.occurrenceCount
            }
        }
    }

    private var historicalActivityObservationIDs: Set<String> {
        visibleMessages.reduce(into: Set<String>()) { ids, message in
            guard Self.messageCarriesActivityEvidence(message) else { return }
            if let toolCallID = message.toolCallId?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !toolCallID.isEmpty {
                ids.insert(toolCallID)
            }
            for content in message.content {
                if let id = content.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !id.isEmpty
                {
                    ids.insert(id)
                }
            }
        }
    }

    private var pendingRunActivityObservations: [RunActivityAccumulator.Observation] {
        let tools: [RunActivityAccumulator.Observation] = viewModel.pendingToolCalls
            .sorted {
                let lhsStartedAt = $0.startedAt ?? .greatestFiniteMagnitude
                let rhsStartedAt = $1.startedAt ?? .greatestFiniteMagnitude
                if lhsStartedAt == rhsStartedAt { return $0.toolCallId < $1.toolCallId }
                return lhsStartedAt < rhsStartedAt
            }
            .compactMap { tool -> RunActivityAccumulator.Observation? in
                guard !Self.shouldSuppressPendingBrowserLifecycleActivity(
                    toolName: tool.name,
                    cardPresentation: browserCardPresentation
                ) else { return nil }
                return RunActivityAccumulator.Observation(
                    id: tool.toolCallId,
                    display: resolveToolCallDisplay(name: tool.name, args: tool.args, phase: .live)
                )
            }
        return streamingThinkingActivityObservations + tools
    }

    private var suppressedPendingRunActivityIDs: Set<String> {
        let pendingBrowserToolCallIDs = Set(viewModel.pendingToolCalls.compactMap { tool -> String? in
            Self.isBrowserLifecycleTool(tool.name) ? tool.toolCallId : nil
        })
        return Self.suppressedRunActivityIDs(
            pendingBrowserToolCallIDs: pendingBrowserToolCallIDs,
            activeBrowserRunEvidences: activeBrowserRunEvidences,
            cardPresentation: browserCardPresentation
        )
    }

    /// Browser starts outlive `pendingToolCalls`: the result event may remove a
    /// call before SwiftUI observes the card becoming live. Include the durable
    /// run evidence IDs so reconciliation can still evict the retained step.
    static func suppressedRunActivityIDs(
        pendingBrowserToolCallIDs: Set<String>,
        activeBrowserRunEvidences: [BrowserRunEvidence],
        cardPresentation: BrowserCardPresentation
    ) -> Set<String> {
        guard cardPresentation == .live else { return [] }
        return pendingBrowserToolCallIDs.union(
            activeBrowserRunEvidences
                .filter(\.runIsActive)
                .flatMap(\.observedToolCallIDs)
        )
    }

    /// Only summaries already emitted into the user-visible streaming payload
    /// join Activity. Runtime diagnostics keep their dedicated recovery UI, and
    /// no private or synthesized chain-of-thought is created here.
    private var streamingThinkingActivityObservations: [RunActivityAccumulator.Observation] {
        guard let streaming = viewModel.streamingAssistantText ?? cachedStreamingText else {
            return []
        }
        return Self.streamingThinkingActivityObservations(from: streaming)
    }

    static func streamingThinkingActivityObservations(
        from streaming: String
    ) -> [RunActivityAccumulator.Observation] {
        Self.parseStreamingText(streaming).enumerated().compactMap { index, segment in
            guard case .thinking = segment.kind else { return nil }
            guard let display = Self.streamingThinkingActivityDisplay(from: segment.text) else {
                return nil
            }
            return RunActivityAccumulator.Observation(
                id: "streaming-thinking-\(index)",
                display: display
            )
        }
    }

    static func streamingThinkingActivityDisplay(from rawText: String) -> ActionLifecycleDisplay? {
        let cleanedText = Self.cleanThinkingTextForDisplay(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty,
              !SharedChatDiagnosticDisplay.isRuntimeDiagnostic(cleanedText)
        else { return nil }
        return ActionLifecycleDisplay(
            sfSymbol: "lightbulb",
            text: cleanedText,
            tint: DesignTokens.Color.labelTertiary
        )
    }

    private func synchronizeRunActivityAccumulator() {
        runActivityAccumulator.reconcile(currentRunActivityReducerInput)
    }

    nonisolated static func messageCarriesActivityEvidence(_ message: OpenClawChatMessage) -> Bool {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if role == "toolresult" || role == "tool_result" || role == "tool" || role == "function" {
            return true
        }
        return message.content.contains { item in
            switch (item.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "thinking", "toolcall", "tool_call", "tooluse", "tool_use", "toolresult", "tool_result":
                return true
            default:
                return item.name != nil && item.arguments != nil
            }
        }
    }


    @ViewBuilder
    private func messageRow(
        _ message: OpenClawChatMessage,
        turnActivity: HistoricalTurnActivity? = nil
    ) -> some View {
        let isUser = message.role == "user"
        let isToolResult = Self.isToolResultRole(message.role)

        if isToolResult {
            VStack(alignment: .leading, spacing: 6) {
                if let turnActivity, !turnActivity.displays.isEmpty {
                    actionDetails(
                        displays: turnActivity.displays,
                        sectionId: "\(message.id)-run-activity",
                        kind: .runActivity,
                        elapsedSeconds: turnActivity.elapsedSeconds
                    )
                }
                let standaloneContentIndexes = Self.standaloneToolResultContentIndexes(message)
                if !standaloneContentIndexes.isEmpty {
                    ToolResultCardView(
                        message: message,
                        messages: viewModel.messages,
                        contentIndexes: standaloneContentIndexes
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let parts = Self.splitContent(message.content, isUser: isUser)
            // When a user sends an image with EMPTY text, the upstream send path
            // synthesizes a "See attached." placeholder body (ChatViewModel.swift,
            // read-only submodule). That placeholder reads as spurious/duplicate
            // text next to the image, so suppress it when the same user message
            // already carries an image attachment — the photo speaks for itself
            // (matches ChatGPT/Claude image-only messages).
            let visibleTextBlocks = isUser && !parts.attachments.isEmpty
                ? parts.textBlocks.filter { !Self.isSyntheticAttachmentPlaceholder($0) }
                : parts.textBlocks
            // This user turn was sent with the "Cloud browser" chip (detected on the RAW content —
            // the directive block itself is stripped from the displayed text by MessageCleaner).
            let usedCloudBrowser = isUser && message.content.contains { BrowserDirective.isChipSend($0.text ?? "") }
            // This user turn came from a voice transcription (drives the same meta line).
            let isVoiceMessage = isUser
                && voiceTranscripts.map { transcripts in
                    parts.textBlocks.first.map { transcripts.contains(MessageCleaner.cleanUserMessageText($0)) } ?? false
                } == true
            let inlineToolResults = consolidatedInlineToolResults(parts.jsonToolResults)
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if let turnActivity, !turnActivity.displays.isEmpty {
                    actionDetails(
                        displays: turnActivity.displays,
                        sectionId: "\(message.id)-run-activity",
                        kind: .runActivity,
                        elapsedSeconds: turnActivity.elapsedSeconds
                    )
                }

                // Pairing recovery remains actionable even though diagnostic thoughts
                // now live inside the turn-level Activity disclosure.
                ForEach(Array(parts.thinking.enumerated()), id: \.offset) { _, text in
                    runtimePairingRecoveryCard(for: text, messageID: message.id)
                }

                // One meta line above the bubble — "Transcribed" and/or "Cloud browser", joined by a
                // "•" when both apply — at the same level as the voice-transcription label.
                if isVoiceMessage || usedCloudBrowser {
                    messageMetaLabel(voice: isVoiceMessage, cloudBrowser: usedCloudBrowser)
                }

                if !visibleTextBlocks.isEmpty {
                    speechBubble(texts: visibleTextBlocks, isUser: isUser)
                }

                ForEach(inlineToolResults) { result in
                    let parsed = ToolResultParser.parse(result.text)
                    if !parsed.isKnown, let imageMarkdown = UnknownToolContentProjection
                        .project(result.text).imageMarkdown {
                        AssistantMarkdownView(markdown: imageMarkdown)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                ForEach(Array(parts.attachments.enumerated()), id: \.offset) { _, content in
                    attachmentBadge(content, isUser: isUser)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    /// One transcript disclosure per user turn. OpenClaw may persist one run as
    /// several assistant/thinking/tool-result messages, so message-level grouping
    /// still produced a ladder of diagnostic rows.
    private struct HistoricalTurnActivity {
        var displays: [ActionLifecycleDisplay]
        var elapsedSeconds: Int?
    }

    private var historicalTurnActivities: [UUID: HistoricalTurnActivity] {
        var grouped: [UUID: [ActionLifecycleDisplay]] = [:]
        var elapsedByAnchor: [UUID: Int] = [:]
        var anchor: UUID?
        var activityStartedAt: Double?

        for message in visibleMessages {
            if message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" {
                anchor = nil
                activityStartedAt = nil
                continue
            }

            let displays = historicalActivityDisplays(for: message)
            activityStartedAt = Self.historicalActivityStartTimestamp(
                current: activityStartedAt,
                messageTimestamp: message.timestamp,
                carriesActivity: !displays.isEmpty)
            if !displays.isEmpty {
                if anchor == nil { anchor = message.id }
                if let anchor {
                    grouped[anchor, default: []].append(contentsOf: displays)
                    // Activity arriving after an assistant text fragment proves
                    // that fragment was not the terminal answer. Do not retain a
                    // partial duration if the refreshed turn never persists a
                    // later, timestamped final assistant response.
                }
            }
            if let anchor {
                if let elapsed = Self.updatedCompletedRunElapsedSeconds(
                    current: elapsedByAnchor[anchor],
                    turnStartedAt: activityStartedAt,
                    message: message,
                    carriesActivity: !displays.isEmpty
                ) {
                    elapsedByAnchor[anchor] = elapsed
                } else {
                    elapsedByAnchor.removeValue(forKey: anchor)
                }
            }
        }

        var consolidated: [UUID: HistoricalTurnActivity] = [:]
        for (messageID, displays) in grouped {
            consolidated[messageID] = HistoricalTurnActivity(
                displays: Self.consolidatedHistoricalActivityDisplays(displays),
                elapsedSeconds: elapsedByAnchor[messageID]
            )
        }
        return consolidated
    }

    private func historicalActivityDisplays(for message: OpenClawChatMessage) -> [ActionLifecycleDisplay] {
        let isBrowserCardTurn = browserCardTurnMessageIDs.contains(message.id)
        if Self.isToolResultRole(message.role) {
            return message.content.compactMap { content -> ActionLifecycleDisplay? in
                let rawText = Self.toolResultText(content)
                let toolName = content.name ?? message.toolName
                guard !rawText.isEmpty,
                      !Self.shouldSuppressHistoricalBrowserLifecycleActivity(
                          toolName: toolName,
                          isCardTurn: isBrowserCardTurn,
                          cardPresentation: browserCardPresentation
                      )
                else { return nil }
                let parsed = ToolResultParser.parse(rawText)
                if parsed.isKnown {
                    return Self.foldedKnownToolResultDisplay(parsed, text: rawText)
                }
                return Self.foldedUnknownToolResultDisplay(toolName: toolName, text: rawText)
            }
        }

        let parts = Self.splitContent(message.content, isUser: false)
        let thoughts = ThinkingBlockGrouping.group(parts.thinking).entries.map { entry in
            ActionLifecycleDisplay(
                sfSymbol: "lightbulb",
                text: entry.text,
                phase: .historical,
                tint: DesignTokens.Color.labelTertiary,
                occurrenceCount: entry.occurrences
            )
        }
        let unknownInlineResults = parts.jsonToolResults.compactMap { text -> ActionLifecycleDisplay? in
            Self.foldedUnknownToolResultDisplay(toolName: nil, text: text)
        }
        let knownInlineResults = parts.jsonToolResults.compactMap { text -> ActionLifecycleDisplay? in
            let parsed = ToolResultParser.parse(text)
            guard parsed.isKnown else { return nil }
            return Self.foldedKnownToolResultDisplay(parsed, text: text)
        }
        return thoughts + historicalActionDisplays(
            for: parts,
            isBrowserCardTurn: isBrowserCardTurn
        ) + knownInlineResults + unknownInlineResults
    }

    static func shouldFoldUnknownToolResult(toolName: String?, text: String) -> Bool {
        UnknownToolContentProjection.project(text).safeDetail != nil
    }

    private static func foldedToolResultDisplay(text: String) -> ActionLifecycleDisplay {
        ActionLifecycleDisplay(
            sfSymbol: "checkmark.circle",
            text: "Tool result",
            phase: .historical,
            tint: DesignTokens.Color.labelTertiary,
            detailText: text
        )
    }

    static func foldedKnownToolResultDisplay(
        _ parsed: ParsedToolResult,
        text: String
    ) -> ActionLifecycleDisplay? {
        let label: String
        let failed: Bool
        let detailText: String
        switch parsed {
        case .calendarEvents: (label, failed, detailText) = ("Checked calendar", false, text)
        case .calendarAdd: (label, failed, detailText) = ("Created event", false, text)
        case .calendarUpdate: (label, failed, detailText) = ("Updated event", false, text)
        case .calendarDelete: (label, failed, detailText) = ("Deleted event", false, text)
        case .remindersList: (label, failed, detailText) = ("Checked reminders", false, text)
        case .remindersAdd: (label, failed, detailText) = ("Set reminder", false, text)
        case .remindersUpdate: (label, failed, detailText) = ("Updated reminder", false, text)
        case .remindersDelete: (label, failed, detailText) = ("Deleted reminder", false, text)
        case .deviceStatus: (label, failed, detailText) = ("Checked device status", false, text)
        case .deviceInfo: (label, failed, detailText) = ("Got device info", false, text)
        case .taskCreate: (label, failed, detailText) = ("Created task", false, text)
        case .taskUpdate: (label, failed, detailText) = ("Updated task", false, text)
        case .taskDelete: (label, failed, detailText) = ("Deleted task", false, text)
        case .notifySuccess: (label, failed, detailText) = ("Sent notification", false, text)
        case .error(_, let errorMessage):
            (label, failed, detailText) = (
                "Tool failed",
                true,
                ErrorResultCard.privacyProjectedMessage(errorMessage)
            )
        case .unknown: return nil
        }
        return ActionLifecycleDisplay(
            sfSymbol: failed ? "exclamationmark.circle" : "checkmark.circle",
            text: label,
            historicalText: label,
            phase: .historical,
            tint: failed ? DesignTokens.Color.systemRed : DesignTokens.Color.labelTertiary,
            detailText: detailText
        )
    }

    static func toolResultNeedsStandalonePresentation(_ message: OpenClawChatMessage) -> Bool {
        !standaloneToolResultContentIndexes(message).isEmpty
    }

    static func standaloneToolResultContentIndexes(_ message: OpenClawChatMessage) -> Set<Int> {
        Set(message.content.enumerated().compactMap { index, content in
            let text = toolResultText(content)
            guard !text.isEmpty else { return nil }
            let parsed = ToolResultParser.parse(text)
            guard !parsed.isKnown else { return nil }
            let foldsIntoActivity = foldedUnknownToolResultDisplay(
                toolName: content.name ?? message.toolName,
                text: text
            ) != nil
            return foldsIntoActivity ? nil : index
        })
    }

    static func foldedUnknownToolResultDisplay(
        toolName: String?,
        text: String
    ) -> ActionLifecycleDisplay? {
        guard !ToolResultParser.parse(text).isKnown,
              shouldFoldUnknownToolResult(toolName: toolName, text: text),
              let sanitizedText = safeFoldedToolResultDetail(text)
        else { return nil }
        return foldedToolResultDisplay(text: sanitizedText)
    }

    /// Projects unknown result output into a privacy-safe detail. Plain-language
    /// user-facing summaries survive; diagnostic-only output and arbitrary
    /// structured envelopes do not. Known rich results are handled before this
    /// boundary, and image markdown remains on its dedicated visible path.
    static func safeFoldedToolResultDetail(_ text: String) -> String? {
        UnknownToolContentProjection.project(text).safeDetail
    }

    static func containsUnknownStructuredEnvelope(_ text: String) -> Bool {
        UnknownToolContentProjection.containsStructuredEnvelope(text)
    }

    static func activityDisclosureKind(isActive: Bool) -> ActionLifecycleDisclosure.Kind {
        isActive ? .toolActivity : .runActivity
    }

    /// The live run's disclosure — unlike a completed turn's, which is keyed by message id — reuses
    /// one section id for every turn in the conversation.
    static let liveRunActivitySectionID = "pending-tool-activity"

    /// Expansion state for the live "Working" disclosure across one reconciliation tick.
    ///
    /// Because `liveRunActivitySectionID` is shared by every turn, a new run must clear it:
    /// otherwise turn 2 would open itself simply because the user opened turn 1 — the same
    /// "expanded section I never opened" that #1278 reported. A run boundary (effective run count
    /// 0 -> >0) is the *only* thing that clears it. In particular the end of a run does not: the
    /// user who expanded a live timeline keeps it expanded while the run winds down and the reply
    /// lands. Every turn therefore starts collapsed, matching the completed per-message Activity
    /// disclosure, which starts collapsed because its id has never been seen before.
    static func reconcileLiveRunActivityExpansion(
        expandedSections: Set<String>,
        previousEffectiveRunCount: Int,
        currentEffectiveRunCount: Int
    ) -> Set<String> {
        guard previousEffectiveRunCount == 0, currentEffectiveRunCount > 0 else {
            return expandedSections
        }
        var updated = expandedSections
        updated.remove(liveRunActivitySectionID)
        return updated
    }

    /// Follow a newly appearing cross-device/local/voice run once, but do not yank a reader back
    /// to the composer whenever another tool step reconciles into an already-active timeline.
    static func shouldScrollToLiveActivity(
        previousEffectiveRunCount: Int,
        currentEffectiveRunCount: Int
    ) -> Bool {
        previousEffectiveRunCount == 0 && currentEffectiveRunCount > 0
    }

    static func containsInlineImageToolResult(_ text: String) -> Bool {
        AssistantMarkdownParser.parse(text).contains {
            if case .image = $0 { return true }
            return false
        }
    }

    static func foldedUnknownToolResultIndexes(for message: OpenClawChatMessage) -> Set<Int> {
        Set(message.content.enumerated().compactMap { index, content in
            let text = toolResultText(content)
            guard !ToolResultParser.parse(text).isKnown,
                  shouldFoldUnknownToolResult(toolName: content.name ?? message.toolName, text: text)
            else { return nil }
            return index
        })
    }

    static func consolidatedHistoricalActivityDisplays(
        _ displays: [ActionLifecycleDisplay]
    ) -> [ActionLifecycleDisplay] {
        var indexes: [String: Int] = [:]
        var result: [ActionLifecycleDisplay] = []

        for display in displays {
            let key = "\(display.sfSymbol)|\(display.liveText)|\(display.detailText ?? "")"
            if let index = indexes[key] {
                let count = result[index].occurrenceCount + display.occurrenceCount
                result[index] = result[index].withOccurrenceCount(count)
            } else {
                indexes[key] = result.count
                result.append(display)
            }
        }
        return result
    }

    private static func toolResultText(_ content: OpenClawChatMessageContent) -> String {
        if let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let value = content.content {
            if let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                return string
            }
            if let nested = value.dictionaryValue?["text"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !nested.isEmpty {
                return nested
            }
        }
        return ""
    }

    @ViewBuilder
    private func runtimePairingRecoveryCard(for text: String, messageID: UUID? = nil) -> some View {
        if SharedChatDiagnosticDisplay.needsRuntimePairingApproval(text),
           messageID.map({ $0 == latestRuntimePairingRecoveryMessageID }) ?? true,
           let onOpenDeviceConnections {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rem needs permission to use your machine.")
                    .font(DesignTokens.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SharedChatDiagnosticDisplay.runtimePairingActionCaption)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(SharedChatDiagnosticDisplay.runtimePairingActionTitle) {
                    onOpenDeviceConnections()
                }
                .remInlineRecoveryCTA()
            }
            .padding(DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DesignTokens.Color.backgroundSecondary)
            )
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var latestRuntimePairingRecoveryMessageID: UUID? {
        viewModel.messages.reversed().first { message in
            messageContainsRuntimePairingRecoveryDiagnostic(message)
        }?.id
    }

    private func messageContainsRuntimePairingRecoveryDiagnostic(_ message: OpenClawChatMessage) -> Bool {
        for item in message.content {
            if let thinking = item.thinking, !thinking.isEmpty {
                let cleaned = Self.cleanThinkingTextForDisplay(thinking)
                if SharedChatDiagnosticDisplay.needsRuntimePairingApproval(cleaned) {
                    return true
                }
            }

            if let text = item.text, !text.isEmpty {
                let cleaned = MessageCleaner.cleanAssistantMessage(text)
                if let diagnostics = cleaned.diagnosticsText,
                   SharedChatDiagnosticDisplay.needsRuntimePairingApproval(diagnostics) {
                    return true
                }
                if SharedChatDiagnosticDisplay.needsRuntimePairingApproval(cleaned.displayText) {
                    return true
                }
            }
        }

        return false
    }

    private func historicalActionDisplays(
        for parts: SplitContent,
        isBrowserCardTurn: Bool
    ) -> [ActionLifecycleDisplay] {
        guard !parts.jsonToolResults.contains(where: { ToolResultParser.parse($0).isKnown }) else {
            return []
        }

        var seen = Set<String>()
        var displays: [ActionLifecycleDisplay] = []

        for tool in parts.toolCalls {
            // The live/review browser card is the browser tool's canonical presentation only
            // while that card actually belongs to this chat. A wired browser session alone is
            // not enough: after relaunch or in another chat there may be no card to preserve the
            // persisted activity.
            if Self.shouldSuppressHistoricalBrowserLifecycleActivity(
                toolName: tool.name,
                isCardTurn: isBrowserCardTurn,
                cardPresentation: browserCardPresentation
            ) { continue }
            let display = resolveToolCallDisplay(name: tool.name, args: tool.arguments, phase: .historical)
            guard display.liveText != "Running command",
                  display.liveText != "Checking connected devices" else { continue }
            guard seen.insert("\(display.sfSymbol)|\(display.text)").inserted else { continue }
            displays.append(display)
        }

        return displays
    }

    @ViewBuilder
    private func actionDetails(
        displays: [ActionLifecycleDisplay],
        sectionId: String,
        kind: ActionLifecycleDisclosure.Kind = .agentInstructions,
        elapsedSeconds: Int? = nil,
        isRunActive: Bool = false
    ) -> some View {
        // One writer, one path — the live run no longer gets a second, inverted flag of its own.
        // That flag (`activeRunCollapsed`) existed only to undo the auto-expansion, and because it
        // reset on every run boundary a stream update could reopen a section the user had closed
        // (#1278). Live and completed disclosures now toggle identical state.
        let isExpanded = ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: expandedSections.contains(sectionId),
            kind: kind,
            isRunActive: isRunActive
        )

        ActionLifecycleDisclosure(
            displays: displays,
            isExpanded: isExpanded,
            kind: kind,
            elapsedSeconds: elapsedSeconds,
            isRunActive: isRunActive,
            accessibilityIdentifier: sectionId,
            onToggle: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isExpanded {
                        expandedSections.remove(sectionId)
                    } else {
                        expandedSections.insert(sectionId)
                    }
                }
            }
        )
    }

    private struct InlineToolResultDisplay: Identifiable {
        let id: Int
        let index: Int
        let text: String
        let duplicateCount: Int
    }

    private func consolidatedInlineToolResults(_ texts: [String]) -> [InlineToolResultDisplay] {
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        var results: [InlineToolResultDisplay] = []

        for text in texts {
            let parsed = ToolResultParser.parse(text)
            if let key = parsed.consolidationKey {
                counts[key, default: 0] += 1
            }
        }

        for (index, text) in texts.enumerated() {
            let parsed = ToolResultParser.parse(text)
            let duplicateCount: Int
            if let key = parsed.consolidationKey {
                guard seen.insert(key).inserted else { continue }
                duplicateCount = counts[key, default: 1]
            } else {
                duplicateCount = 1
            }
            results.append(InlineToolResultDisplay(
                id: index,
                index: index,
                text: text,
                duplicateCount: duplicateCount
            ))
        }

        return results
    }

    // MARK: - Content Splitting

    struct SplitContent {
        var thinking: [String] = []
        var textBlocks: [String] = []
        var jsonToolResults: [String] = []
        var toolCalls: [OpenClawChatMessageContent] = []
        var attachments: [OpenClawChatMessageContent] = []
    }

    static func splitContent(_ content: [OpenClawChatMessageContent], isUser: Bool) -> SplitContent {
        var result = SplitContent()
        #if DEBUG
        // Phase 1 diagnostics (#260): trace every content item so we can
        // reconstruct which raw items produced which rendered blocks. Without
        // this, a leak that makes it into `textBlocks` looks identical to one
        // that slipped into `jsonToolResults` with an unknown parser verdict.
        let traceEnabled = Self.chatSanitizeVerbose
        #endif
        for item in content {
            let kind = (item.type ?? "text").lowercased()
            switch kind {
            case "toolcall", "tool_call", "tooluse", "tool_use":
                result.toolCalls.append(item)
            case "toolresult", "tool_result":
                if let text = item.text, !text.isEmpty {
                    let cleaned = MessageCleaner.cleanAssistantMessage(text)
                    if let diagnostics = cleaned.diagnosticsText {
                        result.thinking.append(diagnostics)
                    }
                    if !cleaned.displayText.isEmpty {
                        result.jsonToolResults.append(cleaned.displayText)
                    }
                }
                continue
            case "thinking":
                let text = (item.thinking ?? item.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = Self.cleanThinkingTextForDisplay(text)
                if !cleaned.isEmpty {
                    result.thinking.append(cleaned)
                }
            case "file", "attachment":
                result.attachments.append(item)
            default:
                if item.name != nil && item.arguments != nil {
                    result.toolCalls.append(item)
                } else {
                    let rawText = item.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawThinking = item.thinking?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let rawThinking, !rawThinking.isEmpty, rawThinking != rawText {
                        let cleaned = Self.cleanThinkingTextForDisplay(rawThinking)
                        if !cleaned.isEmpty {
                            result.thinking.append(cleaned)
                        }
                    }

                    // Persisted assistant items can carry reasoning and final prose together. The
                    // old else-if projected the reasoning but discarded the answer, after which
                    // stream handoff removed its cache and left only the Activity disclosure.
                    guard let text = item.text, !text.isEmpty else { continue }
                    let displayText: String
                    if isUser {
                        displayText = MessageCleaner.cleanUserMessageText(text)
                    } else {
                        let cleaned = MessageCleaner.cleanAssistantMessage(text)
                        if let diagnostics = cleaned.diagnosticsText {
                            result.thinking.append(diagnostics)
                        }
                        displayText = cleaned.displayText
                    }
                    let t = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    if !isUser, SharedChatDiagnosticDisplay.isRuntimeDiagnostic(t) {
                        result.thinking.append(t)
                        continue
                    }
                    if !isUser, UnknownToolContentProjection.project(t).residualIsUnsafe {
                        result.jsonToolResults.append(t)
                        #if DEBUG
                        if traceEnabled {
                            print(
                                "[ChatSanitize] SPLIT kind=\(kind) bucket=jsonToolResults " +
                                "len=\(text.count) " +
                                "preview=\(text.prefix(120).replacingOccurrences(of: "\n", with: "\\n"))"
                            )
                        }
                        #endif
                    } else if t.hasPrefix("{"),
                              let d = t.data(using: .utf8),
                              (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] != nil {
                        if isUser {
                            result.textBlocks.append(t)
                        } else {
                            result.jsonToolResults.append(t)
                        }
                        #if DEBUG
                        if traceEnabled {
                            print(
                                "[ChatSanitize] SPLIT kind=\(kind) bucket=jsonToolResults " +
                                "len=\(text.count) " +
                                "preview=\(text.prefix(120).replacingOccurrences(of: "\n", with: "\\n"))"
                            )
                        }
                        #endif
                    } else {
                        result.textBlocks.append(t)
                        #if DEBUG
                        if traceEnabled {
                            print(
                                "[ChatSanitize] SPLIT kind=\(kind) bucket=textBlocks " +
                                "len=\(text.count) " +
                                "preview=\(text.prefix(120).replacingOccurrences(of: "\n", with: "\\n"))"
                            )
                        }
                        #endif
                    }
                }
            }
        }
        return result
    }

    static func cleanThinkingTextForDisplay(_ text: String) -> String {
        MessageCleaner.cleanAssistantMessageText(text)
    }

    // MARK: - Speech Bubble

    @ViewBuilder
    private func speechBubble(texts: [String], isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: -8) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                        let displayText = isUser
                            ? MessageCleaner.cleanUserMessageText(text)
                            : preprocessMarkdown(text, callSite: "history.speechBubble")
                        if !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if isUser {
                                Text(verbatim: displayText)
                                    .font(DesignTokens.Typography.chatMessage)
                                    .foregroundStyle(.white)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            } else {
                                AssistantMarkdownView(markdown: displayText)
                            }
                        }
                    }
                }
                .padding(.horizontal, isUser ? 16 : 0)
                .padding(.vertical, isUser ? 12 : 4)
                .background(isUser ? DesignTokens.Color.brandBlue : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: isUser ? 20 : 4))
                .frame(maxWidth: isUser ? 280 : 560, alignment: isUser ? .trailing : .leading)

                // Tail dots for user bubbles (ArcChatBubble style)
                if isUser {
                    HStack {
                        Spacer()
                        VStack(spacing: 2) {
                            Circle().frame(width: 20)
                            Circle().frame(width: 12)
                                .offset(x: 8)
                        }
                        .foregroundStyle(DesignTokens.Color.brandBlue)
                        .padding(.trailing, 20)
                    }
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
    }

    // MARK: - Thinking Block

    @ViewBuilder
    private func thinkingBlock(
        _ text: String,
        sectionId: String,
        phase: ActionLifecycleDisplay.Phase = .historical
    ) -> some View {
        SharedChatThinkingBlock(
            text: text,
            sectionId: sectionId,
            phase: phase,
            expandedSections: $expandedSections
        )
    }

    // MARK: - Attachment Badge

    @ViewBuilder
    private func attachmentBadge(_ content: OpenClawChatMessageContent, isUser: Bool) -> some View {
        // A sent user image rides in `content.content` as base64 (see
        // `ChatViewModel.performSend` — attachments are appended as content items
        // whose `content` is `att.data.base64EncodedString()`). Render the actual
        // image inline so the transcript shows the photo, not just a paperclip +
        // filename. The user's image is right-aligned (like the message bubble),
        // rounded, and tappable to view full-screen. Falls back to the paperclip
        // badge for non-image / undecodable attachments.
        if let image = Self.attachmentImage(content) {
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 48) }
                platformImageView(image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
                    .onTapGesture { zoomedImage = ZoomedImage(image: image) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("View image full screen")
                if !isUser { Spacer(minLength: 48) }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Text(content.fileName ?? "Attachment")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    /// Wraps a decoded platform image into a SwiftUI `Image` without the
    /// `#if` branch leaking into every call site.
    private func platformImageView(_ image: OpenClawPlatformImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }

    /// Decode a transcript attachment's inline base64 payload into a platform
    /// image. Handles both raw base64 and `data:<mime>;base64,<…>` data URLs, and
    /// a couple of common nested shapes (`{ data: … }`, `{ source: { data: … } }`)
    /// in case the gateway echoes attachments in a structured form. Returns `nil`
    /// when the payload is absent or not a decodable image.
    private static func attachmentImage(_ content: OpenClawChatMessageContent) -> OpenClawPlatformImage? {
        guard let base64 = attachmentBase64(content) else { return nil }
        let payload: String
        if base64.hasPrefix("data:"), let comma = base64.firstIndex(of: ",") {
            payload = String(base64[base64.index(after: comma)...])
        } else {
            payload = base64
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data)
        #elseif canImport(AppKit)
        return NSImage(data: data)
        #else
        return nil
        #endif
    }

    private static func attachmentBase64(_ content: OpenClawChatMessageContent) -> String? {
        guard let value = content.content else { return nil }
        if let string = value.stringValue { return string }
        if let dict = value.dictionaryValue {
            if let data = dict["data"]?.stringValue { return data }
            if let source = dict["source"]?.dictionaryValue, let data = source["data"]?.stringValue {
                return data
            }
        }
        return nil
    }

    // MARK: - Typing Indicator

    @ViewBuilder
    private var typingIndicator: some View {
        HStack(spacing: 6) {
            // The self-drawing Rem face is the "Rem is thinking" signature (replaces
            // the typing dots here; SharedChatTypingDots is still used elsewhere).
            RemFaceMark(mode: .thinking, tint: DesignTokens.Color.brandBlue, size: 20)
            Text("Thinking…")
                .font(.caption.weight(.medium))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pending Tools Bar

    @ViewBuilder
    private var pendingToolsBar: some View {
        let displays = runActivityAccumulator.displays
        if !displays.isEmpty {
            actionDetails(
                displays: displays,
                sectionId: Self.liveRunActivitySectionID,
                kind: Self.activityDisclosureKind(isActive: runActivityAccumulator.isActive),
                isRunActive: runActivityAccumulator.isActive
            )
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }

    private static func isBrowserLifecycleTool(_ rawName: String?) -> Bool {
        let name = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == "browser" || name == "canvas"
    }

    static func shouldSuppressHistoricalBrowserLifecycleActivity(
        toolName: String?,
        isCardTurn: Bool,
        cardPresentation: BrowserCardPresentation
    ) -> Bool {
        isCardTurn && cardPresentation != .none && isBrowserLifecycleTool(toolName)
    }

    static func shouldSuppressPendingBrowserLifecycleActivity(
        toolName: String?,
        cardPresentation: BrowserCardPresentation
    ) -> Bool {
        cardPresentation == .live && isBrowserLifecycleTool(toolName)
    }

    // MARK: - Voice Transcription Label

    @ViewBuilder
    private func voiceLabel(isLive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.fill")
                .font(.caption)
            Text(isLive ? "Transcribing..." : "Transcribed")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(DesignTokens.Color.labelTertiary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    /// Meta line above a user bubble — "Transcribed" and/or "Cloud browser", joined by "•" when both
    /// apply. Same caption style + trailing alignment as `voiceLabel`, so a voice turn that also used
    /// the cloud browser reads as one line rather than two stacked labels.
    @ViewBuilder
    private func messageMetaLabel(voice: Bool, cloudBrowser: Bool) -> some View {
        HStack(spacing: 5) {
            if voice {
                Image(systemName: "mic.fill").font(.caption)
                Text("Transcribed").font(.caption.weight(.medium))
            }
            if voice && cloudBrowser {
                Text("•").font(.caption.weight(.medium))
            }
            if cloudBrowser {
                Image(systemName: "globe").font(.caption)
                Text("Cloud browser").font(.caption.weight(.medium))
            }
        }
        .foregroundStyle(DesignTokens.Color.labelTertiary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Voice Mini Bar

    @ViewBuilder
    private func voiceMiniBar(onEndVoice: @escaping () -> Void) -> some View {
        MiniPlayerBar(
            modeText: (voiceIsReadingAloud || voiceCanRetryReadingAloud)
                ? "Latest Brief" : "Voice Chat",
            titleText: voiceIsReadingAloud ? "Reading latest brief" : (voiceStatusText ?? "Active session"),
            subtitleText: voiceCanRetryReadingAloud
                ? "Microphone stays muted until reading succeeds"
                : (voiceIsReadingAloud ? "Continue listening, then reply" : (voiceStatusText ?? "Active session")),
            timerStartDate: voiceStartDate,
            progress: nil,
            progressColor: DesignTokens.Color.brandBlue,
            primaryButton: .init(
                icon: voiceIsMuted ? "mic.slash.fill" : "mic.fill",
                color: voiceIsMuted ? DesignTokens.Color.systemRed : DesignTokens.Color.labelPrimary,
                accessibilityLabel: voiceIsMuted ? "Unmute microphone" : "Mute microphone",
                action: {
                    onToggleMute?()
                }
            ),
            stopButton: .init(
                icon: voiceIsReadingAloud ? "stop.fill" : "phone.down.fill",
                color: DesignTokens.Color.systemRed,
                accessibilityLabel: voiceIsReadingAloud
                    ? "Stop reading and continue voice chat"
                    : "End voice chat",
                action: {
                    if voiceIsReadingAloud {
                        onStopReadingAloud?()
                    } else {
                        onEndVoice()
                    }
                }
            ),
            retryReadingAction: voiceCanRetryReadingAloud ? onRetryReadingAloud : nil,
            // Voice enabled but the gateway is still waking → show the connecting (thinking-dots)
            // form; the controls + timer animate in once the chat/gateway is live.
            isConnecting: isWaking,
            onTap: {},
            closingDeadline: voiceAutoCloseAt,
            closingDuration: voiceAutoCloseCountdownDuration,
            onKeepOpen: onKeepVoiceOpen
        )
        .accessibilityIdentifier("voice-mini-player-bar")
    }

    // MARK: - Error Banner

    @ViewBuilder
    /// Humanize the raw run-error text the gateway surfaces before showing it in
    /// the banner. The upstream `OpenClawChatViewModel` already clears the pending
    /// run and sets `errorText` on a `state:"error"` chat event (see
    /// `handleChatEvent`), and falls back to a 120s pending-run watchdog
    /// (`armPendingRunTimeout`), so the run no longer spins forever — but the text
    /// it carries is a raw provider string like
    /// `GMI MaaS responded 400: Invalid model name: MiniMaxAI/MiniMax-M2.1`
    /// (the model-not-found outage this change addresses). Surface an actionable
    /// line instead of dumping the HTTP body. Presentation-only: the machine
    /// decision (clearing the run) already happened upstream off the structured
    /// `state`/`errorKind`, so matching copy substrings here is the right layer
    /// (CLAUDE.md principle 5).
    /// Turn raw transport/gateway errors into calm, human copy. Users should never see wire jargon
    /// ("gateway", "channel shutdown", "18789", "15000ms", "OpenClaw", WS close codes) — those are
    /// implementation details. Known infrastructure states get a friendly, reassuring, actionable
    /// line; genuinely unknown (often agent-authored) messages pass through unchanged so real
    /// information isn't hidden.
    /// - Parameter showRawDetail: When true (developer / non-production builds,
    ///   see `AppBackendEnvironment.isDeveloperBuild`), an otherwise-unmatched
    ///   message that carries wire/transport detail (a `wss://` URL, a protocol
    ///   error) is passed through verbatim so a developer can debug it. Normal
    ///   users (false) never see that jargon — they get a calm, human fallback.
    static func humanizedChatError(_ raw: String, showRawDetail: Bool = false) -> String {
        let lower = raw.lowercased()

        // Model / provider not available. "does not exist" is deliberately NOT in this flat list —
        // it's common in agent/tool errors ("that event does not exist", "file does not exist"), so
        // we only treat it as a model problem when the message is actually about the model.
        let modelUnavailableSignals = [
            "invalid model name", "model_not_found", "model not found",
            "unknown model", "no endpoints",
        ]
        let looksLikeMissingModel = lower.contains("does not exist") && lower.contains("model")
        if looksLikeMissingModel || modelUnavailableSignals.contains(where: lower.contains) {
            return "That model isn't available right now — pick another in model settings."
        }

        // Couldn't establish / re-establish the gateway connection. The raw text here is pure wire
        // jargon a user should never see — e.g.
        // "gateway connect: connect to gateway @ wss://remclaw-xxxx.fly.dev/: There was a bad response".
        // The app auto-retries, so a reassuring, actionable line is the right surface.
        //
        // STRONG signals are wire-only and safe to match on their own. Ambiguous phrases like
        // "bad response"/"bad server response" are deliberately NOT here: a model-provider, tool, or
        // agent error can say "bad response" while the gateway is perfectly healthy, so matching them
        // standalone would misclassify a real error as a gateway connect failure (and falsely claim
        // reconnection). They only ride along the motivating case ("...@ wss://... bad response"),
        // which already carries a strong signal, so no separate weak-tier match is needed.
        // "handshake" is likewise NOT here — it's common in tool errors ("SSL handshake failed" to a
        // third-party host); it's only a connect signal when anchored to a gateway marker, handled by
        // `isGatewayTransportWireError` in the fallback below.
        // Gated on `showRawDetail`: dev/staging builds fall through to the raw wire text for debugging
        // (the whole reason the flag exists); prod users get the friendly line.
        let strongConnectSignals = ["gateway connect", "connect to gateway", "wss://", "ws://"]
        if !showRawDetail && strongConnectSignals.contains(where: lower.contains) {
            return "Couldn't reach Rem — reconnecting…"
        }

        // Connection dropped mid-session (the app is already retrying).
        let disconnectedSignals = [
            "channel shutdown", "not connected", "disconnected",
            "connection closed", "websocket", "connection lost",
        ]
        if disconnectedSignals.contains(where: lower.contains) {
            return "Rem lost its connection. Reconnecting…"
        }

        // Gateway waking / not reachable yet / health preflight failing (auto-suspended cloud gateway).
        // "cannot send" is intentionally absent: the only raw string that carries it is
        // "Gateway health not OK; cannot send", already caught by "health not ok" — and a bare
        // "cannot send" can appear in agent-authored failures we shouldn't relabel as "waking".
        // "econnrefused" is likewise absent: a genuinely suspended gateway surfaces its connect error
        // as "connect to gateway @ wss://…" and is already caught by strongConnectSignals above, while
        // a bare "ECONNREFUSED" here is a tool's outbound fetch to a refused host (gateway healthy) —
        // it's handled, only when anchored, by `isGatewayTransportWireError` in the fallback below.
        let wakingSignals = [
            "health not ok", "not reachable", "unreachable",
            "waking", "gateway isn't reachable",
        ]
        if wakingSignals.contains(where: lower.contains) {
            return "Rem is waking up — this takes a few seconds. Try again in a moment."
        }

        // Slow response / timeout (congested gateway, browser tool, etc.).
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("took too long") {
            return "That's taking longer than usual. Give Rem a moment, then try again."
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Something went wrong. Try again." }

        // Genuinely unknown messages are usually agent-authored real information
        // ("that event does not exist", a tool's own error, "Failed to fetch
        // https://api.weather.com (404)") and should pass through so nothing
        // useful is hidden. Only mask when the string is CLEARLY a raw
        // connection/transport error — so the signal list is deliberately narrow
        // and wire-only. Broad terms like "http", "gateway", "://", or "protocol"
        // are intentionally excluded: a legit tool error that merely mentions a
        // URL must not be swallowed and mislabeled as "reconnecting…". When
        // unsure, prefer showing the (already error-surfaced) message. Dev builds
        // (`showRawDetail`) always see it verbatim for debugging.
        if !showRawDetail {
            // Unambiguous gateway-URL tokens (also caught earlier by
            // strongConnectSignals; kept as the last-resort net).
            if lower.contains("wss://") || lower.contains("ws://") {
                return "Couldn't reach Rem — reconnecting…"
            }
            // Ambiguous tokens (socket / econn / handshake) ONLY when anchored to a
            // gateway-transport marker — a standalone "socket hang up" / "ECONNRESET"
            // / "SSL handshake failed" from a healthy-gateway tool call passes through
            // so its real, actionable message stays visible.
            if Self.isGatewayTransportWireError(lower) {
                return "Couldn't reach Rem — reconnecting…"
            }
        }
        return trimmed
    }

    /// Tokens that appear in gateway-transport failures but are ALSO common in
    /// tool/agent errors that hit third-party APIs while the gateway itself is
    /// healthy — "socket hang up", "ECONNRESET"/"ECONNREFUSED", "SSL handshake
    /// failed". Matching them standalone hides a real, actionable tool error
    /// behind "reconnecting…"/"waking up…", so they only count as a connection
    /// problem when the message also carries a gateway-transport marker (below).
    ///
    /// There is no structured field to route on here (CLAUDE.md principle 5): the
    /// chat `errorKind` upstream is an agent-outcome enum — refusal / timeout /
    /// rate_limit / context_length / unknown, none of them "transport" — and
    /// `OpenClawChatEventPayload` drops it anyway, surfacing only `errorMessage`
    /// as a String. So we anchor on the context prefix OpenClawKit's own
    /// transport layer adds, not a structured origin that doesn't reach us.
    private static let ambiguousWireTokens = ["socket", "econn", "handshake"]

    /// Markers OpenClawKit only attaches to genuine gateway-transport failures:
    /// the `wss://`/`ws://` URL and the context prefixes `GatewayChannel.wrap`
    /// prepends to every wrapped transport error ("gateway connect",
    /// "connect to gateway @ wss://…", "gateway send …", "gateway receive",
    /// "gateway reconnect"). Deliberately NOT the bare word "gateway": a tool
    /// error like "502 Bad Gateway; socket hang up" is the third-party target
    /// failing, not our connection, and must pass through unchanged.
    private static let gatewayTransportMarkers = [
        "wss://", "ws://",
        "gateway connect", "connect to gateway",
        "gateway send", "gateway receive", "gateway reconnect",
    ]

    /// True when `lower` names an ambiguous wire token AND carries a
    /// gateway-transport marker — i.e. the token really is about our connection,
    /// not a tool's outbound socket to some third-party host.
    private static func isGatewayTransportWireError(_ lower: String) -> Bool {
        ambiguousWireTokens.contains(where: lower.contains)
            && gatewayTransportMarkers.contains(where: lower.contains)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Color.systemYellow)
            Text(Self.humanizedChatError(text, showRawDetail: AppBackendEnvironment.isDeveloperBuild))
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.errorText = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
            .buttonStyle(.plain)
        }
        // Inset + rounded so the gateway-health callout reads as a contained pill matching the
        // composer's shape, instead of a full-width tinted strip.
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            DesignTokens.Color.systemYellow.opacity(0.15),
            in: .rect(cornerRadius: DesignTokens.CornerRadius.medium)
        )
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    @ViewBuilder
    private var quotaExceededBanner: some View {
        Button {
            onQuotaExceededBannerTap?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(DesignTokens.Color.systemRed)
                Text(quotaExceededBannerText)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .buttonStyle(.plain)
        .background(DesignTokens.Color.systemRed.opacity(0.12))
    }

    // MARK: - Composer

    /// Cross-platform "secondary grouped background" equivalent used for the
    /// thinking picker and Speak button pill.
    private static var pillBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return DesignTokens.Color.backgroundSecondary
        #endif
    }

    @ViewBuilder
    private var composerBar: some View {
        // Shared composer shell — same component as the task **Activity** reply
        // input (`TaskCommentComposer`). Chat injects its transport-specific
        // affordances via the builder slots: Think + Speak as sibling pills in the
        // leading slot, and send/abort in the send slot.
        RemComposerBar(
            text: $viewModel.input,
            placeholder: "Ask anything",
            focus: $isInputFocused,
            onSubmit: { sendIfReady() },
            attachments: {
                if !viewModel.attachments.isEmpty || browserCapabilityAttached {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            if browserCapabilityAttached {
                                browserCapabilityChip
                            }
                            ForEach(viewModel.attachments) { att in
                                attachmentChip(att)
                            }
                        }
                        // Small leading inset off the pill edge (the composer
                        // bleeds this strip out of its `md` content padding), so
                        // the thumbnail aligns to the composer edge rather than
                        // the text column.
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                    }
                }
            },
            // Control row (ChatGPT/Claude pattern): the "+" opens the "Add to Chat"
            // sheet for attachments + Thinking, while the **model picker** and
            // **Speak** stay visible in the bar itself — the two affordances a user
            // changes mid-conversation shouldn't be buried in a sheet. Net composer
            // = [+] · model picker · field · [Speak] [send].
            leading: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    addButton
                    if viewModel.showsModelPicker {
                        modelPickerMenu
                    }
                }
            },
            trailing: { speakButton },
            send: { sendButton }
        )
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .onChange(of: pickedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            showsAddSheet = false
            loadPickedPhotos(items)
        }
        .sheet(isPresented: $showsAddSheet) { addToChatSheet }
        .sheet(isPresented: $showsModelsSheet) {
            NavigationStack {
                Group {
                    if let modelsSettingsDestination {
                        modelsSettingsDestination()
                    } else {
                        SharedModelsSettingsView(
                            models: viewModel.modelChoices,
                            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs)
                    }
                }
                .toolbar {
                        #if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showsModelsSheet = false }
                        }
                        #else
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsModelsSheet = false }
                        }
                        #endif
                    }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraImagePicker { image in
                if let image { loadCameraImage(image) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    // MARK: - "+" Add button

    /// Leading composer affordance — opens the "Add to Chat" sheet. Replaces the
    /// crowded inline pill row (photo · model · thinking) with a single "+".
    @ViewBuilder
    private var addButton: some View {
        Button {
            isInputFocused = false
            showsAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .frame(width: 32, height: 32)
                .background(Self.pillBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to chat")
        .accessibilityHint("Attach a photo or file, or change the thinking level")
    }

    // MARK: - Model picker (composer bar)

    /// Inline model picker that lives in the composer's leading slot next to "+".
    /// Automatic stays the product default. Explicit choices are grouped under provider submenus
    /// so the top level remains scannable even when several authenticated providers are enabled.
    @ViewBuilder
    private var modelPickerMenu: some View {
        Menu {
            Button {
                viewModel.selectModel(OpenClawChatViewModel.defaultModelSelectionID)
            } label: {
                if isDefaultModelSelected {
                    Label(ModelPickerPresentation.automaticTitle, systemImage: "checkmark")
                } else {
                    Text(ModelPickerPresentation.automaticTitle)
                }
            }

            ForEach(composerModelGroups) { group in
                Menu {
                    ForEach(group.models) { choice in
                        Button {
                            viewModel.selectModel(choice.selectionID)
                        } label: {
                            if effectiveModelSelectionID == choice.selectionID {
                                Label(
                                    ModelUserFacingCopy.modelName(choice.name),
                                    systemImage: "checkmark")
                            } else {
                                Text(ModelUserFacingCopy.modelName(choice.name))
                            }
                        }
                    }
                } label: {
                    Text(group.provider)
                }
            }

            // Footer: choose which gateway-authenticated providers and models are available here.
            Section {
                Button {
                    showsModelsSheet = true
                } label: {
                    Label(ModelPickerPresentation.manageModelsTitle, systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(ModelPickerPresentation.composerTitle(
                    selectionID: effectiveModelSelectionID,
                    models: viewModel.modelChoices
                ))
                    .font(DesignTokens.Typography.caption1)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(DesignTokens.Color.labelSecondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: 32)
            .background(Self.pillBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!ChatComposerSendPolicy.canOpenModelPicker(
            isPreparingSend: viewModel.isPreparingSend,
            isSending: viewModel.isSending))
        .accessibilityLabel("Model")
        .accessibilityValue(ModelPickerPresentation.composerTitle(
            selectionID: effectiveModelSelectionID,
            models: viewModel.modelChoices
        ))
        .accessibilityHint("Use Automatic or choose a model from an available provider")
    }

    private var composerModelGroups: [ModelPickerPolicy.ProviderGroup] {
        ModelPickerPolicy.composerGroups(
            viewModel.modelChoices,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs,
            defaultModelLabel: viewModel.defaultModelLabel,
            hasAuthoritativeProviderEvidence:
                runtimeProviderAuthEvidence.canPresentProviderMenus)
    }

    private var effectiveModelSelectionID: String {
        guard runtimeProviderAuthEvidence.canReconcileExplicitSelection(
            viewModel.modelSelectionID
        ) else {
            return viewModel.modelSelectionID
        }
        return ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: viewModel.modelSelectionID,
            models: viewModel.modelChoices,
            catalogCompleteness: viewModel.modelCatalogCompleteness,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs,
            defaultModelLabel: viewModel.defaultModelLabel
        )
    }

    // MARK: - Add to Chat sheet

    /// "Add to Chat" sheet — ChatGPT/Claude "+" pattern. Camera / Photos / Files
    /// render as three boxed buttons in a row; Thinking is a single row with a
    /// `Menu` picker. The model picker now lives in the composer bar, not here.
    @ViewBuilder
    private var addToChatSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                HStack(spacing: DesignTokens.Spacing.md) {
                    #if os(iOS)
                    attachBox(title: "Camera", systemImage: "camera") {
                        showsAddSheet = false
                        showsCamera = true
                    }
                    #endif

                    PhotosPicker(
                        selection: $pickedPhotoItems,
                        maxSelectionCount: 4,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        attachBoxLabel(title: "Photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.plain)

                    attachBox(title: "Files", systemImage: "folder") {
                        showsAddSheet = false
                        showsFileImporter = true
                    }
                }

                // Only where the cloud browser is wired (browserSession injected — iOS today).
                if browserSession != nil {
                    browserConnectRow
                }

                thinkingRow

                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Add to Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsAddSheet = false }
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsAddSheet = false }
                }
                #endif
            }
        }
        #if os(iOS)
        .presentationDetents([.height(340), .medium])
        #endif
    }

    /// One of the three "Attach" boxed buttons (Camera / Files). Photos uses the
    /// same `attachBoxLabel` wrapped in a `PhotosPicker` instead of a `Button`.
    @ViewBuilder
    private func attachBox(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            attachBoxLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    /// Boxed-button content: a centered icon over a caption label, filling its
    /// share of the row with a rounded secondary-fill background.
    @ViewBuilder
    private func attachBoxLabel(title: String, systemImage: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(DesignTokens.Color.brandBlue)
            Text(title)
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.lg)
        .background(
            Self.pillBackground,
            in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }

    /// "+" sheet row that ATTACHES the cloud browser to the next turn (as a removable chip in the
    /// composer, alongside photos/files). It doesn't prime text or open anything yet — attaching is
    /// cheap and reversible. On send the chip folds the directive into a HIDDEN block (stripped from
    /// the bubble; the turn shows a "Cloud browser" chip instead) so the agent opens the browser
    /// without visible directive prose; the user drives the actual sign-in via the live view's
    /// takeover handshake — Rem never enters credentials.
    @ViewBuilder
    private var browserConnectRow: some View {
        Button {
            setBrowserCapabilityAttached(true)
            showsAddSheet = false
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: "globe")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(DesignTokens.Color.brandBlue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud browser")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)
                    Text("Rem opens a live browser you can watch and take over to sign in.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if browserCapabilityAttached {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.Color.brandBlue)
                }
            }
            // Contained in a filled rounded rect, matching `thinkingRow` — the two single-row
            // affordances below the attach boxes read as one grouped list.
            .padding(DesignTokens.Spacing.md)
            .background(
                Self.pillBackground,
                in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The "Cloud browser" pill in the composer attachment strip — a capability tag for the next
    /// turn, removable like a photo. Styled as a compact pill (globe · label · ✕) to sit beside the
    /// media thumbnails.
    @ViewBuilder
    private var browserCapabilityChip: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.Color.brandBlue)
            Text("Cloud browser")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Button {
                setBrowserCapabilityAttached(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove cloud browser")
        }
        .padding(.leading, DesignTokens.Spacing.md)
        .padding(.trailing, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(Self.pillBackground, in: Capsule())
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cloud browser attached")
    }

    /// The Thinking row — a labeled list row whose trailing control is a `Menu`
    /// the user taps to change reasoning level (Off / Low / Medium / High).
    @ViewBuilder
    private var thinkingRow: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Label("Thinking", systemImage: "brain")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Spacer()
            Menu {
                ForEach(["off", "low", "medium", "high"], id: \.self) { level in
                    Button {
                        viewModel.selectThinkingLevel(level)
                    } label: {
                        if viewModel.thinkingLevel == level {
                            Label(thinkingLevelLabel(level), systemImage: "checkmark")
                        } else {
                            Text(thinkingLevelLabel(level))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(thinkingLevelLabel(viewModel.thinkingLevel))
                        .font(DesignTokens.Typography.caption1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isPreparingSend || viewModel.isSending)
            .accessibilityLabel("Thinking level")
            .accessibilityValue(thinkingLevelLabel(viewModel.thinkingLevel))
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            Self.pillBackground,
            in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
        )
    }

    /// Human label for a thinking level id (`off` → "Off", else capitalized).
    private func thinkingLevelLabel(_ level: String) -> String {
        level == "off" ? "Off" : level.capitalized
    }

    // MARK: - Files / Camera import

    /// `.fileImporter` result handler — loads picked image files into the view
    /// model's pending attachments (same compress + 5 MB path as photos).
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        Task { @MainActor in
            for (index, url) in urls.enumerated() {
                let needsStop = url.startAccessingSecurityScopedResource()
                defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let compressed = await Task.detached { Self.compressedImageData(data) }.value ?? data
                let fileName = "file-\(Int(Date().timeIntervalSince1970))-\(index).jpg"
                viewModel.addImageAttachment(data: compressed, fileName: fileName, mimeType: "image/jpeg")
            }
        }
    }

    #if os(iOS)
    /// Camera capture handler — compresses + hands the captured photo to the
    /// view model just like the Photos / Files paths.
    private func loadCameraImage(_ image: UIImage) {
        Task { @MainActor in
            guard let data = image.jpegData(compressionQuality: 0.9) else { return }
            let compressed = await Task.detached { Self.compressedImageData(data) }.value ?? data
            let fileName = "camera-\(Int(Date().timeIntervalSince1970)).jpg"
            viewModel.addImageAttachment(data: compressed, fileName: fileName, mimeType: "image/jpeg")
        }
    }
    #endif

    // MARK: - Photo Picker

    /// Reads the picked `PhotosPickerItem`s as `Data`, **downscales + recompresses
    /// on Rem's side**, and hands each off to the view model, which validates
    /// type/size and builds a preview.
    ///
    /// Why compress here: `OpenClawChatViewModel.addImageAttachment` enforces a
    /// 5 MB cap (`ChatViewModel.swift` in the read-only `openclaw/` submodule —
    /// `data.count > 5_000_000`). Typical phone photos are 3–12 MB and get
    /// rejected with "Attachment … exceeds 5 MB limit". We can't edit the
    /// submodule, so we shrink the data *before* the cap sees it: a 2048px
    /// long-edge JPEG at 0.7 quality lands well under 5 MB, so normal photos just
    /// work. The resulting bytes are always JPEG, so the filename/mime are forced
    /// to jpg/`image/jpeg`.
    private func loadPickedPhotos(_ items: [PhotosPickerItem]) {
        Task { @MainActor in
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let compressed = await Task.detached { Self.compressedImageData(data) }.value ?? data
                let fileName = "image-\(Int(Date().timeIntervalSince1970))-\(index).jpg"
                viewModel.addImageAttachment(data: compressed, fileName: fileName, mimeType: "image/jpeg")
            }
            pickedPhotoItems = []
        }
    }

    /// Resize the long edge to `maxPixel` (default 2048) and JPEG-encode at
    /// `quality` (default 0.7). Cross-platform via ImageIO (no UIKit/AppKit
    /// branch); EXIF orientation is baked in so the pixels are display-ready.
    /// Returns `nil` if the data isn't a decodable image, in which case the
    /// caller falls back to the original bytes.
    static func compressedImageData(
        _ data: Data,
        maxPixel: CGFloat = 2048,
        quality: CGFloat = 0.7
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Speak Button

    /// Voice entry pill — sibling of the Think pill, but the **primary** voice
    /// affordance on the control row. Present whenever the platform supplies a
    /// voice hook (`onVoiceTap`) and voice mode isn't already active.
    ///
    /// Prominence: Speak renders as a **filled brand-blue pill** with a white,
    /// semibold label so it reads as a distinct primary call-to-action — not a peer
    /// of the subtle (secondary-background) Think pill. After Think + Speak were
    /// made siblings on the control row they collapsed into the same visual weight
    /// and Speak felt diminished; the filled treatment restores the "prominent
    /// pill" reading while the two still share the row. When quota is exhausted it
    /// falls back to the muted pill fill so the disabled state stays legible.
    @ViewBuilder
    private var speakButton: some View {
        if onVoiceTap != nil, !isVoiceModeActive {
            Button {
                onVoiceTap?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Speak")
                        .font(DesignTokens.Typography.caption1Bold)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, 6)
                .foregroundStyle(hasQuota() ? Color.white : DesignTokens.Color.labelTertiary)
                .background(
                    hasQuota() ? DesignTokens.Color.brandBlue : Self.pillBackground,
                    in: .rect(cornerRadius: DesignTokens.CornerRadius.medium)
                )
            }
            .buttonStyle(.plain)
            .disabled(!hasQuota())
            .accessibilityLabel("Speak")
            .accessibilityHint("Start a voice conversation")
        }
    }

    // MARK: - Model Picker helper

    /// Whether the current selection is the gateway/plan default (no override).
    private var isDefaultModelSelected: Bool {
        effectiveModelSelectionID == OpenClawChatViewModel.defaultModelSelectionID
    }

    // MARK: - Send Button

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.pendingRunCount > 0 {
            Button {
                viewModel.abort()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(DesignTokens.Color.systemRed, in: Circle())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                sendIfReady()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        canSendComposer && hasRequiredSendQuota
                            ? DesignTokens.Color.brandBlue
                            : DesignTokens.Color.labelTertiary,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSendComposer || !hasRequiredSendQuota)
        }
    }

    // MARK: - Attachment Chip

    @ViewBuilder
    private func attachmentChip(_ att: OpenClawPendingAttachment) -> some View {
        // ChatGPT/Claude-style chip: a rounded thumbnail with a corner "x" to
        // remove — no filename text. The "x" overlaps the top-trailing corner,
        // so the strip carries a little top/trailing padding to avoid clipping.
        let side: CGFloat = 56
        ZStack(alignment: .topTrailing) {
            Group {
                #if canImport(UIKit)
                if let preview = att.preview {
                    Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
                } else {
                    chipPlaceholder
                }
                #else
                if let preview = att.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                } else {
                    chipPlaceholder
                }
                #endif
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))

            Button {
                viewModel.removeAttachment(att.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private var chipPlaceholder: some View {
        ZStack {
            Rectangle().fill(DesignTokens.Color.fillTertiary)
            Image(systemName: "doc")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        }
    }

    // MARK: - Send flow

    /// Sends the current input, gated on `hasQuota()` and
    /// `consumeSendSlot`. Input is cleared only after the send goes through,
    /// to prevent "Modifying state during view update" warnings.
    /// Send is enabled when the VM would allow it OR the cloud-browser chip is attached — the chip is
    /// content in its own right (it injects a directive on send), so it can send with an empty field.
    private var canSendComposer: Bool {
        ChatComposerSendPolicy.canSend(
            input: viewModel.input,
            hasAuthoritativeProviderEvidence:
                runtimeProviderAuthEvidence.canReconcileExplicitSelection(
                    effectiveModelSelectionID
                ),
            // Upstream OpenClaw keeps its default chat usable independently of `models.list`.
            // Rem's additional auth-evidence RPC is required only when honoring an explicit
            // provider choice; an older/local upstream gateway that lacks that RPC must not
            // strand Automatic chat.
            requiresProviderEvidence:
                effectiveModelSelectionID != OpenClawChatViewModel.defaultModelSelectionID,
            isPreparingSend: viewModel.isPreparingSend,
            viewModelCanSend: viewModel.canSend,
            browserCapabilityAttached: browserCapabilityAttached)
    }

    private var composerIsSessionCommand: Bool {
        ChatComposerSendPolicy.isSessionCommand(viewModel.input)
    }

    private var hasRequiredSendQuota: Bool {
        ChatComposerSendPolicy.hasRequiredQuota(
            input: viewModel.input,
            hasQuota: hasQuota())
    }

    private var runtimeConfiguredProviderIDs: [String] {
        runtimeProviderAuthEvidence.effectiveProviderIDs ?? []
    }

    private func sendIfReady() {
        guard canSendComposer else { return }
        guard hasRequiredSendQuota else { return }
        briefAnchorAllowsBottomFollowing = true

        // Capture the full user-authorized payload now; model repair and quota can both suspend.
        // Do not mutate the live composer in this synchronous callback path: TextField may still be
        // committing, and any edit made during preparation belongs to the next draft.
        // A session command remains exact control-plane input. Do not wrap it in the browser
        // directive or consume a newly attached browser chip.
        let browserCapabilityWasAttached = browserCapabilityAttached && !composerIsSessionCommand
        let browserCapabilityRevisionAtSend = browserCapabilityRevision
        let messageSnapshot = browserCapabilityWasAttached
            ? BrowserDirective.wrapChipSend(userText: viewModel.input)
            : viewModel.input
        let attachmentsSnapshot = viewModel.attachments

        // Acceptance must happen in this same synchronous callback. Deferring the VM call through
        // another Task would let a queued picker mutation or TextField commit run first, changing
        // the model/thinking snapshot or making the old payload own a newer composer revision.
        viewModel.send(
            modelSelectionID: effectiveModelSelectionID,
            message: messageSnapshot,
            attachments: attachmentsSnapshot
        ) {
            // Model reconciliation owns the first network phase. Quota and composer state must
            // change exactly once, only after that repair and all local dispatch guards
            // succeed; otherwise a rejected reset/health check would charge the user.
            if let consume = consumeSendSlot {
                let ok = await consume()
                guard ok else { return false }
            }

            // Only consume the exact chip revision captured by this send. If the user detached
            // and reattached while model repair/quota was pending, the new chip remains.
            if browserCapabilityWasAttached,
               browserCapabilityAttached,
               browserCapabilityRevision == browserCapabilityRevisionAtSend
            {
                setBrowserCapabilityAttached(false)
            }

            // Dispatch acceptance is the exact new-turn boundary. Clear any prior answer still in
            // the stream/history handoff before this run starts, including a repeated-identical
            // prompt whose timestamp-free fingerprint cannot distinguish the two user rows. Doing
            // this here avoids depending on pending-run/stream event ordering and preserves the old
            // answer when model repair, quota, or a local dispatch guard rejects the send.
            cachedStreamingText = nil
            cachedStreamingOriginUserAnchor = nil
            onAfterSend?()
            return true
        }
    }

    private func setBrowserCapabilityAttached(_ attached: Bool) {
        guard browserCapabilityAttached != attached else { return }
        browserCapabilityAttached = attached
        browserCapabilityRevision &+= 1
    }

    // MARK: - Markdown Preprocessing

    /// Clean assistant markdown for display. Mirrors
    /// upstream `ChatMarkdownPreprocessor` (internal to OpenClawChatUI) by
    /// stripping gateway metadata before local rendering handles markdown
    /// text and fenced code blocks.
    ///
    /// `callSite` is a short tag identifying the render path that invoked the
    /// cleaner — used by Phase 1 diagnostics for #260 (Chat sanitization gaps:
    /// shell command output and tool errors leak into AI bubbles) to prove
    /// which path bypasses the cleaner. Defaults to "unknown" so call sites
    /// that forget to tag themselves are still visible in logs.
    private func preprocessMarkdown(_ text: String, callSite: String = "unknown") -> String {
        let cleaned = MessageCleaner.cleanAssistantMessageText(text)
        #if DEBUG
        // Verbose entry trace (Phase 1): logs every invocation, regardless of
        // whether the cleaner changed the input, tagged with the render path.
        // This is the instrumentation that proves a bypass — if leaked text
        // renders in a bubble but no `[ChatSanitize] ENTRY site=...` log fires
        // matching that render, the render path is bypassing the cleaner.
        if Self.chatSanitizeVerbose {
            let dedupKey = "\(callSite)|\(text.hashValue)"
            if dedupKey != Self.lastTracedEntry {
                Self.lastTracedEntry = dedupKey
                let looksLikeLeak = Self.looksLikeUnstrippedLeak(text: text, cleaned: cleaned)
                let changed = text != cleaned
                print(
                    "[ChatSanitize] ENTRY site=\(callSite) " +
                    "inLen=\(text.count) outLen=\(cleaned.count) " +
                    "changed=\(changed) suspiciousUnstripped=\(looksLikeLeak) " +
                    "preview=\(text.prefix(120).replacingOccurrences(of: "\n", with: "\\n"))"
                )
            }
        }
        if Self.chatSanitizeVerbose {
            // Legacy before/after dedup kept for readability when the cleaner
            // actually modifies the text during targeted investigations.
            if text != cleaned, text != Self.lastLoggedSanitizeInput {
                Self.lastLoggedSanitizeInput = text
                print("[ChatSanitize] BEFORE (\(text.count) chars): \(text.prefix(200))")
                print("[ChatSanitize] AFTER  (\(cleaned.count) chars): \(cleaned.prefix(200))")
            }
        }
        #endif
        return cleaned
    }

    private func preprocessStreamingMarkdown(_ text: String, callSite: String = "unknown") -> String {
        let cleaned = MessageCleaner.cleanStreamingAssistantMessageText(text)
        #if DEBUG
        if Self.chatSanitizeVerbose {
            let dedupKey = "\(callSite)|\(text.hashValue)"
            if dedupKey != Self.lastTracedEntry {
                Self.lastTracedEntry = dedupKey
                let changed = text != cleaned
                print(
                    "[ChatSanitize] ENTRY site=\(callSite) " +
                    "inLen=\(text.count) outLen=\(cleaned.count) " +
                    "changed=\(changed) streaming=true " +
                    "preview=\(text.prefix(120).replacingOccurrences(of: "\n", with: "\\n"))"
                )
            }
        }
        #endif
        return cleaned
    }

    #if DEBUG
    /// Heuristic for Phase 1 diagnostics: does the assistant text *look* like
    /// it carries an unstripped tool-error or CLI help leak after the cleaner
    /// ran? Used to flag candidates that need new patterns in Phase 2. Kept
    /// intentionally loose — false positives are fine for diagnostics.
    private static func looksLikeUnstrippedLeak(text: String, cleaned: String) -> Bool {
        // If the cleaner already emptied it, not a leak.
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let markers = [
            "Tool ", // "Tool reminders.list not found"
            "error: unknown command",
            "(Command exited with code",
            "Usage:",
            "\nOptions:\n",
            "\nCommands:\n",
            "command not found",
        ]
        return markers.contains(where: { cleaned.contains($0) })
    }
    #endif

    // MARK: - Tool Call Display Resolution

    private func resolveToolCallDisplay(
        name: String?,
        args: OpenClawKit.AnyCodable?,
        phase: ActionLifecycleDisplay.Phase = .live
    ) -> ActionLifecycleDisplay {
        let lowerName = (name ?? "").lowercased()
        let action = extractArgString(from: args, key: "action")

        if lowerName == "nodes" {
            return resolveNodesDisplay(action: action, args: args).withPhase(phase)
        }

        let summary = ToolDisplayRegistry.resolve(name: name, args: args)
        let sfSymbol = sfSymbolForEmoji(summary.emoji)
        let text = [summary.label, summary.detailLine].compactMap { $0 }.joined(separator: " · ")
        let isEditingInstruction = editingInstructionToolNames.contains(lowerName)
        return ActionLifecycleDisplay(
            sfSymbol: sfSymbol,
            text: text,
            phase: phase,
            presentation: isEditingInstruction ? .editingInstruction : .card
        )
    }

    private var editingInstructionToolNames: Set<String> {
        ["write", "edit", "exec"]
    }

    private func resolveNodesDisplay(action: String?, args: OpenClawKit.AnyCodable?) -> ActionLifecycleDisplay {
        switch action {
        case "status":
            return ActionLifecycleDisplay(sfSymbol: "macbook.and.iphone", text: "Checking connected devices")
        case "invoke":
            return resolveNodeInvokeDisplay(args: args)
        case "describe":
            return ActionLifecycleDisplay(sfSymbol: "info.circle", text: "Getting device info")
        case "notify":
            return ActionLifecycleDisplay(sfSymbol: "bell", text: "Sending notification")
        case "pending":
            return ActionLifecycleDisplay(sfSymbol: "person.badge.clock", text: "Checking pending devices")
        case "approve":
            return ActionLifecycleDisplay(sfSymbol: "checkmark.circle", text: "Approving device")
        case "camera_snap":
            return ActionLifecycleDisplay(sfSymbol: "camera", text: "Taking photo")
        case "camera_list":
            return ActionLifecycleDisplay(sfSymbol: "camera", text: "Listing cameras")
        case "camera_clip":
            return ActionLifecycleDisplay(sfSymbol: "video", text: "Recording video")
        case "screen_record":
            return ActionLifecycleDisplay(sfSymbol: "rectangle.dashed.badge.record", text: "Recording screen")
        default:
            return ActionLifecycleDisplay(sfSymbol: "macbook.and.iphone", text: action.map { "Nodes · \($0)" } ?? "Nodes")
        }
    }

    private func resolveNodeInvokeDisplay(args: OpenClawKit.AnyCodable?) -> ActionLifecycleDisplay {
        let command = extractArgString(from: args, key: "command") ?? ""
        let (sfSymbol, verb) = nodeCommandDisplay(command)
        return ActionLifecycleDisplay(sfSymbol: sfSymbol, text: verb)
    }

    private func nodeCommandDisplay(_ command: String) -> (sfSymbol: String, verb: String) {
        switch command {
        case "calendar.events", "calendar.search": return ("calendar", "Checking calendar")
        case "calendar.add": return ("calendar.badge.plus", "Creating event")
        case "calendar.update": return ("calendar.badge.clock", "Updating event")
        case "calendar.delete": return ("calendar.badge.minus", "Deleting event")
        case "reminders.list", "reminders.search": return ("asset.apple-reminders-logo", "Searching through reminders")
        case "reminders.add": return ("asset.apple-reminders-logo", "Creating reminder")
        case "reminders.update": return ("asset.apple-reminders-logo", "Updating reminder")
        case "reminders.delete": return ("asset.apple-reminders-logo", "Deleting reminder")
        case "device.status": return ("battery.100", "Checking device status")
        case "device.info": return ("iphone", "Getting device info")
        case "system.notify": return ("bell", "Sending notification")
        case "system.which": return ("magnifyingglass", "Checking capabilities")
        default:
            let parts = command.split(separator: ".")
            if parts.count >= 2 {
                return ("iphone", "\(parts[0].capitalized) · \(parts[1])")
            }
            return ("iphone", command.isEmpty ? "Running command" : command)
        }
    }

    private func sfSymbolForEmoji(_ emoji: String) -> String {
        switch emoji {
        case "🛠️": return "wrench"
        case "📖": return "book"
        case "✍️": return "pencil"
        case "📝": return "doc.text"
        case "📎": return "paperclip"
        case "🧰": return "gearshape.2"
        case "🌐": return "globe"
        case "📱": return "iphone"
        case "⏰": return "clock"
        case "🔌": return "bolt"
        case "🟢": return "message"
        case "💬": return "bubble.left"
        case "🖼️": return "photo"
        default: return "puzzlepiece"
        }
    }

    private func extractArgString(from args: OpenClawKit.AnyCodable?, key: String) -> String? {
        guard let args else { return nil }
        if let dict = args.value as? [String: Any], let val = dict[key] as? String {
            return val
        }
        if let dict = args.value as? [String: OpenClawKit.AnyCodable], let val = dict[key]?.value as? String {
            return val
        }
        return nil
    }

    // MARK: - Streaming Bubble (with thinking block parsing)

    @ViewBuilder
    private func streamingBubble(_ text: String) -> some View {
        let segments = Self.parseStreamingText(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .thinking:
                    let cleanedText = Self.cleanThinkingTextForDisplay(segment.text)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let activityDisplay = Self.streamingThinkingActivityDisplay(from: segment.text)
                    let displayText = activityDisplay?.liveText ?? cleanedText
                    if !displayText.isEmpty {
                        if SharedChatDiagnosticDisplay.isRuntimeDiagnostic(cleanedText) {
                            thinkingBlock(displayText, sectionId: "streaming-\(segment.id)", phase: .live)
                            runtimePairingRecoveryCard(for: displayText)
                        } else if let activityDisplay,
                                  !runActivityAccumulator.displays.contains(where: {
                            $0.sfSymbol == activityDisplay.sfSymbol && $0.liveText == displayText
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.caption)
                                    Text("Thinking…")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(DesignTokens.Color.labelTertiary)

                                Text(displayText)
                                    .font(.system(.footnote).italic())
                                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .response:
                    let cleaned = MessageCleaner.cleanAssistantMessage(segment.text)
                    if let diagnostics = cleaned.diagnosticsText {
                        thinkingBlock(diagnostics, sectionId: "streaming-\(segment.id)-diagnostic", phase: .live)
                        runtimePairingRecoveryCard(for: diagnostics)
                    }

                    let displayText = preprocessStreamingMarkdown(
                        cleaned.displayText,
                        callSite: "streaming.response"
                    )
                    if !displayText.isEmpty,
                       !SharedChatDiagnosticDisplay.isRuntimeDiagnostic(displayText) {
                        AssistantMarkdownView(markdown: displayText)
                    }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Streaming Text Parser

    private enum StreamingSegmentKind {
        case thinking, response
    }

    private struct StreamingSegment: Identifiable {
        let id = UUID()
        let kind: StreamingSegmentKind
        let text: String
    }

    /// Splits streaming text on `<think>`/`</think>` tags into typed segments.
    private static func parseStreamingText(_ raw: String) -> [StreamingSegment] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard raw.range(of: "<think", options: .caseInsensitive) != nil else {
            return [StreamingSegment(kind: .response, text: trimmed)]
        }

        var segments: [StreamingSegment] = []
        var remaining = raw[...]

        while let openRange = remaining.range(of: "<think>", options: .caseInsensitive) {
            let before = remaining[remaining.startIndex..<openRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty {
                segments.append(StreamingSegment(kind: .response, text: before))
            }
            remaining = remaining[openRange.upperBound...]

            if let closeRange = remaining.range(of: "</think>", options: .caseInsensitive) {
                let thinking = remaining[remaining.startIndex..<closeRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !thinking.isEmpty {
                    segments.append(StreamingSegment(kind: .thinking, text: thinking))
                }
                remaining = remaining[closeRange.upperBound...]
            } else {
                let thinking = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                if !thinking.isEmpty {
                    segments.append(StreamingSegment(kind: .thinking, text: thinking))
                }
                remaining = remaining[remaining.endIndex...]
            }
        }

        let after = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty {
            segments.append(StreamingSegment(kind: .response, text: after))
        }

        return segments.isEmpty ? [StreamingSegment(kind: .response, text: trimmed)] : segments
    }
}

struct SharedChatThinkingBlock: View {
    let text: String
    let sectionId: String
    var phase: ActionLifecycleDisplay.Phase = .historical
    @Binding var expandedSections: Set<String>

    private var collapsedTitle: String {
        SharedChatDiagnosticDisplay.collapsedTitle(for: text, isLive: phase == .live)
    }

    private var collapsedIcon: String {
        SharedChatDiagnosticDisplay.collapsedIcon(for: text)
    }

    var body: some View {
        SharedChatCollapsibleSection(
            icon: collapsedIcon,
            title: collapsedTitle,
            sectionId: sectionId,
            expandedSections: $expandedSections
        ) {
            SharedChatThinkingContent(text: text)
                .clipped()
        }
    }
}

/// R3 (#812): collapsed container for a consolidated run of thoughts.
///
/// Reuses `SharedChatThinkingBlock`'s collapse affordance + `SharedChatThinkingContent`
/// markdown rendering, but renders one "Thinking · N steps" header over the deduped
/// `ThinkingBlockGrouping.Group`. Identical diagnostics appear once with an "×N" badge
/// instead of stacking as separate rows.
struct SharedChatThinkingGroupBlock: View {
    let group: ThinkingBlockGrouping.Group
    let sectionId: String
    @Binding var expandedSections: Set<String>

    /// Warn icon when any folded thought is a runtime diagnostic, else the brain.
    private var collapsedIcon: String {
        group.entries.contains { SharedChatDiagnosticDisplay.isRuntimeDiagnostic($0.text) }
            ? "exclamationmark.triangle"
            : "brain"
    }

    private var collapsedTitle: String {
        "Thinking · \(group.stepCount) steps"
    }

    var body: some View {
        SharedChatCollapsibleSection(
            icon: collapsedIcon,
            title: collapsedTitle,
            sectionId: sectionId,
            expandedSections: $expandedSections
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.entries) { entry in
                    thinkingEntry(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func thinkingEntry(_ entry: ThinkingBlockGrouping.Entry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            SharedChatThinkingContent(text: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.occurrences > 1 {
                Text("×\(entry.occurrences)")
                    .font(DesignTokens.Typography.chatMeta.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(DesignTokens.Color.fillTertiary)
                    )
                    .accessibilityLabel("Repeated \(entry.occurrences) times")
            }
        }
    }
}

private struct SharedChatThinkingContent: View {
    let text: String
    @State private var fadeState = ThinkingFadeState()

    var body: some View {
        let scrollView = ScrollView {
            AssistantMarkdownView(markdown: text, tone: .secondary)
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
        .scrollIndicators(.hidden)

        if #available(iOS 18.0, macOS 15.0, *) {
            scrollView
                .onScrollGeometryChange(for: ThinkingFadeState.self) { geometry in
                    let visibleMinY = geometry.contentOffset.y
                    let visibleMaxY = geometry.contentOffset.y + geometry.containerSize.height
                    let hasOverflow = geometry.contentSize.height > geometry.containerSize.height + 1
                    return ThinkingFadeState(
                        showsTop: hasOverflow && visibleMinY > 1,
                        showsBottom: hasOverflow && geometry.contentSize.height > visibleMaxY + 1
                    )
                } action: { _, newValue in
                    fadeState = newValue
                }
                .thinkingVerticalFades(fadeState)
        } else {
            scrollView
        }
    }
}

private struct ThinkingFadeState: Equatable {
    var showsTop = false
    var showsBottom = false
}

private extension View {
    func thinkingVerticalFades(_ state: ThinkingFadeState) -> some View {
        overlay(alignment: .top) {
            if state.showsTop {
                LinearGradient(
                    colors: [
                        DesignTokens.Color.backgroundPrimary,
                        DesignTokens.Color.backgroundPrimary.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 24)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if state.showsBottom {
                LinearGradient(
                    colors: [
                        DesignTokens.Color.backgroundPrimary.opacity(0),
                        DesignTokens.Color.backgroundPrimary
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 24)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Typing Dots

/// Animated bouncing dots for the typing indicator. Namespaced under
/// `Shared` prefix to avoid collision with the iOS `RemChatView` file's
/// legacy `TypingDots` (which we keep until iOS fully migrates to this view).
struct SharedChatTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 0.55 : (animate ? 0.85 : 0.25))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(idx) * 0.2),
                        value: animate)
            }
        }
        .onAppear { updateAnimationState() }
        .onDisappear { animate = false }
        .onChange(of: scenePhase) { _, _ in updateAnimationState() }
        .onChange(of: reduceMotion) { _, _ in updateAnimationState() }
    }

    private func updateAnimationState() {
        guard !reduceMotion, scenePhase == .active else {
            animate = false
            return
        }
        animate = true
    }
}

// MARK: - Full-screen image viewer

/// Identifiable wrapper so a tapped sent image can drive a `fullScreenCover` /
/// `sheet` item presentation.
struct ZoomedImage: Identifiable {
    let id = UUID()
    let image: OpenClawPlatformImage
}

/// Pinch / double-tap zoomable full-screen viewer for a sent image. Mirrors the
/// ChatGPT/Claude "tap an image to view larger" behavior.
struct FullScreenImageViewer: View {
    let image: OpenClawPlatformImage
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            imageView
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value, 1), 5)
                        }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2.5
                        lastScale = scale
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 16)
            .accessibilityLabel("Close")
        }
    }

    private var imageView: Image {
        #if canImport(UIKit)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}

#if os(iOS)
// MARK: - Camera picker (iOS)

/// Thin `UIImagePickerController` wrapper for the "+" sheet's Camera row. Returns
/// the captured photo (or `nil` if the user cancels) and dismisses itself.
struct CameraImagePicker: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker
        init(_ parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.onCapture(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCapture(nil)
            parent.dismiss()
        }
    }
}
#endif
