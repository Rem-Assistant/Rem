import Testing
@testable import RemClaw

struct SessionsListViewStateResolverTests {
    @Test func disconnectedWhenOperatorNotReady() {
        let state = SessionsListViewStateResolver.resolve(
            operatorReady: false,
            isLoading: true,
            hasLoadedOnce: false,
            hasVisibleSessions: false,
            hasLoadError: false
        )
        #expect(state == .disconnected)
    }

    @Test func loadingDuringInitialFetch() {
        let state = SessionsListViewStateResolver.resolve(
            operatorReady: true,
            isLoading: true,
            hasLoadedOnce: false,
            hasVisibleSessions: false,
            hasLoadError: false
        )
        #expect(state == .loading)
    }

    @Test func waitingBeforeInitialRequestDoesNotClaimEmptyOrLoading() {
        let state = SessionsListViewStateResolver.resolve(
            operatorReady: true,
            isLoading: false,
            hasLoadedOnce: false,
            hasVisibleSessions: false,
            hasLoadError: false
        )
        #expect(state == .waitingForRequest)
        #expect(state.usesLoadingSkeleton)
    }

    @Test func skeletonPresentationIsLimitedToAnUncachedScheduledOrActiveRequest() {
        #expect(SessionsListViewState.waitingForRequest.usesLoadingSkeleton)
        #expect(SessionsListViewState.loading.usesLoadingSkeleton)
        #expect(!SessionsListViewState.disconnected.usesLoadingSkeleton)
        #expect(!SessionsListViewState.empty.usesLoadingSkeleton)
        #expect(!SessionsListViewState.loaded.usesLoadingSkeleton)
        #expect(!SessionsListViewState.error.usesLoadingSkeleton)
    }

    @Test func retryWithNoVisibleRowsRemainsLoading() {
        let state = SessionsListViewStateResolver.resolve(
            operatorReady: true,
            isLoading: true,
            hasLoadedOnce: true,
            hasVisibleSessions: false,
            hasLoadError: true
        )
        #expect(state == .loading)
    }

    @Test func errorWhenLoadFailedWithoutVisibleSessions() {
        let state = SessionsListViewStateResolver.resolve(
            operatorReady: true,
            isLoading: false,
            hasLoadedOnce: true,
            hasVisibleSessions: false,
            hasLoadError: true
        )
        #expect(state == .error)
    }

    @Test func emptyWhenConnectedAndNoSessions() {
        let state = SessionsListViewStateResolver.resolve(
            operatorReady: true,
            isLoading: false,
            hasLoadedOnce: true,
            hasVisibleSessions: false,
            hasLoadError: false
        )
        #expect(state == .empty)
    }

    @Test func loadedWhenVisibleSessionsExist() {
        let state = SessionsListViewStateResolver.resolve(
            operatorReady: true,
            isLoading: false,
            hasLoadedOnce: true,
            hasVisibleSessions: true,
            hasLoadError: false
        )
        #expect(state == .loaded)
    }
}
