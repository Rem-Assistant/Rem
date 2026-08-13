import AVFoundation
import Combine
import OpenClawKit
import SwiftUI

/// Gateway-backed voice selection for Rem's spoken responses.
///
/// Voice names come from the active gateway at runtime. This screen never asks
/// for provider credentials and never exposes provider implementation names.
/// Writes use a fresh `config.get` hash, patch the canonical nested Talk config,
/// then wait for the restarted gateway to confirm the effective selection.
struct SharedVoiceSettingsView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway

    @StateObject private var previewPlayer = VoiceSettingsPreviewPlayer()
    @State private var previewRequestGate = VoicePreviewRequestGate()
    @State private var voices: [VoiceSettingsVoice] = []
    @State private var providerID: String?
    @State private var selectedVoiceID: String?
    @State private var savingVoiceID: String?
    @State private var loadOperationActive = false
    @State private var reloadRequestedAfterActiveLoad = false
    @State private var operatorRecoveryTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var loadRecoveryAction: VoiceSettingsRecoveryAction = .retry
    @State private var isRecoveringConfiguration = false
    @State private var configurationRecoveryTask: Task<Void, Never>?
    @State private var configurationRecoveryAttemptID: UUID?
    @State private var configurationRecoveryReloadPending = false
    @State private var operationMessage: String?
    @State private var operationError: String?
    @State private var previewRequestTask: Task<Void, Never>?
    @State private var activePreviewAttemptID: String?
    @State private var tuning = VoiceTuningStore.settings

    var body: some View {
        Group {
            if isLoading, voices.isEmpty {
                VoiceSettingsOverviewLoadingSkeleton()
            } else if voices.isEmpty {
                emptyState
            } else {
                overview
            }
        }
        .navigationTitle("Voice")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .onChange(of: tuning) { _, newValue in
            // Persist immediately. The talk managers read the store when they build
            // each `talk.speak` request, so the next utterance picks this up without
            // a reconnect or a gateway restart.
            VoiceTuningStore.settings = newValue
        }
        .onChange(of: gateway.operatorReady) { wasReady, isReady in
            guard !wasReady, isReady, savingVoiceID == nil else { return }
            let recoveredConfiguration = VoiceConfigurationRecoveryPolicy.shouldConsumePendingReload(
                wasReady: wasReady,
                isReady: isReady,
                reloadPending: configurationRecoveryReloadPending
            )
            if recoveredConfiguration {
                configurationRecoveryReloadPending = false
            }
            operatorRecoveryTask?.cancel()
            operatorRecoveryTask = nil
            if loadOperationActive {
                reloadRequestedAfterActiveLoad = true
            } else if recoveredConfiguration || voices.isEmpty {
                Task { await load() }
            }
        }
        .onDisappear {
            // Leaving the whole Voice screen must silence any preview started
            // from the overview's top control. The chooser has its own
            // `onDisappear` stop; this covers the overview-level control.
            stopActivePreview()
            operatorRecoveryTask?.cancel()
            operatorRecoveryTask = nil
            configurationRecoveryTask?.cancel()
            configurationRecoveryTask = nil
            configurationRecoveryAttemptID = nil
            configurationRecoveryReloadPending = false
            isRecoveringConfiguration = false
        }
    }

    @ViewBuilder
    private var overview: some View {
        #if os(macOS)
        Form { overviewContent }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { overviewContent }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        #endif
    }

    @ViewBuilder
    private var overviewContent: some View {
        previewSection

        Section {
            NavigationLink {
                voiceChooser
            } label: {
                HStack(spacing: DesignTokens.Spacing.md) {
                    SettingsIcon(icon: "waveform", color: .blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Voice")
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.Color.labelPrimary)
                        Text(selectedVoice?.displayName ?? "Choose a voice")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                    }
                }
            }
            .accessibilityIdentifier("voice-chooser-nav")

            tuningSlider(
                title: "Speed",
                value: tuningBinding(\.speed, range: .speed),
                range: .speed,
                step: 0.05,
                readout: Self.speedReadout,
                minimumLabel: "Slower",
                maximumLabel: "Faster",
                identifier: "voice-speed-slider"
            )
        } header: {
            Text("Spoken responses")
        } footer: {
            Text("Choose how Rem sounds when reading a response or talking with you. Speed applies to the next thing Rem says.")
        }

        if VoiceTuningProviderSupport.supportsVoiceCharacter(providerID: providerID) {
            Section {
                tuningSlider(
                    title: "Consistency",
                    value: tuningBinding(\.stability, range: .stability),
                    range: .stability,
                    step: 0.05,
                    readout: Self.percentReadout,
                    minimumLabel: "More expressive",
                    maximumLabel: "More consistent",
                    identifier: "voice-stability-slider"
                )

                tuningSlider(
                    title: "Likeness",
                    value: tuningBinding(\.similarity, range: .similarity),
                    range: .similarity,
                    step: 0.05,
                    readout: Self.percentReadout,
                    minimumLabel: "Looser",
                    maximumLabel: "Closer",
                    identifier: "voice-similarity-slider"
                )
            } header: {
                Text("Character")
            } footer: {
                Text("Consistency trades expressive range for a steadier delivery. Likeness controls how closely Rem holds to the chosen voice.")
            }
        }

        if tuning.hasOverrides {
            Section {
                Button("Reset to Agent Defaults", role: .destructive) {
                    tuning = .agentDefaults
                }
                .accessibilityIdentifier("voice-tuning-reset")
            } footer: {
                Text("Clears these adjustments so this agent's own settings apply.")
            }
        }
    }

    /// A play/hear-the-voice control pinned to the top of the overview so the
    /// user can hear the *currently selected* voice with whatever Speed and
    /// Character adjustments the sliders below are set to, without diving into
    /// the "Choose a voice" list first (#1373 / #1372).
    ///
    /// This reuses the exact preview pipeline the per-voice rows already use —
    /// `talk.speak` → `VoiceSettingsPreviewPlayer` (AVAudioPlayer). It adds no
    /// new audio stack, and it cannot reintroduce the mic echo (#1358): the
    /// settings screen never activates the recording session; that lives only
    /// in the talk-mode managers during a live voice session. There is no
    /// mic-input path here for the preview to be captured by.
    @ViewBuilder
    private var previewSection: some View {
        if let previewVoice = selectedVoice ?? voices.first {
            let isActive = previewPlayer.activeVoiceID == previewVoice.id
            let isLoadingPreview = previewPlayer.loadingVoiceID == previewVoice.id
            Section {
                Button {
                    switch previewPlayer.tap(voiceID: previewVoice.id) {
                    case .stop:
                        stopActivePreview()
                    case .start:
                        startPreview(previewVoice)
                    }
                } label: {
                    HStack(spacing: DesignTokens.Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(DesignTokens.Color.brandBlue)
                                .frame(width: 36, height: 36)
                            if isLoadingPreview {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: isActive ? "stop.fill" : "play.fill")
                                    .font(.body.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(isActive ? "Playing preview…" : "Hear this voice")
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Color.labelPrimary)
                            Text(previewVoice.displayName)
                                .font(DesignTokens.Typography.caption1)
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    loadOperationActive ||
                        !previewPlayer.buttonEnabled(for: previewVoice.id, isSaving: savingVoiceID != nil)
                )
                .accessibilityLabel(
                    isActive
                        ? "Stop preview of \(previewVoice.displayName)"
                        : "Hear a preview of \(previewVoice.displayName) with your current settings"
                )
                .accessibilityIdentifier("voice-preview-current")
            } footer: {
                Text("Plays a short sample in the selected voice with your current speed and character settings. Adjust the sliders below, then play again to compare.")
            }
        }
    }

    private func tuningBinding(
        _ keyPath: WritableKeyPath<VoiceTuningSettings, Double?>,
        range: VoiceTuningRange
    ) -> Binding<Double> {
        Binding(
            get: { tuning[keyPath: keyPath] ?? range.defaultValue },
            set: { tuning[keyPath: keyPath] = range.clamped($0) }
        )
    }

    @ViewBuilder
    private func tuningSlider(
        title: String,
        value: Binding<Double>,
        range: VoiceTuningRange,
        step: Double,
        readout: (Double) -> String,
        minimumLabel: String,
        maximumLabel: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                Spacer(minLength: 0)
                Text(readout(value.wrappedValue))
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .monospacedDigit()
            }
            Slider(
                value: value,
                in: range.lowerBound...range.upperBound,
                step: step
            ) {
                Text(title)
            } minimumValueLabel: {
                Text(minimumLabel)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            } maximumValueLabel: {
                Text(maximumLabel)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
            .accessibilityIdentifier(identifier)
            .accessibilityValue(readout(value.wrappedValue))
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private nonisolated static func speedReadout(_ value: Double) -> String {
        String(format: "%.2f×", value)
    }

    private nonisolated static func percentReadout(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var selectedVoice: VoiceSettingsVoice? {
        voices.first { $0.id == selectedVoiceID }
    }

    /// Stability and likeness are only consumed by providers whose
    /// `resolveTalkOverrides` maps them into `voiceSettings`. Sending them to a
    /// provider that drops them would be harmless but dishonest — the preview
    /// would imply the sliders did something the synthesis never saw.
    private var characterTuning: VoiceTuningSettings? {
        VoiceTuningProviderSupport.supportsVoiceCharacter(providerID: providerID) ? tuning : nil
    }

    @ViewBuilder
    private var voiceChooser: some View {
        Group {
        #if os(macOS)
            Form { chooserContent }
                .formStyle(.grouped)
                .macSettingsCenteredColumn()
        #else
            List { chooserContent }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
        #endif
        }
        .navigationTitle("Choose a voice")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear {
            stopActivePreview()
        }
    }

    @ViewBuilder
    private var chooserContent: some View {
        if let operationMessage {
            Section {
                Label(operationMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(DesignTokens.Typography.caption1)
            }
        }

        if let operationError {
            Section {
                Label(operationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(DesignTokens.Typography.caption1)
                Button("Try Again") {
                    retryLoad()
                }
                .remSettingsCTA(.primary, size: .compact)
            }
        }

        Section {
            ForEach(voices) { voice in
                voiceRow(voice)
            }
        } footer: {
            Text("Your choice follows this agent across your devices. Tap the play button to hear a preview.")
        }
    }

    private func voiceRow(_ voice: VoiceSettingsVoice) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button {
                switch previewPlayer.tap(voiceID: voice.id) {
                case .stop:
                    stopActivePreview()
                case .start:
                    startPreview(voice)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(DesignTokens.Color.brandBlue)
                        .frame(width: 36, height: 36)
                    Image(systemName: previewPlayer.activeVoiceID == voice.id ? "stop.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                loadOperationActive ||
                    !previewPlayer.buttonEnabled(for: voice.id, isSaving: savingVoiceID != nil)
            )
            .overlay {
                if previewPlayer.loadingVoiceID == voice.id {
                    Circle()
                        .fill(DesignTokens.Color.brandBlue)
                        .frame(width: 36, height: 36)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .accessibilityLabel(
                previewPlayer.activeVoiceID == voice.id
                    ? "Stop \(voice.displayName) preview"
                    : "Preview \(voice.displayName)"
            )
            .accessibilityIdentifier("voice-preview-\(voice.id)")

            Button {
                beginSaving(voice)
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.displayName)
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.Color.labelPrimary)
                            .multilineTextAlignment(.leading)
                        if let detail = voice.displayDetail {
                            Text(detail)
                                .font(DesignTokens.Typography.caption1)
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    if savingVoiceID == voice.id {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving voice")
                    } else {
                        VoiceSelectionIndicator(isSelected: selectedVoiceID == voice.id)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(savingVoiceID != nil || loadOperationActive)
            .accessibilityLabel(
                selectedVoiceID == voice.id
                    ? "\(voice.displayName), selected"
                    : "Choose \(voice.displayName)"
            )
            .accessibilityAddTraits(selectedVoiceID == voice.id ? .isSelected : [])
            .accessibilityIdentifier("voice-choice-\(voice.id)")
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Spacer(minLength: 0)
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            Text(loadError ?? "No voices are available yet.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .multilineTextAlignment(.center)
            emptyStateAction
            if isRecoveringConfiguration {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Setting up Voice")
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .macSettingsCenteredColumn()
    }

    @ViewBuilder
    private var emptyStateAction: some View {
        switch loadRecoveryAction {
        case .repairManagedConfiguration:
            Button("Set Up Voice") {
                beginConfigurationRecovery()
            }
            .disabled(isRecoveringConfiguration)
            .remSettingsCTA(.primary, size: .compact)
        case .openProviderSetup:
            NavigationLink {
                VoiceProviderSetupView(
                    managedPlanRequired: gateway.activeGatewayProviderForDisplay == .fly
                )
            } label: {
                Text("View Setup Steps")
            }
            .remSettingsCTA(.primary, size: .compact)
        case .reconnect:
            Button("Reconnect") { retryLoad() }
                .remSettingsCTA(.primary, size: .compact)
        case .openManagedGatewayUpdate:
            NavigationLink {
                SharedGatewayRecoveryDestinationView(gateway: gateway)
            } label: {
                Text("Review Agent Update")
            }
            .remSettingsCTA(.primary, size: .compact)
        case .openSelfManagedUpdate:
            NavigationLink {
                VoiceGatewayUpdateInstructionsView(
                    provider: gateway.activeGatewayProviderForDisplay
                )
            } label: {
                Text("View Update Steps")
            }
            .remSettingsCTA(.primary, size: .compact)
        case .retry:
            Button("Try Again") { retryLoad() }
                .remSettingsCTA(.primary, size: .compact)
        }
    }

    private func load() async {
        // Both pull-to-refresh and operator recovery can request a reload. Keep
        // one authoritative read in flight, and never let it overwrite a save.
        guard !loadOperationActive, savingVoiceID == nil else { return }
        loadOperationActive = true
        defer {
            loadOperationActive = false
            if reloadRequestedAfterActiveLoad, savingVoiceID == nil {
                reloadRequestedAfterActiveLoad = false
                Task { await load() }
            }
        }

        guard VoiceSettingsReadinessPolicy.canIssueOperatorRequests(
            operatorReady: gateway.operatorReady,
            aggregateConnected: gateway.connectionState.isConnected
        ) else {
            voices = []
            if operatorRecoveryIsInProgress {
                // The aggregate gateway can be connected while its operator leg
                // is still recovering. Bound the shimmer; a failed leg must turn
                // into actionable recovery rather than loading forever.
                isLoading = true
                loadError = nil
                loadRecoveryAction = .retry
                scheduleOperatorRecoveryTimeout()
            } else {
                isLoading = false
                loadError = "Couldn't connect to this agent's voice settings."
                loadRecoveryAction = .reconnect
            }
            return
        }

        operatorRecoveryTask?.cancel()
        operatorRecoveryTask = nil

        isLoading = true
        loadError = nil
        loadRecoveryAction = .retry
        operationMessage = nil
        operationError = nil

        do {
            async let catalogData = gateway.skillsRequest(
                method: "talk.catalog",
                paramsJSON: "{}",
                timeoutSeconds: 15
            )
            async let configData = gateway.skillsRequest(
                method: "talk.config",
                paramsJSON: "{}",
                timeoutSeconds: 15
            )
            let (rawCatalog, rawConfig) = try await (catalogData, configData)
            let catalog = try JSONDecoder().decode(TalkCatalogResponse.self, from: rawCatalog)
            let selection = try VoiceSettingsConfigParser.selection(from: rawConfig)

            guard let activeProvider = VoiceSettingsCatalogPolicy.providerToLoad(
                catalog: catalog,
                selection: selection
            ) else {
                voices = []
                applyLoadFailure(
                    VoiceSettingsLoadPresentation.missingProvider(
                        gatewayProvider: gateway.activeGatewayProviderForDisplay
                    )
                )
                isLoading = false
                return
            }

            let rawVoices: Data
            do {
                rawVoices = try await gateway.skillsRequest(
                    method: "talk.voices",
                    paramsJSON: "{}",
                    timeoutSeconds: 20
                )
            } catch {
                voices = []
                applyLoadFailure(
                    VoiceSettingsLoadPresentation.presentation(
                        for: error,
                        gatewayProvider: gateway.activeGatewayProviderForDisplay
                    )
                )
                isLoading = false
                return
            }

            let response = try JSONDecoder().decode(TalkVoicesResponse.self, from: rawVoices)
            guard response.provider.caseInsensitiveCompare(activeProvider) == .orderedSame else {
                throw VoiceSettingsViewError.catalogChanged
            }

            providerID = response.provider
            selectedVoiceID = selection?.provider.caseInsensitiveCompare(response.provider) == .orderedSame
                ? selection?.voiceID
                : nil
            voices = response.voices.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            if voices.isEmpty {
                loadError = "No voices are available for this agent yet."
            }
        } catch {
            voices = []
            applyLoadFailure(
                VoiceSettingsLoadPresentation.presentation(
                    for: error,
                    gatewayProvider: gateway.activeGatewayProviderForDisplay
                )
            )
        }
        isLoading = false
    }

    private var operatorRecoveryIsInProgress: Bool {
        switch gateway.sessionHealth.operatorSessionState {
        case .connecting:
            return true
        case .disconnected:
            return gateway.connectionState.isConnected || gateway.connectionState == .connecting
        case .connected, .failed:
            return false
        }
    }

    private func scheduleOperatorRecoveryTimeout() {
        operatorRecoveryTask?.cancel()
        operatorRecoveryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled,
                  voices.isEmpty,
                  configurationRecoveryReloadPending || !gateway.operatorReady
            else { return }
            configurationRecoveryReloadPending = false
            isLoading = false
            loadError = "Couldn't connect to this agent's voice settings."
            loadRecoveryAction = .reconnect
            operatorRecoveryTask = nil
        }
    }

    private func retryLoad() {
        operatorRecoveryTask?.cancel()
        operatorRecoveryTask = nil
        if !gateway.operatorReady {
            gateway.reconnect()
        }
        Task { await load() }
    }

    private func applyLoadFailure(_ presentation: VoiceSettingsFailurePresentation) {
        loadError = presentation.message
        loadRecoveryAction = presentation.action
    }

    private func beginConfigurationRecovery() {
        guard configurationRecoveryTask == nil,
              let request = gateway.makeVoiceConfigurationRecoveryRequest()
        else {
            loadError = "Sign in again before setting up Voice."
            loadRecoveryAction = .reconnect
            return
        }
        let attemptID = UUID()
        configurationRecoveryReloadPending = false
        configurationRecoveryAttemptID = attemptID
        isRecoveringConfiguration = true
        configurationRecoveryTask = Task { @MainActor in
            let requestAccountID = request.accountID
            defer {
                if VoiceConfigurationRecoveryPolicy.ownsCurrentAttempt(
                    attemptID: attemptID,
                    currentAttemptID: configurationRecoveryAttemptID
                ) {
                    isRecoveringConfiguration = false
                    configurationRecoveryTask = nil
                    configurationRecoveryAttemptID = nil
                }
            }
            let result = await VoiceConfigurationRecoveryCoordinator.shared.recover(
                accountID: requestAccountID
            ) {
                try await request.perform()
            }
            guard !Task.isCancelled else { return }
            let completion = VoiceConfigurationRecoveryPolicy.completion(
                for: result,
                requestAccountID: requestAccountID,
                currentAccountID: gateway.authenticatedAccountIDForRecovery
            )
            switch completion {
            case .reload:
                loadError = nil
                loadRecoveryAction = .retry
                isLoading = true
                configurationRecoveryReloadPending = true
                gateway.reconnect()
                scheduleOperatorRecoveryTimeout()
            case .openProviderSetup:
                loadError = "This agent needs provider credentials from its gateway setup."
                loadRecoveryAction = .openProviderSetup
            case .showFailure:
                loadError = "Voice setup couldn't be completed. Try again."
                loadRecoveryAction = .repairManagedConfiguration
            case .discardAccountChange:
                break
            }
        }
    }

    private func beginSaving(_ voice: VoiceSettingsVoice) {
        // Claim the mutation synchronously in the button action, before the
        // unstructured Task reaches its first suspension. This closes the rapid-
        // tap window that could otherwise launch overlapping gateway restarts.
        guard savingVoiceID == nil, !loadOperationActive, selectedVoiceID != voice.id else {
            return
        }
        savingVoiceID = voice.id
        Task { await saveClaimed(voice) }
    }

    private func saveClaimed(_ voice: VoiceSettingsVoice) async {
        guard savingVoiceID == voice.id else { return }
        defer { savingVoiceID = nil }
        guard selectedVoiceID != voice.id else { return }
        guard let providerID else {
            operationError = "Couldn't identify this agent's voice service. Try refreshing."
            return
        }
        guard VoiceSettingsReadinessPolicy.canIssueOperatorRequests(
            operatorReady: gateway.operatorReady,
            aggregateConnected: gateway.connectionState.isConnected
        ) else {
            operationError = "Reconnect this agent, then try again."
            return
        }

        let previousVoiceID = selectedVoiceID
        operationMessage = nil
        operationError = nil
        stopActivePreview()

        do {
            let snapshotData = try await gateway.skillsRequest(
                method: "config.get",
                paramsJSON: "{}",
                timeoutSeconds: 15
            )
            let params = try VoiceSettingsConfigParser.patchParams(
                snapshotData: snapshotData,
                provider: providerID,
                voiceID: voice.id
            )
            let paramsData = try JSONEncoder().encode(params)
            guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
                throw VoiceSettingsViewError.invalidRequest
            }

            let patchAcknowledgement: VoiceConfigPatchAcknowledgement
            do {
                _ = try await gateway.skillsRequest(
                    method: "config.patch",
                    paramsJSON: paramsJSON,
                    timeoutSeconds: 20
                )
                patchAcknowledgement = .accepted
            } catch let responseError as GatewayResponseError {
                // A structured RPC rejection means the gateway did not accept
                // the write (for example, a stale base hash). Do not spend the
                // restart window polling a change that cannot have landed.
                patchAcknowledgement = .rejected
                throw responseError
            } catch {
                // The gateway can disconnect while acknowledging the patch because
                // the write queues its restart. Confirmation below is authoritative.
                patchAcknowledgement = .ambiguous
            }

            let postPatch = VoiceSaveLifecyclePolicy.afterPatch(
                patchAcknowledgement,
                previousVoiceID: previousVoiceID,
                requestedVoiceID: voice.id
            )
            selectedVoiceID = postPatch.visibleVoiceID

            let readback = await waitForSelection(
                providerID: providerID,
                voiceID: voice.id
            )
            let decision = VoiceSaveLifecyclePolicy.afterReadback(
                readback,
                previousVoiceID: previousVoiceID,
                requestedVoiceID: voice.id
            )
            selectedVoiceID = decision.visibleVoiceID
            if decision.isConfirmed {
                operationMessage = "\(voice.displayName) is now Rem's voice."
            } else {
                operationError = "Couldn't confirm the new voice after the agent restarted. Try again."
            }
        } catch {
            selectedVoiceID = previousVoiceID
            operationError = "Couldn't save the voice. Try again."
        }
    }

    private func waitForSelection(
        providerID expectedProviderID: String,
        voiceID expectedVoiceID: String
    ) async -> VoiceConfigReadback {
        var receivedAuthoritativeReadback = false
        for attempt in 0..<10 {
            if Task.isCancelled { return .unavailable }
            // The paired operator leg can recover before the aggregate connection
            // (which also includes node health). Poll the same operator session used
            // by `skillsRequest`, mirroring TimezoneSyncService.
            if gateway.operatorReady {
                do {
                    let data = try await gateway.skillsRequest(
                        method: "talk.config",
                        paramsJSON: "{}",
                        timeoutSeconds: 5
                    )
                    receivedAuthoritativeReadback = true
                    if try VoiceSettingsConfigParser.selection(from: data)?.matches(
                        provider: expectedProviderID,
                        voiceID: expectedVoiceID
                    ) == true {
                        return .matched
                    }
                } catch {
                    // A restart is expected; retry until the bounded deadline.
                }
            }
            if attempt < 9 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        return receivedAuthoritativeReadback ? .different : .unavailable
    }

    private func startPreview(_ voice: VoiceSettingsVoice) {
        previewRequestTask?.cancel()
        let attemptID = UUID().uuidString
        let command = previewRequestGate.claimReplacement(previewID: attemptID)
        activePreviewAttemptID = attemptID
        previewRequestTask = Task {
            await previewRequestGate.executeReplacement(
                command,
                cancelCurrent: { previewID in await cancelPreview(previewID: previewID) },
                startNext: { previewID in
                    await preview(
                        voice,
                        previewID: previewID,
                        attemptID: attemptID
                    )
                }
            )
        }
    }

    private func preview(
        _ voice: VoiceSettingsVoice,
        previewID: String,
        attemptID: String
    ) async {
        operationError = nil
        do {
            // The preview must sound like the real thing, so it carries the same
            // tuning the talk managers send on every utterance.
            let params = TalkSpeakPreviewParams(
                text: "Hi, I'm Rem. Here's how I'll sound.",
                voiceId: voice.id,
                previewId: previewID,
                speed: tuning.speed,
                stability: characterTuning?.stability,
                similarity: characterTuning?.similarity
            )
            let paramsData = try JSONEncoder().encode(params)
            guard let paramsJSON = String(data: paramsData, encoding: .utf8) else {
                throw VoiceSettingsViewError.invalidRequest
            }
            let data: Data
            do {
                data = try await gateway.skillsRequest(
                    method: "talk.speak",
                    paramsJSON: paramsJSON,
                    timeoutSeconds: 30
                )
            } catch where GatewayTalkSpeechCompatibility.shouldRetryWithoutPreviewID(for: error) {
                let legacyParams = TalkSpeakLegacyPreviewParams(
                    text: params.text,
                    voiceId: params.voiceId,
                    speed: params.speed,
                    stability: params.stability,
                    similarity: params.similarity
                )
                let legacyData = try JSONEncoder().encode(legacyParams)
                guard let legacyJSON = String(data: legacyData, encoding: .utf8) else {
                    throw VoiceSettingsViewError.invalidRequest
                }
                data = try await gateway.skillsRequest(
                    method: "talk.speak",
                    paramsJSON: legacyJSON,
                    timeoutSeconds: 30
                )
            }
            try Task.checkCancellation()
            guard activePreviewAttemptID == attemptID else { return }
            let response = try JSONDecoder().decode(GatewayTalkSpeechAudio.self, from: data)
            try previewPlayer.play(response, voiceID: voice.id)
            activePreviewAttemptID = nil
            previewRequestTask = nil
        } catch is CancellationError {
            return
        } catch {
            // Some transports surface cancellation as their own error. Never let
            // a superseded request stop or overwrite a newer preview.
            guard
                !Task.isCancelled,
                activePreviewAttemptID == attemptID,
                previewPlayer.activeVoiceID == voice.id
            else { return }
            activePreviewAttemptID = nil
            previewRequestTask = nil
            previewPlayer.stop()
            operationError = "Couldn't play this voice preview. Try again."
        }
    }

    private func stopActivePreview() {
        previewRequestTask?.cancel()
        let command = previewRequestGate.claimStop()
        activePreviewAttemptID = nil
        previewPlayer.stop()
        previewRequestTask = Task {
            await previewRequestGate.executeStop(command) { previewID in
                await cancelPreview(previewID: previewID)
            }
        }
    }

    private func cancelPreview(previewID: String) async {
        let params = TalkSpeakCancelParams(previewId: previewID)
        guard
            let paramsData = try? JSONEncoder().encode(params),
            let paramsJSON = String(data: paramsData, encoding: .utf8)
        else { return }
        _ = try? await gateway.skillsRequest(
            method: "talk.speak.cancel",
            paramsJSON: paramsJSON,
            timeoutSeconds: 5
        )
    }
}

private struct TalkSpeakPreviewParams: Encodable {
    let text: String
    let voiceId: String
    let previewId: String
    /// Omitted from the JSON when nil, so an untouched control sends nothing and
    /// the gateway's own configuration decides.
    var speed: Double?
    var stability: Double?
    var similarity: Double?
}

private struct TalkSpeakCancelParams: Encodable {
    let previewId: String
}

private struct TalkSpeakLegacyPreviewParams: Encodable {
    let text: String
    let voiceId: String
    var speed: Double?
    var stability: Double?
    var similarity: Double?
}

@MainActor
private final class VoiceSettingsPreviewPlayer: ObservableObject {
    @Published private(set) var stateMachine = VoicePreviewStateMachine()

    private var player: AVAudioPlayer?
    private var completionTask: Task<Void, Never>?

    var activeVoiceID: String? { stateMachine.phase.activeVoiceID }
    var loadingVoiceID: String? {
        guard case .loading(let voiceID) = stateMachine.phase else { return nil }
        return voiceID
    }

    func buttonEnabled(for voiceID: String, isSaving: Bool) -> Bool {
        stateMachine.buttonEnabled(for: voiceID, isSaving: isSaving)
    }

    func tap(voiceID: String) -> VoicePreviewTapAction {
        if stateMachine.phase.activeVoiceID != voiceID {
            stopPlaybackResources()
        }
        return stateMachine.tap(voiceID: voiceID)
    }

    func play(_ audio: GatewayTalkSpeechAudio, voiceID: String) throws {
        guard let data = GatewayTalkSpeechPlaybackPolicy.playableData(from: audio) else {
            throw VoiceSettingsViewError.invalidAudio
        }
        completionTask?.cancel()
        let nextPlayer = try AVAudioPlayer(data: data)
        nextPlayer.prepareToPlay()
        guard nextPlayer.play() else { throw VoiceSettingsViewError.invalidAudio }
        player = nextPlayer
        stateMachine.didStartPlaying(voiceID: voiceID)

        let duration = max(0.1, nextPlayer.duration)
        completionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.15) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stateMachine.stop()
        stopPlaybackResources()
    }

    private func stopPlaybackResources() {
        completionTask?.cancel()
        completionTask = nil
        player?.stop()
        player = nil
    }
}

private struct VoiceSelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    isSelected ? DesignTokens.Color.brandBlue : DesignTokens.Color.labelSecondary,
                    lineWidth: 2
                )
            if isSelected {
                Circle()
                    .fill(DesignTokens.Color.brandBlue)
                    .padding(4)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct VoiceSettingsOverviewLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.md) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DesignTokens.Color.fillTertiary)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 7) {
                    bar(width: 74, height: 15)
                    bar(width: 118, height: 11)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(DesignTokens.Color.fillTertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            Spacer(minLength: 0)
        }
        .padding(.top, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shimmering()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading voices…")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: height)
    }
}

private struct VoiceProviderSetupView: View {
    let managedPlanRequired: Bool

    var body: some View {
        Form {
            Section("Voice provider") {
                Text(
                    managedPlanRequired
                        ? "Managed Voice isn't available for this account. You can use provider credentials owned by your gateway instead."
                        : "This agent uses credentials owned by its gateway. Device-only API keys cannot configure Voice."
                )
                Text("Open the gateway's OpenClaw Control UI, then choose Settings → Talk to configure the provider there.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Text("Configure ELEVENLABS_API_KEY in the gateway environment, or set talk.providers.elevenlabs.apiKey in the gateway's OpenClaw configuration.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Link(
                    "Open the OpenClaw setup guide",
                    destination: URL(string: "https://docs.openclaw.ai/nodes/talk")!
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Set Up Voice")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct VoiceGatewayUpdateInstructionsView: View {
    let provider: GatewayProvider?

    var body: some View {
        Form {
            Section("Update this agent") {
                Text(updateMessage)
                Text("After the gateway is updated and restarted, return to Voice and try loading choices again.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                Link(
                    "Open the OpenClaw update guide",
                    destination: URL(string: "https://docs.openclaw.ai/install/updating")!
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Update Agent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var updateMessage: String {
        switch provider {
        case .local:
            "Update this local gateway from the Mac app or OpenClaw tooling. Rem will not change local runtime files from Voice settings."
        case .manual, .none:
            "This gateway is managed outside Rem. Update and restart it with the same tooling or hosting workflow used to install it."
        case .fly:
            "Return to Agent settings to review the managed gateway update path."
        }
    }
}

private enum VoiceSettingsViewError: LocalizedError {
    case catalogChanged
    case invalidRequest
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .catalogChanged: "The available voices changed. Try refreshing."
        case .invalidRequest: "Could not prepare the request."
        case .invalidAudio: "The voice preview could not be played."
        }
    }
}
