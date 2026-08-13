import Foundation
import Testing
@testable import RemClaw

/// Tests for the `isBootstrap` plumbing added in #300a.
///
/// #300a is a behavior-neutral data-path change: a new optional field on
/// `GatewaySetupCode` and `GatewayConfig` (and the matching back-compat
/// optional on `GatewayConfigStore.StoredGatewayMeta`) plus an
/// `isBootstrap: Bool = false` parameter on the gateway clients' connect
/// methods. Until #300b lands, every emitter and decoder leaves the field
/// `false`/`nil` so no existing call site observes a behavior change.
///
/// These tests lock down:
///   1. JSON round-trip for `GatewayConfig.isBootstrap == nil`
///      (pre-#300a persisted configs decode unchanged).
///   2. JSON round-trip for `GatewayConfig.isBootstrap == true`
///      (the field survives a write/read cycle once #300b sets it).
///   3. Legacy stored-meta JSON without the `isBootstrap` key decodes
///      cleanly with `isBootstrap == nil` — same back-compat shape that
///      #317 used for the `transport` family.
///   4. `GatewaySetupCode` Codable defaults `isBootstrap` to `false` when
///      the field is absent in JSON (matches the pre-#300a wire format).
struct GatewayIsBootstrapPlumbingTests {

    // MARK: - GatewayConfig round-trips

    @Test func roundTripWithNilIsBootstrapPreservesAbsence() throws {
        // Simulates a pre-#300a persisted config re-read after the upgrade:
        // JSON has no "isBootstrap" field, decodes to nil, encoding again
        // must not invent a value.
        let original = GatewayConfig(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            provider: .fly,
            displayName: "Cloud"
        )
        #expect(original.isBootstrap == nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: data)
        #expect(decoded.isBootstrap == nil)
    }

    @Test func roundTripWithExplicitIsBootstrapTrue() throws {
        let original = GatewayConfig(
            url: "https://remclaw-abc.fly.dev",
            token: "boot_xyz",
            provider: .fly,
            displayName: "Cloud (bootstrap)",
            isBootstrap: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: data)
        #expect(decoded.isBootstrap == true)
        #expect(decoded.token == "boot_xyz")
    }

    @Test func roundTripWithExplicitIsBootstrapFalse() throws {
        // Covers the case where #300b explicitly sets `isBootstrap: false`
        // for a long-lived shared token (vs leaving it nil). Both should
        // route the token to OpenClawKit's `token:` slot at connect time.
        let original = GatewayConfig(
            url: "https://remclaw-abc.fly.dev",
            token: "long_lived_t",
            provider: .fly,
            displayName: "Cloud",
            isBootstrap: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: data)
        #expect(decoded.isBootstrap == false)
    }

    @Test func decodesLegacyJSONWithoutIsBootstrapField() throws {
        // Exact JSON shape that pre-#300a `GatewayConfigStore.StoredGatewayMeta`
        // wrote (also covers the #317 transport fields being absent — those
        // remain back-compat-safe). Adding `isBootstrap?` to `GatewayConfig`
        // must NOT break decoding of this payload.
        let legacyJSON = """
        {
            "id": "abc-123",
            "url": "https://remclaw-abc.fly.dev",
            "token": "legacy_token",
            "provider": "fly",
            "displayName": "Cloud Gateway",
            "isActive": true
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: data)
        #expect(decoded.isBootstrap == nil)
        #expect(decoded.token == "legacy_token")
    }

    @Test func decodesLegacyStoredMetaArrayWithoutIsBootstrapField() throws {
        // `GatewayConfigStore.StoredGatewayMeta` is private; mirror its
        // post-#300a shape here (matching the in-source decl) and prove a
        // legacy persisted-meta array — written before #300a — decodes
        // cleanly with `isBootstrap == nil`. Same pattern the #317 tests
        // use for the transport family.
        let legacyMetaArray = """
        [
            {
                "id": "abc-123",
                "url": "http://MacBook.local:18789",
                "provider": "local",
                "displayName": "My Mac",
                "isActive": true
            },
            {
                "id": "def-456",
                "url": "https://remclaw-xyz.fly.dev",
                "provider": "fly",
                "displayName": "Cloud",
                "isActive": false
            }
        ]
        """
        struct MetaShape: Codable {
            let id: String
            var url: String
            var provider: GatewayProvider
            var displayName: String
            var macAddress: String?
            var isActive: Bool
            var transport: GatewayTransport?
            var tailscaleURL: String?
            var sshLocalPort: Int?
            var isBootstrap: Bool?
        }
        let data = try #require(legacyMetaArray.data(using: .utf8))
        let metas = try JSONDecoder().decode([MetaShape].self, from: data)
        #expect(metas.count == 2)
        #expect(metas.allSatisfy { $0.isBootstrap == nil })
    }

    // MARK: - GatewaySetupCode

    @Test func setupCodeDefaultsIsBootstrapToFalse() {
        // Memberwise init's default + Codable's `decodeIfPresent ?? false`
        // both produce `false` when caller / payload omits the field.
        let code = GatewaySetupCode(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            tls: nil, displayName: nil, stableID: nil
        )
        #expect(code.isBootstrap == false)
    }

    @Test func setupCodeRoundTripWithIsBootstrapTrue() throws {
        let code = GatewaySetupCode(
            url: "https://remclaw-abc.fly.dev",
            token: "boot_xyz",
            tls: nil,
            displayName: nil,
            stableID: nil,
            isBootstrap: true
        )
        let decoded = try #require(GatewaySetupCode.decode(code.encode()))
        #expect(decoded.isBootstrap == true)
        #expect(decoded == code)
    }

    @Test func setupCodeDecodeDefaultsAbsentIsBootstrapToFalse() {
        // Pre-#300a wire shape — no `isBootstrap` key. Must decode with
        // `false`, not throw or default to anything else.
        let payload = #"{"url":"https://gw.example.com","token":"t"}"#
            .data(using: .utf8)!
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = GatewaySetupCode.decode(encoded)
        #expect(decoded?.isBootstrap == false)
    }

    @Test func setupCodeUpstreamFormatProducesIsBootstrapTrue() {
        // Inverted from #300a's locking test: the upstream-format
        // `{ url, bootstrapToken }` decoder branch now flips
        // `isBootstrap: true` (#300b). That's what routes the token
        // through `GatewayClient.connect(bootstrapToken:)` at connect
        // time, unlocking OpenClawKit's pair-bootstrap handshake. The
        // `bootstrapToken` value still maps onto the `token` slot for
        // wire compatibility with the Rem-format consumers.
        let payload = #"{"url":"https://gw.example.com","bootstrapToken":"boot_xyz"}"#
            .data(using: .utf8)!
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = GatewaySetupCode.decode(encoded)
        #expect(decoded?.isBootstrap == true)
        #expect(decoded?.token == "boot_xyz")
    }

    @Test func setupCodeLegacyRemFormatProducesIsBootstrapFalse() {
        // Counterpart to the upstream-format test above: the legacy Rem
        // wire shape (`{ url, token, ... }`) — emitted by the cloud
        // backend (`backend/src/services/setup-code.ts`) and by every
        // setup code minted before #300b — must continue to decode with
        // `isBootstrap == false` so the long-lived shared-token auth
        // path stays intact. Regression guard against a future change
        // accidentally flipping the Rem-format branch too.
        let payload = #"{"url":"https://gw.example.com","token":"long_lived_t","tls":true,"displayName":"Cloud Gateway","stableID":"remclaw-abc"}"#
            .data(using: .utf8)!
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = GatewaySetupCode.decode(encoded)
        #expect(decoded?.isBootstrap == false)
        #expect(decoded?.token == "long_lived_t")
        #expect(decoded?.displayName == "Cloud Gateway")
    }

    @Test func toGatewayConfigCarriesIsBootstrapTrueAsTrue() {
        let code = GatewaySetupCode(
            url: "https://remclaw-abc.fly.dev",
            token: "boot",
            tls: nil, displayName: nil, stableID: nil,
            isBootstrap: true
        )
        let config = code.toGatewayConfig()
        #expect(config.isBootstrap == true)
    }

    @Test func toGatewayConfigLeavesIsBootstrapNilWhenSetupCodeIsFalse() {
        // Pre-#300b every `GatewaySetupCode` has `isBootstrap == false`,
        // and the resulting `GatewayConfig` must persist with
        // `isBootstrap == nil` (back-compat with the StoredGatewayMeta
        // shape that pre-#300a configs use).
        let code = GatewaySetupCode(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            tls: nil, displayName: nil, stableID: nil
        )
        let config = code.toGatewayConfig()
        #expect(config.isBootstrap == nil)
    }
}
