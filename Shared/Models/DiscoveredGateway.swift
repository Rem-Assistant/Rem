import Foundation

/// A gateway discovered on the local network via mDNS / Bonjour
/// (`_openclaw-gw._tcp`). Shared between iOS and Mac so the same model
/// can drive `SharedNearbyGatewaysView` regardless of platform.
struct DiscoveredGateway: Identifiable, Equatable, Hashable, Sendable {
    /// Unique service identifier (`<name>.<type>.<domain>`).
    let id: String

    /// Human-readable name advertised by the service.
    let name: String

    /// Resolved hostname (typically `<name>.local`).
    let host: String

    /// Service port (currently the OpenClaw gateway default).
    let port: UInt16

    /// HTTP URL string built from host + port. Use `wss://` form via the
    /// gateway client when establishing the WebSocket session.
    var url: String { "http://\(host):\(port)" }
}
