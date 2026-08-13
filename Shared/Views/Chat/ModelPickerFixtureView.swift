import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

#if DEBUG
/// Auth-free model-picker proof. Automatic remains the default, the one supported managed
/// MiniMax model is available without exposing managed-provider siblings, and the authenticated
/// Anthropic provider expands into its explicit model choices through a nested submenu.
struct ModelPickerFixtureView: View {
    @State private var viewModel = OpenClawChatViewModel(
        sessionKey: ModelPickerFixtureTransport.sessionKey,
        transport: ModelPickerFixtureTransport(),
        initialThinkingLevel: "low")
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            SharedRemChatView(
                viewModel: viewModel,
                runtimeProviderAuthEvidence: .verified(["anthropic"]))
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            viewModel.load()
        }
    }
}

private final class ModelPickerFixtureTransport: @unchecked Sendable, OpenClawChatTransport {
    static let sessionKey = "fixture-model-picker"

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        try Self.decode(OpenClawChatHistoryPayload.self, from: [
            "sessionKey": sessionKey,
            "sessionId": "fixture-model-picker-id",
            "thinkingLevel": "low",
            "messages": [],
        ])
    }

    func listModels() async throws -> [OpenClawChatModelChoice] {
        [
            OpenClawChatModelChoice(
                modelID: "MiniMaxAI/MiniMax-M2.7",
                name: "MiniMax M2.7",
                provider: "gmi",
                contextWindow: 196_608),
            OpenClawChatModelChoice(
                modelID: "SomeOtherManagedModel",
                name: "Some Other Managed Model",
                provider: "gmi",
                contextWindow: 32_000),
            OpenClawChatModelChoice(
                modelID: "claude-sonnet-4-5",
                name: "Claude Sonnet 4.5",
                provider: "anthropic",
                contextWindow: 200_000),
        ]
    }

    func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        OpenClawChatSessionsListResponse(
            ts: Date().timeIntervalSince1970 * 1000,
            path: nil,
            count: 0,
            defaults: OpenClawChatSessionsDefaults(
                modelProvider: "gmi",
                model: "MiniMaxAI/MiniMax-M2.7",
                contextTokens: 196_608,
                thinkingLevels: nil,
                thinkingOptions: nil,
                thinkingDefault: "low",
                mainSessionKey: nil),
            sessions: [])
    }

    func sendMessage(
        sessionKey _: String,
        message _: String,
        thinking _: String,
        idempotencyKey _: String,
        attachments _: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        try Self.decode(OpenClawChatSendResponse.self, from: [
            "runId": "fixture-run",
            "status": "complete",
        ])
    }

    func abortRun(sessionKey _: String, runId _: String) async throws {}
    func setSessionModel(sessionKey _: String, model _: String?) async throws {}
    func setSessionThinking(sessionKey _: String, thinkingLevel _: String) async throws {}
    func requestHealth(timeoutMs _: Int) async throws -> Bool { true }
    func events() -> AsyncStream<OpenClawChatTransportEvent> { AsyncStream { $0.finish() } }
    func setActiveSessionKey(_: String) async throws {}
    func resetSession(sessionKey _: String) async throws {}
    func compactSession(sessionKey _: String) async throws {}

    private static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}
#endif
