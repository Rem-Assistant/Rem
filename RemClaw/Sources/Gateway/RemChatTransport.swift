import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import Foundation

/// Thin Sendable wrapper around the shared SessionDisplayNames enum.
/// The enum uses static methods (no stored state) so this is safe.
private final class SessionNameStore: @unchecked Sendable {
    func name(for sessionKey: String) -> String? {
        SessionDisplayNames.name(for: sessionKey)
    }
    func setName(_ name: String, for sessionKey: String) {
        SessionDisplayNames.setName(name, for: sessionKey)
    }
    func setNameIfAbsent(_ name: String, for sessionKey: String) {
        SessionDisplayNames.setNameIfAbsent(name, for: sessionKey)
    }
    static func nameFromMessage(_ message: String) -> String {
        SessionDisplayNames.generateName(from: message)
    }
}

/// Cross-method state shared by the iOS transport's request and event paths.
///
/// `chat.history` returns the stable agent session id, while live `agent` events carry the
/// gateway's execution run id. `OpenClawChatViewModel` filters those events against its history
/// `sessionId`, so the transport must normalize the event id exactly as `MacChatTransport` does.
nonisolated final class IOSChatTransportState: @unchecked Sendable {
    struct Route: Equatable {
        let sessionKey: String
        let sessionId: String?
    }

    private let lock = NSLock()
    private var _sessionKey: String?
    private var _sessionId: String?
    private var _lifecycleEpoch = RunLifecycleEpoch.legacy

    var route: Route? {
        lock.withLock {
            guard let sessionKey = _sessionKey else { return nil }
            return Route(sessionKey: sessionKey, sessionId: _sessionId)
        }
    }

    var lifecycleEpoch: RunLifecycleEpoch { lock.withLock { _lifecycleEpoch } }

    func setLifecycleEpoch(_ epoch: RunLifecycleEpoch) {
        lock.withLock { _lifecycleEpoch = epoch }
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
}

nonisolated final class ChatSendDispatchCoordinator: @unchecked Sendable {
    struct Key: Hashable { let sessionKey: String; let idempotencyKey: String }
    private enum State {
        case pending([UUID: CheckedContinuation<String?, Never>])
        case accepted(String)
    }
    private let lock = NSLock()
    private var states: [Key: State] = [:]
    private var acceptedOrder: [Key] = []
    private var cancelledWaiterIDs: Set<UUID> = []

    func begin(_ key: Key) { lock.withLock { states[key] = .pending([:]) } }

    func accept(_ key: Key, runID: String) {
        let waiters: [UUID: CheckedContinuation<String?, Never>] = lock.withLock {
            guard let state = states[key], case .pending(let waiters) = state else { return [:] }
            states[key] = .accepted(runID)
            let acceptedKey = Key(sessionKey: key.sessionKey, idempotencyKey: runID)
            states[acceptedKey] = .accepted(runID)
            acceptedOrder.append(key)
            if acceptedKey != key { acceptedOrder.append(acceptedKey) }
            while acceptedOrder.count > 256 {
                states.removeValue(forKey: acceptedOrder.removeFirst())
            }
            return waiters
        }
        waiters.values.forEach { $0.resume(returning: runID) }
    }

    func finish(_ key: Key) {
        let waiters: [UUID: CheckedContinuation<String?, Never>] = lock.withLock {
            guard let state = states[key], case .pending(let waiters) = state else { return [:] }
            states.removeValue(forKey: key)
            return waiters
        }
        waiters.values.forEach { $0.resume(returning: nil) }
    }

    func acceptedRunID(for key: Key) async throws -> String? {
        let waiterID = UUID()
        let runID = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: String?? = lock.withLock {
                    switch states[key] {
                    case .some(.pending(var waiters)):
                        if cancelledWaiterIDs.remove(waiterID) != nil {
                            return .some(nil)
                        }
                        waiters[waiterID] = continuation
                        states[key] = .pending(waiters)
                        return nil
                    case .some(.accepted(let runID)):
                        cancelledWaiterIDs.remove(waiterID)
                        return .some(runID)
                    case .none:
                        cancelledWaiterIDs.remove(waiterID)
                        return .some(nil)
                    }
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            self.cancelWaiter(waiterID, for: key)
        }
        try Task.checkCancellation()
        return runID
    }

    private func cancelWaiter(_ waiterID: UUID, for key: Key) {
        let continuation: CheckedContinuation<String?, Never>? = lock.withLock {
            guard let state = states[key], case .pending(var waiters) = state else { return nil }
            guard let continuation = waiters.removeValue(forKey: waiterID) else {
                // Cancellation handlers may run before their operation installs the continuation.
                cancelledWaiterIDs.insert(waiterID)
                return nil
            }
            states[key] = .pending(waiters)
            return continuation
        }
        continuation?.resume(returning: nil)
    }

    func retire(sessionKey: String, runID: String) {
        lock.withLock {
            states = states.filter { key, state in
                guard key.sessionKey == sessionKey else { return true }
                if case .accepted(let acceptedRunID) = state {
                    return acceptedRunID != runID
                }
                return true
            }
            acceptedOrder.removeAll { states[$0] == nil }
        }
    }

    func pendingWaiterCount(for key: Key) -> Int {
        lock.withLock {
            guard let state = states[key], case .pending(let waiters) = state else { return 0 }
            return waiters.count
        }
    }
}

struct IOSGatewayChatTransport: OpenClawChatTransport, Sendable {
    private let gateway: GatewayNodeSession
    private let state = IOSChatTransportState()
    private let latencyTraces = ChatLatencyTraceStore()
    private let sessionDefaultsPatchCache = ChatSessionDefaultsPatchCache()
    private let sessionNames = SessionNameStore()
    private let dispatchCoordinator = ChatSendDispatchCoordinator()
    /// Called before sending a message to ensure the node session is alive.
    private let onWillSend: (@Sendable () async -> Void)?
    /// Marks the exact boundary where the detached `chat.send` request begins. Preflight and
    /// encoding failures occur before this callback and can receive a terminal before-dispatch
    /// quota disposition.
    private let onChatSendDispatched: (@MainActor @Sendable () throws -> Void)?
    /// Retires the exact durable quota handoff only after the gateway accepts a run.
    private let onChatSendAccepted: (@MainActor @Sendable () -> Void)?
    private let chatLifecycleRequester: (@Sendable (
        _ method: String,
        _ paramsJSON: String?,
        _ timeoutSeconds: Int
    ) async throws -> Data)?
    /// Supplies prior transcript turns to PREPEND to a session's gateway history.
    /// Used for task-scoped continuation chats (`rem-task-<UUID>`): a cloud (AgentBox) run
    /// has no gateway session to replay, so its persisted turns (backend
    /// `task_chat_messages`, migration 025) are injected here as real prior messages
    /// — the chat opens the actual conversation, not an empty composer (#869 / #874).
    /// Returns [] for non-task sessions, so regular chats are unaffected.
    private let priorTranscriptProvider: (@Sendable (String) async throws -> [AnyCodable])?
    /// Publishes run starts and routed browser-tool starts before the chat view model consumes them.
    /// The UI stores this evidence durably, closing the start/result-before-render race from #1141.
    private let onBrowserRunBegan: (@MainActor @Sendable (String, Bool) -> Void)?
    private let onBrowserRunEnded: (@MainActor @Sendable (String, String?) -> Void)?
    private let onBrowserRunCancelled: (@MainActor @Sendable (String) -> Void)?
    private let onBrowserToolActivity: (@MainActor @Sendable (BrowserToolActivity) -> Void)?
    private let onRunLifecycleEvidence: (@MainActor @Sendable (RunLifecycleEvidence) -> Void)?
    private let lifecycleEpochSource: RunLifecycleEpochSource
    private let lifecycleTransportID: UUID
    private let onRunLifecycleEpoch: (@MainActor @Sendable (RunLifecycleEpoch) -> Void)?

    func pendingAbortWaiterCount(sessionKey: String, idempotencyKey: String) -> Int {
        dispatchCoordinator.pendingWaiterCount(for: .init(
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey
        ))
    }

    init(
        gateway: GatewayNodeSession,
        onWillSend: (@Sendable () async -> Void)? = nil,
        onChatSendDispatched: (@MainActor @Sendable () throws -> Void)? = nil,
        onChatSendAccepted: (@MainActor @Sendable () -> Void)? = nil,
        chatLifecycleRequester: (@Sendable (
            _ method: String,
            _ paramsJSON: String?,
            _ timeoutSeconds: Int
        ) async throws -> Data)? = nil,
        priorTranscriptProvider: (@Sendable (String) async throws -> [AnyCodable])? = nil,
        onBrowserRunBegan: (@MainActor @Sendable (String, Bool) -> Void)? = nil,
        onBrowserRunEnded: (@MainActor @Sendable (String, String?) -> Void)? = nil,
        onBrowserRunCancelled: (@MainActor @Sendable (String) -> Void)? = nil,
        onBrowserToolActivity: (@MainActor @Sendable (BrowserToolActivity) -> Void)? = nil,
        onRunLifecycleEvidence: (@MainActor @Sendable (RunLifecycleEvidence) -> Void)? = nil,
        lifecycleEpochSource: RunLifecycleEpochSource? = nil,
        initialLifecycleLease: RunLifecycleTransportLease? = nil,
        onRunLifecycleEpoch: (@MainActor @Sendable (RunLifecycleEpoch) -> Void)? = nil
    ) {
        self.gateway = gateway
        self.onWillSend = onWillSend
        self.onChatSendDispatched = onChatSendDispatched
        self.onChatSendAccepted = onChatSendAccepted
        self.chatLifecycleRequester = chatLifecycleRequester
        self.priorTranscriptProvider = priorTranscriptProvider
        self.onBrowserRunBegan = onBrowserRunBegan
        self.onBrowserRunEnded = onBrowserRunEnded
        self.onBrowserRunCancelled = onBrowserRunCancelled
        self.onBrowserToolActivity = onBrowserToolActivity
        self.onRunLifecycleEvidence = onRunLifecycleEvidence
        let resolvedEpochSource = lifecycleEpochSource ?? RunLifecycleEpochSource()
        let resolvedLease = initialLifecycleLease ?? resolvedEpochSource.beginTransport()
        self.lifecycleEpochSource = resolvedEpochSource
        self.lifecycleTransportID = resolvedLease.transportID
        self.onRunLifecycleEpoch = onRunLifecycleEpoch
        state.setLifecycleEpoch(resolvedLease.epoch)
    }

    /// History payload re-encode shape. OpenClawChatHistoryPayload has no public
    /// memberwise init across the module boundary, so we round-trip a merged payload
    /// through JSON. Fields mirror OpenClawChatHistoryPayload exactly.
    private struct MergedHistoryPayload: Codable {
        let sessionKey: String
        let sessionId: String?
        let messages: [AnyCodable]?
        let thinkingLevel: String?
    }

    /// Map "label" -> "displayName" in raw sessions.list JSON for sessions
    /// where displayName is missing. The gateway stores names set via
    /// sessions.patch under the "label" key, but OpenClawChatSessionEntry
    /// decodes from "displayName". Without this, cross-device sessions
    /// appear with nil displayName and may be filtered out.
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

    /// Strip the canonical `agent:<agentId>:` prefix the gateway adds to every
    /// custom session key, returning the bare alias the app + view model use
    /// (`agent:main:chat-abc` → `chat-abc`, `agent:main:main` → `main`). Returns
    /// `nil` for keys that are already bare (`main`, `global`, `unknown`) or not
    /// in canonical shape, so callers can leave those untouched.
    static func bareSessionKey(_ key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "agent" else { return nil }
        let rest = parts.dropFirst(2).joined(separator: ":")
        return rest.isEmpty ? nil : rest
    }

    /// Bare app keys alias only the primary `agent:main:` namespace. Preserve
    /// any other canonical agent identity because gateway agent events are
    /// globally broadcast and two agents may use the same chat suffix.
    private static func sessionRouteMatches(event: String, active: String) -> Bool {
        if event == active { return true }
        let eventBare = bareSessionKey(event)
        let activeBare = bareSessionKey(active)
        guard (eventBare == nil) != (activeBare == nil) else { return false }

        let canonical = eventBare != nil ? event : active
        let bare = eventBare != nil ? active : event
        let parts = canonical.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "agent", parts[1] == "main" else { return false }
        return (bareSessionKey(canonical) ?? canonical) == bare
    }

    /// Rebuild a chat event payload with its session key normalized from the
    /// canonical gateway form to the bare alias, so `OpenClawChatViewModel`'s
    /// session-key matching accepts events for runs it didn't start (voice /
    /// cross-device). Uses a Codable round-trip because the payload has no
    /// public memberwise initializer across the module boundary. No-op when the
    /// key is already bare.
    static func normalizingCanonicalSessionKey(
        _ payload: OpenClawChatEventPayload
    ) -> OpenClawChatEventPayload {
        guard let sessionKey = payload.sessionKey,
              let bare = bareSessionKey(sessionKey),
              bare != sessionKey,
              let data = try? JSONEncoder().encode(payload),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return payload }
        dict["sessionKey"] = bare
        guard let newData = try? JSONSerialization.data(withJSONObject: dict),
              let decoded = try? JSONDecoder().decode(OpenClawChatEventPayload.self, from: newData)
        else { return payload }
        return decoded
    }

    /// Chat events share the gateway broadcast stream just like agent events.
    /// Route before normalization so a foreign canonical agent cannot be
    /// collapsed onto the active bare-key conversation.
    static func routedChatEvent(
        _ payload: OpenClawChatEventPayload,
        activeSessionKey: String?
    ) -> OpenClawChatEventPayload? {
        guard let eventSessionKey = payload.sessionKey,
              let activeSessionKey,
              sessionRouteMatches(event: eventSessionKey, active: activeSessionKey)
        else { return nil }
        return normalizingCanonicalSessionKey(payload)
    }

    /// Rewrite a live agent event to the stable session id expected by `OpenClawChatViewModel`.
    /// The gateway execution run id and `chat.history.sessionId` are different identifiers; without
    /// this bridge, iOS silently drops streaming assistant and tool-call events. Mirrors the shipped
    /// Mac transport compatibility path.
    static func normalizingAgentRunID(
        _ payload: OpenClawAgentEventPayload,
        sessionId: String?
    ) -> OpenClawAgentEventPayload {
        guard let sessionId,
              payload.runId != sessionId,
              let data = try? JSONEncoder().encode(payload),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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

    /// Agent events are global on the gateway connection. Preserve the upstream `sessionKey`
    /// routing contract and fail closed before rewriting a run id, otherwise a late event from chat
    /// A can be relabelled with chat B's history session id and leak A's tool activity into B.
    static func routedAgentEvent(
        _ payload: OpenClawAgentEventPayload,
        eventSessionKey: String?,
        activeSessionKey: String?,
        sessionId: String?
    ) -> OpenClawAgentEventPayload? {
        guard let eventSessionKey, let activeSessionKey else { return nil }
        guard sessionRouteMatches(event: eventSessionKey, active: activeSessionKey) else { return nil }
        return normalizingAgentRunID(payload, sessionId: sessionId)
    }

    private struct AgentRouteEnvelope: Decodable {
        let sessionKey: String?
    }

    static func browserToolActivity(
        from payload: OpenClawAgentEventPayload,
        sessionKey: String
    ) -> BrowserToolActivity? {
        guard (payload.data["phase"]?.value as? String)?.lowercased() == "start",
              let toolName = payload.data["name"]?.value as? String,
              toolName.caseInsensitiveCompare("browser") == .orderedSame
                || toolName.caseInsensitiveCompare("canvas") == .orderedSame
        else { return nil }
        let toolCallID = payload.data["toolCallId"]?.value as? String
            ?? "\(payload.runId):\(payload.seq ?? 0):\(toolName)"
        return BrowserToolActivity(
            sessionKey: sessionKey,
            runID: payload.runId,
            toolCallID: toolCallID,
            toolName: toolName,
            action: BrowserCardStateResolver.argAction(payload.data["args"]))
    }

    /// Returns a usable, conversation-derived title, or nil for empty / generic
    /// client names / device names. Delegates to the shared
    /// `MessageCleaner.usableSessionTitle` so the device-name guard (the gateway
    /// labels a session with the connecting device's name — "iPhone 17 Pro")
    /// stays in one place across iOS + Mac.
    private static func usableTitle(_ value: Any?) -> String? {
        MessageCleaner.usableSessionTitle(value as? String)
    }

    func abortRun(sessionKey: String, runId: String) async throws {
        let exactRunID = try await dispatchCoordinator.acceptedRunID(for: .init(
            sessionKey: sessionKey,
            idempotencyKey: runId
        ))
        try Task.checkCancellation()
        guard let exactRunID else { return }
        #if DEBUG
        print("[RemTransport] abortRun sessionKey=\(sessionKey) runId=\(exactRunID)")
        #endif
        struct Params: Codable {
            var sessionKey: String
            var runId: String
        }
        let data = try JSONEncoder().encode(Params(sessionKey: sessionKey, runId: exactRunID))
        let json = String(data: data, encoding: .utf8)
        _ = try await requestChatLifecycle(
            method: "chat.abort",
            paramsJSON: json,
            timeoutSeconds: 10
        )
        dispatchCoordinator.retire(sessionKey: sessionKey, runID: exactRunID)
        if ChatLatencyDiagnostics.isEnabled {
            await latencyTraces.terminate(
                runID: exactRunID,
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

    /// A cancelled owner may not issue abort until `chat.send` has returned the exact run ID.
    /// Run this RPC outside the cancelled parent so teardown cannot turn it into an abort-before-send.
    private func abortAcceptedRunAfterCancellation(
        sessionKey: String,
        runID: String
    ) async throws {
        struct Params: Codable {
            let sessionKey: String
            let runId: String
        }
        let data = try JSONEncoder().encode(Params(sessionKey: sessionKey, runId: runID))
        let json = String(data: data, encoding: .utf8)
        let abortTask = Task.detached {
            try await self.requestChatLifecycle(
                method: "chat.abort",
                paramsJSON: json,
                timeoutSeconds: 10
            )
        }
        _ = try await abortTask.value
        dispatchCoordinator.retire(sessionKey: sessionKey, runID: runID)
    }

    /// Abort ALL active runs for a session — `chat.abort` with `runId` omitted (the gateway cancels
    /// every in-flight run for the sessionKey). Used by the browser takeover handshake, where we
    /// don't track a runId and just want the agent to stop driving the page.
    func abortActiveRuns(sessionKey: String) async throws {
        #if DEBUG
        print("[RemTransport] abortActiveRuns sessionKey=\(sessionKey)")
        #endif
        struct Params: Codable { var sessionKey: String }
        let data = try JSONEncoder().encode(Params(sessionKey: sessionKey))
        let json = String(data: data, encoding: .utf8)
        _ = try await self.gateway.request(method: "chat.abort", paramsJSON: json, timeoutSeconds: 10)
    }

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        let targetLimit = max(1, limit ?? SessionListPagination.initialLimit)
        guard targetLimit > SessionListPagination.pageSize else {
            return try await listSessionsLegacy(limit: limit)
        }
        do {
            return try await listSessionsInBoundedPages(targetLimit: targetLimit)
        } catch where SessionListEnrichmentFallback.shouldRetryMinimalParams(after: error) {
            // Compatibility for deployed gateways that predate keyset cursor
            // support. They retain the former cumulative request contract.
            print("[RemTransport] paged sessions.list unsupported; using legacy cumulative request")
            try Task.checkCancellation()
            return try await listSessionsLegacy(limit: targetLimit)
        }
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
            let page = injectSessionDisplayNames(decoded) ?? decoded
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
        print("[RemTransport] listSessions limit=\(String(describing: limit))")
        // Ask the gateway to read each transcript and return a stable, first-user-
        // message-derived title (`derivedTitle`) plus the real last-message text
        // (`lastMessagePreview`). These power two fixes:
        //   • title stability — the first-user-derived title stays on the
        //     accepted response instead of following per-turn label changes.
        //   • row subtitles — we show the actual last message instead of a
        //     generic "Conversation saved on your machine" placeholder.
        // Booleans are written as JSON literals (not Codable Bools) to dodge the
        // 1/0 encoding pitfall that trips INVALID_REQUEST on some gateways.
        let limitClause = limit.map { "\"limit\":\($0)," } ?? ""
        let enrichedJSON = "{\(limitClause)\"includeDerivedTitles\":true,\"includeLastMessage\":true}"
        // Minimal params for older gateways that reject the enrichment flags
        // (`additionalProperties: false` on the params schema).
        let fallbackJSON: String? = limit.map { "{\"limit\":\($0)}" }
        do {
            let res: Data
            do {
                res = try await self.gateway.request(method: "sessions.list", paramsJSON: enrichedJSON, timeoutSeconds: 15)
            } catch where SessionListEnrichmentFallback.shouldRetryMinimalParams(after: error) {
                print("[RemTransport] listSessions enriched params rejected (\(Self.errorDetails(error))); retrying minimal")
                res = try await self.gateway.request(method: "sessions.list", paramsJSON: fallbackJSON, timeoutSeconds: 15)
            }
            print("[RemTransport] listSessions got \(res.count) bytes")

            // Pre-process raw JSON: map "label" -> "displayName" for sessions
            // where displayName is missing.
            let processedRes = Self.mapLabelToDisplayName(res) ?? res

            let response = try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: processedRes)
            print("[RemTransport] listSessions decoded \(response.sessions.count) sessions")
            #if DEBUG
            for s in response.sessions {
                print("[RemTransport]   session key=\(s.key) displayName=\(s.displayName ?? "nil") updatedAt=\(s.updatedAt.map { String($0) } ?? "nil")")
            }
            if let rawStr = String(data: res, encoding: .utf8) {
                print("[RemTransport] raw sessions.list response: \(rawStr.prefix(2000))")
            }
            #endif

            // Inject client-generated display names for sessions missing one
            return injectSessionDisplayNames(response) ?? response
        } catch {
            print("[RemTransport] listSessions FAILED: \(error)")
            throw error
        }
    }

    /// Activates a session and ensures tool events are enabled.
    ///
    /// Operators receive all broadcast events without explicit subscription,
    /// but tool events are suppressed unless the session's verboseLevel is
    /// set to "on" or "full" (default is "off"). We patch the session to
    /// enable tool visibility.
    func setActiveSessionKey(_ sessionKey: String) async throws {
        // Switch the event route BEFORE any session patch can suspend. `OpenClawChatViewModel`
        // already considers this the new conversation when it calls us; leaving the previous route
        // active across the await would let a late tool event from chat A contaminate chat B.
        state.activate(sessionKey: sessionKey)
        #if DEBUG
        print("[RemTransport] setActiveSessionKey=\(sessionKey)")
        #endif

        // Don't materialize a server-side session for a brand-new chat the
        // user hasn't sent a message to yet. `patchSessionDefaults` issues a
        // `sessions.patch`, which CREATES the session on the gateway and makes
        // it surface in `sessions.list` as an empty "Untitled" row — the junk
        // the user sees after opening a chat and navigating away without
        // sending. A session is only "real" once it has a pinned local name:
        // `sendMessage` pins it on the first send, and `listSessions` pins it
        // for existing sessions opened from history. For a fresh, never-used
        // key there is no name, so we skip the patch here; `sendMessage` runs
        // `patchSessionDefaults` again before the first send, so tool-event
        // visibility (verboseLevel/execNode) is still set once a message is
        // actually sent.
        guard sessionNames.name(for: sessionKey) != nil else {
            #if DEBUG
            print("[RemTransport] setActiveSessionKey skip patch for fresh session \(sessionKey)")
            #endif
            return
        }

        await patchSessionDefaults(sessionKey: sessionKey, force: true)
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        #if DEBUG
        print("[RemTransport] requestHistory sessionKey=\(sessionKey)")
        #endif
        state.activate(sessionKey: sessionKey)
        do {
            let payload = try await requestGatewayHistory(sessionKey: sessionKey)
            state.setSessionID(payload.sessionId, for: sessionKey)
            let compatible = try await mergeCompatibilityGatewayHistory(
                into: payload,
                sessionKey: sessionKey
            )
            return try await mergePriorTranscript(into: compatible, sessionKey: sessionKey)
        } catch {
            throw error
        }
    }

    private func requestGatewayHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        struct Params: Codable { var sessionKey: String }
        let data = try JSONEncoder().encode(Params(sessionKey: sessionKey))
        let json = String(data: data, encoding: .utf8)
        let response = try await gateway.request(
            method: "chat.history",
            paramsJSON: json,
            timeoutSeconds: 15
        )
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: response)
    }

    /// Upgrade compatibility is a read-through union, not a session-list selection.
    /// OpenClaw's `chat.history` returns an empty successful payload for an unknown key,
    /// so probing the deterministic legacy alias neither creates a session nor needs the
    /// async/top-50 `sessions.list` cache. New sends remain on the canonical payload.
    private func mergeCompatibilityGatewayHistory(
        into payload: OpenClawChatHistoryPayload,
        sessionKey: String
    ) async throws -> OpenClawChatHistoryPayload {
        let aliases = TaskChatSessionIdentity.compatibilityHistorySessionKeys(for: sessionKey)
        // Normalize the primary payload before deciding whether aliases exist. Deleted or
        // ambiguous legacy task rows intentionally stay directly readable, and malformed
        // timestamp metadata in those rows must not make an otherwise valid turn disappear.
        var messages = TaskChatHistoryMerge.normalizedGatewayHistory(payload.messages ?? [])
        for alias in aliases {
            let legacy = try await requestGatewayHistory(sessionKey: alias)
            messages = TaskChatHistoryMerge.mergedGatewayCompatibility(
                legacyHistory: legacy.messages ?? [],
                canonicalHistory: messages
            )
        }
        let merged = MergedHistoryPayload(
            sessionKey: payload.sessionKey,
            sessionId: payload.sessionId,
            messages: messages,
            thinkingLevel: payload.thinkingLevel
        )
        let data = try JSONEncoder().encode(merged)
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: data)
    }

    /// Prepend a task-scoped session's persisted cloud-run transcript (if any) to the
    /// gateway history, so the chat renders the REAL prior conversation. No-op (returns
    /// the payload unchanged) when there's no provider, the session isn't task-scoped,
    /// or the transcript is empty. A task transcript fetch/decode failure propagates;
    /// silently returning only gateway turns would present a valid-looking partial
    /// execution history.
    private func mergePriorTranscript(
        into payload: OpenClawChatHistoryPayload,
        sessionKey: String
    ) async throws -> OpenClawChatHistoryPayload {
        guard let provider = priorTranscriptProvider else { return payload }
        let prior = try await provider(sessionKey)
        guard !prior.isEmpty else { return payload }

        // Cloud runs and gateway continuation can interleave in either order: a user
        // may chat before the first AgentBox run, or trigger another run after a
        // continuation. Merge by structured timestamps rather than assuming one
        // source always happened first. The sets remain disjoint.
        let merged = MergedHistoryPayload(
            sessionKey: payload.sessionKey,
            sessionId: payload.sessionId,
            messages: TaskChatHistoryMerge.merged(
                taskTranscript: prior,
                gatewayHistory: payload.messages ?? []
            ),
            thinkingLevel: payload.thinkingLevel
        )
        let data = try JSONEncoder().encode(merged)
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: data)
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        let dispatchKey = ChatSendDispatchCoordinator.Key(
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey
        )
        dispatchCoordinator.begin(dispatchKey)
        defer { dispatchCoordinator.finish(dispatchKey) }
        let trace = ChatLatencyDiagnostics.isEnabled
            ? await latencyTraces.begin(
                platform: "iOS",
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
        // Probe node before sending — if the node silently dropped,
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

        // Keep the transcript body equal to what the user sent. The native `openclaw-ios`
        // handshake already registers this client/device, the nodes tool exposes the connected
        // device dynamically, and OpenClaw adds the current timestamp to BodyForAgent from its
        // configured `agents.defaults.userTimezone`. Hidden `[System: ...]` text here could leak
        // into history/session titles and made Rem look like a generic webchat client.
        var enrichedMessage = message

        // Daily Brief: on the FIRST reply into the per-day brief conversation
        // session (`rem-today-<day>`), fold the brief prose in as HIDDEN context
        // so the agent is brief-aware without a visible seed turn (#985 completion).
        // The block is stripped for display by `MessageCleaner.cleanUserMessageText`,
        // so neither the optimistic echo nor the reloaded history shows it. The
        // helper is a no-op for every non-brief session. Prepended OUTERMOST so it
        // leads the message; the cleaner strips each block independently regardless
        // of order.
        //
        // This fallback is legacy-only. The backend advertises `rem-orchestrator` only after its
        // visible artifact is delivered, so durable chat must never resend that prose as a hidden
        // user message. `peekPreamble` enforces the namespace even for cross-device entry.
        //
        // PEEK now, COMMIT after a successful send: `peekPreamble` does NOT burn the
        // once-per-day guard. We only `commitInjection` below once `chat.send`
        // resolves — so if this (often slow, node-preflight-heavy) first send
        // throws, the day stays un-injected and the user's retry re-injects instead
        // of silently losing the brief context for the rest of the day.
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
        // Name/preview from the CLEANED text, not the raw wire message: the composer's cloud-browser
        // chip (and any other stripped block) prepends a hidden directive to `message`, which must
        // not surface as the session title or list preview. Skip when nothing visible remains (e.g. a
        // block-only takeover-control message) so it can't blank an existing name/preview.
        // Name/preview from the CLEANED text, not the raw wire message: the composer's cloud-browser
        // chip (and any other stripped block) prepends a hidden directive to `message`, which must
        // not surface as the session title or list preview. A chip send with no typed text has no
        // prose to name from → label it by the capability ("Cloud browser"). A block-only takeover
        // control message has neither → skip, so it can't blank an existing name/preview.
        let cleanedForDisplay = MessageCleaner.cleanUserMessageText(message)
        let displayText = !cleanedForDisplay.isEmpty
            ? cleanedForDisplay
            : (BrowserDirective.isChipSend(message) ? "Cloud browser" : "")
        let generatedName = SessionNameStore.nameFromMessage(displayText)
        SessionLastMessageTimes.touch(sessionKey)
        if !displayText.isEmpty {
            sessionNames.setNameIfAbsent(generatedName, for: sessionKey)
            SessionLastMessagePreviews.setPreview(displayText, for: sessionKey)
        }

        #if DEBUG
        print("[RemTransport] sendMessage sessionKey=\(sessionKey) message=\(message.prefix(50)) key=\(idempotencyKey)")
        #endif
        // Start the local browser-run placeholder only after all preflight/encoding work succeeds.
        // Every throwing exit from this point is owned by the cancellation catch below.
        // A Cloud browser attachment is an explicit browser launch request, not merely ordinary
        // prose that may or may not lead the model to choose a tool. Publish that intent with the
        // local run start so chat can show the live-browser card immediately; the later structured
        // browser tool event replaces this placeholder with the real run evidence.
        await onBrowserRunBegan?(sessionKey, BrowserDirective.isChipSend(message))
        do {
            await trace?.log("chat.send.request")
            // Once quota is committed, cancellation must resolve in strict wire order. Keep the
            // durable handoff while the detached request awaits gateway acceptance; only a decoded
            // run ID can retire it. A cancelled owner then aborts that exact accepted run.
            try Task.checkCancellation()
            let requestTask = Task.detached {
                try await self.onChatSendDispatched?()
                return try await self.requestChatLifecycle(
                    method: "chat.send",
                    paramsJSON: json,
                    timeoutSeconds: 125
                )
            }
            let res = try await requestTask.value
            let response = try JSONDecoder().decode(OpenClawChatSendResponse.self, from: res)
            dispatchCoordinator.accept(dispatchKey, runID: response.runId)
            await onChatSendAccepted?()
            if Task.isCancelled {
                try await abortAcceptedRunAfterCancellation(
                    sessionKey: sessionKey,
                    runID: response.runId
                )
                throw CancellationError()
            }
            #if DEBUG
            print("[RemTransport] chat.send OK")
            #endif
            await trace?.log("chat.send.response", details: "bytes=\(res.count)")

            // Send succeeded — now burn the once-per-day brief guard. On the throw
            // path below we intentionally do NOT commit, so a failed first send
            // leaves the day un-injected for the retry.
            if didInjectBrief {
                BriefContext.commitInjection(for: sessionKey)
            }

            Task { @MainActor in
                TelemetryService.shared.track(eventName: TelemetryEvent.chatMessageSent, properties: [
                    "session_key": sessionKey,
                    "message_length": message.count,
                    "is_first_message": isFirstMessage,
                ])
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
                        print("[RemTransport] sessions.patch label=\(generatedName) for \(sessionKey)")
                        #endif
                    }
                }
            }

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
            await onBrowserRunCancelled?(sessionKey)
            #if DEBUG
            print("[RemTransport] chat.send FAILED: \(error)")
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
            platform: "iOS",
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey,
            phase: phase,
            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
            messageLength: messageLength,
            attachmentsCount: attachmentsCount
        )
    }

    @discardableResult
    private func patchSessionDefaults(sessionKey: String, force: Bool = false) async -> String {
        // Enable tool event visibility and bind node execution to this iOS device.
        // Doing this before both bootstrap and send avoids stale session metadata.
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
                print("[RemTransport] sessions.patch skipped cached execNode=\(nodeId.prefix(8))… age=\(ageSeconds)s for \(sessionKey)")
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
            _ = try await self.gateway.request(method: "sessions.patch", paramsJSON: json, timeoutSeconds: 10)
            await sessionDefaultsPatchCache.recordPatched(sessionKey: sessionKey, nodeId: nodeId)
            #if DEBUG
            print("[RemTransport] sessions.patch verboseLevel=on execNode=\(nodeId.prefix(8))… OK for \(sessionKey)")
            #endif
            return "result=patched"
        } catch {
            // Best-effort — chat still works if this fails.
            #if DEBUG
            print("[RemTransport] sessions.patch verboseLevel/execNode failed: \(error)")
            #endif
            await sessionDefaultsPatchCache.invalidate(sessionKey: sessionKey)
            return "result=failed \(Self.errorDetails(error))"
        }
    }

    func resetSession(sessionKey: String) async throws {
        #if DEBUG
        print("[RemTransport] resetSession sessionKey=\(sessionKey)")
        #endif
        struct Params: Codable { var key: String }
        let data = try JSONEncoder().encode(Params(key: sessionKey))
        let json = String(data: data, encoding: .utf8)
        _ = try await self.gateway.request(method: "sessions.reset", paramsJSON: json, timeoutSeconds: 10)
    }

    func compactSession(sessionKey: String) async throws {
        #if DEBUG
        print("[RemTransport] compactSession sessionKey=\(sessionKey)")
        #endif
        struct Params: Codable { var key: String }
        let data = try JSONEncoder().encode(Params(key: sessionKey))
        let json = String(data: data, encoding: .utf8)
        _ = try await self.gateway.request(method: "sessions.compact", paramsJSON: json, timeoutSeconds: 30)
    }

    func listModels() async throws -> [OpenClawChatModelChoice] {
        (try await listModelCatalog()).models
    }

    func listModelCatalog() async throws -> OpenClawChatModelCatalogSnapshot {
        #if DEBUG
        print("[RemTransport] listModels")
        #endif
        let res = try await self.gateway.request(method: "models.list", paramsJSON: nil, timeoutSeconds: 15)
        return try Self.decodeModelCatalog(from: res)
    }

    static func decodeModelCatalog(from data: Data) throws -> OpenClawChatModelCatalogSnapshot {
        let result = try JSONDecoder().decode(ModelsListResult.self, from: data)
        let models = result.models.map { model in
            OpenClawChatModelChoice(
                modelID: model.id,
                name: model.name,
                provider: model.provider,
                contextWindow: model.contextwindow)
        }
        return OpenClawChatModelCatalogSnapshot(
            models: models,
            completeness: catalogCompleteness(from: result.catalogComplete),
            provenance: result.catalogSource)
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

    func setSessionModel(sessionKey: String, model: String?) async throws {
        #if DEBUG
        print("[RemTransport] setSessionModel sessionKey=\(sessionKey) model=\(model ?? "nil")")
        #endif
        // Build JSON manually so nil model encodes as null (not omitted).
        // The gateway requires explicit null to clear the model override.
        var dict: [String: Any] = ["key": sessionKey]
        dict["model"] = model ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: dict)
        let json = String(data: data, encoding: .utf8)
        _ = try await self.gateway.request(method: "sessions.patch", paramsJSON: json, timeoutSeconds: 10)
    }

    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {
        #if DEBUG
        print("[RemTransport] setSessionThinking sessionKey=\(sessionKey) thinkingLevel=\(thinkingLevel)")
        #endif
        struct Params: Codable {
            var key: String
            var thinkingLevel: String
        }
        let params = Params(key: sessionKey, thinkingLevel: thinkingLevel)
        let data = try JSONEncoder().encode(params)
        let json = String(data: data, encoding: .utf8)
        _ = try await self.gateway.request(method: "sessions.patch", paramsJSON: json, timeoutSeconds: 10)
    }

    func requestHealth(timeoutMs: Int) async throws -> Bool {
        let seconds = max(1, Int(ceil(Double(timeoutMs) / 1000.0)))
        let res = try await self.gateway.request(method: "health", paramsJSON: nil, timeoutSeconds: seconds)
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
                print("[RemTransport] events() stream started")
                #endif
                let stream = await self.gateway.subscribeServerEvents()
                for await evt in stream {
                    if Task.isCancelled { return }
                    switch evt.event {
                    case "tick":
                        continuation.yield(.tick)
                    case "seqGap":
                        continuation.yield(.seqGap)
                    case "health":
                        guard let payload = evt.payload else { break }
                        let ok = (try? GatewayPayloadDecoding.decode(
                            payload,
                            as: OpenClawGatewayHealthOK.self))?.ok ?? true
                        continuation.yield(.health(ok: ok))
                    case "chat":
                        guard let payload = evt.payload else { break }
                        if let decodedChatPayload = try? GatewayPayloadDecoding.decode(
                            payload,
                            as: OpenClawChatEventPayload.self)
                        {
                            let route = state.route
                            guard let chatPayload = Self.routedChatEvent(
                                decodedChatPayload,
                                activeSessionKey: route?.sessionKey)
                            else {
                                #if DEBUG
                                print("[RemTransport] dropped unrouted chat event session=\(decodedChatPayload.sessionKey ?? "nil") active=\(route?.sessionKey ?? "nil")")
                                #endif
                                break
                            }
                            #if DEBUG
                            print("[RemTransport] chat event state=\(chatPayload.state ?? "nil") session=\(chatPayload.sessionKey ?? "nil")")
                            #endif
                            let latencySessionKey = chatPayload.sessionKey.flatMap {
                                Self.bareSessionKey($0) ?? $0
                            }
                            let terminalState = chatPayload.state?.lowercased()
                            if ChatLatencyDiagnostics.isEnabled {
                                let trace = await latencyTraces.active(
                                    runID: chatPayload.runId,
                                    sessionKey: latencySessionKey
                                )
                                await trace?.markFirstChatEvent(state: chatPayload.state)
                                if let terminalState,
                                   ["final", "aborted", "error"].contains(terminalState)
                                {
                                    await latencyTraces.terminate(
                                        runID: chatPayload.runId,
                                        sessionKey: latencySessionKey,
                                        outcome: terminalState
                                    )
                                }
                            }

                            if let terminalState,
                               ["final", "aborted", "error"].contains(terminalState),
                               let rawSessionKey = chatPayload.sessionKey
                            {
                                let sessionKey = Self.bareSessionKey(rawSessionKey) ?? rawSessionKey
                                if let evidence = Self.terminalRunLifecycleEvidence(
                                    state: terminalState,
                                    sessionKey: sessionKey,
                                    runID: chatPayload.runId,
                                    connectionEpoch: connectionEpoch
                                ) {
                                    await onRunLifecycleEvidence?(evidence)
                                }
                                await onBrowserRunEnded?(sessionKey, chatPayload.runId)
                            }

                            // Update session preview with assistant's final response
                            if chatPayload.state == "final",
                               let msg = chatPayload.message,
                               let sk = chatPayload.sessionKey
                            {
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
                                        SessionLastMessagePreviews.setPreview(text, for: sk)
                                        SessionLastMessageTimes.touch(sk)
                                    }
                                }
                            }

                            // Normalize the canonical gateway session key
                            // (`agent:main:<key>`) back to the bare alias the
                            // chat view model uses (`<key>`) BEFORE handing the
                            // event to OpenClawChatViewModel. The gateway
                            // canonicalizes every custom key (see
                            // `session-store-key.ts: canonicalizeSessionKeyForAgent`),
                            // but the view model's `matchesCurrentSessionKey`
                            // only bridges the `main` ↔ `agent:main:main` pair.
                            // Without this, lifecycle events for a run the view
                            // model did not itself start (e.g. every VOICE turn,
                            // which goes through RemTalkModeManager's direct
                            // `chat.send`, so its runId is never in the view
                            // model's `pendingRuns`) are dropped on custom
                            // `chat-*` / `task-*` sessions — so `refreshHistoryAfterRun`
                            // never fires and the completed turn never lands in
                            // the transcript. Text turns are unaffected (their
                            // runId is "our run", which bypasses the key check).
                            continuation.yield(.chat(chatPayload))
                        } else {
                            #if DEBUG
                            print("[RemTransport] chat event DECODE FAILED")
                            #endif
                        }
                    case "agent":
                        guard let payload = evt.payload else { break }
                        guard let decodedPayload = try? GatewayPayloadDecoding.decode(
                            payload,
                            as: OpenClawAgentEventPayload.self) else { break }
                        let routeEnvelope = try? GatewayPayloadDecoding.decode(
                            payload,
                            as: AgentRouteEnvelope.self)
                        let latencyMetadata: ChatLatencyAgentEventMetadata? = ChatLatencyDiagnostics.isEnabled
                            ? (try? GatewayPayloadDecoding.decode(
                                payload,
                                as: ChatLatencyAgentEventMetadata.self))
                            : nil
                        let eventSessionKey = latencyMetadata?.sessionKey ?? routeEnvelope?.sessionKey
                        let route = state.route
                        guard let agentPayload = Self.routedAgentEvent(
                            decodedPayload,
                            eventSessionKey: eventSessionKey,
                            activeSessionKey: route?.sessionKey,
                            sessionId: route?.sessionId)
                        else {
                            #if DEBUG
                            print("[RemTransport] dropped unrouted agent event session=\(eventSessionKey ?? "nil") active=\(route?.sessionKey ?? "nil")")
                            #endif
                            break
                        }
                        let normalizedSessionKey = Self.bareSessionKey(eventSessionKey ?? "")
                            ?? eventSessionKey
                            ?? route?.sessionKey
                            ?? ""
                        if let evidence = Self.activeRunLifecycleEvidence(
                            from: decodedPayload,
                            sessionKey: normalizedSessionKey,
                            connectionEpoch: connectionEpoch
                        ) {
                            await onRunLifecycleEvidence?(evidence)
                        }
                        if let activity = Self.browserToolActivity(
                            from: decodedPayload,
                            sessionKey: normalizedSessionKey)
                        {
                            await onBrowserToolActivity?(activity)
                        }
                        #if DEBUG
                        print("[RemTransport] agent event stream=\(agentPayload.stream) runId=\(agentPayload.runId)")
                        #endif
                        if let latencyMetadata,
                           let trace = await latencyTraces.active(
                               runID: latencyMetadata.runID,
                               sessionKey: normalizedSessionKey
                           )
                        {
                            await trace.recordAgentEvent(latencyMetadata)
                        }
                        // Every callback above may suspend while navigation activates a
                        // different fresh session. Revalidate immediately before delivery so
                        // an event accepted for A cannot become B's first bound agent run.
                        guard state.route?.sessionKey == route?.sessionKey else {
                            #if DEBUG
                            print("[RemTransport] dropped agent event after route changed")
                            #endif
                            break
                        }
                        continuation.yield(.agent(agentPayload))
                    default:
                        break
                    }
                }
                #if DEBUG
                print("[RemTransport] events() stream ended")
                #endif
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
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
        let normalizedSessionKey = (bareSessionKey(sessionKey) ?? sessionKey)
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
                sessionKey: bareSessionKey(sessionKey) ?? sessionKey,
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
        let normalizedSessionKey = (bareSessionKey(sessionKey) ?? sessionKey)
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
                // generic client name, or a device name ("iPhone 17 Pro").
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
            print("[RemTransport] session name injection failed: \(error)")
            #endif
            return nil
        }
    }
}
