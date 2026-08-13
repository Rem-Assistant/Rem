import Testing
@testable import RemClawMac

@MainActor
struct MacRouterChatRoutingTests {
    @Test func newChatAlwaysMintsFreshGeneralRoute() {
        let router = MacRouter()
        router.startNewChat()

        #expect(router.selectedScreen == .chat)
        #expect(router.pendingSessionKey?.hasPrefix("chat-") == true)
        #expect(router.pendingSessionIsFresh)
    }

    @Test func sessionsRowKeepsSelectedExistingSession() {
        let router = MacRouter()
        router.openSession("agent:main:existing")

        #expect(router.selectedScreen == .chat)
        #expect(router.pendingSessionKey == "agent:main:existing")
        #expect(!router.pendingSessionIsFresh)
    }
}
