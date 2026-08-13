import Foundation
import Testing
@testable import RemClaw

struct GatewaySetupCodeTests {

    @Test func roundTripAllFields() throws {
        let code = GatewaySetupCode(
            url: "https://remclaw-abc123.fly.dev",
            token: "tok_abc",
            tls: true,
            displayName: "Cloud Gateway",
            stableID: "remclaw-abc123"
        )
        let encoded = code.encode()
        let decoded = try #require(GatewaySetupCode.decode(encoded))
        #expect(decoded == code)
    }

    @Test func roundTripMinimalFields() throws {
        let code = GatewaySetupCode(
            url: "https://gw.example.com",
            token: "t",
            tls: nil,
            displayName: nil,
            stableID: nil
        )
        let decoded = try #require(GatewaySetupCode.decode(code.encode()))
        #expect(decoded == code)
    }

    @Test func base64URLSafeNoPadding() {
        let code = GatewaySetupCode(
            url: "https://remclaw-00000000.fly.dev",
            token: "secret",
            tls: nil, displayName: nil, stableID: nil
        )
        let encoded = code.encode()
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test func decodeRejectsGarbage() {
        #expect(GatewaySetupCode.decode("not a setup code") == nil)
        #expect(GatewaySetupCode.decode("") == nil)
        #expect(GatewaySetupCode.decode("   ") == nil)
    }

    @Test func decodeRejectsNonURLScheme() {
        // base64url of {"url":"ftp://x.com","token":"t"}
        let payload = #"{"url":"ftp://x.com","token":"t"}"#.data(using: .utf8)!
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(GatewaySetupCode.decode(encoded) == nil)
    }

    @Test func decodeRejectsMissingRequiredFields() {
        let missingToken = #"{"url":"https://x.com"}"#.data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(GatewaySetupCode.decode(missingToken) == nil)

        let missingURL = #"{"token":"t"}"#.data(using: .utf8)!
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(GatewaySetupCode.decode(missingURL) == nil)
    }

    @Test func decodeAcceptsWSScheme() {
        let code = GatewaySetupCode(
            url: "wss://gw.example.com",
            token: "t",
            tls: nil, displayName: nil, stableID: nil
        )
        #expect(GatewaySetupCode.decode(code.encode()) != nil)
    }

    @Test func decodeTrimsWhitespace() {
        let code = GatewaySetupCode(
            url: "https://gw.example.com",
            token: "t",
            tls: nil, displayName: nil, stableID: nil
        )
        let padded = "  \n\(code.encode())\n  "
        #expect(GatewaySetupCode.decode(padded) != nil)
    }

    @Test func usesTLSInfersFromScheme() {
        #expect(GatewaySetupCode(url: "https://x", token: "t", tls: nil, displayName: nil, stableID: nil).usesTLS)
        #expect(GatewaySetupCode(url: "wss://x", token: "t", tls: nil, displayName: nil, stableID: nil).usesTLS)
        #expect(!GatewaySetupCode(url: "http://x", token: "t", tls: nil, displayName: nil, stableID: nil).usesTLS)
        #expect(!GatewaySetupCode(url: "ws://x", token: "t", tls: nil, displayName: nil, stableID: nil).usesTLS)
    }

    @Test func usesTLSHonorsExplicitFlag() {
        // Explicit tls=false even when URL is https — honors the flag.
        let c = GatewaySetupCode(url: "https://x", token: "t", tls: false, displayName: nil, stableID: nil)
        #expect(!c.usesTLS)
    }

    @Test func toGatewayConfigInfersFlyProvider() {
        let flyCode = GatewaySetupCode(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            tls: nil, displayName: nil, stableID: nil
        )
        #expect(flyCode.toGatewayConfig().provider == .fly)
    }

    @Test func toGatewayConfigInfersManualProvider() {
        let manualCode = GatewaySetupCode(
            url: "https://gw.example.com",
            token: "t",
            tls: nil, displayName: nil, stableID: nil
        )
        #expect(manualCode.toGatewayConfig().provider == .manual)
    }

    @Test func toGatewayConfigUsesProvidedDisplayName() {
        let code = GatewaySetupCode(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            tls: nil,
            displayName: "My Test Gateway",
            stableID: nil
        )
        #expect(code.toGatewayConfig().displayName == "My Test Gateway")
    }

    @Test func toGatewayConfigFallsBackToProviderDisplayName() {
        let code = GatewaySetupCode(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            tls: nil, displayName: nil, stableID: nil
        )
        #expect(code.toGatewayConfig().displayName == "Cloud machine")
    }
}
