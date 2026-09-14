import Foundation
import Testing
@testable import Rem

// Decodes the models straight from the exact JSON the backend serializers emit
// (`formatMessage` / `formatTaskProposal` / `formatConversation` in conversations.routes.ts),
// pinning every snake_case -> camelCase key mapping, the `ProposalState` enum values, and the
// null-handling on optional fields.

@Suite("Rem conversation model decoding")
struct RemConversationModelDecodingTests {
    private let decoder = JSONDecoder()

    @Test("ConversationMessage maps run_id and created_at")
    func decodeMessage() throws {
        let json = """
        {
          "id": "42",
          "role": "assistant",
          "content": "Hello",
          "run_id": "11111111-1111-4111-8111-111111111111",
          "created_at": "2026-09-06T09:00:01.000Z"
        }
        """
        let message = try decoder.decode(ConversationMessage.self, from: Data(json.utf8))
        #expect(message.id == "42")
        #expect(message.role == "assistant")
        #expect(message.isAssistant)
        #expect(message.content == "Hello")
        #expect(message.runID == "11111111-1111-4111-8111-111111111111")
        #expect(message.createdAt == "2026-09-06T09:00:01.000Z")
    }

    @Test("ConversationMessage tolerates a null run_id")
    func decodeMessageNullRunID() throws {
        let json = """
        { "id": "10", "role": "user", "content": "Hi", "run_id": null, "created_at": "2026-09-06T09:00:00.000Z" }
        """
        let message = try decoder.decode(ConversationMessage.self, from: Data(json.utf8))
        #expect(message.runID == nil)
        #expect(!message.isAssistant)
    }

    @Test("ConversationToolProposal maps every field and nested patch")
    func decodePendingProposal() throws {
        let json = """
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
        """
        let proposal = try decoder.decode(ConversationToolProposal.self, from: Data(json.utf8))
        #expect(proposal.id == "7")
        #expect(proposal.messageID == "42")
        #expect(proposal.toolName == "tasks.update")
        #expect(proposal.taskID == "aaaaaaaa-0000-4000-8000-000000000001")
        #expect(proposal.taskTitle == "Finish the launch checklist")
        #expect(proposal.patch.status == "completed")
        #expect(proposal.explanation == "You said this is done.")
        #expect(proposal.state == .pending)
        #expect(proposal.effectID == nil)
        #expect(proposal.failureCode == nil)
        #expect(proposal.resolvedAt == nil)
    }

    @Test("A resolved failed proposal decodes state, failure_code and resolved_at")
    func decodeFailedProposal() throws {
        let json = """
        {
          "id": "9",
          "message_id": "43",
          "tool_name": "tasks.update",
          "task_id": "bbbbbbbb-0000-4000-8000-000000000001",
          "task_title": "Send the investor update",
          "patch": { "status": "completed" },
          "explanation": null,
          "state": "failed",
          "effect_id": "effect-2",
          "failure_code": "task_status_changed",
          "created_at": "2026-09-06T09:00:01.000Z",
          "updated_at": "2026-09-06T09:00:04.000Z",
          "resolved_at": "2026-09-06T09:00:04.000Z"
        }
        """
        let proposal = try decoder.decode(ConversationToolProposal.self, from: Data(json.utf8))
        #expect(proposal.state == .failed)
        #expect(proposal.failureCode == "task_status_changed")
        #expect(proposal.effectID == "effect-2")
        #expect(proposal.explanation == nil)
        #expect(proposal.resolvedAt == "2026-09-06T09:00:04.000Z")
    }

    @Test("Every backend proposal state decodes")
    func decodeAllBackendStates() throws {
        for raw in ["pending", "succeeded", "failed", "dismissed"] {
            let state = try decoder.decode(ProposalState.self, from: Data("\"\(raw)\"".utf8))
            #expect(state.rawValue == raw)
        }
    }

    @Test("Only pending is non-terminal")
    func terminalStates() {
        #expect(ProposalState.pending.isTerminal == false)
        #expect(ProposalState.succeeded.isTerminal)
        #expect(ProposalState.failed.isTerminal)
        #expect(ProposalState.dismissed.isTerminal)
        #expect(ProposalState.stale.isTerminal)
    }

    @Test("ProposalPatch renders in_progress as a readable status")
    func readableStatus() {
        #expect(ProposalPatch(status: "in_progress").readableStatus == "in progress")
        #expect(ProposalPatch(status: "completed").readableStatus == "completed")
    }

    @Test("Conversation summary maps snake_case fields")
    func decodeConversation() throws {
        let json = """
        {
          "id": "1a2b3c4d-0000-4000-8000-000000000001",
          "session_key": "rem-chat-1a2b3c4d-0000-4000-8000-000000000001",
          "title": "Tidy my tasks",
          "last_message_preview": "Here are the changes.",
          "message_count": 4,
          "created_at": "2026-09-06T09:00:00.000Z",
          "updated_at": "2026-09-06T09:05:00.000Z"
        }
        """
        let conversation = try decoder.decode(Conversation.self, from: Data(json.utf8))
        #expect(conversation.id == "1a2b3c4d-0000-4000-8000-000000000001")
        #expect(conversation.sessionKey == "rem-chat-1a2b3c4d-0000-4000-8000-000000000001")
        #expect(conversation.title == "Tidy my tasks")
        #expect(conversation.lastMessagePreview == "Here are the changes.")
        #expect(conversation.messageCount == 4)
    }

    @Test("Approve task ignores unknown columns from SELECT *")
    func decodeApprovedTaskIgnoresExtraColumns() throws {
        let json = """
        {
          "id": "task-1",
          "user_id": "user-1",
          "title": "Finish the launch checklist",
          "status": "completed",
          "updated_at": "2026-09-06T09:05:00.000Z",
          "sort_order": 3
        }
        """
        let task = try decoder.decode(ConversationApprovedTask.self, from: Data(json.utf8))
        #expect(task.id == "task-1")
        #expect(task.title == "Finish the launch checklist")
        #expect(task.status == "completed")
    }
}
