import Foundation
import Observation

#if DEBUG
@MainActor
@Observable
final class PreviewGatewayDiscovery: GatewayDiscovering {
    var discoveredGateways: [DiscoveredGateway]
    var isBrowsing: Bool
    var permissionState: LocalNetworkPermissionState

    init(
        discoveredGateways: [DiscoveredGateway] = [],
        isBrowsing: Bool = false,
        permissionState: LocalNetworkPermissionState = .authorized
    ) {
        self.discoveredGateways = discoveredGateways
        self.isBrowsing = isBrowsing
        self.permissionState = permissionState
    }

    func startBrowsing() {}
    func stopBrowsing() {}

    static let nearbyMac = DiscoveredGateway(
        id: "preview-nearby-mac",
        name: "Sam's Mac Gateway",
        host: "sam-mac.local",
        port: 18790
    )
}
#endif
