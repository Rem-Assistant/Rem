import Testing
import Foundation
@testable import RemClaw

@Suite("Reconnect coalescer")
struct ReconnectCoalescerTests {
    // A single reconnect still works — the guard must never refuse the FIRST
    // request (the "guard doesn't deadlock a legit reconnect" invariant).
    @Test func firstReconnectIsAdmitted() {
        var c = ReconnectCoalescer()
        #expect(c.begin(now: 1_000, debounce: true) != nil)
        #expect(c.inFlight == true)
    }

    // Rapid foreground flaps collapse to ONE reconnect: a second in-flight
    // request within the safety window is refused (nil token).
    @Test func inFlightBlocksStacking() {
        var c = ReconnectCoalescer()
        #expect(c.begin(now: 1_000, debounce: false) != nil)
        #expect(c.begin(now: 1_001, debounce: false) == nil)
        #expect(c.begin(now: 1_002, debounce: true) == nil)
    }

    // Once the reconnect settles (end), a new one may start — but the manual/
    // foreground debounce still collapses a too-soon retry.
    @Test func debounceCollapsesRapidManualRetriesAfterEnd() {
        var c = ReconnectCoalescer(safetyExpiry: 30, debounceWindow: 3)
        let t = c.begin(now: 1_000, debounce: true)
        #expect(t != nil)
        c.end(t!)
        // 1s later, not in flight, but within the 3s debounce window → refused.
        #expect(c.begin(now: 1_001, debounce: true) == nil)
        // Past the debounce window → admitted.
        #expect(c.begin(now: 1_004, debounce: true) != nil)
    }

    // The backoff-ladder / keepalive path (debounce: false) must NOT be swallowed
    // by a sub-window backoff: after the previous attempt ends, a 1s-later
    // scheduled retry is admitted.
    @Test func ladderPathIgnoresDebounceWindow() {
        var c = ReconnectCoalescer(safetyExpiry: 30, debounceWindow: 3)
        let t = c.begin(now: 1_000, debounce: false)
        #expect(t != nil)
        c.end(t!)
        #expect(c.begin(now: 1_001, debounce: false) != nil)
    }

    // Self-healing: a reconnect that never calls end() must not wedge
    // reconnection forever — past safetyExpiry a new request is admitted.
    @Test func stuckInFlightSelfHealsAfterSafetyExpiry() {
        var c = ReconnectCoalescer(safetyExpiry: 30, debounceWindow: 3)
        #expect(c.begin(now: 1_000, debounce: false) != nil)
        // Still "in flight" (end never called), within safety window → refused.
        #expect(c.begin(now: 1_020, debounce: false) == nil)
        // Past safety window → admitted despite the never-cleared flag.
        #expect(c.begin(now: 1_031, debounce: false) != nil)
    }

    // A genuinely long-running reconnect (e.g. cold Fly boot) keeps the slot: a
    // debounce:false trigger inside the safety window is still refused.
    @Test func longReconnectHoldsSlotWithinSafetyWindow() {
        var c = ReconnectCoalescer(safetyExpiry: 30, debounceWindow: 3)
        #expect(c.begin(now: 1_000, debounce: false) != nil)
        #expect(c.begin(now: 1_010, debounce: false) == nil)
        #expect(c.begin(now: 1_029, debounce: true) == nil)
    }

    // MARK: - Ownership / generation guard (DEFECT/P1 + P3)

    // Escalation-ownership CONTRACT (P1): while an owner holds the slot (has not
    // yet called `end`), every concurrent `begin` is refused — regardless of
    // trigger class — and the slot frees ONLY when the owner ends with its token.
    // This is exactly the invariant the awaited sub-reconnect escalation relies
    // on: it `await`s the fallback, so its token'd `end` runs only after the full
    // reconnect settles, and nothing can claim during that window.
    @Test func slotHeldUntilOwnerEndsToken() {
        var c = ReconnectCoalescer(safetyExpiry: 30, debounceWindow: 3)
        let owner = c.begin(now: 1_000, debounce: false)
        #expect(owner != nil)
        // Simulated escalation in progress: owner has NOT ended.
        #expect(c.begin(now: 1_002, debounce: false) == nil)
        #expect(c.begin(now: 1_003, debounce: true) == nil)
        // Only the owner's token'd end (after the fallback settles) frees it.
        c.end(owner!)
        #expect(c.inFlight == false)
        #expect(c.begin(now: 1_004, debounce: false) != nil)
    }

    // Reclaim-safety (P3): a STALE `end` (from an owner that already settled)
    // must NOT free a slot a newer `begin` has since re-claimed. This is the
    // hazard the old tokenless dual-release created.
    @Test func staleTokenEndDoesNotReleaseAReclaim() {
        var c = ReconnectCoalescer(safetyExpiry: 30, debounceWindow: 3)
        let t1 = c.begin(now: 1_000, debounce: false)
        #expect(t1 != nil)
        c.end(t1!)                                    // owner A settles → free
        let t2 = c.begin(now: 1_001, debounce: false) // owner B claims
        #expect(t2 != nil)
        c.end(t1!)                                    // stale duplicate end from A
        #expect(c.inFlight == true)                   // B's slot NOT clobbered
        c.end(t2!)
        #expect(c.inFlight == false)                  // only B's own end frees it
    }

    // `reset()` (teardown) clears in-flight AND invalidates outstanding tokens,
    // so a late `end` from the reset-over reconnect can't free a fresh claim.
    @Test func resetInvalidatesOutstandingToken() {
        var c = ReconnectCoalescer(safetyExpiry: 30, debounceWindow: 3)
        let t1 = c.begin(now: 1_000, debounce: false)
        #expect(t1 != nil)
        c.reset()
        #expect(c.inFlight == false)
        let t2 = c.begin(now: 1_100, debounce: false)  // fresh claim after reset
        #expect(t2 != nil)
        c.end(t1!)                                     // stale pre-reset token
        #expect(c.inFlight == true)                    // fresh claim survives
        c.end(t2!)
        #expect(c.inFlight == false)
    }
}
