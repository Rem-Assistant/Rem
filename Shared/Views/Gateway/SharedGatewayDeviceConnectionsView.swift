import SwiftUI

// MARK: - Device Connections (pending + paired list content)

@ViewBuilder
fileprivate func sharedDevicePairingListSections<Gateway: GatewaySessionProviding>(
    gateway: Gateway,
    config: GatewayConfig? = nil,
    configStore: GatewayConfigStore? = nil,
    keepsApprovalCardVisible: Bool = false
) -> some View {
    if !gateway.pendingDevices.isEmpty {
        Section {
            ForEach(gateway.pendingDevices) { device in
                NavigationLink {
                    SharedPendingDeviceDetailView(
                        device: device,
                        onApprove: { gateway.approveDevice(device) },
                        onDecline: { gateway.declineDevice(device) }
                    )
                } label: {
                    SharedPendingDeviceRow(device: device)
                }
            }
        } header: {
            Text("Pending Connections")
        } footer: {
            Text("Open a request to review the device before approving or declining access.")
        }
    } else if keepsApprovalCardVisible || sharedGatewayNeedsApprovalRequest(gateway, config: config) {
        Section {
            SharedGatewayApprovalRequestCard(gateway: gateway, config: config)
        } header: {
            Text("Pending Connections")
        } footer: {
            if sharedGatewaySupportsManagedApproval(gateway, config: config) {
                Text("Finish Connection asks your cloud machine to approve this device, then refreshes paired devices and reconnects Rem.")
            } else {
                Text("Refresh Requests checks this gateway again for a pending device approval.")
            }
        }
    }

    Section {
        if gateway.isLoadingLinkedDevices && gateway.linkedDevices.isEmpty && gateway.pendingDevices.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                    .padding(.vertical, 8)
                Spacer()
            }
        } else if gateway.linkedDevices.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No paired devices")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("Other devices paired with your private machine will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            ForEach(gateway.linkedDevices) { device in
                NavigationLink {
                    SharedDeviceDetailView(
                        gateway: gateway,
                        device: device,
                        config: config,
                        configStore: configStore
                    )
                } label: {
                    SharedDeviceRow(device: device)
                }
            }
        }
    } header: {
        Text("Paired Devices")
    } footer: {
        Text("Open a device to review its connection, remove access, or reset pairing for this device.")
    }
}

private struct SharedGatewayApprovalRequestCard<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    let config: GatewayConfig?

    @State private var isFinishingConnection = false
    @State private var statusMessage: String?

    private var supportsManagedApproval: Bool {
        sharedGatewaySupportsManagedApproval(gateway, config: config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIcon(icon: "person.badge.key.fill", color: .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval needed")
                        .font(.headline)
                    Text(supportsManagedApproval
                         ? "Rem is waiting for this device to be approved, but no pending request is visible yet."
                         : "No pending device request is visible on this gateway yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if supportsManagedApproval {
                approvalButton
                    .remPrimaryActionButton()
            } else {
                approvalButton
                    .remSettingsCTA(.primary)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var approvalButton: some View {
        Button {
            finishConnection()
        } label: {
            HStack(spacing: 8) {
                if isFinishingConnection {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: supportsManagedApproval ? "checkmark.seal" : "arrow.clockwise")
                }
                Text(buttonTitle)
            }
        }
        .disabled(isFinishingConnection)
        .accessibilityIdentifier(supportsManagedApproval
                                 ? "paired-devices-finish-connection"
                                 : "paired-devices-refresh-requests")
    }

    private var buttonTitle: String {
        if isFinishingConnection {
            return supportsManagedApproval ? "Finishing Connection" : "Refreshing Requests"
        }
        return supportsManagedApproval ? "Finish Connection" : "Refresh Requests"
    }

    private func finishConnection() {
        isFinishingConnection = true
        statusMessage = supportsManagedApproval
            ? "Asking your cloud machine to approve this device."
            : "Refreshing pending device requests."

        Task { @MainActor in
            do {
                if supportsManagedApproval {
                    statusMessage = try await gateway.requestPairingApproval(config: config)
                        ?? "Checked this gateway for pending device approvals."
                    await gateway.fetchPendingDevices()
                } else {
                    await gateway.fetchPendingDevices()
                    statusMessage = "Checked this gateway for pending device approvals."
                }
                gateway.fetchLinkedDevices()
            } catch {
                statusMessage = supportsManagedApproval
                    ? "Connection approval failed: \(error.localizedDescription)"
                    : "Request refresh failed: \(error.localizedDescription)"
            }
            isFinishingConnection = false
        }
    }
}

private func sharedGatewaySupportsManagedApproval<Gateway: GatewaySessionProviding>(
    _ gateway: Gateway,
    config: GatewayConfig?
) -> Bool {
    config?.provider == .fly && gateway.supportsExplicitPairingApproval
}

private func sharedGatewayNeedsApprovalRequest<Gateway: GatewaySessionProviding>(
    _ gateway: Gateway,
    config: GatewayConfig?
) -> Bool {
    // Keep the recovery card mounted while list refresh is in flight. The full
    // pairing screen separately pins it across reconnect state transitions.
    guard gateway.pendingDevices.isEmpty else { return false }

    if case .pairingRequired = gateway.connectionState {
        return true
    }

    if gateway.sessionHealth.manualRecoveryState == .approvalRequired {
        return true
    }

    if GatewayApprovalRecoveryCardPolicy.shouldRemainVisible(
        enteredForApprovalRecovery: false,
        supportsManagedApproval: sharedGatewaySupportsManagedApproval(gateway, config: config),
        nodeConnected: gateway.connectionState.isConnected,
        operatorReady: gateway.operatorReady
    ) {
        return true
    }

    return gateway.sessionHealth.recoveryHints.contains(.openApprovalsList)
}

enum GatewayApprovalRecoveryCardPolicy {
    static func shouldRemainVisible(
        enteredForApprovalRecovery: Bool,
        supportsManagedApproval: Bool,
        nodeConnected: Bool,
        operatorReady: Bool
    ) -> Bool {
        let fullyConnected = nodeConnected && operatorReady
        return (enteredForApprovalRecovery && !fullyConnected)
            || (supportsManagedApproval && nodeConnected && !operatorReady)
    }
}

// MARK: - Machine Connections List (pending + paired only; used in chat sheet, etc.)

/// Pending + paired list. For connection detail, use ``SharedGatewayDevicePairingScreen``.
struct SharedDevicePairingListView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway

    var body: some View {
        List {
            sharedDevicePairingListSections(gateway: gateway)
        }
        .navigationTitle("Paired Devices")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        #endif
        .modifier(DevicePairingListModifiers(gateway: gateway))
    }
}

// MARK: - Machine Connections (single drill-in for gateway detail)

/// One place for pending/paired and **Pair a new device** (local). Device-specific recovery lives in device detail.
struct SharedGatewayDevicePairingScreen<Gateway: GatewaySessionProviding>: View {
    let config: GatewayConfig
    let configStore: GatewayConfigStore
    let gateway: Gateway

    @State private var showPairSheet = false
    @State private var enteredForApprovalRecovery: Bool

    init(config: GatewayConfig, configStore: GatewayConfigStore, gateway: Gateway) {
        self.config = config
        self.configStore = configStore
        self.gateway = gateway
        self._enteredForApprovalRecovery = State(
            initialValue: gateway.connectionState.needsDeviceRePair
        )
    }

    private var keepsApprovalCardVisible: Bool {
        GatewayApprovalRecoveryCardPolicy.shouldRemainVisible(
            enteredForApprovalRecovery: enteredForApprovalRecovery,
            supportsManagedApproval: sharedGatewaySupportsManagedApproval(gateway, config: config),
            nodeConnected: gateway.connectionState.isConnected,
            operatorReady: gateway.operatorReady
        )
    }

    private var pairSetupCode: GatewaySetupCode? {
        #if os(macOS)
        guard config.provider == .local else { return nil }
        return LocalGatewayManager.pairableSetupCode()
        #else
        return nil
        #endif
    }

    private var pairSheetIsLANReachable: Bool {
        #if os(macOS)
        return LocalGatewayManager.isLANReachable()
        #else
        return true
        #endif
    }

    var body: some View {
        List {
            sharedDevicePairingListSections(
                gateway: gateway,
                config: config,
                configStore: configStore,
                keepsApprovalCardVisible: keepsApprovalCardVisible
            )

            Section {
                if pairSetupCode != nil {
                    Button {
                        showPairSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "qrcode", color: .blue)
                            Text("Pair a New Device")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Paired Devices")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        #endif
        .modifier(DevicePairingListModifiers(gateway: gateway))
        .sheet(isPresented: $showPairSheet) {
            if let code = pairSetupCode {
                SharedPairDeviceSheetView(
                    code: code,
                    isLANReachable: pairSheetIsLANReachable
                ) {
                    showPairSheet = false
                }
            }
        }
    }
}

// MARK: - Device pairing list modifiers (shared)

private struct DevicePairingListModifiers<Gateway: GatewaySessionProviding>: ViewModifier {
    let gateway: Gateway

    func body(content: Content) -> some View {
        content
            .task {
                await gateway.fetchPendingDevices()
                gateway.fetchLinkedDevices()
            }
            .refreshable {
                await gateway.fetchPendingDevices()
                gateway.fetchLinkedDevices()
            }
            .alert("Device Action Failed",
                   isPresented: Binding(
                    get: { gateway.pendingDeviceError != nil },
                    set: { if !$0 { gateway.pendingDeviceError = nil } }
                   )) {
                Button("OK") { gateway.pendingDeviceError = nil }
            } message: {
                Text(gateway.pendingDeviceError ?? "")
            }
    }
}

#if DEBUG
private struct SharedGatewayDeviceConnectionsPreview: View {
    let title: String
    let scenario: PreviewGatewayScenario

    var body: some View {
        NavigationStack {
            SharedGatewayDevicePairingScreen(
                config: scenario.config,
                configStore: PreviewGatewayConfigs.store(configs: [scenario.config]),
                gateway: PreviewGatewaySession(scenario: scenario)
            )
            .navigationTitle(title)
        }
    }
}

#Preview("Machine Connections — No Devices") {
    SharedGatewayDeviceConnectionsPreview(
        title: "No Devices",
        scenario: .cloudDisconnected
    )
}

#Preview("Machine Connections — Pending Request") {
    SharedGatewayDeviceConnectionsPreview(
        title: "Pending Request",
        scenario: .cloudApprovalPending
    )
}

#Preview("Machine Connections — Approval Needed, No Visible Request") {
    SharedGatewayDeviceConnectionsPreview(
        title: "Approval Needed",
        scenario: .cloudApprovalPendingNoVisibleRequest
    )
}

#Preview("Machine Connections — Paired Devices") {
    SharedGatewayDeviceConnectionsPreview(
        title: "Paired Devices",
        scenario: .cloudConnected
    )
}

#Preview("Machine Connections — Current Device Recovery") {
    SharedGatewayDeviceConnectionsPreview(
        title: "Current Device Recovery",
        scenario: .deviceNeedsRepair
    )
}
#endif
