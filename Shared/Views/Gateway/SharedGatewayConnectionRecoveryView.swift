import SwiftUI

// MARK: - Connection Recovery Compatibility Wrapper

/// Backwards-compatible wrapper for older fixture and route call sites.
///
/// Production recovery now lives in the gateway-owned IA:
/// - Gateway health, retry, and gateway repair live in `SharedGatewayDetailView`.
/// - Device approval, decline, and reset live in the device-specific detail views.
struct SharedGatewayConnectionRecoveryView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    private let configStore: GatewayConfigStore?

    init(gateway: Gateway, configStore: GatewayConfigStore? = nil) {
        self.gateway = gateway
        self.configStore = configStore
    }

    var body: some View {
        SharedGatewayRecoveryDestinationView(
            gateway: gateway,
            configStore: configStore
        )
    }
}

#if DEBUG
private struct SharedGatewayConnectionRecoveryPreview: View {
    let scenario: PreviewGatewayScenario

    var body: some View {
        NavigationStack {
            SharedGatewayConnectionRecoveryView(
                gateway: PreviewGatewaySession(scenario: scenario),
                configStore: PreviewGatewayConfigs.store(configs: [scenario.config])
            )
        }
    }
}

#Preview("Recovery Route - Cloud Approval") {
    SharedGatewayConnectionRecoveryPreview(scenario: .cloudApprovalPending)
}

#Preview("Recovery Route - Cloud Waking") {
    SharedGatewayConnectionRecoveryPreview(scenario: .cloudWaking)
}

#Preview("Recovery Route - Cloud Unreachable") {
    SharedGatewayConnectionRecoveryPreview(scenario: .cloudUnreachable)
}

#Preview("Recovery Route - Local Unavailable") {
    SharedGatewayConnectionRecoveryPreview(scenario: .localMacUnavailable)
}
#endif
