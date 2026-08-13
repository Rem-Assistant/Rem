import SwiftUI

// MARK: - Gateway Home View

/// OpenClaw settings landing page.
/// When a gateway exists, the global settings row lands on that gateway's
/// detail so status/pairing/Skills/MCP controls stay scoped to one gateway.
struct SharedOpenClawGatewayHomeView<Gateway: GatewaySessionProviding>: View {
    @Environment(\.scenePhase) private var scenePhase
    let gateway: Gateway
    var backupView: (() -> AnyView)? = nil
    private let initialConfigStore: GatewayConfigStore?

    @State private var configStore: GatewayConfigStore?
    @State private var runtimeProviderAuthEvidence = RuntimeProviderAuthEvidence.loading(
        lastVerifiedProviderIDs: nil)
    @State private var providerEvidenceSessionGeneration: UInt64?
    /// Bounds stale usable-auth evidence when credentials expire or are repaired outside this UI.
    @State private var providerEvidenceRefreshRevision: UInt64 = 0

    private var providerEvidenceGatewayIdentity: String {
        [gateway.storedGatewayURL ?? "", gateway.activeLocalGatewayURL ?? ""]
            .joined(separator: "|")
    }

    init(
        gateway: Gateway,
        backupView: (() -> AnyView)? = nil,
        initialConfigStore: GatewayConfigStore? = nil
    ) {
        self.gateway = gateway
        self.backupView = backupView
        self.initialConfigStore = initialConfigStore
        self._configStore = State(initialValue: initialConfigStore)
    }

    var body: some View {
        Group {
            if let store = configStore,
               let config = SharedGatewaySettingsResolver.preferredLandingConfig(from: store.configs) {
                SharedGatewayDetailView(
                    config: config,
                    configStore: store,
                    gateway: gateway,
                    runtimeProviderAuthEvidence: runtimeProviderAuthEvidence,
                    backupView: backupView,
                    showsConnectionsLink: true
                )
            } else {
                SharedGatewayListView(
                    gateway: gateway,
                    runtimeProviderAuthEvidence: runtimeProviderAuthEvidence,
                    backupView: backupView,
                    initialConfigStore: configStore
                )
            }
        }
        .onAppear {
            if configStore == nil {
                configStore = initialConfigStore ?? SharedGatewaySettingsStore.makeMigratedStore(gateway: gateway)
            }
        }
        .task(id: [
            gateway.operatorReady.description,
            String(gateway.operatorSessionGeneration),
            providerEvidenceGatewayIdentity,
            String(gateway.skillsSnapshotVersion),
            String(providerEvidenceRefreshRevision),
        ]
            .joined(separator: "|")) {
            let sessionGeneration = gateway.operatorSessionGeneration
            let priorSameScopeEvidence = providerEvidenceSessionGeneration == sessionGeneration
                ? runtimeProviderAuthEvidence
                : nil
            let lastVerified = priorSameScopeEvidence?.hasAuthoritativeSnapshot == true
                ? priorSameScopeEvidence?.effectiveProviderIDs
                : nil
            providerEvidenceSessionGeneration = sessionGeneration
            runtimeProviderAuthEvidence = priorSameScopeEvidence?.beginningSameScopeRefresh
                ?? .loading(lastVerifiedProviderIDs: nil)
            guard gateway.operatorReady else {
                runtimeProviderAuthEvidence = .failed(lastVerifiedProviderIDs: lastVerified)
                return
            }
            let gatewayIdentity = providerEvidenceGatewayIdentity
            do {
                let providerIDs = try await gateway.loadRuntimeConfiguredProviderIDs()
                guard !Task.isCancelled,
                      gateway.operatorReady,
                      gateway.operatorSessionGeneration == sessionGeneration,
                      providerEvidenceGatewayIdentity == gatewayIdentity
                else { return }
                runtimeProviderAuthEvidence = .verified(providerIDs)
            } catch {
                guard !Task.isCancelled,
                      gateway.operatorSessionGeneration == sessionGeneration,
                      providerEvidenceGatewayIdentity == gatewayIdentity
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
    }
}

#if DEBUG
#Preview("Gateway Home — Empty") {
    NavigationStack {
        SharedOpenClawGatewayHomeView(
            gateway: PreviewGatewaySession(scenario: .cloudDisconnected),
            initialConfigStore: PreviewGatewayConfigs.store(configs: [])
        )
    }
}

#Preview("Gateway Home — One Cloud") {
    NavigationStack {
        SharedOpenClawGatewayHomeView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected),
            initialConfigStore: PreviewGatewayConfigs.store(configs: [PreviewGatewayConfigs.cloud])
        )
    }
}

#Preview("Gateway Home — Cloud + Local") {
    NavigationStack {
        SharedOpenClawGatewayHomeView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected),
            initialConfigStore: PreviewGatewayConfigs.store(configs: [
                PreviewGatewayConfigs.cloud,
                PreviewGatewayConfigs.localMac
            ])
        )
    }
}
#endif
