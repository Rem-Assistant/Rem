import Foundation
import Testing
@testable import RemClaw

struct DailyBriefNotificationRoutingTests {
    @MainActor
    @Test func voiceCommandsRemainRouterOwnedUntilALiveRootAcknowledgesThem() {
        let router = VoiceSessionControlRouter()
        let firstRoot = UUID()
        router.enqueue(.readLatestBrief, accountID: "account-a")
        let token = router.commandToken

        #expect(router.claimCommand(for: token, accountID: "account-a", ownerID: firstRoot) == .readLatestBrief)
        router.releaseCommand(ownerID: firstRoot)

        let replacementRoot = UUID()
        let replacementToken = router.commandToken
        #expect(router.claimCommand(
            for: replacementToken,
            accountID: "account-a",
            ownerID: replacementRoot
        ) == .readLatestBrief)
        router.acknowledgeCommand(for: replacementToken, ownerID: replacementRoot)
        #expect(router.latestCommand == nil)

        router.enqueue(.open)
        let nextToken = router.commandToken
        #expect(router.claimCommand(for: nextToken, accountID: "account-a", ownerID: firstRoot) == .open)
        router.acknowledgeCommand(for: nextToken, ownerID: replacementRoot)
        #expect(router.latestCommand == .open)
        router.acknowledgeCommand(for: nextToken, ownerID: firstRoot)
        #expect(router.latestCommand == nil)
    }

    @MainActor
    @Test func commandBoundToOneAccountNeverReplaysIntoAnotherAccount() {
        let router = VoiceSessionControlRouter()
        let firstRoot = UUID()
        router.enqueue(.readLatestBrief, accountID: "account-a")
        #expect(router.claimCommand(
            for: router.commandToken,
            accountID: "account-a",
            ownerID: firstRoot
        ) == .readLatestBrief)
        router.releaseCommand(ownerID: firstRoot)

        #expect(router.claimCommand(
            for: router.commandToken,
            accountID: "account-b",
            ownerID: UUID()
        ) == nil)
        #expect(router.latestCommand == nil)
    }

    @MainActor
    @Test func claimedReadRemainsPendingWhenPlaybackDoesNotStart() throws {
        let router = VoiceSessionControlRouter()
        let playback = LatestBriefPlaybackController()
        let ownerID = UUID()
        _ = try #require(playback.beginRequest())
        router.enqueue(.readLatestBrief, accountID: "account-a")
        let token = router.commandToken

        #expect(router.claimCommand(
            for: token,
            accountID: "account-a",
            ownerID: ownerID
        ) == .readLatestBrief)
        let didStart = playback.beginRequest() != nil
        if didStart {
            router.acknowledgeCommand(for: token, ownerID: ownerID)
        }

        #expect(!didStart)
        #expect(router.latestCommand == .readLatestBrief)
    }

    @MainActor
    @Test func ownerlessBriefIntentIsDiscardedBeforeAnotherAccountSignsIn() {
        let router = VoiceSessionControlRouter()
        router.enqueue(.readLatestBrief, accountID: nil)

        #expect(router.latestCommand == nil)
        #expect(router.claimCommand(
            for: router.commandToken,
            accountID: "account-b",
            ownerID: UUID()
        ) == nil)
    }

    @Test func canonicalListenDeepLinkParsesOnlyTheBriefListenRoute() {
        #expect(LatestBriefDeepLink.isListenRequest(LatestBriefDeepLink.listenURL))
        let accountURL = LatestBriefDeepLink.listenURL(accountID: "account-a")
        #expect(LatestBriefDeepLink.isListenRequest(accountURL))
        #expect(LatestBriefDeepLink.accountID(from: accountURL) == "account-a")
        #expect(LatestBriefDeepLink.accountID(from: LatestBriefDeepLink.listenURL) == nil)
        #expect(!LatestBriefDeepLink.isListenRequest(URL(string: "remclaw://brief/open")!))
        #expect(!LatestBriefDeepLink.isListenRequest(URL(string: "remclaw://voice/start")!))
        #expect(!LatestBriefDeepLink.isListenRequest(URL(string: "https://example.com/brief/listen")!))
    }

    @Test func coldBriefTapAlwaysDefersWhileStoredAuthIsStillRestoring() {
        #expect(LatestBriefDeepLink.shouldDeferUntilAuthRestores(
            isCheckingAuth: true
        ))
        #expect(!LatestBriefDeepLink.shouldDeferUntilAuthRestores(
            isCheckingAuth: false
        ))
    }

    @Test func cachedProfileCannotClaimBriefUntilAuthenticationActuallySucceeds() {
        let url = LatestBriefDeepLink.listenURL(accountID: "account-a")
        #expect(LatestBriefDeepLink.validatedAccountID(
            from: url,
            isAuthenticated: false,
            currentUserID: "account-a"
        ) == nil)
        #expect(LatestBriefDeepLink.validatedAccountID(
            from: url,
            isAuthenticated: true,
            currentUserID: "account-b"
        ) == nil)
        #expect(LatestBriefDeepLink.validatedAccountID(
            from: url,
            isAuthenticated: true,
            currentUserID: "account-a"
        ) == "account-a")
    }

    @Test func newBriefNotificationRoutesToCanonicalListenFlow() {
        let url = DailyBriefNotificationRouting.deepLink(from: [
            "type": "daily_brief",
            "accountId": "account-a",
            "deepLink": "remclaw://brief/listen",
            "briefDate": "2026-08-08",
        ])
        #expect(url == LatestBriefDeepLink.listenURL(accountID: "account-a"))
    }

    @Test func staleNotificationFromAnotherAccountNeverOpensOrNarratesCurrentAccountBrief() throws {
        let notificationURL = try #require(DailyBriefNotificationRouting.deepLink(from: [
            "type": "daily_brief",
            "accountId": "account-a",
            // Even a forged legacy link cannot change the account-bound canonical destination.
            "deepLink": "remclaw://brief/listen?accountId=account-b",
        ]))

        #expect(LatestBriefDeepLink.accountID(from: notificationURL) == "account-a")
        #expect(LatestBriefDeepLink.validatedAccountID(
            from: notificationURL,
            isAuthenticated: true,
            currentUserID: "account-b"
        ) == nil)
    }

    @Test func ownerlessLegacyCheckinCannotReplayIntoTheCurrentAccount() {
        let url = DailyBriefNotificationRouting.deepLink(from: [
            "type": "checkin",
            "deepLink": "rem://brief",
        ])
        #expect(url == nil)
    }

    @Test func unrelatedNotificationDoesNotEnterBriefPlayback() {
        #expect(DailyBriefNotificationRouting.deepLink(from: [
            "type": "task",
            "taskId": UUID().uuidString,
        ]) == nil)
    }
}
