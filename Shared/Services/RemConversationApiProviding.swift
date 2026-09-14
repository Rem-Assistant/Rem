import Foundation

// MARK: - Conversation API abstraction
//
// The protocol the `RemConversationViewModel` depends on, so the view model is unit-testable with a
// mock and the shared views compile into both platform targets without referencing the iOS-only
// concrete client (`RemConversationApiService`, which wraps `AuthenticatedHttpClient`). Domain
// result types keep the wire DTOs (`ConversationChatResponse` etc.) out of the view layer.

/// Messages + proposals for a conversation, plus the older-page cursor.
public struct ConversationHistory: Sendable, Equatable {
    public let sessionKey: String?
    public let messages: [ConversationMessage]
    public let proposals: [ConversationToolProposal]
    public let nextCursor: String?

    public init(
        sessionKey: String?,
        messages: [ConversationMessage],
        proposals: [ConversationToolProposal],
        nextCursor: String?
    ) {
        self.sessionKey = sessionKey
        self.messages = messages
        self.proposals = proposals
        self.nextCursor = nextCursor
    }
}

/// The assistant turn produced by a chat send, plus any proposals it created.
public struct SentChat: Sendable, Equatable {
    public let message: ConversationMessage
    public let proposals: [ConversationToolProposal]

    public init(message: ConversationMessage, proposals: [ConversationToolProposal]) {
        self.message = message
        self.proposals = proposals
    }
}

/// The outcome of approving a proposal.
public struct ApprovedProposal: Sendable, Equatable {
    public let task: ConversationApprovedTask?
    public let effectID: String?
    public let replayed: Bool

    public init(task: ConversationApprovedTask?, effectID: String?, replayed: Bool) {
        self.task = task
        self.effectID = effectID
        self.replayed = replayed
    }
}

/// The full conversation surface the app talks to. All methods are `@MainActor` because the
/// concrete client reads main-actor-isolated credentials via `AuthenticatedHttpClient`.
@MainActor
public protocol RemConversationApiProviding {
    /// `POST /api/v1/conversations` — create (or resolve an existing) conversation. `id` is a UUID
    /// the client may supply for idempotency; the server generates one when omitted.
    func createConversation(id: String?, title: String?) async throws -> Conversation

    /// `GET /api/v1/conversations` — list the user's conversations, newest first.
    func listConversations(limit: Int?, cursor: String?) async throws -> (conversations: [Conversation], nextCursor: String?)

    /// `GET /api/v1/conversations/:id` — messages + proposals for one conversation.
    func getConversation(id: String, limit: Int?, cursor: String?) async throws -> ConversationHistory

    /// `POST /api/v1/conversations/:id/chat` — send a user message and get Rem's reply + proposals.
    func sendChat(conversationId: String, message: String, idempotencyKey: String) async throws -> SentChat

    /// `POST /api/v1/conversations/:id/task-proposals/:proposalId/approve` — apply a proposal.
    func approveProposal(conversationId: String, proposalId: String) async throws -> ApprovedProposal

    /// `POST /api/v1/conversations/:id/task-proposals/:proposalId/dismiss` — dismiss a proposal.
    func dismissProposal(conversationId: String, proposalId: String) async throws
}

public extension RemConversationApiProviding {
    /// Convenience: history from the first page.
    func getConversation(id: String) async throws -> ConversationHistory {
        try await getConversation(id: id, limit: nil, cursor: nil)
    }
}

// MARK: - Preview / fixture stub

#if DEBUG
/// A no-network conformer used by SwiftUI previews and the `--rem-conversation-proposal-fixture`
/// launch arg so the shared views render each proposal state with no sign-in. Interactions resolve
/// to canned successes so tapping Approve / Dismiss in a fixture behaves sanely.
@MainActor
public final class PreviewConversationApiService: RemConversationApiProviding {
    public init() {}

    public func createConversation(id: String?, title: String?) async throws -> Conversation {
        Conversation(
            id: id ?? UUID().uuidString,
            sessionKey: "rem-chat-preview",
            title: title,
            lastMessagePreview: nil,
            messageCount: 0,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    public func listConversations(limit: Int?, cursor: String?) async throws -> (conversations: [Conversation], nextCursor: String?) {
        ([], nil)
    }

    public func getConversation(id: String, limit: Int?, cursor: String?) async throws -> ConversationHistory {
        ConversationHistory(sessionKey: "rem-chat-preview", messages: [], proposals: [], nextCursor: nil)
    }

    public func sendChat(conversationId: String, message: String, idempotencyKey: String) async throws -> SentChat {
        SentChat(
            message: ConversationMessage(
                id: UUID().uuidString,
                role: "assistant",
                content: "This is a preview reply.",
                runID: idempotencyKey,
                createdAt: "2026-01-01T00:00:00.000Z"
            ),
            proposals: []
        )
    }

    public func approveProposal(conversationId: String, proposalId: String) async throws -> ApprovedProposal {
        ApprovedProposal(
            task: ConversationApprovedTask(id: UUID().uuidString, title: "Preview task", status: "completed"),
            effectID: UUID().uuidString,
            replayed: false
        )
    }

    public func dismissProposal(conversationId: String, proposalId: String) async throws {}
}
#endif
