import SwiftUI

/// Production recovery router for launch and banner handoffs. It keeps the
/// destination inside the gateway-owned IA instead of presenting a generic
/// connection hub as the final surface.
struct SharedGatewayRecoveryDestinationView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    private let initialConfigStore: GatewayConfigStore?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var configStore: GatewayConfigStore?
    @State private var showsPairingRecovery: Bool
    @State private var runtimeProviderAuthEvidence = RuntimeProviderAuthEvidence.loading(
        lastVerifiedProviderIDs: nil)
    @State private var providerEvidenceSessionGeneration: UInt64?
    /// Bounds stale usable-auth evidence when credentials expire or are repaired outside this UI.
    @State private var providerEvidenceRefreshRevision: UInt64 = 0

    private var providerEvidenceGatewayIdentity: String {
        [gateway.storedGatewayURL ?? "", gateway.activeLocalGatewayURL ?? ""]
            .joined(separator: "|")
    }

    private var activeConfig: GatewayConfig? {
        configStore.flatMap { SharedGatewaySettingsResolver.preferredLandingConfig(from: $0.configs) }
    }

    init(gateway: Gateway, configStore: GatewayConfigStore? = nil) {
        self.gateway = gateway
        self.initialConfigStore = configStore
        self._configStore = State(initialValue: configStore)
        self._showsPairingRecovery = State(initialValue: gateway.connectionState.needsDeviceRePair)
    }

    var body: some View {
        Group {
            if let configStore, let config = activeConfig {
                // Capture the entry route. A pairing approval intentionally moves
                // through connecting/disconnected states; switching destinations
                // mid-request would discard the result and strand the user back in
                // Agent settings.
                if showsPairingRecovery {
                    SharedGatewayDevicePairingScreen(
                        config: config,
                        configStore: configStore,
                        gateway: gateway
                    )
                } else {
                    SharedGatewayDetailView(
                        config: config,
                        configStore: configStore,
                        gateway: gateway,
                        runtimeProviderAuthEvidence: runtimeProviderAuthEvidence,
                        backupView: nil,
                        showsConnectionsLink: true
                    )
                }
            } else {
                List {
                    Section {
                        Text("No gateway is configured on this device yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .navigationTitle("Gateway")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
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
#Preview("Recovery Destination — Approval Pending") {
    NavigationStack {
        SharedGatewayRecoveryDestinationView(
            gateway: PreviewGatewaySession(scenario: .cloudApprovalPending),
            configStore: PreviewGatewayConfigs.store(configs: [PreviewGatewayConfigs.cloud])
        )
    }
}

#Preview("Recovery Destination — Gateway Detail") {
    NavigationStack {
        SharedGatewayRecoveryDestinationView(
            gateway: PreviewGatewaySession(scenario: .cloudUnreachable),
            configStore: PreviewGatewayConfigs.store(configs: [PreviewGatewayConfigs.cloud])
        )
    }
}
#endif
