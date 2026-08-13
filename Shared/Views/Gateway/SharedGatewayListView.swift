import SwiftUI

// MARK: - Machine List View

/// Machine list view shared between iOS and macOS.
/// Shows configured machines and connection status.
struct SharedGatewayListView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    let runtimeProviderAuthEvidence: RuntimeProviderAuthEvidence
    var backupView: (() -> AnyView)? = nil
    private let initialConfigStore: GatewayConfigStore?

    @State private var configStore: GatewayConfigStore?

    init(
        gateway: Gateway,
        runtimeProviderAuthEvidence: RuntimeProviderAuthEvidence,
        backupView: (() -> AnyView)? = nil,
        initialConfigStore: GatewayConfigStore? = nil
    ) {
        self.gateway = gateway
        self.runtimeProviderAuthEvidence = runtimeProviderAuthEvidence
        self.backupView = backupView
        self.initialConfigStore = initialConfigStore
        self._configStore = State(initialValue: initialConfigStore)
    }

    /// Sorted configs: active gateways first, then inactive.
    private var sortedConfigs: [GatewayConfig] {
        guard let store = configStore else { return [] }
        return SharedGatewaySettingsResolver.sortedConfigs(store.configs)
    }

    var body: some View {
        openClawListChrome
            .navigationTitle("Machines")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                if configStore == nil {
                    configStore = initialConfigStore ?? SharedGatewaySettingsStore.makeMigratedStore(gateway: gateway)
                }
            }
    }

    // `ListStyle.insetGrouped` is iOS/iPadOS-only (not in macOS SDK). On Mac,
    // `Form` + `.grouped` approximates the same section grouping. Widths
    // follow `DesignTokens.Layout` (Native reference frames), **leading** in
    // the split detail — same as system Settings, not a centered card.
    @ViewBuilder
    private var openClawListContent: some View {
        if let store = configStore {
            Section {
                if sortedConfigs.isEmpty {
                    Text("No machines configured yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(sortedConfigs, id: \.id) { config in
                        NavigationLink {
                            SharedGatewayDetailView(
                                config: config,
                                configStore: store,
                                gateway: gateway,
                                runtimeProviderAuthEvidence: runtimeProviderAuthEvidence,
                                backupView: backupView
                            )
                        } label: {
                            SharedGatewayRow(
                                config: config,
                                connectionState: config.isActive ? gateway.connectionState : nil
                            )
                        }
                    }
                }
            }
        }

        Section {
            Text("Additional gateway setup options are not available in this release.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openClawListChrome: some View {
        #if os(macOS)
        Form { openClawListContent }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { openClawListContent }
            .listStyle(.insetGrouped)
        #endif
    }
}

#if DEBUG
#Preview("Machine List — Empty") {
    NavigationStack {
        SharedGatewayListView(
            gateway: PreviewGatewaySession(scenario: .cloudDisconnected),
            runtimeProviderAuthEvidence: .verified([]),
            initialConfigStore: PreviewGatewayConfigs.store(configs: [])
        )
    }
}

#Preview("Machine List — Active Cloud") {
    NavigationStack {
        SharedGatewayListView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected),
            runtimeProviderAuthEvidence: .verified([]),
            initialConfigStore: PreviewGatewayConfigs.store(configs: [PreviewGatewayConfigs.cloud])
        )
    }
}

#Preview("Machine List — Inactive Local") {
    NavigationStack {
        SharedGatewayListView(
            gateway: PreviewGatewaySession(scenario: .localMacUnavailable),
            runtimeProviderAuthEvidence: .verified([]),
            initialConfigStore: PreviewGatewayConfigs.store(configs: [
                PreviewGatewayConfigs.cloud,
                PreviewGatewayConfigs.inactiveManual
            ])
        )
    }
}

#Preview("Machine List — Backup Available") {
    NavigationStack {
        SharedGatewayListView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected),
            runtimeProviderAuthEvidence: .verified([]),
            backupView: { AnyView(Text("Open local backup gateway")) },
            initialConfigStore: PreviewGatewayConfigs.store(configs: [
                PreviewGatewayConfigs.cloud,
                PreviewGatewayConfigs.localMac
            ])
        )
    }
}
#endif
