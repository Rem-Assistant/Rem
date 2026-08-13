import SwiftUI

// MARK: - Shared Pending Devices View

/// Displays devices awaiting pairing approval with approve/decline actions.
/// Shared between iOS and macOS via the GatewaySessionProviding protocol.
struct SharedPendingDevicesView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway

    var body: some View {
        Group {
            if gateway.isLoadingPendingDevices && gateway.pendingDevices.isEmpty {
                loadingView
            } else if gateway.pendingDevices.isEmpty {
                emptyView
            } else {
                deviceList
            }
        }
        .task {
            await gateway.fetchPendingDevices()
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
            Image(systemName: "checkmark.shield")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No pending requests")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Devices requesting access to your gateway will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var deviceList: some View {
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
    }
}

// MARK: - Pending Device Row

struct SharedPendingDeviceRow: View {
    let device: PendingDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.connectionSymbol)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.connectionDisplayName)
                    .font(.body)

                Text(device.connectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
        }
        .padding(.vertical, 4)
    }
}

struct SharedPendingDeviceDetailView: View {
    let device: PendingDevice
    let onApprove: () -> Void
    let onDecline: () -> Void
    #if DEBUG
    var fixtureActionState: PendingDeviceDetailPreviewState = .idle
    #endif

    @Environment(\.dismiss) private var dismiss
    @State private var showDeclineConfirmation = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        SettingsIcon(icon: device.connectionSymbol, color: .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.connectionDisplayName)
                                .font(.headline)
                            Text(device.connectionSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(device.connectionApprovalBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    onApprove()
                    dismiss()
                } label: {
                    HStack {
                        #if DEBUG
                        if fixtureActionState == .approving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        #endif
                        Text(approveTitle)
                    }
                }
                .remPrimaryActionButton()
                .disabled(isActionInProgress)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                Button(role: .destructive) {
                    showDeclineConfirmation = true
                } label: {
                    HStack {
                        #if DEBUG
                        if fixtureActionState == .declining {
                            ProgressView()
                                .controlSize(.small)
                        }
                        #endif
                        Text(declineTitle)
                    }
                }
                .remInlineRecoveryCTA(.destructive)
                .disabled(isActionInProgress)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            } footer: {
                Text("Declining rejects this request only. The device can request access again later.")
            }

            #if DEBUG
            if fixtureActionState == .actionFailed {
                Section {
                    Label {
                        Text("Device action failed. Try again after the gateway reconnects.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            #endif
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(device.connectionDisplayName)
        .confirmationDialog(
            "Decline \(device.connectionDisplayName)?",
            isPresented: $showDeclineConfirmation,
            titleVisibility: .visible
        ) {
            Button("Decline", role: .destructive) {
                onDecline()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(device.connectionDeclineDialogMessage)
        }
    }

    private var approveTitle: String {
        #if DEBUG
        if fixtureActionState == .approving {
            return device.isRuntimeAgentRequest ? "Approving Connection" : "Approving Device"
        }
        #endif
        return device.isRuntimeAgentRequest ? "Approve Connection" : "Approve Device"
    }

    private var declineTitle: String {
        #if DEBUG
        if fixtureActionState == .declining { return "Declining Request" }
        #endif
        return "Decline Request"
    }

    private var isActionInProgress: Bool {
        #if DEBUG
        fixtureActionState == .approving || fixtureActionState == .declining
        #else
        false
        #endif
    }
}

private extension PendingDevice {
    var isRuntimeAgentRequest: Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName == "agent" || normalizedDisplayName == "agent"
    }

    var connectionDisplayName: String {
        isRuntimeAgentRequest ? "Rem agent" : name
    }

    var connectionSubtitle: String {
        isRuntimeAgentRequest ? "Runtime requesting access" : "Requesting access"
    }

    var connectionSymbol: String {
        isRuntimeAgentRequest ? "laptopcomputer.and.iphone" : inferredPlatform.sfSymbol
    }

    var connectionApprovalBody: String {
        if isRuntimeAgentRequest {
            return "Approve this request only if it came from the Rem chat you just started. Approval lets the Rem runtime use this cloud gateway for approved actions. Declining rejects this request only; it does not sign you out, remove the app, or delete your gateway."
        }

        return "Approve this request only if this is your device. Approval lets this device connect to this gateway. Declining only rejects this request; it does not sign you out, remove the app, or delete your gateway."
    }

    var connectionDeclineDialogMessage: String {
        if isRuntimeAgentRequest {
            return "This Rem runtime request will not be able to use your gateway unless it requests access again."
        }

        return "This device will not be able to connect to your gateway unless it requests access again."
    }
}

#if DEBUG
enum PendingDeviceDetailPreviewState: CaseIterable {
    case idle
    case approving
    case declining
    case actionFailed
}

#Preview("Pending Device — Idle") {
    NavigationStack {
        SharedPendingDeviceDetailView(
            device: PreviewDevices.pendingIPhone,
            onApprove: {},
            onDecline: {}
        )
    }
}

#Preview("Pending Device — Approving") {
    NavigationStack {
        SharedPendingDeviceDetailView(
            device: PreviewDevices.pendingIPhone,
            onApprove: {},
            onDecline: {},
            fixtureActionState: .approving
        )
    }
}

#Preview("Pending Device — Declining") {
    NavigationStack {
        SharedPendingDeviceDetailView(
            device: PreviewDevices.pendingIPhone,
            onApprove: {},
            onDecline: {},
            fixtureActionState: .declining
        )
    }
}

#Preview("Pending Device — Action Failed") {
    NavigationStack {
        SharedPendingDeviceDetailView(
            device: PreviewDevices.pendingIPhone,
            onApprove: {},
            onDecline: {},
            fixtureActionState: .actionFailed
        )
    }
}

#Preview("Pending Rem Agent") {
    NavigationStack {
        SharedPendingDeviceDetailView(
            device: PreviewDevices.pendingAgent,
            onApprove: {},
            onDecline: {}
        )
    }
}
#endif
