import Foundation
import Testing
@testable import RemMac

// macOS mirror of the iOS `RemConversationApiServiceTests`. Exercises `MacRemConversationApiService`
// against a mock transport: it asserts the exact HTTP method, path (including query), and request
// body for each call, that success bodies decode into the domain result types, and that non-2xx
// responses map to `RemConversationApiError.requestFailed` carrying the backend's structured
// `reason` / `failure_code`.

@MainActor
private final class MockMacConversationHttpClient: MacRemConversationHttpClient {
    struct Call: Sendable {
        let path: String
        let method: String
        let body: Data?
    }

    private(set) var calls: [Call] = []
    /// Per-call response; defaults to a 200 with an empty body.
    var handler: (@MainActor (String, String, Data?) throws -> (Data, HTTPURLResponse))?

    var lastCall: Call? { calls.last }

    func send(path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        calls.append(Call(path: path, method: method, body: body))
        if let handler {
            return try handler(path, method, body)
        }
        return (Data(), Self.response(200))
    }

    static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://backend.test")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

@MainActor
@Suite("MacRemConversationApiService")
struct MacRemConversationApiServiceTests {
    private let conversationId = "1a2b3c4d-0000-4000-8000-000000000001"
    private let proposalId = "1a2b3c4d-0000-4000-8000-000000000002"

    private func makeService(_ mock: MockMacConversationHttpClient) -> MacRemConversationApiService {
        MacRemConversationApiService(http: mock)
    }

    // MARK: sendChat

    @Test("sendChat POSTs to /chat with the message + idempotency_key and decodes the reply")
    func sendChatRequestAndDecode() async throws {
        let mock = MockMacConversationHttpClient()
        let idempotencyKey = "1a2b3c4d-0000-4000-8000-0000000000ff"
        mock.handler = { _, _, _ in
            (Self.chatResponseJSON.data(using: .utf8)!, MockMacConversationHttpClient.response(201))
        }
        let service = makeService(mock)

        let result = try await service.sendChat(
            conversationId: conversationId,
            message: "Mark the checklist done",
            idempotencyKey: idempotencyKey
        )

        let call = try #require(mock.lastCall)
        #expect(call.method == "POST")
        #expect(call.path == "/api/v1/conversations/\(conversationId)/chat")

        // Body carries exactly { message, idempotency_key }.
        let body = try #require(call.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["message"] as? String == "Mark the checklist done")
        #expect(json["idempotency_key"] as? String == idempotencyKey)

        // Decoded reply + proposal.
        #expect(result.message.id == "42")
        #expect(result.message.isAssistant)
        #expect(result.proposals.count == 1)
        let proposal = try #require(result.proposals.first)
        #expect(proposal.id == "7")
        #expect(proposal.messageID == "42")
        #expect(proposal.toolName == "tasks.update")
        #expect(proposal.patch.status == "completed")
        #expect(proposal.state == .pending)
    }

    @Test("sendChat maps a 429 quota failure to requestFailed with the structured reason")
    func sendChatQuotaFailure() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            let body = #"{"error":"You have used the model requests included in your current plan.","reason":"quota_exhausted"}"#
            return (body.data(using: .utf8)!, MockMacConversationHttpClient.response(429))
        }
        let service = makeService(mock)

        do {
            _ = try await service.sendChat(conversationId: conversationId, message: "hi", idempotencyKey: proposalId)
            Issue.record("Expected failure")
        } catch let error as RemConversationApiError {
            guard case let .requestFailed(status, _, reason, _) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
            #expect(status == 429)
            #expect(reason == "quota_exhausted")
        }
    }

    // MARK: approve

    @Test("approveProposal POSTs to /approve and decodes status/task/effect_id/replayed")
    func approveRequestAndDecode() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            (Self.approveResponseJSON.data(using: .utf8)!, MockMacConversationHttpClient.response(200))
        }
        let service = makeService(mock)

        let result = try await service.approveProposal(conversationId: conversationId, proposalId: proposalId)

        let call = try #require(mock.lastCall)
        #expect(call.method == "POST")
        #expect(call.path == "/api/v1/conversations/\(conversationId)/task-proposals/\(proposalId)/approve")
        #expect(call.body == nil)

        #expect(result.effectID == "effect-1")
        #expect(result.replayed == false)
        // `task` is a full SELECT * row; only id/title/status are decoded, extra columns ignored.
        #expect(result.task?.id == "task-1")
        #expect(result.task?.title == "Finish the launch checklist")
        #expect(result.task?.status == "completed")
    }

    @Test("approveProposal maps 409 task_changed to a stale-signalling requestFailed")
    func approveTaskChangedConflict() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            let body = #"{"error":"The task changed after this proposal was created.","reason":"task_changed"}"#
            return (body.data(using: .utf8)!, MockMacConversationHttpClient.response(409))
        }
        let service = makeService(mock)

        do {
            _ = try await service.approveProposal(conversationId: conversationId, proposalId: proposalId)
            Issue.record("Expected failure")
        } catch let error as RemConversationApiError {
            guard case let .requestFailed(status, _, reason, failureCode) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
            #expect(status == 409)
            #expect(reason == "task_changed")
            #expect(failureCode == nil)
            #expect(error.isTaskChangedConflict)
        }
    }

    @Test("approveProposal preserves failure_code on a 409 proposal_failed")
    func approveFailureCodePreserved() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            let body = #"{"error":"This task proposal can no longer be applied.","reason":"proposal_failed","failure_code":"task_status_changed"}"#
            return (body.data(using: .utf8)!, MockMacConversationHttpClient.response(409))
        }
        let service = makeService(mock)

        do {
            _ = try await service.approveProposal(conversationId: conversationId, proposalId: proposalId)
            Issue.record("Expected failure")
        } catch let error as RemConversationApiError {
            guard case let .requestFailed(status, _, reason, failureCode) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
            #expect(status == 409)
            #expect(reason == "proposal_failed")
            #expect(failureCode == "task_status_changed")
            #expect(!error.isTaskChangedConflict)
        }
    }

    // MARK: dismiss

    @Test("dismissProposal POSTs to /dismiss and succeeds on an empty 204")
    func dismissSuccess() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in (Data(), MockMacConversationHttpClient.response(204)) }
        let service = makeService(mock)

        try await service.dismissProposal(conversationId: conversationId, proposalId: proposalId)

        let call = try #require(mock.lastCall)
        #expect(call.method == "POST")
        #expect(call.path == "/api/v1/conversations/\(conversationId)/task-proposals/\(proposalId)/dismiss")
        #expect(call.body == nil)
    }

    @Test("dismissProposal maps a 404 to requestFailed with the error message")
    func dismissNotFound() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            (#"{"error":"Task proposal not found"}"#.data(using: .utf8)!, MockMacConversationHttpClient.response(404))
        }
        let service = makeService(mock)

        do {
            try await service.dismissProposal(conversationId: conversationId, proposalId: proposalId)
            Issue.record("Expected failure")
        } catch let error as RemConversationApiError {
            guard case let .requestFailed(status, message, _, _) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }
            #expect(status == 404)
            #expect(message == "Task proposal not found")
        }
    }

    // MARK: get / create / list request shaping

    @Test("getConversation GETs the id path with the limit query and decodes messages + proposals")
    func getConversationRequestAndDecode() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            (Self.historyResponseJSON.data(using: .utf8)!, MockMacConversationHttpClient.response(200))
        }
        let service = makeService(mock)

        let history = try await service.getConversation(id: conversationId, limit: 100, cursor: nil)

        let call = try #require(mock.lastCall)
        #expect(call.method == "GET")
        #expect(call.path == "/api/v1/conversations/\(conversationId)?limit=100")
        #expect(history.messages.count == 1)
        #expect(history.proposals.count == 1)
        #expect(history.nextCursor == "CURSOR2")
    }

    @Test("createConversation sends no body when given no id or title")
    func createConversationEmptyBody() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            (Self.conversationJSON.data(using: .utf8)!, MockMacConversationHttpClient.response(201))
        }
        let service = makeService(mock)

        let conversation = try await service.createConversation(id: nil, title: nil)

        let call = try #require(mock.lastCall)
        #expect(call.method == "POST")
        #expect(call.path == "/api/v1/conversations")
        #expect(call.body == nil)
        #expect(conversation.id == "1a2b3c4d-0000-4000-8000-000000000001")
    }

    @Test("listConversations decodes the collection and next_cursor")
    func listConversationsDecode() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in
            let body = "{\"conversations\":[\(Self.conversationJSON)],\"next_cursor\":\"CURSOR1\"}"
            return (body.data(using: .utf8)!, MockMacConversationHttpClient.response(200))
        }
        let service = makeService(mock)

        let result = try await service.listConversations(limit: nil, cursor: nil)
        #expect(result.conversations.count == 1)
        #expect(result.nextCursor == "CURSOR1")
    }

    @Test("a success body that fails to decode maps to invalidResponse")
    func malformedSuccessBody() async throws {
        let mock = MockMacConversationHttpClient()
        mock.handler = { _, _, _ in ("not json".data(using: .utf8)!, MockMacConversationHttpClient.response(200)) }
        let service = makeService(mock)

        do {
            _ = try await service.getConversation(id: conversationId)
            Issue.record("Expected failure")
        } catch let error as RemConversationApiError {
            #expect(error == .invalidResponse)
        }
    }

    // MARK: - Fixtures

    static let chatResponseJSON = """
    {
      "run_id": "1a2b3c4d-0000-4000-8000-0000000000ff",
      "session_key": "rem-chat-1a2b3c4d-0000-4000-8000-000000000001",
      "status": "completed",
      "message": {
        "id": "42",
        "role": "assistant",
        "content": "I can update \\u2018Finish the launch checklist\\u2019 to completed.",
        "run_id": "1a2b3c4d-0000-4000-8000-0000000000ff",
        "created_at": "2026-09-06T09:00:01.000Z"
      },
      "tool_proposals": [
        {
          "id": "7",
          "message_id": "42",
          "tool_name": "tasks.update",
          "task_id": "aaaaaaaa-0000-4000-8000-000000000001",
          "task_title": "Finish the launch checklist",
          "patch": { "status": "completed" },
          "explanation": "You said this is done.",
          "state": "pending",
          "effect_id": null,
          "failure_code": null,
          "created_at": "2026-09-06T09:00:01.000Z",
          "updated_at": "2026-09-06T09:00:01.000Z",
          "resolved_at": null
        }
      ]
    }
    """

    static let approveResponseJSON = """
    {
      "status": "succeeded",
      "task": {
        "id": "task-1",
        "user_id": "user-1",
        "title": "Finish the launch checklist",
        "status": "completed",
        "updated_at": "2026-09-06T09:05:00.000Z",
        "sort_order": 3
      },
      "effect_id": "effect-1",
      "replayed": false
    }
    """

    static let historyResponseJSON = """
    {
      "session_key": "rem-chat-1a2b3c4d-0000-4000-8000-000000000001",
      "messages": [
        {
          "id": "10",
          "role": "user",
          "content": "Tidy my tasks",
          "run_id": null,
          "created_at": "2026-09-06T09:00:00.000Z"
        }
      ],
      "tool_proposals": [
        {
          "id": "8",
          "message_id": "11",
          "tool_name": "tasks.update",
          "task_id": "bbbbbbbb-0000-4000-8000-000000000001",
          "task_title": "Draft the retro notes",
          "patch": { "status": "in_progress" },
          "explanation": null,
          "state": "succeeded",
          "effect_id": "effect-9",
          "failure_code": null,
          "created_at": "2026-09-06T09:00:01.000Z",
          "updated_at": "2026-09-06T09:00:02.000Z",
          "resolved_at": "2026-09-06T09:00:02.000Z"
        }
      ],
      "next_cursor": "CURSOR2"
    }
    """

    static let conversationJSON = """
    {
      "id": "1a2b3c4d-0000-4000-8000-000000000001",
      "session_key": "rem-chat-1a2b3c4d-0000-4000-8000-000000000001",
      "title": "Tidy my tasks",
      "last_message_preview": "Here are the changes I can make.",
      "message_count": 4,
      "created_at": "2026-09-06T09:00:00.000Z",
      "updated_at": "2026-09-06T09:05:00.000Z"
    }
    """
}
