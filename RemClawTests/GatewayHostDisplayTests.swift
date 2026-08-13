import Testing
@testable import RemClaw

/// A pre-warmed pool gateway keeps its internal `remclaw-pool-<id>.fly.dev` Fly
/// app name after assignment (Fly apps can't be renamed; re-creating a per-user
/// app would defeat the pool). That internal "pool" name must never surface to
/// users — a founder saw `Host = remclaw-pool-…fly.dev` in Agent Settings.
@Suite("Gateway host display")
struct GatewayHostDisplayTests {
    @Test func poolHostIsMaskedToFriendlyLabel() {
        #expect(GatewayHostDisplay.sanitized("remclaw-pool-00000000.fly.dev")
                == GatewayHostDisplay.managedCloudLabel)
    }

    @Test func poolHostDetectionIsCaseInsensitive() {
        #expect(GatewayHostDisplay.isPoolHost("REMCLAW-POOL-ABC123.FLY.DEV"))
        #expect(GatewayHostDisplay.sanitized("REMCLAW-POOL-ABC123.FLY.DEV")
                == GatewayHostDisplay.managedCloudLabel)
    }

    @Test func perUserFlyHostPassesThroughUnchanged() {
        // A real per-user managed app must still show its own hostname.
        #expect(GatewayHostDisplay.sanitized("remclaw-abc12345.fly.dev")
                == "remclaw-abc12345.fly.dev")
        #expect(!GatewayHostDisplay.isPoolHost("remclaw-abc12345.fly.dev"))
    }

    @Test func nonPoolHostsPassThrough() {
        #expect(GatewayHostDisplay.sanitized("sam-mac.local") == "sam-mac.local")
        #expect(GatewayHostDisplay.sanitized("localhost") == "localhost")
        // A non-fly host that merely contains "pool" must not be masked.
        #expect(GatewayHostDisplay.sanitized("mypool.example.com") == "mypool.example.com")
        #expect(GatewayHostDisplay.sanitized(nil) == nil)
    }

    @Test func gatewayConfigHostDisplayMasksPoolURL() {
        let config = GatewayConfig(
            url: "https://remclaw-pool-00000000.fly.dev",
            token: "token",
            provider: .fly,
            displayName: "Cloud Gateway"
        )
        #expect(config.hostDisplay == GatewayHostDisplay.managedCloudLabel)
    }
}
