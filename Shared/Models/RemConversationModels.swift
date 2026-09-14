import Foundation

// MARK: - Rem conversation models
//
// Codable mirrors of Rem's own conversation API — the app talks to the backend directly instead of
// routing chat through the OpenClaw gateway. Field names track the backend route serializers
// `formatMessage` / `formatTaskProposal` / `formatConversation` in
// `backend/src/routes/conversations.routes.ts` (verified against that file). These live in Shared/
// so the shared conversation + proposal views compile into BOTH the iOS and macOS targets per the
// DRY rule in CLAUDE.md; the concrete networking (`RemConversationApiService`) stays iOS-only.

// MARK: Message

/// One persisted turn in a conversation. Mirrors `formatMessage`
/// (`conversations.routes.ts:45`): `{ id, role, content, run_id, created_at }`.
public nonisolated struct ConversationMessage: Codable, Identifiable, Sendable, Hashable {
    /// Stable message id (a bigint serialized as a string by the backend).
    public let id: String
    /// "user" | "assistant" (the only roles the backend returns to clients).
    public let role: String
    public let content: String
    /// The run/idempotency id that produced this turn; null for older rows.
    public let runID: String?
    /// ISO 8601 timestamp.
    public let createdAt: String

    public var isAssistant: Bool { role == "assistant" }

    public init(id: String, role: String, content: String, runID: String?, createdAt: String) {
        self.id = id
        self.role = role
        self.content = content
        self.runID = runID
        self.createdAt = createdAt
    }

    public enum CodingKeys: String, CodingKey {
        case id, role, content
        case runID = "run_id"
        case createdAt = "created_at"
    }
}

// MARK: Proposal

/// Lifecycle state of a task-update proposal.
///
/// The backend emits exactly `pending | succeeded | failed | dismissed`
/// (`conversations.routes.ts` proposal `state`). `stale` is **client-only**: it is never decoded
/// from the backend — the view model applies it when an approve is rejected with HTTP 409 and the
/// structured `reason == "task_changed"`, meaning the underlying task moved on since the proposal
/// was created and a fresh proposal is required.
public nonisolated enum ProposalState: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case succeeded
    case failed
    case dismissed
    case stale

    /// A resolved state that no longer offers Approve / Dismiss.
    public var isTerminal: Bool { self != .pending }
}

/// The patch a proposal would apply. Today only `status` is ever proposed
/// (`patch: { status: row.proposed_status }`). `status` is one of
/// `pending | in_progress | completed | blocked`.
public nonisolated struct ProposalPatch: Codable, Sendable, Hashable {
    public let status: String

    public init(status: String) {
        self.status = status
    }

    /// Human-readable status for copy ("in_progress" -> "in progress"), matching the backend's own
    /// `status.replace('_', ' ')` rendering in the assistant reply.
    public var readableStatus: String {
        status.replacingOccurrences(of: "_", with: " ")
    }
}

/// A single `tasks.update` proposal awaiting the user's approval. Mirrors `formatTaskProposal`
/// (`conversations.routes.ts:55`).
public nonisolated struct ConversationToolProposal: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    /// The assistant message this proposal hangs off (`message_id`).
    public let messageID: String
    /// Always "tasks.update" today.
    public let toolName: String
    public let taskID: String
    public let taskTitle: String
    public let patch: ProposalPatch
    /// Rem's rationale for the change; may be null.
    public let explanation: String?
    public let state: ProposalState
    /// Audit effect id once applied; null while pending.
    public let effectID: String?
    /// Structured failure classifier when `state == .failed`; null otherwise.
    public let failureCode: String?
    public let createdAt: String
    public let updatedAt: String
    /// When the proposal reached a terminal state; null while pending.
    public let resolvedAt: String?

    public init(
        id: String,
        messageID: String,
        toolName: String = "tasks.update",
        taskID: String,
        taskTitle: String,
        patch: ProposalPatch,
        explanation: String?,
        state: ProposalState,
        effectID: String?,
        failureCode: String?,
        createdAt: String,
        updatedAt: String,
        resolvedAt: String?
    ) {
        self.id = id
        self.messageID = messageID
        self.toolName = toolName
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.patch = patch
        self.explanation = explanation
        self.state = state
        self.effectID = effectID
        self.failureCode = failureCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case messageID = "message_id"
        case toolName = "tool_name"
        case taskID = "task_id"
        case taskTitle = "task_title"
        case patch
        case explanation
        case state
        case effectID = "effect_id"
        case failureCode = "failure_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case resolvedAt = "resolved_at"
    }
}

// MARK: Conversation summary

/// A conversation row from create / list. Mirrors `formatConversation`
/// (`conversations.routes.ts:73`).
public nonisolated struct Conversation: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let sessionKey: String?
    public let title: String?
    public let lastMessagePreview: String?
    public let messageCount: Int?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        sessionKey: String?,
        title: String?,
        lastMessagePreview: String?,
        messageCount: Int?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.sessionKey = sessionKey
        self.title = title
        self.lastMessagePreview = lastMessagePreview
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case sessionKey = "session_key"
        case title
        case lastMessagePreview = "last_message_preview"
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// The task returned by a successful approve (`{ task }`). The backend serializes the full
/// `SELECT * FROM tasks` row, so this decodes only the fields the UI needs and ignores the rest;
/// every field is optional because `task` may be null on a replayed/settled approve.
public nonisolated struct ConversationApprovedTask: Codable, Sendable, Hashable {
    public let id: String?
    public let title: String?
    public let status: String?

    public init(id: String?, title: String?, status: String?) {
        self.id = id
        self.title = title
        self.status = status
    }

    public enum CodingKeys: String, CodingKey {
        case id, title, status
    }
}

// MARK: - Wire response DTOs (internal to the networking layer)

/// `POST /conversations/:id/chat` success body:
/// `{ run_id, session_key, status, message, tool_proposals }`.
nonisolated struct ConversationChatResponse: Codable {
    let runID: String?
    let sessionKey: String?
    let status: String?
    let message: ConversationMessage
    let toolProposals: [ConversationToolProposal]

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case sessionKey = "session_key"
        case status
        case message
        case toolProposals = "tool_proposals"
    }
}

/// `GET /conversations/:id` body: `{ session_key, messages, tool_proposals, next_cursor }`.
nonisolated struct ConversationHistoryResponse: Codable {
    let sessionKey: String?
    let messages: [ConversationMessage]
    let toolProposals: [ConversationToolProposal]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case sessionKey = "session_key"
        case messages
        case toolProposals = "tool_proposals"
        case nextCursor = "next_cursor"
    }
}

/// `POST .../approve` success body: `{ status:"succeeded", task, effect_id, replayed }`.
nonisolated struct ConversationApproveResponse: Codable {
    let status: String
    let task: ConversationApprovedTask?
    let effectID: String?
    let replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case task
        case effectID = "effect_id"
        case replayed
    }
}

/// `GET /conversations` body: `{ conversations, next_cursor }`.
nonisolated struct ConversationListResponse: Codable {
    let conversations: [Conversation]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case conversations
        case nextCursor = "next_cursor"
    }
}

/// Shape of the backend's JSON error bodies. Every conversation error path returns `{ error }`,
/// and the proposal lifecycle paths add structured `reason` / `failure_code` fields the client
/// switches on (principle 5: structured signals, not string parsing).
nonisolated struct ConversationErrorBody: Codable {
    let error: String?
    let reason: String?
    let failureCode: String?

    enum CodingKeys: String, CodingKey {
        case error
        case reason
        case failureCode = "failure_code"
    }
}

// MARK: - Error

/// Errors surfaced by `RemConversationApiService`. `requestFailed` preserves the HTTP status plus
/// the backend's structured `reason` / `failureCode` so the view model can distinguish a stale
/// proposal (409 + `task_changed`) from a genuine failure without parsing human-readable copy.
public enum RemConversationApiError: LocalizedError, Equatable {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String? = nil, reason: String? = nil, failureCode: String? = nil)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case let .requestFailed(code, message, _, _):
            return message ?? "Request failed (HTTP \(code))"
        }
    }

    /// True when the backend rejected an approve because the task changed since the proposal was
    /// created (HTTP 409 + `reason == "task_changed"`) — the proposal is stale.
    public var isTaskChangedConflict: Bool {
        if case let .requestFailed(code, _, reason, _) = self {
            return code == 409 && reason == "task_changed"
        }
        return false
    }
}
