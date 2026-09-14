import Foundation

/// Parses and **validates** a `remclaw://connect?url=…&token=…` gateway-repoint deep link.
///
/// Repointing the gateway hands a new backend the device's node-command allowlist and the chat
/// transport — "conversation content out and node commands in" — so an untrusted deep link must not
/// do it silently. The previous handler (`RemApp.handleDeepLink`) read both query items and
/// called `gateway.configure(...)` immediately: no confirmation, no scheme check, no host allowlist
/// (#1342 PART 2, and the task-#44 defense-in-depth even if the renderer allowlist in
/// `AssistantMarkdownLinkPolicy` were perfect).
///
/// This type owns the parse + **validate** half (pure, unit-tested). The **confirm** half lives at
/// the call site, which must obtain explicit user consent — showing `Request.gatewayHost` — before
/// invoking `configure`.
///
/// Validation fails **closed**:
/// - outer link is `remclaw://connect`
/// - a `url` query item that parses as `https://` with a non-empty host. The gateway is always TLS
///   (`RemGatewayClient.webSocketURL` derives `wss` from an `https` origin; `useTLS` keys off
///   `scheme == "https"`), so `http`, `wss`, `javascript:`, scheme-less, or host-less payloads are
///   rejected outright rather than surfaced for confirmation.
/// - a non-empty `token` query item.
///
/// Mirrors the existing deep-link parsers (`VoiceSessionDeepLink`, `LatestBriefDeepLink` in
/// `VoiceSessionControl.swift`) — same `scheme`/`host` constants and `static func` shape.
enum GatewayConnectDeepLink {
    static let scheme = "remclaw"
    static let host = "connect"

    /// Only TLS gateway origins are accepted. A repoint target that is not `https` is treated as
    /// hostile and dropped before the user is ever asked.
    static let allowedGatewaySchemes: Set<String> = ["https"]

    /// A validated repoint request. Constructing one asserts nothing about the token's authenticity —
    /// only that the payload is well-formed enough to be worth asking the user about.
    struct Request: Equatable {
        let gatewayURL: String
        let gatewayToken: String
        /// Host of the gateway URL, surfaced verbatim in the confirmation prompt so the user sees
        /// exactly where their device would be repointed.
        let gatewayHost: String
    }

    /// Returns a validated `Request`, or `nil` if the link is not a well-formed, `https`, hosted,
    /// tokened `remclaw://connect` repoint. `nil` means "ignore silently" — never "repoint".
    static func request(from url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host else { return nil }

        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawGatewayURL = items.first(where: { $0.name == "url" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return nil }

        guard let parsed = URL(string: rawGatewayURL),
              let gatewayScheme = parsed.scheme?.lowercased(),
              allowedGatewaySchemes.contains(gatewayScheme),
              let gatewayHost = parsed.host,
              !gatewayHost.isEmpty else { return nil }

        return Request(gatewayURL: rawGatewayURL, gatewayToken: token, gatewayHost: gatewayHost)
    }
}
