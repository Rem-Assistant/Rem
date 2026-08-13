import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

#if DEBUG
/// Deterministic, auth-free runtime proof for #1141.
///
/// The fixture drives the same sequence as production: history establishes a stable session id,
/// sending creates an in-flight run, then a live `agent/tool` browser event arrives before the
/// browser call exists in persisted history. The real `SharedRemChatView` must show its pinned card.
struct BrowserLiveCardFixtureView: View {
    @State private var viewModel: OpenClawChatViewModel
    @State private var browserSession: BrowserLiveSession
    @State private var didSend = false

    init() {
        let browserSession = BrowserLiveSession(makeTransport: { nil })
        let transport = BrowserLiveCardFixtureTransport(browserSession: browserSession)
        self._viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: BrowserLiveCardFixtureTransport.sessionKey,
            transport: transport,
            initialThinkingLevel: "low"))
        self._browserSession = State(initialValue: browserSession)
    }

    var body: some View {
        NavigationStack {
            SharedRemChatView(viewModel: viewModel)
        }
        .environment(browserSession)
        .task {
            guard !didSend else { return }
            didSend = true
            for _ in 0..<40 where !viewModel.healthOK {
                try? await Task.sleep(for: .milliseconds(50))
            }
            viewModel.input = "Use the browser to open example.com"
            viewModel.send()
        }
    }
}

private final class BrowserLiveCardFixtureTransport: @unchecked Sendable, OpenClawChatTransport {
    static let sessionKey = "fixture-live-browser-card"
    private let continuationLock = NSLock()
    private var eventContinuation: AsyncStream<OpenClawChatTransportEvent>.Continuation?
    private weak var browserSession: BrowserLiveSession?

    init(browserSession: BrowserLiveSession) {
        self.browserSession = browserSession
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        try Self.decode(OpenClawChatHistoryPayload.self, from: [
            "sessionKey": sessionKey,
            "sessionId": "fixture-browser-session-id",
            "thinkingLevel": "low",
            "messages": [],
        ])
    }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey: String,
        attachments _: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        await browserSession?.beginBrowserRun(for: Self.sessionKey)
        await browserSession?.recordBrowserToolActivity(BrowserToolActivity(
            sessionKey: Self.sessionKey,
            runID: "fixture-browser-session-id",
            toolCallID: "fixture-browser-tabs",
            toolName: "browser",
            action: "tabs"))
        let startEvent = try Self.decode(OpenClawAgentEventPayload.self, from: [
            "runId": "fixture-browser-session-id",
            "seq": 1,
            "stream": "tool",
            "ts": 1,
            "data": [
                "phase": "start",
                "name": "browser",
                "toolCallId": "fixture-browser-tabs",
                "args": ["action": "tabs"],
            ],
        ])
        let resultEvent = try Self.decode(OpenClawAgentEventPayload.self, from: [
            "runId": "fixture-browser-session-id",
            "seq": 2,
            "stream": "tool",
            "ts": 2,
            "data": [
                "phase": "result",
                "name": "browser",
                "toolCallId": "fixture-browser-tabs",
                "result": ["ok": true],
            ],
        ])
        // Both events intentionally land before a render. `pendingToolCalls` returns to empty, while
        // the transport-captured evidence must still keep the live card visible.
        let continuation = continuationLock.withLock { eventContinuation }
        continuation?.yield(.agent(startEvent))
        continuation?.yield(.agent(resultEvent))
        return try Self.decode(OpenClawChatSendResponse.self, from: [
            "runId": idempotencyKey,
            "status": "started",
        ])
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { continuation in
            continuationLock.withLock { eventContinuation = continuation }
        }
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool { true }
    func abortRun(sessionKey _: String, runId _: String) async throws {}
    func listModels() async throws -> [OpenClawChatModelChoice] { [] }
    func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        OpenClawChatSessionsListResponse(
            ts: Date().timeIntervalSince1970 * 1000,
            path: nil,
            count: 0,
            defaults: OpenClawChatSessionsDefaults(
                model: nil,
                contextTokens: nil,
                thinkingLevels: nil,
                thinkingOptions: nil,
                thinkingDefault: "low",
                mainSessionKey: nil),
            sessions: [])
    }
    func setSessionModel(sessionKey _: String, model _: String?) async throws {}
    func setSessionThinking(sessionKey _: String, thinkingLevel _: String) async throws {}
    func setActiveSessionKey(_: String) async throws {}
    func resetSession(sessionKey _: String) async throws {}
    func compactSession(sessionKey _: String) async throws {}

    private static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}
#endif
