import SwiftUI
import OpenClawChatUI
import OpenClawKit

/// Chat window for Rem for Mac.
/// Uses OpenClawChatUI's OpenClawChatView with a transport backed by
/// the operator session.
struct MacChatWindow: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(MacGatewaySessionManager.self) private var session
    @Environment(MacRouter.self) private var router
    @Environment(\.localGateway) private var localGateway
    @Environment(MacTaskStore.self) private var taskStore
    @Environment(MacOrchestratorSuggestionStore.self) private var orchestratorSuggestionStore
    @State private var chatViewModel: OpenClawChatViewModel?
    @State private var transport: MacChatTransport?
    @State private var runLifecycleEvidenceStore = RunLifecycleEvidenceStore()
    @State private var chatTransportSetupGate = ChatTransportSetupGate()
    @State private var quotaService = MacQuotaService()
    /// Provider menus require the active gateway model-auth runtime's usable-auth evidence on both
    /// cloud and local routes. Raw local auth-profile membership is only a refresh revision.
    @State private var runtimeProviderAuthEvidence = RuntimeProviderAuthEvidence.loading(
        lastVerifiedProviderIDs: nil)
    @State private var providerEvidenceScopeID: String?
    /// Bounds stale usable-auth evidence when a credential expires or is repaired externally while
    /// this chat remains open. Reconnect and foreground transitions refresh immediately as well.
    @State private var providerEvidenceRefreshRevision: UInt64 = 0
    /// True when the active chat was opened as a BRAND-NEW conversation (fresh-chat init with no
    /// session key) rather than an existing session picked from the Sessions tab. A new conversation
    /// has no server history to load, so `SharedRemChatView` shows the starter immediately instead of
    /// the loading skeleton (FIX 1). Set false whenever we switch to an existing session key.
    @State private var isFreshConversation: Bool = false
    /// The route the Mac sessions UI asked this shared chat surface to display. This is separate
    /// from `chatViewModel.sessionKey`, which changes asynchronously, so the shared gate can hide
    /// the prior transcript from the first frame of a session switch.
    @State private var requestedSessionKey: String?
    /// Mac voice pipeline (PR 1 for #321 (Voice on Mac parity mini-epic)).
    /// STT only for now — TTS playback lands in PR 2, audio-route handling
    /// in PR 3. The manager is created lazily on first voice tap so we don't
    /// allocate SFSpeechRecognizer / AVAudioEngine for users who never use
    /// voice.
    @State private var talkMode: RemMacTalkModeManager?
    @State private var talkStartDate: Date?
    @State private var showApprovalsSheet = false
    @State private var showRecoveryDetails = false

    var body: some View {
        AnyView(Group {
            if !session.isAuthenticated {
                notSignedInView
                    .navigationTitle("Chat")
            } else if !session.sessionHealth.operatorUsable {
                operatorUnavailableView
                    .navigationTitle("Chat")
            } else if let vm = chatViewModel {
                AnyView(VStack(spacing: 0) {
                    if shouldShowNodeRecoveryBanner {
                        nodeRecoveryBanner
                    }
                    AnyView(SharedRemChatView(
                        viewModel: vm,
                        orchestratorSuggestionSnapshot: activeOrchestratorSuggestionSnapshot,
                        onAcceptSuggestion: acceptOrchestratorSuggestion,
                        onDismissSuggestion: dismissOrchestratorSuggestion,
                        hasQuota: { macHasQuotaForUI },
                        consumeSendSlot: { @MainActor [dispatchContext = transport?.quotaDispatchContext] in
                            await consumeQuotaSlot(
                                viewModel: vm,
                                dispatchContext: dispatchContext
                            )
                        },
                        showsQuotaExceededBanner: !macHasQuotaForUI,
                        quotaExceededBannerText: quotaBannerMessage,
                        onQuotaExceededBannerTap: {
                            vm.errorText = quotaBannerMessage
                        },
                        // Scope the voice mini-bar to the conversation the voice session is attached to.
                        // `talkMode` is a single per-window manager, so a bare `isEnabled` shows the bar in
                        // EVERY open chat (incl. a New Chat) while voice is only attached to one session.
                        // Mirror the transcription-state scoping in `mappedVoiceTranscriptionState`
                        // (guards on `tm.attachedSessionKey == chatViewModel?.sessionKey`).
                        isVoiceModeActive: (talkMode?.isEnabled ?? false) && talkMode?.attachedSessionKey == vm.sessionKey,
                        // Gate the waking card on OPERATOR usability, not the aggregate connection
                        // state. Mac keeps chat usable when only the node leg is down (operator up →
                        // `operatorUsable`, with the nodeRecoveryBanner explaining limited tools). The
                        // aggregate would be .unreachable/.pairingRequired in that partial-failure
                        // state, which would wrongly blank the transcript + disable the composer.
                        gatewayConnectionState: session.sessionHealth.operatorUsable ? .connected : session.connectionState,
                        briefAccountID: session.authenticatedAccountIDForRecovery,
                        // Both local and managed gateways expose non-GMI choices only when the
                        // active gateway's model-auth runtime confirms usable auth. Local profile
                        // metadata and the Mac Keychain can invalidate this snapshot but never
                        // authorize a provider by themselves.
                        runtimeProviderAuthEvidence: runtimeProviderAuthEvidence,
                        modelsSettingsDestination: {
                            AnyView(SharedModelsSettingsScreen(
                                gateway: session,
                                runtimeProviderAuthEvidence: runtimeProviderAuthEvidence
                            ) {
                                vm.refresh()
                            })
                        },
                        isFreshConversation: isFreshConversation,
                        requestedSessionKey: requestedSessionKey,
                        onVoiceTap: { startVoiceSession() },
                        voiceTranscriptionState: mappedVoiceTranscriptionState,
                        voiceTranscripts: talkMode.map { Array($0.voiceTranscripts) },
                        onEndVoice: { stopVoiceSession() },
                        voiceStatusText: talkMode?.statusText,
                        voiceResponsePhase: talkMode?.responsePhase ?? .idle,
                        voiceIsMuted: talkMode?.isMuted ?? false,
                        onToggleMute: { talkMode?.toggleMute() },
                        voiceInputModeIsPTT: talkMode?.inputMode == .pushToTalk,
                        onToggleVoiceInputMode: { talkMode?.togglePushToTalkMode() },
                        voiceStartDate: talkStartDate,
                        onAfterSend: {
                            if let tm = talkMode, tm.isEnabled {
                                tm.speakNextResponse()
                            }
                        },
                        sessionPreviewContext: session.sessionPreviewContext,
                        runLifecycleEvidenceStore: runLifecycleEvidenceStore,
                        localSessionName: { key in
                            // Mac layers its own per-device store on top of the
                            // shared store. Keeps existing Mac-only chat names
                            // working during migration to the shared store.
                            MacSessionDisplayNames.name(for: key)
                                ?? SessionDisplayNames.name(for: key)
                        },
                        setSessionName: { name, key in
                            // Write to both stores so both Mac sessions list and
                            // shared chat view read the updated name. Persist to
                            // gateway so names survive across devices.
                            MacSessionDisplayNames.setName(name, for: key)
                            SessionDisplayNames.setName(name, for: key)
                            Task { @MainActor in
                                await patchSessionLabel(key: key, label: name)
                            }
                        }
                    ))
                }
                .accessibilityIdentifier("mac-chat-view")
                .onChange(of: session.connectionState) { _, newState in
                    talkMode?.updateGatewayConnected(newState.isConnected)
                }
                .onChange(of: vm.sessionKey) { _, newKey in
                    talkMode?.updateSessionKey(newKey)
                    refreshOrchestratorSuggestionsIfNeeded(for: newKey)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    refreshOrchestratorSuggestionsIfNeeded(for: vm.sessionKey)
                }
                )
            } else {
                // Operator usability is already established by the branch above;
                // only the async view-model construction remains.
                ChatConnectionLoadingView(connectionState: .connected)
                    .navigationTitle("Chat")
            }
        })
        .frame(minWidth: 480, minHeight: 400)
        .sheet(isPresented: $showApprovalsSheet) {
            NavigationStack {
                SharedDevicePairingListView(gateway: session)
            }
            .frame(minWidth: 520, minHeight: 460)
        }
        .onChange(of: session.operatorReady) { _, ready in
            if ready {
                initializeChatIfNeeded(route: consumePendingChatRoute())
            } else {
                chatTransportSetupGate.invalidate()
                chatViewModel = nil
                transport = nil
            }
        }
        .onChange(of: orchestratorSuggestionScopeID) { _, newScopeID in
            // MainWindow owns synchronous invalidation across authentication changes. Chat only
            // starts the replacement refresh for the active orchestrator session.
            if let sessionKey = chatViewModel?.sessionKey {
                refreshOrchestratorSuggestionsIfNeeded(for: sessionKey)
            }
        }
        .onDisappear {
            chatTransportSetupGate.invalidate()
        }
        .task {
            // First-render init. Consume pendingSessionKey here so a click
            // from the Sessions tab opens that session instead of racing
            // with a fresh-chat init (the previous impl called
            // `initializeChatIfNeeded()` unconditionally on .task AND
            // consumed pendingSessionKey in .onAppear, so the "new chat"
            // init could win the race). See #305 Mac chat parity followup.
            if session.operatorReady {
                initializeChatIfNeeded(route: consumePendingChatRoute())
            }
        }
        .task(id: quotaSummaryTaskID) {
            guard session.isAuthenticated else { return }
            await session.fetchUsageSummary()
            guard macUsageSummaryIsCurrent, let remaining = session.usageSummary?.remaining else { return }
            quotaService.recordAuthoritativeRemaining(remaining)
        }
        .task(id: providerEvidenceTaskID) {
            let sessionGeneration = session.operatorSessionGeneration
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
            guard session.operatorReady else {
                runtimeProviderAuthEvidence = .failed(lastVerifiedProviderIDs: lastVerified)
                return
            }
            do {
                let loaded = try await session.loadRuntimeConfiguredProviderIDs(
                    candidateProviderIDs: providerCandidateIDs)
                guard !Task.isCancelled,
                      session.operatorReady,
                      session.operatorSessionGeneration == sessionGeneration,
                      providerEvidenceScopeID == scopeID
                else { return }
                runtimeProviderAuthEvidence = .verified(loaded)
            } catch {
                guard !Task.isCancelled,
                      session.operatorReady,
                      session.operatorSessionGeneration == sessionGeneration,
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
        .onChange(of: router.pendingSessionKey) { _, newKey in
            // Fires when the user taps another session AFTER chat is
            // already initialized (i.e. they're already on the chat
            // screen or returning to it). Safe to call even if it was
            // nil'd by .task above.
            guard let key = newKey else { return }
            let isFresh = router.pendingSessionIsFresh
            router.pendingSessionKey = nil
            router.pendingSessionIsFresh = false
            switchToSession(key, isFresh: isFresh)
        }
    }

    private var orchestratorSuggestionScopeID: String {
        [
            session.userProfile?.id ?? "",
            session.backendURL ?? "",
            session.effectiveGatewayScopeIdentity
        ].joined(separator: "|")
    }

    private var activeOrchestratorSuggestionSnapshot: OrchestratorSuggestionSnapshot? {
        orchestratorSuggestionStore.snapshot(for: orchestratorSuggestionScopeID)
    }

    private var quotaSummaryTaskID: String {
        [session.userProfile?.id ?? "", session.backendURL ?? "", session.isAuthenticated.description]
            .joined(separator: "|")
    }

    private var macUsageSummaryIsCurrent: Bool {
        !session.isLoadingUsage
            && !session.usageSummaryIsStale
            && session.usageLoadError == nil
    }

    private var macHasQuotaForUI: Bool {
        guard !quotaService.reservationRetryBlocked else { return false }
        guard let remaining = quotaService.effectiveRemaining(
            fallbackSummary: session.usageSummary,
            summaryIsCurrent: macUsageSummaryIsCurrent
        ) else { return true }
        return remaining.day > 0 && remaining.month > 0
    }

    private var quotaBannerMessage: String {
        let remaining = quotaService.effectiveRemaining(
            fallbackSummary: session.usageSummary,
            summaryIsCurrent: macUsageSummaryIsCurrent
        )
            ?? RemainingQuota(day: 0, month: 1)
        return MacQuotaBannerPolicy.message(
            reservationRetryBlocked: quotaService.reservationRetryBlocked,
            plan: macUsageSummaryIsCurrent ? session.usageSummary?.plan : nil,
            remaining: remaining
        )
    }

    @MainActor
    private func consumeQuotaSlot(
        viewModel: OpenClawChatViewModel,
        dispatchContext: MacQuotaDispatchContext?
    ) async -> Bool {
        guard let dispatchContext else {
            viewModel.errorText = "Rem couldn't verify your plan right now. Check your connection and try again."
            return false
        }
        do {
            _ = try await quotaService.consumeRequestSlot(dispatchContext: dispatchContext)
            return true
        } catch {
            switch MacQuotaFailurePolicy.classify(error) {
            case .quotaExceeded(let quota):
                viewModel.errorText = quota.message
            case .verificationUnavailable:
                viewModel.errorText = "Rem couldn't verify your plan right now. Check your connection and try again."
            case .reservationRetryBlocked:
                viewModel.errorText = "That message wasn't sent, but its quota check may have counted. "
                    + "To avoid counting it twice, don't retry it. Check Usage or contact support."
            }
            return false
        }
    }

    private func acceptOrchestratorSuggestion(_ suggestion: TaskSuggestion) {
        Task {
            await orchestratorSuggestionStore.accept(
                suggestion,
                taskStore: taskStore,
                scopeID: orchestratorSuggestionScopeID
            )
        }
    }

    private func dismissOrchestratorSuggestion(_ suggestion: TaskSuggestion) {
        Task {
            await orchestratorSuggestionStore.dismissSuggestion(
                suggestion,
                scopeID: orchestratorSuggestionScopeID
            )
        }
    }

    private func refreshOrchestratorSuggestionsIfNeeded(for sessionKey: String) {
        guard BriefContext.isDurableOrchestratorSession(sessionKey) else { return }
        Task {
            await orchestratorSuggestionStore.refresh(
                scopeID: orchestratorSuggestionScopeID,
                accountID: session.authenticatedAccountIDForRecovery
            )
        }
    }

    // MARK: - Placeholder Views

    private var providerCandidateIDs: [String] {
        ModelPickerPolicy.providerIDsForRuntimeEvidence(
            models: chatViewModel?.modelChoices ?? [],
            requestedSelectionID: chatViewModel?.modelSelectionID
                ?? OpenClawChatViewModel.defaultModelSelectionID)
    }

    private var providerEvidenceGatewayIdentity: String {
        [session.storedGatewayURL ?? "", session.activeLocalGatewayURL ?? ""]
            .joined(separator: "|")
    }

    private var providerEvidenceTaskID: String {
        ([
            session.operatorReady.description,
            String(session.operatorSessionGeneration),
            providerEvidenceGatewayIdentity,
            String(session.skillsSnapshotVersion),
            String(providerEvidenceRefreshRevision),
            // LocalGatewayLifecycle refreshes this metadata after auth-profiles changes. It only
            // invalidates the RPC snapshot; it never authorizes a provider by itself.
            (localGateway?.state.configuredProviders ?? []).sorted().joined(separator: ","),
        ] + providerCandidateIDs)
            .joined(separator: "|")
    }

    private var notSignedInView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sign In Required")
                .font(.title3.bold())
            Text("Sign in from the main window to use chat.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mac-chat-sign-in-required")
    }

    private var operatorUnavailableView: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.badge.clock")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(operatorRecoveryTitle)
                .font(.title3.bold())
            Text(operatorRecoveryMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            healthSummaryView

            HStack(spacing: 8) {
                if session.sessionHealth.recoveryHints.contains(.reconnect) {
                    Button("Connect") {
                        session.connectIfConfigured()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if session.sessionHealth.recoveryHints.contains(.rePairThisDevice) {
                    Button("Re-pair this Mac") {
                        session.resetPairing(localGateway: localGateway)
                    }
                    .buttonStyle(.bordered)
                }
                if session.sessionHealth.recoveryHints.contains(.openApprovalsList) {
                    Button("Open approvals list") {
                        openApprovalsList()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let detail = session.sessionHealth.detail, !detail.isEmpty {
                DisclosureGroup("Technical details", isExpanded: $showRecoveryDetails) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("mac-chat-operator-unavailable")
    }

    private var shouldShowNodeRecoveryBanner: Bool {
        let health = session.sessionHealth
        guard health.operatorUsable else { return false }
        if !health.nodeSessionState.isConnected { return true }
        if health.manualRecoveryState != .none { return true }
        if case .stopped = health.gatewayProcessState { return true }
        if case .failed(_) = health.gatewayProcessState { return true }
        return false
    }

    private var nodeRecoveryBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Gateway tools are limited")
                    .font(.headline)
                Spacer()
            }
            Text(nodeRecoveryMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            healthSummaryView

            HStack(spacing: 8) {
                if session.sessionHealth.recoveryHints.contains(.retryNodeConnection) {
                    Button("Retry node") {
                        session.reconnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if session.sessionHealth.recoveryHints.contains(.rePairThisDevice) {
                    Button("Re-pair this Mac") {
                        session.resetPairing(localGateway: localGateway)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if session.sessionHealth.recoveryHints.contains(.openApprovalsList) {
                    Button("Open approvals list") {
                        openApprovalsList()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let detail = session.sessionHealth.detail, !detail.isEmpty {
                DisclosureGroup("Technical details", isExpanded: $showRecoveryDetails) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var operatorRecoveryTitle: String {
        switch session.sessionHealth.manualRecoveryState {
        case .approvalRequired:
            return "Approval pending"
        case .rePairRequired:
            return "Gateway trust reset needed"
        case .nodeRetryRequired:
            return "Gateway reconnect needed"
        case .none:
            return "Chat is not connected"
        }
    }

    private var operatorRecoveryMessage: String {
        switch session.sessionHealth.manualRecoveryState {
        case .approvalRequired:
            return "Approve this Mac from pending requests, then reconnect."
        case .rePairRequired:
            return "The gateway no longer trusts this device token. Re-pair this Mac to continue."
        case .nodeRetryRequired:
            return "Operator is not ready yet. Reconnect to recover chat."
        case .none:
            return "Connect to your gateway to start chatting."
        }
    }

    private var nodeRecoveryMessage: String {
        switch session.sessionHealth.manualRecoveryState {
        case .approvalRequired:
            return "Chat is available, but the node session still needs approval or repair."
        case .rePairRequired:
            return "Chat is available, but node tools are blocked until this Mac is re-paired."
        case .nodeRetryRequired:
            return "Operator chat is connected, but node tools are offline. Retry or re-pair to restore full capability."
        case .none:
            return "Operator chat is connected. Node-dependent tools may be temporarily unavailable."
        }
    }

    private var healthSummaryView: some View {
        VStack(spacing: 6) {
            statusRow(
                label: "Operator",
                stateLabel: session.sessionHealth.operatorSessionState.label,
                color: legStateColor(session.sessionHealth.operatorSessionState)
            )
            statusRow(
                label: "Node",
                stateLabel: session.sessionHealth.nodeSessionState.label,
                color: legStateColor(session.sessionHealth.nodeSessionState)
            )
            statusRow(
                label: "Gateway Process",
                stateLabel: session.sessionHealth.gatewayProcessState.label,
                color: processStateColor(session.sessionHealth.gatewayProcessState)
            )
        }
        .frame(maxWidth: 520)
    }

    private func statusRow(label: String, stateLabel: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(stateLabel)
                .font(.caption.weight(.medium))
        }
    }

    private func legStateColor(_ state: GatewaySessionLegState) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .gray
        case .failed: .red
        }
    }

    private func processStateColor(_ state: GatewayProcessState) -> Color {
        switch state {
        case .running: .green
        case .starting: .orange
        case .stopped: .gray
        case .failed(_): .red
        case .unknown: .secondary
        }
    }

    // Pending tools bar and tool icon/label resolution moved to
    // `Shared/Views/Chat/SharedRemChatView.swift` where iOS and Mac share
    // a single `resolveToolCallDisplay(name:args:)` implementation backed by
    // the OpenClawKit `ToolDisplayRegistry`. See PR for #305 (Mac chat
    // parity epic).

    // MARK: - Session Label Persistence

    /// Writes the user-edited session display name to the gateway via
    /// `sessions.patch` so the name persists across reinstalls and other
    /// devices that list sessions. Fire-and-forget; failures are logged
    /// only in DEBUG builds.
    private func patchSessionLabel(key: String, label: String) async {
        struct PatchParams: Codable {
            var key: String
            var label: String
        }
        let params = PatchParams(key: key, label: label)
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8) else { return }
        let gatewaySession = await session.client.chatSession
        _ = try? await gatewaySession.request(
            method: "sessions.patch",
            paramsJSON: json,
            timeoutSeconds: 10)
    }

    // MARK: - Chat Initialization

    /// Atomically reads-and-clears `router.pendingSessionKey`. Used from
    /// both `.task` and `.onChange(operatorReady)` so the two init paths
    /// can't race against each other to both observe a non-nil key.
    private func consumePendingChatRoute() -> MacChatRoute? {
        guard let key = router.pendingSessionKey else { return nil }
        let route = MacChatRoute(sessionKey: key, isFresh: router.pendingSessionIsFresh)
        router.pendingSessionKey = nil
        router.pendingSessionIsFresh = false
        return route
    }

    private func chatBindingKey(sessionKey: String) -> String {
        [session.storedGatewayURL ?? "", sessionKey].joined(separator: "|")
    }

    private func initializeChatIfNeeded(route: MacChatRoute? = nil) {
        // Every real doorway supplies an explicit route. A restoration edge case with no pending
        // route falls back to a fresh chat—not a hardcoded durable namespace that an old backend
        // may never have populated.
        let resolved = route ?? MacChatRoute(
            sessionKey: "chat-\(UUID().uuidString.prefix(8).lowercased())",
            isFresh: true
        )
        let key = resolved.sessionKey
        refreshOrchestratorSuggestionsIfNeeded(for: key)
        isFreshConversation = resolved.isFresh
        requestedSessionKey = key
        guard ChatTransportSetupReadiness.isReady(
            operatorReady: session.operatorReady,
            sessionHealth: session.sessionHealth
        ) else {
            chatTransportSetupGate.invalidate()
            return
        }
        guard chatViewModel == nil else {
            // If we already have a view model but a specific key was requested, switch to it
            if route != nil {
                chatViewModel?.switchSession(to: key)
            }
            return
        }
        let bindingKey = chatBindingKey(sessionKey: key)
        let lifecycleStore = runLifecycleEvidenceStore
        let setupRequest = chatTransportSetupGate.begin(
            bindingKey: bindingKey,
            lifecycleStore: lifecycleStore
        )
        let quotaDispatchContext = quotaService.makeDispatchContext()
        Task {
            let newTransport = await session.makeChatTransport(
                quotaDispatchContext: quotaDispatchContext,
                onChatSendAcknowledged: { context in
                    quotaService.markReservedRequestAcknowledged(in: context)
                },
                onRunLifecycleEvidence: { evidence in
                    lifecycleStore.record(evidence)
                },
                lifecycleEpochSource: lifecycleStore.epochSource,
                initialLifecycleLease: setupRequest.lifecycleLease,
                onRunLifecycleEpoch: { epoch in
                    lifecycleStore.setCurrentConnectionEpoch(epoch)
                }
            )
            chatTransportSetupGate.commit(
                setupRequest.ticket,
                currentBindingKey: chatBindingKey(sessionKey: requestedSessionKey ?? key),
                isReady: ChatTransportSetupReadiness.isReady(
                    operatorReady: session.operatorReady,
                    sessionHealth: session.sessionHealth
                )
            ) {
                let vm = OpenClawChatViewModel(
                    sessionKey: key,
                    transport: newTransport)
                transport = newTransport
                chatViewModel = vm
            }
        }
    }

    /// Switch the active chat to a specific session key.
    private func switchToSession(_ sessionKey: String, isFresh: Bool = false) {
        // Switching to a named session = opening an existing conversation, so it may have history to
        // load → keep the loading skeleton (not a fresh conversation).
        isFreshConversation = isFresh
        requestedSessionKey = sessionKey
        refreshOrchestratorSuggestionsIfNeeded(for: sessionKey)
        if let vm = chatViewModel {
            vm.switchSession(to: sessionKey)
        } else {
            initializeChatIfNeeded(route: MacChatRoute(sessionKey: sessionKey, isFresh: isFresh))
        }
    }

    // MARK: - Voice Session (#321 (Voice on Mac parity mini-epic))
    //
    // Mirrors iOS `ContentView.startVoiceSession` / `stopVoiceSession`, minus
    // the iOS-only Live Activity wiring. Source of truth for voice
    // state is `talkMode` (RemMacTalkModeManager) — views read it through the
    // optional hooks on SharedRemChatView.

    /// Translates `RemMacTalkModeManager.VoiceTranscriptionState` → the
    /// shared view's `VoiceTranscriptionState`. Kept local so Mac-only voice
    /// types don't leak into `Shared/`.
    private var mappedVoiceTranscriptionState: SharedRemChatView.VoiceTranscriptionState? {
        // Scope the app-global manager's transcription to the conversation the voice session is
        // attached to — otherwise it renders as a bubble in every open chat (matches iOS RemChatView).
        guard let tm = talkMode, tm.attachedSessionKey == chatViewModel?.sessionKey else { return nil }
        switch tm.transcriptionState {
        case .idle: return .idle
        case .transcribing(let partial): return .transcribing(partial: partial)
        case .sent(let text): return .sent(text: text)
        }
    }

    /// Starts or reuses the voice manager and wires it to the active chat
    /// session. Lazy-creates the manager to avoid allocating audio resources
    /// for users who never touch voice.
    private func startVoiceSession() {
        let manager = talkMode ?? RemMacTalkModeManager()
        talkMode = manager
        Task {
            let gatewaySession = await session.client.chatSession
            manager.attachGateway(gatewaySession)
            manager.attachQuotaService(quotaService)
            manager.updateGatewayConnected(session.connectionState.isConnected)
            if let vm = chatViewModel {
                manager.updateSessionKey(vm.sessionKey)
            }
            talkStartDate = Date()
            manager.setEnabled(true)
        }
    }

    private func stopVoiceSession() {
        talkMode?.stop()
        talkStartDate = nil
    }

    private func openApprovalsList() {
        if !session.operatorReady {
            session.reconnect()
        }
        Task { await session.fetchPendingDevices() }
        showApprovalsSheet = true
    }
}
