import Foundation
import Testing
@testable import RemClaw

/// Gating logic for the "Reconnected" toast: it must confirm recovery from a
/// disconnect the user actually saw (visible backoff), NOT a soft grace-period
/// blip / cold start / routine foreground resume, and must debounce a flaky
/// stretch to at most one toast per window.
struct RemReconnectToastPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Gate 1 — user-visible disconnect

    @Test func toastsOnVisibleDisconnectRecovery() {
        // Recovered from the visible Unreachable/backoff state, no prior toast.
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: true, now: t0, lastToastAt: nil) == true)
    }

    @Test func doesNotToastOnGracePeriodBlip() {
        // The soft grace blip never sets `sawVisibleDisconnect`.
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: false, now: t0, lastToastAt: nil) == false)
    }

    @Test func doesNotToastOnColdStart() {
        // First-ever connect: no disconnect was ever shown.
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: false, now: t0, lastToastAt: nil) == false)
    }

    @Test func doesNotToastOnSilentForegroundResume() {
        // Routine foreground-after-background: the single transient `.unreachable`
        // is masked by the grace period as `.connecting`, so backoff (and the flag)
        // is never reached — modeled here as sawVisibleDisconnect == false.
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: false, now: t0, lastToastAt: nil) == false)
    }

    // MARK: Gate 2 — debounce

    @Test func debouncesRapidRecoveryCycles() {
        // A second visible recovery within the window is suppressed.
        let lastToast = t0
        let soon = t0.addingTimeInterval(RemReconnectToastPolicy.debounceWindow - 1)
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: true, now: soon, lastToastAt: lastToast) == false)
    }

    @Test func toastsAgainAfterDebounceWindow() {
        // A visible recovery past the window confirms again.
        let lastToast = t0
        let later = t0.addingTimeInterval(RemReconnectToastPolicy.debounceWindow + 1)
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: true, now: later, lastToastAt: lastToast) == true)
    }

    @Test func debounceBoundaryIsExclusive() {
        // Exactly at the window edge: no longer within the window, so it toasts.
        let lastToast = t0
        let atEdge = t0.addingTimeInterval(RemReconnectToastPolicy.debounceWindow)
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: true, now: atEdge, lastToastAt: lastToast) == true)
    }

    @Test func debounceNeverOverridesTheVisibleGate() {
        // Even outside the debounce window, a non-visible recovery must not toast.
        let lastToast = t0
        let later = t0.addingTimeInterval(RemReconnectToastPolicy.debounceWindow + 100)
        #expect(RemReconnectToastPolicy.shouldToast(
            sawVisibleDisconnect: false, now: later, lastToastAt: lastToast) == false)
    }
}
