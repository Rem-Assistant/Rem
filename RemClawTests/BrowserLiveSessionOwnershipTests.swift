import Foundation
import Testing
@testable import RemClaw

/// Ownership + sticky-ended lifecycle for the in-chat "Rem's browser session" card.
///
/// There is exactly ONE cloud browser per gateway, so its retained frame/URL/ended-state belong to
/// one conversation at a time. These tests pin the two founder-reported invariants:
///   1. Once a conversation's session has ENDED it is STICKY per conversation — re-entering (noting
///      it as owner again) must never silently un-end it, so the card can't re-animate to LIVE.
///   2. A different conversation taking the single browser starts fresh (not-ended) and does NOT
///      clear the previous owner's ended marker (per-conversation, not a global bool).
@MainActor
struct BrowserLiveSessionOwnershipTests {
    private func makeSession() -> BrowserLiveSession {
        // No transport: these tests exercise pure ownership/ended state, never streaming.
        BrowserLiveSession(makeTransport: { nil })
    }

    @Test func endingAConversationIsStickyAcrossReEntry() {
        let session = makeSession()

        session.noteBrowsingConversation("A")
        session.markSessionEnded()
        #expect(session.hasEnded)
        #expect(session.endedConversationKeys.contains("A"))

        // Re-entering the same chat (owner noted again) must keep it ended — this is exactly the
        // re-open path that used to re-animate "Rem is using a browser".
        session.noteBrowsingConversation("A")
        #expect(session.hasEnded)
        #expect(session.endedConversationKeys.contains("A"))
    }

    @Test func differentConversationTakesBrowserFreshAndKeepsPriorEndSticky() {
        let session = makeSession()

        session.noteBrowsingConversation("A")
        session.markSessionEnded()

        // B takes the single browser: it becomes the owner and starts NOT ended...
        session.noteBrowsingConversation("B")
        #expect(session.lastConversationKey == "B")
        #expect(!session.hasEnded)
        // ...and A's ended marker survives (per-conversation, not a global flag).
        #expect(session.endedConversationKeys.contains("A"))

        // Switching ownership back to A still reads as ended (sticky).
        session.noteBrowsingConversation("A")
        #expect(session.hasEnded)
    }

    @Test func ownerLifecycleTicketDistinguishesABAFromUnchangedOwnership() {
        let session = makeSession()

        session.noteBrowsingConversation("A")
        let firstATicket = session.browserOwnerLifecycleTicket
        session.noteBrowsingConversation("A")
        #expect(session.browserOwnerLifecycleTicket == firstATicket)

        session.noteBrowsingConversation("B")
        session.noteBrowsingConversation("A")
        #expect(session.lastConversationKey == "A")
        #expect(session.browserOwnerLifecycleTicket == firstATicket + 2)
    }

    @Test func firstLiveEvidenceClaimsOwnershipBeforeTheCardCanRender() {
        let session = makeSession()
        session.noteBrowsingConversation("A")

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "B",
            runID: "run-b",
            toolCallID: "navigate-b",
            toolName: "browser",
            action: "navigate"
        ))

        #expect(session.lastConversationKey == "B")
    }

    @Test func newBrowsingRevivesTheOwnersEndedCard() {
        let session = makeSession()

        session.noteBrowsingConversation("A")
        session.markSessionEnded()
        #expect(session.hasEnded)

        // A genuinely new browse in the SAME chat clears its ended marker so the live card returns.
        session.noteAgentBrowsing()
        #expect(!session.hasEnded)
        #expect(!session.endedConversationKeys.contains("A"))
    }

    @Test func userEndIsAHardMarkerClearedOnNewRunSoAReBrowseCanRevive() {
        let session = makeSession()
        session.noteBrowsingConversation("A")

        session.endByUser()
        #expect(session.userEndedConversationKeys.contains("A")) // hard suppress for the live gate
        #expect(session.hasEnded)                                // + soft-frozen for the review sheet

        // The authoritative begin-run edge lifts ONLY the hard user-End...
        session.beginBrowserRun(for: "A")
        #expect(!session.userEndedConversationKeys.contains("A"))
        #expect(session.hasEnded) // ...the actual ended marker stands until browsing resumes

        // ...and browsing actually resuming clears the soft freeze too.
        session.noteAgentBrowsing()
        #expect(!session.hasEnded)
    }

    @Test func revivingOneConversationDoesNotUnendAnother() {
        let session = makeSession()

        session.noteBrowsingConversation("A")
        session.markSessionEnded()
        session.noteBrowsingConversation("B")
        session.markSessionEnded()
        #expect(session.endedConversationKeys.contains("A"))
        #expect(session.endedConversationKeys.contains("B"))

        // Reviving the current owner (B) must not touch A's ended state.
        session.noteAgentBrowsing()
        #expect(!session.endedConversationKeys.contains("B"))
        #expect(session.endedConversationKeys.contains("A"))
    }

    @Test func runCompletionDoesNotEndAnOpenBrowserSession() {
        let session = makeSession()
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A",
            runID: "run-a",
            toolCallID: "navigate-a",
            toolName: "browser",
            action: "navigate"
        ))

        session.endBrowserRun(for: "A", runID: "run-a")

        #expect(session.lastConversationKey == "A")
        #expect(!session.hasEnded)
        #expect(session.browserRunEvidences(for: "A").contains { $0.containsBrowserActivity })
    }

    @Test func dismissingViewerPreservesActiveSessionAndTakeover() {
        var transportsCreated = 0
        let session = BrowserLiveSession(makeTransport: {
            transportsCreated += 1
            return BrowserLifecycleTestTransport()
        })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A",
            runID: "run-a",
            toolCallID: "navigate-a",
            toolName: "browser",
            action: "navigate"
        ))
        session.present()
        session.takeControl()

        session.dismissViewer()

        #expect(!session.isPresented)
        #expect(!session.hasEnded)
        #expect(session.isControlling)
        #expect(session.phase == .idle)
        #expect(transportsCreated == 1)

        session.present()
        #expect(session.isPresented)
        #expect(session.isControlling)
        #expect(transportsCreated == 2)
    }

    @Test func endedPresentationNeverCreatesATransportEvenThroughStaleLiveEntryPoint() {
        var transportsCreated = 0
        let session = BrowserLiveSession(makeTransport: {
            transportsCreated += 1
            return BrowserLifecycleTestTransport()
        })
        session.noteBrowsingConversation("A")
        session.markSessionEnded()

        session.presentEnded()
        #expect(session.isPresented)
        #expect(session.hasEnded)
        #expect(transportsCreated == 0)

        session.dismissViewer()
        session.present() // stale live-card action must fail closed into ended review
        #expect(session.isPresented)
        #expect(session.hasEnded)
        #expect(transportsCreated == 0)
    }

    @Test func duplicateAgentCloseEventsProduceOneEndedTransition() {
        let session = makeSession()
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A",
            runID: "run-a",
            toolCallID: "navigate-a",
            toolName: "browser",
            action: "navigate"
        ))
        var endedOwners: [String?] = []
        session.onEndedOwnershipChanged = { endedOwners.append($0) }

        for toolCallID in ["stop-a", "stop-a-duplicate"] {
            session.recordBrowserToolActivity(BrowserToolActivity(
                sessionKey: "A",
                runID: "run-a",
                toolCallID: toolCallID,
                toolName: "browser",
                action: "stop"
            ))
        }

        #expect(session.hasEnded)
        #expect(endedOwners.count == 1)
        #expect(endedOwners.first! == "A")
    }

    @Test func lateBrowserEventFromUserEndedRunCannotReopenSession() {
        let session = makeSession()
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-a", toolCallID: "navigate-a",
            toolName: "browser", action: "navigate"
        ))
        session.endByUser()

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-a", toolCallID: "late-navigate-a",
            toolName: "browser", action: "navigate"
        ))

        #expect(session.hasEnded)
        #expect(session.userEndedConversationKeys.contains("A"))
        #expect(!session.browserRunEvidences(for: "A").contains { $0.supportsLiveCard })
    }

    @Test func freshRunCanReopenAfterUserEnd() {
        let session = makeSession()
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-a", toolCallID: "navigate-a",
            toolName: "browser", action: "navigate"
        ))
        session.endByUser()

        session.beginBrowserRun(for: "A")
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-b", toolCallID: "navigate-b",
            toolName: "browser", action: "navigate"
        ))

        #expect(!session.hasEnded)
        #expect(!session.userEndedConversationKeys.contains("A"))
        #expect(session.browserRunEvidences(for: "A").contains { $0.supportsLiveCard })
    }

    @Test func lateEndedRunEventStaysBlockedAfterFreshRunBegins() {
        let session = makeSession()
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-a", toolCallID: "navigate-a",
            toolName: "browser", action: "navigate"
        ))
        session.endByUser()
        session.beginBrowserRun(for: "A")

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-a", toolCallID: "late-navigate-a",
            toolName: "browser", action: "navigate"
        ))
        #expect(session.hasEnded)

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-b", toolCallID: "navigate-b",
            toolName: "browser", action: "navigate"
        ))
        #expect(!session.hasEnded)
    }

    @Test func closeFirstClaimsItsConversationAndEndsIt() {
        let session = makeSession()

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "B", runID: "run-b", toolCallID: "close-b",
            toolName: "browser", action: "close"
        ))

        #expect(session.lastConversationKey == "B")
        #expect(session.hasEnded)
        #expect(session.endedConversationKeys == ["B"])
    }

    @Test func crossOwnerCloseEndsTheTeardownConversationNotPriorOwner() {
        var transportsCreated = 0
        let session = BrowserLiveSession(makeTransport: {
            transportsCreated += 1
            return BrowserLifecycleTestTransport()
        })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "A", runID: "run-a", toolCallID: "navigate-a",
            toolName: "browser", action: "navigate"
        ))
        session.present()

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "B", runID: "run-b", toolCallID: "close-b",
            toolName: "browser", action: "close"
        ))

        #expect(session.lastConversationKey == "B")
        #expect(session.hasEnded)
        #expect(session.endedConversationKeys.contains("B"))
        #expect(!session.endedConversationKeys.contains("A"))
        #expect(transportsCreated == 1) // teardown ownership never starts a B viewer
    }

    @Test func dismissingViewerDoesNotCancelPendingHandBack() async {
        let session = makeSession()
        session.noteBrowsingConversation("A")
        session.takeControl()
        var controlIntents: [Bool] = []
        session.onControlIntentChanged = { controlIntents.append($0) }
        session.onRequestHandBack = {
            try? await Task.sleep(for: .milliseconds(20))
            return .authorized
        }

        session.handBack()
        #expect(session.isHandBackPending)
        session.dismissViewer()
        #expect(session.isHandBackPending)

        try? await Task.sleep(for: .milliseconds(100))
        #expect(!session.isHandBackPending)
        #expect(!session.isControlling)
        #expect(controlIntents == [false])
    }
}

@MainActor
private final class BrowserLifecycleTestTransport: BrowserFrameTransport {
    func connect(
        onMessage: @escaping (BrowserWireMessage) -> Void,
        onClose: @escaping (Error?) -> Void
    ) {}

    func send(_ data: Data) {}
    func disconnect() {}
}
