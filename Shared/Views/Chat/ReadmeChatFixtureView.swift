import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

#if DEBUG
/// README chat fixture: renders the REAL `SharedRemChatView` with a mock transport
/// that serves a short, realistic conversation — a user asking Rem to work a task and
/// Rem reporting what it did. 100% mock data: no account, no network, no real
/// names/emails. Launch arg: `--rem-chat-fixture`.
struct ReadmeChatFixtureView: View {
    @State private var viewModel: OpenClawChatViewModel
    @State private var didLoad = false

    init() {
        let transport = ReadmeChatFixtureTransport()
        self._viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: ReadmeChatFixtureTransport.sessionKey,
            transport: transport,
            initialThinkingLevel: "low"
        ))
    }

    var body: some View {
        NavigationStack {
            SharedRemChatView(viewModel: viewModel)
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            viewModel.refresh()
        }
    }
}

private final class ReadmeChatFixtureTransport: @unchecked Sendable, OpenClawChatTransport {
    static let sessionKey = "readme-chat-fixture"

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let payload: [String: Any] = [
            "sessionKey": sessionKey,
            "sessionId": "readme-chat-session",
            "thinkingLevel": "low",
            "messages": Self.conversation()
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
            "runId": "readme-run",
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

    private static func conversation() -> [[String: Any]] {
        // Recent epoch-seconds timestamps so the time separator reads as "Today", not 1969.
        let base = Date().timeIntervalSince1970 - 240
        return [
            message(
                role: "user",
                text: "Can you tidy up my inbox before I start my day?",
                timestamp: base
            ),
            message(
                role: "assistant",
                text: """
                Done — I archived 38 newsletters and snoozed 5 low-priority threads on this Mac.

                Two threads look like they still need you:
                • the venue about Saturday's set
                • a note from a bandmate about the setlist

                Want me to draft quick replies to those two?
                """,
                timestamp: base + 40
            ),
            message(
                role: "user",
                text: "Yes — draft a reply to the venue.",
                timestamp: base + 120
            ),
            message(
                role: "assistant",
                text: "Drafted a reply confirming the 7 PM load-in and asking about parking. It's saved to your drafts for a final look before it goes out.",
                timestamp: base + 160
            ),
        ]
    }

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
