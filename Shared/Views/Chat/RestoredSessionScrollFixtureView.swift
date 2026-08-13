import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

#if DEBUG
struct RestoredSessionScrollFixtureView: View {
    @State private var viewModel: OpenClawChatViewModel
    @State private var didRequestRealHistory = false

    init() {
        let transport = RestoredSessionScrollFixtureTransport()
        self._viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: RestoredSessionScrollFixtureTransport.sessionKey,
            transport: transport,
            initialThinkingLevel: "low"
        ))
    }

    var body: some View {
        NavigationStack {
            SharedRemChatView(viewModel: viewModel)
        }
        .task {
            guard !didRequestRealHistory else { return }
            didRequestRealHistory = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            viewModel.refresh()
        }
    }
}

private final class RestoredSessionScrollFixtureTransport: @unchecked Sendable, OpenClawChatTransport {
    static let sessionKey = "fixture-restored-long-session"
    private let requestLock = NSLock()
    private var historyRequestCount = 0

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let requestIndex = nextHistoryRequestIndex()
        let payload: [String: Any] = [
            "sessionKey": sessionKey,
            "sessionId": "fixture-session-id",
            "thinkingLevel": "low",
            "messages": requestIndex == 1 ? Self.staleSnapshotMessages() : Self.fixtureMessages()
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

    private func nextHistoryRequestIndex() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        historyRequestCount += 1
        return historyRequestCount
    }

    private static func staleSnapshotMessages() -> [[String: Any]] {
        [
            message(
                idSuffix: 1,
                role: "user",
                text: "Stale pre-switch message: this should be replaced by real restored history.",
                timestamp: 1
            ),
            message(
                idSuffix: 2,
                role: "assistant",
                text: "Stale pre-switch reply: if this remains the only visible history, the race is still present.",
                timestamp: 2
            )
        ]
    }

    private static func fixtureMessages() -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for index in 1...28 {
            let isUser = index % 2 == 1
            let role = isUser ? "user" : "assistant"
            let text = isUser
                ? "Earlier restored turn \(index): I opened this session from Sessions."
                : "Earlier restored reply \(index): this filler creates enough history to require bottom scrolling."
            messages.append(message(idSuffix: index, role: role, text: text, timestamp: Double(index)))
        }

        messages.append(message(
            idSuffix: 29,
            role: "user",
            text: "When I open this old session, please land me at the latest message.",
            timestamp: 29
        ))
        messages.append(message(
            idSuffix: 30,
            role: "assistant",
            text: "Final restored message: if this line is visible after launch, the restored chat opened at the bottom.",
            timestamp: 30
        ))
        return messages
    }

    private static func message(idSuffix _: Int, role: String, text: String, timestamp: Double) -> [String: Any] {
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
