import Foundation
import Testing
@testable import RemClaw

struct GatewayCredentialReconciliationTests {
    @Test func exactCanonicalURLWinsOverAnotherActiveGateway() {
        let exact = config(id: "exact", url: "https://canonical.fly.dev", isActive: false)
        let active = config(id: "active", url: "https://old-pool.fly.dev", isActive: true)

        let selected = GatewayCredentialReconciliation.configToReplace(
            in: [active, exact],
            canonicalURL: exact.url,
            provider: .fly
        )

        #expect(selected?.id == exact.id)
    }

    @Test func activeManagedGatewayIsReusedWhenBackendURLChanges() {
        let stale = config(id: "managed", url: "https://remclaw-pool-old.fly.dev", isActive: true)

        let selected = GatewayCredentialReconciliation.configToReplace(
            in: [stale],
            canonicalURL: "https://remclaw-user.fly.dev",
            provider: .fly
        )

        #expect(selected?.id == stale.id)
    }

    @Test func activeManualGatewayIsNeverOverwrittenByAnotherManualURL() {
        let manual = config(
            id: "manual",
            url: "https://custom.example.com",
            provider: .manual,
            isActive: true
        )

        let selected = GatewayCredentialReconciliation.configToReplace(
            in: [manual],
            canonicalURL: "https://managed-railway.example.com",
            provider: .manual
        )

        #expect(selected == nil)
    }

    @Test func invalidatedBackendTokenDoesNotCompleteSessionRestore() {
        #expect(GatewayCredentialReconciliation.shouldCompleteSessionRestore(hasBackendToken: false) == false)
        #expect(GatewayCredentialReconciliation.shouldCompleteSessionRestore(hasBackendToken: true))
    }

    private func config(
        id: String,
        url: String,
        provider: GatewayProvider = .fly,
        isActive: Bool
    ) -> GatewayConfig {
        GatewayConfig(
            id: id,
            url: url,
            token: "token",
            provider: provider,
            displayName: "Gateway",
            isActive: isActive
        )
    }
}
