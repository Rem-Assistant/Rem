import Foundation
import Observation

/// Status of the iOS Local Network permission. iOS gates `NWBrowser`
/// behind a per-app prompt that fires the first time you call `start()`.
/// macOS doesn't have this gate — use `.authorized` there.
enum LocalNetworkPermissionState: Equatable, Sendable {
    case undetermined
    case authorized
    case denied
}

/// Cross-platform contract for an mDNS/Bonjour browser that finds local
/// OpenClaw gateways. Implemented by `LocalGatewayDiscovery` (Mac) and
/// `IOSGatewayDiscovery` (iOS) so `SharedNearbyGatewaysView` can render
/// either one without `#if os` casts.
@MainActor
protocol GatewayDiscovering: AnyObject, Observable {
    var discoveredGateways: [DiscoveredGateway] { get }
    var isBrowsing: Bool { get }
    var permissionState: LocalNetworkPermissionState { get }

    func startBrowsing()
    func stopBrowsing()
}
