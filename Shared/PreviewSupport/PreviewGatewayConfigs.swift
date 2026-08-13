import Foundation

#if DEBUG
enum PreviewGatewayConfigs {
    static let cloud = GatewayConfig(
        id: "preview-cloud-gateway",
        url: "https://preview-gateway.rem.local",
        token: "preview-token",
        provider: .fly,
        displayName: "Cloud Gateway",
        isActive: true,
        transport: .manual
    )

    static let localMac = GatewayConfig(
        id: "preview-local-mac-gateway",
        url: "http://rem-mac.local:18790",
        token: "preview-token",
        provider: .local,
        displayName: "Mac Gateway",
        macAddress: "AA:BB:CC:DD:EE:FF",
        isActive: true,
        transport: .manual
    )

    static let inactiveManual = GatewayConfig(
        id: "preview-manual-gateway",
        url: "https://manual-gateway.example.com",
        token: "preview-token",
        provider: .manual,
        displayName: "Manual Gateway",
        isActive: false,
        transport: .manual
    )

    @MainActor
    static func store(configs: [GatewayConfig] = [cloud]) -> GatewayConfigStore {
        GatewayConfigStore(fixtureConfigs: configs)
    }
}
#endif
