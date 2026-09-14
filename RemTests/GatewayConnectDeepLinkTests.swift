import Testing
import Foundation
@testable import Rem

/// Regression coverage for #1342 PART 2 — validation of a `remclaw://connect` gateway repoint before
/// any confirmation is even offered. `GatewayConnectDeepLink.request(from:)` returning `nil` means
/// "ignore, never repoint"; returning a `Request` means "well-formed enough to ask the user about"
/// (the confirmation itself lives in `RemApp` and is the second gate).
///
/// RED proof: relax the validator to `return Request(gatewayURL: rawGatewayURL, …)` without the
/// `https`/host checks (the pre-fix behavior, which read `url`+`token` and configured immediately) —
/// `rejectsNonHttpsGatewayScheme` and `rejectsHostlessOrUnparsableGatewayURL` fail. GREEN: with the
/// fail-closed validation, all pass.
@Suite("Gateway connect deep-link validation (#1342)")
struct GatewayConnectDeepLinkTests {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("test URL did not parse: \(string)")
        }
        return url
    }

    @Test func validHttpsRepointParsesWithHost() throws {
        let request = try #require(GatewayConnectDeepLink.request(
            from: url("remclaw://connect?url=https://remclaw-abc123.fly.dev&token=secret")))
        #expect(request.gatewayURL == "https://remclaw-abc123.fly.dev")
        #expect(request.gatewayToken == "secret")
        #expect(request.gatewayHost == "remclaw-abc123.fly.dev")
    }

    /// The gateway is always TLS, so a non-`https` target is hostile and dropped before any prompt —
    /// including the `wss://evil.example` and `javascript:` shapes from the probe.
    @Test func rejectsNonHttpsGatewayScheme() {
        for raw in [
            "remclaw://connect?url=http://evil.example&token=x",
            "remclaw://connect?url=wss://evil.example&token=x",
            "remclaw://connect?url=javascript:alert(1)&token=x",
            "remclaw://connect?url=ftp://evil.example/x&token=x",
        ] {
            #expect(GatewayConnectDeepLink.request(from: url(raw)) == nil, "\(raw) must be rejected")
        }
    }

    @Test func rejectsHostlessOrUnparsableGatewayURL() {
        #expect(GatewayConnectDeepLink.request(
            from: url("remclaw://connect?url=https:///no-host&token=x")) == nil)
        #expect(GatewayConnectDeepLink.request(
            from: url("remclaw://connect?url=not-a-url&token=x")) == nil)
    }

    @Test func rejectsMissingOrEmptyUrlOrToken() {
        #expect(GatewayConnectDeepLink.request(
            from: url("remclaw://connect?token=x")) == nil)
        #expect(GatewayConnectDeepLink.request(
            from: url("remclaw://connect?url=https://x.fly.dev")) == nil)
        #expect(GatewayConnectDeepLink.request(
            from: url("remclaw://connect?url=https://x.fly.dev&token=")) == nil)
    }

    @Test func rejectsWrongOuterSchemeOrHost() {
        #expect(GatewayConnectDeepLink.request(
            from: url("https://connect?url=https://x.fly.dev&token=x")) == nil)
        #expect(GatewayConnectDeepLink.request(
            from: url("remclaw://voice?url=https://x.fly.dev&token=x")) == nil)
    }

    /// Outer scheme/host matching is case-insensitive, mirroring the other deep-link parsers.
    @Test func outerSchemeAndHostAreCaseInsensitive() throws {
        let request = try #require(GatewayConnectDeepLink.request(
            from: url("REMCLAW://CONNECT?url=https://gw.fly.dev&token=t")))
        #expect(request.gatewayHost == "gw.fly.dev")
    }
}
