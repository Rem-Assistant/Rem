import Foundation
import OpenClawChatUI
import OSLog

/// Explicit opt-in for short dogfood sampling runs. Production and ordinary debug launches take
/// the disabled path, so they create no trace actor and do no secondary agent-event decode.
nonisolated enum ChatLatencyDiagnostics {
    #if DEBUG
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--rem-chat-latency-sample")
    #else
    static let isEnabled = false
    #endif
}

/// Lightweight, app-side timing for the chat lifecycle.
///
/// This intentionally lives in Rem rather than OpenClawKit so we can measure
/// the transport phases that differ between iOS, macOS, local gateways, and
/// cloud gateways without taking a submodule bump for every instrumentation
/// adjustment.
actor ChatLatencyTrace {
    let platform: String

    private let logger = Logger(subsystem: "app.remclaw", category: "chat-latency")
    private let startedNanos: UInt64
    private var seenFirstChatEvent = false
    private var seenFirstAgentEvent = false
    private var seenFirstAssistantOutput = false
    private var seenFirstReasoningOutput = false
    private var seenFirstToolEvent = false
    private var toolReceiptStarts: [String: UInt64] = [:]
    private var finished = false

    init(
        platform: String,
        messageLength: Int,
        attachmentsCount: Int,
        startedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.platform = platform
        self.startedNanos = startedAtUptimeNanoseconds
    }

    func log(_ phase: String, details: String = "") {
        let message = Self.formattedMessage(
            platform: platform,
            phase: phase,
            elapsedMs: elapsedMsString(),
            details: details
        )
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        print(message)
        #endif
    }

    func markFirstChatEvent(state: String?) {
        guard !seenFirstChatEvent else { return }
        seenFirstChatEvent = true
        log("chat.event.first", details: "state=\(state ?? "nil")")
    }

    func recordAgentEvent(_ event: ChatLatencyAgentEventMetadata) {
        if !seenFirstAgentEvent {
            seenFirstAgentEvent = true
            log(
                "agent.event.first",
                details: "stream=\(event.stream) dataKeys=\(event.dataKeys.joined(separator: ","))"
            )
        }
        recordSpecificAgentPhase(event)
    }

    /// Records phase-specific timing without retaining or logging assistant, reasoning, tool-input,
    /// or tool-result content. `agent.event.first` is intentionally separate: a lifecycle event is
    /// proof that the gateway started emitting, but it is not proof that a model token was visible.
    func recordSpecificAgentPhase(_ event: ChatLatencyAgentEventMetadata) {
        if event.hasAssistantOutput, !seenFirstAssistantOutput {
            seenFirstAssistantOutput = true
            log("assistant.output.first")
        }
        if event.hasReasoningOutput, !seenFirstReasoningOutput {
            seenFirstReasoningOutput = true
            log("reasoning.output.first")
        }

        guard event.isToolEvent else { return }
        if !seenFirstToolEvent {
            seenFirstToolEvent = true
            log("tool.event.first", details: "phase=\(event.phase ?? "unknown")")
        }
        guard let toolCallID = event.toolCallID else { return }
        if event.isDirectToolEvent {
            switch event.phase {
            case "start":
                toolReceiptStarts[toolCallID] = DispatchTime.now().uptimeNanoseconds
                log("tool.received.start")
            case "result":
                var details: [String] = []
                if let start = toolReceiptStarts.removeValue(forKey: toolCallID) {
                    details.append("receiptDurationMs=\(Self.durationMsString(since: start))")
                }
                log("tool.received.end", details: details.joined(separator: " "))
            default:
                break
            }
        }
        if event.phase == "end" {
            if let sourceDurationMs = event.sourceDurationMs {
                log(
                    "tool.source.end",
                    details: "sourceDurationMs=\(String(format: "%.1f", sourceDurationMs))"
                )
            } else if let reason = event.sourceDurationInvalidReason {
                log("tool.source.invalid", details: "reason=\(reason)")
            }
        }
    }

    func finish(phase: String = "chat.final", details: String = "") {
        guard !finished else { return }
        finished = true
        log(phase, details: details)
    }

    func fail(details: String = "") {
        guard !finished else { return }
        finished = true
        log("chat.failed", details: details)
    }

    private func elapsedMsString() -> String {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(now - startedNanos) / 1_000_000
        return String(format: "%.1f", elapsedMs)
    }

    private static func durationMsString(since startNanos: UInt64) -> String {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000
        return String(format: "%.1f", elapsedMs)
    }

    nonisolated static func formattedMessage(
        platform: String,
        phase: String,
        elapsedMs: String,
        details: String
    ) -> String {
        let suffix = details.isEmpty ? "" : " \(details)"
        return "[ChatLatency] platform=\(platform) phase=\(phase) elapsedMs=\(elapsedMs)\(suffix)"
    }
}

/// Privacy-safe projection of an upstream OpenClaw agent event.
///
/// OpenClaw exposes a gateway-emission timestamp plus structured stream/phase/tool identifiers. It
/// does not expose provider request-start or provider first-token timestamps, so this type must not
/// be used to label `assistant.output.first` as provider TTFT. Text is decoded only to determine
/// whether displayable output exists and is discarded immediately; it is never retained or logged.
nonisolated struct ChatLatencyAgentEventMetadata: Decodable, Equatable, Sendable {
    let runID: String
    let sessionKey: String?
    let stream: String
    let sourceTimestampMs: Int?
    let dataKeys: [String]
    let phase: String?
    let kind: String?
    let toolCallID: String?
    let sourceStartedAtMs: Double?
    let sourceEndedAtMs: Double?
    let hasAssistantOutput: Bool
    let hasReasoningOutput: Bool

    var isToolEvent: Bool {
        stream.caseInsensitiveCompare("tool") == .orderedSame
            || kind?.caseInsensitiveCompare("tool") == .orderedSame
    }

    var isDirectToolEvent: Bool {
        stream.caseInsensitiveCompare("tool") == .orderedSame
    }

    var sourceDurationMs: Double? {
        guard let sourceStartedAtMs,
              let sourceEndedAtMs,
              sourceEndedAtMs >= sourceStartedAtMs
        else { return nil }
        return sourceEndedAtMs - sourceStartedAtMs
    }

    var sourceDurationInvalidReason: String? {
        guard let sourceStartedAtMs, let sourceEndedAtMs else { return nil }
        return sourceEndedAtMs < sourceStartedAtMs ? "end_before_start" : nil
    }

    private struct DataFields: Decodable {
        let phase: String?
        let kind: String?
        let toolCallId: String?
        let startedAt: Double?
        let endedAt: Double?
        let text: String?
        let delta: String?

        private struct DynamicCodingKey: CodingKey {
            let stringValue: String
            let intValue: Int? = nil

            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        let keys: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            keys = container.allKeys.map(\.stringValue).sorted()
            phase = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "phase")!)
            kind = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "kind")!)
            toolCallId = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "toolCallId")!)
            startedAt = try container.decodeIfPresent(Double.self, forKey: DynamicCodingKey(stringValue: "startedAt")!)
            endedAt = try container.decodeIfPresent(Double.self, forKey: DynamicCodingKey(stringValue: "endedAt")!)
            text = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "text")!)
            delta = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "delta")!)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runId
        case sessionKey
        case stream
        case ts
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runId)
        sessionKey = try container.decodeIfPresent(String.self, forKey: .sessionKey)
        stream = try container.decode(String.self, forKey: .stream)
        sourceTimestampMs = try container.decodeIfPresent(Int.self, forKey: .ts)
        let data = try container.decode(DataFields.self, forKey: .data)
        dataKeys = data.keys
        phase = data.phase
        kind = data.kind
        toolCallID = data.toolCallId
        sourceStartedAtMs = data.startedAt
        sourceEndedAtMs = data.endedAt
        let hasOutput = [data.delta, data.text].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        hasAssistantOutput = stream.caseInsensitiveCompare("assistant") == .orderedSame && hasOutput
        hasReasoningOutput = stream.caseInsensitiveCompare("thinking") == .orderedSame && hasOutput
    }
}

actor ChatLatencyTraceStore {
    private struct StoredTrace {
        let sessionKey: String
        let trace: ChatLatencyTrace
        let createdNanos: UInt64
    }

    private struct TerminalTombstone {
        let sessionKey: String
        let createdNanos: UInt64
    }

    private let enabled: Bool
    private let maximumTraceCount: Int
    private let maximumTombstoneCount: Int
    private let retentionNanos: UInt64
    private let nowNanos: @Sendable () -> UInt64
    private var pendingByIdempotencyKey: [String: StoredTrace] = [:]
    private var activeByRunID: [String: StoredTrace] = [:]
    private var terminalByRunID: [String: TerminalTombstone] = [:]

    init(
        enabled: Bool = ChatLatencyDiagnostics.isEnabled,
        maximumTraceCount: Int = 64,
        maximumTombstoneCount: Int = 128,
        retentionNanos: UInt64 = 5 * 60 * 1_000_000_000,
        nowNanos: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.enabled = enabled
        self.maximumTraceCount = max(1, maximumTraceCount)
        self.maximumTombstoneCount = max(1, maximumTombstoneCount)
        self.retentionNanos = retentionNanos
        self.nowNanos = nowNanos
    }

    @discardableResult
    func begin(
        platform: String,
        sessionKey: String,
        idempotencyKey: String,
        messageLength: Int,
        attachmentsCount: Int,
        startedAtUptimeNanoseconds: UInt64? = nil
    ) async -> ChatLatencyTrace? {
        guard enabled else { return nil }
        await prune()
        if let existing = pendingByIdempotencyKey[idempotencyKey] {
            guard existing.sessionKey == sessionKey else {
                pendingByIdempotencyKey.removeValue(forKey: idempotencyKey)
                await existing.trace.finish(
                    phase: "chat.evicted",
                    details: "reason=invalid_correlation"
                )
                return nil
            }
            return existing.trace
        }
        let trace = ChatLatencyTrace(
            platform: platform,
            messageLength: messageLength,
            attachmentsCount: attachmentsCount,
            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds ?? nowNanos()
        )
        pendingByIdempotencyKey[idempotencyKey] = StoredTrace(
            sessionKey: sessionKey,
            trace: trace,
            createdNanos: nowNanos()
        )
        await enforceTraceCap()
        return trace
    }

    func recordPreparation(
        platform: String,
        sessionKey: String,
        idempotencyKey: String,
        phase: OpenClawChatSendPreparationPhase,
        startedAtUptimeNanoseconds: UInt64? = nil,
        messageLength: Int,
        attachmentsCount: Int
    ) async {
        guard enabled else { return }
        let trace: ChatLatencyTrace?
        switch phase {
        case .started:
            trace = await begin(
                platform: platform,
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey,
                messageLength: messageLength,
                attachmentsCount: attachmentsCount,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds
            )
        default:
            await prune()
            trace = pendingByIdempotencyKey[idempotencyKey].flatMap {
                $0.sessionKey == sessionKey ? $0.trace : nil
            }
        }
        switch phase {
        case .started:
            await trace?.log(
                "send.preparation.start",
                details: "messageLength=\(messageLength) attachments=\(attachmentsCount)"
            )
        case .optimisticAppendCompleted:
            await trace?.log("optimistic.append.end")
        case .modelPatchWaitStarted:
            await trace?.log("model.patch.wait.start")
        case .modelPatchWaitEnded:
            await trace?.log("model.patch.wait.end")
        }
    }

    /// Associates the server-acknowledged run with its pending client send. If OpenClaw deduplicates
    /// onto an already-active run, preserve the original trace instead of overwriting it.
    @discardableResult
    func bind(
        runID: String,
        idempotencyKey: String,
        sessionKey: String
    ) async -> ChatLatencyTrace? {
        guard enabled else { return nil }
        await prune()
        guard let pending = pendingByIdempotencyKey.removeValue(forKey: idempotencyKey) else {
            guard let active = activeByRunID[runID], active.sessionKey == sessionKey else { return nil }
            return active.trace
        }
        guard pending.sessionKey == sessionKey else {
            await pending.trace.finish(phase: "chat.evicted", details: "reason=invalid_correlation")
            return nil
        }
        if let terminal = terminalByRunID[runID], terminal.sessionKey == sessionKey {
            await pending.trace.finish(phase: "chat.terminal_before_ack")
            return nil
        }
        if let existing = activeByRunID[runID] {
            guard existing.sessionKey == sessionKey else {
                await pending.trace.finish(phase: "chat.evicted", details: "reason=invalid_correlation")
                return nil
            }
            await pending.trace.finish(phase: "chat.deduplicated")
            return existing.trace
        }
        activeByRunID[runID] = pending
        await enforceTraceCap()
        return pending.trace
    }

    func active(runID: String?, sessionKey: String?) async -> ChatLatencyTrace? {
        guard enabled,
              let runID,
              let sessionKey
        else { return nil }
        await prune()
        if let terminal = terminalByRunID[runID], terminal.sessionKey == sessionKey {
            return nil
        }
        if let stored = activeByRunID[runID], stored.sessionKey == sessionKey {
            return stored.trace
        }
        // OpenClaw normally uses the idempotency key as runId. Its ack and first event can race on
        // separate client tasks, so allow that exact pending correlation until `bind` consumes it.
        if let pending = pendingByIdempotencyKey[runID], pending.sessionKey == sessionKey {
            return pending.trace
        }
        return nil
    }

    func terminate(
        runID: String?,
        sessionKey: String?,
        outcome: String,
        details: String = ""
    ) async {
        guard enabled, let runID, let sessionKey else { return }
        await prune()
        let stored: StoredTrace?
        if let active = activeByRunID[runID], active.sessionKey == sessionKey {
            activeByRunID.removeValue(forKey: runID)
            stored = active
        } else if let pending = pendingByIdempotencyKey[runID], pending.sessionKey == sessionKey {
            // A terminal event can arrive immediately after the gateway ack but before the send
            // task binds the response. Remove the pending correlation so a late bind cannot revive it.
            pendingByIdempotencyKey.removeValue(forKey: runID)
            stored = pending
        } else {
            stored = nil
        }
        recordTerminal(runID: runID, sessionKey: sessionKey, createdNanos: nowNanos())
        guard let stored else { return }
        let normalizedOutcome = outcome.lowercased()
        switch normalizedOutcome {
        case "final":
            await stored.trace.finish(details: details)
        case "aborted":
            await stored.trace.finish(phase: "chat.aborted", details: details)
        case "error":
            await stored.trace.finish(phase: "chat.error", details: details)
        default:
            await stored.trace.finish(phase: "chat.terminal", details: "outcome=\(normalizedOutcome) \(details)")
        }
    }

    func failPending(idempotencyKey: String, details: String = "") async {
        guard enabled else { return }
        await prune()
        let stored = pendingByIdempotencyKey.removeValue(forKey: idempotencyKey)
        await stored?.trace.fail(details: details)
    }

    // Store-level diagnostics used by pure unit tests; no identifiers are returned or logged.
    func counts() async -> (pending: Int, active: Int, terminal: Int) {
        await prune()
        return (pendingByIdempotencyKey.count, activeByRunID.count, terminalByRunID.count)
    }

    func prune() async {
        guard enabled else { return }
        let now = nowNanos()
        let expiredPending = pendingByIdempotencyKey.filter {
            Self.isExpired(createdNanos: $0.value.createdNanos, nowNanos: now, retentionNanos: retentionNanos)
        }
        let expiredActive = activeByRunID.filter {
            Self.isExpired(createdNanos: $0.value.createdNanos, nowNanos: now, retentionNanos: retentionNanos)
        }
        for (key, stored) in expiredPending {
            pendingByIdempotencyKey.removeValue(forKey: key)
            await stored.trace.finish(phase: "chat.evicted", details: "reason=expired")
        }
        for (key, stored) in expiredActive {
            activeByRunID.removeValue(forKey: key)
            recordTerminal(runID: key, sessionKey: stored.sessionKey, createdNanos: now)
            await stored.trace.finish(phase: "chat.evicted", details: "reason=expired")
        }
        terminalByRunID = terminalByRunID.filter {
            !Self.isExpired(
                createdNanos: $0.value.createdNanos,
                nowNanos: now,
                retentionNanos: retentionNanos
            )
        }
        await enforceTraceCap()
        pruneTombstoneCap()
    }

    private func enforceTraceCap() async {
        while pendingByIdempotencyKey.count + activeByRunID.count > maximumTraceCount {
            let oldestPending = pendingByIdempotencyKey.min { $0.value.createdNanos < $1.value.createdNanos }
            let oldestActive = activeByRunID.min { $0.value.createdNanos < $1.value.createdNanos }
            if let pending = oldestPending,
               oldestActive == nil || pending.value.createdNanos <= oldestActive!.value.createdNanos
            {
                pendingByIdempotencyKey.removeValue(forKey: pending.key)
                await pending.value.trace.finish(phase: "chat.evicted", details: "reason=capacity")
            } else if let active = oldestActive {
                activeByRunID.removeValue(forKey: active.key)
                recordTerminal(
                    runID: active.key,
                    sessionKey: active.value.sessionKey,
                    createdNanos: nowNanos()
                )
                await active.value.trace.finish(phase: "chat.evicted", details: "reason=capacity")
            } else {
                return
            }
        }
    }

    private func pruneTombstoneCap() {
        while terminalByRunID.count > maximumTombstoneCount,
              let oldest = terminalByRunID.min(by: { $0.value.createdNanos < $1.value.createdNanos })
        {
            terminalByRunID.removeValue(forKey: oldest.key)
        }
    }

    private func recordTerminal(runID: String, sessionKey: String, createdNanos: UInt64) {
        if let active = activeByRunID[runID], active.sessionKey != sessionKey {
            return
        }
        if let existing = terminalByRunID[runID], existing.sessionKey != sessionKey {
            return
        }
        terminalByRunID[runID] = TerminalTombstone(
            sessionKey: sessionKey,
            createdNanos: createdNanos
        )
        pruneTombstoneCap()
    }

    private nonisolated static func isExpired(
        createdNanos: UInt64,
        nowNanos: UInt64,
        retentionNanos: UInt64
    ) -> Bool {
        nowNanos >= createdNanos && nowNanos - createdNanos >= retentionNanos
    }
}
