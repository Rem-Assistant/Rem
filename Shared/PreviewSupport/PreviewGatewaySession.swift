import Foundation
import SwiftUI

#if DEBUG
@MainActor
@Observable
final class PreviewGatewaySession: GatewaySessionProviding {
    var connectionState: GatewayConnectionState
    var sessionHealth = GatewaySessionHealthSnapshot.compose(
        operatorSessionState: .connected,
        nodeSessionState: .connected,
        gatewayProcessState: .running,
        manualRecoveryState: .none,
        detail: nil
    )
    var gatewayHostDisplay: String?
    var operatorReady = true
    var skillsSnapshotVersion = 0
    var isAutoRePairInProgress = false
    var supportsExplicitPairingApproval = true
    var isConfigured = true
    var isAuthenticated = true
    var linkedDevices: [LinkedDevice]
    var isLoadingLinkedDevices = false
    var pendingDevices: [PendingDevice]
    var isLoadingPendingDevices = false
    var pendingDeviceError: String?
    var storedGatewayURL: String?
    var storedGatewayToken: String?
    var activeLocalGatewayURL: String?
    var activeLocalGatewayToken: String?

    /// Optional canned RPC responder for fixtures that need `skillsRequest` to
    /// resolve (e.g. the Voice settings fixture feeding `talk.*`). When nil,
    /// `skillsRequest` throws, preserving the original no-gateway behaviour.
    @ObservationIgnored
    var skillsRequestHandler: ((_ method: String, _ paramsJSON: String?) async throws -> Data)?

    private let updateReadinessScenario: PreviewGatewayUpdateReadinessScenario

    init(
        scenario: PreviewGatewayScenario = .cloudConnected,
        updateReadinessScenario: PreviewGatewayUpdateReadinessScenario = .managedPreflightRequired
    ) {
        let config = scenario.config
        self.connectionState = scenario.connectionState
        self.gatewayHostDisplay = config.url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        self.linkedDevices = scenario.linkedDevices
        self.pendingDevices = scenario.pendingDevices
        self.updateReadinessScenario = updateReadinessScenario

        if config.provider == .local {
            self.activeLocalGatewayURL = config.url
            self.activeLocalGatewayToken = config.token
        } else {
            self.storedGatewayURL = config.url
            self.storedGatewayToken = config.token
        }
    }

    convenience init(
        connectionState: GatewayConnectionState,
        updateReadinessScenario: PreviewGatewayUpdateReadinessScenario,
        scenario: PreviewGatewayScenario? = nil
    ) {
        let resolvedScenario = scenario ?? PreviewGatewayScenario.cloudConnected
        self.init(
            scenario: resolvedScenario,
            updateReadinessScenario: updateReadinessScenario
        )
        self.connectionState = connectionState
    }

    func fetchLinkedDevices() {}
    func unlinkDevice(_ device: LinkedDevice) {}
    func fetchPendingDevices() async {}
    func approveDevice(_ device: PendingDevice) {
        pendingDevices.removeAll { $0.id == device.id }
        connectionState = .connected
    }
    func declineDevice(_ device: PendingDevice) {
        pendingDevices.removeAll { $0.id == device.id }
    }
    func reconnect() {}
    func connectIfConfigured() {}
    func clearConfiguration() {}
    func configure(gatewayURL: String, gatewayToken: String) {}
    func configure(gatewayConfig: GatewayConfig) {}
    func signOut() {}
    func resetPairing() {}

    func resetPairing(config: GatewayConfig?, configStore: GatewayConfigStore?) async throws -> String? {
        connectionState = .pairingRequired
        pendingDevices = [PreviewDevices.pendingIPhone]
        return "Preview reset pairing created a pending device request."
    }

    func requestPairingApproval(config: GatewayConfig?) async throws -> String? {
        connectionState = .connected
        pendingDevices = []
        return "Backend approved 1 pending device; reconnecting."
    }

    func fetchGatewayUpdateReadiness() async throws -> GatewayUpdateReadiness? {
        switch updateReadinessScenario {
        case .managedPreflightRequired:
            return GatewayUpdateReadiness(
                canUpdate: false,
                status: .managedFlyPreflightRequired,
                hostingProvider: "fly",
                gatewayUrl: PreviewGatewayConfigs.cloud.url,
                managedFlyAppName: "fixture-gateway",
                message: "Gateway updates require a tested backup, same-gateway deploy target, health check, and rollback path before they can be enabled.",
                requiredChecks: [
                    "same_gateway_target",
                    "backup_or_snapshot",
                    "approved_gateway_image",
                    "post_update_health_check",
                    "rollback_path",
                ],
                preflightChecks: Self.managedFlyPreflightChecks,
                approvedTargets: [
                    GatewayUpdateApprovedTarget(
                        id: "openclaw-stable",
                        label: "OpenClaw stable",
                        channel: "stable",
                        image: "ghcr.io/rem-assistant/openclaw-gateway:stable",
                        requiredCapabilities: ["skills.search"],
                        enabled: false,
                        disabledReason: "Not installable yet. Safe in-app updates require backup/snapshot, same-gateway targeting, health check, and rollback preflight."
                    ),
                ]
            )
        case .manualUpdate:
            return GatewayUpdateReadiness(
                canUpdate: false,
                status: .manualUpdate,
                hostingProvider: "fly",
                gatewayUrl: PreviewGatewayConfigs.cloud.url,
                managedFlyAppName: nil,
                message: "This gateway is not eligible for managed in-app updates yet. Update it outside Rem, then reconnect if needed.",
                requiredChecks: []
            )
        case .refreshFallback:
            throw URLError(.cannotConnectToHost)
        }
    }

    func skillsRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        if let skillsRequestHandler {
            return try await skillsRequestHandler(method, paramsJSON)
        }
        throw URLError(.unsupportedURL)
    }

    private static let managedFlyPreflightChecks: [GatewayUpdatePreflightCheck] = [
        GatewayUpdatePreflightCheck(
            id: "same_gateway_target",
            label: "Same Gateway Target",
            status: .ready,
            message: "Managed Fly app fixture-gateway is known. Machine and volume checks still need to run before updates can be enabled."
        ),
        GatewayUpdatePreflightCheck(
            id: "backup_or_snapshot",
            label: "Backup Or Snapshot",
            status: .blocked,
            message: "A tested gateway backup or volume snapshot is required before Rem can expose an in-app update action."
        ),
        GatewayUpdatePreflightCheck(
            id: "approved_gateway_image",
            label: "Approved Gateway Image",
            status: .ready,
            message: "The stable OpenClaw gateway image is approved for preflight display, but installation remains disabled until every safety gate passes."
        ),
        GatewayUpdatePreflightCheck(
            id: "post_update_health_check",
            label: "Post-Update Health Check",
            status: .notRun,
            message: "A post-update health probe has not run for this gateway and must pass before updates can be enabled."
        ),
        GatewayUpdatePreflightCheck(
            id: "rollback_path",
            label: "Rollback Path",
            status: .blocked,
            message: "A tested rollback path is required before Rem can offer managed gateway updates."
        ),
    ]
}
#endif
