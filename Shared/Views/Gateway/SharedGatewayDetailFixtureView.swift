import Foundation
import SwiftUI

#if DEBUG
typealias SharedGatewayDetailFixtureGateway = PreviewGatewaySession
typealias GatewayConnectionRecoveryFixtureScenario = PreviewGatewayScenario
typealias GatewayUpdateReadinessFixtureScenario = PreviewGatewayUpdateReadinessScenario

/// Deterministic visual QA surface for the shared gateway detail actions.
///
/// Launch iOS with `--rem-gateway-detail-fixture` to render the exact
/// `SharedGatewayDetailView` action section without auth, persisted gateway
/// configs, Keychain tokens, or a live gateway. Add
/// `--rem-gateway-approval-needs-attention-fixture`,
/// `--rem-gateway-local-unavailable-fixture`,
/// `--rem-gateway-update-manual-fixture` or
/// `--rem-gateway-update-refresh-fallback-fixture` to exercise the update
/// readiness and approval variants from #631/#643.
struct SharedGatewayDetailFixtureView: View {
    private let config: GatewayConfig
    private let usesCloudRecoveryGrace: Bool
    @State private var gateway: SharedGatewayDetailFixtureGateway
    @State private var configStore: GatewayConfigStore

    init(
        state: GatewayConnectionState = .fromGatewayDetailFixtureLaunchArguments(),
        provider: GatewayProvider = .fromGatewayDetailFixtureLaunchArguments(),
        usesCloudRecoveryGrace: Bool = .fromGatewayDetailFixtureLaunchArguments(),
        updateReadinessScenario: GatewayUpdateReadinessFixtureScenario = .fromLaunchArguments()
    ) {
        let displayName = provider == .local ? "Mac Gateway" : "Cloud Gateway"
        let url = provider == .local ? "http://rem-mac.local:18790" : "https://fixture-gateway.rem.local"
        let config = GatewayConfig(
            id: provider == .local ? "fixture-local-mac-gateway" : "fixture-cloud-gateway",
            url: url,
            token: "fixture-token",
            provider: provider,
            displayName: displayName,
            isActive: true,
            transport: .manual
        )
        self.config = config
        self.usesCloudRecoveryGrace = usesCloudRecoveryGrace
        self._gateway = State(initialValue: SharedGatewayDetailFixtureGateway(
            connectionState: state,
            updateReadinessScenario: updateReadinessScenario,
            scenario: provider == .local ? .localMacUnavailable : nil
        ))
        self._configStore = State(initialValue: GatewayConfigStore(fixtureConfigs: [config]))
    }

    var body: some View {
        NavigationStack {
            SharedGatewayDetailView(
                config: config,
                configStore: configStore,
                gateway: gateway,
                runtimeProviderAuthEvidence: .verified([]),
                showsConnectionsLink: false,
                usesCloudRecoveryGrace: usesCloudRecoveryGrace
            )
        }
    }
}

struct SharedGatewayConnectionRecoveryFixtureView: View {
    private let config: GatewayConfig
    private let scenario: GatewayConnectionRecoveryFixtureScenario
    @State private var gateway: SharedGatewayDetailFixtureGateway
    @State private var configStore: GatewayConfigStore

    init(scenario: GatewayConnectionRecoveryFixtureScenario = .fromLaunchArguments()) {
        let config = GatewayConfig(
            id: scenario.configID,
            url: scenario.url,
            token: "fixture-token",
            provider: scenario.provider,
            displayName: scenario.displayName,
            isActive: true,
            transport: .manual
        )
        self.config = config
        self.scenario = scenario
        self._gateway = State(initialValue: SharedGatewayDetailFixtureGateway(
            connectionState: scenario.connectionState,
            updateReadinessScenario: .managedPreflightRequired,
            scenario: scenario
        ))
        self._configStore = State(initialValue: GatewayConfigStore(fixtureConfigs: [config]))
    }

    var body: some View {
        NavigationStack {
            SharedGatewayConnectionRecoveryView(
                gateway: gateway,
                configStore: configStore
            )
        }
    }
}

struct SharedGatewayDevicePairingFixtureView: View {
    private let config: GatewayConfig
    @State private var gateway: SharedGatewayDetailFixtureGateway
    @State private var configStore: GatewayConfigStore

    init(scenario: GatewayConnectionRecoveryFixtureScenario = .fromLaunchArguments()) {
        let config = GatewayConfig(
            id: scenario.configID,
            url: scenario.url,
            token: "fixture-token",
            provider: scenario.provider,
            displayName: scenario.displayName,
            isActive: true,
            transport: .manual
        )
        self.config = config
        self._gateway = State(initialValue: SharedGatewayDetailFixtureGateway(
            connectionState: scenario.connectionState,
            updateReadinessScenario: .managedPreflightRequired,
            scenario: scenario
        ))
        self._configStore = State(initialValue: GatewayConfigStore(fixtureConfigs: [config]))
    }

    var body: some View {
        NavigationStack {
            SharedGatewayDevicePairingScreen(
                config: config,
                configStore: configStore,
                gateway: gateway
            )
        }
    }
}

struct SharedGatewayRecoveryDestinationFixtureView: View {
    private let config: GatewayConfig
    @State private var gateway: SharedGatewayDetailFixtureGateway
    @State private var configStore: GatewayConfigStore

    init(scenario: GatewayConnectionRecoveryFixtureScenario = .fromLaunchArguments()) {
        let config = GatewayConfig(
            id: scenario.configID,
            url: scenario.url,
            token: "fixture-token",
            provider: scenario.provider,
            displayName: scenario.displayName,
            isActive: true,
            transport: .manual
        )
        self.config = config
        self._gateway = State(initialValue: SharedGatewayDetailFixtureGateway(
            connectionState: scenario.connectionState,
            updateReadinessScenario: .managedPreflightRequired,
            scenario: scenario
        ))
        self._configStore = State(initialValue: GatewayConfigStore(fixtureConfigs: [config]))
    }

    var body: some View {
        SharedGatewayRecoveryDestinationView(
            gateway: gateway,
            configStore: configStore
        )
    }
}

private extension GatewayConnectionState {
    static func fromGatewayDetailFixtureLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> GatewayConnectionState {
        if arguments.contains("--rem-gateway-local-unavailable-fixture") {
            return .unreachable(nil)
        }
        if arguments.contains("--rem-gateway-approval-pending-fixture")
            || arguments.contains("--rem-gateway-approval-needs-attention-fixture") {
            return .pairingRequired
        }
        return .connected
    }
}

private extension GatewayProvider {
    static func fromGatewayDetailFixtureLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> GatewayProvider {
        arguments.contains("--rem-gateway-local-unavailable-fixture") ? .local : .fly
    }
}

private extension Bool {
    static func fromGatewayDetailFixtureLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        !arguments.contains("--rem-gateway-approval-needs-attention-fixture")
    }
}

#Preview("Gateway Detail — Connected") {
    SharedGatewayDetailFixtureView(state: .connected)
}

#Preview("Gateway Detail — Cloud Approval Pending") {
    SharedGatewayDetailFixtureView(state: .pairingRequired)
}

#Preview("Gateway Detail — Checking Approval") {
    SharedGatewayDetailFixtureView(
        state: .pairingRequired,
        usesCloudRecoveryGrace: false
    )
}

#Preview("Gateway Detail — Cloud Unreachable") {
    SharedGatewayDetailFixtureView(
        state: .unreachable("connect failed: gateway unavailable"),
        usesCloudRecoveryGrace: false
    )
}

#Preview("Gateway Detail — Disconnected") {
    SharedGatewayDetailFixtureView(state: .disconnected)
}

#Preview("Cloud Approval Needs Attention") {
    SharedGatewayDetailFixtureView(
        state: .pairingRequired,
        usesCloudRecoveryGrace: false
    )
}

#Preview("Update Preflight Required") {
    SharedGatewayDetailFixtureView(updateReadinessScenario: .managedPreflightRequired)
}

#Preview("Update Manual") {
    SharedGatewayDetailFixtureView(updateReadinessScenario: .manualUpdate)
}

#Preview("Update Refresh Fallback") {
    SharedGatewayDetailFixtureView(updateReadinessScenario: .refreshFallback)
}

#Preview("Connection Recovery") {
    SharedGatewayConnectionRecoveryFixtureView()
}

#Preview("Connection Recovery — Mac Unavailable") {
    SharedGatewayConnectionRecoveryFixtureView(scenario: .localMacUnavailable)
}

#Preview("Machine Connections — Empty") {
    SharedGatewayDevicePairingFixtureView(scenario: .cloudDisconnected)
}

#Preview("Machine Connections — Pending Request") {
    SharedGatewayDevicePairingFixtureView(scenario: .cloudApprovalPending)
}

#Preview("Machine Connections — Paired Devices") {
    SharedGatewayDevicePairingFixtureView(scenario: .cloudConnected)
}

#Preview("Machine Connections — Current Device Recovery") {
    SharedGatewayDevicePairingFixtureView(scenario: .deviceNeedsRepair)
}
#endif
