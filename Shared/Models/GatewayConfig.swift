import Foundation

// MARK: - Gateway Host Display

/// Masks internal infrastructure names out of any user-facing "Host" / gateway
/// name field.
///
/// Pre-warmed pool gateways are created with the Fly app name
/// `remclaw-pool-<id>` (by the managed pre-warm pool pipeline). On
/// assignment that app is handed to the user as-is — Fly apps cannot be renamed
/// in place, and re-creating a `remclaw-{userId[:8]}` app would defeat the whole
/// point of the pool (<30s assign). So the user's real `gateway_url` /
/// `fly_app_name` legitimately stays `remclaw-pool-<id>.fly.dev` for connection
/// and backend repair.
///
/// What must NOT happen is that internal "pool" name leaking into the UI: per
/// `CLAUDE.md` the user-facing identity is a managed cloud gateway, not "pool".
/// A founder saw `Host = remclaw-pool-…fly.dev` in Agent Settings — this helper
/// is the single chokepoint that keeps that from reaching any display surface.
enum GatewayHostDisplay {
    /// Friendly label shown in place of an internal pool app host. We cannot
    /// synthesize a truthful per-user hostname here (the real app *is* the pool
    /// app), so we present the managed-cloud product name instead of a fake
    /// `remclaw-<userId>.fly.dev` that wouldn't resolve.
    static let managedCloudLabel = "Rem Cloud Gateway"

    /// `true` when `host` is an internal pre-warmed pool app host.
    static func isPoolHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized.hasPrefix("remclaw-pool-") && normalized.hasSuffix(".fly.dev")
    }

    /// Returns a UI-safe host string. Non-pool hosts pass through unchanged
    /// (e.g. `remclaw-abc12345.fly.dev`, `sam-mac.local`); pool hosts are
    /// replaced with `managedCloudLabel`. `nil` in → `nil` out.
    static func sanitized(_ host: String?) -> String? {
        guard let host else { return nil }
        return isPoolHost(host) ? managedCloudLabel : host
    }
}

// MARK: - Gateway Provider

/// The type of gateway deployment.
enum GatewayProvider: String, Codable, Sendable, CaseIterable {
    case fly = "fly"
    case local = "local"
    /// Manually entered URL/token gateway records used by setup-code fallback,
    /// legacy custom gateways, and older saved configurations.
    case manual = "manual"

    var displayName: String {
        switch self {
        case .fly: "Cloud machine"
        case .local: "Local Mac"
        case .manual: "Manual"
        }
    }

    var icon: String {
        switch self {
        case .fly: "cloud.fill"
        case .local: "desktopcomputer"
        case .manual: "wrench.and.screwdriver.fill"
        }
    }

    /// Where the agent runs, shown in the "Runs on" Gateway Info row.
    /// Founder rename: the gateway concept is surfaced as "Agents", so we
    /// describe the runtime location rather than a device name.
    var runsOnDescription: String {
        switch self {
        case .fly: "Cloud"
        case .local: "This Mac"
        case .manual: "Custom"
        }
    }
}

// MARK: - Authenticated Gateway Credential Refresh

/// Non-provider gateway connection material returned by `/api/v1/me/credentials`.
/// Provider API keys are gateway/backend owned and must never be retained by this DTO.
nonisolated struct GatewayCredentialsResponse: Decodable, Equatable, Sendable {
    let gatewayUrl: String
    let gatewayToken: String
    let hostingProvider: String?
}

/// Decodes a successful authenticated credential refresh and removes the legacy device-cached
/// Voice provider key before callers publish the refreshed connection. Scrub failure is fatal:
/// an existing secret must not silently survive a successful server refresh.
nonisolated enum GatewayCredentialRefreshPolicy {
    static func decodeAndScrubLegacyVoiceKey(
        data: Data,
        scrubLegacyVoiceKey: () throws -> Void
    ) throws -> GatewayCredentialsResponse {
        let response = try JSONDecoder().decode(GatewayCredentialsResponse.self, from: data)
        try scrubLegacyVoiceKey()
        return response
    }
}

// MARK: - Gateway Update Readiness

enum GatewayUpdateReadinessStatus: Equatable, Sendable, Decodable {
    case noGateway
    case managedFlyPreflightRequired
    case manualUpdate
    case unknown(String)

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "no_gateway":
            self = .noGateway
        case "managed_fly_preflight_required":
            self = .managedFlyPreflightRequired
        case "manual_update":
            self = .manualUpdate
        default:
            self = .unknown(rawValue)
        }
    }
}

struct GatewayUpdateReadinessResponse: Decodable, Sendable, Equatable {
    let readiness: GatewayUpdateReadiness
}

struct GatewayUpdateApprovedTarget: Decodable, Sendable, Equatable {
    let id: String
    let label: String
    let channel: String
    let image: String
    let requiredCapabilities: [String]
    let enabled: Bool
    let disabledReason: String
}

enum GatewayUpdatePreflightCheckStatus: Equatable, Sendable, Decodable {
    case ready
    case blocked
    case notRun
    case unknown(String)

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "ready":
            self = .ready
        case "blocked":
            self = .blocked
        case "not_run":
            self = .notRun
        default:
            self = .unknown(rawValue)
        }
    }
}

struct GatewayUpdatePreflightCheck: Decodable, Sendable, Equatable {
    let id: String
    let label: String
    let status: GatewayUpdatePreflightCheckStatus
    let message: String
}

struct GatewayUpdateReadiness: Decodable, Sendable, Equatable {
    let canUpdate: Bool
    let status: GatewayUpdateReadinessStatus
    let hostingProvider: String
    let gatewayUrl: String?
    let managedFlyAppName: String?
    let message: String
    let requiredChecks: [String]
    let preflightChecks: [GatewayUpdatePreflightCheck]
    let approvedTargets: [GatewayUpdateApprovedTarget]

    init(
        canUpdate: Bool,
        status: GatewayUpdateReadinessStatus,
        hostingProvider: String,
        gatewayUrl: String?,
        managedFlyAppName: String?,
        message: String,
        requiredChecks: [String],
        preflightChecks: [GatewayUpdatePreflightCheck] = [],
        approvedTargets: [GatewayUpdateApprovedTarget] = []
    ) {
        self.canUpdate = canUpdate
        self.status = status
        self.hostingProvider = hostingProvider
        self.gatewayUrl = gatewayUrl
        self.managedFlyAppName = managedFlyAppName
        self.message = message
        self.requiredChecks = requiredChecks
        self.preflightChecks = preflightChecks
        self.approvedTargets = approvedTargets
    }

    private enum CodingKeys: String, CodingKey {
        case canUpdate
        case status
        case hostingProvider
        case gatewayUrl
        case managedFlyAppName
        case message
        case requiredChecks
        case preflightChecks
        case approvedTargets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canUpdate = try container.decode(Bool.self, forKey: .canUpdate)
        status = try container.decode(GatewayUpdateReadinessStatus.self, forKey: .status)
        hostingProvider = try container.decode(String.self, forKey: .hostingProvider)
        gatewayUrl = try container.decodeIfPresent(String.self, forKey: .gatewayUrl)
        managedFlyAppName = try container.decodeIfPresent(String.self, forKey: .managedFlyAppName)
        message = try container.decode(String.self, forKey: .message)
        requiredChecks = try container.decodeIfPresent([String].self, forKey: .requiredChecks) ?? []
        preflightChecks = try container.decodeIfPresent([GatewayUpdatePreflightCheck].self, forKey: .preflightChecks) ?? []
        approvedTargets = try container.decodeIfPresent([GatewayUpdateApprovedTarget].self, forKey: .approvedTargets) ?? []
    }
}

// MARK: - Gateway Config

/// A single gateway configuration. The app supports multiple gateways
/// (cloud, local Mac, manual) with one active at a time.
///
/// Two axes live on this struct:
/// - `provider: GatewayProvider` — *where* the gateway is deployed
///   (Fly cloud / local Mac / manual URL). Drives the "Add Gateway"
///   chooser, deploy overlay, and legacy-migration labeling.
/// - `transport: GatewayTransport?` — *how* this device reaches it
///   (Bonjour LAN / Tailscale / SSH tunnel / manual URL). Added for
///   #317 (Remote Mac gateway access epic). Optional for back-compat
///   with pre-#317 persisted configs, which decode with `transport == nil`
///   and resolve via `GatewayTransport.inferred(fromURL:provider:)` at
///   read time — read `effectiveTransport`.
struct GatewayConfig: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var url: String
    var token: String
    var provider: GatewayProvider
    var displayName: String
    var macAddress: String?
    var isActive: Bool

    // MARK: - #317 transport fields (optional, additive)

    /// How this device reaches the gateway. `nil` on configs persisted
    /// before #317 — callers should read `effectiveTransport`, which
    /// infers from the URL when this is `nil`. New configs written by the
    /// Mac Tailscale toggle (PR 2) and the iOS remote-gateway setup flow
    /// (PR 3) always set this explicitly.
    var transport: GatewayTransport?

    /// Tailscale-specific URL when `transport == .tailscale`. Usually the
    /// Mac's `https://<machine>.ts.net` endpoint from
    /// `openclaw qr --remote`. `nil` for other transports. When set, takes
    /// precedence over `url` for the tailnet WebSocket handshake;
    /// `url` may remain populated with a LAN / loopback fallback for
    /// back-compat with callers that haven't been routed yet.
    var tailscaleURL: String?

    /// SSH local-forward port hint when `transport == .ssh`. Matches the
    /// `-L <port>:127.0.0.1:<port>` port the user runs on their Mac.
    /// `nil` for other transports; when nil the connection router assumes
    /// the gateway's default (`18789`). No SSH tunnel lifecycle is managed
    /// by the app per locked decision 1 — this is purely a routing hint.
    var sshLocalPort: Int?

    // MARK: - #300a bootstrap-credential field (optional, additive)

    /// Whether `token` is a bootstrap credential (upstream pair-bootstrap
    /// flow) rather than a long-lived shared gateway token. Source of truth
    /// for the connect-time auth router in `GatewayClient` /
    /// `MacGatewayClient`: when `true`, `token` is passed as
    /// `bootstrapToken:` to OpenClawKit's `GatewayNodeSession.connect(...)`,
    /// which serializes it as `auth.bootstrapToken` on the wire and triggers
    /// the upstream device-token handshake (`GatewayChannel.swift:430-440,
    /// 545-607`). When `false` / `nil`, `token` is passed as `token:` →
    /// `auth.token` (current behavior).
    ///
    /// Optional for back-compat with pre-#300a persisted configs (same
    /// pattern as #317's `transport`/`tailscaleURL`/`sshLocalPort`); a `nil`
    /// value is treated as `false` semantically. Until #300b lands, every
    /// code path that produces a `GatewayConfig` sets this to `nil`, so no
    /// runtime behavior change ships in #300a.
    var isBootstrap: Bool?

    /// The host portion of the gateway URL for display purposes
    /// (e.g. "remclaw-abc12345.fly.dev").
    ///
    /// Routed through `GatewayHostDisplay.sanitized` so an internal pool app
    /// name (`remclaw-pool-<id>.fly.dev`) never surfaces to users.
    var hostDisplay: String? {
        GatewayHostDisplay.sanitized(URL(string: url)?.host)
    }

    /// Transport resolved for connection routing. Returns the stored
    /// `transport` when set; otherwise falls back to
    /// `GatewayTransport.inferred(fromURL:provider:)` for back-compat with
    /// pre-#317 configs. Never `nil`.
    var effectiveTransport: GatewayTransport {
        transport ?? GatewayTransport.inferred(fromURL: url, provider: provider)
    }

    init(
        id: String = UUID().uuidString,
        url: String,
        token: String,
        provider: GatewayProvider = .fly,
        displayName: String,
        macAddress: String? = nil,
        isActive: Bool = false,
        transport: GatewayTransport? = nil,
        tailscaleURL: String? = nil,
        sshLocalPort: Int? = nil,
        isBootstrap: Bool? = nil
    ) {
        self.id = id
        self.url = url
        self.token = token
        self.provider = provider
        self.displayName = displayName
        self.macAddress = macAddress
        self.isActive = isActive
        self.transport = transport
        self.tailscaleURL = tailscaleURL
        self.sshLocalPort = sshLocalPort
        self.isBootstrap = isBootstrap
    }
}
