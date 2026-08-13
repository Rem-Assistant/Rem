import Testing
@testable import RemClaw

struct SessionListPaginationTests {
    @Test func growsWindowWhenGatewayReportsMoreRows() {
        #expect(SessionListPagination.nextLimit(
            currentLimit: 100,
            receivedCount: 100,
            hasMore: true
        ) == 200)
    }

    @Test func stopsWhenGatewayReportsCompleteWindow() {
        #expect(SessionListPagination.nextLimit(
            currentLimit: 100,
            receivedCount: 100,
            hasMore: false
        ) == nil)
    }

    @Test func legacyGatewayGrowsOnlyAfterFullWindow() {
        #expect(SessionListPagination.nextLimit(
            currentLimit: 100,
            receivedCount: 100,
            hasMore: nil
        ) == 200)
        #expect(SessionListPagination.nextLimit(
            currentLimit: 200,
            receivedCount: 147,
            hasMore: nil
        ) == nil)
    }

    @Test func recreatedSurfaceRestoresTheAuthoritativeCachedWindow() {
        #expect(SessionListPagination.restoredLimit(
            currentLimit: 100,
            appliedLimit: 200,
            cachedCount: 200
        ) == 200)
        #expect(SessionListPagination.restoredLimit(
            currentLimit: 100,
            appliedLimit: nil,
            cachedCount: 240
        ) == 240)
    }

    @Test func filteredWindowKeepsPagingUntilVisibleTailAdvances() {
        #expect(SessionListPagination.nextLimitPastFilteredWindow(
            previousVisibleTail: "chat-visible-100",
            currentVisibleTail: "chat-visible-100",
            currentLimit: 200,
            receivedCount: 200,
            hasMore: true
        ) == 300)

        #expect(SessionListPagination.nextLimitPastFilteredWindow(
            previousVisibleTail: "chat-visible-100",
            currentVisibleTail: "chat-visible-201",
            currentLimit: 300,
            receivedCount: 300,
            hasMore: true
        ) == nil)
    }

    @Test func filteredWindowStopsAtAuthoritativeEnd() {
        #expect(SessionListPagination.nextLimitPastFilteredWindow(
            previousVisibleTail: "chat-visible-100",
            currentVisibleTail: "chat-visible-100",
            currentLimit: 200,
            receivedCount: 200,
            hasMore: false
        ) == nil)
    }

    @Test func terminalCursorMismatchRestartsCurrentWindowOnce() {
        // A newly active row moved ahead of the cursor and is missing.
        #expect(SessionListPagination.shouldRestartAfterCursorDrift(
            receivedCount: 5,
            totalCount: 6,
            targetLimit: 200,
            hasMore: false
        ))

        // A row already collected from page one was remotely deleted and is stale.
        #expect(SessionListPagination.shouldRestartAfterCursorDrift(
            receivedCount: 6,
            totalCount: 5,
            targetLimit: 200,
            hasMore: false
        ))

        #expect(!SessionListPagination.shouldRestartAfterCursorDrift(
            receivedCount: 100,
            totalCount: 200,
            targetLimit: 100,
            hasMore: false
        ))
        #expect(!SessionListPagination.shouldRestartAfterCursorDrift(
            receivedCount: 5,
            totalCount: 6,
            targetLimit: 200,
            hasMore: true
        ))
    }
}
