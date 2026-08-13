import Testing
@testable import RemClaw

struct ChatConnectionPresentationTests {
    @Test func pairingIsActionable() {
        let value = ChatConnectionPresentation.resolve(.pairingRequired)
        #expect(value.title == "Finish connecting this device")
        #expect(value.showsReviewConnection)
    }

    @Test func unreachableIsActionable() {
        let value = ChatConnectionPresentation.resolve(.unreachable("wire detail"))
        #expect(value.title == "Can't reach your gateway")
        #expect(value.showsRetry)
        #expect(value.showsReviewConnection)
        #expect(!value.subtitle.contains("wire detail"))
    }

    @Test func wakingStatesStayNonTerminal() {
        for state in [GatewayConnectionState.disconnected, .connecting] {
            let value = ChatConnectionPresentation.resolve(state)
            #expect(value.title == "Waiting for your gateway")
            #expect(value.showsRetry)
            #expect(!value.showsReviewConnection)
        }
    }

    @Test func connectedWithoutViewModelMeansPreparingChat() {
        let value = ChatConnectionPresentation.resolve(.connected)
        #expect(value.title == "Preparing chat")
        #expect(!value.showsRetry)
        #expect(!value.showsReviewConnection)
    }

    @Test func unauthorizedRoutesToRecovery() {
        let value = ChatConnectionPresentation.resolve(.unauthorized)
        #expect(value.title == "Sign-in needed")
        #expect(!value.showsRetry)
        #expect(value.showsReviewConnection)
    }

    @MainActor
    @Test func launchFailureContinueAnywayRetryAndRecoveryHaveOnePresenter() async {
        let showsGlobalBanner = MainConnectionRecoveryBannerPolicy.shouldShow(
            isConfigured: true,
            isConnected: false,
            isCompletingDeploy: false,
            selectedTab: .history,
            hasNavigationDestination: false
        )
        let failed = ChatConnectionPresentation.resolve(.unreachable("wake failed"))
        let failedSessionsState = SessionsListViewStateResolver.resolve(
            operatorReady: false,
            isLoading: false,
            hasLoadedOnce: false,
            hasVisibleSessions: false,
            hasLoadError: false
        )
        let mountedRecoveryPresenterCount = (showsGlobalBanner ? 1 : 0)
            + (failedSessionsState == .disconnected ? 1 : 0)

        #expect(!showsGlobalBanner)
        #expect(mountedRecoveryPresenterCount == 1)
        #expect(failed.showsRetry)
        #expect(failed.showsReviewConnection)

        var wakeCount = 0
        var reconnectCount = 0
        let wakeTask = GatewayConnectionRecovery.retry(
            wake: { wakeCount += 1 },
            reconnect: { reconnectCount += 1 }
        )
        await wakeTask.value
        #expect(wakeCount == 1)
        #expect(reconnectCount == 1)

        let retrying = ChatConnectionPresentation.resolve(.connecting)
        #expect(retrying.showsRetry)
        #expect(!retrying.showsReviewConnection)

        let recovered = ChatConnectionPresentation.resolve(.connected)
        #expect(!recovered.showsRetry)
        #expect(!recovered.showsReviewConnection)

        let recoveredSessionsState = SessionsListViewStateResolver.resolve(
            operatorReady: true,
            isLoading: true,
            hasLoadedOnce: false,
            hasVisibleSessions: false,
            hasLoadError: false
        )
        #expect(recoveredSessionsState == .loading)
    }

    @Test func nonChatRootStillOwnsTheGlobalRecoveryBanner() {
        #expect(MainConnectionRecoveryBannerPolicy.shouldShow(
            isConfigured: true,
            isConnected: false,
            isCompletingDeploy: false,
            selectedTab: .agenda,
            hasNavigationDestination: false
        ))
        #expect(!MainConnectionRecoveryBannerPolicy.shouldShow(
            isConfigured: true,
            isConnected: false,
            isCompletingDeploy: false,
            selectedTab: .agenda,
            hasNavigationDestination: true
        ))
    }
}
