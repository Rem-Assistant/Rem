import Foundation
import SwiftUI

#if DEBUG
/// Deterministic visual QA surface for the shared settings root.
///
/// Launch the Mac target with `--rem-settings-fixture` to render the exact
/// `SharedSettingsView` rows without running auth, autoconnect, or live
/// gateway tasks.
struct SharedSettingsFixtureView: View {
    @State private var gateway = SharedSettingsFixtureGateway()

    var body: some View {
        NavigationStack {
            SharedSettingsView(
                gateway: gateway,
                onSignOut: { nil },
                onDeleteAccount: { nil },
                profileName: "Avery Lane",
                profileSubtitle: "avery@example.com",
                permissionsView: { fixtureDetail("Permissions", icon: "hand.raised.fill") },
                aboutView: { fixtureDetail("About", icon: "info.circle.fill") },
                gatewayBackupView: {
                    AnyView(fixtureDetail("Backup", icon: "externaldrive.fill"))
                }
            )
        }
        #if os(macOS)
        .frame(width: 760, height: 620)
        #endif
    }

    private func fixtureDetail(_ title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            SettingsIcon(icon: icon)
            Text(title)
                .font(DesignTokens.Typography.title3)
            Text("Fixture detail")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }
}

/// Deterministic visual QA surface for the Composio Connections detail route.
///
/// Launch with `--rem-connectors-fixture` to inspect the Connectors screen
/// without running auth, autoconnect, or live gateway tasks.
struct SharedConnectorsFixtureView: View {
    var body: some View {
        NavigationStack {
            SharedComposioConnectionsView(service: MockComposioService())
        }
        // Keep the deterministic mock flow inside the fixture so visual QA can inspect the
        // connection-completion state and its transient toast instead of handing off to Safari.
        .environment(\.openURL, OpenURLAction { _ in .handled })
        #if os(macOS)
        .frame(width: 760, height: 620)
        #endif
    }
}

#Preview("Settings Fixture") {
    SharedSettingsFixtureView()
}

#Preview("Connectors Fixture") {
    SharedConnectorsFixtureView()
}

@MainActor
@Observable
private final class SharedSettingsFixtureGateway: GatewaySessionProviding {
    var connectionState: GatewayConnectionState = .connected
    var sessionHealth = GatewaySessionHealthSnapshot.compose(
        operatorSessionState: .connected,
        nodeSessionState: .connected,
        gatewayProcessState: .running,
        manualRecoveryState: .none,
        detail: nil
    )
    var gatewayHostDisplay: String? = "fixture.rem.local"
    var operatorReady = true
    var skillsSnapshotVersion = 0
    var isAutoRePairInProgress = false
    var isConfigured = true
    var isAuthenticated = true
    var linkedDevices: [LinkedDevice] = []
    var isLoadingLinkedDevices = false
    var pendingDevices: [PendingDevice] = []
    var isLoadingPendingDevices = false
    var pendingDeviceError: String?
    var storedGatewayURL: String? = "https://fixture.rem.local"
    var storedGatewayToken: String? = "fixture-token"
    var activeLocalGatewayURL: String?
    var activeLocalGatewayToken: String?

    func fetchLinkedDevices() {}
    func unlinkDevice(_ device: LinkedDevice) {}
    func fetchPendingDevices() async {}
    func approveDevice(_ device: PendingDevice) {}
    func declineDevice(_ device: PendingDevice) {}
    func reconnect() {}
    func connectIfConfigured() {}
    func clearConfiguration() {}
    func configure(gatewayURL: String, gatewayToken: String) {}
    func configure(gatewayConfig: GatewayConfig) {}
    func signOut() {}
    func resetPairing() {}

    func resetPairing(config: GatewayConfig?, configStore: GatewayConfigStore?) async throws -> String? {
        nil
    }

    func skillsRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        throw URLError(.unsupportedURL)
    }
}
#endif
