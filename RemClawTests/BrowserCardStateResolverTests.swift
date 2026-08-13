import Foundation
import Testing
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
@testable import RemClaw

/// Pure decision tests for the in-chat browser card. An owned browser stays active across agent-run
/// completion; only explicit user/agent teardown moves it to the ended review presentation.
struct BrowserCardStateResolverTests {
    // MARK: message builders

    private func userMessage(_ text: String) -> OpenClawChatMessage {
        OpenClawChatMessage(
            role: "user",
            content: [OpenClawChatMessageContent(type: "text", text: text, mimeType: nil, fileName: nil, content: nil)],
            timestamp: nil)
    }

    private func assistantText(_ text: String) -> OpenClawChatMessage {
        OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(type: "text", text: text, mimeType: nil, fileName: nil, content: nil)],
            timestamp: nil)
    }

    /// An assistant tool-call message, e.g. `browser navigate` / `browser stop` / `browser status`.
    private func toolCall(
        _ tool: String,
        _ action: String,
        id: String = "call"
    ) -> OpenClawChatMessage {
        let item = OpenClawChatMessageContent(
            type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil,
            id: id, name: tool, arguments: AnyCodable(["action": action]))
        return OpenClawChatMessage(role: "assistant", content: [item], timestamp: nil)
    }

    // MARK: - Owned active session survives run completion

    @Test func ownedSessionWithUnclosedNavigateStaysLiveWithoutAnAgentRun() {
        let history = [
            userMessage("open example.com"),
            toolCall("browser", "navigate"),
            assistantText("Here's the page."),
        ]
        let state = BrowserCardStateResolver.resolve(
            messages: history, pendingRunCount: 0, isOwner: true, isSessionEnded: false)
        #expect(state == .live)
    }

    @Test func switchIntoNonOwnerChatWithBrowserHistoryShowsNothing() {
        let history = [userMessage("open example.com"), toolCall("browser", "navigate")]
        let state = BrowserCardStateResolver.resolve(
            messages: history, pendingRunCount: 0, isOwner: false, isSessionEnded: false)
        #expect(state == .none)
    }

    // MARK: - Genuinely live in the current chat

    @Test func activeRunBrowsingInCurrentTurnIsLive() {
        let messages = [
            userMessage("open example.com"),
            toolCall("browser", "navigate"),
        ]
        let state = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 1, isOwner: true, isSessionEnded: false)
        #expect(state == .live)
    }

    @Test func liveToolEventShowsCardBeforeBrowserCallReachesHistory() {
        let messages = [userMessage("open example.com")]
        var evidence = BrowserRunEvidence()
        evidence.begin(sessionKey: "chat-browser")
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser",
            toolCallID: "browser-1",
            toolName: "browser",
            action: "navigate"))

        let state = BrowserCardStateResolver.resolve(
            messages: messages,
            pendingRunCount: 1,
            isOwner: false,
            isSessionEnded: false,
            activeRunEvidence: evidence)
        #expect(state == .live)
    }

    @Test func everyActiveBrowserActionShowsCardBeforeHistoryArrives() {
        for action in ["tabs", "status", "snapshot", "act"] {
            var evidence = BrowserRunEvidence()
            evidence.begin(sessionKey: "chat-browser")
            evidence.record(BrowserToolActivity(
                sessionKey: "chat-browser",
                toolCallID: "browser-\(action)",
                toolName: "browser",
                action: action))

            #expect(evidence.supportsLiveCard, "Expected browser action \(action) to show the live card")
        }
    }

    @Test func browserStartWithoutDecodedActionStillShowsCard() {
        var evidence = BrowserRunEvidence()
        evidence.begin(sessionKey: "chat-browser")
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser",
            toolCallID: "browser-unknown",
            toolName: "browser",
            action: nil))

        #expect(evidence.supportsLiveCard)
    }

    @Test func terminalStructuredBrowserEvidenceKeepsActiveCardWhenHistoryOmitsToolRow() {
        let messages = [
            userMessage("open example.com"),
            assistantText("Done — Example Domain."),
        ]
        var evidence = BrowserRunEvidence()
        evidence.begin(sessionKey: "chat-browser", runID: "run-browser")
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser",
            runID: "run-browser",
            toolCallID: "browser-1",
            toolName: "browser",
            action: "navigate"))
        evidence.end(sessionKey: "chat-browser", runID: "run-browser")

        #expect(BrowserCardStateResolver.resolve(
            messages: messages,
            pendingRunCount: 0,
            isOwner: true,
            isSessionEnded: false,
            activeRunEvidence: evidence) == .live)
        let fallbackAnchor = SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: messages,
            baselineMessageID: messages.first?.id,
            baselineMessageIndex: messages.indices.first,
            baselineMessageSignature: messages.first.map(
                SharedRemChatView.browserTranscriptBoundarySignature),
            existingResolvedMessageID: nil,
            evidenceIsLive: false)
        #expect(SharedRemChatView.browserAnchorMessageID(
            messages: messages,
            activeRunEvidences: [evidence],
            structuredResolvedAnchor: fallbackAnchor) == fallbackAnchor)

        let unrelatedUser = userMessage("unrelated")
        let unrelatedAnswer = assistantText("A later unrelated answer")
        let laterMessages = messages + [unrelatedUser, unrelatedAnswer]
        let frozenAnchor = SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: laterMessages,
            baselineMessageID: messages.first?.id,
            baselineMessageIndex: messages.indices.first,
            baselineMessageSignature: messages.first.map(
                SharedRemChatView.browserTranscriptBoundarySignature),
            existingResolvedMessageID: fallbackAnchor,
            evidenceIsLive: false)
        #expect(frozenAnchor == fallbackAnchor)
        #expect(SharedRemChatView.browserAnchorMessageID(
            messages: laterMessages,
            activeRunEvidences: [evidence],
            structuredResolvedAnchor: frozenAnchor) == fallbackAnchor)

        let olderBrowserRow = toolCall("browser", "navigate")
        let historyWithOlderBrowser = [userMessage("older browse"), olderBrowserRow] + messages
        #expect(SharedRemChatView.browserAnchorMessageID(
            messages: historyWithOlderBrowser,
            activeRunEvidences: [evidence],
            structuredResolvedAnchor: fallbackAnchor) == fallbackAnchor)

        let priorMessages = [userMessage("prior"), assistantText("prior answer")]
        let externalBaseline = priorMessages.last?.id
        #expect(SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: priorMessages,
            baselineMessageID: externalBaseline,
            baselineMessageIndex: priorMessages.indices.last,
            baselineMessageSignature: priorMessages.last.map(
                SharedRemChatView.browserTranscriptBoundarySignature),
            existingResolvedMessageID: nil,
            evidenceIsLive: true) == nil)
        let externalUser = userMessage("external browse")
        let externalAnswer = assistantText("external browser answer")
        let refreshedMessages = priorMessages + [externalUser, externalAnswer]
        #expect(SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: refreshedMessages,
            baselineMessageID: externalBaseline,
            baselineMessageIndex: priorMessages.indices.last,
            baselineMessageSignature: priorMessages.last.map(
                SharedRemChatView.browserTranscriptBoundarySignature),
            existingResolvedMessageID: nil,
            evidenceIsLive: false) == externalAnswer.id)

        let olderBaselineBrowserRow = toolCall("browser", "navigate", id: "older-browser")
        let priorEndingInBrowser = [userMessage("older browser turn"), olderBaselineBrowserRow]
        let olderBrowserSignature = SharedRemChatView.browserTranscriptBoundarySignature(
            olderBaselineBrowserRow)
        let newExternalUser = userMessage("new external browser turn")
        let newExternalAnswer = assistantText("new external answer")
        let newExternalHistory = priorEndingInBrowser + [newExternalUser, newExternalAnswer]
        #expect(SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: newExternalHistory,
            baselineMessageID: olderBaselineBrowserRow.id,
            baselineMessageIndex: priorEndingInBrowser.indices.last,
            baselineMessageSignature: olderBrowserSignature,
            existingResolvedMessageID: nil,
            evidenceIsLive: false,
            structuredToolCallIDs: ["new-browser"]) == newExternalAnswer.id)

        let newExactBrowserRow = toolCall("browser", "navigate", id: "new-browser")
        let newExternalHistoryWithExact = priorEndingInBrowser
            + [newExternalUser, newExactBrowserRow, newExternalAnswer]
        #expect(SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: newExternalHistoryWithExact,
            baselineMessageID: olderBaselineBrowserRow.id,
            baselineMessageIndex: priorEndingInBrowser.indices.last,
            baselineMessageSignature: olderBrowserSignature,
            existingResolvedMessageID: nil,
            evidenceIsLive: false,
            structuredToolCallIDs: ["new-browser"]) == newExactBrowserRow.id)

        let optimisticUser = userMessage("replace my id")
        let optimisticMessages = priorMessages + [optimisticUser]
        let replacedUser = userMessage("replace my id")
        let replacementAnswer = assistantText("browser answer after reconciliation")
        let reconciledMessages = priorMessages + [replacedUser, replacementAnswer]
        let optimisticSignature = SharedRemChatView.browserTranscriptBoundarySignature(
            optimisticUser)
        #expect(SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: reconciledMessages,
            baselineMessageID: optimisticUser.id,
            baselineMessageIndex: optimisticMessages.indices.last,
            baselineMessageSignature: optimisticSignature,
            existingResolvedMessageID: nil,
            evidenceIsLive: false) == replacementAnswer.id)

        let replacementBrowserRow = toolCall("browser", "navigate")
        let reconciledWithExact = priorMessages
            + [replacedUser, replacementBrowserRow, replacementAnswer]
        #expect(SharedRemChatView.resolveStructuredBrowserAnchor(
            messages: reconciledWithExact,
            baselineMessageID: optimisticUser.id,
            baselineMessageIndex: optimisticMessages.indices.last,
            baselineMessageSignature: optimisticSignature,
            existingResolvedMessageID: nil,
            evidenceIsLive: false) == replacementBrowserRow.id)
    }

    @Test func requestedOnlyEvidenceDoesNotManufactureReviewCard() {
        let messages = [userMessage("hello")]
        var evidence = BrowserRunEvidence()
        evidence.markBrowserRequested(sessionKey: "chat-browser", runID: "run-browser")
        evidence.end(sessionKey: "chat-browser", runID: "run-browser")

        #expect(BrowserCardStateResolver.resolve(
            messages: messages,
            pendingRunCount: 0,
            isOwner: false,
            isSessionEnded: false,
            activeRunEvidence: evidence) == .none)
        #expect(SharedRemChatView.browserAnchorMessageID(
            messages: messages,
            activeRunEvidences: [evidence]) == nil)
    }

    @Test func externalRunEvidenceShowsCardWithoutLocalPendingRunUntilTerminal() {
        let messages = [userMessage("open example.com")]
        var evidence = BrowserRunEvidence()
        evidence.begin(sessionKey: "chat-browser", runID: "voice-run")
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser",
            runID: "voice-run",
            toolCallID: "browser-1",
            toolName: "browser",
            action: "navigate"))
        #expect(evidence.supportsLiveCard)

        // Voice and cross-device runs are not inserted into this view model's pending-run set.
        #expect(BrowserCardStateResolver.resolve(
            messages: messages,
            pendingRunCount: 0,
            isOwner: false,
            isSessionEnded: false,
            activeRunEvidence: evidence) == .live)

        evidence.end(sessionKey: "chat-browser", runID: "voice-run")
        #expect(BrowserCardStateResolver.resolve(
            messages: messages,
            pendingRunCount: 0,
            isOwner: false,
            isSessionEnded: false,
            activeRunEvidence: evidence) == .none)
    }

    @MainActor
    @Test func transportEvidenceSurvivesStartAndResultBeforeRender() throws {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.beginBrowserRun(for: "chat-browser")
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser",
            toolCallID: "browser-1",
            toolName: "browser",
            action: "navigate"))

        // A result intentionally does not erase the transport latch. The pending-tool projection may
        // already be empty by the first render; the evidence remains authoritative for this run.
        let evidence = try #require(session.browserRunEvidences(for: "chat-browser").first)
        #expect(evidence.supportsLiveCard)
        #expect(BrowserCardStateResolver.resolve(
            messages: [userMessage("open example.com")],
            pendingRunCount: 1,
            isOwner: false,
            isSessionEnded: false,
            activeRunEvidence: evidence) == .live)

        session.beginBrowserRun(for: "chat-next-run")
        let nextRunHasLiveEvidence = session.browserRunEvidences(for: "chat-next-run")
            .contains { evidence in evidence.supportsLiveCard }
        #expect(!nextRunHasLiveEvidence)
    }

    @MainActor
    @Test func cloudBrowserAttachmentShowsLiveCardBeforeFirstToolEvent() throws {
        let session = BrowserLiveSession(makeTransport: { nil })

        session.beginBrowserRun(for: "chat-browser", browserRequested: true)

        let evidence = try #require(session.browserRunEvidences(for: "chat-browser").first)
        #expect(evidence.supportsLiveCard)
        #expect(!evidence.supportsOwnershipClaim)
        #expect(session.lastConversationKey == nil)
        #expect(!BrowserCardStateResolver.canPresentLiveBrowser(
            messages: [userMessage("open example.com")],
            pendingRunCount: 1,
            activeRunEvidences: [evidence]))
        #expect(BrowserCardStateResolver.resolve(
            messages: [userMessage("open example.com")],
            pendingRunCount: 1,
            isOwner: true,
            isSessionEnded: false,
            activeRunEvidence: evidence) == .live)
    }

    @Test func realBrowserToolEvidenceEnablesPresentationForCurrentRun() {
        var evidence = BrowserRunEvidence()
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-1", toolCallID: "tabs-1",
            toolName: "browser", action: "tabs"))

        #expect(BrowserCardStateResolver.canPresentLiveBrowser(
            messages: [userMessage("open example.com")],
            pendingRunCount: 0,
            activeRunEvidences: [evidence]))
    }

    @MainActor
    @Test func cloudBrowserAttachmentDoesNotStealExistingOwnerBeforeToolStart() {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.noteBrowsingConversation("chat-a")

        session.beginBrowserRun(for: "chat-b", browserRequested: true)

        #expect(session.lastConversationKey == "chat-a")
        session.cancelPendingBrowserRun(for: "chat-b")
        #expect(session.lastConversationKey == "chat-a")
    }

    @Test func liveStopEventEndsCardWithinActiveRun() {
        let messages = [userMessage("open example.com"), toolCall("browser", "navigate")]
        var evidence = BrowserRunEvidence()
        evidence.begin(sessionKey: "chat-browser", runID: "run-1")
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser",
            runID: "run-1",
            toolCallID: "browser-open",
            toolName: "browser",
            action: "navigate"))
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser",
            runID: "run-1",
            toolCallID: "browser-stop",
            toolName: "browser",
            action: "stop"))
        #expect(!evidence.supportsLiveCard)
        #expect(BrowserCardStateResolver.resolve(
            messages: messages,
            pendingRunCount: 1,
            isOwner: true,
            isSessionEnded: true,
            activeRunEvidence: evidence) == .ended)

        // A read-only status arriving after teardown in the same run must not reopen stale history.
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser",
            runID: "run-1",
            toolCallID: "browser-status",
            toolName: "browser",
            action: "status"))
        #expect(!evidence.supportsLiveCard)

        // Terminal delivery can reach BrowserLiveSession before the view model decrements its
        // pending-run count. Closed disposition remains authoritative during that handoff.
        evidence.end(sessionKey: "chat-browser", runID: "run-1")
        #expect(BrowserCardStateResolver.resolve(
            messages: messages,
            pendingRunCount: 1,
            isOwner: true,
            isSessionEnded: true,
            activeRunEvidence: evidence) == .ended)
    }

    @Test func aNewRunCanReopenAfterThePreviousRunClosed() {
        var evidence = BrowserRunEvidence()
        evidence.begin(sessionKey: "chat-browser", runID: "run-1")
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-1", toolCallID: "close-1",
            toolName: "browser", action: "close"))
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-2", toolCallID: "tabs-2",
            toolName: "browser", action: "tabs"))

        #expect(evidence.runID == "run-2")
        #expect(evidence.supportsLiveCard)
    }

    @Test func terminalFromOlderRunDoesNotEndNewerRun() {
        var evidence = BrowserRunEvidence()
        evidence.begin(sessionKey: "chat-browser", runID: "run-1")
        evidence.record(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-2", toolCallID: "tabs-2",
            toolName: "browser", action: "tabs"))

        evidence.end(sessionKey: "chat-browser", runID: "run-1")

        #expect(evidence.runID == "run-2")
        #expect(evidence.supportsLiveCard)
    }

    @MainActor
    @Test func overlappingRunTerminationDoesNotEndTheBrowserSession() {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-a", toolCallID: "navigate-a",
            toolName: "browser", action: "navigate"))
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-b", toolCallID: "tabs-b",
            toolName: "browser", action: "tabs"))
        var anchorState = session.browserTranscriptAnchorState(for: "chat-browser")
        #expect(anchorState?.runID == "run-b")
        #expect(anchorState?.structuredToolCallIDs == ["tabs-b"])
        #expect(anchorState?.runIsActive == true)

        session.endBrowserRun(for: "chat-browser", runID: "run-b")
        var evidences = session.browserRunEvidences(for: "chat-browser")
        anchorState = session.browserTranscriptAnchorState(for: "chat-browser")
        #expect(anchorState?.runID == "run-b")
        #expect(anchorState?.structuredToolCallIDs == ["tabs-b"])
        #expect(anchorState?.runIsActive == false)
        #expect(evidences.filter { evidence in evidence.supportsLiveCard }.count == 1)
        #expect(BrowserCardStateResolver.resolve(
            messages: [userMessage("browse"), toolCall("browser", "navigate")],
            pendingRunCount: 0,
            isOwner: true,
            isSessionEnded: false,
            activeRunEvidences: evidences) == .live)

        session.endBrowserRun(for: "chat-browser", runID: "run-a")
        evidences = session.browserRunEvidences(for: "chat-browser")
        anchorState = session.browserTranscriptAnchorState(for: "chat-browser")
        #expect(anchorState?.runID == "run-b")
        #expect(anchorState?.structuredToolCallIDs == ["tabs-b"])
        #expect(!evidences.contains { evidence in evidence.supportsLiveCard })
        #expect(BrowserCardStateResolver.resolve(
            messages: [userMessage("browse"), toolCall("browser", "navigate")],
            pendingRunCount: 1,
            isOwner: true,
            isSessionEnded: session.hasEnded,
            activeRunEvidences: evidences) == .live)
    }

    @MainActor
    @Test func ordinaryTerminalRunRetiresUntouchedLocalPlaceholder() {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.beginBrowserRun(for: "chat-browser")

        session.endBrowserRun(for: "chat-browser", runID: "non-browser-run")

        #expect(session.browserRunEvidences(for: "chat-browser").isEmpty)
    }

    @MainActor
    @Test func failedSendCancelsOnlyItsLocalPlaceholder() {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "voice-run", toolCallID: "navigate-voice",
            toolName: "browser", action: "navigate"))
        session.beginBrowserRun(for: "chat-browser")

        session.cancelPendingBrowserRun(for: "chat-browser")

        let evidences = session.browserRunEvidences(for: "chat-browser")
        #expect(evidences.count == 1)
        #expect(evidences[0].runID == "voice-run")
        #expect(evidences[0].supportsLiveCard)
    }

    @MainActor
    @Test func teardownFromOneOverlappingRunClosesTheSharedBrowser() {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-a", toolCallID: "navigate-a",
            toolName: "browser", action: "navigate"))
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-b", toolCallID: "stop-b",
            toolName: "browser", action: "stop"))

        var evidences = session.browserRunEvidences(for: "chat-browser")
        #expect(!evidences.contains { evidence in evidence.supportsLiveCard })
        #expect(BrowserCardStateResolver.resolve(
            messages: [userMessage("browse"), toolCall("browser", "navigate")],
            pendingRunCount: 1,
            isOwner: true,
            isSessionEnded: session.hasEnded,
            activeRunEvidences: evidences) == .ended)

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-a", toolCallID: "status-a",
            toolName: "browser", action: "status"))
        #expect(!session.browserRunEvidences(for: "chat-browser")
            .contains { evidence in evidence.supportsLiveCard })

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-a", toolCallID: "reopen-a",
            toolName: "browser", action: "navigate"))
        evidences = session.browserRunEvidences(for: "chat-browser")
        #expect(evidences.contains { evidence in evidence.supportsLiveCard })
    }

    @MainActor
    @Test func localNextRunReadOnlyActionDoesNotReopenClosedBrowser() {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-1", toolCallID: "navigate-1",
            toolName: "browser", action: "navigate"))
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-1", toolCallID: "stop-1",
            toolName: "browser", action: "stop"))
        session.endBrowserRun(for: "chat-browser", runID: "run-1")

        session.beginBrowserRun(for: "chat-browser")
        #expect(!session.browserRunEvidences(for: "chat-browser")
            .contains { evidence in evidence.supportsLiveCard })

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-2", toolCallID: "status-2",
            toolName: "browser", action: "status"))
        #expect(!session.browserRunEvidences(for: "chat-browser")
            .contains { evidence in evidence.supportsLiveCard })

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-2", toolCallID: "navigate-2",
            toolName: "browser", action: "navigate"))
        #expect(session.browserRunEvidences(for: "chat-browser")
            .contains { evidence in evidence.supportsLiveCard })
    }

    @MainActor
    @Test func externalNextRunReadOnlyActionDoesNotReopenClosedBrowser() {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-1", toolCallID: "navigate-1",
            toolName: "browser", action: "navigate"))
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-1", toolCallID: "close-1",
            toolName: "browser", action: "close"))
        session.endBrowserRun(for: "chat-browser", runID: "run-1")

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-2", toolCallID: "tabs-2",
            toolName: "browser", action: "tabs"))
        #expect(!session.browserRunEvidences(for: "chat-browser")
            .contains { evidence in evidence.supportsLiveCard })

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "run-2", toolCallID: "open-2",
            toolName: "browser", action: "open"))
        #expect(session.browserRunEvidences(for: "chat-browser")
            .contains { evidence in evidence.supportsLiveCard })
    }

    @MainActor
    @Test func sequentialExternalRunsRetainOnlyLatestTerminalAuthority() {
        let session = BrowserLiveSession(makeTransport: { nil })
        for index in 0..<20 {
            let runID = "voice-run-\(index)"
            session.recordBrowserToolActivity(BrowserToolActivity(
                sessionKey: "chat-browser", runID: runID, toolCallID: "tabs-\(index)",
                toolName: "browser", action: "tabs"))
            let activeEvidences = session.browserRunEvidences(for: "chat-browser")
            #expect(activeEvidences.count == 1)
            #expect(activeEvidences[0].runID == runID)
            #expect(activeEvidences[0].observedToolCallIDs == ["tabs-\(index)"])
            session.endBrowserRun(for: "chat-browser", runID: runID)
        }

        let evidences = session.browserRunEvidences(for: "chat-browser")
        #expect(evidences.count == 1)
        #expect(!evidences[0].runIsActive)
        #expect(evidences[0].runID == "voice-run-19")
    }

    @MainActor
    @Test func fastBrowserRunKeepsLiveEvidenceThroughOneRenderWindow() async {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "fast-run", toolCallID: "tabs-fast",
            toolName: "browser", action: "tabs"))

        session.endBrowserRunEnsuringPresentation(
            for: "chat-browser",
            runID: "fast-run",
            minimumVisibilityNanoseconds: 10_000_000
        )

        #expect(session.browserRunEvidences(for: "chat-browser")
            .contains { $0.supportsLiveCard })

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!session.browserRunEvidences(for: "chat-browser")
            .contains { $0.supportsLiveCard })
    }

    @MainActor
    @Test func delayedUnscopedEndDoesNotTerminateNewerOverlappingRun() async {
        let session = BrowserLiveSession(makeTransport: { nil })
        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "old-run", toolCallID: "tabs-old",
            toolName: "browser", action: "tabs"))
        session.endBrowserRunEnsuringPresentation(
            for: "chat-browser",
            runID: nil,
            minimumVisibilityNanoseconds: 10_000_000
        )

        session.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: "chat-browser", runID: "new-run", toolCallID: "tabs-new",
            toolName: "browser", action: "tabs"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(session.browserRunEvidences(for: "chat-browser")
            .contains { $0.runID == "new-run" && $0.supportsLiveCard })
    }

    @Test func readOnlyStatusInCurrentTurnWhileOpenStaysLive() {
        // The agent resumes a still-open browser with a read-only `status` in this turn — still live.
        let messages = [
            userMessage("open example.com"),
            toolCall("browser", "navigate"),
            assistantText("Looking..."),
            userMessage("keep going"),
            toolCall("browser", "status"),
        ]
        let state = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 1, isOwner: true, isSessionEnded: false)
        #expect(state == .live)
    }

    @Test func reBrowseInLaterTurnRevivesLiveNotStuckEnded() {
        // A FIRST browse was explicitly ended, then a NEW user message triggers a SECOND browse in
        // a fresh run. Real open evidence clears the ended marker and returns the active card.
        let messages = [
            userMessage("search X"),
            toolCall("browser", "navigate"),
            assistantText("Here are the results."),
            userMessage("now look at Y"),
            toolCall("browser", "navigate"),
        ]
        let state = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 1, isOwner: true, isSessionEnded: false)
        #expect(state == .live)
        #expect(state != .ended)
    }

    // MARK: - Explicit teardown vs unrelated run activity

    @Test func unrelatedLaterTurnLeavesOwnedBrowserSessionActive() {
        let messages = [
            userMessage("open example.com"),
            toolCall("browser", "navigate"),
            assistantText("Done."),
            userMessage("what's the weather?"),   // new turn, no browser use
        ]
        let state = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 1, isOwner: true, isSessionEnded: false)
        #expect(state == .live)
    }

    @Test func explicitCloseInCurrentTurnIsNotLive() {
        let messages = [
            userMessage("open example.com"),
            toolCall("browser", "navigate"),
            toolCall("browser", "stop"),
        ]
        let state = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 1, isOwner: true, isSessionEnded: true)
        #expect(state == .ended)
        #expect(state != .live)
    }

    @Test func userEndedSessionSuppressesLiveEvenWithActiveRun() {
        // The user hit End; the run it aborted is still winding down (pendingRunCount == 1) with the
        // navigate still in the current turn. The explicit ended marker must keep it suppressed.
        let messages = [userMessage("open example.com"), toolCall("browser", "navigate")]
        let state = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 1, isOwner: true, isSessionEnded: true)
        #expect(state == .ended)
        #expect(state != .live)
    }

    // MARK: - No browser at all

    @Test func chatThatNeverBrowsedShowsNothing() {
        let messages = [userMessage("hi"), assistantText("hello")]
        let liveState = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 1, isOwner: false, isSessionEnded: false)
        let idleState = BrowserCardStateResolver.resolve(
            messages: messages, pendingRunCount: 0, isOwner: false, isSessionEnded: false)
        #expect(liveState == .none)
        #expect(idleState == .none)
    }

    @Test func activeOwnershipSurvivesMissingTranscriptAndPrunedRunEvidence() {
        #expect(BrowserCardStateResolver.resolve(
            messages: [],
            pendingRunCount: 0,
            isOwner: true,
            isSessionEnded: false
        ) == .live)
    }
}
