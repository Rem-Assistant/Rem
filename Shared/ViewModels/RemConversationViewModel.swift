import Foundation
import Observation

// MARK: - Proposal display item
//
// A proposal plus the per-item UI state the view model owns on top of the decoded backend `state`:
// an in-flight flag while an approve/dismiss is running, an optional inline error, and a
// `displayState` that can advance client-side (e.g. to `.stale` after a 409 `task_changed`, or to
// `.succeeded` the moment an approve returns, before any refetch).

public struct RemProposalDisplayItem: Identifiable, Sendable, Hashable {
    public let proposal: ConversationToolProposal
    /// The state shown in the card. Seeded from `proposal.state`, then advanced by user actions.
    public var displayState: ProposalState
    /// True while an approve/dismiss network call for this item is in flight.
    public var isBusy: Bool
    /// A short, retryable error to show under the card (does not change `displayState`).
    public var inlineError: String?

    public var id: String { proposal.id }

    public init(
        proposal: ConversationToolProposal,
        displayState: ProposalState? = nil,
        isBusy: Bool = false,
        inlineError: String? = nil
    ) {
        self.proposal = proposal
        self.displayState = displayState ?? proposal.state
        self.isBusy = isBusy
        self.inlineError = inlineError
    }
}

// MARK: - View model

/// Drives one conversation: loading history, sending a message, and approving / dismissing task
/// proposals. `@MainActor @Observable` so SwiftUI observes `messages`, `proposals`, `isSending`,
/// and `errorText` directly. Lives in Shared/ (depends only on `RemConversationApiProviding`) so
/// the shared conversation view can bind to it on either platform.
@MainActor
@Observable
public final class RemConversationViewModel {
    public let conversationId: String
    private let service: RemConversationApiProviding

    public private(set) var messages: [ConversationMessage] = []
    public private(set) var proposals: [RemProposalDisplayItem] = []
    /// True while a chat send is awaiting Rem's reply.
    public private(set) var isSending = false
    /// A conversation-level error (load / send failure). Card-level failures use `inlineError`.
    public private(set) var errorText: String?
    /// Cursor for the previous page of history, if any.
    public private(set) var nextCursor: String?

    public init(
        conversationId: String,
        service: RemConversationApiProviding,
        seededMessages: [ConversationMessage] = [],
        seededProposals: [RemProposalDisplayItem] = []
    ) {
        self.conversationId = conversationId
        self.service = service
        self.messages = seededMessages
        self.proposals = seededProposals
    }

    /// Proposals whose card should render beneath a given assistant message.
    public func proposals(for messageID: String) -> [RemProposalDisplayItem] {
        proposals.filter { $0.proposal.messageID == messageID }
    }

    // MARK: Load

    /// Loads the most recent page of history, replacing the current messages / proposals.
    public func loadHistory(limit: Int? = nil) async {
        errorText = nil
        do {
            let history = try await service.getConversation(id: conversationId, limit: limit, cursor: nil)
            messages = history.messages
            proposals = history.proposals.map { RemProposalDisplayItem(proposal: $0) }
            nextCursor = history.nextCursor
        } catch {
            errorText = Self.describe(error)
        }
    }

    // MARK: Send

    /// Sends a user message. Optimistically appends the user's turn, then appends Rem's reply and
    /// any proposals it created. The backend replies with only the assistant turn (the user turn is
    /// persisted server-side), so the optimistic append is what shows the user's own text.
    public func send(_ text: String, idempotencyKey: String = UUID().uuidString) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        errorText = nil
        isSending = true
        messages.append(
            ConversationMessage(
                id: "local-user-\(idempotencyKey)",
                role: "user",
                content: trimmed,
                runID: idempotencyKey,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        )
        do {
            let result = try await service.sendChat(
                conversationId: conversationId,
                message: trimmed,
                idempotencyKey: idempotencyKey
            )
            messages.append(result.message)
            proposals.append(contentsOf: result.proposals.map { RemProposalDisplayItem(proposal: $0) })
        } catch {
            errorText = Self.describe(error)
        }
        isSending = false
    }

    // MARK: Approve

    /// Approves a proposal. On success the card advances to `.succeeded`. A 409 `task_changed`
    /// advances it to `.stale`; a failure that carries a structured `failure_code` advances it to
    /// `.failed`; anything else (503, 409 running/pending, 404) leaves it pending with a retryable
    /// inline error.
    public func approve(_ id: String) async {
        guard let index = proposals.firstIndex(where: { $0.id == id }),
              proposals[index].displayState == .pending,
              !proposals[index].isBusy else { return }
        setBusy(at: index, true)
        proposals[index].inlineError = nil
        do {
            _ = try await service.approveProposal(conversationId: conversationId, proposalId: id)
            guard let i = proposals.firstIndex(where: { $0.id == id }) else { return }
            proposals[i].displayState = .succeeded
            proposals[i].isBusy = false
            proposals[i].inlineError = nil
        } catch {
            applyApproveFailure(id: id, error: error)
        }
    }

    private func applyApproveFailure(id: String, error: Error) {
        guard let i = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[i].isBusy = false
        if let apiError = error as? RemConversationApiError, case let .requestFailed(_, message, _, failureCode) = apiError {
            if apiError.isTaskChangedConflict {
                proposals[i].displayState = .stale
                proposals[i].inlineError = nil
            } else if failureCode != nil {
                proposals[i].displayState = .failed
                proposals[i].inlineError = message
            } else {
                // Retryable (temporarily unavailable, still reconciling, not found) — stay pending.
                proposals[i].inlineError = message ?? Self.describe(error)
            }
        } else {
            proposals[i].inlineError = Self.describe(error)
        }
    }

    // MARK: Dismiss

    /// Dismisses a proposal. On success (or a 404 — already gone) the card advances to `.dismissed`;
    /// a 409 (already resolved) leaves the card as-is with an inline error.
    public func dismiss(_ id: String) async {
        guard let index = proposals.firstIndex(where: { $0.id == id }),
              proposals[index].displayState == .pending,
              !proposals[index].isBusy else { return }
        setBusy(at: index, true)
        proposals[index].inlineError = nil
        do {
            try await service.dismissProposal(conversationId: conversationId, proposalId: id)
            guard let i = proposals.firstIndex(where: { $0.id == id }) else { return }
            proposals[i].displayState = .dismissed
            proposals[i].isBusy = false
            proposals[i].inlineError = nil
        } catch {
            guard let i = proposals.firstIndex(where: { $0.id == id }) else { return }
            proposals[i].isBusy = false
            if let apiError = error as? RemConversationApiError,
               case let .requestFailed(code, message, _, _) = apiError {
                if code == 404 {
                    proposals[i].displayState = .dismissed
                    proposals[i].inlineError = nil
                } else {
                    proposals[i].inlineError = message
                }
            } else {
                proposals[i].inlineError = Self.describe(error)
            }
        }
    }

    // MARK: Helpers

    private func setBusy(at index: Int, _ busy: Bool) {
        guard proposals.indices.contains(index) else { return }
        proposals[index].isBusy = busy
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
