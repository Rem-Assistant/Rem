import Foundation
import Observation
import RemKit
import OSLog
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private let chatUILogger = Logger(subsystem: "ai.openclaw", category: "RemChatUI")

@MainActor
@Observable
// swiftlint:disable:next type_body_length
public final class RemChatViewModel {
    public static let defaultModelSelectionID = "__default__"

    public private(set) var messages: [RemChatMessage] = []
    public var input: String = "" {
        didSet { self.composerMutationRevision &+= 1 }
    }
    public private(set) var thinkingLevel: String
    public private(set) var thinkingLevelOptions: [RemChatThinkingLevelOption]
    public private(set) var modelSelectionID: String = "__default__"
    public private(set) var modelChoices: [RemChatModelChoice] = []
    public private(set) var modelCatalogCompleteness: RemChatModelCatalogCompleteness = .unknown
    public private(set) var modelCatalogProvenance: String?
    public private(set) var isLoading = false
    /// True from the synchronous acceptance of an authorized send until model reconciliation and
    /// its caller-supplied pre-dispatch work have finished. Unlike `isSending`, this covers the
    /// network window before a chat run exists so composer UIs can reject duplicate quota charges.
    public private(set) var isPreparingSend = false
    public private(set) var isSending = false
    public private(set) var isAborting = false
    public var errorText: String?
    public var attachments: [RemPendingAttachment] = [] {
        didSet { self.composerMutationRevision &+= 1 }
    }
    public private(set) var healthOK: Bool = false
    public private(set) var pendingRunCount: Int = 0

    public private(set) var sessionKey: String
    public private(set) var sessionId: String?
    public private(set) var streamingAssistantText: String?
    public private(set) var pendingToolCalls: [RemChatPendingToolCall] = []
    public private(set) var sessions: [RemChatSessionEntry] = []
    public private(set) var isRefreshingSessions = false
    public private(set) var sessionsHasMore: Bool?
    public private(set) var sessionsTotalCount: Int?
    /// Authoritative row window currently retained by this view model. A recreated Sessions
    /// surface uses it to refresh/delete against the same window instead of regressing to 100.
    public private(set) var sessionsLimitApplied: Int?
    public private(set) var sessionsLoadError: String?
    private let transport: any RemChatTransport
    private var sessionDefaults: RemChatSessionsDefaults?
    private let prefersExplicitThinkingLevel: Bool
    private let onThinkingLevelChanged: (@MainActor @Sendable (String) -> Void)?

    @ObservationIgnored
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var activeSendTask: Task<Void, Never>?
    private var nextBootstrapGeneration: UInt64 = 0
    private var activeBootstrapGeneration: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    /// Generation whose complete bootstrap is already painted. View appearance is not a refresh
    /// command: the same long-lived model can reappear after Sessions without invalidating its
    /// transcript. `refresh()` remains the explicit network-reload path.
    private var loadedSessionGeneration: UInt64?
    private var queuedSessionKeyAfterSend: String?
    private struct ComposerDraft {
        var input: String
        var attachments: [RemPendingAttachment]
    }
    /// Immutable composer payload captured synchronously when an authorized send is accepted.
    /// Model repair and quota authorization may suspend, so neither may read a later user edit.
    private struct AuthorizedSendSnapshot {
        var sourceInput: String
        var sourceAttachments: [RemPendingAttachment]
        var sourceComposerMutationRevision: UInt64
        var message: String
        var attachments: [RemPendingAttachment]
        var thinkingLevel: String
    }
    /// Monotonic ownership token for the whole composer. Text and attachments form one draft:
    /// if either changes while send preparation suspends, that newer draft must never be cleared
    /// or combined with restored pieces from the accepted payload.
    private var composerMutationRevision: UInt64 = 0
    private var composerDraftsBySession: [String: ComposerDraft] = [:]
    private var sessionRefreshCount = 0
    private var nextSessionListRequestID: UInt64 = 0
    private var appliedSessionListRequestID: UInt64 = 0
    private var appliedSessionListLimit = 0
    /// Freshness for session defaults and load-error state is independent from the row-window
    /// watermark: an older bounded bootstrap may preserve rows, but it must not clear or replace
    /// metadata/error state produced by a newer pagination request.
    private var appliedSessionMetadataRequestID: UInt64 = 0
    private var confirmedActiveSessionKey: String?
    private var pendingRuns = Set<String>() {
        didSet { self.pendingRunCount = self.pendingRuns.count }
    }
    private var preparingRuns = Set<String>()

    @ObservationIgnored
    private nonisolated(unsafe) var pendingRunTimeoutTasks: [String: Task<Void, Never>] = [:]
    private let pendingRunTimeoutMs: UInt64 = 120_000
    // Session switches can overlap in-flight picker patches, so stale completions
    // must compare against the latest request and latest desired value for that session.
    private var nextModelSelectionRequestID: UInt64 = 0
    private var latestModelSelectionRequestIDsBySession: [String: UInt64] = [:]
    private var latestModelSelectionIDsBySession: [String: String] = [:]
    private var lastSuccessfulModelSelectionIDsBySession: [String: String] = [:]
    private var inFlightModelPatchCountsBySession: [String: Int] = [:]
    private var modelPatchWaitersBySession: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var nextThinkingSelectionRequestID: UInt64 = 0
    private var latestThinkingSelectionRequestIDsBySession: [String: UInt64] = [:]
    private var latestThinkingLevelsBySession: [String: String] = [:]
    private var isCompacting = false
    private var lastCompactAt: Date?
    private let compactCooldown: TimeInterval = 60

    private var pendingToolCallsById: [String: RemChatPendingToolCall] = [:] {
        didSet {
            self.pendingToolCalls = self.pendingToolCallsById.values
                .sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        }
    }

    private var lastHealthPollAt: Date?

    public init(
        sessionKey: String,
        transport: any RemChatTransport,
        initialThinkingLevel: String? = nil,
        onThinkingLevelChanged: (@MainActor @Sendable (String) -> Void)? = nil)
    {
        self.sessionKey = sessionKey
        self.transport = transport
        let normalizedThinkingLevel = Self.normalizedThinkingLevel(initialThinkingLevel)
        let initialResolvedThinkingLevel = normalizedThinkingLevel ?? "off"
        self.thinkingLevel = initialResolvedThinkingLevel
        self.thinkingLevelOptions = Self.withCurrentThinkingOption(
            Self.baseThinkingLevelOptions,
            current: initialResolvedThinkingLevel)
        self.prefersExplicitThinkingLevel = normalizedThinkingLevel != nil
        self.onThinkingLevelChanged = onThinkingLevelChanged

        self.eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.transport.events()
            for await evt in stream {
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    self?.handleTransportEvent(evt)
                }
            }
        }
    }

    deinit {
        self.eventTask?.cancel()
        self.bootstrapTask?.cancel()
        self.activeSendTask?.cancel()
        for (_, task) in self.pendingRunTimeoutTasks {
            task.cancel()
        }
    }

    public func load() {
        guard self.loadedSessionGeneration != self.sessionGeneration else { return }
        guard self.bootstrapTask == nil else { return }
        self.startBootstrap()
    }

    public func refresh() {
        self.loadedSessionGeneration = nil
        self.startBootstrap()
    }

    public func send() {
        guard self.activeSendTask == nil else { return }
        self.activeSendTask = Task { [weak self] in
            guard let self else { return }
            await self.performSend()
            self.activeSendTask = nil
        }
    }

    /// Reconciles a caller-authorized model selection before sending. If the session retained an
    /// explicit override that the caller can no longer offer, the reset-to-default patch must
    /// succeed before any message is dispatched; a failed patch therefore fails closed.
    public func send(
        modelSelectionID selectionID: String,
        message: String? = nil,
        attachments: [RemPendingAttachment]? = nil,
        beforeDispatch: @escaping @MainActor () async -> Bool = { true }
    ) {
        guard self.activeSendTask == nil else { return }
        let acceptedSessionKey = self.sessionKey
        let effectiveSelectionID = self.normalizedSelectionID(selectionID)
        let snapshot = AuthorizedSendSnapshot(
            sourceInput: self.input,
            sourceAttachments: self.attachments,
            sourceComposerMutationRevision: self.composerMutationRevision,
            message: message ?? self.input,
            attachments: attachments ?? self.attachments,
            thinkingLevel: self.thinkingLevel)
        self.isPreparingSend = true
        self.activeSendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeSendTask = nil
                self.isPreparingSend = false
                if !self.isSending, let queuedSessionKey = self.queuedSessionKeyAfterSend {
                    self.queuedSessionKeyAfterSend = nil
                    self.performSessionSwitch(to: queuedSessionKey)
                }
            }
            // Session commands do not dispatch a model turn and must remain available even when a
            // stale/unavailable explicit model cannot be repaired. `performSend` classifies and
            // executes them before health/quota; bypass model reconciliation here as well.
            if Self.isSessionCommand(snapshot.message) {
                await self.performSend(snapshot: snapshot, beforeDispatch: beforeDispatch)
                return
            }
            // A picker patch may already be in flight when Send synchronously claims the turn.
            // Wait for its authoritative result before quota. If it failed or resolved to a
            // different model, repair the exact accepted selection and fail closed on failure.
            await self.waitForPendingModelPatches(in: acceptedSessionKey)
            guard self.sessionKey == acceptedSessionKey else { return }
            if effectiveSelectionID != self.modelSelectionID {
                await self.performSelectModel(effectiveSelectionID, allowDuringSendPreparation: true)
                guard self.modelSelectionID == effectiveSelectionID else { return }
            }
            await self.performSend(snapshot: snapshot, beforeDispatch: beforeDispatch)
        }
    }

    public func abort() {
        Task { await self.performAbort() }
    }

    public func refreshSessions(limit: Int? = nil) {
        Task { await self.fetchSessions(limit: limit) }
    }

    /// Refreshes the session list and completes only after the gateway request finishes.
    /// List surfaces use this to keep loading and pagination UI tied to real network work.
    @discardableResult
    public func reloadSessions(limit: Int? = nil) async -> Bool {
        await self.fetchSessions(limit: limit)
    }

    public func switchSession(to sessionKey: String) {
        let next = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return }
        // Once Send is accepted, finish preparation and transport acknowledgement against the
        // captured conversation before changing the shared transcript. This prevents both silent
        // message loss and old-run activity from appearing in the destination during bootstrap.
        if self.isPreparingSend || self.isSending {
            // The latest tap is authoritative. Returning to the source conversation cancels an
            // earlier queued destination instead of unexpectedly navigating after Send settles.
            self.queuedSessionKeyAfterSend = next == self.sessionKey ? nil : next
            return
        }
        guard next != self.sessionKey else { return }
        self.performSessionSwitch(to: next)
    }

    private func performSessionSwitch(to next: String) {
        if self.input.isEmpty, self.attachments.isEmpty {
            self.composerDraftsBySession[self.sessionKey] = nil
        } else {
            self.composerDraftsBySession[self.sessionKey] = ComposerDraft(
                input: self.input,
                attachments: self.attachments)
        }
        self.sessionGeneration &+= 1
        self.sessionKey = next
        self.confirmedActiveSessionKey = nil
        // Composer state belongs to one conversation. Carrying a draft or attachment across a
        // route change can leak it into the next chat and suppress that destination's prefill.
        let destinationDraft = self.composerDraftsBySession[next]
        self.input = destinationDraft?.input ?? ""
        self.attachments = destinationDraft?.attachments ?? []
        self.modelSelectionID = Self.defaultModelSelectionID
        self.startBootstrap()
    }

    public func selectThinkingLevel(_ level: String) {
        guard !self.isPreparingSend, !self.isSending else { return }
        Task { await self.performSelectThinkingLevel(level) }
    }

    public func selectModel(_ selectionID: String) {
        guard !self.isPreparingSend, !self.isSending else { return }
        Task { await self.performSelectModel(selectionID) }
    }

    public var sessionChoices: [RemChatSessionEntry] {
        let now = Date().timeIntervalSince1970 * 1000
        let cutoff = now - (24 * 60 * 60 * 1000)
        let sorted = self.sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        let mainSessionKey = self.resolvedMainSessionKey

        var result: [RemChatSessionEntry] = []
        var included = Set<String>()

        // Always show the resolved main session first, even if it hasn't been updated recently.
        if let main = sorted.first(where: { $0.key == mainSessionKey }) {
            result.append(main)
            included.insert(main.key)
        } else {
            result.append(self.placeholderSession(key: mainSessionKey))
            included.insert(mainSessionKey)
        }

        for entry in sorted {
            guard !included.contains(entry.key) else { continue }
            guard entry.key == self.sessionKey || !Self.isHiddenInternalSession(entry.key) else { continue }
            guard (entry.updatedAt ?? 0) >= cutoff else { continue }
            result.append(entry)
            included.insert(entry.key)
        }

        if !included.contains(self.sessionKey) {
            if let current = sorted.first(where: { $0.key == self.sessionKey }) {
                result.append(current)
            } else {
                result.append(self.placeholderSession(key: self.sessionKey))
            }
        }

        return result
    }

    private var resolvedMainSessionKey: String {
        let trimmed = self.sessionDefaults?.mainSessionKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? "main"
    }

    private static func isHiddenInternalSession(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed == "onboarding" || trimmed.hasSuffix(":onboarding")
    }

    public var showsModelPicker: Bool {
        !self.modelChoices.isEmpty
    }

    public var defaultModelLabel: String {
        guard let defaultModelID = self.normalizedModelSelectionID(self.sessionDefaults?.model) else {
            return "Default"
        }
        return "Default: \(self.modelLabel(for: defaultModelID))"
    }

    private static let baseThinkingLevelOptions: [RemChatThinkingLevelOption] = [
        RemChatThinkingLevelOption(id: "off", label: "off"),
        RemChatThinkingLevelOption(id: "minimal", label: "minimal"),
        RemChatThinkingLevelOption(id: "low", label: "low"),
        RemChatThinkingLevelOption(id: "medium", label: "medium"),
        RemChatThinkingLevelOption(id: "high", label: "high"),
    ]

    public func addAttachments(urls: [URL]) {
        Task { await self.loadAttachments(urls: urls) }
    }

    public func addImageAttachment(data: Data, fileName: String, mimeType: String) {
        Task { await self.addImageAttachment(url: nil, data: data, fileName: fileName, mimeType: mimeType) }
    }

    public func removeAttachment(_ id: RemPendingAttachment.ID) {
        self.attachments.removeAll { $0.id == id }
    }

    public var canSend: Bool {
        let trimmed = self.input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !self.isPreparingSend && !self.isSending && self.pendingRunCount == 0 &&
            (!trimmed.isEmpty || !self.attachments.isEmpty)
    }

    // MARK: - Internals

    private struct BootstrapRequest: Equatable {
        var generation: UInt64
        var sessionKey: String
        var sessionGeneration: UInt64
    }

    private struct SessionRequest: Equatable {
        var sessionKey: String
        var generation: UInt64
    }

    private func startBootstrap() {
        self.bootstrapTask?.cancel()
        self.nextBootstrapGeneration &+= 1
        let request = BootstrapRequest(
            generation: self.nextBootstrapGeneration,
            sessionKey: self.sessionKey,
            sessionGeneration: self.sessionGeneration)
        self.activeBootstrapGeneration = request.generation
        self.isLoading = true
        self.bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrap(request: request)
        }
    }

    private func isCurrentBootstrap(_ request: BootstrapRequest) -> Bool {
        request.generation == self.activeBootstrapGeneration &&
            request.sessionKey == self.sessionKey &&
            request.sessionGeneration == self.sessionGeneration
    }

    private func currentSessionRequest() -> SessionRequest {
        SessionRequest(sessionKey: self.sessionKey, generation: self.sessionGeneration)
    }

    private func isCurrentSessionRequest(_ request: SessionRequest) -> Bool {
        request.sessionKey == self.sessionKey && request.generation == self.sessionGeneration
    }

    private func markCurrentSessionWarmIfUsable(generation: UInt64) {
        guard generation == self.sessionGeneration,
              self.confirmedActiveSessionKey == self.sessionKey,
              self.healthOK
        else {
            self.loadedSessionGeneration = nil
            return
        }
        self.loadedSessionGeneration = generation
    }

    private func setTransportActiveSession(for request: BootstrapRequest) async {
        var activated = false
        do {
            try await self.transport.setActiveSessionKey(request.sessionKey)
            activated = true
        } catch {
            // Best-effort only; history/send/health still work without push events.
        }
        if self.isCurrentBootstrap(request) {
            if activated {
                self.confirmedActiveSessionKey = request.sessionKey
            } else if self.confirmedActiveSessionKey != request.sessionKey {
                self.confirmedActiveSessionKey = nil
            }
            return
        }

        // Cancellation is best-effort at the transport boundary. If an older request finishes
        // last, reassert the newest key. A transient failure must not be mistaken for success;
        // retry a bounded number of times and mark health unavailable if the subscription cannot
        // be restored. A later load/refresh will attempt activation again.
        var failures = 0
        while failures < 3 {
            let latest = self.currentSessionRequest()
            do {
                try await self.transport.setActiveSessionKey(latest.sessionKey)
                if self.isCurrentSessionRequest(latest) {
                    self.confirmedActiveSessionKey = latest.sessionKey
                    return
                }
                failures = 0
            } catch {
                failures += 1
                if failures < 3 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        self.confirmedActiveSessionKey = nil
        self.healthOK = false
        chatUILogger.error("unable to restore active chat session after stale activation")
    }

    private func bootstrap(request: BootstrapRequest) async {
        guard self.isCurrentBootstrap(request) else { return }
        self.errorText = nil
        self.healthOK = false
        self.clearPendingRuns(reason: nil)
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        self.sessionId = nil
        defer {
            if self.isCurrentBootstrap(request) {
                self.isLoading = false
                self.bootstrapTask = nil
            }
        }
        do {
            await self.setTransportActiveSession(for: request)
            guard self.isCurrentBootstrap(request) else { return }

            let payload = try await self.transport.requestHistory(sessionKey: request.sessionKey)
            guard self.isCurrentBootstrap(request) else { return }
            self.messages = Self.reconcileMessageIDs(
                previous: self.messages,
                incoming: Self.decodeMessages(payload.messages ?? []))
            self.sessionId = payload.sessionId
            if !self.prefersExplicitThinkingLevel,
               let level = Self.normalizedThinkingLevel(payload.thinkingLevel)
            {
                self.thinkingLevel = level
            }
            self.syncThinkingLevelOptions()
            await self.pollHealthIfNeeded(force: true, bootstrapRequest: request)
            guard self.isCurrentBootstrap(request) else { return }
            // Chat bootstrap only needs bounded session defaults/model metadata. If Sessions has
            // already established a wider history window, preserve those rows while applying the
            // fresh metadata rather than coupling chat-opening latency to the user's list depth.
            await self.fetchSessions(
                limit: 50,
                bootstrapRequest: request,
                preserveLargerSessionWindow: true)
            guard self.isCurrentBootstrap(request) else { return }
            await self.fetchModels(bootstrapRequest: request)
            guard self.isCurrentBootstrap(request) else { return }
            // A painted transcript alone is not a usable warm chat. If activation or health failed,
            // a later appearance must retry the full bootstrap instead of getting stuck behind the
            // warm-session fast path.
            self.markCurrentSessionWarmIfUsable(generation: request.sessionGeneration)
            self.errorText = nil
        } catch {
            guard self.isCurrentBootstrap(request) else { return }
            self.errorText = error.localizedDescription
            chatUILogger.error("bootstrap failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func decodeMessages(_ raw: [AnyCodable]) -> [RemChatMessage] {
        let decoded = raw.compactMap { item in
            (try? ChatPayloadDecoding.decode(item, as: RemChatMessage.self))
                .map { Self.stripInboundMetadata(from: $0) }
        }
        return Self.dedupeMessages(decoded)
    }

    private static func stripInboundMetadata(from message: RemChatMessage) -> RemChatMessage {
        guard message.role.lowercased() == "user" else {
            return message
        }

        let sanitizedContent = message.content.map { content -> RemChatMessageContent in
            guard let text = content.text else { return content }
            let cleaned = ChatMarkdownPreprocessor.preprocess(markdown: text).cleaned
            return RemChatMessageContent(
                type: content.type,
                text: cleaned,
                thinking: content.thinking,
                thinkingSignature: content.thinkingSignature,
                mimeType: content.mimeType,
                fileName: content.fileName,
                content: content.content,
                id: content.id,
                name: content.name,
                arguments: content.arguments)
        }

        return RemChatMessage(
            id: message.id,
            role: message.role,
            content: sanitizedContent,
            timestamp: message.timestamp,
            toolCallId: message.toolCallId,
            toolName: message.toolName,
            usage: message.usage,
            stopReason: message.stopReason)
    }

    private static func messageContentFingerprint(for message: RemChatMessage) -> String {
        message.content.map { item in
            let type = (item.type ?? "text").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (item.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = (item.fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [type, text, id, name, fileName].joined(separator: "\\u{001F}")
        }.joined(separator: "\\u{001E}")
    }

    private static func messageIdentityKey(for message: RemChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !role.isEmpty else { return nil }

        let timestamp: String = {
            guard let value = message.timestamp, value.isFinite else { return "" }
            return String(format: "%.3f", value)
        }()

        let contentFingerprint = Self.messageContentFingerprint(for: message)
        let toolCallId = (message.toolCallId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = (message.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if timestamp.isEmpty, contentFingerprint.isEmpty, toolCallId.isEmpty, toolName.isEmpty {
            return nil
        }
        return [role, timestamp, toolCallId, toolName, contentFingerprint].joined(separator: "|")
    }

    private static func userRefreshIdentityKey(for message: RemChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role == "user" else { return nil }

        let contentFingerprint = Self.messageContentFingerprint(for: message)
        let toolCallId = (message.toolCallId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = (message.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if contentFingerprint.isEmpty, toolCallId.isEmpty, toolName.isEmpty {
            return nil
        }
        return [role, toolCallId, toolName, contentFingerprint].joined(separator: "|")
    }

    private static func reconcileMessageIDs(
        previous: [RemChatMessage],
        incoming: [RemChatMessage]) -> [RemChatMessage]
    {
        guard !previous.isEmpty, !incoming.isEmpty else { return incoming }

        var idsByKey: [String: [UUID]] = [:]
        for message in previous {
            guard let key = Self.messageIdentityKey(for: message) else { continue }
            idsByKey[key, default: []].append(message.id)
        }

        return incoming.map { message in
            guard let key = Self.messageIdentityKey(for: message),
                  var ids = idsByKey[key],
                  let reusedId = ids.first
            else {
                return message
            }
            ids.removeFirst()
            if ids.isEmpty {
                idsByKey.removeValue(forKey: key)
            } else {
                idsByKey[key] = ids
            }
            guard reusedId != message.id else { return message }
            return RemChatMessage(
                id: reusedId,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                toolCallId: message.toolCallId,
                toolName: message.toolName,
                usage: message.usage,
                stopReason: message.stopReason)
        }
    }

    private static func reconcileRunRefreshMessages(
        previous: [RemChatMessage],
        incoming: [RemChatMessage]) -> [RemChatMessage]
    {
        guard !previous.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return previous }

        func countKeys(_ keys: [String]) -> [String: Int] {
            keys.reduce(into: [:]) { counts, key in
                counts[key, default: 0] += 1
            }
        }

        var reconciled = Self.reconcileMessageIDs(previous: previous, incoming: incoming)
        let incomingIdentityKeys = Set(reconciled.compactMap(Self.messageIdentityKey(for:)))
        var remainingIncomingUserRefreshCounts = countKeys(
            reconciled.compactMap(Self.userRefreshIdentityKey(for:)))

        var lastMatchedPreviousIndex: Int?
        for (index, message) in previous.enumerated() {
            if let key = Self.messageIdentityKey(for: message),
               incomingIdentityKeys.contains(key)
            {
                lastMatchedPreviousIndex = index
                continue
            }
            if let userKey = Self.userRefreshIdentityKey(for: message),
               let remaining = remainingIncomingUserRefreshCounts[userKey],
               remaining > 0
            {
                remainingIncomingUserRefreshCounts[userKey] = remaining - 1
                lastMatchedPreviousIndex = index
            }
        }

        let trailingUserMessages = (lastMatchedPreviousIndex != nil
            ? previous.suffix(from: previous.index(after: lastMatchedPreviousIndex!))
            : ArraySlice(previous))
            .filter { message in
                guard message.role.lowercased() == "user" else { return false }
                guard let key = Self.userRefreshIdentityKey(for: message) else { return false }
                let remaining = remainingIncomingUserRefreshCounts[key] ?? 0
                if remaining > 0 {
                    remainingIncomingUserRefreshCounts[key] = remaining - 1
                    return false
                }
                return true
            }

        guard !trailingUserMessages.isEmpty else {
            return reconciled
        }

        for message in trailingUserMessages {
            guard let messageTimestamp = message.timestamp else {
                reconciled.append(message)
                continue
            }

            let insertIndex = reconciled.firstIndex { existing in
                guard let existingTimestamp = existing.timestamp else { return false }
                return existingTimestamp > messageTimestamp
            } ?? reconciled.endIndex
            reconciled.insert(message, at: insertIndex)
        }

        return Self.dedupeMessages(reconciled)
    }

    private static func dedupeMessages(_ messages: [RemChatMessage]) -> [RemChatMessage] {
        var result: [RemChatMessage] = []
        result.reserveCapacity(messages.count)
        var seen = Set<String>()

        for message in messages {
            guard let key = Self.dedupeKey(for: message) else {
                result.append(message)
                continue
            }
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(message)
        }

        return result
    }

    private static func dedupeKey(for message: RemChatMessage) -> String? {
        guard let timestamp = message.timestamp else { return nil }
        let text = message.content.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "\(message.role)|\(timestamp)|\(text)"
    }

    private static let resetTriggers: Set<String> = ["/new", "/reset", "/clear"]
    private static let compactTriggers: Set<String> = ["/compact"]

    private static func isSessionCommand(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return resetTriggers.contains(normalized) || compactTriggers.contains(normalized)
    }

    private func performSend(
        snapshot: AuthorizedSendSnapshot? = nil,
        beforeDispatch: @MainActor () async -> Bool = { true }
    ) async {
        guard !self.isSending else { return }
        let sourceInput = snapshot?.sourceInput ?? self.input
        let sourceAttachments = snapshot?.sourceAttachments ?? self.attachments
        let sourceComposerMutationRevision = snapshot?.sourceComposerMutationRevision
            ?? self.composerMutationRevision
        let composerInput = snapshot?.message ?? self.input
        let attachments = snapshot?.attachments ?? self.attachments
        let thinkingLevel = snapshot?.thinkingLevel ?? self.thinkingLevel
        let trimmed = composerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        if Self.resetTriggers.contains(trimmed.lowercased()) {
            if self.composerMutationRevision == sourceComposerMutationRevision { self.input = "" }
            await self.performReset()
            return
        }
        if Self.compactTriggers.contains(trimmed.lowercased()) {
            if self.composerMutationRevision == sourceComposerMutationRevision { self.input = "" }
            await self.performCompact()
            return
        }

        let sessionKey = self.sessionKey

        guard self.healthOK else {
            self.errorText = "Gateway health not OK; cannot send"
            return
        }

        let sessionRequest = self.currentSessionRequest()
        self.isSending = true
        self.errorText = nil
        defer {
            self.isSending = false
            if let queuedSessionKey = self.queuedSessionKeyAfterSend {
                self.queuedSessionKeyAfterSend = nil
                self.performSessionSwitch(to: queuedSessionKey)
            }
        }

        // All local dispatch guards have accepted the immutable payload. Only now may a caller
        // consume quota or clear view-local capability state. A rejection leaves the composer and
        // navigation untouched; an edit made while this closure suspends remains the next draft.
        guard await beforeDispatch() else { return }

        let preparationStartedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let runId = UUID().uuidString
        let messageText = trimmed.isEmpty && !attachments.isEmpty ? "See attached." : trimmed
        self.pendingRuns.insert(runId)
        self.preparingRuns.insert(runId)
        self.armPendingRunTimeout(runId: runId)
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        // Snapshot and clear the composer before the first suspension point. Diagnostic hooks
        // must never cause a later continuation to erase a draft or attachment added meanwhile.
        var clearedComposerMutationRevision: UInt64?
        if self.composerMutationRevision == sourceComposerMutationRevision {
            self.input = ""
            self.attachments = []
            clearedComposerMutationRevision = self.composerMutationRevision
        }
        defer { self.preparingRuns.remove(runId) }

        // Append without awaiting diagnostics so clearing the composer always has immediate,
        // visible feedback. The captured monotonic start still includes encoding and UI work.
        var userContent: [RemChatMessageContent] = [
            RemChatMessageContent(
                type: "text",
                text: messageText,
                thinking: nil,
                thinkingSignature: nil,
                mimeType: nil,
                fileName: nil,
                content: nil,
                id: nil,
                name: nil,
                arguments: nil),
        ]
        let encodedAttachments = attachments.map { att -> RemChatAttachmentPayload in
            RemChatAttachmentPayload(
                type: att.type,
                mimeType: att.mimeType,
                fileName: att.fileName,
                content: att.data.base64EncodedString())
        }
        for att in encodedAttachments {
            userContent.append(
                RemChatMessageContent(
                    type: att.type,
                    text: nil,
                    thinking: nil,
                    thinkingSignature: nil,
                    mimeType: att.mimeType,
                    fileName: att.fileName,
                    content: AnyCodable(att.content),
                    id: nil,
                    name: nil,
                    arguments: nil))
        }
        let optimisticMessageID = UUID()
        self.messages.append(
            RemChatMessage(
                id: optimisticMessageID,
                role: "user",
                content: userContent,
                timestamp: Date().timeIntervalSince1970 * 1000))

        do {
            await self.transport.observeSendPreparation(
                sessionKey: sessionKey,
                idempotencyKey: runId,
                phase: .started,
                startedAtUptimeNanoseconds: preparationStartedAtUptimeNanoseconds,
                messageLength: messageText.count,
                attachmentsCount: encodedAttachments.count)
            try Task.checkCancellation()
            await self.transport.observeSendPreparation(
                sessionKey: sessionKey,
                idempotencyKey: runId,
                phase: .optimisticAppendCompleted,
                startedAtUptimeNanoseconds: preparationStartedAtUptimeNanoseconds,
                messageLength: messageText.count,
                attachmentsCount: encodedAttachments.count)
            try Task.checkCancellation()
            await self.transport.observeSendPreparation(
                sessionKey: sessionKey,
                idempotencyKey: runId,
                phase: .modelPatchWaitStarted,
                startedAtUptimeNanoseconds: preparationStartedAtUptimeNanoseconds,
                messageLength: messageText.count,
                attachmentsCount: encodedAttachments.count)
            try Task.checkCancellation()
            await self.waitForPendingModelPatches(in: sessionKey)
            try Task.checkCancellation()
            await self.transport.observeSendPreparation(
                sessionKey: sessionKey,
                idempotencyKey: runId,
                phase: .modelPatchWaitEnded,
                startedAtUptimeNanoseconds: preparationStartedAtUptimeNanoseconds,
                messageLength: messageText.count,
                attachmentsCount: encodedAttachments.count)
            try Task.checkCancellation()
            self.preparingRuns.remove(runId)
            let response = try await self.transport.sendMessage(
                sessionKey: sessionKey,
                message: messageText,
                thinking: thinkingLevel,
                idempotencyKey: runId,
                attachments: encodedAttachments)
            if response.runId != runId {
                self.clearPendingRun(runId)
                self.pendingRuns.insert(response.runId)
                self.armPendingRunTimeout(runId: response.runId)
            }
        } catch is CancellationError {
            self.messages.removeAll { $0.id == optimisticMessageID }
            if self.isCurrentSessionRequest(sessionRequest) {
                // Restore the captured composer as one unit only while we still own the exact
                // state produced by our clear. Even an edit that returns to the same visible text,
                // or a deliberate clear after dispatch, advances the revision and wins.
                if let clearedComposerMutationRevision,
                   self.composerMutationRevision == clearedComposerMutationRevision
                {
                    self.input = sourceInput
                    self.attachments = sourceAttachments
                }
            }
            self.clearPendingRun(runId)
        } catch {
            self.messages.removeAll { $0.id == optimisticMessageID }
            if self.isCurrentSessionRequest(sessionRequest),
               let clearedComposerMutationRevision,
               self.composerMutationRevision == clearedComposerMutationRevision
            {
                self.input = sourceInput
                self.attachments = sourceAttachments
            }
            self.clearPendingRun(runId)
            if self.isCurrentSessionRequest(sessionRequest) {
                self.errorText = error.localizedDescription
            }
            chatUILogger.error("chat.send failed \(error.localizedDescription, privacy: .public)")
        }

    }

    private func performAbort() async {
        guard !self.pendingRuns.isEmpty else { return }
        guard !self.isAborting else { return }
        self.isAborting = true
        defer { self.isAborting = false }

        let runIds = Array(self.pendingRuns)
        let preparingRunIds = runIds.filter { self.preparingRuns.contains($0) }
        if !preparingRunIds.isEmpty {
            self.activeSendTask?.cancel()
        }
        for runId in preparingRunIds {
            self.preparingRuns.remove(runId)
            self.clearPendingRun(runId)
        }
        for runId in runIds {
            do {
                try await self.transport.abortRun(sessionKey: self.sessionKey, runId: runId)
            } catch {
                // Best-effort.
            }
        }
    }

    @discardableResult
    private func fetchSessions(
        limit: Int?,
        bootstrapRequest: BootstrapRequest? = nil,
        preserveLargerSessionWindow: Bool = false
    ) async -> Bool {
        if let bootstrapRequest, !self.isCurrentBootstrap(bootstrapRequest) { return false }
        self.nextSessionListRequestID &+= 1
        let requestID = self.nextSessionListRequestID
        // The gateway's omitted-limit contract is currently a 100-row window.
        let requestLimit = limit ?? 100
        self.sessionRefreshCount += 1
        self.isRefreshingSessions = true
        defer {
            self.sessionRefreshCount = max(0, self.sessionRefreshCount - 1)
            self.isRefreshingSessions = self.sessionRefreshCount > 0
        }
        do {
            let res = try await self.transport.listSessions(limit: limit)
            if let bootstrapRequest, !self.isCurrentBootstrap(bootstrapRequest) { return false }
            // A slower smaller request must never truncate a larger window that
            // already completed. For equal windows, the newest request wins.
            guard requestLimit > self.appliedSessionListLimit
                    || (requestLimit == self.appliedSessionListLimit
                        && requestID >= self.appliedSessionListRequestID)
            else {
                guard preserveLargerSessionWindow,
                      requestLimit < self.appliedSessionListLimit
                else { return false }
                if requestID >= self.appliedSessionMetadataRequestID {
                    self.appliedSessionMetadataRequestID = requestID
                    self.sessionsLoadError = nil
                    self.sessionDefaults = res.defaults
                    self.syncSelectedModel()
                    self.syncThinkingLevelOptions()
                }
                return true
            }
            self.appliedSessionListLimit = requestLimit
            self.appliedSessionListRequestID = requestID
            self.sessionsLimitApplied = res.limitApplied ?? requestLimit
            self.sessions = res.sessions
            self.sessionsHasMore = res.hasMore
            self.sessionsTotalCount = res.totalCount
            if requestID >= self.appliedSessionMetadataRequestID {
                self.appliedSessionMetadataRequestID = requestID
                self.sessionsLoadError = nil
                self.sessionDefaults = res.defaults
                self.syncSelectedModel()
                self.syncThinkingLevelOptions()
            }
            return true
        } catch {
            if requestID >= self.appliedSessionMetadataRequestID {
                self.appliedSessionMetadataRequestID = requestID
                self.sessionsLoadError = error.localizedDescription
            }
            return false
        }
    }

    private func fetchModels(bootstrapRequest: BootstrapRequest? = nil) async {
        if let bootstrapRequest, !self.isCurrentBootstrap(bootstrapRequest) { return }
        do {
            let catalog = try await self.transport.listModelCatalog()
            if let bootstrapRequest, !self.isCurrentBootstrap(bootstrapRequest) { return }
            self.modelChoices = catalog.models
            self.modelCatalogCompleteness = catalog.completeness
            self.modelCatalogProvenance = catalog.provenance
            self.syncSelectedModel()
        } catch {
            // Best-effort.
        }
    }

    private func performReset() async {
        let request = self.currentSessionRequest()
        self.isLoading = true
        self.errorText = nil
        do {
            try await self.transport.resetSession(sessionKey: request.sessionKey)
        } catch {
            guard self.isCurrentSessionRequest(request) else { return }
            self.isLoading = false
            self.errorText = error.localizedDescription
            chatUILogger.error("session reset failed \(error.localizedDescription, privacy: .public)")
            return
        }

        guard self.isCurrentSessionRequest(request) else { return }
        // Reset succeeded, so the pre-reset transcript can no longer be treated as authoritative.
        // Clear warm state before bootstrapping so a failed reload remains retryable on re-entry.
        self.loadedSessionGeneration = nil
        self.startBootstrap()
    }

    private func performCompact() async {
        guard !self.isCompacting else { return }
        guard !self.isSending, self.pendingRuns.isEmpty, !self.isAborting else {
            self.errorText = "Wait for the current response before compacting the session."
            return
        }
        if let lastCompactAt,
           Date().timeIntervalSince(lastCompactAt) < self.compactCooldown
        {
            self.errorText = "Please wait before compacting this session again."
            return
        }

        let request = self.currentSessionRequest()
        self.isCompacting = true
        self.isLoading = true
        self.errorText = nil
        do {
            try await self.transport.compactSession(sessionKey: request.sessionKey)
        } catch {
            guard self.isCurrentSessionRequest(request) else {
                self.isCompacting = false
                return
            }
            self.isLoading = false
            self.isCompacting = false
            self.errorText = "Unable to compact the session. Please try again."
            let nsError = error as NSError
            chatUILogger.error(
                "compact failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            chatUILogger.error("compact details=\(String(describing: error), privacy: .private)")
            return
        }

        guard self.isCurrentSessionRequest(request) else {
            self.isCompacting = false
            return
        }
        self.lastCompactAt = Date()
        self.isCompacting = false
        // Compaction succeeded, so a failed bootstrap must not leave the pre-compact transcript
        // marked warm and suppress the next appearance retry.
        self.loadedSessionGeneration = nil
        self.startBootstrap()
    }

    private func performSelectThinkingLevel(_ level: String) async {
        // Re-check after the public method's unstructured Task reaches the main actor. A picker
        // tap queued immediately before Send may not begin until Send has already claimed the turn.
        guard !self.isPreparingSend, !self.isSending else { return }
        let next = Self.normalizedThinkingLevel(level) ?? "off"
        guard next != self.thinkingLevel else { return }

        let sessionKey = self.sessionKey
        self.thinkingLevel = next
        self.syncThinkingLevelOptions()
        self.updateCurrentSessionThinkingLevel(next, sessionKey: sessionKey)
        self.onThinkingLevelChanged?(next)
        self.nextThinkingSelectionRequestID &+= 1
        let requestID = self.nextThinkingSelectionRequestID
        self.latestThinkingSelectionRequestIDsBySession[sessionKey] = requestID
        self.latestThinkingLevelsBySession[sessionKey] = next

        do {
            try await self.transport.setSessionThinking(sessionKey: sessionKey, thinkingLevel: next)
            guard requestID == self.latestThinkingSelectionRequestIDsBySession[sessionKey] else {
                let latest = self.latestThinkingLevelsBySession[sessionKey] ?? next
                guard latest != next else { return }
                try? await self.transport.setSessionThinking(sessionKey: sessionKey, thinkingLevel: latest)
                return
            }
        } catch {
            guard sessionKey == self.sessionKey,
                  requestID == self.latestThinkingSelectionRequestIDsBySession[sessionKey]
            else { return }
            // Best-effort. Persisting the user's local preference matters more than a patch error here.
        }
    }

    private func performSelectModel(
        _ selectionID: String,
        allowDuringSendPreparation: Bool = false
    ) async {
        // The authorized-send repair is the only model mutation allowed after Send claims the
        // turn. A picker Task queued one run-loop earlier must not change the charged dispatch.
        guard allowDuringSendPreparation || (!self.isPreparingSend && !self.isSending) else { return }
        let next = self.normalizedSelectionID(selectionID)
        guard next != self.modelSelectionID else { return }

        let sessionKey = self.sessionKey
        let previous = self.modelSelectionID
        let previousRequestID = self.latestModelSelectionRequestIDsBySession[sessionKey]
        self.nextModelSelectionRequestID &+= 1
        let requestID = self.nextModelSelectionRequestID
        let nextModelRef = self.modelRef(forSelectionID: next)
        self.latestModelSelectionRequestIDsBySession[sessionKey] = requestID
        self.latestModelSelectionIDsBySession[sessionKey] = next
        self.beginModelPatch(for: sessionKey)
        self.modelSelectionID = next
        self.errorText = nil
        defer { self.endModelPatch(for: sessionKey) }

        do {
            try await self.transport.setSessionModel(
                sessionKey: sessionKey,
                model: nextModelRef)
            guard requestID == self.latestModelSelectionRequestIDsBySession[sessionKey] else {
                // Keep older successful patches as rollback state, but do not replay
                // stale UI/session state over a newer in-flight or completed selection.
                self.lastSuccessfulModelSelectionIDsBySession[sessionKey] = next
                return
            }
            self.applySuccessfulModelSelection(next, sessionKey: sessionKey, syncSelection: true)
        } catch {
            guard requestID == self.latestModelSelectionRequestIDsBySession[sessionKey] else { return }
            self.latestModelSelectionIDsBySession[sessionKey] = previous
            if let previousRequestID {
                self.latestModelSelectionRequestIDsBySession[sessionKey] = previousRequestID
            } else {
                self.latestModelSelectionRequestIDsBySession.removeValue(forKey: sessionKey)
            }
            if self.lastSuccessfulModelSelectionIDsBySession[sessionKey] == previous {
                self.applySuccessfulModelSelection(
                    previous,
                    sessionKey: sessionKey,
                    syncSelection: sessionKey == self.sessionKey)
            }
            guard sessionKey == self.sessionKey else { return }
            self.modelSelectionID = previous
            self.errorText = error.localizedDescription
            chatUILogger.error("sessions.patch(model) failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginModelPatch(for sessionKey: String) {
        self.inFlightModelPatchCountsBySession[sessionKey, default: 0] += 1
    }

    private func endModelPatch(for sessionKey: String) {
        let remaining = max(0, (self.inFlightModelPatchCountsBySession[sessionKey] ?? 0) - 1)
        if remaining == 0 {
            self.inFlightModelPatchCountsBySession.removeValue(forKey: sessionKey)
            let waiters = self.modelPatchWaitersBySession.removeValue(forKey: sessionKey) ?? [:]
            for waiter in waiters.values {
                waiter.resume()
            }
            return
        }
        self.inFlightModelPatchCountsBySession[sessionKey] = remaining
    }

    private func waitForPendingModelPatches(in sessionKey: String) async {
        guard (self.inFlightModelPatchCountsBySession[sessionKey] ?? 0) > 0 else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                self.modelPatchWaitersBySession[sessionKey, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelModelPatchWaiter(waiterID, sessionKey: sessionKey)
            }
        }
    }

    private func cancelModelPatchWaiter(_ waiterID: UUID, sessionKey: String) {
        guard let continuation = self.modelPatchWaitersBySession[sessionKey]?.removeValue(forKey: waiterID)
        else { return }
        if self.modelPatchWaitersBySession[sessionKey]?.isEmpty == true {
            self.modelPatchWaitersBySession.removeValue(forKey: sessionKey)
        }
        continuation.resume()
    }

    private func syncThinkingLevelOptions() {
        let currentSession = self.sessions.first(where: { $0.key == self.sessionKey })
        var options = self.resolvedThinkingLevelOptions(for: currentSession)
        if let current = Self.normalizedThinkingLevel(self.thinkingLevel) {
            options = Self.withCurrentThinkingOption(options, current: current)
        }
        self.thinkingLevelOptions = options
    }

    private func resolvedThinkingLevelOptions(
        for currentSession: RemChatSessionEntry?) -> [RemChatThinkingLevelOption]
    {
        if let levels = Self.normalizedThinkingLevelOptions(currentSession?.thinkingLevels), !levels.isEmpty {
            return levels
        }

        let defaultsMatch = currentSession.map {
            Self.sessionModelMatchesDefaults($0, defaults: self.sessionDefaults)
        } ?? true

        if defaultsMatch,
           let levels = Self.normalizedThinkingLevelOptions(self.sessionDefaults?.thinkingLevels),
           !levels.isEmpty
        {
            return levels
        }

        if let options = Self.thinkingOptions(from: currentSession?.thinkingOptions), !options.isEmpty {
            return options
        }

        if defaultsMatch,
           let options = Self.thinkingOptions(from: self.sessionDefaults?.thinkingOptions),
           !options.isEmpty
        {
            return options
        }

        return Self.baseThinkingLevelOptions
    }

    private static func sessionModelMatchesDefaults(
        _ session: RemChatSessionEntry,
        defaults: RemChatSessionsDefaults?) -> Bool
    {
        let providerMatches = session.modelProvider == nil || session.modelProvider == defaults?.modelProvider
        let modelMatches = session.model == nil || session.model == defaults?.model
        return providerMatches && modelMatches
    }

    private static func normalizedThinkingLevelOptions(
        _ levels: [RemChatThinkingLevelOption]?) -> [RemChatThinkingLevelOption]?
    {
        guard let levels else { return nil }
        return Self.dedupedThinkingOptions(
            levels.compactMap { level in
                guard let id = Self.normalizedThinkingLevel(level.id) else { return nil }
                let label = level.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return RemChatThinkingLevelOption(id: id, label: label.isEmpty ? id : label)
            })
    }

    private static func thinkingOptions(from labels: [String]?) -> [RemChatThinkingLevelOption]? {
        guard let labels else { return nil }
        return Self.dedupedThinkingOptions(
            labels.compactMap { label in
                guard let id = Self.normalizedThinkingLevel(label) else { return nil }
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                return RemChatThinkingLevelOption(id: id, label: trimmed.isEmpty ? id : trimmed)
            })
    }

    private static func withCurrentThinkingOption(
        _ options: [RemChatThinkingLevelOption],
        current: String) -> [RemChatThinkingLevelOption]
    {
        guard !options.contains(where: { $0.id == current }) else { return options }
        return options + [RemChatThinkingLevelOption(id: current, label: current)]
    }

    private static func dedupedThinkingOptions(
        _ options: [RemChatThinkingLevelOption]) -> [RemChatThinkingLevelOption]
    {
        var result: [RemChatThinkingLevelOption] = []
        var seen = Set<String>()
        for option in options {
            guard !option.id.isEmpty, !seen.contains(option.id) else { continue }
            seen.insert(option.id)
            result.append(option)
        }
        return result
    }

    private func placeholderSession(key: String) -> RemChatSessionEntry {
        RemChatSessionEntry(
            key: key,
            kind: nil,
            displayName: nil,
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil)
    }

    private func syncSelectedModel() {
        let currentSession = self.sessions.first(where: { $0.key == self.sessionKey })
        let explicitModelID = self.normalizedModelSelectionID(
            currentSession?.model,
            provider: currentSession?.modelProvider)
        if let explicitModelID {
            self.lastSuccessfulModelSelectionIDsBySession[self.sessionKey] = explicitModelID
            self.modelSelectionID = explicitModelID
            return
        }
        self.lastSuccessfulModelSelectionIDsBySession[self.sessionKey] = Self.defaultModelSelectionID
        self.modelSelectionID = Self.defaultModelSelectionID
    }

    private func normalizedSelectionID(_ selectionID: String) -> String {
        let trimmed = selectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.defaultModelSelectionID }
        return trimmed
    }

    private func normalizedModelSelectionID(_ modelID: String?, provider: String? = nil) -> String? {
        guard let modelID else { return nil }
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let provider = Self.normalizedProvider(provider) {
            let providerQualified = Self.providerQualifiedModelSelectionID(modelID: trimmed, provider: provider)
            if let match = self.modelChoices.first(where: {
                $0.selectionID == providerQualified ||
                    ($0.modelID == trimmed && Self.normalizedProvider($0.provider) == provider)
            }) {
                return match.selectionID
            }
            return providerQualified
        }
        if self.modelChoices.contains(where: { $0.selectionID == trimmed }) {
            return trimmed
        }
        let matches = self.modelChoices.filter { $0.modelID == trimmed || $0.selectionID == trimmed }
        if matches.count == 1 {
            return matches[0].selectionID
        }
        return trimmed
    }

    private func modelRef(forSelectionID selectionID: String) -> String? {
        let normalized = self.normalizedSelectionID(selectionID)
        if normalized == Self.defaultModelSelectionID {
            return nil
        }
        return normalized
    }

    private func modelLabel(for modelID: String) -> String {
        self.modelChoices.first(where: { $0.selectionID == modelID || $0.modelID == modelID })?.displayLabel ??
            modelID
    }

    private func applySuccessfulModelSelection(_ selectionID: String, sessionKey: String, syncSelection: Bool) {
        self.lastSuccessfulModelSelectionIDsBySession[sessionKey] = selectionID
        let resolved = self.resolvedSessionModelIdentity(forSelectionID: selectionID)
        self.updateCurrentSessionModel(
            modelID: resolved.modelID,
            modelProvider: resolved.modelProvider,
            sessionKey: sessionKey,
            syncSelection: syncSelection)
        if sessionKey == self.sessionKey {
            self.syncThinkingLevelOptions()
        }
    }

    private func resolvedSessionModelIdentity(forSelectionID selectionID: String)
    -> (modelID: String?, modelProvider: String?) {
        guard let modelRef = self.modelRef(forSelectionID: selectionID) else {
            return (nil, nil)
        }
        if let choice = self.modelChoices.first(where: { $0.selectionID == modelRef }) {
            return (choice.modelID, Self.normalizedProvider(choice.provider))
        }
        return (modelRef, nil)
    }

    private static func normalizedProvider(_ provider: String?) -> String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func providerQualifiedModelSelectionID(modelID: String, provider: String) -> String {
        let providerPrefix = "\(provider)/"
        if modelID.hasPrefix(providerPrefix) {
            return modelID
        }
        return "\(provider)/\(modelID)"
    }

    private func updateCurrentSessionThinkingLevel(_ thinkingLevel: String?, sessionKey: String) {
        guard let index = self.sessions.firstIndex(where: { $0.key == sessionKey }) else { return }
        let current = self.sessions[index]
        self.sessions[index] = RemChatSessionEntry(
            key: current.key,
            kind: current.kind,
            displayName: current.displayName,
            surface: current.surface,
            subject: current.subject,
            room: current.room,
            space: current.space,
            updatedAt: current.updatedAt,
            sessionId: current.sessionId,
            systemSent: current.systemSent,
            abortedLastRun: current.abortedLastRun,
            thinkingLevel: thinkingLevel,
            verboseLevel: current.verboseLevel,
            inputTokens: current.inputTokens,
            outputTokens: current.outputTokens,
            totalTokens: current.totalTokens,
            modelProvider: current.modelProvider,
            model: current.model,
            contextTokens: current.contextTokens,
            thinkingLevels: current.thinkingLevels,
            thinkingOptions: current.thinkingOptions,
            thinkingDefault: current.thinkingDefault)
    }

    private func updateCurrentSessionModel(
        modelID: String?,
        modelProvider: String?,
        sessionKey: String,
        syncSelection: Bool)
    {
        if let index = self.sessions.firstIndex(where: { $0.key == sessionKey }) {
            let current = self.sessions[index]
            self.sessions[index] = RemChatSessionEntry(
                key: current.key,
                kind: current.kind,
                displayName: current.displayName,
                surface: current.surface,
                subject: current.subject,
                room: current.room,
                space: current.space,
                updatedAt: current.updatedAt,
                sessionId: current.sessionId,
                systemSent: current.systemSent,
                abortedLastRun: current.abortedLastRun,
                thinkingLevel: current.thinkingLevel,
                verboseLevel: current.verboseLevel,
                inputTokens: current.inputTokens,
                outputTokens: current.outputTokens,
                totalTokens: current.totalTokens,
                modelProvider: modelProvider,
                model: modelID,
                contextTokens: current.contextTokens)
        } else {
            let placeholder = self.placeholderSession(key: sessionKey)
            self.sessions.append(
                RemChatSessionEntry(
                    key: placeholder.key,
                    kind: placeholder.kind,
                    displayName: placeholder.displayName,
                    surface: placeholder.surface,
                    subject: placeholder.subject,
                    room: placeholder.room,
                    space: placeholder.space,
                    updatedAt: placeholder.updatedAt,
                    sessionId: placeholder.sessionId,
                    systemSent: placeholder.systemSent,
                    abortedLastRun: placeholder.abortedLastRun,
                    thinkingLevel: placeholder.thinkingLevel,
                    verboseLevel: placeholder.verboseLevel,
                    inputTokens: placeholder.inputTokens,
                    outputTokens: placeholder.outputTokens,
                    totalTokens: placeholder.totalTokens,
                    modelProvider: modelProvider,
                    model: modelID,
                    contextTokens: placeholder.contextTokens))
        }
        if syncSelection {
            self.syncSelectedModel()
        }
    }

    private func handleTransportEvent(_ evt: RemChatTransportEvent) {
        switch evt {
        case let .health(ok):
            self.healthOK = ok && self.confirmedActiveSessionKey == self.sessionKey
        case .tick:
            Task { await self.pollHealthIfNeeded(force: false) }
        case let .chat(chat):
            self.handleChatEvent(chat)
        case let .sessionMessage(message):
            self.handleSessionMessageEvent(message)
        case let .agent(agent):
            self.handleAgentEvent(agent)
        case .seqGap:
            self.errorText = nil
            self.clearPendingRuns(reason: nil)
            let request = self.currentSessionRequest()
            Task {
                await self.refreshHistoryAfterRun(request: request)
                await self.pollHealthIfNeeded(force: true)
            }
        }
    }

    private func handleSessionMessageEvent(_ payload: RemSessionMessageEventPayload) {
        if let sessionKey = payload.sessionKey,
           !Self.matchesCurrentSessionKey(incoming: sessionKey, current: self.sessionKey)
        {
            return
        }

        guard let message = payload.message else { return }
        guard message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" else {
            return
        }
        if self.pendingRunCount > 0 {
            return
        }

        let sanitized = Self.stripInboundMetadata(from: message)
        let reconciled = Self.reconcileMessageIDs(previous: self.messages, incoming: self.messages + [sanitized])
        self.messages = Self.dedupeMessages(reconciled)
    }

    private func handleChatEvent(_ chat: RemChatEventPayload) {
        let isOurRun = chat.runId.flatMap { self.pendingRuns.contains($0) } ?? false

        // Gateway may publish canonical session keys (for example "agent:main:main")
        // even when this view currently uses an alias key (for example "main").
        // Never drop events for our own pending run on key mismatch, or the UI can stay
        // stuck at "thinking" until the user reopens and forces a history reload.
        if let sessionKey = chat.sessionKey,
           !Self.matchesCurrentSessionKey(incoming: sessionKey, current: self.sessionKey),
           !isOurRun
        {
            return
        }
        if !isOurRun {
            // Keep multiple clients in sync: if another client finishes a run for our session, refresh history.
            switch chat.state {
            case "final", "aborted", "error":
                self.streamingAssistantText = nil
                self.pendingToolCallsById = [:]
                let request = self.currentSessionRequest()
                Task { await self.refreshHistoryAfterRun(request: request) }
            default:
                break
            }
            return
        }

        switch chat.state {
        case "final", "aborted", "error":
            if chat.state == "error" {
                self.errorText = chat.errorMessage ?? "Chat failed"
            }
            if let runId = chat.runId {
                self.clearPendingRun(runId)
            } else if self.pendingRuns.count <= 1 {
                self.clearPendingRuns(reason: nil)
            }
            self.pendingToolCallsById = [:]
            self.streamingAssistantText = nil
            let request = self.currentSessionRequest()
            Task { await self.refreshHistoryAfterRun(request: request) }
        default:
            break
        }
    }

    private static func matchesCurrentSessionKey(incoming: String, current: String) -> Bool {
        let incomingNormalized = incoming.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentNormalized = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if incomingNormalized == currentNormalized {
            return true
        }
        // Common alias pair in operator clients: UI uses "main" while gateway emits canonical.
        if (incomingNormalized == "agent:main:main" && currentNormalized == "main") ||
            (incomingNormalized == "main" && currentNormalized == "agent:main:main")
        {
            return true
        }
        return false
    }

    private func handleAgentEvent(_ evt: RemAgentEventPayload) {
        // A destination bootstrap is not yet authoritative, so a finishing event from the prior
        // conversation must not populate it. A stable brand-new conversation legitimately has no
        // session ID until its first agent event; bind that ID only while our own first run is
        // pending and the transport has confirmed the active session key.
        guard !self.isLoading, self.confirmedActiveSessionKey == self.sessionKey else { return }
        if let sessionId {
            guard evt.runId == sessionId else { return }
        } else {
            guard !self.pendingRuns.isEmpty else { return }
            self.sessionId = evt.runId
        }

        switch evt.stream {
        case "assistant":
            if let text = evt.data["text"]?.value as? String {
                self.streamingAssistantText = text
            }
        case "tool":
            guard let phase = evt.data["phase"]?.value as? String else { return }
            guard let name = evt.data["name"]?.value as? String else { return }
            guard let toolCallId = evt.data["toolCallId"]?.value as? String else { return }
            if phase == "start" {
                let args = evt.data["args"]
                self.pendingToolCallsById[toolCallId] = RemChatPendingToolCall(
                    toolCallId: toolCallId,
                    name: name,
                    args: args,
                    startedAt: evt.ts.map(Double.init) ?? Date().timeIntervalSince1970 * 1000,
                    isError: nil)
            } else if phase == "result" {
                self.pendingToolCallsById[toolCallId] = nil
            }
        default:
            break
        }
    }

    private func refreshHistoryAfterRun(request: SessionRequest) async {
        guard self.isCurrentSessionRequest(request) else { return }
        do {
            let payload = try await self.transport.requestHistory(sessionKey: request.sessionKey)
            guard self.isCurrentSessionRequest(request) else { return }
            self.messages = Self.reconcileRunRefreshMessages(
                previous: self.messages,
                incoming: Self.decodeMessages(payload.messages ?? []))
            self.sessionId = payload.sessionId
            if !self.prefersExplicitThinkingLevel,
               let level = Self.normalizedThinkingLevel(payload.thinkingLevel)
            {
                self.thinkingLevel = level
                self.syncThinkingLevelOptions()
            }
            self.markCurrentSessionWarmIfUsable(generation: request.generation)
        } catch {
            guard self.isCurrentSessionRequest(request) else { return }
            // The final event cleared transient run UI, but durable history did not reconcile.
            // Force the next appearance to heal from the gateway instead of preserving stale pixels.
            self.loadedSessionGeneration = nil
            chatUILogger.error("refresh history failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func armPendingRunTimeout(runId: String) {
        self.pendingRunTimeoutTasks[runId]?.cancel()
        self.pendingRunTimeoutTasks[runId] = Task { [weak self] in
            let timeoutMs = await MainActor.run { self?.pendingRunTimeoutMs ?? 0 }
            try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.pendingRuns.contains(runId) else { return }
                self.clearPendingRun(runId)
                self.errorText = "Timed out waiting for a reply; try again or refresh."
            }
        }
    }

    private func clearPendingRun(_ runId: String) {
        self.pendingRuns.remove(runId)
        self.pendingRunTimeoutTasks[runId]?.cancel()
        self.pendingRunTimeoutTasks[runId] = nil
    }

    private func clearPendingRuns(reason: String?) {
        for runId in self.pendingRuns {
            self.pendingRunTimeoutTasks[runId]?.cancel()
        }
        self.pendingRunTimeoutTasks.removeAll()
        self.pendingRuns.removeAll()
        if let reason, !reason.isEmpty {
            self.errorText = reason
        }
    }

    private func pollHealthIfNeeded(
        force: Bool,
        bootstrapRequest: BootstrapRequest? = nil
    ) async {
        if let bootstrapRequest, !self.isCurrentBootstrap(bootstrapRequest) { return }
        if !force, let last = self.lastHealthPollAt, Date().timeIntervalSince(last) < 10 {
            return
        }
        self.lastHealthPollAt = Date()
        do {
            let ok = try await self.transport.requestHealth(timeoutMs: 5000)
            if let bootstrapRequest, !self.isCurrentBootstrap(bootstrapRequest) { return }
            self.healthOK = ok && self.confirmedActiveSessionKey == self.sessionKey
        } catch {
            if let bootstrapRequest, !self.isCurrentBootstrap(bootstrapRequest) { return }
            self.healthOK = false
        }
    }

    private func loadAttachments(urls: [URL]) async {
        for url in urls {
            do {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                await self.addImageAttachment(
                    url: url,
                    data: data,
                    fileName: url.lastPathComponent,
                    mimeType: Self.mimeType(for: url) ?? "application/octet-stream")
            } catch {
                await MainActor.run { self.errorText = error.localizedDescription }
            }
        }
    }

    private static func mimeType(for url: URL) -> String? {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return (UTType(filenameExtension: ext) ?? .data).preferredMIMEType
    }

    private func addImageAttachment(url: URL?, data: Data, fileName: String, mimeType: String) async {
        if data.count > 5_000_000 {
            self.errorText = "Attachment \(fileName) exceeds 5 MB limit"
            return
        }

        let uti: UTType = {
            if let url {
                return UTType(filenameExtension: url.pathExtension) ?? .data
            }
            return UTType(mimeType: mimeType) ?? .data
        }()
        guard uti.conforms(to: .image) else {
            self.errorText = "Only image attachments are supported right now"
            return
        }

        let preview = Self.previewImage(data: data)
        self.attachments.append(
            RemPendingAttachment(
                url: url,
                data: data,
                fileName: fileName,
                mimeType: mimeType,
                preview: preview))
    }

    private static func previewImage(data: Data) -> RemGatewayPlatformImage? {
        #if canImport(AppKit)
        NSImage(data: data)
        #elseif canImport(UIKit)
        UIImage(data: data)
        #else
        nil
        #endif
    }

    private static func normalizedThinkingLevel(_ level: String?) -> String? {
        guard let level else { return nil }
        let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed.replacingOccurrences(
            of: "[\\s_-]+",
            with: "",
            options: .regularExpression)

        switch collapsed {
        case "adaptive", "auto":
            return "adaptive"
        case "max":
            return "max"
        case "xhigh", "extrahigh":
            return "xhigh"
        case "off", "none":
            return "off"
        case "on", "enable", "enabled":
            return "low"
        case "min", "minimal", "think":
            return "minimal"
        case "low", "thinkhard":
            return "low"
        case "mid", "med", "medium", "thinkharder", "harder":
            return "medium"
        case "high", "ultra", "ultrathink", "thinkhardest", "highest":
            return "high"
        default:
            return trimmed
        }
    }
}
