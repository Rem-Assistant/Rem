import SwiftUI
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

/// iOS chat view — thin wrapper around `SharedRemChatView` that wires the
/// iOS-only services (UsageService quota enforcement, RemTalkModeManager
/// voice pipeline) into the shared view's optional hooks.
///
/// The shared view lives in `Shared/Views/Chat/SharedRemChatView.swift` and
/// is also rendered by `RemClawMac/Sources/UI/MacChatWindow.swift`. Both
/// platforms therefore render the same Rem custom chat surface (#305 (Mac
/// chat parity epic)).
struct RemChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(UsageService.self) private var usageService
    @Environment(RemGatewaySessionManager.self) private var gateway
    @Bindable var viewModel: OpenClawChatViewModel
    let requestSlotHandoff: TextRequestSlotHandoff
    var isTalkModeActive: Bool = false
    /// Passed straight to `SharedRemChatView` — the real gateway connection state, so the in-chat
    /// status card reflects actual gateway state (waking / pairing / unreachable), not generic
    /// chat loading.
    var gatewayConnectionState: GatewayConnectionState = .connected
    /// Loading/error is distinct from a verified empty provider set. A prior snapshot is retained
    /// only within the exact same operator-session + catalog-candidate scope.
    @State private var runtimeProviderAuthEvidence = RuntimeProviderAuthEvidence.loading(
        lastVerifiedProviderIDs: nil)
    @State private var providerEvidenceScopeID: String?
    /// Bounds stale usable-auth evidence when a credential expires or is repaired externally while
    /// this chat remains open. Reconnect and foreground transitions refresh immediately as well.
    @State private var providerEvidenceRefreshRevision: UInt64 = 0
    /// Forwarded to `SharedRemChatView`: true when this chat was just created (New conversation /
    /// starter / skill hand-off) so it skips the loading skeleton and shows the starter immediately.
    var isFreshConversation: Bool = false
    /// Existing-session title captured by the sessions list for honest first-frame presentation.
    var initialExistingSessionTitle: String? = nil
    /// Session key requested by the navigation destination. The shared view uses it to avoid
    /// painting messages from the previous view-model binding while the asynchronous switch runs.
    var requestedSessionKey: String? = nil
    var autoStartVoice: Bool = false
    var onVoiceTap: (() -> Void)?

    // Voice mode support
    var talkMode: RemTalkModeManager?
    var onEndVoice: (() -> Void)?
    var onStopReadingAloud: (() -> Void)?
    var onRetryReadingAloud: (() -> Void)?
    var talkStartDate: Date?
    /// Personalized empty-chat starters, derived by the caller from the same suggestion signals
    /// that feed the Agenda (WS2 "3 surfaces"). Defaults to the generic set.
    var starterPrompts: [SharedRemChatView.FirstChatPrompt] = SharedRemChatView.firstChatPrompts
    /// Attributed, one-tap task proposals rendered after the canonical Daily Brief in the durable
    /// orchestrator conversation. Agenda remains their source of truth and owns accept/dismiss.
    var orchestratorSuggestionSnapshot: OrchestratorSuggestionSnapshot?
    var onAcceptSuggestion: ((TaskSuggestion) -> Void)?
    var onDismissSuggestion: ((TaskSuggestion) -> Void)?
    /// Temporary visible bridge from Agenda while today's durable transcript artifact is pending.
    var briefPreviewMarkdown: String? = nil
    /// Live exact artifact resolved after the destination has already opened.
    var resolvedBriefMarkdown: Binding<String?> = .constant(nil)
    /// Summary/read doorway only: anchor the restored transcript at today's delivered brief.
    var scrollToLatestBrief: Bool = false
    var sessionPreviewContext: SessionPreviewContext = SessionPreviewContext()
    var onOpenDeviceConnections: (() -> Void)?
    var onRetryConnection: (() -> Void)?
    var runLifecycleEvidenceStore: RunLifecycleEvidenceStore?

    /// Bumped after sending a message to force sessionDisplayName to re-evaluate.
    @State private var sessionNameRefresh: Int = 0

    private var hasQuota: Bool {
        usageService.hasQuotaForUI
    }

    private var providerCandidateIDs: [String] {
        ModelPickerPolicy.providerIDsForRuntimeEvidence(
            models: viewModel.modelChoices,
            requestedSelectionID: viewModel.modelSelectionID)
    }

    private var providerEvidenceTaskID: String {
        ([
            gateway.operatorReady.description,
            String(gateway.operatorSessionGeneration),
            gateway.storedGatewayURL ?? "",
            String(gateway.skillsSnapshotVersion),
            String(providerEvidenceRefreshRevision),
        ] + providerCandidateIDs)
            .joined(separator: "|")
    }

    var body: some View {
        SharedRemChatView(
            viewModel: viewModel,
            starterPrompts: starterPrompts,
            orchestratorSuggestionSnapshot: orchestratorSuggestionSnapshot,
            onAcceptSuggestion: onAcceptSuggestion,
            onDismissSuggestion: onDismissSuggestion,
            briefPreviewMarkdown: briefPreviewMarkdown,
            resolvedBriefMarkdown: resolvedBriefMarkdown,
            scrollToLatestBrief: scrollToLatestBrief,
            hasQuota: { usageService.hasQuotaForUI },
            consumeSendSlot: { @MainActor in
                await consumeQuotaSlot()
            },
            showsQuotaExceededBanner: !usageService.hasQuotaForUI,
            quotaExceededBannerText: usageService.quotaPresentation.bannerText,
            onQuotaExceededBannerTap: {
                usageService.presentCurrentQuotaDenial()
            },
            isVoiceModeActive: isTalkModeActive,
            gatewayConnectionState: gatewayConnectionState,
            briefAccountID: gateway.authenticatedAccountIDForRecovery,
            runtimeProviderAuthEvidence: runtimeProviderAuthEvidence,
            modelsSettingsDestination: {
                AnyView(SharedModelsSettingsScreen(
                    gateway: gateway,
                    runtimeProviderAuthEvidence: runtimeProviderAuthEvidence
                ) {
                    viewModel.refresh()
                })
            },
            isFreshConversation: isFreshConversation,
            initialExistingSessionTitle: initialExistingSessionTitle,
            requestedSessionKey: requestedSessionKey,
            autoStartVoice: autoStartVoice,
            onVoiceTap: onVoiceTap,
            voiceTranscriptionState: mappedTranscriptionState,
            voiceTranscripts: talkMode.map { Array($0.voiceTranscripts) },
            onEndVoice: onEndVoice,
            voiceStatusText: talkMode?.statusText,
            voiceResponsePhase: talkMode?.responsePhase ?? .idle,
            voiceIsReadingAloud: talkMode?.isReadingAloud ?? false,
            voiceCanRetryReadingAloud: talkMode?.canRetryReadingAloud ?? false,
            voiceIsMuted: talkMode?.isMuted ?? false,
            onToggleMute: { toggleVoiceMute() },
            onStopReadingAloud: {
                if let onStopReadingAloud {
                    onStopReadingAloud()
                } else {
                    talkMode?.stopReadingAloud(continueListening: true)
                }
            },
            onRetryReadingAloud: onRetryReadingAloud,
            voiceStartDate: talkStartDate,
            voiceAutoCloseAt: talkMode?.autoCloseAt,
            voiceAutoCloseCountdownDuration: talkMode?.voiceAutoCloseCountdownDuration ?? 30,
            onKeepVoiceOpen: { talkMode?.keepVoiceOpen() },
            onAfterSend: {
                if let tm = talkMode, tm.isEnabled {
                    tm.speakNextResponse()
                }
                // Force nav title to re-read after the transport auto-names.
                // Note: NOT done synchronously here (would trigger "Modifying
                // state during view update" — this runs on a background Task
                // whose continuation resumes on the next runloop tick).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    sessionNameRefresh += 1
                }
            },
            sessionPreviewContext: sessionPreviewContext,
            onOpenDeviceConnections: onOpenDeviceConnections,
            onRetryConnection: onRetryConnection,
            runLifecycleEvidenceStore: runLifecycleEvidenceStore,
            sessionNameRefreshToken: sessionNameRefresh,
            localSessionName: { SessionDisplayNames.name(for: $0) },
            setSessionName: { name, key in
                SessionDisplayNames.setName(name, for: key)
            }
        )
        .task(id: providerEvidenceTaskID) {
            let sessionGeneration = gateway.operatorSessionGeneration
            let scopeID = ([String(sessionGeneration)] + providerCandidateIDs)
                .joined(separator: "|")
            let priorSameScopeEvidence = providerEvidenceScopeID == scopeID
                ? runtimeProviderAuthEvidence
                : nil
            let lastVerified = priorSameScopeEvidence?.hasAuthoritativeSnapshot == true
                ? priorSameScopeEvidence?.effectiveProviderIDs
                : nil
            providerEvidenceScopeID = scopeID
            runtimeProviderAuthEvidence = priorSameScopeEvidence?.beginningSameScopeRefresh
                ?? .loading(lastVerifiedProviderIDs: nil)
            guard gateway.operatorReady else {
                runtimeProviderAuthEvidence = .failed(lastVerifiedProviderIDs: lastVerified)
                return
            }
            do {
                let loaded = try await gateway.loadRuntimeConfiguredProviderIDs(
                    candidateProviderIDs: providerCandidateIDs)
                guard !Task.isCancelled,
                      gateway.operatorReady,
                      gateway.operatorSessionGeneration == sessionGeneration,
                      providerEvidenceScopeID == scopeID
                else { return }
                runtimeProviderAuthEvidence = .verified(loaded)
            } catch {
                guard !Task.isCancelled,
                      gateway.operatorReady,
                      gateway.operatorSessionGeneration == sessionGeneration,
                      providerEvidenceScopeID == scopeID
                else { return }
                runtimeProviderAuthEvidence = .resolvingLoadFailure(
                    error,
                    priorSameScopeEvidence: priorSameScopeEvidence
                )
            }
        }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                providerEvidenceRefreshRevision &+= 1
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                providerEvidenceRefreshRevision &+= 1
            }
        }
        .task { try? await usageService.fetchSummary() }
        // Voice mini-player bar is rendered by the shared view via
        // onEndVoice/voiceStatusText/voiceIsMuted inputs.
    }

    private func toggleVoiceMute() {
        guard let tm = talkMode else { return }
        if tm.isMuted {
            tm.unmute()
        } else {
            tm.mute()
        }
    }

    // MARK: - Voice Transcription Bridge

    /// Translates the iOS-specific `RemTalkModeManager.VoiceTranscriptionState`
    /// into the shared view's `SharedRemChatView.VoiceTranscriptionState`.
    private var mappedTranscriptionState: SharedRemChatView.VoiceTranscriptionState? {
        // The talk manager is app-global, so its transcription state must be scoped to the
        // conversation the voice session is actually attached to — otherwise the last transcription
        // ("do you think we could go faster") renders as a bubble in EVERY open chat, not just the
        // one being spoken into.
        guard let tm = talkMode, tm.attachedSessionKey == viewModel.sessionKey else { return nil }
        switch tm.transcriptionState {
        case .idle: return .idle
        case .transcribing(let partial): return .transcribing(partial: partial)
        case .sent(let text): return .sent(text: text)
        }
    }

    // MARK: - Quota Slot Consumption

    /// Attempts to consume a usage slot before sending. Returns true only after the backend
    /// authoritatively reserves the slot. Quota exhaustion opens the quota UI; an unavailable
    /// authority leaves the draft intact. An ambiguous response permanently suppresses reservation
    /// retries for that account in this service lifetime because no gateway-bound replay proof exists.
    @MainActor
    private func consumeQuotaSlot() async -> Bool {
        // The same freshness-filtered evidence drives the composer and this final local preflight.
        // Retained summary zero must not be re-stamped when the first post-reset send reaches here.
        if usageService.presentCurrentQuotaDenial() {
            return false
        }
        do {
            let reservation = try await usageService.consumeRequestSlot()
            requestSlotHandoff.install(reservation)
            usageService.dismissQuotaError()
            return true
        } catch {
            switch UsageSlotFailurePolicy.classify(error) {
            case .quotaExceeded(let quota):
                usageService.handleQuotaExceeded(quota)
            case .verificationUnavailable:
                viewModel.errorText = "Rem couldn't verify your plan right now. Check your connection and try again."
            case .reservationRetryBlocked:
                viewModel.errorText = "That message wasn't sent, but its quota check may have counted. To avoid counting it twice, don't retry it. Check Usage or contact support."
            }
            return false
        }
    }
}
