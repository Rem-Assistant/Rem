import Foundation
import Testing
@testable import RemClaw

@MainActor
struct SharedGatewaySettingsResolverTests {
    @Test func preferredLandingConfigUsesActiveGateway() {
        let inactive = GatewayConfig(
            id: "cloud",
            url: "https://cloud.example.com",
            token: "token",
            provider: .fly,
            displayName: "Cloud Gateway",
            isActive: false
        )
        let active = GatewayConfig(
            id: "local",
            url: "http://127.0.0.1:18789",
            token: "token",
            provider: .local,
            displayName: "This Mac",
            isActive: true
        )

        let selected = SharedGatewaySettingsResolver.preferredLandingConfig(
            from: [inactive, active]
        )

        #expect(selected?.id == "local")
    }

    @Test func preferredLandingConfigFallsBackToFirstSavedGateway() {
        let cloud = GatewayConfig(
            id: "cloud",
            url: "https://cloud.example.com",
            token: "token",
            provider: .fly,
            displayName: "Cloud Gateway"
        )
        let manual = GatewayConfig(
            id: "manual",
            url: "https://gateway.example.com",
            token: "token",
            provider: .manual,
            displayName: "Manual Gateway"
        )

        let selected = SharedGatewaySettingsResolver.preferredLandingConfig(
            from: [cloud, manual]
        )

        #expect(selected?.id == "cloud")
    }

    @Test func sortedConfigsPutsActiveGatewayFirstThenName() {
        let beta = GatewayConfig(
            id: "beta",
            url: "https://beta.example.com",
            token: "token",
            provider: .manual,
            displayName: "Beta"
        )
        let active = GatewayConfig(
            id: "active",
            url: "http://127.0.0.1:18789",
            token: "token",
            provider: .local,
            displayName: "This Mac",
            isActive: true
        )
        let alpha = GatewayConfig(
            id: "alpha",
            url: "https://alpha.example.com",
            token: "token",
            provider: .manual,
            displayName: "Alpha"
        )

        let sorted = SharedGatewaySettingsResolver.sortedConfigs([beta, active, alpha])

        #expect(sorted.map(\.id) == ["active", "alpha", "beta"])
    }

    @Test func macHardwareControlsOnlyShowForLocalGateways() {
        let cloud = GatewayConfig(
            id: "cloud",
            url: "https://cloud.example.com",
            token: "token",
            provider: .fly,
            displayName: "Cloud Gateway",
            macAddress: "AA:BB:CC:DD:EE:FF",
            isActive: true
        )
        let manual = GatewayConfig(
            id: "manual",
            url: "https://gateway.example.com",
            token: "token",
            provider: .manual,
            displayName: "Manual Gateway",
            macAddress: "AA:BB:CC:DD:EE:FF",
            isActive: true
        )
        let local = GatewayConfig(
            id: "local",
            url: "http://127.0.0.1:18789",
            token: "token",
            provider: .local,
            displayName: "Local Gateway",
            macAddress: "AA:BB:CC:DD:EE:FF",
            isActive: true
        )

        #expect(SharedGatewaySettingsResolver.showsMacHardwareControls(for: cloud) == false)
        #expect(SharedGatewaySettingsResolver.showsMacHardwareControls(for: manual) == false)
        #expect(SharedGatewaySettingsResolver.showsMacHardwareControls(for: local))
    }

    @Test func switcherTitleDisambiguatesDuplicateGatewayNames() {
        let first = GatewayConfig(
            id: "first-cloud",
            url: "https://first.example.com",
            token: "token",
            provider: .fly,
            displayName: "Cloud Gateway"
        )
        let second = GatewayConfig(
            id: "second-cloud",
            url: "https://second.example.com",
            token: "token",
            provider: .fly,
            displayName: "Cloud Gateway"
        )
        let manual = GatewayConfig(
            id: "manual",
            url: "https://gateway.example.com",
            token: "token",
            provider: .manual,
            displayName: "Manual Gateway"
        )

        let configs = [first, second, manual]

        #expect(SharedGatewaySettingsResolver.switcherTitle(for: first, in: configs) == "Cloud Gateway (first.example.com)")
        #expect(SharedGatewaySettingsResolver.switcherTitle(for: second, in: configs) == "Cloud Gateway (second.example.com)")
        #expect(SharedGatewaySettingsResolver.switcherTitle(for: manual, in: configs) == "Manual Gateway")
    }

    @Test func reusingExistingIDPreservesLocalRowIdentityForSameGatewayURL() {
        let existing = GatewayConfig(
            id: "existing-cloud",
            url: "https://cloud.example.com/",
            token: "old-token",
            provider: .fly,
            displayName: "My Cloud",
            isActive: false
        )
        let redeployed = GatewayConfig(
            id: "fresh-cloud",
            url: "https://cloud.example.com",
            token: "new-token",
            provider: .fly,
            displayName: "Cloud Gateway",
            isActive: true
        )

        let saved = SharedGatewaySettingsResolver.reusingExistingID(
            for: redeployed,
            in: [existing]
        )

        #expect(saved.id == "existing-cloud")
        #expect(saved.token == "new-token")
        #expect(saved.displayName == "My Cloud")
        #expect(saved.isActive)
    }

    @Test func gatewayUpdateReadinessDecodesBackendContract() throws {
        let json = """
        {
          "readiness": {
            "canUpdate": false,
            "status": "managed_fly_preflight_required",
            "hostingProvider": "fly",
            "gatewayUrl": "https://remclaw-00000000.fly.dev",
            "managedFlyAppName": "remclaw-00000000",
            "message": "Gateway updates require preflight.",
            "requiredChecks": ["same_gateway_target", "backup_or_snapshot"],
            "preflightChecks": [
              {
                "id": "same_gateway_target",
                "label": "Same Gateway Target",
                "status": "ready",
                "message": "Managed Fly app is known."
              },
              {
                "id": "backup_or_snapshot",
                "label": "Backup Or Snapshot",
                "status": "blocked",
                "message": "Backup is required."
              },
              {
                "id": "post_update_health_check",
                "label": "Post-Update Health Check",
                "status": "not_run",
                "message": "Health check has not run."
              },
              {
                "id": "future_check",
                "label": "Future Check",
                "status": "future_status",
                "message": "Future backend status."
              }
            ],
            "approvedTargets": [
              {
                "id": "openclaw-stable",
                "label": "OpenClaw stable",
                "channel": "stable",
                "image": "ghcr.io/rem-assistant/openclaw-gateway:stable",
                "requiredCapabilities": ["skills.search"],
                "enabled": false,
                "disabledReason": "Not installable yet."
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GatewayUpdateReadinessResponse.self, from: json)

        #expect(decoded.readiness.canUpdate == false)
        #expect(decoded.readiness.status == .managedFlyPreflightRequired)
        #expect(decoded.readiness.hostingProvider == "fly")
        #expect(decoded.readiness.requiredChecks == ["same_gateway_target", "backup_or_snapshot"])
        #expect(decoded.readiness.preflightChecks.map(\.status) == [
            .ready,
            .blocked,
            .notRun,
            .unknown("future_status"),
        ])
        #expect(decoded.readiness.preflightChecks[0].label == "Same Gateway Target")
        #expect(decoded.readiness.preflightChecks[1].message == "Backup is required.")
        #expect(decoded.readiness.approvedTargets.count == 1)
        #expect(decoded.readiness.approvedTargets[0].id == "openclaw-stable")
        #expect(decoded.readiness.approvedTargets[0].requiredCapabilities == ["skills.search"])
    }

    @Test func gatewayUpdateReadinessPreservesUnknownBackendStatus() throws {
        let json = """
        {
          "readiness": {
            "canUpdate": false,
            "status": "future_status",
            "hostingProvider": "fly",
            "gatewayUrl": null,
            "managedFlyAppName": null,
            "message": "Future backend response.",
            "requiredChecks": []
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GatewayUpdateReadinessResponse.self, from: json)

        #expect(decoded.readiness.status == .unknown("future_status"))
        #expect(decoded.readiness.preflightChecks == [])
        #expect(decoded.readiness.approvedTargets == [])
    }

    @Test func upsertActiveLocalGatewayAddsActiveLocalConfig() {
        let store = makeStore()

        SharedGatewaySettingsStore.upsertActiveLocalGateway(
            in: store,
            url: "http://127.0.0.1:18789",
            token: "local-token"
        )

        let config = store.activeConfig
        #expect(config?.provider == .local)
        #expect(config?.displayName == "Local Gateway")
        #expect(config?.url == "http://127.0.0.1:18789")
        #expect(config?.token == "local-token")
    }

    @Test func upsertActiveLocalGatewayPrefersExistingLocalConfigOverCloud() {
        let store = makeStore()
        store.save(
            GatewayConfig(
                id: "cloud",
                url: "https://cloud.example.com",
                token: "cloud-token",
                provider: .fly,
                displayName: "Cloud Gateway",
                isActive: true
            )
        )
        store.save(
            GatewayConfig(
                id: "local",
                url: "http://127.0.0.1:18789",
                token: "local-token",
                provider: .local,
                displayName: "Local Gateway",
                isActive: false
            )
        )

        SharedGatewaySettingsStore.upsertActiveLocalGateway(
            in: store,
            url: "http://127.0.0.1:18789",
            token: "fresh-local-token"
        )

        #expect(store.configs.count == 2)
        #expect(store.activeConfig?.id == "local")
    }

    private func makeStore() -> GatewayConfigStore {
        let suite = "test.remclaw.gateway-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return GatewayConfigStore(
            keychainService: "app.remclaw.tests.\(UUID().uuidString)",
            defaults: defaults
        )
    }
}
