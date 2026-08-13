import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
@testable import RemClaw
import Testing

@Suite("Cloud browser authenticated lifecycle")
@MainActor
struct BrowserLifecyclePersistenceTests {
    @Test func deniedHandBackKeepsUserInControlAndSurfacesRecovery() async {
        let session = makeSession()
        var intents: [Bool] = []
        session.onControlIntentChanged = { intents.append($0) }
        session.onRequestHandBack = {
            .denied("Couldn't verify your plan. Check your connection and try again.")
        }

        session.takeControl()
        session.handBack()
        await waitForHandBackToSettle(session)

        #expect(session.isControlling)
        #expect(!session.isHandBackPending)
        #expect(session.handBackErrorText == "Couldn't verify your plan. Check your connection and try again.")
        #expect(intents == [true])
    }

    @Test func authorizedHandBackTransfersControlAndEmitsResumeOnce() async {
        let session = makeSession()
        var intents: [Bool] = []
        session.onControlIntentChanged = { intents.append($0) }
        session.onRequestHandBack = { .authorized }

        session.takeControl()
        session.handBack()
        session.handBack() // duplicate taps while authorization is pending are ignored
        await waitForHandBackToSettle(session)

        #expect(!session.isControlling)
        #expect(!session.isHandBackPending)
        #expect(session.handBackErrorText == nil)
        #expect(intents == [true, false])
    }

    @Test func teardownInvalidatesDelayedHandBackAuthorization() async {
        let session = makeSession()
        var intents: [Bool] = []
        session.onControlIntentChanged = { intents.append($0) }
        session.onRequestHandBack = {
            await Task.yield()
            return .authorized
        }

        session.takeControl()
        session.handBack()
        session.stop()
        for _ in 0..<20 { await Task.yield() }

        #expect(!session.isControlling)
        #expect(!session.isHandBackPending)
        #expect(intents == [true])
    }

    @Test func coldLaunchRestoresEndedOwnerForSameAccountAndGateway() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = BrowserViewCoordinator(session: makeSession(), defaults: defaults)
        first.activateAuthenticatedScope(
            accountID: "account-a",
            gatewayURL: "https://Gateway.Example.com/"
        )
        first.session.noteBrowsingConversation("chat-browser")
        first.session.markSessionEnded()
        first.terminateAuthenticatedSession()

        let restoredDefaults = try #require(UserDefaults(suiteName: suite))
        let restored = BrowserViewCoordinator(session: makeSession(), defaults: restoredDefaults)
        restored.activateAuthenticatedScope(
            accountID: "account-a",
            gatewayURL: "https://gateway.example.com"
        )

        #expect(restored.session.lastConversationKey == "chat-browser")
        #expect(restored.session.hasEnded)

        let history = [
            OpenClawChatMessage(
                role: "assistant",
                content: [OpenClawChatMessageContent(
                    type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil,
                    id: "browser-call", name: "browser",
                    arguments: AnyCodable(["action": "navigate"])
                )],
                timestamp: nil
            ),
        ]
        #expect(BrowserCardStateResolver.resolve(
            messages: history,
            pendingRunCount: 0,
            isOwner: restored.session.lastConversationKey == "chat-browser",
            isSessionEnded: restored.session.hasEnded
        ) == .ended)
    }

    @Test func receiptNeverCrossesAccountOrGatewayBoundary() throws {
        let scopeA = try #require(BrowserEndedOwnershipScope(
            accountID: "account-a", gatewayURL: "https://one.example.com"
        ))
        let accountB = try #require(BrowserEndedOwnershipScope(
            accountID: "account-b", gatewayURL: "https://one.example.com"
        ))
        let gatewayB = try #require(BrowserEndedOwnershipScope(
            accountID: "account-a", gatewayURL: "https://two.example.com"
        ))

        let encoded = BrowserEndedOwnershipLedger.recording(
            owner: "chat-a", for: scopeA, in: ""
        )

        #expect(BrowserEndedOwnershipLedger.owner(for: scopeA, in: encoded) == "chat-a")
        #expect(BrowserEndedOwnershipLedger.owner(for: accountB, in: encoded) == nil)
        #expect(BrowserEndedOwnershipLedger.owner(for: gatewayB, in: encoded) == nil)
        #expect(BrowserEndedOwnershipLedger.owner(for: scopeA, in: "malformed") == nil)
    }

    @Test func revivingOneScopeDeletesOnlyItsOwnReceipt() throws {
        let scopeA = try #require(BrowserEndedOwnershipScope(
            accountID: "account-a", gatewayURL: "https://one.example.com"
        ))
        let scopeB = try #require(BrowserEndedOwnershipScope(
            accountID: "account-b", gatewayURL: "https://one.example.com"
        ))
        var encoded = BrowserEndedOwnershipLedger.recording(owner: "chat-a", for: scopeA, in: "")
        encoded = BrowserEndedOwnershipLedger.recording(owner: "chat-b", for: scopeB, in: encoded)

        encoded = BrowserEndedOwnershipLedger.recording(owner: nil, for: scopeA, in: encoded)

        #expect(BrowserEndedOwnershipLedger.owner(for: scopeA, in: encoded) == nil)
        #expect(BrowserEndedOwnershipLedger.owner(for: scopeB, in: encoded) == "chat-b")
    }

    @Test func changingAuthenticatedScopeClearsRuntimeBeforeRestoringNewScope() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = RecordingBrowserTransport()
        let session = BrowserLiveSession(makeTransport: { transport })
        let coordinator = BrowserViewCoordinator(session: session, defaults: defaults)

        coordinator.activateAuthenticatedScope(
            accountID: "account-a", gatewayURL: "https://one.example.com"
        )
        session.noteBrowsingConversation("chat-a")
        session.present()
        session.takeControl()

        coordinator.activateAuthenticatedScope(
            accountID: "account-b", gatewayURL: "https://one.example.com"
        )

        #expect(transport.didDisconnect)
        #expect(session.phase == .idle)
        #expect(!session.isPresented)
        #expect(!session.isControlling)
        #expect(session.lastConversationKey == nil)
        #expect(session.endedConversationKeys.isEmpty)
        #expect(session.userEndedConversationKeys.isEmpty)
        #expect(session.browserRunEvidences(for: "chat-a").isEmpty)
    }

    @Test func explicitRootTeardownRetainsReceiptWithoutWakingEndedBrowser() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = RecordingBrowserTransport()
        let session = BrowserLiveSession(makeTransport: { transport })
        let coordinator = BrowserViewCoordinator(session: session, defaults: defaults)

        coordinator.activateAuthenticatedScope(
            accountID: "account-a", gatewayURL: "https://one.example.com"
        )
        session.noteBrowsingConversation("chat-a")
        session.markSessionEnded()
        session.presentEnded()
        coordinator.terminateAuthenticatedSession()

        #expect(!transport.didConnect)
        #expect(!session.isPresented)
        #expect(session.lastConversationKey == nil)

        let restoredDefaults = try #require(UserDefaults(suiteName: suite))
        let restored = BrowserViewCoordinator(session: makeSession(), defaults: restoredDefaults)
        restored.activateAuthenticatedScope(
            accountID: "account-a", gatewayURL: "https://one.example.com"
        )
        #expect(restored.session.lastConversationKey == "chat-a")
        #expect(restored.session.hasEnded)
    }

    @Test func teardownInvalidatesDelayedEndBeforeNewScopeStartsLocalRun() async {
        let session = makeSession()
        session.beginBrowserRun(for: "shared-chat", browserRequested: true)
        session.endBrowserRunEnsuringPresentation(
            for: "shared-chat",
            runID: nil,
            minimumVisibilityNanoseconds: 10_000_000
        )

        session.terminateAuthenticatedSession()
        session.beginBrowserRun(for: "shared-chat", browserRequested: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(session.browserRunEvidences(for: "shared-chat")
            .contains { $0.supportsLiveCard })
    }

    private func makeSession() -> BrowserLiveSession {
        BrowserLiveSession(makeTransport: { nil })
    }

    private func waitForHandBackToSettle(_ session: BrowserLiveSession) async {
        for _ in 0..<100 where session.isHandBackPending {
            await Task.yield()
        }
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "BrowserLifecyclePersistenceTests.\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suite)), suite)
    }
}

@Suite("Cloud browser settings loading contract")
@MainActor
struct CloudBrowserSettingsLoadingContractTests {
    @Test func initialRequestUsesSkeletonUntilAuthoritativePolicyArrives() {
        #expect(CloudBrowserSettingsLoadPresentation.resolve(
            isLoading: true, hasLoadedPolicy: false, hasError: false
        ) == .skeleton)
        #expect(CloudBrowserSettingsLoadPresentation.resolve(
            isLoading: false, hasLoadedPolicy: true, hasError: false
        ) == .content)
    }

    @Test func initialFailureNeverPresentsDefaultOpenStateAsAuthoritative() {
        #expect(CloudBrowserSettingsLoadPresentation.resolve(
            isLoading: false, hasLoadedPolicy: false, hasError: true
        ) == .failure)
    }

    @Test func refreshKeepsPreviouslyLoadedLayoutVisible() {
        #expect(CloudBrowserSettingsLoadPresentation.resolve(
            isLoading: true, hasLoadedPolicy: true, hasError: false
        ) == .content)
        #expect(CloudBrowserSettingsLoadPresentation.resolve(
            isLoading: false, hasLoadedPolicy: true, hasError: true
        ) == .content)
    }
}

@MainActor
private final class RecordingBrowserTransport: BrowserFrameTransport {
    private(set) var didConnect = false
    private(set) var didDisconnect = false

    func connect(
        onMessage _: @escaping (BrowserWireMessage) -> Void,
        onClose _: @escaping (Error?) -> Void
    ) {
        didConnect = true
    }

    func send(_: Data) {}

    func disconnect() {
        didDisconnect = true
    }
}
