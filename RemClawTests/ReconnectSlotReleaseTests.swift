import Testing
import Foundation
@testable import RemClaw

/// DEFECT 1 regression guard (#connection-reliability review).
///
/// The value-type `ReconnectCoalescerTests` prove the predicate in isolation;
/// they cannot catch a claim-WITHOUT-release WIRING bug in the session manager.
/// This suite drives the manager's real reconnect and asserts the coalescer
/// slot is RELEASED once the reconnect settles — the exact invariant that was
/// broken (slot freed only on `.connected`, so a FAILED reconnect stranded it,
/// dead-ending the backoff ladder and freezing the manual Reconnect button).
///
/// `.serialized` + credential snapshot/restore: the manager reads the global
/// `RemCredentialStore`, so we clear it (to force a deterministic, network-free
/// settle where `connectIfConfigured()` no-ops and NO backoff ladder starts)
/// and restore it in `defer`. Serialized so the brief cleared window doesn't
/// race another test in this suite.
@MainActor
@Suite("Reconnect slot release (manager wiring)", .serialized)
struct ReconnectSlotReleaseTests {
    /// A reconnect that settles WITHOUT reaching `.connected` must still release
    /// the slot. Driven with no creds so `connectIfConfigured()` no-ops: the
    /// reconnect owner's `defer` frees the slot immediately and, crucially, no
    /// ladder re-claims it (an unconfigured `connectIfConfigured` neither sets
    /// `.unreachable` nor schedules a retry). Pre-fix (release only on
    /// `.connected`) this would strand the slot and time out.
    @Test func failedReconnectReleasesSlot() async {
        let savedURL = RemCredentialStore.gatewayURL
        let savedToken = RemCredentialStore.gatewayToken
        let savedProvider = RemCredentialStore.gatewayProviderName
        RemCredentialStore.clearGateway()
        defer {
            RemCredentialStore.gatewayURL = savedURL
            RemCredentialStore.gatewayToken = savedToken
            RemCredentialStore.gatewayProviderName = savedProvider
        }

        let mgr = RemGatewaySessionManager()

        // Claim (begin sets inFlight) + spawn the awaited reconnect owner.
        mgr.reconnect()

        // Poll for the owner's `defer` to free the slot. No network → sub-second.
        var released = false
        for _ in 0..<150 {  // ~3s ceiling
            if !mgr.isReconnectSlotHeldForTesting {
                released = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(released == true)
        #expect(mgr.isReconnectSlotHeldForTesting == false)
    }

    /// DEFECT/P1 wiring guard: while a reconnect is genuinely IN FLIGHT, a second
    /// reconnect must be REFUSED (not stack a second socket pair). Uses an
    /// unreachable, non-routable gateway (RFC 5737 TEST-NET) so the first
    /// reconnect stays in flight through its 10s connect timeout — long enough to
    /// prove the second `reconnect()` is coalesced away rather than admitted.
    /// This is the manager-level analogue of the value-type `slotHeldUntilOwner…`
    /// contract, and the same awaited-ownership shape the sub-reconnect
    /// escalations use (`performReconnectAwaitingSettle`).
    @Test func concurrentReconnectWhileInFlightIsRefused() async {
        let savedURL = RemCredentialStore.gatewayURL
        let savedToken = RemCredentialStore.gatewayToken
        let savedProvider = RemCredentialStore.gatewayProviderName
        // Non-routable host → connect hangs to its timeout, keeping the reconnect
        // in flight for the duration of this test.
        RemCredentialStore.gatewayURL = "https://192.0.2.1"
        RemCredentialStore.gatewayToken = "test-token"
        RemCredentialStore.gatewayProviderName = "Railway"
        defer {
            RemCredentialStore.gatewayURL = savedURL
            RemCredentialStore.gatewayToken = savedToken
            RemCredentialStore.gatewayProviderName = savedProvider
        }

        let mgr = RemGatewaySessionManager()

        mgr.reconnect()                       // claim #1
        // Let the owner task claim + enter the (hanging) connect.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(mgr.isReconnectSlotHeldForTesting == true)   // genuinely in flight

        // Concurrent reconnects during the in-flight window must all be refused.
        mgr.reconnect()
        mgr.reconnect()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(mgr.isReconnectSlotHeldForTesting == true)   // still one owner
        #expect(mgr.reconnectClaimCountForTesting == 1)      // no second claim
    }
}
