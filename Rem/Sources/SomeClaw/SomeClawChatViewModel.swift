import Foundation

enum SomeClawMessageRole: String {
    case user
    case assistant
    case errorEvent
}

struct SomeClawMessage: Identifiable, Equatable {
    let id: UUID
    var role: SomeClawMessageRole
    var text: String
    var isStreaming: Bool

    init(role: SomeClawMessageRole, text: String, isStreaming: Bool = false) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

/// Holds chat state for a single SomeClaw session: message list, streaming
/// buffer, and thinking indicator. Pure UI state — the WebSocket lifecycle is
/// owned by `SomeClawClient`.
@MainActor
@Observable
final class SomeClawChatViewModel {

    typealias Message = SomeClawMessage

    // MARK: - Public State

    private(set) var messages: [Message] = []
    private(set) var isThinking = false
    private(set) var sessionId: String
    private(set) var lastErrorMessage: String?

    let client: SomeClawClient

    // MARK: - Private State

    private var receiveTask: Task<Void, Never>?
    private var streamingMessageId: UUID?

    // MARK: - Init

    init(client: SomeClawClient, sessionId: String? = nil) {
        self.client = client
        self.sessionId = sessionId ?? Self.makeSessionId()
    }

    static func makeSessionId() -> String {
        "rem-\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Lifecycle

    func start() {
        client.connect()
        guard receiveTask == nil else { return }
        let stream = client.events
        receiveTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
    }

    // MARK: - Actions

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Message(role: .user, text: trimmed))
        isThinking = true
        streamingMessageId = nil
        do {
            try await client.sendChat(sessionId: sessionId, text: trimmed)
        } catch {
            isThinking = false
            lastErrorMessage = error.localizedDescription
            messages.append(Message(role: .errorEvent, text: error.localizedDescription))
        }
    }

    func startNewSession() async {
        let newId = SomeClawChatViewModel.makeSessionId()
        do {
            try await client.newSession(sessionId: newId)
            sessionId = newId
            messages.removeAll()
            isThinking = false
            streamingMessageId = nil
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearLocally() {
        messages.removeAll()
        isThinking = false
        streamingMessageId = nil
        lastErrorMessage = nil
    }

    // MARK: - Event Application

    /// Exposed `internal` so unit tests can drive the reducer without a
    /// live WebSocket connection.
    func apply(_ event: SomeClawClient.IncomingEvent) {
        switch event {
        case let .status(eventSession, _):
            guard eventSession == sessionId else { return }
            isThinking = true
        case let .chunk(eventSession, text, done):
            guard eventSession == sessionId else { return }
            applyChunk(text: text, done: done)
        case let .response(eventSession, text, done):
            guard eventSession == sessionId else { return }
            applyFinalResponse(text: text, done: done)
        case let .errorEvent(eventSession, text):
            // Server-level errors arrive without a session id; route those
            // through too. Anything tagged for a different session is dropped.
            guard eventSession == nil || eventSession == sessionId else { return }
            isThinking = false
            streamingMessageId = nil
            lastErrorMessage = text
            messages.append(Message(role: .errorEvent, text: text))
        case .sessions, .unknown:
            break
        }
    }

    private func applyChunk(text: String, done: Bool) {
        if let id = streamingMessageId, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
            if done {
                messages[index].isStreaming = false
                streamingMessageId = nil
                isThinking = false
            }
            return
        }
        var bubble = Message(role: .assistant, text: text, isStreaming: !done)
        if done { bubble.isStreaming = false }
        streamingMessageId = done ? nil : bubble.id
        if done { isThinking = false }
        messages.append(bubble)
    }

    private func applyFinalResponse(text: String, done: Bool) {
        if let id = streamingMessageId, let index = messages.firstIndex(where: { $0.id == id }) {
            // Some servers send the final `response` after a series of chunks
            // — prefer the buffer that already streamed in, since it includes
            // any intermediate edits the user has been watching.
            if messages[index].text.isEmpty {
                messages[index].text = text
            }
            messages[index].isStreaming = false
            streamingMessageId = nil
        } else {
            messages.append(Message(role: .assistant, text: text, isStreaming: false))
        }
        if done { isThinking = false }
    }
}
