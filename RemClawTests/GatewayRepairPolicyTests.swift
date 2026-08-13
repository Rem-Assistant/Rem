import Testing
@testable import RemClaw

@Suite("Gateway repair policy")
struct GatewayRepairPolicyTests {
    @Test func explicitFlyConfigUsesManagedRepair() {
        let config = GatewayConfig(
            url: "https://remclaw-test.fly.dev",
            token: "token",
            provider: .fly,
            displayName: "Cloud Gateway"
        )

        #expect(GatewayRepairPolicy.shouldRunManagedCloudRepair(
            config: config,
            storedProviderName: "Local",
            storedGatewayURL: "http://manual.example"
        ))
    }

    @Test func explicitManualConfigDoesNotUseLegacyFlyState() {
        let config = GatewayConfig(
            url: "https://manual.example",
            token: "token",
            provider: .manual,
            displayName: "Manual Gateway"
        )

        #expect(!GatewayRepairPolicy.shouldRunManagedCloudRepair(
            config: config,
            storedProviderName: "Fly.io",
            storedGatewayURL: "https://stale.fly.dev"
        ))
    }

    @Test func explicitLocalConfigDoesNotUseLegacyFlyState() {
        let config = GatewayConfig(
            url: "http://rem.local:18789",
            token: "token",
            provider: .local,
            displayName: "Local Gateway"
        )

        #expect(!GatewayRepairPolicy.shouldRunManagedCloudRepair(
            config: config,
            storedProviderName: "Fly.io",
            storedGatewayURL: "https://stale.fly.dev"
        ))
    }

    @Test func missingConfigFallsBackToStoredFlyURL() {
        #expect(GatewayRepairPolicy.shouldRunManagedCloudRepair(
            config: nil,
            storedProviderName: "Manual",
            storedGatewayURL: "https://remclaw-test.fly.dev"
        ))
    }
}
