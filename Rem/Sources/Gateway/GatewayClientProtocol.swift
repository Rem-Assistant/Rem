import Foundation

// MARK: - Server provider abstraction

/// Describes where the gateway lives. Protocol-oriented so you can swap
/// Railway for self-hosted, Fly.io, local, etc. later.
protocol GatewayServerProvider: Sendable {
    /// Display name shown in Settings (e.g. "Railway", "Self-hosted").
    var displayName: String { get }

    /// Full gateway URL including scheme (e.g. "https://my-app.up.railway.app").
    var gatewayURL: URL { get }

    /// Bearer token for gateway auth.
    var gatewayToken: String { get }

    /// Whether TLS should be used. Defaults to true for remote providers.
    var usesTLS: Bool { get }
}

/// Default Railway provider — reads from persisted credentials.
struct RailwayProvider: GatewayServerProvider {
    let displayName = "Railway"
    let gatewayURL: URL
    let gatewayToken: String
    var usesTLS: Bool { true }

    init?(gatewayURL: String, gatewayToken: String) {
        guard let url = URL(string: gatewayURL) else { return nil }
        self.gatewayURL = url
        self.gatewayToken = gatewayToken
    }
}

/// Fly.io managed provider — deployed via backend provisioning.
struct FlyProvider: GatewayServerProvider {
    let displayName = "Fly.io"
    let gatewayURL: URL
    let gatewayToken: String
    var usesTLS: Bool { true }

    init?(gatewayURL: String, gatewayToken: String) {
        guard let url = URL(string: gatewayURL) else { return nil }
        self.gatewayURL = url
        self.gatewayToken = gatewayToken
    }
}

// MARK: - Connection state
// RemGatewayConnectionState is now defined in Shared/Protocols/GatewaySessionProviding.swift
// as GatewayConnectionState. The typealias in GatewaySessionConformance.swift preserves
// backward compatibility.
