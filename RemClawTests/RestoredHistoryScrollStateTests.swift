import Testing
@testable import RemClaw

struct RestoredHistoryScrollStateTests {
    @Test func ignoresLoadingAndEmptyHistory() {
        var state = RestoredHistoryScrollState()

        let loadingResult = state.shouldStartScroll(
            isLoading: true,
            sessionKey: "session-a",
            messageCount: 1,
            lastMessageIdentity: "message-1"
        )
        let emptyResult = state.shouldStartScroll(
            isLoading: false,
            sessionKey: "session-a",
            messageCount: 0,
            lastMessageIdentity: nil
        )

        #expect(!loadingResult)
        #expect(!emptyResult)
    }

    @Test func doesNotRepeatScrollForSameRestoredSnapshot() {
        var state = RestoredHistoryScrollState()

        let firstResult = state.shouldStartScroll(
            isLoading: false,
            sessionKey: "session-a",
            messageCount: 3,
            lastMessageIdentity: "message-3"
        )
        let secondResult = state.shouldStartScroll(
            isLoading: false,
            sessionKey: "session-a",
            messageCount: 3,
            lastMessageIdentity: "message-3"
        )

        #expect(firstResult)
        #expect(!secondResult)
    }

    @Test func allowsRealHistorySnapshotAfterEarlyStaleSessionSwitchSnapshot() {
        var state = RestoredHistoryScrollState()

        let staleSnapshotResult = state.shouldStartScroll(
            isLoading: false,
            sessionKey: "session-b",
            messageCount: 2,
            lastMessageIdentity: "old-session-last-message"
        )
        let realSnapshotResult = state.shouldStartScroll(
            isLoading: false,
            sessionKey: "session-b",
            messageCount: 24,
            lastMessageIdentity: "session-b-last-message"
        )

        #expect(staleSnapshotResult)
        #expect(realSnapshotResult)
    }

    @Test func resetAllowsCurrentSnapshotToScrollAgainAfterSessionChange() {
        var state = RestoredHistoryScrollState()

        let firstResult = state.shouldStartScroll(
            isLoading: false,
            sessionKey: "session-a",
            messageCount: 3,
            lastMessageIdentity: "message-3"
        )
        state.reset()
        let resultAfterReset = state.shouldStartScroll(
            isLoading: false,
            sessionKey: "session-a",
            messageCount: 3,
            lastMessageIdentity: "message-3"
        )

        #expect(firstResult)
        #expect(resultAfterReset)
    }
}
