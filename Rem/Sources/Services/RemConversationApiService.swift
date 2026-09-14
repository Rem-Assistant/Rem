import Foundation

// MARK: - Injectable HTTP seam
//
// Mirrors the `SuggestionsApiService` pattern (`RemClaw/Sources/Services/SuggestionsApiService.swift`)
// of routing every call through `AuthenticatedHttpClient` (JWT auth, base-URL resolution, 401
// refresh — `RemClaw/Sources/Services/Auth/AuthenticatedHttpClient.swift`). The one addition is a
// thin protocol around that static entry point so the service is unit-testable with a mock
// transport without touching the global `AuthenticatedHttpClient.requestExecutor` seam.

/// The single HTTP operation `RemConversationApiService` needs. Production wraps
/// `AuthenticatedHttpClient.request`; tests inject a mock.
@MainActor
protocol RemConversationHttpClient {
    func send(path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse)
}

/// Production transport: authenticated request via the shared client, so this service inherits its
/// auth header, base-URL resolution, and silent 401 refresh.
@MainActor
struct AuthenticatedConversationHttpClient: RemConversationHttpClient {
    func send(path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        try await AuthenticatedHttpClient.request(path: path, method: method, body: body)
    }
}

// MARK: - Service

/// REST client for Rem's own conversation API (`backend/src/routes/conversations.routes.ts`). All
/// mutations go through the JWT-authenticated shared HTTP client. iOS-only, like `SuggestionsApiService`.
@MainActor
final class RemConversationApiService: RemConversationApiProviding {
    private let httpClient: RemConversationHttpClient
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private static let basePath = "/api/v1/conversations"

    init(http: RemConversationHttpClient) {
        self.httpClient = http
    }

    /// Production initializer: routes through the authenticated shared client. Kept separate from
    /// the injectable initializer because a `@MainActor` default-argument expression evaluates in a
    /// nonisolated context and cannot call `AuthenticatedConversationHttpClient()`.
    convenience init() {
        self.init(http: AuthenticatedConversationHttpClient())
    }

    // MARK: Create / list

    func createConversation(id: String? = nil, title: String? = nil) async throws -> Conversation {
        struct Body: Encodable {
            let id: String?
            let title: String?
        }
        let body: Data? = (id == nil && title == nil)
            ? nil
            : try encoder.encode(Body(id: id, title: title))
        let (data, http) = try await httpClient.send(path: Self.basePath, method: "POST", body: body)
        try Self.ensureSuccess(data: data, http: http)
        return try decode(Conversation.self, from: data)
    }

    func listConversations(limit: Int? = nil, cursor: String? = nil) async throws -> (conversations: [Conversation], nextCursor: String?) {
        let path = Self.path(Self.basePath, query: Self.query(limit: limit, cursor: cursor))
        let (data, http) = try await httpClient.send(path: path, method: "GET", body: nil)
        try Self.ensureSuccess(data: data, http: http)
        let response = try decode(ConversationListResponse.self, from: data)
        return (response.conversations, response.nextCursor)
    }

    // MARK: Read

    func getConversation(id: String, limit: Int? = nil, cursor: String? = nil) async throws -> ConversationHistory {
        let path = Self.path("\(Self.basePath)/\(Self.escape(id))", query: Self.query(limit: limit, cursor: cursor))
        let (data, http) = try await httpClient.send(path: path, method: "GET", body: nil)
        try Self.ensureSuccess(data: data, http: http)
        let response = try decode(ConversationHistoryResponse.self, from: data)
        return ConversationHistory(
            sessionKey: response.sessionKey,
            messages: response.messages,
            proposals: response.toolProposals,
            nextCursor: response.nextCursor
        )
    }

    // MARK: Chat

    func sendChat(conversationId: String, message: String, idempotencyKey: String) async throws -> SentChat {
        struct Body: Encodable {
            let message: String
            let idempotency_key: String
        }
        let body = try encoder.encode(Body(message: message, idempotency_key: idempotencyKey))
        let path = "\(Self.basePath)/\(Self.escape(conversationId))/chat"
        let (data, http) = try await httpClient.send(path: path, method: "POST", body: body)
        try Self.ensureSuccess(data: data, http: http)
        let response = try decode(ConversationChatResponse.self, from: data)
        return SentChat(message: response.message, proposals: response.toolProposals)
    }

    // MARK: Proposals

    func approveProposal(conversationId: String, proposalId: String) async throws -> ApprovedProposal {
        let path = "\(Self.basePath)/\(Self.escape(conversationId))/task-proposals/\(Self.escape(proposalId))/approve"
        let (data, http) = try await httpClient.send(path: path, method: "POST", body: nil)
        try Self.ensureSuccess(data: data, http: http)
        let response = try decode(ConversationApproveResponse.self, from: data)
        return ApprovedProposal(task: response.task, effectID: response.effectID, replayed: response.replayed ?? false)
    }

    func dismissProposal(conversationId: String, proposalId: String) async throws {
        let path = "\(Self.basePath)/\(Self.escape(conversationId))/task-proposals/\(Self.escape(proposalId))/dismiss"
        let (data, http) = try await httpClient.send(path: path, method: "POST", body: nil)
        // 204 (dismissed) and 200 (idempotent already-dismissed) both succeed; body is empty.
        try Self.ensureSuccess(data: data, http: http)
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RemConversationApiError.invalidResponse
        }
    }

    /// Maps any non-2xx response to `RemConversationApiError.requestFailed`, preserving the
    /// backend's structured `error` / `reason` / `failure_code` fields (principle 5) so callers can
    /// branch on machine-readable signals rather than parsing copy.
    private static func ensureSuccess(data: Data, http: HTTPURLResponse) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(ConversationErrorBody.self, from: data)
            throw RemConversationApiError.requestFailed(
                statusCode: http.statusCode,
                message: body?.error,
                reason: body?.reason,
                failureCode: body?.failureCode
            )
        }
    }

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private static func query(limit: Int?, cursor: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }

    private static func path(_ base: String, query items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return base }
        var components = URLComponents()
        components.queryItems = items
        let encoded = components.percentEncodedQuery ?? ""
        return encoded.isEmpty ? base : "\(base)?\(encoded)"
    }
}
