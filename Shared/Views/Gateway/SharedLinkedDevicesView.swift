import SwiftUI

// MARK: - Shared Linked Devices List

/// Paired devices list shared between iOS and macOS.
struct SharedLinkedDevicesView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway

    var body: some View {
        Group {
            if gateway.isLoadingLinkedDevices && gateway.linkedDevices.isEmpty {
                loadingView
            } else if gateway.linkedDevices.isEmpty {
                emptyView
            } else {
                deviceList
            }
        }
        .onAppear {
            gateway.fetchLinkedDevices()
        }
    }

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
                .padding(.vertical, 8)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No paired devices")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Other devices paired with your gateway will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var deviceList: some View {
        ForEach(gateway.linkedDevices) { device in
            SharedDeviceRow(device: device)
        }
    }
}

#if DEBUG
#Preview("Linked Devices — Empty") {
    List {
        SharedLinkedDevicesView(
            gateway: PreviewGatewaySession(scenario: .cloudDisconnected)
        )
    }
}

#Preview("Linked Devices — Paired") {
    List {
        SharedLinkedDevicesView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected)
        )
    }
}

#Preview("Device Detail — Current Device") {
    NavigationStack {
        SharedDeviceDetailView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected),
            device: PreviewDevices.pairedIPhone
        )
    }
}
#endif

// MARK: - Device Row

struct SharedDeviceRow: View {
    let device: LinkedDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.connectionSymbol)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.connectionDisplayName)
                        .font(.body)

                    if device.isCurrentDevice {
                        Text("This device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.15))
                            )
                    }
                }

                Text(device.connectionPlatformText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(device.connectionIndicatorColor)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Device Detail View

struct SharedDeviceDetailView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    let device: LinkedDevice
    var config: GatewayConfig? = nil
    var configStore: GatewayConfigStore? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showUnlinkConfirmation = false
    @State private var showResetPairingConfirmation = false
    @State private var isResettingPairing = false
    @State private var resetPairingMessage: String?

    var body: some View {
        List {
            // Device header
            Section {
                VStack(spacing: 12) {
                    Image(systemName: device.connectionSymbol)
                        .font(.system(size: 44))
                        .foregroundColor(.blue)

                    Text(device.connectionDisplayName)
                        .font(.title3.bold())

                    if device.isCurrentDevice {
                        Text("Primary Device")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.blue))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                detailRow(label: "Platform", value: device.connectionPlatformText)
                detailRow(label: "Status", value: deviceStatusText)

                if let lastActiveText {
                    detailRow(label: "Last Active", value: lastActiveText)
                }

                if let approvedText {
                    detailRow(label: "Approved", value: approvedText)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(connectionFooterText)
            }

            // Permissions / scopes
            if let scopes = device.scopes, !scopes.isEmpty {
                Section {
                    ForEach(scopes, id: \.self) { scope in
                        HStack(spacing: 8) {
                            Image(systemName: scopeIcon(for: scope))
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(scopeDisplayName(for: scope))
                        }
                    }
                } header: {
                    Text("Permissions")
                }
            }

            if device.isCurrentDevice {
                Section {
                    Button(role: .destructive) {
                        showResetPairingConfirmation = true
                    } label: {
                        HStack {
                            if isResettingPairing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isResettingPairing ? "Resetting Pairing" : "Reset Pairing")
                        }
                    }
                    .remInlineRecoveryCTA(.destructive)
                    .disabled(isResettingPairing)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(resetPairingFooterText)
                }

                if let resetPairingMessage {
                    Section {
                        Label {
                            Text(resetPairingMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Unlink button (non-primary only)
            if !device.isCurrentDevice {
                Section {
                    Button(role: .destructive) {
                        showUnlinkConfirmation = true
                    } label: {
                        Text("Unlink Device")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } footer: {
                    Text("This device will need to pair again to connect to your gateway.")
                }
            }
        }
        #if os(iOS)
        .navigationTitle(device.connectionDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            "Unlink \(device.connectionDisplayName)?",
            isPresented: $showUnlinkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unlink", role: .destructive) {
                gateway.unlinkDevice(device)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device will be disconnected and will need to pair again.")
        }
        .confirmationDialog(
            "Reset pairing for this device?",
            isPresented: $showResetPairingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Pairing", role: .destructive) {
                resetCurrentDevicePairing()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears this device's pairing token and reconnects with a fresh pairing request. Use this only if this device can no longer connect.")
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var deviceStatusText: String {
        if device.isRuntimeAgentConnection, device.isRecentlyActive {
            return "Recently active"
        }
        if device.isRuntimeAgentConnection {
            return "Approved"
        }
        if device.isCurrentDevice, gateway.connectionState.needsDeviceRePair {
            return "Needs pairing"
        }
        if device.isCurrentDevice, !gateway.connectionState.isConnected {
            return "Disconnected"
        }
        if device.isRecentlyActive {
            return "Recently active"
        }
        return "Paired"
    }

    private var connectionFooterText: String {
        if device.isRuntimeAgentConnection {
            return "This Rem runtime connection can use your gateway for approved actions until you remove access."
        }
        if device.isCurrentDevice, gateway.connectionState.needsDeviceRePair {
            return "This device needs to pair with the gateway again before it can connect."
        }
        if device.isCurrentDevice, !gateway.connectionState.isConnected {
            return "This is the device you are using now. Reset pairing only if reconnecting does not work."
        }
        if device.isCurrentDevice {
            return "This is the device you are using now."
        }
        return "This device can connect to your gateway until you remove its access."
    }

    private var resetPairingFooterText: String {
        if gateway.connectionState.needsDeviceRePair {
            return "Reset pairing creates a fresh request for this device. Use this when the gateway asks this device to pair again."
        }
        return "Use reset only when this device no longer connects or the gateway asks it to pair again."
    }

    private func resetCurrentDevicePairing() {
        isResettingPairing = true
        resetPairingMessage = nil

        Task { @MainActor in
            do {
                let message = try await gateway.resetPairing(config: config, configStore: configStore)
                resetPairingMessage = message ?? "Pairing was reset. Rem is reconnecting this device."
            } catch {
                resetPairingMessage = "Reset pairing failed: \(error.localizedDescription)"
            }
            isResettingPairing = false
        }
    }

    private var lastActiveText: String? {
        guard let lastActiveMs = device.lastActiveMs else { return nil }
        return Self.dateText(millisecondsSince1970: lastActiveMs)
    }

    private var approvedText: String? {
        guard let approvedAtMs = device.approvedAtMs else { return nil }
        return Self.dateText(millisecondsSince1970: approvedAtMs)
    }

    private static func dateText(millisecondsSince1970: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millisecondsSince1970) / 1000)
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func scopeIcon(for scope: String) -> String {
        switch scope {
        case "operator.read": "eye"
        case "operator.write": "pencil"
        case "operator.admin": "shield"
        case "operator.talk.secrets": "lock"
        case "operator.pairing": "checkmark.seal"
        default: "circle"
        }
    }

    private func scopeDisplayName(for scope: String) -> String {
        switch scope {
        case "operator.read": "Read"
        case "operator.write": "Write"
        case "operator.admin": "Admin"
        case "operator.talk.secrets": "Voice Secrets"
        case "operator.pairing": "Pairing Approval"
        default: scope
        }
    }
}

private extension LinkedDevice {
    var isRuntimeAgentConnection: Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedClient = (clientId ?? "").lowercased()
        let hasPairingScope = scopes?.contains("operator.pairing") == true

        return normalizedName == "agent"
            || normalizedDisplayName == "agent"
            || normalizedClient.contains("agent")
            || (hasPairingScope && inferredPlatform == .unknown)
    }

    var connectionDisplayName: String {
        isRuntimeAgentConnection ? "Rem agent" : name
    }

    var connectionPlatformText: String {
        isRuntimeAgentConnection ? "Runtime agent" : inferredPlatform.displayName
    }

    var connectionSymbol: String {
        isRuntimeAgentConnection ? "laptopcomputer.and.iphone" : inferredPlatform.sfSymbol
    }

    var connectionIndicatorColor: Color {
        if isCurrentDevice || isRecentlyActive {
            return .green
        }
        return .gray
    }
}
