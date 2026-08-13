import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

#if DEBUG
struct ChatDiagnosticsRowFixtureView: View {
    @State private var viewModel: OpenClawChatViewModel
    @State private var didRequestHistory = false

    init() {
        let transport = ChatDiagnosticsRowFixtureTransport()
        self._viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: ChatDiagnosticsRowFixtureTransport.sessionKey,
            transport: transport,
            initialThinkingLevel: "low"
        ))
    }

    var body: some View {
        NavigationStack {
            SharedRemChatView(viewModel: viewModel)
        }
        .task {
            guard !didRequestHistory else { return }
            didRequestHistory = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            viewModel.refresh()
        }
    }
}

private final class ChatDiagnosticsRowFixtureTransport: @unchecked Sendable, OpenClawChatTransport {
    static let sessionKey = "fixture-chat-diagnostics-row"

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let payload: [String: Any] = [
            "sessionKey": sessionKey,
            "sessionId": "fixture-chat-diagnostics-row-id",
            "thinkingLevel": "low",
            "messages": Self.fixtureMessages()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: data)
    }

    func listModels() async throws -> [OpenClawChatModelChoice] { [] }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey _: String,
        attachments _: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        try Self.decode(OpenClawChatSendResponse.self, from: [
            "runId": "fixture-run",
            "status": "complete"
        ])
    }

    func abortRun(sessionKey _: String, runId _: String) async throws {}

    func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        OpenClawChatSessionsListResponse(
            ts: Date().timeIntervalSince1970 * 1000,
            path: nil,
            count: 1,
            defaults: OpenClawChatSessionsDefaults(
                model: nil,
                contextTokens: nil,
                thinkingLevels: nil,
                thinkingOptions: nil,
                thinkingDefault: "low",
                mainSessionKey: nil
            ),
            sessions: []
        )
    }

    func setSessionModel(sessionKey _: String, model _: String?) async throws {}
    func setSessionThinking(sessionKey _: String, thinkingLevel _: String) async throws {}
    func requestHealth(timeoutMs _: Int) async throws -> Bool { true }
    func events() -> AsyncStream<OpenClawChatTransportEvent> { AsyncStream { $0.finish() } }
    func setActiveSessionKey(_: String) async throws {}
    func resetSession(sessionKey _: String) async throws {}
    func compactSession(sessionKey _: String) async throws {}

    private static func fixtureMessages() -> [[String: Any]] {
        [
            message(
                role: "user",
                text: "Does this gateway have the GitHub skill installed?",
                timestamp: 1
            ),
            message(
                role: "assistant",
                text: noisyAssistantTranscript,
                timestamp: 2
            ),
            // R3 (#812): a looping agent that retried the same failed command
            // produces a long run of near-duplicate thoughts. Drives the
            // consolidated "Thinking · N steps" group with an "×N" badge.
            message(
                role: "user",
                text: "Add my 3 trip reminders: book flights, pack bags, hold mail.",
                timestamp: 3
            ),
            loopingAssistantMessage(timestamp: 4),
            message(role: "user", text: "Add dinner to my calendar.", timestamp: 5_000),
            toolCallMessage(timestamp: 6_000),
            toolResultMessage(timestamp: 7_000),
            message(role: "assistant", text: "Dinner is on your calendar.", timestamp: 9_000)
        ]
    }

    private static func toolCallMessage(timestamp: Double) -> [String: Any] {
        [
            "role": "assistant",
            "timestamp": timestamp,
            "content": [[
                "type": "toolCall",
                "name": "calendar.add",
                "arguments": ["title": "Dinner"]
            ]]
        ]
    }

    private static func toolResultMessage(timestamp: Double) -> [String: Any] {
        [
            "role": "toolResult",
            "timestamp": timestamp,
            "content": [[
                "type": "toolResult",
                "name": "calendar.add",
                "text": #"{"eventId":"event-1","title":"Dinner"}"#
            ]]
        ]
    }

    /// Several consecutive thoughts, most of them the identical
    /// "reminders.add not found" diagnostic, plus a final conversational reply.
    private static func loopingAssistantMessage(timestamp: Double) -> [String: Any] {
        let thoughts = [
            "Calling reminders.add for \"book flights\"…",
            "reminders.add not found",
            "reminders.add not found",
            "reminders.add not found",
            "Retrying reminders.add for \"pack bags\"…",
            "reminders.add not found",
            "reminders.add not found",
            "reminders.add not found",
            "reminders.add not found",
            "Trying tasks.create as a fallback…",
            "reminders.add not found",
            "reminders.add not found"
        ]
        var content: [[String: Any]] = thoughts.map { thought in
            ["type": "thinking", "thinking": thought]
        }
        content.append([
            "type": "text",
            "text": "I couldn't add those reminders — the reminders.add command isn't available on this device. Want me to create them as tasks instead?"
        ])
        return [
            "role": "assistant",
            "timestamp": timestamp,
            "content": content
        ]
    }

    private static let noisyAssistantTranscript = """
    name: github
    description: "GitHub operations via gh CLI: issues, PRs, CI runs, code review, API queries."
    metadata:
      openclaw:
        emoji: "github"
        requires:
          bins: ["gh"]
        install:
          - id: brew
            kind: brew
            formula: gh
            label: "Install GitHub CLI (brew)"

    Tool system.run not found
    node command not allowed: the node (platform: macOS 26.1.0) does not support "system.run.prepare"
    sh: 1: gh: not found

    The GitHub skill needs the `gh` CLI before it can manage repositories.
    """

    private static func message(role: String, text: String, timestamp: Double) -> [String: Any] {
        [
            "role": role,
            "timestamp": timestamp,
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ]
        ]
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}
#endif
