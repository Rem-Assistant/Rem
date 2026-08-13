import Foundation
import Testing
@testable import RemClaw

/// Tests for `GatewayTransport` — the transport / remote-access enum added
/// in PR 1 of #317 (Remote Mac gateway access epic).
///
/// PR 1 is a pure data-model change: new enum, new optional fields on
/// `GatewayConfig`, no behavior. These tests lock down:
///
/// 1. Raw-value stability (Codable wire format — changing a rawValue would
///    silently invalidate every persisted config on upgrade).
/// 2. Host-based inference rules used by `effectiveTransport` for pre-#317
///    configs that decode with `transport == nil`.
/// 3. Deployment-aware inference: a loopback URL on a `.local` deployment
///    is Bonjour-equivalent, not SSH.
/// 4. JSON round-trip with `transport == nil` (back-compat) and explicit
///    `.tailscale` / `.ssh` values.
struct GatewayTransportTests {

    // MARK: - Raw value stability

    @Test func rawValuesArePersistenceContract() {
        // These strings live in UserDefaults JSON once users upgrade past
        // #317. Changing any of them silently wipes transport on next read.
        #expect(GatewayTransport.bonjour.rawValue == "bonjour")
        #expect(GatewayTransport.tailscale.rawValue == "tailscale")
        #expect(GatewayTransport.ssh.rawValue == "ssh")
        #expect(GatewayTransport.manual.rawValue == "manual")
    }

    @Test func allCasesComplete() {
        #expect(GatewayTransport.allCases.count == 4)
        #expect(Set(GatewayTransport.allCases) == [.bonjour, .tailscale, .ssh, .manual])
    }

    // MARK: - Provider-aware inference (pre-#317 back-compat)

    @Test func inferTailscaleFromMagicDNSHost() {
        #expect(GatewayTransport.inferred(fromURL: "https://my-mac.tail-scales.ts.net",
                                          provider: .local)
                == .tailscale)
        #expect(GatewayTransport.inferred(fromURL: "wss://my-mac.tail-scales.ts.net:18789",
                                          provider: .manual)
                == .tailscale)
    }

    @Test func inferBonjourFromDotLocalHost() {
        #expect(GatewayTransport.inferred(fromURL: "http://MacBook-Pro.local:18789",
                                          provider: .local)
                == .bonjour)
        #expect(GatewayTransport.inferred(fromURL: "ws://rem-mac.local",
                                          provider: .manual)
                == .bonjour)
    }

    @Test func inferSSHFromLoopbackHost() {
        // URL-only inference has no way to know the loopback belongs to a
        // local deployment vs a running SSH tunnel; it defaults to `.ssh`.
        // Callers that know the deployment use the provider-aware variant.
        #expect(GatewayTransport.inferred(fromURL: "ws://127.0.0.1:18789",
                                          provider: .manual) == .ssh)
        #expect(GatewayTransport.inferred(fromURL: "http://localhost:18789",
                                          provider: .fly) == .ssh)
    }

    @Test func inferManualForFlyAndOtherHosts() {
        #expect(GatewayTransport.inferred(fromURL: "https://remclaw-abc123.fly.dev",
                                          provider: .fly)
                == .manual)
        #expect(GatewayTransport.inferred(fromURL: "https://gateway.example.com",
                                          provider: .manual)
                == .manual)
    }

    @Test func inferManualForGarbageURL() {
        #expect(GatewayTransport.inferred(fromURL: "", provider: .local) == .manual)
        #expect(GatewayTransport.inferred(fromURL: "not a url", provider: .manual) == .manual)
    }

    // MARK: - Deployment-aware inference

    @Test func loopbackOnLocalDeploymentIsBonjour() {
        // The "Mac hosting Rem also hosts its gateway" case — same machine,
        // no remote transport. Must NOT be classified as SSH.
        #expect(GatewayTransport.inferred(fromURL: "ws://127.0.0.1:18789",
                                          provider: .local) == .bonjour)
        #expect(GatewayTransport.inferred(fromURL: "http://localhost:18789",
                                          provider: .local) == .bonjour)
    }

    @Test func loopbackOnNonLocalDeploymentStaysSSH() {
        // If a loopback URL shows up with a `.fly` or `.manual` provider
        // the only explanation is an SSH tunnel.
        #expect(GatewayTransport.inferred(fromURL: "ws://127.0.0.1:18789",
                                          provider: .fly) == .ssh)
        #expect(GatewayTransport.inferred(fromURL: "ws://127.0.0.1:18789",
                                          provider: .manual) == .ssh)
    }

    @Test func flyHostAlwaysManualRegardlessOfProvider() {
        // Provider-aware variant only special-cases loopback+.local —
        // everything else defers to URL-only rules.
        #expect(GatewayTransport.inferred(fromURL: "https://remclaw-abc123.fly.dev",
                                          provider: .fly) == .manual)
        #expect(GatewayTransport.inferred(fromURL: "https://mac.ts.net",
                                          provider: .local) == .tailscale)
    }

    // MARK: - GatewayConfig effectiveTransport

    @Test func effectiveTransportPrefersStoredValue() {
        // Explicit transport wins even if URL would infer differently.
        let config = GatewayConfig(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            provider: .fly,
            displayName: "Cloud",
            transport: .tailscale
        )
        #expect(config.effectiveTransport == .tailscale)
    }

    @Test func effectiveTransportFallsBackToInferenceWhenNil() {
        // Pre-#317 config: no transport stored → infer from URL + provider.
        let bonjourConfig = GatewayConfig(
            url: "http://MacBook-Pro.local:18789",
            token: "t",
            provider: .local,
            displayName: "Local"
        )
        #expect(bonjourConfig.transport == nil)
        #expect(bonjourConfig.effectiveTransport == .bonjour)

        let flyConfig = GatewayConfig(
            url: "https://remclaw-abc.fly.dev",
            token: "t",
            provider: .fly,
            displayName: "Cloud"
        )
        #expect(flyConfig.transport == nil)
        #expect(flyConfig.effectiveTransport == .manual)
    }

    // MARK: - Codable round-trip

    @Test func roundTripWithNilTransportPreservesAbsence() throws {
        // Simulates a pre-#317 persisted config re-read after the upgrade:
        // JSON has no "transport" field, decodes to nil, effectiveTransport
        // infers. Encoding again must not invent a transport value.
        let original = GatewayConfig(
            url: "http://rem.local",
            token: "t",
            provider: .local,
            displayName: "Local"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: data)
        #expect(decoded.transport == nil)
        #expect(decoded.tailscaleURL == nil)
        #expect(decoded.sshLocalPort == nil)
    }

    @Test func roundTripWithExplicitTailscale() throws {
        let original = GatewayConfig(
            url: "http://MacBook-Pro.local:18789",
            token: "t",
            provider: .local,
            displayName: "My Mac",
            transport: .tailscale,
            tailscaleURL: "https://macbook-pro.tail-scales.ts.net",
            sshLocalPort: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: data)
        #expect(decoded.transport == .tailscale)
        #expect(decoded.tailscaleURL == "https://macbook-pro.tail-scales.ts.net")
        #expect(decoded.effectiveTransport == .tailscale)
    }

    @Test func roundTripWithExplicitSSH() throws {
        let original = GatewayConfig(
            url: "ws://127.0.0.1:18789",
            token: "t",
            provider: .local,
            displayName: "SSH Tunneled",
            transport: .ssh,
            sshLocalPort: 18789
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GatewayConfig.self, from: data)
        #expect(decoded.transport == .ssh)
        #expect(decoded.sshLocalPort == 18789)
    }

    @Test func decodesLegacyJSONWithoutTransportField() throws {
        // Exact JSON shape that pre-#317 `GatewayConfigStore.StoredGatewayMeta`
        // wrote. Adding `transport?` to `GatewayConfig` must NOT break
        // decoding of this payload.
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
        #expect(decoded.transport == nil)
        #expect(decoded.effectiveTransport == .manual)  // inferred from fly.dev host
    }

    @Test @MainActor func gatewayConfigStoreLoadsLegacyStoredMetaArrayWithoutTransportField() throws {
        // Exact JSON shape that pre-#317 `GatewayConfigStore.StoredGatewayMeta`
        // wrote. Exercise the real store/decode/load path rather than a local
        // mirror struct so this test catches production persistence drift.
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
        let suite = "test.remclaw.gateway-transport.\(UUID().uuidString)"
        let service = "app.remclaw.tests.gateway-transport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let data = try #require(legacyMetaArray.data(using: .utf8))
        defaults.set(data, forKey: "rem.gateway.configs")
        _ = KeychainStore.saveString("token-abc", service: service, account: "gateway.token.abc-123")
        _ = KeychainStore.saveString("token-def", service: service, account: "gateway.token.def-456")
        defer {
            defaults.removePersistentDomain(forName: suite)
            _ = KeychainStore.delete(service: service, account: "gateway.token.abc-123")
            _ = KeychainStore.delete(service: service, account: "gateway.token.def-456")
        }

        let store = GatewayConfigStore(keychainService: service, defaults: defaults)

        #expect(store.configs.count == 2)
        #expect(store.configs.allSatisfy { $0.transport == nil })
        #expect(store.configs.allSatisfy { $0.tailscaleURL == nil })
        #expect(store.configs.allSatisfy { $0.sshLocalPort == nil })
        #expect(store.configs.first(where: { $0.id == "abc-123" })?.effectiveTransport == .bonjour)
        #expect(store.configs.first(where: { $0.id == "def-456" })?.effectiveTransport == .manual)
    }
}
