import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

#if DEBUG
/// README chat fixtures: render the REAL `SharedRemChatView` with a mock transport that
/// serves a short, realistic conversation, driven into the states the founder-facing gallery
/// documents. 100% mock data: no account, no network, no real names/emails.
///
/// Two entry points share the same shipping view and mock transport:
/// - `ReadmeChatFixtureView` (`--rem-chat-fixture`) — an in-progress **voice** conversation:
///   the VOICE CHAT bar in its live (listening) state replaces the text composer, so the
///   Speak button is gone and the bar shows mic · status/timer · red hang-up.
/// - `ReadmeBriefChatFixtureView` (`--rem-brief-chat-fixture`) — the **Daily Brief delivered as
///   chat**: the AI-authored brief sits in the transcript as an assistant turn (exactly how
///   `DailyBriefTranscriptReconciler` projects it into the durable `rem-orchestrator` session),
///   with the voice bar in its brief-reading state ("Latest Brief" · "Reading latest brief").

/// 06 — Chat in voice mode. The normal "Ask anything" composer is replaced at the bottom by the
/// live VOICE CHAT bar; there is no Speak button in voice mode.
struct ReadmeChatFixtureView: View {
    @State private var viewModel: OpenClawChatViewModel
    @State private var didLoad = false

    init() {
        let transport = ReadmeChatFixtureTransport(messages: ReadmeChatFixtureTransport.inboxConversation())
        self._viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: ReadmeChatFixtureTransport.sessionKey,
            transport: transport,
            initialThinkingLevel: "low"
        ))
    }

    var body: some View {
        NavigationStack {
            SharedRemChatView(
                viewModel: viewModel,
                isVoiceModeActive: true,
                onEndVoice: {},
                // Live "listening" state — a working voice session, not the error state.
                voiceStatusText: "Listening…",
                voiceIsReadingAloud: false,
                voiceIsMuted: false,
                onToggleMute: {},
                // ~3s in, so the bar's timer reads a small running value (e.g. 0:03).
                voiceStartDate: Date().addingTimeInterval(-3)
            )
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            viewModel.refresh()
        }
    }
}

/// 02 — The Daily Brief IS the chat. The authored brief is delivered into the transcript as an
/// assistant turn (not a standalone card), and the voice bar sits in its brief-reading state.
struct ReadmeBriefChatFixtureView: View {
    @State private var viewModel: OpenClawChatViewModel
    @State private var didLoad = false

    init() {
        let transport = ReadmeChatFixtureTransport(
            messages: ReadmeChatFixtureTransport.briefConversation(),
            sessionKey: ReadmeChatFixtureTransport.briefSessionKey
        )
        self._viewModel = State(initialValue: OpenClawChatViewModel(
            sessionKey: ReadmeChatFixtureTransport.briefSessionKey,
            transport: transport,
            initialThinkingLevel: "low"
        ))
    }

    var body: some View {
        NavigationStack {
            SharedRemChatView(
                viewModel: viewModel,
                isVoiceModeActive: true,
                onEndVoice: {},
                voiceStatusText: "Reading latest brief",
                // Brief-reading state → the bar reads "Latest Brief" / "Reading latest brief"
                // and the trailing control becomes Stop.
                voiceIsReadingAloud: true,
                voiceIsMuted: false,
                onToggleMute: {},
                onStopReadingAloud: {},
                voiceStartDate: Date().addingTimeInterval(-6)
            )
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
    /// The Daily Brief is delivered into the durable Today conversation; mirror that key so the
    /// fixture matches how the real brief-as-chat transcript is addressed.
    static let briefSessionKey = DailyBriefTranscriptReconciler.durableSessionKey

    private let messages: [[String: Any]]
    private let key: String

    init(messages: [[String: Any]], sessionKey: String = ReadmeChatFixtureTransport.sessionKey) {
        self.messages = messages
        self.key = sessionKey
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let payload: [String: Any] = [
            "sessionKey": sessionKey,
            "sessionId": "readme-chat-session",
            "thinkingLevel": "low",
            "messages": messages
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

    // MARK: - Mock conversations

    /// A user asking Rem to work a task and Rem reporting what it did.
    static func inboxConversation() -> [[String: Any]] {
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

    /// The AI-authored Daily Brief, delivered as a proactive assistant turn — the same shape
    /// `DailyBriefTranscriptReconciler` matches in the durable transcript.
    static func briefConversation() -> [[String: Any]] {
        let base = Date().timeIntervalSince1970 - 30
        return [
            message(
                role: "assistant",
                text: """
                Good morning — here's your day.

                Two things slipped and are worth clearing first:
                • Reply to the venue about Saturday's set — overdue since 8:00 AM
                • Send the updated setlist to the band — overdue since 9:30 AM

                On the calendar:
                • Coffee chat with a mentor at 7:00 PM
                • Rehearsal prep tomorrow at 6:00 PM

                Nothing else is urgent. Want me to draft the venue reply first?
                """,
                timestamp: base
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
