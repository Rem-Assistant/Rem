import SwiftUI

// MARK: - Gateway Detail View

struct SharedGatewayDetailView<Gateway: GatewaySessionProviding>: View {
    let config: GatewayConfig
    let configStore: GatewayConfigStore
    let gateway: Gateway
    let runtimeProviderAuthEvidence: RuntimeProviderAuthEvidence
    var backupView: (() -> AnyView)? = nil
    var showsConnectionsLink = false
    var usesCloudRecoveryGrace = true
    @Environment(\.dismiss) private var dismiss

    @State private var selectedConfigID: String?
    @State private var showGatewayChooser = false
    @State private var showDeleteConfirmation = false
    @State private var cloudRecoveryGraceUntil: Date?
    @State private var gatewayStatusRefreshTick = 0
    @State private var backendUpdateReadiness: GatewayUpdateReadiness?
    @State private var updateReadinessError: String?
    #if os(iOS)
    @State private var showCloudDeploy = false
    @State private var wakeMacAddress = ""
    @State private var isSendingWakePacket = false
    @State private var wakePacketSent = false
    #else
    @State private var showLocalSetup = false
    @Environment(\.localGateway) private var localGateway
    #endif

    private var selectedConfig: GatewayConfig {
        let id = selectedConfigID ?? config.id
        return configStore.configs.first(where: { $0.id == id })
            ?? configStore.configs.first(where: { $0.id == config.id })
            ?? config
    }

    private var sortedConfigs: [GatewayConfig] {
        SharedGatewaySettingsResolver.sortedConfigs(configStore.configs)
    }

    private var hasCloudConfigured: Bool {
        configStore.configs.contains { $0.provider == .fly }
    }

    private var isHealthyCloudConfigured: Bool {
        selectedConfig.provider == .fly && gateway.connectionState.isConnected
    }

    private static var debugCloudRepairEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            #if os(macOS)
            Form { sections }
                .formStyle(.grouped)
            #else
            List { sections }
                .listStyle(.insetGrouped)
            #endif
        }
        .macSettingsCenteredColumn()
        // Founder rename: the gateway concept is surfaced as "Agent settings".
        // The top-level Settings → Agents landing (showsConnectionsLink) uses
        // the "Agent settings" framing; drilling into a specific gateway from
        // the connections list keeps that gateway's own name.
        .navigationTitle(showsConnectionsLink ? "Agent settings" : selectedConfig.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Founder: we only support a single cloud agent right now, so the
        // top-right gateway switcher/list button is noise. Hidden until
        // multi-agent management exists.
        #if os(iOS)
        .onAppear {
            if selectedConfigID == nil {
                selectedConfigID = config.id
            }
            updateCloudRecoveryGrace(for: gateway.connectionState, config: selectedConfig)
            if wakeMacAddress.isEmpty {
                wakeMacAddress = selectedConfig.macAddress ?? RemCredentialStore.macWoLAddress ?? ""
            }
        }
        .sheet(isPresented: $showGatewayChooser) {
            if showCloudDeploy {
                CloudGatewayDeploySheet(
                    gateway: gateway,
                    isRepair: hasCloudConfigured,
                    onConfigured: { config in
                        let savedConfig = SharedGatewaySettingsResolver.reusingExistingID(for: config, in: configStore.configs)
                        configStore.save(savedConfig)
                        configStore.setActive(id: savedConfig.id)
                        selectedConfigID = savedConfig.id
                    },
                    onComplete: { config in
                        let savedConfig = SharedGatewaySettingsResolver.reusingExistingID(for: config, in: configStore.configs)
                        gateway.configure(gatewayConfig: savedConfig)
                        selectedConfigID = savedConfig.id
                        showCloudDeploy = false
                    },
                    onCancel: { showCloudDeploy = false }
                )
            } else {
                let showCurrentCloudState = isHealthyCloudConfigured && !Self.debugCloudRepairEnabled
                SharedChooseGatewayView(
                    onCloudDeploy: { showCloudDeploy = true },
                    cloudDeployTitle: showCurrentCloudState ? "Cloud Gateway Connected" : (hasCloudConfigured ? "Repair Cloud Gateway" : "Deploy to Cloud"),
                    cloudDeploySubtitle: showCurrentCloudState
                        ? "Your existing cloud gateway is already connected."
                        : hasCloudConfigured
                        ? "Reconnect your existing Fly.io gateway. This will not create a second cloud gateway."
                        : "Create your Rem cloud gateway on Fly.io. Reachable from any device.",
                    cloudDeployBadge: showCurrentCloudState ? "Current" : (hasCloudConfigured ? "Existing" : "Recommended"),
                    cloudDeployDisabled: showCurrentCloudState,
                    cloudDeployConfirmationTitle: hasCloudConfigured && !showCurrentCloudState ? "Repair Cloud Gateway?" : nil,
                    cloudDeployConfirmationMessage: hasCloudConfigured
                        ? "This may update your active managed gateway and connection token. It will not create a second cloud gateway."
                        : nil,
                    cloudDeployConfirmationButtonTitle: "Repair Gateway",
                    discovery: IOSGatewayDiscovery(),
                    onConnect: addGateway,
                    onCancel: { showGatewayChooser = false }
                )
            }
        }
        .onChange(of: showGatewayChooser) { _, isShown in
            if !isShown { showCloudDeploy = false }
        }
        #else
        .onAppear {
            if selectedConfigID == nil {
                selectedConfigID = config.id
            }
            updateCloudRecoveryGrace(for: gateway.connectionState, config: selectedConfig)
        }
        .sheet(isPresented: $showGatewayChooser) {
            let hasLocalConfigured = configStore.configs.contains { $0.provider == .local }
            if showLocalSetup, let localGateway {
                LocalGatewaySetupView(
                    localGateway: localGateway,
                    onComplete: addGateway,
                    onCancel: { showLocalSetup = false }
                )
            } else {
                SharedChooseGatewayView(
                    onLocalGateway: localGateway != nil ? { showLocalSetup = true } : nil,
                    localGatewayActionLabel: localGateway != nil ? "Run Locally on This Mac" : nil,
                    localGatewaySubtitle: hasLocalConfigured
                        ? "A local gateway is already configured."
                        : "Runs as a local process. Fast, private, no hosting costs.",
                    localGatewayDisabled: hasLocalConfigured,
                    discovery: LocalGatewayDiscovery(),
                    onConnect: addGateway,
                    onCancel: { showGatewayChooser = false }
                )
            }
        }
        .onChange(of: showGatewayChooser) { _, isShown in
            if !isShown { showLocalSetup = false }
        }
        #endif
        .task {
            if selectedConfig.isActive {
                await gateway.fetchPendingDevices()
            }
        }
            .task(id: cloudRecoveryGraceUntil) {
            guard let until = cloudRecoveryGraceUntil else { return }
            let remaining = until.timeIntervalSinceNow
            guard remaining > 0 else {
                gatewayStatusRefreshTick += 1
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            gatewayStatusRefreshTick += 1
        }
        .confirmationDialog("Remove Gateway?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let removedConfig = selectedConfig
                let wasActive = removedConfig.isActive
                configStore.remove(id: removedConfig.id)
                if wasActive {
                    if let next = configStore.configs.first {
                        configStore.setActive(id: next.id)
                        gateway.configure(gatewayConfig: next)
                        selectedConfigID = next.id
                    } else {
                        gateway.clearConfiguration()
                    }
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved gateway from this device. The gateway itself keeps running. You can pair again from this device anytime.")
        }
        .onChange(of: gateway.connectionState) { _, newState in
            updateCloudRecoveryGrace(for: newState, config: selectedConfig)
        }
        .onChange(of: selectedConfigID) { _, _ in
            updateCloudRecoveryGrace(for: gateway.connectionState, config: selectedConfig)
        }
    }

    @ViewBuilder
    private var sections: some View {
        let config = selectedConfig

        // MARK: - Gateway
        // One "Gateway" section holds everything about this single agent's
        // gateway: how it runs (Runs on / Host), its live status (Connection),
        // and the lifecycle actions (Reconnect / Remove). Founder note —
        // "associated things should be grouped together"; these all describe the
        // same gateway, so they share one container instead of scattering the
        // actions into a separate trailing section.
        Section {
                LabeledContent("Agent runtime", value: "OpenClaw")
                LabeledContent("Runs on", value: config.provider.runsOnDescription)
                LabeledContent("Host") {
                    Text(config.hostDisplay ?? config.url)
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if SharedGatewaySettingsResolver.showsMacHardwareControls(for: config),
                   let mac = config.macAddress,
                   !mac.isEmpty {
                    LabeledContent("MAC Address", value: mac)
                }

                if config.isActive {
                    let _ = gatewayStatusRefreshTick
                    let presentation = GatewayStatusHelper.presentation(
                        for: gateway.connectionState,
                        provider: config.provider,
                        isWithinRecoveryGrace: isWithinCloudRecoveryGrace,
                        supportsExplicitPairingApproval: gateway.supportsExplicitPairingApproval,
                        isAutoRePairing: gateway.isAutoRePairInProgress,
                        isUserRePairing: false
                    )

                    HStack {
                        Text("Connection")
                        Spacer()
                        HStack(spacing: 6) {
                            if presentation.detail != nil {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(presentation.color)
                            } else {
                                Circle()
                                    .fill(presentation.color)
                                    .frame(width: 8, height: 8)
                            }
                            Text(presentation.text)
                                .foregroundStyle(.secondary)
                        }
                    }

                } else {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text("Inactive")
                            .foregroundStyle(.secondary)
                    }
                }

                // Lifecycle actions live inside the Gateway section so every
                // gateway-scoped item sits together. Founder: the two actions
                // read as a pair, so present them side by side (Reconnect |
                // Remove) instead of stacked full-width rows. Remove stays
                // visually destructive (red). When no primary action applies
                // (e.g. cloud approval pending), Remove sits alone.
                HStack(spacing: DesignTokens.Spacing.lg) {
                    if shouldShowPrimaryGatewayAction(for: config) {
                        primaryGatewayActionButton(for: config)
                    }
                    removeGatewayButton
                }
                .remSettingsCtaListRow()
            } header: {
                Text("Gateway")
            } footer: {
                Text("Removing a gateway only forgets it on this device. It does not sign you out or approve/decline pending devices.")
            }

            if config.isActive {
                // MARK: - Connectivity (how the agent is reached + what it can run)
                Section {
                    NavigationLink {
                        SharedGatewayDevicePairingScreen(
                            config: config,
                            configStore: configStore,
                            gateway: gateway
                        )
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "laptopcomputer.and.iphone", color: .indigo)
                            Text("Paired Devices")
                            Spacer()
                            if !gateway.pendingDevices.isEmpty {
                                Text("\(gateway.pendingDevices.count)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.orange))
                            }
                        }
                    }
                    .accessibilityIdentifier("device-pairing-row")

                    // Account connectors stay runtime-scoped but distinct from
                    // machine pairing: a Connector is an authenticated service
                    // such as Gmail, GitHub, or Notion.
                    NavigationLink {
                        SharedComposioConnectionsView(service: ComposioService())
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "link.circle.fill", color: .purple)
                            Text("Connectors")
                        }
                    }
                    .accessibilityIdentifier("gateway-connectors-nav")

                    #if os(iOS)
                    // Cloud browser — the SSRF site policy for the agent's cloud browser. iOS +
                    // managed Fly gateway only: the write patches + restarts the backend-stored
                    // gateway, so read and write must target the same one (see #1046). Nested here
                    // under Connectivity rather than top-level Settings — it's an agent capability,
                    // not a global app preference.
                    if gateway.activeGatewayProviderForDisplay == .fly {
                        NavigationLink {
                            SharedCloudBrowserSettingsView(gateway: gateway)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(icon: "globe", color: .blue)
                                Text("Cloud browser")
                            }
                        }
                        .accessibilityIdentifier("gateway-cloud-browser-nav")
                    }
                    #endif

                    if shouldShowBackupRow(for: config), let backupView {
                        NavigationLink {
                            backupView()
                        } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(icon: "externaldrive.fill", color: .green)
                                Text("Backup")
                            }
                        }
                        .accessibilityIdentifier("gateway-backup-nav")
                    }

                    // Skills are things the agent can do. Keep them separate in
                    // language from Connectors, which provide account access.
                    NavigationLink {
                        SharedSkillsHomeView(gateway: gateway)
                            .navigationTitle("Skills")
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "puzzlepiece.extension.fill", color: .purple)
                            Text("Skills")
                        }
                    }
                    .accessibilityIdentifier("gateway-skills-nav")

                    // Automations — the container for scheduled, ask-once-run-forever
                    // behavior. Daily Check-ins (the founder's simplified routines) is the
                    // first automation. Moved here from top-level Settings: scheduled agent
                    // behavior belongs with the agent, alongside how it's reached and what
                    // it can run, not as a global app preference.
                    NavigationLink {
                        SharedAutomationsSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "bell.badge.fill", color: .pink)
                            Text("Automations")
                        }
                    }
                    .accessibilityIdentifier("gateway-automations-nav")
                } header: {
                    Text("Connectivity")
                } footer: {
                    Text("Review paired devices, connected accounts, installed skills, and scheduled automations for this agent.")
                }

                // MARK: - Memory & Keys (what the agent remembers + how it authenticates)
                Section {
                    // "Dreaming" memory — facts Rem remembers about the user.
                    // Moved here from top-level Settings: the path is now
                    // Settings → Agents → Memory. Backend `user_memory` is the
                    // source of truth (see MemoryService).
                    NavigationLink {
                        SharedMemorySettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "brain.head.profile", color: .pink)
                            Text("Memory")
                        }
                    }
                    .accessibilityIdentifier("gateway-memory-nav")

                    // Models — manage the runtime-backed Automatic and MiniMax policy, then inspect
                    // only providers the active gateway confirms it can route.
                    NavigationLink {
                        SharedModelsSettingsScreen(
                            gateway: gateway,
                            runtimeProviderAuthEvidence: runtimeProviderAuthEvidence
                        )
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "cpu", color: .indigo)
                            Text("Models")
                        }
                    }
                    .accessibilityIdentifier("gateway-models-nav")
                } header: {
                    Text("Memory & Keys")
                }

                // MARK: - Experience (how the agent sounds)
                Section {
                    NavigationLink {
                        SharedVoiceSettingsView(gateway: gateway)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "waveform", color: .blue)
                            Text("Voice")
                        }
                    }
                    .accessibilityIdentifier("gateway-voice-nav")
                } header: {
                    Text("Experience")
                }

                #if os(iOS)
                if SharedGatewaySettingsResolver.showsMacHardwareControls(for: config) {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mac MAC Address")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundStyle(.secondary)
                            TextField("AA:BB:CC:DD:EE:FF", text: $wakeMacAddress)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onChange(of: wakeMacAddress) { _, newValue in
                                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let storedValue = trimmed.isEmpty ? nil : trimmed
                                    var updated = config
                                    updated.macAddress = storedValue
                                    configStore.save(updated)
                                    RemCredentialStore.macWoLAddress = storedValue
                                    wakePacketSent = false
                                }
                        }

                        if !wakeMacAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                Task {
                                    isSendingWakePacket = true
                                    wakePacketSent = false
                                    wakePacketSent = await WakeOnLAN.send(macAddress: wakeMacAddress)
                                    isSendingWakePacket = false
                                }
                            } label: {
                                HStack {
                                    if isSendingWakePacket {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else if wakePacketSent {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else {
                                        Image(systemName: "wake")
                                    }
                                    Text(wakePacketSent ? "Packet Sent" : "Wake Mac")
                                }
                            }
                            .disabled(isSendingWakePacket)
                        }
                    } header: {
                        Text("Wake-on-LAN")
                    } footer: {
                        Text("Send a magic packet to wake your Mac from sleep. Works best over Ethernet and may be unreliable over Wi-Fi.")
                    }
                }
                #endif
            }
        }

    @ViewBuilder
    private func primaryGatewayActionButton(for config: GatewayConfig) -> some View {
        if !config.isActive {
            EmptyView()
        } else if gateway.connectionState.needsDeviceRePair {
            NavigationLink {
                SharedGatewayDevicePairingScreen(
                    config: config,
                    configStore: configStore,
                    gateway: gateway
                )
            } label: {
                Text("Review Connection")
            }
            .remSettingsCTA(.primary)
        } else if gateway.connectionState.isConnected {
            Button("Reconnect") {
                gateway.reconnect()
            }
            .remSettingsCTA(.primary)
        } else {
            Button("Connect") {
                gateway.connectIfConfigured()
            }
            .remSettingsCTA(.primary)
        }
    }

    private func shouldShowPrimaryGatewayAction(for config: GatewayConfig) -> Bool {
        config.isActive
    }

    private func shouldShowBackupRow(for config: GatewayConfig) -> Bool {
        #if os(macOS)
        config.isActive && config.provider == .local && backupView != nil
        #else
        false
        #endif
    }

    private var removeGatewayButton: some View {
        Button("Remove", role: .destructive) {
            showDeleteConfirmation = true
        }
        .remSettingsCTA(.destructive)
    }

    private var isWithinCloudRecoveryGrace: Bool {
        guard let cloudRecoveryGraceUntil else { return false }
        return Date() < cloudRecoveryGraceUntil
    }

    private func updateCloudRecoveryGrace(for state: GatewayConnectionState, config: GatewayConfig) {
        guard usesCloudRecoveryGrace else {
            cloudRecoveryGraceUntil = nil
            return
        }
        guard config.provider == .fly else {
            cloudRecoveryGraceUntil = nil
            return
        }

        switch state {
        case .connecting, .unreachable, .pairingRequired:
            if cloudRecoveryGraceUntil.map({ Date() < $0 }) != true {
                cloudRecoveryGraceUntil = Date().addingTimeInterval(cloudRecoveryGraceDuration)
            }
        case .connected, .disconnected, .unauthorized:
            cloudRecoveryGraceUntil = nil
        }
    }

    private func switchToGateway(_ config: GatewayConfig) {
        selectedConfigID = config.id
        configStore.setActive(id: config.id)
        gateway.configure(gatewayConfig: config)
        #if os(iOS)
        wakeMacAddress = config.macAddress ?? RemCredentialStore.macWoLAddress ?? ""
        wakePacketSent = false
        #endif
    }

    private func addGateway(_ config: GatewayConfig) {
        configStore.save(config)
        switchToGateway(config)
        showGatewayChooser = false
        #if os(macOS)
        showLocalSetup = false
        #endif
    }

    private func refreshUpdateReadiness(for config: GatewayConfig) async {
        guard config.isActive, config.provider == .fly else {
            backendUpdateReadiness = nil
            updateReadinessError = nil
            return
        }

        do {
            backendUpdateReadiness = try await gateway.fetchGatewayUpdateReadiness()
            updateReadinessError = nil
        } catch {
            backendUpdateReadiness = nil
            updateReadinessError = "Using local update status. Rem could not refresh backend readiness yet."
        }
    }
}

#if DEBUG
private struct SharedGatewayDetailPreview: View {
    let scenario: PreviewGatewayScenario

    var body: some View {
        NavigationStack {
            SharedGatewayDetailView(
                config: scenario.config,
                configStore: PreviewGatewayConfigs.store(configs: [scenario.config]),
                gateway: PreviewGatewaySession(scenario: scenario),
                runtimeProviderAuthEvidence: .verified([]),
                showsConnectionsLink: true,
                usesCloudRecoveryGrace: scenario != .cloudCheckingApproval
            )
        }
    }
}

#Preview("Gateway Detail — Connected") {
    SharedGatewayDetailPreview(scenario: .cloudConnected)
}

#Preview("Gateway Detail — Waiting Approval") {
    SharedGatewayDetailPreview(scenario: .cloudApprovalPending)
}

#Preview("Gateway Detail — Checking Approval") {
    SharedGatewayDetailPreview(scenario: .cloudCheckingApproval)
}

#Preview("Gateway Detail — Unreachable") {
    SharedGatewayDetailPreview(scenario: .cloudUnreachable)
}

#Preview("Gateway Detail — Disconnected") {
    SharedGatewayDetailPreview(scenario: .cloudDisconnected)
}
#endif
