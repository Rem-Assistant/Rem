import Foundation

/// Self-contained connection details for a gateway, encoded as a single
/// base64url-safe string that can be copy-pasted or shared between devices.
///
/// Format: base64url(JSON{url, token, tls?, displayName?, stableID?})
///
/// One paste replaces our previous "URL field + token field" manual entry.
/// Emitted by the backend after cloud deploy and by the local Mac gateway
/// on startup; consumed by iOS + Mac "Setup code" entry flow.
///
/// **Security**: the token is base64-encoded, not encrypted. Treat the setup
/// code with the same confidentiality as the token itself — anyone who holds
/// the string can connect to the gateway.
struct GatewaySetupCode: Codable, Sendable, Equatable {
    /// WebSocket / HTTPS URL of the gateway, including scheme.
    let url: String

    /// Auth token used on the Authorization header / WebSocket handshake.
    ///
    /// When `isBootstrap == true` this carries a short-lived **bootstrap**
    /// credential that the gateway exchanges for a persistent device-auth
    /// token via OpenClawKit's pair-bootstrap handshake. When false (the
    /// default) it's a long-lived shared gateway token.
    let token: String

    /// Optional TLS hint. When nil, inferred from `url` scheme.
    let tls: Bool?

    /// Optional human-readable label (e.g. "Cloud Gateway", "MacBook Pro").
    let displayName: String?

    /// Optional stable identifier used for preferred-gateway tracking
    /// across discovery sessions (e.g. the Fly app name or machine ID).
    let stableID: String?

    /// Whether `token` is a bootstrap credential (upstream pair-bootstrap
    /// flow) rather than a long-lived shared gateway token.
    ///
    /// Plumbed through #300a as the structured field callers route on, and
    /// flipped to `true` in #300b for the upstream `{ url, bootstrapToken }`
    /// decoder branch (Mac now emits this format via `openclaw qr --json`).
    /// That's what unlocks OpenClawKit's transparent bootstrap → device-token
    /// handshake at connect time (`GatewayChannel.swift:430-440, 545-607`).
    /// Rem-format payloads (`{ url, token }`) — emitted by the cloud backend
    /// — continue to produce `false`, preserving the long-lived shared-token
    /// auth path.
    ///
    /// Defaulted in the memberwise init below and treated as `false` when
    /// absent in JSON (Codable extension), so older payloads decode cleanly.
    let isBootstrap: Bool

    init(
        url: String,
        token: String,
        tls: Bool?,
        displayName: String?,
        stableID: String?,
        isBootstrap: Bool = false
    ) {
        self.url = url
        self.token = token
        self.tls = tls
        self.displayName = displayName
        self.stableID = stableID
        self.isBootstrap = isBootstrap
    }

    // Custom Codable so payloads without `isBootstrap` decode as `false`,
    // matching the pre-#300a wire format. Encoding always emits the field.
    private enum CodingKeys: String, CodingKey {
        case url, token, tls, displayName, stableID, isBootstrap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decode(String.self, forKey: .url)
        self.token = try c.decode(String.self, forKey: .token)
        self.tls = try c.decodeIfPresent(Bool.self, forKey: .tls)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.stableID = try c.decodeIfPresent(String.self, forKey: .stableID)
        self.isBootstrap = try c.decodeIfPresent(Bool.self, forKey: .isBootstrap) ?? false
    }
}

extension GatewaySetupCode {
    /// Encode to a base64url string (URL-safe, no padding) so the code can
    /// live unescaped in URLs, clipboards, and QR payloads.
    ///
    /// `try!` is safe here: `GatewaySetupCode` contains only `String` and
    /// `Bool?` fields, which JSONEncoder cannot fail to encode.
    func encode() -> String {
        let data = try! JSONEncoder().encode(self)
        return data.base64URLEncodedString()
    }

    /// Decode a base64url-encoded setup code. Returns nil on invalid base64,
    /// invalid JSON, or a URL that doesn't parse as http(s) / ws(s).
    ///
    /// Accepts two payload shapes:
    /// 1. **Rem format** — `{ url, token, tls?, displayName?, stableID? }`.
    ///    Emitted by our Mac setup sheet (#279) and by the cloud backend
    ///    (`backend/src/services/setup-code.ts`). `token` is the gateway's
    ///    long-lived shared auth token.
    /// 2. **Upstream format** — `{ url, bootstrapToken }`. Emitted by
    ///    `openclaw qr --json`. `bootstrapToken` is a short-lived handoff
    ///    credential; OpenClawKit's pair-bootstrap flow exchanges it for
    ///    a persistent device-auth token server-side.
    ///
    /// Both get mapped into the same struct so callers don't need to
    /// branch. If we migrate Mac to emit upstream format (#280), iOS
    /// decodes it the same way. If the bootstrap-vs-persistent semantic
    /// difference ever needs to surface to callers (e.g. for scope
    /// negotiation), add a flag at that point.
    static func decode(_ code: String) -> GatewaySetupCode? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64URLEncoded: trimmed)
        else { return nil }

        // Try the Rem format first. It's strict on unknown fields being
        // absent (via `GatewaySetupCode`'s declared properties), but
        // JSONDecoder with default config ignores extras — so a payload
        // with BOTH `token` and `bootstrapToken` still decodes via this
        // path. That's fine; we want any payload with a `token` to use it.
        if let decoded = try? JSONDecoder().decode(GatewaySetupCode.self, from: data),
           !decoded.token.isEmpty,
           let parsed = URL(string: decoded.url),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss" {
            return decoded
        }

        // Fall back to the upstream format: `{ url, bootstrapToken }`. The
        // `token` field above would have been absent/empty, so we map
        // `bootstrapToken` → `token` here.
        struct UpstreamPayload: Decodable {
            let url: String
            let bootstrapToken: String
        }
        guard let upstream = try? JSONDecoder().decode(UpstreamPayload.self, from: data),
              let parsed = URL(string: upstream.url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss",
              !upstream.bootstrapToken.isEmpty
        else { return nil }

        // #300b: upstream's `{ url, bootstrapToken }` payload IS a bootstrap
        // credential — short-lived, intended to be exchanged server-side via
        // OpenClawKit's pair-bootstrap handshake (`GatewayChannel.swift:430-440,
        // 545-607`) for a persistent device-auth token. Flipping `isBootstrap`
        // to `true` on this branch is what routes the token through
        // `GatewayClient.connect(bootstrapToken:)` instead of `token:`,
        // unlocking the transparent handshake. The Rem-format branch above
        // continues to produce `isBootstrap: false` for long-lived shared
        // gateway tokens — see `setupCodeLegacyRemFormatProducesIsBootstrapFalse`
        // in `GatewayIsBootstrapPlumbingTests`.
        return GatewaySetupCode(
            url: upstream.url,
            token: upstream.bootstrapToken,
            tls: nil,
            displayName: nil,
            stableID: nil,
            isBootstrap: true
        )
    }

    /// True TLS value — honors explicit `tls` if set, otherwise infers from URL scheme.
    var usesTLS: Bool {
        if let tls { return tls }
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return true }
        return scheme == "https" || scheme == "wss"
    }

    /// Map to an active `GatewayConfig` ready to persist. Provider is inferred
    /// from the host (fly.dev → .fly, else → .manual).
    ///
    /// `isBootstrap` carries through so the connect-time auth router
    /// (`GatewayConfig.isBootstrap?` → `GatewayClient.connect(bootstrapToken:)`)
    /// can pick the right wire frame. Pre-#300b every code path produces
    /// `false`, so behavior is unchanged.
    func toGatewayConfig(id: String = UUID().uuidString) -> GatewayConfig {
        let host = URL(string: url)?.host ?? ""
        let provider: GatewayProvider = host.hasSuffix(".fly.dev") ? .fly : .manual
        return GatewayConfig(
            id: id,
            url: url,
            token: token,
            provider: provider,
            displayName: displayName ?? provider.displayName,
            macAddress: nil,
            isActive: true,
            isBootstrap: isBootstrap ? true : nil
        )
    }
}

// MARK: - Base64URL helpers

private extension Data {
    /// Base64URL encoding: `+` → `-`, `/` → `_`, strips `=` padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64URL decoding with padding restored.
    init?(base64URLEncoded input: String) {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}
