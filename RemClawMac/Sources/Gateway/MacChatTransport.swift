import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

// MARK: - Session Display Names (Mac-local)

/// Read/write session display names via UserDefaults.
/// Mac-local equivalent of the iOS SessionDisplayNames enum.
enum MacSessionDisplayNames {
    private static let key = "RemClaw.mac.sessionDisplayNames"
    private static let lock = NSLock()

    static func name(for sessionKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return dict?[sessionKey]
    }

    static func setName(_ displayName: String, for sessionKey: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        dict[sessionKey] = displayName
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func setNameIfAbsent(_ displayName: String, for sessionKey: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        guard dict[sessionKey] == nil else { return }
        dict[sessionKey] = displayName
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Seed an accepted sessions-list snapshot with at most one defaults write.
    /// Existing local/user-renamed titles always win.
    static func setNamesIfAbsent(_ namesBySessionKey: [String: String]) {
        guard !namesBySessionKey.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        var changed = false
        for (sessionKey, displayName) in namesBySessionKey where dict[sessionKey] == nil {
            dict[sessionKey] = displayName
            changed = true
        }
        guard changed else { return }
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func removeName(for sessionKey: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        dict.removeValue(forKey: sessionKey)
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func generateName(from message: String) -> String {
        var trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip legacy device context preambles from persisted sessions.
        if let range = trimmed.range(
            of: #"\[System: [^\]]*\]\s*"#,
            options: .regularExpression)
        {
            trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return "New conversation" }
        let maxLen = 40
        if trimmed.count <= maxLen { return trimmed }
        let prefix = trimmed.prefix(maxLen)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "..."
        }
        return String(prefix) + "..."
    }
}

/// Tracks last-message timestamps per session (Mac-local).
enum MacSessionLastMessageTimes {
    private static let key = "RemClaw.mac.sessionLastMessageTimes"

    static func timestamp(for sessionKey: String) -> Date? {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        guard let ms = dict?[sessionKey] else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static func touch(_ sessionKey: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        dict[sessionKey] = Date().timeIntervalSince1970 * 1000
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func remove(_ sessionKey: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        dict.removeValue(forKey: sessionKey)
        UserDefaults.standard.set(dict, forKey: key)
    }
}

/// Stores one-line preview of last message per session (Mac-local).
enum MacSessionLastMessagePreviews {
    private static let key = "RemClaw.mac.sessionLastMessagePreviews"

    static func preview(for sessionKey: String) -> String? {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return dict?[sessionKey]
    }

    static func remove(_ sessionKey: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        dict.removeValue(forKey: sessionKey)
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func setPreview(_ text: String, for sessionKey: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let trimmed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dict[sessionKey] = trimmed
        UserDefaults.standard.set(dict, forKey: key)
    }
}

// MARK: - Sendable Session Name Wrapper

/// Thin Sendable wrapper around MacSessionDisplayNames.
private final class SessionNameStore: @unchecked Sendable {
    func name(for sessionKey: String) -> String? {
        MacSessionDisplayNames.name(for: sessionKey)
    }
    func setName(_ name: String, for sessionKey: String) {
        MacSessionDisplayNames.setName(name, for: sessionKey)
    }
    func setNameIfAbsent(_ name: String, for sessionKey: String) {
        MacSessionDisplayNames.setNameIfAbsent(name, for: sessionKey)
    }
    static func nameFromMessage(_ message: String) -> String {
        MacSessionDisplayNames.generateName(from: message)
    }
}

// MARK: - Transport State

/// Shared transport state for cross-method coordination.
///
/// The event loop caches values that request methods need:
/// - `sessionId`: from chat.history, used to rewrite agent event runIds
/// - `finalMessage`: from chat.final, used to patch stale history responses
nonisolated private final class MacTransportState: @unchecked Sendable {
    struct Route: Equatable {
        let sessionKey: String
        let sessionId: String?
    }

    private let lock = NSLock()

    private var _sessionKey: String?
    private var _sessionId: String?
    private var _finalSessionKey: String?
    private var _finalMessage: OpenClawKit.AnyCodable?
    private var _sentSessionKey: String?
    private var _sentMessageText: String?
    private var _lifecycleEpoch = RunLifecycleEpoch.legacy

    var lifecycleEpoch: RunLifecycleEpoch { lock.withLock { _lifecycleEpoch } }

    func setLifecycleEpoch(_ epoch: RunLifecycleEpoch) {
        lock.withLock { _lifecycleEpoch = epoch }
    }

    var route: Route? {
        lock.withLock {
            guard let sessionKey = _sessionKey else { return nil }
            return Route(sessionKey: sessionKey, sessionId: _sessionId)
        }
    }

    func activate(sessionKey: String) {
        lock.withLock {
            guard _sessionKey != sessionKey else { return }
            _sessionKey = sessionKey
            _sessionId = nil
        }
    }

    func setSessionID(_ sessionId: String?, for sessionKey: String) {
        lock.withLock {
            guard _sessionKey == sessionKey else { return }
            _sessionId = sessionId
        }
    }
    var finalSessionKey: String? {
        get { lock.withLock { _finalSessionKey } }
        set { lock.withLock { _finalSessionKey = newValue } }
    }
    var finalMessage: OpenClawKit.AnyCodable? {
        get { lock.withLock { _finalMessage } }
        set { lock.withLock { _finalMessage = newValue } }
    }
    var sentSessionKey: String? {
        get { lock.withLock { _sentSessionKey } }
        set { lock.withLock { _sentSessionKey = newValue } }
    }
    var sentMessageText: String? {
        get { lock.withLock { _sentMessageText } }
        set { lock.withLock { _sentMessageText = newValue } }
    }

    /// Atomically reads and clears the final message + sent caches for a given
    /// session key. Returns nil if the cached key doesn't match.
    func consumeFinalState(for sessionKey: String) -> (finalMessage: OpenClawKit.AnyCodable, userText: String?)? {
        lock.withLock {
            guard _finalSessionKey == sessionKey, let msg = _finalMessage else { return nil }
            let userText = (_sentSessionKey == sessionKey) ? _sentMessageText : nil
            _finalMessage = nil
            _finalSessionKey = nil
            _sentMessageText = nil
            _sentSessionKey = nil
            return (msg, userText)
        }
    }
}

// MARK: - Mac Chat Memory Diagnostics

#if DEBUG
/// Lightweight counters for #601 dogfood memory investigations. The counters
/// stay DEBUG-only and intentionally avoid storing payloads or message text.
private final class MacChatMemoryDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var yieldedEvents = 0
    private var droppedEvents = 0
    private var chatEvents = 0
    private var agentEvents = 0
    private var historyRefreshes = 0
    private var lastHistoryPayloadBytes = 0
    private var lastHistoryMessageCount = 0
    private var largestHistoryPayloadBytes = 0

    nonisolated func recordHistory(payload: OpenClawChatHistoryPayload, rawBytes: Int) {
        let messageCount = payload.messages?.count ?? 0
        lock.withLock {
            historyRefreshes += 1
            lastHistoryPayloadBytes = rawBytes
            lastHistoryMessageCount = messageCount
            largestHistoryPayloadBytes = max(largestHistoryPayloadBytes, rawBytes)
            Self.logLocked(
                reason: "history",
                yieldedEvents: yieldedEvents,
                droppedEvents: droppedEvents,
                chatEvents: chatEvents,
                agentEvents: agentEvents,
                historyRefreshes: historyRefreshes,
                lastHistoryPayloadBytes: lastHistoryPayloadBytes,
                lastHistoryMessageCount: lastHistoryMessageCount,
                largestHistoryPayloadBytes: largestHistoryPayloadBytes
            )
        }
    }

    nonisolated func recordYield(_ result: AsyncStream<OpenClawChatTransportEvent>.Continuation.YieldResult, kind: String) {
        lock.withLock {
            let didDrop: Bool
            switch result {
            case .enqueued:
                yieldedEvents += 1
                didDrop = false
            case .dropped:
                yieldedEvents += 1
                droppedEvents += 1
                didDrop = true
            case .terminated:
                return
            @unknown default:
                yieldedEvents += 1
                didDrop = false
            }

            if kind == "chat" {
                chatEvents += 1
            } else if kind == "agent" {
                agentEvents += 1
            }

            let shouldLog = yieldedEvents % 100 == 0
                || (didDrop && (droppedEvents == 1 || droppedEvents % 25 == 0))
            guard shouldLog else { return }
            Self.logLocked(
                reason: kind,
                yieldedEvents: yieldedEvents,
                droppedEvents: droppedEvents,
                chatEvents: chatEvents,
                agentEvents: agentEvents,
                historyRefreshes: historyRefreshes,
                lastHistoryPayloadBytes: lastHistoryPayloadBytes,
                lastHistoryMessageCount: lastHistoryMessageCount,
                largestHistoryPayloadBytes: largestHistoryPayloadBytes
            )
        }
    }

    private static func logLocked(
        reason: String,
        yieldedEvents: Int,
        droppedEvents: Int,
        chatEvents: Int,
        agentEvents: Int,
        historyRefreshes: Int,
        lastHistoryPayloadBytes: Int,
        lastHistoryMessageCount: Int,
        largestHistoryPayloadBytes: Int
    ) {
        print(
            "[MacMemoryDiagnostics] reason=\(reason) yieldedEvents=\(yieldedEvents) "
                + "droppedEvents=\(droppedEvents) chatEvents=\(chatEvents) agentEvents=\(agentEvents) "
                + "historyRefreshes=\(historyRefreshes) lastHistoryPayloadBytes=\(lastHistoryPayloadBytes) "
                + "lastHistoryMessageCount=\(lastHistoryMessageCount) "
                + "largestHistoryPayloadBytes=\(largestHistoryPayloadBytes)"
        )
    }
}
#endif

private struct MacActiveQuotaDispatchKey: Hashable {
    let sessionKey: String
    let idempotencyKey: String
}

/// Reference-backed so every copy of `MacChatTransport` coordinates through live dispatches and a
/// bounded tail of resolved exact-run tombstones. Resolution is identity-checked: an older same-key
/// send cannot replace or unregister its successor.
final class MacActiveQuotaDispatchRegistry: @unchecked Sendable {
    private final class Entry {
        let boundary: MacGatewayDispatchBoundary
        var resolvedSequence: UInt64?

        init(boundary: MacGatewayDispatchBoundary, resolvedSequence: UInt64?) {
            self.boundary = boundary
            self.resolvedSequence = resolvedSequence
        }
    }

    private let lock = NSLock()
    private let maxResolvedEntries: Int
    private var nextResolvedSequence: UInt64 = 0
    private var entries: [MacActiveQuotaDispatchKey: Entry] = [:]

    init(maxResolvedEntries: Int = 128) {
        self.maxResolvedEntries = max(0, maxResolvedEntries)
    }

    func register(
        _ boundary: MacGatewayDispatchBoundary,
        sessionKey: String,
        idempotencyKey: String
    ) {
        lock.withLock {
            entries[MacActiveQuotaDispatchKey(
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )] = Entry(boundary: boundary, resolvedSequence: nil)
        }
    }

    func boundary(sessionKey: String, idempotencyKey: String) -> MacGatewayDispatchBoundary? {
        lock.withLock {
            entries[MacActiveQuotaDispatchKey(
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )]?.boundary
        }
    }

    func markResolved(
        _ boundary: MacGatewayDispatchBoundary,
        sessionKey: String,
        idempotencyKey: String
    ) {
        lock.withLock {
            let key = MacActiveQuotaDispatchKey(
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )
            guard entries[key]?.boundary === boundary else { return }
            nextResolvedSequence &+= 1
            let entry = entries[key]!
            entry.resolvedSequence = nextResolvedSequence
            if let acceptedRunID = boundary.acceptedRunID {
                let acceptedKey = MacActiveQuotaDispatchKey(
                    sessionKey: sessionKey,
                    idempotencyKey: acceptedRunID
                )
                if entries[acceptedKey] == nil || entries[acceptedKey] === entry {
                    entries[acceptedKey] = entry
                }
            }
            trimResolvedEntriesLocked()
        }
    }

    var resolvedEntryCount: Int {
        lock.withLock {
            Set(entries.values.compactMap { entry in
                entry.resolvedSequence == nil ? nil : ObjectIdentifier(entry)
            }).count
        }
    }

    private func trimResolvedEntriesLocked() {
        let resolvedByIdentity = entries.values.reduce(
            into: [ObjectIdentifier: Entry]()
        ) { result, entry in
            guard entry.resolvedSequence != nil else { return }
            result[ObjectIdentifier(entry)] = entry
        }
        let resolved = resolvedByIdentity.values.compactMap { entry -> (Entry, UInt64)? in
            guard let sequence = entry.resolvedSequence else { return nil }
            return (entry, sequence)
        }
        let excess = resolved.count - maxResolvedEntries
        guard excess > 0 else { return }
        for (entry, _) in resolved.sorted(by: { $0.1 < $1.1 }).prefix(excess) {
            entries = entries.filter { $0.value !== entry }
        }
    }
}

// MARK: - Mac Chat Transport

/// Chat transport for Rem for Mac.
/// Implements OpenClawChatTransport using the operator session for chat RPCs
/// and the event stream, at parity with the iOS IOSGatewayChatTransport.
struct MacChatTransport: OpenClawChatTransport, Sendable {
    typealias ChatLifecycleRequester = @Sendable (
        _ method: String,
        _ paramsJSON: String?,
        _ timeoutSeconds: Int
    ) async throws -> Data

    private let gateway: GatewayNodeSession
    private let state = MacTransportState()
    private let latencyTraces = ChatLatencyTraceStore()
    private let sessionDefaultsPatchCache = ChatSessionDefaultsPatchCache()
    private let sessionNames = SessionNameStore()
    private let activeQuotaDispatches = MacActiveQuotaDispatchRegistry()
    #if DEBUG
    nonisolated(unsafe) private let memoryDiagnostics = MacChatMemoryDiagnostics()
    #endif
    /// Called before sending a message to ensure the node session is alive.
    private let onWillSend: (@Sendable () async -> Void)?
    let quotaDispatchContext: MacQuotaDispatchContext?
    private let onChatSendAcknowledged: (@MainActor @Sendable (MacQuotaDispatchContext) -> Void)?
    private let chatLifecycleRequester: ChatLifecycleRequester?
    private let beforeChatGatewayStart: (@Sendable () async -> Void)?
    private let onPendingChatAbortJoined: (@Sendable () async -> Void)?
    private let afterChatDispatchAcknowledged: (@Sendable () async -> Void)?
    private let onRunLifecycleEvidence: (@MainActor @Sendable (RunLifecycleEvidence) -> Void)?
    private let lifecycleEpochSource: RunLifecycleEpochSource
    private let lifecycleTransportID: UUID
    private let onRunLifecycleEpoch: (@MainActor @Sendable (RunLifecycleEpoch) -> Void)?

    init(
        gateway: GatewayNodeSession,
        onWillSend: (@Sendable () async -> Void)? = nil,
        quotaDispatchContext: MacQuotaDispatchContext? = nil,
        onChatSendAcknowledged: (@MainActor @Sendable (MacQuotaDispatchContext) -> Void)? = nil,
        chatLifecycleRequester: ChatLifecycleRequester? = nil,
        beforeChatGatewayStart: (@Sendable () async -> Void)? = nil,
        onPendingChatAbortJoined: (@Sendable () async -> Void)? = nil,
        afterChatDispatchAcknowledged: (@Sendable () async -> Void)? = nil,
        onRunLifecycleEvidence: (@MainActor @Sendable (RunLifecycleEvidence) -> Void)? = nil,
        lifecycleEpochSource: RunLifecycleEpochSource? = nil,
        initialLifecycleLease: RunLifecycleTransportLease? = nil,
        onRunLifecycleEpoch: (@MainActor @Sendable (RunLifecycleEpoch) -> Void)? = nil
    ) {
        self.gateway = gateway
        self.onWillSend = onWillSend
        self.quotaDispatchContext = quotaDispatchContext
        self.onChatSendAcknowledged = onChatSendAcknowledged
        self.chatLifecycleRequester = chatLifecycleRequester
        self.beforeChatGatewayStart = beforeChatGatewayStart
        self.onPendingChatAbortJoined = onPendingChatAbortJoined
        self.afterChatDispatchAcknowledged = afterChatDispatchAcknowledged
        self.onRunLifecycleEvidence = onRunLifecycleEvidence
        let resolvedEpochSource = lifecycleEpochSource ?? RunLifecycleEpochSource()
        let resolvedLease = initialLifecycleLease ?? resolvedEpochSource.beginTransport()
        self.lifecycleEpochSource = resolvedEpochSource
        self.lifecycleTransportID = resolvedLease.transportID
        self.onRunLifecycleEpoch = onRunLifecycleEpoch
        state.setLifecycleEpoch(resolvedLease.epoch)
    }

    // MARK: - Session Key Normalization

    /// Strip the canonical "agent:{id}:" prefix from session keys.
    /// The gateway canonicalizes keys like "chat-xxx" to "agent:default:chat-xxx"
    /// but ChatViewModel uses raw keys.
    private static func stripCanonicalPrefix(_ sessionKey: String) -> String {
        guard sessionKey.hasPrefix("agent:") else { return sessionKey }
        let secondColon = sessionKey.dropFirst(6).firstIndex(of: ":")
        guard let idx = secondColon else { return sessionKey }
        return String(sessionKey[sessionKey.index(after: idx)...])
    }

    /// A bare app route may alias the primary `agent:main:` namespace, but it
    /// must never erase a different canonical agent identity. Agent events are
    /// broadcast gateway-wide, so suffix-only matching leaks same-named chats
    /// across agents.
    private static func sessionRouteMatches(event: String, active: String) -> Bool {
        if event == active { return true }
        let eventIsCanonical = event.hasPrefix("agent:")
        let activeIsCanonical = active.hasPrefix("agent:")
        guard eventIsCanonical != activeIsCanonical else { return false }

        let canonical = eventIsCanonical ? event : active
        let bare = eventIsCanonical ? active : event
        let parts = canonical.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "agent", parts[1] == "main" else { return false }
        return stripCanonicalPrefix(canonical) == bare
    }

    private struct AgentRouteEnvelope: Decodable {
        let sessionKey: String?
    }

    /// Agent events share one gateway connection across conversations. Fail closed unless the
    /// event belongs to the currently active route, then normalize its execution run id to the
    /// stable history session id expected by `OpenClawChatViewModel`.
    static func routedAgentEvent(
        _ payload: OpenClawAgentEventPayload,
        eventSessionKey: String?,
        activeSessionKey: String?,
        sessionId: String?
    ) -> OpenClawAgentEventPayload? {
        guard let eventSessionKey, let activeSessionKey else { return nil }
        guard sessionRouteMatches(event: eventSessionKey, active: activeSessionKey) else {
            return nil
        }
        guard let sessionId, payload.runId != sessionId,
              let encoded = try? JSONEncoder().encode(payload),
              var dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return payload }
        dict["runId"] = sessionId
        dict["run_id"] = sessionId
        guard let rewrittenData = try? JSONSerialization.data(withJSONObject: dict),
              let rewritten = try? JSONDecoder().decode(
                  OpenClawAgentEventPayload.self,
                  from: rewrittenData)
        else { return payload }
        return rewritten
    }

    /// Route a globally broadcast chat event before erasing its canonical
    /// agent identity. This keeps a foreign same-suffix final from entering the
    /// active history cache or triggering a transcript refresh.
    static func routedChatEvent(
        _ payload: OpenClawChatEventPayload,
        activeSessionKey: String?
    ) -> OpenClawChatEventPayload? {
        guard let eventSessionKey = payload.sessionKey,
              let activeSessionKey,
              sessionRouteMatches(event: eventSessionKey, active: activeSessionKey)
        else { return nil }
        guard eventSessionKey.hasPrefix("agent:"),
              let encoded = try? JSONEncoder().encode(payload),
              var dict = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return payload }

        let rawKey = stripCanonicalPrefix(eventSessionKey)
        dict["sessionKey"] = rawKey
        dict["session_key"] = rawKey
        guard let rewrittenData = try? JSONSerialization.data(withJSONObject: dict),
              let rewritten = try? JSONDecoder().decode(OpenClawChatEventPayload.self, from: rewrittenData)
        else { return payload }
        return rewritten
    }

    /// Map "label" to "displayName" in raw sessions.list JSON for sessions
    /// where displayName is missing.
    private static func mapLabelToDisplayName(_ data: Data) -> Data? {
        do {
            guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var sessions = dict["sessions"] as? [[String: Any]] else {
                return nil
            }
            var didMap = false
            for i in sessions.indices {
                let displayName = sessions[i]["displayName"] as? String
                let displayNameTrimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard displayNameTrimmed.isEmpty else { continue }

                guard let label = sessions[i]["label"] as? String,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                sessions[i]["displayName"] = label
                didMap = true
            }
            guard didMap else { return nil }
            dict["sessions"] = sessions
            return try JSONSerialization.data(withJSONObject: dict)
        } catch {
            return nil
        }
    }

    /// Strip canonical prefix from all session keys in a list response.
    private func stripCanonicalPrefixFromSessions(
        _ response: OpenClawChatSessionsListResponse
    ) -> OpenClawChatSessionsListResponse? {
        do {
            let data = try JSONEncoder().encode(response)
            guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var sessions = dict["sessions"] as? [[String: Any]] else {
                return nil
            }
            var didStrip = false
            for i in sessions.indices {
                guard let key = sessions[i]["key"] as? String,
                      key.hasPrefix("agent:") else { continue }
                sessions[i]["key"] = Self.stripCanonicalPrefix(key)
                didStrip = true
            }
            guard didStrip else { return nil }
            dict["sessions"] = sessions
            let patchedData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: patchedData)
        } catch {
            return nil
        }
    }

    // MARK: - OpenClawChatTransport

    func abortRun(sessionKey: String, runId: String) async throws {
        #if DEBUG
        print("[MacTransport] abortRun sessionKey=\(sessionKey) runId=\(runId)")
        #endif
        if let boundary = activeQuotaDispatches.boundary(
            sessionKey: sessionKey,
            idempotencyKey: runId
        ) {
            boundary.requestCancellation()
            await onPendingChatAbortJoined?()
            while true {
                if let acknowledgement = boundary.claimAcceptedRunForCancellation() {
                    do {
                        try await abortAcceptedRunAfterCancellation(
                            sessionKey: sessionKey,
                            runID: acknowledgement.runID
                        )
                        boundary.completeAcceptedRunAbort()
                    } catch {
                        boundary.failAcceptedRunAbort()
                        throw error
                    }
                }
                switch await boundary.waitUntilCancellationResolved() {
                case .resolved:
                    return
                case .retryableAbort:
                    continue
                }
            }
        }
        struct Params: Codable {
            var sessionKey: String
            var runId: String
        }
        let data = try JSONEncoder().encode(Params(sessionKey: sessionKey, runId: runId))
        let json = String(data: data, encoding: .utf8)
        _ = try await requestChatLifecycle(method: "chat.abort", paramsJSON: json, timeoutSeconds: 10)
        if ChatLatencyDiagnostics.isEnabled {
            await latencyTraces.terminate(
                runID: runId,
                sessionKey: sessionKey,
                outcome: "aborted",
                details: "source=abort.request"
            )
        }
    }

    private func requestChatLifecycle(
        method: String,
        paramsJSON: String?,
        timeoutSeconds: Int
    ) async throws -> Data {
        if let chatLifecycleRequester {
            return try await chatLifecycleRequester(method, paramsJSON, timeoutSeconds)
        }
        return try await gateway.request(
            method: method,
            paramsJSON: paramsJSON,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func abortAcceptedRunAfterCancellation(sessionKey: String, runID: String) async throws {
        struct Params: Codable {
            let sessionKey: String
            let runId: String
        }
        let data = try JSONEncoder().encode(Params(sessionKey: sessionKey, runId: runID))
        let json = String(data: data, encoding: .utf8)
        _ = try await requestChatLifecycle(
            method: "chat.abort",
            paramsJSON: json,
            timeoutSeconds: 10
        )
    }

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        let targetLimit = max(1, limit ?? SessionListPagination.initialLimit)
        guard targetLimit > SessionListPagination.pageSize else {
            return try await listSessionsLegacy(limit: limit)
        }
        do {
            return try await listSessionsInBoundedPages(targetLimit: targetLimit)
        } catch where SessionListEnrichmentFallback.shouldRetryMinimalParams(after: error) {
            #if DEBUG
            print("[MacTransport] paged sessions.list unsupported; using legacy cumulative request")
            #endif
            try Task.checkCancellation()
            return try await listSessionsLegacy(limit: targetLimit)
        }
    }

    func listModels() async throws -> [OpenClawChatModelChoice] {
        (try await listModelCatalog()).models
    }

    func listModelCatalog() async throws -> OpenClawChatModelCatalogSnapshot {
        #if DEBUG
        print("[MacTransport] listModels")
        #endif
        let data = try await gateway.request(
            method: "models.list",
            paramsJSON: nil,
            timeoutSeconds: 15)
        return try Self.decodeModelCatalog(from: data)
    }

    static func decodeModelCatalog(from data: Data) throws -> OpenClawChatModelCatalogSnapshot {
        let payload = try JSONDecoder().decode(ModelsListPayload.self, from: data)
        return OpenClawChatModelCatalogSnapshot(
            models: Self.modelChoices(from: payload),
            completeness: catalogCompleteness(from: payload.catalogComplete),
            provenance: payload.catalogSource)
    }

    static func decodeModelChoices(from data: Data) throws -> [OpenClawChatModelChoice] {
        modelChoices(from: try JSONDecoder().decode(ModelsListPayload.self, from: data))
    }

    private static func catalogCompleteness(
        from wireValue: Bool?
    ) -> OpenClawChatModelCatalogCompleteness {
        switch wireValue {
        case true: .complete
        case false: .incomplete
        case nil: .unknown
        }
    }

    private static func modelChoices(from result: ModelsListPayload) -> [OpenClawChatModelChoice] {
        result.models.map { model in
            OpenClawChatModelChoice(
                modelID: model.id,
                name: model.name,
                provider: model.provider,
                contextWindow: model.contextwindow)
        }
    }

    func setSessionModel(sessionKey: String, model: String?) async throws {
        #if DEBUG
        print("[MacTransport] setSessionModel sessionKey=\(sessionKey) model=\(model ?? "nil")")
        #endif
        // Explicit JSON null clears a retained session override; omitting the field does not.
        var params: [String: Any] = ["key": sessionKey]
        params["model"] = model ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: params)
        let paramsJSON = String(data: data, encoding: .utf8)
        _ = try await gateway.request(
            method: "sessions.patch",
            paramsJSON: paramsJSON,
            timeoutSeconds: 10)
    }

    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {
        #if DEBUG
        print("[MacTransport] setSessionThinking sessionKey=\(sessionKey) thinkingLevel=\(thinkingLevel)")
        #endif
        struct Params: Codable {
            let key: String
            let thinkingLevel: String
        }
        let data = try JSONEncoder().encode(Params(key: sessionKey, thinkingLevel: thinkingLevel))
        let paramsJSON = String(data: data, encoding: .utf8)
        _ = try await gateway.request(
            method: "sessions.patch",
            paramsJSON: paramsJSON,
            timeoutSeconds: 10)
    }

    private func listSessionsInBoundedPages(
        targetLimit: Int
    ) async throws -> OpenClawChatSessionsListResponse {
        var sessions: [OpenClawChatSessionEntry] = []
        var firstResponse: OpenClawChatSessionsListResponse?
        var lastResponse: OpenClawChatSessionsListResponse?
        var cursorUpdatedAt: Int64?
        var cursorKey: String?

        while sessions.count < targetLimit {
            try Task.checkCancellation()
            let pageLimit = min(SessionListPagination.pageSize, targetLimit - sessions.count)
            let cursorClause: String
            if let cursorUpdatedAt, let cursorKey,
               let keyData = try? JSONEncoder().encode(cursorKey),
               let keyJSON = String(data: keyData, encoding: .utf8)
            {
                cursorClause = "\"cursorUpdatedAt\":\(cursorUpdatedAt),\"cursorKey\":\(keyJSON),"
            } else {
                cursorClause = ""
            }
            let params = "{\"limit\":\(pageLimit),\(cursorClause)\"includeDerivedTitles\":true,\"includeLastMessage\":true}"
            let data = try await gateway.request(
                method: "sessions.list",
                paramsJSON: params,
                timeoutSeconds: 15)
            let processed = Self.mapLabelToDisplayName(data) ?? data
            let decoded = try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: processed)
            let normalized = stripCanonicalPrefixFromSessions(decoded) ?? decoded
            let page = injectSessionDisplayNames(normalized) ?? normalized
            firstResponse = firstResponse ?? page
            lastResponse = page
            sessions.append(contentsOf: page.sessions)
            guard !page.sessions.isEmpty, page.hasMore != false else { break }
            guard let boundary = decoded.sessions.last,
                  let updatedAt = boundary.updatedAt,
                  updatedAt.isFinite
            else {
                try Task.checkCancellation()
                return try await listSessionsLegacy(limit: targetLimit)
            }
            cursorUpdatedAt = Int64(updatedAt)
            cursorKey = boundary.key
        }

        let metadata = firstResponse ?? lastResponse
        let totalCount = lastResponse?.totalCount ?? metadata?.totalCount
        if SessionListPagination.shouldRestartAfterCursorDrift(
            receivedCount: sessions.count,
            totalCount: totalCount,
            targetLimit: targetLimit,
            hasMore: lastResponse?.hasMore)
        {
            try Task.checkCancellation()
            return try await listSessionsLegacy(limit: targetLimit)
        }
        return OpenClawChatSessionsListResponse(
            ts: lastResponse?.ts ?? metadata?.ts,
            path: metadata?.path,
            count: sessions.count,
            totalCount: totalCount,
            limitApplied: targetLimit,
            hasMore: lastResponse?.hasMore,
            defaults: metadata?.defaults,
            sessions: sessions)
    }

    private func listSessionsLegacy(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        #if DEBUG
        print("[MacTransport] listSessions limit=\(String(describing: limit))")
        #endif
        let limitClause = limit.map { "\"limit\":\($0)," } ?? ""
        let enrichedJSON = "{\(limitClause)\"includeDerivedTitles\":true,\"includeLastMessage\":true}"
        let fallbackJSON: String? = limit.map { "{\"limit\":\($0)}" }
        do {
            let res: Data
            do {
                res = try await gateway.request(
                    method: "sessions.list",
                    paramsJSON: enrichedJSON,
                    timeoutSeconds: 15)
            } catch where SessionListEnrichmentFallback.shouldRetryMinimalParams(after: error) {
                #if DEBUG
                print("[MacTransport] enriched sessions.list rejected; retrying minimal params")
                #endif
                res = try await gateway.request(
                    method: "sessions.list",
                    paramsJSON: fallbackJSON,
                    timeoutSeconds: 15)
            }
            #if DEBUG
            print("[MacTransport] listSessions got \(res.count) bytes")
            #endif

            let processedRes = Self.mapLabelToDisplayName(res) ?? res
            let response = try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: processedRes)
            let normalized = stripCanonicalPrefixFromSessions(response) ?? response
            return injectSessionDisplayNames(normalized) ?? normalized
        } catch {
            #if DEBUG
            print("[MacTransport] listSessions FAILED: \(error)")
            #endif
            throw error
        }
    }

    /// Activates a session and ensures tool events are enabled.
    func setActiveSessionKey(_ sessionKey: String) async throws {
        #if DEBUG
        print("[MacTransport] setActiveSessionKey=\(sessionKey)")
        #endif
        // Route global agent events immediately, including for a brand-new conversation that has
        // no history session id yet. Activating a different key clears the prior id atomically.
        state.activate(sessionKey: sessionKey)

        // Don't materialize a server-side session for a brand-new chat the
        // user hasn't sent a message to yet. `patchSessionDefaults` issues a
        // `sessions.patch`, which CREATES the session on the gateway. Those
        // empty sessions would otherwise surface as "Untitled" rows — here and,
        // because sessions.list is shared, on iOS too. A session is "real" once
        // it has a pinned local name (`sendMessage` pins it on first send;
        // `listSessions` pins it for existing sessions). `sendMessage` patches
        // again before sending, so tool-event visibility is set once a message
        // is actually sent.
        guard sessionNames.name(for: sessionKey) != nil else {
            #if DEBUG
            print("[MacTransport] setActiveSessionKey skip patch for fresh session \(sessionKey)")
            #endif
            return
        }
        await patchSessionDefaults(sessionKey: sessionKey, force: true)
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        #if DEBUG
        print("[MacTransport] requestHistory sessionKey=\(sessionKey)")
        #endif
        struct Params: Codable { var sessionKey: String }
        let data = try JSONEncoder().encode(Params(sessionKey: sessionKey))
        let json = String(data: data, encoding: .utf8)
        let rawPayload: OpenClawChatHistoryPayload
        do {
            let res = try await gateway.request(method: "chat.history", paramsJSON: json, timeoutSeconds: 15)
            rawPayload = try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: res)
            #if DEBUG
            memoryDiagnostics.recordHistory(payload: rawPayload, rawBytes: res.count)
            #endif
        } catch {
            throw error
        }

        // Strip server-injected timestamps and metadata from user messages
        let payload = cleanHistoryMessages(rawPayload) ?? rawPayload

        // Cache sessionId for agent event rewriting. Nil is authoritative for a fresh session and
        // must clear any prior conversation's id rather than leaving stale routing state behind.
        state.setSessionID(payload.sessionId, for: sessionKey)

        // If we have a cached final message (from chat.final event), patch the
        // history response if the server hasn't persisted yet.
        guard let cached = state.consumeFinalState(for: sessionKey) else {
            return payload
        }

        return patchHistoryIfStale(payload: payload, cachedMessage: cached.finalMessage, userMessageText: cached.userText) ?? payload
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]
    ) async throws -> OpenClawChatSendResponse {
        let dispatchBoundary = MacGatewayDispatchBoundary()
        activeQuotaDispatches.register(
            dispatchBoundary,
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey
        )
        defer {
            dispatchBoundary.resolve()
            activeQuotaDispatches.markResolved(
                dispatchBoundary,
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey
            )
        }
        let trace = ChatLatencyDiagnostics.isEnabled
            ? await latencyTraces.begin(
                platform: "macOS",
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey,
                messageLength: message.count,
                attachmentsCount: attachments.count
            )
            : nil
        await trace?.log(
            "send.start",
            details: "messageLength=\(message.count) attachments=\(attachments.count)"
        )
        // Probe node before sending -- if the node silently dropped,
        // reconnect it now so device commands work when the AI responds.
        let preflightStart = DispatchTime.now().uptimeNanoseconds
        await onWillSend?()
        await trace?.log("preflight.end", details: "durationMs=\(Self.durationMsString(since: preflightStart))")
        let patchStart = DispatchTime.now().uptimeNanoseconds
        let patchResult = await patchSessionDefaults(sessionKey: sessionKey)
        await trace?.log(
            "sessions.patch.end",
            details: "durationMs=\(Self.durationMsString(since: patchStart)) \(patchResult)"
        )

        struct Params: Codable {
            var sessionKey: String
            var message: String
            var thinking: String
            var attachments: [OpenClawChatAttachmentPayload]?
            var timeoutMs: Int
            var idempotencyKey: String
        }

        // Auto-name the session from the first message (local + server-side)
        let isFirstMessage = sessionNames.name(for: sessionKey) == nil

        // Match the native iOS path: keep the transcript equal to the user's text. The
        // `openclaw-macos` handshake registers this client/device, the nodes tool exposes its
        // live capabilities, and OpenClaw owns timestamp injection through userTimezone.
        var enrichedMessage = message

        // Daily Brief: fold the brief prose into the first reply of a legacy `rem-today-<day>`
        // session as HIDDEN context (stripped for display by MessageCleaner). The store
        // + strip live in Shared so both platforms behave identically; today only iOS
        // opens the brief chat, but this keeps the Mac transport correct if a user ever
        // replies into that legacy session there (e.g. cross-device). Durable `rem-orchestrator`
        // already contains its delivered visible artifact and is always a no-op here. #985.
        //
        // PEEK now, COMMIT after a successful send (see RemChatTransport for the
        // rationale): a failed first send must NOT burn the once-per-day guard.
        let didInjectBrief: Bool
        if let briefPreamble = BriefContext.peekPreamble(for: sessionKey) {
            enrichedMessage = briefPreamble + enrichedMessage
            didInjectBrief = true
        } else {
            didInjectBrief = false
        }

        let params = Params(
            sessionKey: sessionKey,
            message: enrichedMessage,
            thinking: thinking,
            attachments: attachments.isEmpty ? nil : attachments,
            timeoutMs: 120_000,
            idempotencyKey: idempotencyKey)
        let data = try JSONEncoder().encode(params)
        let json = String(data: data, encoding: .utf8)
        // Parity with iOS: name/preview from CLEANED text so a composer cloud-browser chip's hidden
        // directive block can't surface as the session title/preview (the composer is shared, so this
        // reaches Mac the moment a BrowserLiveSession is injected there). See RemChatTransport.
        let cleanedForDisplay = MessageCleaner.cleanUserMessageText(message)
        let displayText = !cleanedForDisplay.isEmpty
            ? cleanedForDisplay
            : (BrowserDirective.isChipSend(message) ? "Cloud browser" : "")
        let generatedName = SessionNameStore.nameFromMessage(displayText)
        MacSessionLastMessageTimes.touch(sessionKey)
        if !displayText.isEmpty {
            sessionNames.setNameIfAbsent(generatedName, for: sessionKey)
            MacSessionLastMessagePreviews.setPreview(displayText, for: sessionKey)
        }

        #if DEBUG
        print("[MacTransport] sendMessage sessionKey=\(sessionKey) message=\(message.prefix(50)) key=\(idempotencyKey)")
        #endif
        do {
            await trace?.log("chat.send.request")
            // Quota is already committed. A local Task is not dispatch evidence: cancellation may
            // win before its worker begins, and the durable token remains until the gateway returns
            // the exact accepted run. Cancellation after dispatch waits for that run, retires the
            // matching handoff, then aborts only that run.
            try Task.checkCancellation()
            let acknowledgement = try await MacQuotaGatewayDispatch.run(
                boundary: dispatchBoundary,
                dispatchContext: quotaDispatchContext,
                beforeGatewayStart: beforeChatGatewayStart,
                request: {
                    try await self.requestChatLifecycle(
                        method: "chat.send",
                        paramsJSON: json,
                        timeoutSeconds: 125
                    )
                },
                decodeRunID: { data in
                    try JSONDecoder().decode(OpenClawChatSendResponse.self, from: data).runId
                },
                onAcknowledged: { acknowledgement in
                    guard let context = acknowledgement.dispatchContext else { return }
                    await self.onChatSendAcknowledged?(context)
                },
                abortAcceptedRun: { acknowledgement in
                    try await self.abortAcceptedRunAfterCancellation(
                        sessionKey: sessionKey,
                        runID: acknowledgement.runID
                    )
                }
            )
            await afterChatDispatchAcknowledged?()
            let res = acknowledgement.responseData
            // Cache user message for history patching only on success
            state.sentSessionKey = sessionKey
            state.sentMessageText = message
            #if DEBUG
            print("[MacTransport] chat.send OK")
            #endif
            await trace?.log("chat.send.response", details: "bytes=\(res.count)")

            // Send succeeded — now burn the once-per-day brief guard. The throw
            // path below intentionally does NOT commit, so a failed first send
            // leaves the day un-injected for the retry.
            if didInjectBrief {
                BriefContext.commitInjection(for: sessionKey)
            }

            // Persist session label on the gateway so it survives reinstalls
            // and shows in sessions.list from any client.
            if isFirstMessage {
                Task {
                    struct PatchParams: Codable {
                        var key: String
                        var label: String
                    }
                    let patch = PatchParams(key: sessionKey, label: generatedName)
                    if let patchData = try? JSONEncoder().encode(patch),
                       let patchJSON = String(data: patchData, encoding: .utf8) {
                        _ = try? await self.gateway.request(
                            method: "sessions.patch",
                            paramsJSON: patchJSON,
                            timeoutSeconds: 10)
                        #if DEBUG
                        print("[MacTransport] sessions.patch label=\(generatedName) for \(sessionKey)")
                        #endif
                    }
                }
            }

            let response = try JSONDecoder().decode(OpenClawChatSendResponse.self, from: res)
            if ChatLatencyDiagnostics.isEnabled {
                await latencyTraces.bind(
                    runID: response.runId,
                    idempotencyKey: idempotencyKey,
                    sessionKey: sessionKey
                )
            }
            await onRunLifecycleEvidence?(Self.localRunLifecycleEvidence(
                sessionKey: sessionKey,
                runID: response.runId,
                connectionEpoch: state.lifecycleEpoch
            ))
            return response
        } catch {
            #if DEBUG
            print("[MacTransport] chat.send FAILED: \(error)")
            #endif
            let errorDetails = Self.errorDetails(error)
            await trace?.log("chat.send.failed", details: errorDetails)
            if ChatLatencyDiagnostics.isEnabled {
                await latencyTraces.failPending(idempotencyKey: idempotencyKey, details: errorDetails)
            }
            await sessionDefaultsPatchCache.invalidate(sessionKey: sessionKey)
            throw error
        }
    }

    func observeSendPreparation(
        sessionKey: String,
        idempotencyKey: String,
        phase: OpenClawChatSendPreparationPhase,
        startedAtUptimeNanoseconds: UInt64,
        messageLength: Int,
        attachmentsCount: Int
    ) async {
        guard ChatLatencyDiagnostics.isEnabled else { return }
        await latencyTraces.recordPreparation(
            platform: "macOS",
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey,
            phase: phase,
            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
            messageLength: messageLength,
            attachmentsCount: attachmentsCount
        )
    }

    /// Patches session defaults: enable tool event visibility and bind node
    /// execution to this Mac's node ID.
    @discardableResult
    private func patchSessionDefaults(sessionKey: String, force: Bool = false) async -> String {
        struct PatchParams: Codable {
            var key: String
            var verboseLevel: String
            var execNode: String
        }

        let nodeId = DeviceIdentityStore.loadOrCreate().deviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeId.isEmpty else { return "result=missing-node" }

        if !force {
            switch await sessionDefaultsPatchCache.decision(sessionKey: sessionKey, nodeId: nodeId) {
            case .skip(let ageSeconds):
                #if DEBUG
                print("[MacTransport] sessions.patch skipped cached execNode=\(nodeId.prefix(8))... age=\(ageSeconds)s for \(sessionKey)")
                #endif
                return "result=skipped ageSeconds=\(ageSeconds)"
            case .patch:
                break
            }
        }

        let params = PatchParams(key: sessionKey, verboseLevel: "on", execNode: nodeId)
        guard let data = try? JSONEncoder().encode(params),
              let json = String(data: data, encoding: .utf8) else { return "result=encode-failed" }

        do {
            _ = try await gateway.request(method: "sessions.patch", paramsJSON: json, timeoutSeconds: 10)
            await sessionDefaultsPatchCache.recordPatched(sessionKey: sessionKey, nodeId: nodeId)
            #if DEBUG
            print("[MacTransport] sessions.patch verboseLevel=on execNode=\(nodeId.prefix(8))... OK for \(sessionKey)")
            #endif
            return "result=patched"
        } catch {
            #if DEBUG
            print("[MacTransport] sessions.patch verboseLevel/execNode failed: \(error)")
            #endif
            await sessionDefaultsPatchCache.invalidate(sessionKey: sessionKey)
            return "result=failed \(Self.errorDetails(error))"
        }
    }

    func requestHealth(timeoutMs: Int) async throws -> Bool {
        let seconds = max(1, Int(ceil(Double(timeoutMs) / 1000.0)))
        let res = try await gateway.request(method: "health", paramsJSON: nil, timeoutSeconds: seconds)
        return (try? JSONDecoder().decode(OpenClawGatewayHealthOK.self, from: res))?.ok ?? true
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        guard let connectionEpoch = lifecycleEpochSource.issueSubscription(
            for: lifecycleTransportID
        ) else {
            return AsyncStream { continuation in continuation.finish() }
        }
        state.setLifecycleEpoch(connectionEpoch)
        return AsyncStream(OpenClawChatTransportEvent.self, bufferingPolicy: .bufferingNewest(200)) { continuation in
            let task = Task {
                await onRunLifecycleEpoch?(connectionEpoch)
                #if DEBUG
                print("[MacTransport] events() stream started")
                #endif
                let stream = await self.gateway.subscribeServerEvents()
                for await evt in stream {
                    if Task.isCancelled { return }
                    switch evt.event {
                    case "tick":
                        yieldEvent(.tick, kind: "tick", continuation: continuation)
                    case "seqGap":
                        yieldEvent(.seqGap, kind: "seqGap", continuation: continuation)
                    case "health":
                        guard let payload = evt.payload else { break }
                        let ok = (try? GatewayPayloadDecoding.decode(
                            payload, as: OpenClawGatewayHealthOK.self))?.ok ?? true
                        yieldEvent(.health(ok: ok), kind: "health", continuation: continuation)
                    case "chat":
                        guard let payload = evt.payload else { break }
                        if let decodedChatPayload = try? GatewayPayloadDecoding.decode(
                            payload, as: OpenClawChatEventPayload.self)
                        {
                            let route = state.route
                            guard let chatPayload = Self.routedChatEvent(
                                decodedChatPayload,
                                activeSessionKey: route?.sessionKey)
                            else {
                                #if DEBUG
                                print("[MacTransport] dropped unrouted chat event session=\(decodedChatPayload.sessionKey ?? "nil") active=\(route?.sessionKey ?? "nil")")
                                #endif
                                break
                            }

                            #if DEBUG
                            print("[MacTransport] chat event state=\(chatPayload.state ?? "nil") session=\(chatPayload.sessionKey ?? "nil")")
                            #endif
                            let terminalState = chatPayload.state?.lowercased()
                            if ChatLatencyDiagnostics.isEnabled {
                                let trace = await latencyTraces.active(
                                    runID: chatPayload.runId,
                                    sessionKey: chatPayload.sessionKey
                                )
                                await trace?.markFirstChatEvent(state: chatPayload.state)
                                if let terminalState,
                                   ["final", "aborted", "error"].contains(terminalState)
                                {
                                    await latencyTraces.terminate(
                                        runID: chatPayload.runId,
                                        sessionKey: chatPayload.sessionKey,
                                        outcome: terminalState
                                    )
                                }
                            }

                            if let state = chatPayload.state?.lowercased(),
                               let sessionKey = chatPayload.sessionKey,
                               let evidence = Self.terminalRunLifecycleEvidence(
                                   state: state,
                                   sessionKey: sessionKey,
                                   runID: chatPayload.runId,
                                   connectionEpoch: connectionEpoch
                               )
                            {
                                await onRunLifecycleEvidence?(evidence)
                            }

                            // Cache the message from "final" events. The gateway
                            // broadcasts "final" before persistence completes, so
                            // requestHistory() may return stale data.
                            if chatPayload.state == "final",
                               let msg = chatPayload.message,
                               let sk = chatPayload.sessionKey
                            {
                                state.finalSessionKey = sk
                                state.finalMessage = msg

                                // Update session preview with assistant's response
                                if let data = try? JSONEncoder().encode(msg),
                                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                    let text: String? = {
                                        if let t = dict["text"] as? String { return t }
                                        if let content = dict["content"] as? [[String: Any]] {
                                            return content.compactMap { $0["text"] as? String }.joined(separator: " ")
                                        }
                                        return nil
                                    }()
                                    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MacSessionLastMessagePreviews.setPreview(text, for: sk)
                                        MacSessionLastMessageTimes.touch(sk)
                                    }
                                }

                                #if DEBUG
                                print("[MacTransport] cached final message for session=\(sk)")
                                #endif
                            }

                            yieldEvent(.chat(chatPayload), kind: "chat", continuation: continuation)
                        } else {
                            #if DEBUG
                            print("[MacTransport] chat event DECODE FAILED")
                            #endif
                        }
                    case "agent":
                        guard let payload = evt.payload else { break }
                        guard let decodedPayload = try? GatewayPayloadDecoding.decode(
                            payload, as: OpenClawAgentEventPayload.self) else { break }
                        let latencyMetadata: ChatLatencyAgentEventMetadata? = ChatLatencyDiagnostics.isEnabled
                            ? (try? GatewayPayloadDecoding.decode(
                                payload,
                                as: ChatLatencyAgentEventMetadata.self))
                            : nil
                        let rawSessionKey = (try? GatewayPayloadDecoding.decode(
                            payload,
                            as: AgentRouteEnvelope.self
                        ))?.sessionKey
                        let route = state.route
                        let eventSessionKey = latencyMetadata?.sessionKey ?? rawSessionKey
                        guard let agentPayload = Self.routedAgentEvent(
                            decodedPayload,
                            eventSessionKey: eventSessionKey,
                            activeSessionKey: route?.sessionKey,
                            sessionId: route?.sessionId)
                        else {
                            #if DEBUG
                            print("[MacTransport] dropped unrouted agent event session=\(rawSessionKey ?? "nil") active=\(route?.sessionKey ?? "nil")")
                            #endif
                            break
                        }
                        let normalizedSessionKey = Self.stripCanonicalPrefix(eventSessionKey ?? "")
                        if let evidence = Self.activeRunLifecycleEvidence(
                            from: decodedPayload,
                            sessionKey: normalizedSessionKey,
                            connectionEpoch: connectionEpoch
                        ) {
                            await onRunLifecycleEvidence?(evidence)
                        }
                        #if DEBUG
                        print("[MacTransport] agent event stream=\(agentPayload.stream) runId=\(agentPayload.runId) sessionIdCache=\(route?.sessionId ?? "nil")")
                        #endif
                        if let latencyMetadata,
                           let eventSessionKey = latencyMetadata.sessionKey,
                           let trace = await latencyTraces.active(
                               runID: latencyMetadata.runID,
                               sessionKey: Self.stripCanonicalPrefix(eventSessionKey)
                           )
                        {
                            await trace.recordAgentEvent(latencyMetadata)
                        }
                        guard state.route?.sessionKey == route?.sessionKey else {
                            #if DEBUG
                            print("[MacTransport] dropped agent event after route changed")
                            #endif
                            break
                        }
                        yieldEvent(.agent(agentPayload), kind: "agent", continuation: continuation)
                    default:
                        break
                    }
                }
                #if DEBUG
                print("[MacTransport] events() stream ended")
                #endif
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func yieldEvent(
        _ event: OpenClawChatTransportEvent,
        kind: String,
        continuation: AsyncStream<OpenClawChatTransportEvent>.Continuation
    ) {
        let result = continuation.yield(event)
        #if DEBUG
        memoryDiagnostics.recordYield(result, kind: kind)
        #else
        _ = result
        #endif
    }

    private static func durationMsString(since startNanos: UInt64) -> String {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000
        return String(format: "%.1f", elapsedMs)
    }

    private static func errorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        return "errorDomain=\(nsError.domain) errorCode=\(nsError.code) errorType=\(String(reflecting: type(of: error)))"
    }

    private static func agentEventLooksToolRelated(_ payload: OpenClawAgentEventPayload) -> Bool {
        if payload.stream.localizedCaseInsensitiveContains("tool") {
            return true
        }
        return payload.data.keys.contains { key in
            key.localizedCaseInsensitiveContains("tool")
                || key.localizedCaseInsensitiveContains("command")
                || key.localizedCaseInsensitiveContains("invocation")
        }
    }

    static func activeRunLifecycleEvidence(
        from payload: OpenClawAgentEventPayload,
        sessionKey: String,
        connectionEpoch: RunLifecycleEpoch = RunLifecycleEvidence.defaultEpoch
    ) -> RunLifecycleEvidence? {
        let normalizedSessionKey = stripCanonicalPrefix(sessionKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let runID = payload.runId.trimmingCharacters(in: .whitespacesAndNewlines)
        let stream = payload.stream.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSessionKey.isEmpty, !runID.isEmpty,
              agentEventLooksToolRelated(payload)
                || stream.contains("thinking")
                || stream.contains("reasoning")
        else { return nil }
        return RunLifecycleEvidence(
            run: .init(sessionKey: normalizedSessionKey, runID: runID),
            phase: .active,
            connectionEpoch: connectionEpoch
        )
    }

    static func localRunLifecycleEvidence(
        sessionKey: String,
        runID: String,
        connectionEpoch: RunLifecycleEpoch = RunLifecycleEvidence.defaultEpoch
    ) -> RunLifecycleEvidence {
        RunLifecycleEvidence(
            run: .init(
                sessionKey: stripCanonicalPrefix(sessionKey),
                runID: runID
            ),
            phase: .localRegistered,
            connectionEpoch: connectionEpoch
        )
    }

    static func terminalRunLifecycleEvidence(
        state: String,
        sessionKey: String,
        runID: String?,
        connectionEpoch: RunLifecycleEpoch = RunLifecycleEvidence.defaultEpoch
    ) -> RunLifecycleEvidence? {
        let normalizedSessionKey = stripCanonicalPrefix(sessionKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionKey.isEmpty,
              let runID = runID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runID.isEmpty
        else { return nil }
        let outcome: RunLifecycleEvidence.TerminalOutcome
        switch state.lowercased() {
        case "final": outcome = .final
        case "aborted": outcome = .aborted
        case "error": outcome = .error
        default: return nil
        }
        return RunLifecycleEvidence(
            run: .init(sessionKey: normalizedSessionKey, runID: runID),
            phase: .terminal(outcome),
            connectionEpoch: connectionEpoch
        )
    }

    // MARK: - Session Display Names

    /// Inject client-generated display names into sessions that lack one.
    private func injectSessionDisplayNames(
        _ response: OpenClawChatSessionsListResponse
    ) -> OpenClawChatSessionsListResponse? {
        do {
            let responseData = try JSONEncoder().encode(response)
            guard var dict = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  var sessions = dict["sessions"] as? [[String: Any]] else {
                return nil
            }

            var didInject = false
            for i in sessions.indices {
                let existing = sessions[i]["displayName"] as? String
                // Inject our local (message-derived) name whenever the server's
                // displayName isn't a usable conversation title — empty, a
                // generic client name, or a device name ("Sam's MacBook Pro").
                guard !MessageCleaner.isUsableSessionTitle(existing) else { continue }

                guard let key = sessions[i]["key"] as? String,
                      let localName = sessionNames.name(for: key) else { continue }

                sessions[i]["displayName"] = localName
                didInject = true
            }

            guard didInject else { return nil }
            dict["sessions"] = sessions
            let patchedData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: patchedData)
        } catch {
            #if DEBUG
            print("[MacTransport] session name injection failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Message Cleaning

    /// Strip server-injected metadata from user message text.
    ///
    /// Delegates to the shared `MessageCleaner.cleanUserMessageText` so the
    /// history pre-clean can never drift from the render-time cleaner. This used
    /// to be a hand-maintained copy that (e.g.) missed the Daily Brief
    /// hidden-context block (#985) and the TalkMode prefix; keeping one
    /// implementation avoids re-introducing that gap.
    private static func cleanUserMessageText(_ text: String) -> String {
        MessageCleaner.cleanUserMessageText(text)
    }

    /// Clean server-injected metadata from user messages in a history payload.
    private func cleanHistoryMessages(
        _ payload: OpenClawChatHistoryPayload
    ) -> OpenClawChatHistoryPayload? {
        do {
            let payloadData = try JSONEncoder().encode(payload)
            guard var dict = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                return nil
            }
            guard var messagesArray = dict["messages"] as? [Any] else {
                return nil
            }

            var didClean = false
            for i in messagesArray.indices {
                guard var msg = messagesArray[i] as? [String: Any],
                      (msg["role"] as? String) == "user" else { continue }

                // Handle content as array of content blocks
                if var contentArray = msg["content"] as? [[String: Any]] {
                    for j in contentArray.indices {
                        guard let text = contentArray[j]["text"] as? String else { continue }
                        let cleaned = Self.cleanUserMessageText(text)
                        if cleaned != text {
                            contentArray[j]["text"] = cleaned
                            didClean = true
                        }
                    }
                    msg["content"] = contentArray
                    messagesArray[i] = msg
                }
                // Handle content as plain string
                else if let text = msg["content"] as? String {
                    let cleaned = Self.cleanUserMessageText(text)
                    if cleaned != text {
                        msg["content"] = cleaned
                        messagesArray[i] = msg
                        didClean = true
                    }
                }
            }

            guard didClean else { return nil }
            dict["messages"] = messagesArray
            let patchedData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: patchedData)
        } catch {
            return nil
        }
    }

    // MARK: - History Patching

    /// If the server's history is stale (missing the final assistant message),
    /// patch it with cached messages.
    private func patchHistoryIfStale(
        payload: OpenClawChatHistoryPayload,
        cachedMessage: OpenClawKit.AnyCodable,
        userMessageText: String?
    ) -> OpenClawChatHistoryPayload? {
        do {
            let payloadData = try JSONEncoder().encode(payload)
            guard var dict = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                return nil
            }
            var messagesArray = dict["messages"] as? [Any] ?? []

            // If the last message is already an assistant response, no patch needed.
            if let lastMsg = messagesArray.last as? [String: Any],
               (lastMsg["role"] as? String) == "assistant" {
                return nil
            }

            // If the user message isn't in the server response, prepend it
            if let text = userMessageText {
                let lastMsgIsUser = (messagesArray.last as? [String: Any])?["role"] as? String == "user"
                if !lastMsgIsUser {
                    let ts = Int(Date().timeIntervalSince1970 * 1000)
                    messagesArray.append([
                        "role": "user",
                        "content": [["type": "text", "text": text]],
                        "timestamp": ts
                    ] as [String: Any])
                }
            }

            // Append the cached assistant final message
            let cachedData = try JSONEncoder().encode(cachedMessage)
            let cachedObj = try JSONSerialization.jsonObject(with: cachedData)

            if let msgDict = cachedObj as? [String: Any] {
                messagesArray.append(msgDict)
            } else if let text = cachedObj as? String {
                let ts = Int(Date().timeIntervalSince1970 * 1000)
                messagesArray.append([
                    "role": "assistant",
                    "content": [["type": "text", "text": text]],
                    "timestamp": ts
                ] as [String: Any])
            } else {
                return nil
            }

            dict["messages"] = messagesArray
            let patchedData = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: patchedData)
        } catch {
            return nil
        }
    }
}
