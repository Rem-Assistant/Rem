import Foundation

/// Self-contained WebSocket client for the SomeClaw relay (`relay_server.py`).
///
/// The relay accepts JSON messages over `wss://` with optional self-signed TLS
/// — see issue #94 for protocol details. This client deliberately has no
/// OpenClaw dependency: SomeClaw is a separate Claude Code wrapper, not a
/// gateway. It is currently exposed only behind `#if DEBUG` for internal use.
///
/// Connection lifecycle:
/// - `connect()` is idempotent. Repeated calls while connected are no-ops.
/// - On unexpected disconnect, the client schedules an exponential-backoff
///   reconnect (up to 30s) as long as `disconnect()` was not called.
/// - WebSocket-level pings keep the connection alive (the relay does not
///   support JSON-level pings).
@MainActor
@Observable
final class SomeClawClient {

    // MARK: - Public Types

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// Decoded server-to-client event, faithful to the relay protocol.
    enum IncomingEvent: Equatable {
        case status(sessionId: String, state: String)
        case chunk(sessionId: String, text: String, done: Bool)
        case response(sessionId: String, text: String, done: Bool)
        case errorEvent(sessionId: String?, text: String)
        case sessions(ids: [String])
        case unknown(type: String)
    }

    enum ClientError: Error {
        case notConnected
        case encodingFailed
        case invalidEndpoint
    }

    // MARK: - Public State

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var lastEvent: IncomingEvent?

    /// AsyncStream consumers can subscribe to for decoded events.
    /// One stream per `connect()` call; consumers read all events including
    /// reconnection-recovered ones until `disconnect()` is invoked.
    var events: AsyncStream<IncomingEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    var endpoint: URL
    var allowSelfSignedCert: Bool

    // MARK: - Private State

    private var session: URLSession?
    private var sessionDelegate: SomeClawSessionDelegate?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<IncomingEvent>.Continuation] = [:]
    private var shouldStayConnected = false
    private var reconnectAttempt = 0

    // MARK: - Init

    init(endpoint: URL, allowSelfSignedCert: Bool = true) {
        self.endpoint = endpoint
        self.allowSelfSignedCert = allowSelfSignedCert
    }

    // MARK: - Connect / Disconnect

    func connect() {
        guard connectionState != .connected, connectionState != .connecting else { return }
        shouldStayConnected = true
        // Fresh user intent — clear any leftover backoff from a prior session.
        reconnectAttempt = 0
        openConnection()
    }

    func disconnect() {
        shouldStayConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown(reason: nil)
        connectionState = .disconnected
    }

    /// Reconfigure the endpoint. If currently connected, this disconnects and
    /// — when `shouldStayConnected` is true — reconnects to the new URL.
    func updateEndpoint(_ newEndpoint: URL, allowSelfSignedCert: Bool) {
        let wasConnected = shouldStayConnected
        disconnect()
        self.endpoint = newEndpoint
        self.allowSelfSignedCert = allowSelfSignedCert
        if wasConnected {
            connect()
        }
    }

    // MARK: - Send

    func sendChat(sessionId: String, text: String) async throws {
        try await sendJSON(["type": "message", "session_id": sessionId, "text": text])
    }

    func newSession(sessionId: String) async throws {
        try await sendJSON(["type": "new_session", "session_id": sessionId])
    }

    func listSessions() async throws {
        try await sendJSON(["type": "list_sessions"])
    }

    func clearSession(sessionId: String) async throws {
        try await sendJSON(["type": "clear_session", "session_id": sessionId])
    }

    // MARK: - Private: Connection

    private func openConnection() {
        connectionState = .connecting

        // The handshake-open callback is what actually proves the connection
        // succeeded — only then is it safe to clear the reconnect-backoff
        // counter. Resetting in `openConnection` itself would defeat backoff
        // for endpoints that fail immediately (#94 review).
        let delegate = SomeClawSessionDelegate(
            allowSelfSignedCert: allowSelfSignedCert,
            onOpen: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleHandshakeOpen()
                }
            }
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: endpoint)
        task.resume()

        self.sessionDelegate = delegate
        self.session = session
        self.task = task
        self.connectionState = .connected

        startReceiveLoop()
        startPing()
    }

    private func handleHandshakeOpen() {
        // Confirmed open by the URL loading system — clear backoff so that a
        // long-lived connection that later drops starts retrying from 1s again.
        reconnectAttempt = 0
    }

    private func teardown(reason: String?) {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: reason?.data(using: .utf8))
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
    }

    private func handleConnectionDrop(error: Error?) {
        teardown(reason: error?.localizedDescription)
        if let error {
            connectionState = .failed(error.localizedDescription)
        } else {
            connectionState = .disconnected
        }
        guard shouldStayConnected else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.shouldStayConnected else { return }
                self.openConnection()
            }
        }
    }

    // MARK: - Private: Receive

    private func startReceiveLoop() {
        receiveLoopTask?.cancel()
        guard let task else { return }
        receiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handleIncoming(message)
                } catch {
                    self?.handleConnectionDrop(error: error)
                    return
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let bytes):
            data = bytes
        case .string(let string):
            data = string.data(using: .utf8)
        @unknown default:
            data = nil
        }
        guard let data else { return }
        guard let event = SomeClawEventDecoder.decode(data) else { return }
        lastEvent = event
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Private: Send / Ping

    private func sendJSON(_ payload: [String: Any]) async throws {
        guard let task, connectionState == .connected else {
            throw ClientError.notConnected
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            throw ClientError.encodingFailed
        }
        try await task.send(.string(json))
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.task?.sendPing { _ in }
                }
            }
        }
    }
}

// MARK: - URLSession Delegate (TLS handling)

/// Stand-alone delegate so trust callbacks can be `nonisolated`. Bypassing
/// identity verification keeps the connection TLS-encrypted while accepting
/// the relay's self-signed certificate on the local network.
private final class SomeClawSessionDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    let allowSelfSignedCert: Bool
    let onOpen: @Sendable () -> Void

    init(allowSelfSignedCert: Bool, onOpen: @escaping @Sendable () -> Void) {
        self.allowSelfSignedCert = allowSelfSignedCert
        self.onOpen = onOpen
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowSelfSignedCert,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen()
    }
}

// MARK: - JSON decoding

/// Pure helper used by the client's main-actor receive loop. Kept separate so
/// it can be unit-tested without bringing up a WebSocket.
enum SomeClawEventDecoder {
    static func decode(_ data: Data) -> SomeClawClient.IncomingEvent? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = raw["type"] as? String else {
            return nil
        }
        let sessionId = raw["session_id"] as? String
        switch type {
        case "status":
            let state = raw["state"] as? String ?? ""
            return .status(sessionId: sessionId ?? "", state: state)
        case "chunk":
            let text = raw["text"] as? String ?? ""
            let done = raw["done"] as? Bool ?? false
            return .chunk(sessionId: sessionId ?? "", text: text, done: done)
        case "response":
            let text = raw["text"] as? String ?? ""
            let done = raw["done"] as? Bool ?? true
            return .response(sessionId: sessionId ?? "", text: text, done: done)
        case "error":
            // Relay sometimes sends `error` field instead of `text` — accept both.
            let text = (raw["text"] as? String) ?? (raw["error"] as? String) ?? "Unknown error"
            return .errorEvent(sessionId: sessionId, text: text)
        case "sessions":
            let ids = (raw["sessions"] as? [String])
                ?? (raw["sessions"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
                ?? []
            return .sessions(ids: ids)
        default:
            return .unknown(type: type)
        }
    }
}
