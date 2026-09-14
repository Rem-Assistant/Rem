import Foundation
import Testing
@testable import Rem

// Drives `RemConversationViewModel` with a mock `RemConversationApiProviding` and asserts the
// per-proposal display-state transitions (approve -> succeeded / stale / failed / retryable, dismiss
// -> dismissed) plus the optimistic send flow and load path.

@MainActor
private final class MockConversationApi: RemConversationApiProviding {
    var createResult: Result<Conversation, Error>?
    var listResult: Result<(conversations: [Conversation], nextCursor: String?), Error>?
    var historyResult: Result<ConversationHistory, Error> = .success(
        ConversationHistory(sessionKey: nil, messages: [], proposals: [], nextCursor: nil)
    )
    var sendResult: Result<SentChat, Error>?
    var approveResult: Result<ApprovedProposal, Error> = .success(
        ApprovedProposal(task: nil, effectID: "effect-1", replayed: false)
    )
    var dismissError: Error?

    private(set) var approvedIds: [String] = []
    private(set) var dismissedIds: [String] = []
    private(set) var sentMessages: [String] = []

    func createConversation(id: String?, title: String?) async throws -> Conversation {
        try result(createResult ?? .failure(RemConversationApiError.invalidResponse))
    }

    func listConversations(limit: Int?, cursor: String?) async throws -> (conversations: [Conversation], nextCursor: String?) {
        try result(listResult ?? .success(([], nil)))
    }

    func getConversation(id: String, limit: Int?, cursor: String?) async throws -> ConversationHistory {
        try result(historyResult)
    }

    func sendChat(conversationId: String, message: String, idempotencyKey: String) async throws -> SentChat {
        sentMessages.append(message)
        return try result(sendResult ?? .failure(RemConversationApiError.invalidResponse))
    }

    func approveProposal(conversationId: String, proposalId: String) async throws -> ApprovedProposal {
        approvedIds.append(proposalId)
        return try result(approveResult)
    }

    func dismissProposal(conversationId: String, proposalId: String) async throws {
        dismissedIds.append(proposalId)
        if let dismissError { throw dismissError }
    }

    private func result<T>(_ result: Result<T, Error>) throws -> T {
        switch result {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }
}

@MainActor
@Suite("RemConversationViewModel")
struct RemConversationViewModelTests {
    private func proposal(
        id: String,
        state: ProposalState = .pending,
        status: String = "completed"
    ) -> ConversationToolProposal {
        ConversationToolProposal(
            id: id,
            messageID: "a1",
            taskID: "task-\(id)",
            taskTitle: "Task \(id)",
            patch: ProposalPatch(status: status),
            explanation: nil,
            state: state,
            effectID: nil,
            failureCode: nil,
            createdAt: "2026-09-06T09:00:01.000Z",
            updatedAt: "2026-09-06T09:00:01.000Z",
            resolvedAt: nil
        )
    }

    private func makeViewModel(
        _ api: MockConversationApi,
        proposals: [ConversationToolProposal] = []
    ) -> RemConversationViewModel {
        RemConversationViewModel(
            conversationId: "conv-1",
            service: api,
            seededProposals: proposals.map { RemProposalDisplayItem(proposal: $0) }
        )
    }

    // MARK: approve

    @Test("approve advances a pending card to succeeded and clears busy")
    func approveSucceeds() async {
        let api = MockConversationApi()
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.approve("p1")

        #expect(api.approvedIds == ["p1"])
        let item = viewModel.proposals.first { $0.id == "p1" }
        #expect(item?.displayState == .succeeded)
        #expect(item?.isBusy == false)
        #expect(item?.inlineError == nil)
    }

    @Test("approve maps 409 task_changed to the stale terminal state")
    func approveTaskChangedGoesStale() async {
        let api = MockConversationApi()
        api.approveResult = .failure(
            RemConversationApiError.requestFailed(statusCode: 409, message: "changed", reason: "task_changed")
        )
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.approve("p1")

        let item = viewModel.proposals.first { $0.id == "p1" }
        #expect(item?.displayState == .stale)
        #expect(item?.isBusy == false)
    }

    @Test("approve keeps a task_changed 409 stale even when the backend includes a failure_code")
    func approveTaskChangedWithFailureCodeStaysStale() async {
        // The real backend sends a failure_code alongside reason:task_changed on approve
        // (execution -> route). The card must still go .stale, not .failed: isTaskChangedConflict
        // is checked before the failure_code branch — this pins that ordering against the real payload.
        let api = MockConversationApi()
        api.approveResult = .failure(
            RemConversationApiError.requestFailed(
                statusCode: 409,
                message: "The task changed after this proposal was created.",
                reason: "task_changed",
                failureCode: "task_observation_changed"
            )
        )
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.approve("p1")

        let item = viewModel.proposals.first { $0.id == "p1" }
        #expect(item?.displayState == .stale)
        #expect(item?.isBusy == false)
        #expect(item?.inlineError == nil)
    }

    @Test("approve with a failure_code moves the card to failed with an inline error")
    func approveFailureCodeFails() async {
        let api = MockConversationApi()
        api.approveResult = .failure(
            RemConversationApiError.requestFailed(
                statusCode: 409, message: "can no longer be applied", reason: "proposal_failed", failureCode: "task_status_changed"
            )
        )
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.approve("p1")

        let item = viewModel.proposals.first { $0.id == "p1" }
        #expect(item?.displayState == .failed)
        #expect(item?.inlineError == "can no longer be applied")
    }

    @Test("approve on a transient 503 stays pending with a retryable inline error")
    func approveTransientStaysPending() async {
        let api = MockConversationApi()
        api.approveResult = .failure(
            RemConversationApiError.requestFailed(statusCode: 503, message: "temporarily unavailable", reason: "execution_unavailable")
        )
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.approve("p1")

        let item = viewModel.proposals.first { $0.id == "p1" }
        #expect(item?.displayState == .pending)
        #expect(item?.inlineError == "temporarily unavailable")
    }

    @Test("approve is a no-op on an already-resolved card")
    func approveIgnoresResolved() async {
        let api = MockConversationApi()
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1", state: .succeeded)])

        await viewModel.approve("p1")

        #expect(api.approvedIds.isEmpty)
        #expect(viewModel.proposals.first { $0.id == "p1" }?.displayState == .succeeded)
    }

    // MARK: dismiss

    @Test("dismiss advances a pending card to dismissed")
    func dismissSucceeds() async {
        let api = MockConversationApi()
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.dismiss("p1")

        #expect(api.dismissedIds == ["p1"])
        #expect(viewModel.proposals.first { $0.id == "p1" }?.displayState == .dismissed)
    }

    @Test("dismiss treats a 404 as already dismissed")
    func dismissNotFoundBecomesDismissed() async {
        let api = MockConversationApi()
        api.dismissError = RemConversationApiError.requestFailed(statusCode: 404, message: "not found")
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.dismiss("p1")

        #expect(viewModel.proposals.first { $0.id == "p1" }?.displayState == .dismissed)
    }

    @Test("dismiss on a 409 keeps the card pending with an inline error")
    func dismissConflictStaysPending() async {
        let api = MockConversationApi()
        api.dismissError = RemConversationApiError.requestFailed(statusCode: 409, message: "A resolved task proposal cannot be dismissed")
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1")])

        await viewModel.dismiss("p1")

        let item = viewModel.proposals.first { $0.id == "p1" }
        #expect(item?.displayState == .pending)
        #expect(item?.inlineError == "A resolved task proposal cannot be dismissed")
    }

    // MARK: send

    @Test("send appends the optimistic user turn plus Rem's reply and proposals")
    func sendAppendsTurns() async {
        let api = MockConversationApi()
        let assistant = ConversationMessage(id: "a9", role: "assistant", content: "Done", runID: "r9", createdAt: "2026-09-06T09:00:05.000Z")
        api.sendResult = .success(SentChat(message: assistant, proposals: [proposal(id: "p9")]))
        let viewModel = makeViewModel(api)

        await viewModel.send("Please tidy up")

        #expect(api.sentMessages == ["Please tidy up"])
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages.first?.role == "user")
        #expect(viewModel.messages.first?.content == "Please tidy up")
        #expect(viewModel.messages.last?.id == "a9")
        #expect(viewModel.proposals.contains { $0.id == "p9" })
        #expect(viewModel.isSending == false)
        #expect(viewModel.errorText == nil)
    }

    @Test("send failure keeps the optimistic user turn and sets errorText")
    func sendFailureSetsError() async {
        let api = MockConversationApi()
        api.sendResult = .failure(RemConversationApiError.requestFailed(statusCode: 503, message: "Rem is temporarily unavailable. Try again in a moment."))
        let viewModel = makeViewModel(api)

        await viewModel.send("hi")

        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.role == "user")
        #expect(viewModel.errorText == "Rem is temporarily unavailable. Try again in a moment.")
        #expect(viewModel.isSending == false)
    }

    @Test("send ignores blank input")
    func sendIgnoresBlank() async {
        let api = MockConversationApi()
        let viewModel = makeViewModel(api)

        await viewModel.send("   ")

        #expect(api.sentMessages.isEmpty)
        #expect(viewModel.messages.isEmpty)
    }

    // MARK: load

    @Test("loadHistory populates messages, proposals and the cursor")
    func loadHistoryPopulates() async {
        let api = MockConversationApi()
        let message = ConversationMessage(id: "m1", role: "assistant", content: "Hi", runID: nil, createdAt: "2026-09-06T09:00:00.000Z")
        api.historyResult = .success(
            ConversationHistory(sessionKey: "rem-chat-conv-1", messages: [message], proposals: [proposal(id: "p1")], nextCursor: "CUR")
        )
        let viewModel = makeViewModel(api)

        await viewModel.loadHistory()

        #expect(viewModel.messages.map(\.id) == ["m1"])
        #expect(viewModel.proposals.map(\.id) == ["p1"])
        #expect(viewModel.proposals.first?.displayState == .pending)
        #expect(viewModel.nextCursor == "CUR")
    }

    @Test("loadHistory failure sets errorText")
    func loadHistoryFailure() async {
        let api = MockConversationApi()
        api.historyResult = .failure(RemConversationApiError.requestFailed(statusCode: 404, message: "Conversation not found"))
        let viewModel = makeViewModel(api)

        await viewModel.loadHistory()

        #expect(viewModel.errorText == "Conversation not found")
    }

    @Test("proposals(for:) filters to the owning assistant message")
    func proposalsForMessage() {
        let api = MockConversationApi()
        let other = ConversationToolProposal(
            id: "p2", messageID: "a2", taskID: "t2", taskTitle: "Other",
            patch: ProposalPatch(status: "completed"), explanation: nil, state: .pending,
            effectID: nil, failureCode: nil, createdAt: "x", updatedAt: "y", resolvedAt: nil
        )
        let viewModel = makeViewModel(api, proposals: [proposal(id: "p1"), other])

        #expect(viewModel.proposals(for: "a1").map(\.id) == ["p1"])
        #expect(viewModel.proposals(for: "a2").map(\.id) == ["p2"])
    }
}
