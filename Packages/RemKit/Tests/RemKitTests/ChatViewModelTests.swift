import RemKit
import Foundation
import Testing
@testable import RemChatUI

private func chatTextMessage(role: String, text: String, timestamp: Double) -> AnyCodable {
    AnyCodable([
        "role": role,
        "content": [["type": "text", "text": text]],
        "timestamp": timestamp,
    ])
}

private func historyPayload(
    sessionKey: String = "main",
    sessionId: String? = "sess-main",
    messages: [AnyCodable] = []) -> RemChatHistoryPayload
{
    RemChatHistoryPayload(
        sessionKey: sessionKey,
        sessionId: sessionId,
        messages: messages,
        thinkingLevel: "off")
}

private func sessionEntry(key: String, updatedAt: Double) -> RemChatSessionEntry {
    RemChatSessionEntry(
        key: key,
        kind: nil,
        displayName: nil,
        surface: nil,
        subject: nil,
        room: nil,
        space: nil,
        updatedAt: updatedAt,
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

private func thinkingOption(_ id: String, label: String? = nil) -> RemChatThinkingLevelOption {
    RemChatThinkingLevelOption(id: id, label: label ?? id)
}

private func sessionEntry(
    key: String,
    updatedAt: Double,
    model: String?,
    modelProvider: String? = nil) -> RemChatSessionEntry
{
    RemChatSessionEntry(
        key: key,
        kind: nil,
        displayName: nil,
        surface: nil,
        subject: nil,
        room: nil,
        space: nil,
        updatedAt: updatedAt,
        sessionId: nil,
        systemSent: nil,
        abortedLastRun: nil,
        thinkingLevel: nil,
        verboseLevel: nil,
        inputTokens: nil,
        outputTokens: nil,
        totalTokens: nil,
        modelProvider: modelProvider,
        model: model,
        contextTokens: nil)
}

private func modelChoice(id: String, name: String, provider: String = "anthropic") -> RemChatModelChoice {
    RemChatModelChoice(modelID: id, name: name, provider: provider, contextWindow: nil)
}

private func makeViewModel(
    sessionKey: String = "main",
    historyResponses: [RemChatHistoryPayload],
    historyRequestHook: (@Sendable (String) async throws -> RemChatHistoryPayload)? = nil,
    setActiveSessionHook: (@Sendable (String) async throws -> Void)? = nil,
    requestHealthHook: (@Sendable () async throws -> Bool)? = nil,
    sessionsResponses: [RemChatSessionsListResponse] = [],
    modelResponses: [[RemChatModelChoice]] = [],
    modelRequestHook: (@Sendable () async throws -> [RemChatModelChoice])? = nil,
    modelCatalogCompleteness: RemChatModelCatalogCompleteness = .unknown,
    modelCatalogProvenance: String? = nil,
    resetSessionHook: (@Sendable (String) async throws -> Void)? = nil,
    compactSessionHook: (@Sendable (String) async throws -> Void)? = nil,
    setSessionModelHook: (@Sendable (String?) async throws -> Void)? = nil,
    setSessionThinkingHook: (@Sendable (String) async throws -> Void)? = nil,
    initialThinkingLevel: String? = nil,
    onThinkingLevelChanged: (@MainActor @Sendable (String) -> Void)? = nil) async
    -> (TestChatTransport, RemChatViewModel)
{
    let transport = TestChatTransport(
        historyResponses: historyResponses,
        historyRequestHook: historyRequestHook,
        setActiveSessionHook: setActiveSessionHook,
        requestHealthHook: requestHealthHook,
        sessionsResponses: sessionsResponses,
        modelResponses: modelResponses,
        modelRequestHook: modelRequestHook,
        modelCatalogCompleteness: modelCatalogCompleteness,
        modelCatalogProvenance: modelCatalogProvenance,
        resetSessionHook: resetSessionHook,
        compactSessionHook: compactSessionHook,
        setSessionModelHook: setSessionModelHook,
        setSessionThinkingHook: setSessionThinkingHook)
    let vm = await MainActor.run {
        RemChatViewModel(
            sessionKey: sessionKey,
            transport: transport,
            initialThinkingLevel: initialThinkingLevel,
            onThinkingLevelChanged: onThinkingLevelChanged)
    }
    return (transport, vm)
}

private func loadAndWaitBootstrap(
    vm: RemChatViewModel,
    sessionId: String? = nil) async throws
{
    await MainActor.run { vm.load() }
    try await waitUntil("bootstrap") {
        await MainActor.run {
            vm.healthOK && (sessionId == nil || vm.sessionId == sessionId)
        }
    }
}

private func sendUserMessage(_ vm: RemChatViewModel, text: String = "hi") async {
    await MainActor.run {
        vm.input = text
        vm.send()
    }
}

@discardableResult
private func sendMessageAndEmitFinal(
    transport: TestChatTransport,
    vm: RemChatViewModel,
    text: String,
    sessionKey: String = "main") async throws -> String
{
    await sendUserMessage(vm, text: text)
    try await waitUntil("pending run starts") { await MainActor.run { vm.pendingRunCount == 1 } }
    try await waitUntil("chat.send starts") { await transport.lastSentRunId() != nil }

    let runId = try #require(await transport.lastSentRunId())
    transport.emit(
        .chat(
            RemChatEventPayload(
                runId: runId,
                sessionKey: sessionKey,
                state: "final",
                message: nil,
                errorMessage: nil)))
    return runId
}

private func emitAssistantText(
    transport: TestChatTransport,
    runId: String,
    text: String,
    seq: Int = 1)
{
    transport.emit(
        .agent(
            RemAgentEventPayload(
                runId: runId,
                seq: seq,
                stream: "assistant",
                ts: Int(Date().timeIntervalSince1970 * 1000),
                data: ["text": AnyCodable(text)])))
}

private func emitToolStart(
    transport: TestChatTransport,
    runId: String,
    seq: Int = 2)
{
    transport.emit(
        .agent(
            RemAgentEventPayload(
                runId: runId,
                seq: seq,
                stream: "tool",
                ts: Int(Date().timeIntervalSince1970 * 1000),
                data: [
                    "phase": AnyCodable("start"),
                    "name": AnyCodable("demo"),
                    "toolCallId": AnyCodable("t1"),
                    "args": AnyCodable(["x": 1]),
                ])))
}

private func emitExternalFinal(
    transport: TestChatTransport,
    runId: String = "other-run",
    sessionKey: String = "main")
{
    transport.emit(
        .chat(
            RemChatEventPayload(
                runId: runId,
                sessionKey: sessionKey,
                state: "final",
                message: nil,
                errorMessage: nil)))
}

@MainActor
private final class CallbackBox {
    var values: [String] = []
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

private actor AsyncCounter {
    private var value: Int

    init(_ initialValue: Int = 0) {
        self.value = initialValue
    }

    func increment() -> Int {
        self.value += 1
        return self.value
    }

    func current() -> Int {
        self.value
    }
}

private actor StringRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        self.values.append(value)
    }

    func snapshot() -> [String] {
        self.values
    }
}

private actor OptionalIntRecorder {
    private var values: [Int?] = []

    func append(_ value: Int?) {
        self.values.append(value)
    }

    func snapshot() -> [Int?] {
        self.values
    }
}

private actor TestChatTransportState {
    var historyCallCount: Int = 0
    var sessionsCallCount: Int = 0
    var modelsCallCount: Int = 0
    var resetSessionKeys: [String] = []
    var compactSessionKeys: [String] = []
    var sentRunIds: [String] = []
    var sentMessages: [String] = []
    var sentAttachmentFileNames: [[String]] = []
    var sentThinkingLevels: [String] = []
    var abortedRunIds: [String] = []
    var patchedModels: [String?] = []
    var patchedThinkingLevels: [String] = []
    var sendPreparationPhases: [RemChatSendPreparationPhase] = []
}

private final class TestChatTransport: @unchecked Sendable, RemChatTransport {
    private let state = TestChatTransportState()
    private let historyResponses: [RemChatHistoryPayload]
    private let historyRequestHook: (@Sendable (String) async throws -> RemChatHistoryPayload)?
    private let setActiveSessionHook: (@Sendable (String) async throws -> Void)?
    private let requestHealthHook: (@Sendable () async throws -> Bool)?
    private let sessionsResponses: [RemChatSessionsListResponse]
    private let sessionsRequestHook: (@Sendable (Int?) async throws -> RemChatSessionsListResponse)?
    private let modelResponses: [[RemChatModelChoice]]
    private let modelRequestHook: (@Sendable () async throws -> [RemChatModelChoice])?
    private let modelCatalogCompleteness: RemChatModelCatalogCompleteness
    private let modelCatalogProvenance: String?
    private let resetSessionHook: (@Sendable (String) async throws -> Void)?
    private let compactSessionHook: (@Sendable (String) async throws -> Void)?
    private let setSessionModelHook: (@Sendable (String?) async throws -> Void)?
    private let setSessionThinkingHook: (@Sendable (String) async throws -> Void)?
    private let sendPreparationHook: (@Sendable (RemChatSendPreparationPhase) async -> Void)?
    private let sendMessageHook: (@Sendable (String) async throws -> RemChatSendResponse)?

    private let stream: AsyncStream<RemChatTransportEvent>
    private let continuation: AsyncStream<RemChatTransportEvent>.Continuation

    init(
        historyResponses: [RemChatHistoryPayload],
        historyRequestHook: (@Sendable (String) async throws -> RemChatHistoryPayload)? = nil,
        setActiveSessionHook: (@Sendable (String) async throws -> Void)? = nil,
        requestHealthHook: (@Sendable () async throws -> Bool)? = nil,
        sessionsResponses: [RemChatSessionsListResponse] = [],
        sessionsRequestHook: (@Sendable (Int?) async throws -> RemChatSessionsListResponse)? = nil,
        modelResponses: [[RemChatModelChoice]] = [],
        modelRequestHook: (@Sendable () async throws -> [RemChatModelChoice])? = nil,
        modelCatalogCompleteness: RemChatModelCatalogCompleteness = .unknown,
        modelCatalogProvenance: String? = nil,
        resetSessionHook: (@Sendable (String) async throws -> Void)? = nil,
        compactSessionHook: (@Sendable (String) async throws -> Void)? = nil,
        setSessionModelHook: (@Sendable (String?) async throws -> Void)? = nil,
        setSessionThinkingHook: (@Sendable (String) async throws -> Void)? = nil,
        sendPreparationHook: (@Sendable (RemChatSendPreparationPhase) async -> Void)? = nil,
        sendMessageHook: (@Sendable (String) async throws -> RemChatSendResponse)? = nil)
    {
        self.historyResponses = historyResponses
        self.historyRequestHook = historyRequestHook
        self.setActiveSessionHook = setActiveSessionHook
        self.requestHealthHook = requestHealthHook
        self.sessionsResponses = sessionsResponses
        self.sessionsRequestHook = sessionsRequestHook
        self.modelResponses = modelResponses
        self.modelRequestHook = modelRequestHook
        self.modelCatalogCompleteness = modelCatalogCompleteness
        self.modelCatalogProvenance = modelCatalogProvenance
        self.resetSessionHook = resetSessionHook
        self.compactSessionHook = compactSessionHook
        self.setSessionModelHook = setSessionModelHook
        self.setSessionThinkingHook = setSessionThinkingHook
        self.sendPreparationHook = sendPreparationHook
        self.sendMessageHook = sendMessageHook
        var cont: AsyncStream<RemChatTransportEvent>.Continuation!
        self.stream = AsyncStream { c in
            cont = c
        }
        self.continuation = cont
    }

    func events() -> AsyncStream<RemChatTransportEvent> {
        self.stream
    }

    func setActiveSessionKey(_ sessionKey: String) async throws {
        try await self.setActiveSessionHook?(sessionKey)
    }

    func requestHistory(sessionKey: String) async throws -> RemChatHistoryPayload {
        if let historyRequestHook = self.historyRequestHook {
            return try await historyRequestHook(sessionKey)
        }
        let idx = await self.state.historyCallCount
        await self.state.setHistoryCallCount(idx + 1)
        if idx < self.historyResponses.count {
            return self.historyResponses[idx]
        }
        return self.historyResponses.last ?? RemChatHistoryPayload(
            sessionKey: sessionKey,
            sessionId: nil,
            messages: [],
            thinkingLevel: "off")
    }

    func sendMessage(
        sessionKey _: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [RemChatAttachmentPayload]) async throws -> RemChatSendResponse
    {
        await self.state.sentRunIdsAppend(idempotencyKey)
        await self.state.sentMessagesAppend(message)
        await self.state.sentAttachmentFileNamesAppend(attachments.map(\.fileName))
        await self.state.sentThinkingLevelsAppend(thinking)
        if let sendMessageHook = self.sendMessageHook {
            return try await sendMessageHook(idempotencyKey)
        }
        return RemChatSendResponse(runId: idempotencyKey, status: "ok")
    }

    func observeSendPreparation(
        sessionKey _: String,
        idempotencyKey _: String,
        phase: RemChatSendPreparationPhase,
        startedAtUptimeNanoseconds _: UInt64,
        messageLength _: Int,
        attachmentsCount _: Int
    ) async {
        await self.state.sendPreparationPhasesAppend(phase)
        await self.sendPreparationHook?(phase)
    }

    func abortRun(sessionKey _: String, runId: String) async throws {
        await self.state.abortedRunIdsAppend(runId)
    }

    func listSessions(limit: Int?) async throws -> RemChatSessionsListResponse {
        if let sessionsRequestHook = self.sessionsRequestHook {
            return try await sessionsRequestHook(limit)
        }
        let idx = await self.state.sessionsCallCount
        await self.state.setSessionsCallCount(idx + 1)
        if idx < self.sessionsResponses.count {
            return self.sessionsResponses[idx]
        }
        return self.sessionsResponses.last ?? RemChatSessionsListResponse(
            ts: nil,
            path: nil,
            count: 0,
            defaults: nil,
            sessions: [])
    }

    func listModels() async throws -> [RemChatModelChoice] {
        if let modelRequestHook {
            return try await modelRequestHook()
        }
        let idx = await self.state.modelsCallCount
        await self.state.setModelsCallCount(idx + 1)
        if idx < self.modelResponses.count {
            return self.modelResponses[idx]
        }
        return self.modelResponses.last ?? []
    }

    func listModelCatalog() async throws -> RemChatModelCatalogSnapshot {
        RemChatModelCatalogSnapshot(
            models: try await self.listModels(),
            completeness: self.modelCatalogCompleteness,
            provenance: self.modelCatalogProvenance)
    }

    func setSessionModel(sessionKey _: String, model: String?) async throws {
        await self.state.patchedModelsAppend(model)
        if let setSessionModelHook = self.setSessionModelHook {
            try await setSessionModelHook(model)
        }
    }

    func resetSession(sessionKey: String) async throws {
        await self.state.resetSessionKeysAppend(sessionKey)
        if let resetSessionHook = self.resetSessionHook {
            try await resetSessionHook(sessionKey)
        }
    }

    func compactSession(sessionKey: String) async throws {
        await self.state.compactSessionKeysAppend(sessionKey)
        if let compactSessionHook = self.compactSessionHook {
            try await compactSessionHook(sessionKey)
        }
    }

    func setSessionThinking(sessionKey _: String, thinkingLevel: String) async throws {
        await self.state.patchedThinkingLevelsAppend(thinkingLevel)
        if let setSessionThinkingHook = self.setSessionThinkingHook {
            try await setSessionThinkingHook(thinkingLevel)
        }
    }

    func requestHealth(timeoutMs _: Int) async throws -> Bool {
        try await self.requestHealthHook?() ?? true
    }

    func emit(_ evt: RemChatTransportEvent) {
        self.continuation.yield(evt)
    }

    func lastSentRunId() async -> String? {
        let ids = await self.state.sentRunIds
        return ids.last
    }

    func abortedRunIds() async -> [String] {
        await self.state.abortedRunIds
    }

    func sentThinkingLevels() async -> [String] {
        await self.state.sentThinkingLevels
    }

    func sentMessages() async -> [String] {
        await self.state.sentMessages
    }

    func sentAttachmentFileNames() async -> [[String]] {
        await self.state.sentAttachmentFileNames
    }

    func patchedModels() async -> [String?] {
        await self.state.patchedModels
    }

    func patchedThinkingLevels() async -> [String] {
        await self.state.patchedThinkingLevels
    }

    func sendPreparationPhases() async -> [RemChatSendPreparationPhase] {
        await self.state.sendPreparationPhases
    }

    func resetSessionKeys() async -> [String] {
        await self.state.resetSessionKeys
    }

    func compactSessionKeys() async -> [String] {
        await self.state.compactSessionKeys
    }

    func historyCallCount() async -> Int {
        await self.state.historyCallCount
    }
}

extension TestChatTransportState {
    fileprivate func setHistoryCallCount(_ v: Int) {
        self.historyCallCount = v
    }

    fileprivate func setSessionsCallCount(_ v: Int) {
        self.sessionsCallCount = v
    }

    fileprivate func setModelsCallCount(_ v: Int) {
        self.modelsCallCount = v
    }

    fileprivate func sentRunIdsAppend(_ v: String) {
        self.sentRunIds.append(v)
    }

    fileprivate func sentMessagesAppend(_ v: String) {
        self.sentMessages.append(v)
    }

    fileprivate func sentAttachmentFileNamesAppend(_ v: [String]) {
        self.sentAttachmentFileNames.append(v)
    }

    fileprivate func abortedRunIdsAppend(_ v: String) {
        self.abortedRunIds.append(v)
    }

    fileprivate func sentThinkingLevelsAppend(_ v: String) {
        self.sentThinkingLevels.append(v)
    }

    fileprivate func patchedModelsAppend(_ v: String?) {
        self.patchedModels.append(v)
    }

    fileprivate func patchedThinkingLevelsAppend(_ v: String) {
        self.patchedThinkingLevels.append(v)
    }

    fileprivate func sendPreparationPhasesAppend(_ phase: RemChatSendPreparationPhase) {
        self.sendPreparationPhases.append(phase)
    }

    fileprivate func resetSessionKeysAppend(_ v: String) {
        self.resetSessionKeys.append(v)
    }

    fileprivate func compactSessionKeysAppend(_ v: String) {
        self.compactSessionKeys.append(v)
    }
}

@Suite struct ChatViewModelTests {
    @Test func repeatedViewAppearanceKeepsWarmSessionWithoutReloadingHistory() async throws {
        let history = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "already warm", timestamp: 1)])
        let (transport, vm) = await makeViewModel(historyResponses: [history])
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.load()
            vm.load()
        }
        try await Task.sleep(for: .milliseconds(25))

        #expect(await transport.historyCallCount() == 1)
        #expect(await MainActor.run {
            vm.messages.first?.content.first?.text == "already warm" && !vm.isLoading
        })
    }

    @Test func repeatedAppearanceDuringBootstrapCoalescesOntoExistingRequest() async throws {
        let gate = AsyncGate()
        let historyRequests = AsyncCounter()
        let history = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "loaded once", timestamp: 1)])
        let (transport, vm) = await makeViewModel(
            historyResponses: [],
            historyRequestHook: { _ in
                _ = await historyRequests.increment()
                await gate.wait()
                return history
            })

        await MainActor.run {
            vm.load()
            vm.load()
        }
        try await waitUntil("history request starts") {
            await historyRequests.current() == 1
        }
        await gate.open()
        try await waitUntil("coalesced bootstrap") {
            await MainActor.run { vm.healthOK && !vm.isLoading }
        }

        #expect(await historyRequests.current() == 1)
        #expect(await transport.historyCallCount() == 0)
    }

    @Test func explicitRefreshReloadsWarmSessionHistory() async throws {
        let first = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "first", timestamp: 1)])
        let refreshed = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "refreshed", timestamp: 2)])
        let (transport, vm) = await makeViewModel(historyResponses: [first, refreshed])
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run { vm.refresh() }
        try await waitUntil("explicit refresh") {
            await MainActor.run {
                vm.messages.first?.content.first?.text == "refreshed" && !vm.isLoading
            }
        }

        #expect(await transport.historyCallCount() == 2)
    }

    @Test func failedAppearanceLoadRemainsRetryable() async throws {
        let historyRequests = AsyncCounter()
        let recovered = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "recovered", timestamp: 1)])
        let (_, vm) = await makeViewModel(
            historyResponses: [],
            historyRequestHook: { _ in
                let attempt = await historyRequests.increment()
                if attempt == 1 { throw URLError(.cannotConnectToHost) }
                return recovered
            })

        await MainActor.run { vm.load() }
        try await waitUntil("first bootstrap fails") {
            await MainActor.run { vm.errorText != nil && !vm.isLoading }
        }

        await MainActor.run { vm.load() }
        try await waitUntil("appearance retry succeeds") {
            await MainActor.run {
                vm.messages.first?.content.first?.text == "recovered" && !vm.isLoading
            }
        }

        #expect(await historyRequests.current() == 2)
    }

    @Test func failedActivationDoesNotMarkSessionWarmAndNextAppearanceRecovers() async throws {
        let activationAttempts = AsyncCounter()
        let initial = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "history without activation", timestamp: 1)])
        let recovered = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "activation recovered", timestamp: 2)])
        let (transport, vm) = await makeViewModel(
            historyResponses: [initial, recovered],
            setActiveSessionHook: { _ in
                if await activationAttempts.increment() == 1 {
                    throw URLError(.cannotConnectToHost)
                }
            })

        await MainActor.run { vm.load() }
        try await waitUntil("first bootstrap finishes without activation") {
            await MainActor.run { !vm.isLoading && !vm.healthOK }
        }

        await MainActor.run { vm.load() }
        try await waitUntil("appearance retries activation and history") {
            await MainActor.run {
                vm.messages.first?.content.first?.text == "activation recovered" &&
                    vm.healthOK && !vm.isLoading
            }
        }

        #expect(await activationAttempts.current() == 2)
        #expect(await transport.historyCallCount() == 2)
    }

    @Test func failedPostRunHistoryRefreshMakesReentryHealFromGateway() async throws {
        let historyAttempts = AsyncCounter()
        let initial = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "before run", timestamp: 1)])
        let recovered = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "durable final", timestamp: 2)])
        let (transport, vm) = await makeViewModel(
            historyResponses: [],
            historyRequestHook: { _ in
                switch await historyAttempts.increment() {
                case 1: return initial
                case 2: throw URLError(.networkConnectionLost)
                default: return recovered
                }
            })
        try await loadAndWaitBootstrap(vm: vm)
        _ = try await sendMessageAndEmitFinal(transport: transport, vm: vm, text: "run")
        try await waitUntil("post-run refresh fails") { await historyAttempts.current() == 2 }

        await MainActor.run { vm.load() }
        try await waitUntil("re-entry heals failed run refresh") {
            await MainActor.run {
                vm.messages.first?.content.first?.text == "durable final" && !vm.isLoading
            }
        }

        #expect(await historyAttempts.current() == 3)
    }

    @Test func failedPostResetBootstrapRemainsRetryableOnReentry() async throws {
        let historyAttempts = AsyncCounter()
        let initial = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "before reset", timestamp: 1)])
        let recovered = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "after reset", timestamp: 2)])
        let (transport, vm) = await makeViewModel(
            historyResponses: [],
            historyRequestHook: { _ in
                switch await historyAttempts.increment() {
                case 1: return initial
                case 2: throw URLError(.networkConnectionLost)
                default: return recovered
                }
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "/new"
            vm.send()
        }
        try await waitUntil("post-reset bootstrap fails") {
            guard await historyAttempts.current() == 2 else { return false }
            return await MainActor.run { vm.errorText != nil && !vm.isLoading }
        }

        await MainActor.run { vm.load() }
        try await waitUntil("re-entry heals reset bootstrap") {
            await MainActor.run {
                vm.messages.first?.content.first?.text == "after reset" && !vm.isLoading
            }
        }

        #expect(await transport.resetSessionKeys() == ["main"])
        #expect(await historyAttempts.current() == 3)
    }

    @Test func failedPostCompactBootstrapRemainsRetryableOnReentry() async throws {
        let historyAttempts = AsyncCounter()
        let initial = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "before compact", timestamp: 1)])
        let recovered = historyPayload(
            messages: [chatTextMessage(role: "assistant", text: "after compact", timestamp: 2)])
        let (transport, vm) = await makeViewModel(
            historyResponses: [],
            historyRequestHook: { _ in
                switch await historyAttempts.increment() {
                case 1: return initial
                case 2: throw URLError(.networkConnectionLost)
                default: return recovered
                }
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "/compact"
            vm.send()
        }
        try await waitUntil("post-compact bootstrap fails") {
            guard await historyAttempts.current() == 2 else { return false }
            return await MainActor.run { vm.errorText != nil && !vm.isLoading }
        }

        await MainActor.run { vm.load() }
        try await waitUntil("re-entry heals compact bootstrap") {
            await MainActor.run {
                vm.messages.first?.content.first?.text == "after compact" && !vm.isLoading
            }
        }

        #expect(await transport.compactSessionKeys() == ["main"])
        #expect(await historyAttempts.current() == 3)
    }

    @Test func sessionSwitchClearsConversationScopedComposerState() async {
        let transport = TestChatTransport(historyResponses: [historyPayload(sessionKey: "other")])
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        await MainActor.run {
            vm.input = "private draft"
            vm.attachments = [
                RemPendingAttachment(
                    url: nil,
                    data: Data([0x01]),
                    fileName: "private.txt",
                    mimeType: "text/plain",
                    preview: nil),
            ]
            vm.switchSession(to: "other")
        }

        #expect(await MainActor.run { vm.input.isEmpty })
        #expect(await MainActor.run { vm.attachments.isEmpty })
    }

    @Test func staleActiveSessionCompletionRetriesAndReassertsLatestKey() async throws {
        let aGate = AsyncGate()
        let aRequests = AsyncCounter()
        let bRequests = AsyncCounter()
        let completions = StringRecorder()
        let (_, vm) = await makeViewModel(
            historyResponses: [historyPayload(sessionKey: "b", sessionId: "session-b")],
            setActiveSessionHook: { sessionKey in
                if sessionKey == "a" {
                    _ = await aRequests.increment()
                    await aGate.wait()
                }
                if sessionKey == "b", await bRequests.increment() == 2 {
                    throw NSError(domain: "TransientActivation", code: 1)
                }
                await completions.append(sessionKey)
            })
        await MainActor.run { vm.switchSession(to: "a") }
        try await waitUntil("session a activation started") { await aRequests.current() == 1 }
        await MainActor.run { vm.switchSession(to: "b") }
        try await waitUntil("session b activation completed") {
            await completions.snapshot().contains("b")
        }

        await aGate.open()
        try await waitUntil("latest session key reasserted") {
            let values = await completions.snapshot()
            return values.suffix(2) == ["a", "b"]
        }
        try await waitUntil("session b bootstrap completed") {
            await MainActor.run { vm.sessionKey == "b" && vm.sessionId == "session-b" && !vm.isLoading }
        }
    }

    @Test func exhaustedStaleActivationRecoveryCannotBeMaskedByHealthPoll() async throws {
        let aGate = AsyncGate()
        let healthGate = AsyncGate()
        let aRequests = AsyncCounter()
        let bAttempts = AsyncCounter()
        let healthRequests = AsyncCounter()
        let (_, vm) = await makeViewModel(
            historyResponses: [historyPayload(sessionKey: "b", sessionId: "session-b")],
            setActiveSessionHook: { sessionKey in
                if sessionKey == "a" {
                    _ = await aRequests.increment()
                    await aGate.wait()
                    return
                }
                if sessionKey == "b", await bAttempts.increment() > 1 {
                    throw NSError(domain: "PersistentActivation", code: 1)
                }
            },
            requestHealthHook: {
                _ = await healthRequests.increment()
                await healthGate.wait()
                return true
            })

        await MainActor.run { vm.switchSession(to: "a") }
        try await waitUntil("session a activation started") { await aRequests.current() == 1 }
        await MainActor.run { vm.switchSession(to: "b") }
        try await waitUntil("session b health pending") { await healthRequests.current() == 1 }

        await aGate.open()
        try await waitUntil("stale activation retries exhausted") { await bAttempts.current() == 4 }
        await healthGate.open()
        try await waitUntil("session b bootstrap completed without masking activation failure") {
            await MainActor.run { vm.sessionId == "session-b" && !vm.isLoading && !vm.healthOK }
        }
    }

    @Test func latestSessionSwitchOwnsHistoryAndLoadingState() async throws {
        let aGate = AsyncGate()
        let bGate = AsyncGate()
        let aRequests = AsyncCounter()
        let bRequests = AsyncCounter()
        let aCompletions = AsyncCounter()
        let transport = TestChatTransport(
            historyResponses: [],
            historyRequestHook: { sessionKey in
                switch sessionKey {
                case "a":
                    _ = await aRequests.increment()
                    await aGate.wait()
                    _ = await aCompletions.increment()
                    return historyPayload(
                        sessionKey: "a",
                        sessionId: "session-a",
                        messages: [chatTextMessage(role: "assistant", text: "from a", timestamp: 1)])
                case "b":
                    _ = await bRequests.increment()
                    await bGate.wait()
                    return historyPayload(
                        sessionKey: "b",
                        sessionId: "session-b",
                        messages: [chatTextMessage(role: "assistant", text: "from b", timestamp: 2)])
                default:
                    return historyPayload(sessionKey: sessionKey)
                }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }

        await MainActor.run { vm.switchSession(to: "a") }
        try await waitUntil("session a history requested") { await aRequests.current() == 1 }

        await MainActor.run { vm.switchSession(to: "b") }
        try await waitUntil("session b history requested") { await bRequests.current() == 1 }
        #expect(await MainActor.run { vm.sessionKey == "b" && vm.isLoading })

        await aGate.open()
        try await waitUntil("stale session a response completed") { await aCompletions.current() == 1 }
        #expect(await MainActor.run {
            vm.sessionKey == "b" && vm.sessionId != "session-a" && vm.messages.isEmpty && vm.isLoading
        })

        await bGate.open()
        try await waitUntil("session b committed") {
            await MainActor.run { vm.sessionId == "session-b" && !vm.isLoading }
        }
        #expect(await MainActor.run {
            vm.messages.first?.content.compactMap(\.text).joined() == "from b"
        })
    }

    @Test func streamsAssistantAndClearsOnFinal() async throws {
        let sessionId = "sess-main"
        let history1 = historyPayload(sessionId: sessionId)
        let history2 = historyPayload(
            sessionId: sessionId,
            messages: [
                chatTextMessage(
                    role: "assistant",
                    text: "final answer",
                    timestamp: Date().timeIntervalSince1970 * 1000),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)
        await sendUserMessage(vm)
        try await waitUntil("pending run starts") { await MainActor.run { vm.pendingRunCount == 1 } }

        emitAssistantText(transport: transport, runId: sessionId, text: "streaming…")

        try await waitUntil("assistant stream visible") {
            await MainActor.run { vm.streamingAssistantText == "streaming…" }
        }

        emitToolStart(transport: transport, runId: sessionId)

        try await waitUntil("tool call pending") { await MainActor.run { vm.pendingToolCalls.count == 1 } }

        let runId = try #require(await transport.lastSentRunId())
        transport.emit(
            .chat(
                RemChatEventPayload(
                    runId: runId,
                    sessionKey: "main",
                    state: "final",
                    message: nil,
                    errorMessage: nil)))

        try await waitUntil("pending run clears") { await MainActor.run { vm.pendingRunCount == 0 } }
        try await waitUntil("history refresh") {
            await MainActor.run { vm.messages.contains(where: { $0.role == "assistant" }) }
        }
        #expect(await MainActor.run { vm.streamingAssistantText } == nil)
        #expect(await MainActor.run { vm.pendingToolCalls.isEmpty })
    }

    @Test func keepsOptimisticUserMessageWhenFinalRefreshReturnsOnlyAssistantHistory() async throws {
        let sessionId = "sess-main"
        let now = Date().timeIntervalSince1970 * 1000
        let history1 = historyPayload(sessionId: sessionId)
        let history2 = historyPayload(
            sessionId: sessionId,
            messages: [
                chatTextMessage(
                    role: "assistant",
                    text: "final answer",
                    timestamp: now + 1),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)
        try await sendMessageAndEmitFinal(
            transport: transport,
            vm: vm,
            text: "hello from mac webchat")

        try await waitUntil("assistant history refreshes without dropping user message") {
            await MainActor.run {
                let texts = vm.messages.map { message in
                    (message.role, message.content.compactMap(\.text).joined(separator: "\n"))
                }
                return texts.contains(where: { $0.0 == "assistant" && $0.1 == "final answer" }) &&
                    texts.contains(where: { $0.0 == "user" && $0.1 == "hello from mac webchat" })
            }
        }
    }

    @Test func keepsOptimisticUserMessageWhenFinalRefreshHistoryIsTemporarilyEmpty() async throws {
        let sessionId = "sess-main"
        let history1 = historyPayload(sessionId: sessionId)
        let history2 = historyPayload(sessionId: sessionId, messages: [])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)
        try await sendMessageAndEmitFinal(
            transport: transport,
            vm: vm,
            text: "hello from mac webchat")

        try await waitUntil("empty refresh does not clear optimistic user message") {
            await MainActor.run {
                vm.messages.contains { message in
                    message.role == "user" &&
                        message.content.compactMap(\.text).joined(separator: "\n") == "hello from mac webchat"
                }
            }
        }
    }

    @Test func doesNotDuplicateUserMessageWhenRefreshReturnsCanonicalTimestamp() async throws {
        let sessionId = "sess-main"
        let now = Date().timeIntervalSince1970 * 1000
        let history1 = historyPayload(sessionId: sessionId)
        let history2 = historyPayload(
            sessionId: sessionId,
            messages: [
                chatTextMessage(
                    role: "user",
                    text: "hello from mac webchat",
                    timestamp: now + 5_000),
                chatTextMessage(
                    role: "assistant",
                    text: "final answer",
                    timestamp: now + 6_000),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)
        try await sendMessageAndEmitFinal(
            transport: transport,
            vm: vm,
            text: "hello from mac webchat")

        try await waitUntil("canonical refresh keeps one user message") {
            await MainActor.run {
                let userMessages = vm.messages.filter { message in
                    message.role == "user" &&
                        message.content.compactMap(\.text).joined(separator: "\n") == "hello from mac webchat"
                }
                let hasAssistant = vm.messages.contains { message in
                    message.role == "assistant" &&
                        message.content.compactMap(\.text).joined(separator: "\n") == "final answer"
                }
                return hasAssistant && userMessages.count == 1
            }
        }
    }

    @Test func preservesRepeatedOptimisticUserMessagesWithIdenticalContentDuringRefresh() async throws {
        let sessionId = "sess-main"
        let now = Date().timeIntervalSince1970 * 1000
        let history1 = historyPayload(sessionId: sessionId)
        let history2 = historyPayload(
            sessionId: sessionId,
            messages: [
                chatTextMessage(
                    role: "user",
                    text: "retry",
                    timestamp: now + 5_000),
                chatTextMessage(
                    role: "assistant",
                    text: "first answer",
                    timestamp: now + 6_000),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2, history2])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)
        try await sendMessageAndEmitFinal(
            transport: transport,
            vm: vm,
            text: "retry")
        try await sendMessageAndEmitFinal(
            transport: transport,
            vm: vm,
            text: "retry")

        try await waitUntil("repeated optimistic user message is preserved") {
            await MainActor.run {
                let retryMessages = vm.messages.filter { message in
                    message.role == "user" &&
                        message.content.compactMap(\.text).joined(separator: "\n") == "retry"
                }
                let hasAssistant = vm.messages.contains { message in
                    message.role == "assistant" &&
                        message.content.compactMap(\.text).joined(separator: "\n") == "first answer"
                }
                return hasAssistant && retryMessages.count == 2
            }
        }
    }

    @Test func acceptsCanonicalSessionKeyEventsForOwnPendingRun() async throws {
        let history1 = historyPayload()
        let history2 = historyPayload(
            messages: [
                chatTextMessage(
                    role: "assistant",
                    text: "from history",
                    timestamp: Date().timeIntervalSince1970 * 1000),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])
        try await loadAndWaitBootstrap(vm: vm)
        await sendUserMessage(vm)
        try await waitUntil("pending run starts") { await MainActor.run { vm.pendingRunCount == 1 } }
        try await waitUntil("chat.send starts") { await transport.lastSentRunId() != nil }

        let runId = try #require(await transport.lastSentRunId())
        transport.emit(
            .chat(
                RemChatEventPayload(
                    runId: runId,
                    sessionKey: "agent:main:main",
                    state: "final",
                    message: nil,
                    errorMessage: nil)))

        try await waitUntil("pending run clears") { await MainActor.run { vm.pendingRunCount == 0 } }
        try await waitUntil("history refresh") {
            await MainActor.run { vm.messages.contains(where: { $0.role == "assistant" }) }
        }
    }

    @Test func acceptsCanonicalSessionKeyEventsForExternalRuns() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history1 = historyPayload(messages: [chatTextMessage(role: "user", text: "first", timestamp: now)])
        let history2 = historyPayload(
            messages: [
                chatTextMessage(role: "user", text: "first", timestamp: now),
                chatTextMessage(role: "assistant", text: "from external run", timestamp: now + 1),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])

        await MainActor.run { vm.load() }
        try await waitUntil("bootstrap history loaded") { await MainActor.run { vm.messages.count == 1 } }

        transport.emit(
            .chat(
                RemChatEventPayload(
                    runId: "external-run",
                    sessionKey: "agent:main:main",
                    state: "final",
                    message: nil,
                    errorMessage: nil)))

        try await waitUntil("history refresh after canonical external event") {
            await MainActor.run { vm.messages.count == 2 }
        }
    }

    @Test func appendsExternalSessionUserMessageForActiveSession() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let (transport, vm) = await makeViewModel(historyResponses: [historyPayload()])

        await MainActor.run { vm.load() }
        try await waitUntil("bootstrap history loaded") { await MainActor.run { vm.messages.isEmpty } }

        transport.emit(
            .sessionMessage(
                RemSessionMessageEventPayload(
                    sessionKey: "agent:main:main",
                    message: RemChatMessage(
                        role: "user",
                        content: [
                            RemChatMessageContent(
                                type: "text",
                                text: "spoken transcript",
                                mimeType: nil,
                                fileName: nil,
                                content: nil),
                        ],
                        timestamp: now),
                    messageId: "msg-1",
                    messageSeq: 1)))

        try await waitUntil("external transcript visible") {
            await MainActor.run {
                vm.messages.count == 1 &&
                    vm.messages.first?.role == "user" &&
                    vm.messages.first?.content.first?.text == "spoken transcript"
            }
        }
    }

    @Test func ignoresExternalSessionUserMessageForOtherSession() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let (transport, vm) = await makeViewModel(historyResponses: [historyPayload()])

        await MainActor.run { vm.load() }
        try await waitUntil("bootstrap history loaded") { await MainActor.run { vm.messages.isEmpty } }

        transport.emit(
            .sessionMessage(
                RemSessionMessageEventPayload(
                    sessionKey: "other",
                    message: RemChatMessage(
                        role: "user",
                        content: [
                            RemChatMessageContent(
                                type: "text",
                                text: "other transcript",
                                mimeType: nil,
                                fileName: nil,
                                content: nil),
                        ],
                        timestamp: now),
                    messageId: "msg-2",
                    messageSeq: 2)))

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await MainActor.run { vm.messages.isEmpty })
    }

    @Test func preservesMessageIDsAcrossHistoryRefreshes() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history1 = historyPayload(messages: [chatTextMessage(role: "user", text: "hello", timestamp: now)])
        let history2 = historyPayload(
            messages: [
                chatTextMessage(role: "user", text: "hello", timestamp: now),
                chatTextMessage(role: "assistant", text: "world", timestamp: now + 1),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])

        await MainActor.run { vm.load() }
        try await waitUntil("bootstrap history loaded") { await MainActor.run { vm.messages.count == 1 } }
        let firstIdBefore = try #require(await MainActor.run { vm.messages.first?.id })

        emitExternalFinal(transport: transport)

        try await waitUntil("history refresh") { await MainActor.run { vm.messages.count == 2 } }
        let firstIdAfter = try #require(await MainActor.run { vm.messages.first?.id })
        #expect(firstIdAfter == firstIdBefore)
    }

    @Test func clearsStreamingOnExternalFinalEvent() async throws {
        let sessionId = "sess-main"
        let history = historyPayload(sessionId: sessionId)
        let (transport, vm) = await makeViewModel(historyResponses: [history, history])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)

        emitAssistantText(transport: transport, runId: sessionId, text: "external stream")
        emitToolStart(transport: transport, runId: sessionId)

        try await waitUntil("streaming active") {
            await MainActor.run { vm.streamingAssistantText == "external stream" }
        }
        try await waitUntil("tool call pending") { await MainActor.run { vm.pendingToolCalls.count == 1 } }

        emitExternalFinal(transport: transport)

        try await waitUntil("streaming cleared") { await MainActor.run { vm.streamingAssistantText == nil } }
        #expect(await MainActor.run { vm.pendingToolCalls.isEmpty })
    }

    @Test func seqGapClearsPendingRunsAndAutoRefreshesHistory() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history1 = historyPayload()
        let history2 = historyPayload(messages: [chatTextMessage(role: "assistant", text: "resynced after gap", timestamp: now)])

        let (transport, vm) = await makeViewModel(historyResponses: [history1, history2])

        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "hello")
        try await waitUntil("pending run starts") { await MainActor.run { vm.pendingRunCount == 1 } }

        transport.emit(.seqGap)

        try await waitUntil("pending run clears on seqGap") {
            await MainActor.run { vm.pendingRunCount == 0 }
        }
        try await waitUntil("history refreshes on seqGap") {
            await MainActor.run { vm.messages.contains(where: { $0.role == "assistant" }) }
        }
        #expect(await MainActor.run { vm.errorText == nil })
    }

    @Test func sessionChoicesPreferMainAndRecent() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let recent = now - (2 * 60 * 60 * 1000)
        let recentOlder = now - (5 * 60 * 60 * 1000)
        let stale = now - (26 * 60 * 60 * 1000)
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 4,
            defaults: nil,
            sessions: [
                sessionEntry(key: "recent-1", updatedAt: recent),
                sessionEntry(key: "main", updatedAt: stale),
                sessionEntry(key: "recent-2", updatedAt: recentOlder),
                sessionEntry(key: "old-1", updatedAt: stale),
            ])

        let (_, vm) = await makeViewModel(historyResponses: [history], sessionsResponses: [sessions])
        await MainActor.run { vm.load() }
        try await waitUntil("sessions loaded") { await MainActor.run { !vm.sessions.isEmpty } }

        let keys = await MainActor.run { vm.sessionChoices.map(\.key) }
        #expect(keys == ["main", "recent-1", "recent-2"])
    }

    @Test func sessionChoicesIncludeCurrentWhenMissing() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let recent = now - (30 * 60 * 1000)
        let history = historyPayload(sessionKey: "custom", sessionId: "sess-custom")
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: recent),
            ])

        let (_, vm) = await makeViewModel(
            sessionKey: "custom",
            historyResponses: [history],
            sessionsResponses: [sessions])
        await MainActor.run { vm.load() }
        try await waitUntil("sessions loaded") { await MainActor.run { !vm.sessions.isEmpty } }

        let keys = await MainActor.run { vm.sessionChoices.map(\.key) }
        #expect(keys == ["main", "custom"])
    }

    @Test func sessionChoicesUseResolvedMainSessionKeyInsteadOfLiteralMain() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let recent = now - (30 * 60 * 1000)
        let recentOlder = now - (90 * 60 * 1000)
        let history = historyPayload(sessionKey: "Luke’s MacBook Pro", sessionId: "sess-main")
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 2,
            defaults: RemChatSessionsDefaults(
                model: nil,
                contextTokens: nil,
                mainSessionKey: "Luke’s MacBook Pro"),
            sessions: [
                RemChatSessionEntry(
                    key: "Luke’s MacBook Pro",
                    kind: nil,
                    displayName: "Luke’s MacBook Pro",
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: recent,
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
                    contextTokens: nil),
                sessionEntry(key: "recent-1", updatedAt: recentOlder),
            ])

        let (_, vm) = await makeViewModel(
            sessionKey: "Luke’s MacBook Pro",
            historyResponses: [history],
            sessionsResponses: [sessions])
        await MainActor.run { vm.load() }
        try await waitUntil("sessions loaded") { await MainActor.run { !vm.sessions.isEmpty } }

        let keys = await MainActor.run { vm.sessionChoices.map(\.key) }
        #expect(keys == ["Luke’s MacBook Pro", "recent-1"])
    }

    @Test func sessionChoicesHideInternalOnboardingSession() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let recent = now - (2 * 60 * 1000)
        let recentOlder = now - (5 * 60 * 1000)
        let history = historyPayload(sessionKey: "agent:main:main", sessionId: "sess-main")
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 2,
            defaults: RemChatSessionsDefaults(
                model: nil,
                contextTokens: nil,
                mainSessionKey: "agent:main:main"),
            sessions: [
                RemChatSessionEntry(
                    key: "agent:main:onboarding",
                    kind: nil,
                    displayName: "Luke’s MacBook Pro",
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: recent,
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
                    contextTokens: nil),
                RemChatSessionEntry(
                    key: "agent:main:main",
                    kind: nil,
                    displayName: "Luke’s MacBook Pro",
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: recentOlder,
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
                    contextTokens: nil),
            ])

        let (_, vm) = await makeViewModel(
            sessionKey: "agent:main:main",
            historyResponses: [history],
            sessionsResponses: [sessions])
        await MainActor.run { vm.load() }
        try await waitUntil("sessions loaded") { await MainActor.run { !vm.sessions.isEmpty } }

        let keys = await MainActor.run { vm.sessionChoices.map(\.key) }
        #expect(keys == ["agent:main:main"])
    }

    @Test func resetTriggerResetsSessionAndReloadsHistory() async throws {
        let before = historyPayload(
            messages: [
                chatTextMessage(role: "assistant", text: "before reset", timestamp: 1),
            ])
        let after = historyPayload(
            messages: [
                chatTextMessage(role: "assistant", text: "after reset", timestamp: 2),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [before, after])
        try await loadAndWaitBootstrap(vm: vm)
        try await waitUntil("initial history loaded") {
            await MainActor.run { vm.messages.first?.content.first?.text == "before reset" }
        }

        await MainActor.run {
            vm.input = "/new"
            vm.send()
        }

        try await waitUntil("reset called") {
            await transport.resetSessionKeys() == ["main"]
        }
        try await waitUntil("history reloaded") {
            await MainActor.run { vm.messages.first?.content.first?.text == "after reset" }
        }
        #expect(await transport.lastSentRunId() == nil)
    }

    @Test func compactTriggerCompactsSessionAndReloadsHistory() async throws {
        let before = historyPayload(
            messages: [
                chatTextMessage(role: "assistant", text: "before compact", timestamp: 1),
            ])
        let after = historyPayload(
            messages: [
                chatTextMessage(role: "assistant", text: "after compact", timestamp: 2),
            ])

        let (transport, vm) = await makeViewModel(historyResponses: [before, after])
        try await loadAndWaitBootstrap(vm: vm)
        try await waitUntil("initial history loaded") {
            await MainActor.run { vm.messages.first?.content.first?.text == "before compact" }
        }

        await MainActor.run {
            vm.input = "/compact"
            vm.send()
        }

        try await waitUntil("compact called") {
            await transport.compactSessionKeys() == ["main"]
        }
        try await waitUntil("history reloaded") {
            await MainActor.run { vm.messages.first?.content.first?.text == "after compact" }
        }
        #expect(await transport.lastSentRunId() == nil)
    }

    @Test func compactTriggerShowsGenericErrorMessageOnFailure() async throws {
        let history = historyPayload()
        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            compactSessionHook: { _ in
                throw NSError(
                    domain: "TestCompact",
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "backend details should not leak"])
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "/compact"
            vm.send()
        }

        try await waitUntil("compact attempted") {
            await transport.compactSessionKeys() == ["main"]
        }
        #expect(await MainActor.run { vm.errorText } == "Unable to compact the session. Please try again.")
    }

    @Test func compactTriggerIgnoresConcurrentAndImmediateRepeatRequests() async throws {
        let before = historyPayload(
            messages: [
                chatTextMessage(role: "assistant", text: "before compact", timestamp: 1),
            ])
        let after = historyPayload(
            messages: [
                chatTextMessage(role: "assistant", text: "after compact", timestamp: 2),
            ])
        let gate = AsyncGate()
        let (transport, vm) = await makeViewModel(
            historyResponses: [before, after],
            compactSessionHook: { _ in
                await gate.wait()
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "/compact"
            vm.send()
            vm.input = "/compact"
            vm.send()
        }

        try await waitUntil("single compact request issued") {
            await transport.compactSessionKeys() == ["main"]
        }
        #expect(await MainActor.run { vm.errorText } == nil)

        await gate.open()
        try await waitUntil("history reloaded after compact") {
            await MainActor.run { vm.messages.first?.content.first?.text == "after compact" }
        }

        await MainActor.run {
            vm.input = "/compact"
            vm.send()
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.compactSessionKeys() == ["main"])
        #expect(await MainActor.run { vm.errorText } == "Please wait before compacting this session again.")
    }

    @Test func compactTriggerAllowsImmediateRetryAfterFailure() async throws {
        let history = historyPayload()
        let attemptCount = AsyncCounter()
        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            compactSessionHook: { _ in
                let next = await attemptCount.increment()
                if next == 1 {
                    throw NSError(
                        domain: "TestCompact",
                        code: 42,
                        userInfo: [NSLocalizedDescriptionKey: "temporary failure"])
                }
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "/compact"
            vm.send()
        }

        try await waitUntil("first compact attempted") {
            await transport.compactSessionKeys() == ["main"]
        }
        #expect(await MainActor.run { vm.errorText } == "Unable to compact the session. Please try again.")

        await MainActor.run {
            vm.input = "/compact"
            vm.send()
        }

        try await waitUntil("second compact attempted") {
            await transport.compactSessionKeys() == ["main", "main"]
        }
        #expect(await MainActor.run { vm.errorText } == nil)
    }

    @Test func bootstrapsModelSelectionFromSessionAndDefaults() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: RemChatSessionsDefaults(model: "openai/gpt-4.1-mini", contextTokens: nil),
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: "anthropic/claude-opus-4-6"),
            ])
        let models = [
            modelChoice(id: "anthropic/claude-opus-4-6", name: "Claude Opus 4.6"),
            modelChoice(id: "openai/gpt-4.1-mini", name: "GPT-4.1 mini", provider: "openai"),
        ]

        let (_, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models])

        try await loadAndWaitBootstrap(vm: vm)

        #expect(await MainActor.run { vm.showsModelPicker })
        #expect(await MainActor.run { vm.modelSelectionID } == "anthropic/claude-opus-4-6")
        #expect(await MainActor.run { vm.defaultModelLabel } == "Default: openai/gpt-4.1-mini")
    }

    @Test(arguments: [false, true])
    func providerQualifiedSessionSelectionSurvivesEmptyOrFailedModelsList(fails: Bool) async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                sessionEntry(
                    key: "main",
                    updatedAt: now,
                    model: "claude-opus-4-6",
                    modelProvider: "anthropic"),
            ])
        let (_, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            sessionsResponses: [sessions],
            modelRequestHook: {
                if fails { throw NSError(domain: "models.list", code: 1) }
                return []
            })

        await MainActor.run { vm.load() }
        try await waitUntil("bootstrap finishes after models.list") {
            await MainActor.run { !vm.isLoading && vm.healthOK }
        }

        #expect(await MainActor.run { vm.modelChoices.isEmpty })
        #expect(await MainActor.run { vm.modelSelectionID } == "anthropic/claude-opus-4-6")
    }

    @Test func publishesModelCatalogCompletenessAndProvenanceFromTransport() async throws {
        let (_, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            modelResponses: [[modelChoice(id: "managed", name: "Managed", provider: "gmi")]],
            modelCatalogCompleteness: .incomplete,
            modelCatalogProvenance: "configured-fallback")

        try await loadAndWaitBootstrap(vm: vm)

        #expect(await MainActor.run { vm.modelCatalogCompleteness } == .incomplete)
        #expect(await MainActor.run { vm.modelCatalogProvenance } == "configured-fallback")
    }

    @Test func selectingDefaultModelPatchesNilAndUpdatesSelection() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: RemChatSessionsDefaults(model: "openai/gpt-4.1-mini", contextTokens: nil),
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: "anthropic/claude-opus-4-6"),
            ])
        let models = [
            modelChoice(id: "anthropic/claude-opus-4-6", name: "Claude Opus 4.6"),
            modelChoice(id: "openai/gpt-4.1-mini", name: "GPT-4.1 mini", provider: "openai"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models])

        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run { vm.selectModel(RemChatViewModel.defaultModelSelectionID) }

        try await waitUntil("session model patched") {
            let patched = await transport.patchedModels()
            return patched == [nil]
        }

        #expect(await MainActor.run { vm.modelSelectionID } == RemChatViewModel.defaultModelSelectionID)
    }

    @Test func authorizedSendResetsUnavailableSessionOverrideBeforeDispatch() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let beforeDispatchCount = AsyncCounter()
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            sessionsResponses: [
                RemChatSessionsListResponse(
                    ts: now,
                    path: nil,
                    count: 1,
                    defaults: nil,
                    sessions: [
                        sessionEntry(key: "main", updatedAt: now, model: "claude-opus-4-6", modelProvider: "anthropic"),
                    ])
            ],
            modelResponses: [[modelChoice(id: "claude-opus-4-6", name: "Claude Opus 4.6")]])
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "Use an available model"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
        }

        try await waitUntil("default patch and send complete") {
            let patchedModels = await transport.patchedModels()
            let sentRunID = await transport.lastSentRunId()
            return patchedModels == [nil] && sentRunID != nil
        }
        #expect(await beforeDispatchCount.current() == 1)
        #expect(await MainActor.run { vm.modelSelectionID } == RemChatViewModel.defaultModelSelectionID)
    }

    @Test func authorizedSendFailsClosedWhenDefaultResetFails() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let beforeDispatchCount = AsyncCounter()
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            sessionsResponses: [
                RemChatSessionsListResponse(
                    ts: now,
                    path: nil,
                    count: 1,
                    defaults: nil,
                    sessions: [
                        sessionEntry(key: "main", updatedAt: now, model: "claude-opus-4-6", modelProvider: "anthropic"),
                    ])
            ],
            modelResponses: [[modelChoice(id: "claude-opus-4-6", name: "Claude Opus 4.6")]],
            setSessionModelHook: { _ in
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "patch failed"])
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "Do not send with stale override"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
        }

        try await waitUntil("default patch fails") {
            await transport.patchedModels() == [nil]
        }
        try await waitUntil("authorized send preparation ends") {
            await MainActor.run { !vm.isPreparingSend }
        }
        #expect(await beforeDispatchCount.current() == 0)
        #expect(await transport.lastSentRunId() == nil)
        #expect(await MainActor.run { vm.input } == "Do not send with stale override")
        #expect(await MainActor.run { vm.modelSelectionID } == "anthropic/claude-opus-4-6")
    }

    @Test func authorizedResetCommandRunsBeforeUnavailableModelReconciliation() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let beforeDispatchCount = AsyncCounter()
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload(), historyPayload()],
            sessionsResponses: [
                RemChatSessionsListResponse(
                    ts: now,
                    path: nil,
                    count: 1,
                    defaults: nil,
                    sessions: [
                        sessionEntry(
                            key: "main",
                            updatedAt: now,
                            model: "claude-opus-4-6",
                            modelProvider: "anthropic"),
                    ])
            ],
            modelResponses: [[modelChoice(id: "claude-opus-4-6", name: "Claude Opus 4.6")]],
            setSessionModelHook: { _ in
                throw NSError(domain: "test", code: 1)
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "/reset"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
        }

        try await waitUntil("authorized reset command runs") {
            await transport.resetSessionKeys() == ["main"]
        }
        #expect(await transport.patchedModels().isEmpty)
        #expect(await beforeDispatchCount.current() == 0)
        #expect(await transport.lastSentRunId() == nil)
    }

    @Test func authorizedCompactCommandRunsBeforeUnavailableModelReconciliation() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let beforeDispatchCount = AsyncCounter()
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload(), historyPayload()],
            sessionsResponses: [
                RemChatSessionsListResponse(
                    ts: now,
                    path: nil,
                    count: 1,
                    defaults: nil,
                    sessions: [
                        sessionEntry(
                            key: "main",
                            updatedAt: now,
                            model: "claude-opus-4-6",
                            modelProvider: "anthropic"),
                    ])
            ],
            modelResponses: [[modelChoice(id: "claude-opus-4-6", name: "Claude Opus 4.6")]],
            setSessionModelHook: { _ in
                throw NSError(domain: "test", code: 1)
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "/compact"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
        }

        try await waitUntil("authorized compact command runs") {
            await transport.compactSessionKeys() == ["main"]
        }
        #expect(await transport.patchedModels().isEmpty)
        #expect(await beforeDispatchCount.current() == 0)
        #expect(await transport.lastSentRunId() == nil)
    }

    @Test func authorizedSendDoesNotChargeWhenAcceptedInFlightModelPatchFails() async throws {
        let modelPatchGate = AsyncGate()
        let modelPatchAttempts = AsyncCounter()
        let beforeDispatchCount = AsyncCounter()
        let openAIModel = modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai")
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            modelResponses: [[openAIModel]],
            setSessionModelHook: { _ in
                if await modelPatchAttempts.increment() == 1 {
                    await modelPatchGate.wait()
                }
                throw NSError(
                    domain: "test",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "patch failed"])
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run { vm.selectModel(openAIModel.selectionID) }
        try await waitUntil("accepted model patch starts") {
            await transport.patchedModels() == ["openai/gpt-5.4"]
        }
        await MainActor.run {
            #expect(vm.modelSelectionID == openAIModel.selectionID)
            vm.input = "do not charge fallback"
            vm.send(modelSelectionID: openAIModel.selectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
        }
        #expect(await MainActor.run { vm.isPreparingSend })
        #expect(await beforeDispatchCount.current() == 0)
        await modelPatchGate.open()

        try await waitUntil("failed accepted model repair settles") {
            await MainActor.run { !vm.isPreparingSend }
        }
        #expect(await transport.patchedModels() == ["openai/gpt-5.4", "openai/gpt-5.4"])
        #expect(await beforeDispatchCount.current() == 0)
        #expect(await transport.lastSentRunId() == nil)
        #expect(await MainActor.run { vm.input } == "do not charge fallback")
        #expect(await MainActor.run {
            vm.modelSelectionID == RemChatViewModel.defaultModelSelectionID
        })
    }

    @Test func authorizedSendRejectsDuplicatePreDispatchWorkWhileModelRepairIsInFlight() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let beforeDispatchCount = AsyncCounter()
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            sessionsResponses: [
                RemChatSessionsListResponse(
                    ts: now,
                    path: nil,
                    count: 1,
                    defaults: nil,
                    sessions: [
                        sessionEntry(
                            key: "main",
                            updatedAt: now,
                            model: "claude-opus-4-6",
                            modelProvider: "anthropic"),
                    ])
            ],
            modelResponses: [[modelChoice(id: "claude-opus-4-6", name: "Claude Opus 4.6")]],
            setSessionModelHook: { _ in
                try await Task.sleep(for: .milliseconds(150))
            })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "Charge once"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
            #expect(vm.isPreparingSend)
            #expect(!vm.canSend)
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
        }

        try await waitUntil("single repair and send complete") {
            let patchedModels = await transport.patchedModels()
            let sentRunID = await transport.lastSentRunId()
            return patchedModels == [nil] && sentRunID != nil
        }
        #expect(await beforeDispatchCount.current() == 1)
    }

    @Test func authorizedSendQueuesNavigationUntilDeniedPreDispatchWorkSettles() async throws {
        let gate = AsyncGate()
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload(sessionKey: "main"), historyPayload(sessionKey: "other")])
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "Keep this draft on main"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                await gate.wait()
                return false
            }
        }
        try await waitUntil("pre-dispatch work starts") {
            await MainActor.run { vm.isPreparingSend }
        }

        await MainActor.run { vm.switchSession(to: "other") }
        #expect(await MainActor.run { vm.sessionKey } == "main")
        await gate.open()

        try await waitUntil("denied send settles on requested destination") {
            await MainActor.run { vm.sessionKey == "other" && !vm.isLoading && !vm.isPreparingSend }
        }
        #expect(await transport.lastSentRunId() == nil)
        #expect(await MainActor.run { vm.input.isEmpty })
        await MainActor.run { vm.switchSession(to: "main") }
        #expect(await MainActor.run { vm.input } == "Keep this draft on main")
    }

    @Test func authorizedSendUsesSynchronousPayloadSnapshotAndPreservesLaterDraftEdits() async throws {
        let preDispatchStarted = AsyncGate()
        let allowDispatch = AsyncGate()
        let (transport, vm) = await makeViewModel(historyResponses: [historyPayload()])
        try await loadAndWaitBootstrap(vm: vm)
        let originalAttachment = RemPendingAttachment(
            url: nil,
            data: Data("old".utf8),
            fileName: "old.txt",
            mimeType: "text/plain",
            preview: nil)
        let replacementAttachment = RemPendingAttachment(
            url: nil,
            data: Data("new".utf8),
            fileName: "new.txt",
            mimeType: "text/plain",
            preview: nil)

        await MainActor.run {
            vm.input = "original draft"
            vm.attachments = [originalAttachment]
            vm.send(
                modelSelectionID: RemChatViewModel.defaultModelSelectionID,
                message: "wrapped original draft",
                attachments: [originalAttachment]
            ) {
                await preDispatchStarted.open()
                await allowDispatch.wait()
                return true
            }
        }
        await preDispatchStarted.wait()
        await MainActor.run {
            vm.input = "replacement draft"
            vm.attachments = [replacementAttachment]
        }
        await allowDispatch.open()

        try await waitUntil("snapshotted send completes") {
            await transport.lastSentRunId() != nil
        }
        #expect(await transport.sentMessages() == ["wrapped original draft"])
        #expect(await transport.sentAttachmentFileNames() == [["old.txt"]])
        #expect(await MainActor.run { vm.input } == "replacement draft")
        #expect(await MainActor.run { vm.attachments.map(\.fileName) } == ["new.txt"])
    }

    @Test func authorizedSendDoesNotClearDraftEditedAwayAndBackToSameText() async throws {
        let preDispatchStarted = AsyncGate()
        let allowDispatch = AsyncGate()
        let (transport, vm) = await makeViewModel(historyResponses: [historyPayload()])
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "same visible draft"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                await preDispatchStarted.open()
                await allowDispatch.wait()
                return true
            }
        }
        await preDispatchStarted.wait()
        await MainActor.run {
            vm.input = "temporary edit"
            vm.input = "same visible draft"
        }
        await allowDispatch.open()

        try await waitUntil("snapshotted send completes") {
            await transport.lastSentRunId() != nil
        }
        #expect(await transport.sentMessages() == ["same visible draft"])
        #expect(await MainActor.run { vm.input } == "same visible draft")
    }

    @Test func failedAuthorizedSendDoesNotRestoreDraftAfterUserClearsComposer() async throws {
        let gate = AsyncGate()
        struct ExpectedFailure: Error {}
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            },
            sendMessageHook: { _ in throw ExpectedFailure() })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "do not resurrect"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID)
        }
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run {
            vm.input = "changed my mind"
            vm.input = ""
        }
        await gate.open()

        try await waitUntil("failed send settles") {
            await MainActor.run { !vm.isSending && !vm.isPreparingSend }
        }
        #expect(await MainActor.run { vm.input.isEmpty })
    }

    @Test func authorizedSendLocksModelAndThinkingUntilDispatchIsAccepted() async throws {
        let preDispatchStarted = AsyncGate()
        let allowDispatch = AsyncGate()
        let openAIModel = modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai")
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            modelResponses: [[openAIModel]])
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "use accepted controls"
            // These picker tasks are queued immediately before Send claims the turn. Their public
            // synchronous guard passes, so the actor-side guard must still reject them later.
            vm.selectModel(openAIModel.selectionID)
            vm.selectThinkingLevel("high")
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                await preDispatchStarted.open()
                await allowDispatch.wait()
                return true
            }
        }
        await preDispatchStarted.wait()
        await MainActor.run {
            vm.selectModel(openAIModel.selectionID)
            vm.selectThinkingLevel("high")
        }

        #expect(await MainActor.run {
            vm.modelSelectionID == RemChatViewModel.defaultModelSelectionID &&
                vm.thinkingLevel == "off"
        })
        #expect(await transport.patchedModels().isEmpty)
        #expect(await transport.patchedThinkingLevels().isEmpty)
        await allowDispatch.open()

        try await waitUntil("send with accepted controls completes") {
            await transport.lastSentRunId() != nil
        }
        #expect(await transport.sentThinkingLevels() == ["off"])
    }

    @Test func authorizedSendDoesNotConsumePreDispatchWorkWhenHealthRejectsPayload() async throws {
        let beforeDispatchCount = AsyncCounter()
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            requestHealthHook: { false })
        await MainActor.run { vm.load() }
        try await waitUntil("unhealthy bootstrap completes") {
            let historyLoaded = await transport.historyCallCount() == 1
            let loadingFinished = await MainActor.run { !vm.isLoading }
            return historyLoaded && loadingFinished
        }

        await MainActor.run {
            vm.input = "Keep this uncharged"
            vm.send(modelSelectionID: RemChatViewModel.defaultModelSelectionID) {
                _ = await beforeDispatchCount.increment()
                return true
            }
        }
        try await waitUntil("health-rejected send preparation ends") {
            await MainActor.run { !vm.isPreparingSend }
        }
        #expect(await beforeDispatchCount.current() == 0)
        #expect(await MainActor.run { vm.input } == "Keep this uncharged")
    }

    @Test func selectingProviderQualifiedModelDisambiguatesDuplicateModelIDs() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: RemChatSessionsDefaults(model: "openrouter/gpt-4.1-mini", contextTokens: nil),
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: "gpt-4.1-mini", modelProvider: "openrouter"),
            ])
        let models = [
            modelChoice(id: "gpt-4.1-mini", name: "GPT-4.1 mini", provider: "openai"),
            modelChoice(id: "gpt-4.1-mini", name: "GPT-4.1 mini", provider: "openrouter"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models])

        try await loadAndWaitBootstrap(vm: vm)

        #expect(await MainActor.run { vm.modelSelectionID } == "openrouter/gpt-4.1-mini")

        await MainActor.run { vm.selectModel("openai/gpt-4.1-mini") }

        try await waitUntil("provider-qualified model patched") {
            let patched = await transport.patchedModels()
            return patched == ["openai/gpt-4.1-mini"]
        }
    }

    @Test func slashModelIDsStayProviderQualifiedInSelectionAndPatch() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
            ])
        let models = [
            modelChoice(
                id: "openai/gpt-5.4",
                name: "GPT-5.4 via Vercel AI Gateway",
                provider: "vercel-ai-gateway"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models])

        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run { vm.selectModel("vercel-ai-gateway/openai/gpt-5.4") }

        try await waitUntil("slash model patched with provider-qualified ref") {
            let patched = await transport.patchedModels()
            return patched == ["vercel-ai-gateway/openai/gpt-5.4"]
        }
    }

    @Test func staleModelPatchCompletionsDoNotOverwriteNewerSelection() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
            ])
        let models = [
            modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai"),
            modelChoice(id: "gpt-5.4-pro", name: "GPT-5.4 Pro", provider: "openai"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models],
            setSessionModelHook: { model in
                if model == "openai/gpt-5.4" {
                    try await Task.sleep(for: .milliseconds(200))
                }
            })

        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.selectModel("openai/gpt-5.4")
            vm.selectModel("openai/gpt-5.4-pro")
        }

        try await waitUntil("two model patches complete", timeoutSeconds: 6) {
            let patched = await transport.patchedModels()
            return patched == ["openai/gpt-5.4", "openai/gpt-5.4-pro"]
        }

        #expect(await MainActor.run { vm.modelSelectionID } == "openai/gpt-5.4-pro")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "main" })?.model } == "gpt-5.4-pro")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "main" })?.modelProvider } == "openai")
    }

    @Test func sendWaitsForInFlightModelPatchToFinish() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
            ])
        let models = [
            modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai"),
        ]
        let gate = AsyncGate()

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models],
            setSessionModelHook: { model in
                if model == "openai/gpt-5.4" {
                    await gate.wait()
                }
            })

        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run { vm.selectModel("openai/gpt-5.4") }
        try await waitUntil("model patch started") {
            let patched = await transport.patchedModels()
            return patched == ["openai/gpt-5.4"]
        }

        await sendUserMessage(vm, text: "hello")
        try await waitUntil("send entered waiting state") {
            await MainActor.run { vm.isSending }
        }
        #expect(await transport.lastSentRunId() == nil)
        try await waitUntil("preparation reaches model patch wait") {
            await transport.sendPreparationPhases() == [
                .started,
                .optimisticAppendCompleted,
                .modelPatchWaitStarted,
            ]
        }
        #expect(await transport.sendPreparationPhases() == [
            .started,
            .optimisticAppendCompleted,
            .modelPatchWaitStarted,
        ])

        await MainActor.run { vm.selectThinkingLevel("high") }
        #expect(await MainActor.run { vm.thinkingLevel } == "off")
        #expect(await transport.patchedThinkingLevels().isEmpty)

        await gate.open()

        try await waitUntil("send released after model patch") {
            await transport.lastSentRunId() != nil
        }
        #expect(await transport.sendPreparationPhases() == [
            .started,
            .optimisticAppendCompleted,
            .modelPatchWaitStarted,
            .modelPatchWaitEnded,
        ])
        #expect(await transport.sentThinkingLevels() == ["off"])
    }

    @Test func preparationObserverCannotEraseDraftTypedAfterSend() async throws {
        let gate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "first")
        try await waitUntil("preparation observer starts") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run { vm.input = "next draft" }
        await gate.open()

        try await waitUntil("send completes") { await transport.lastSentRunId() != nil }
        #expect(await MainActor.run { vm.input } == "next draft")
    }

    @Test func optimisticAppendIsVisibleBeforePreparationObserverSuspends() async throws {
        let startedGate = AsyncGate()
        let completedGate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sendPreparationHook: { phase in
                if phase == .started { await startedGate.wait() }
                if phase == .optimisticAppendCompleted { await completedGate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "measure me")
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        #expect(await MainActor.run { vm.input.isEmpty })
        #expect(await MainActor.run { vm.messages.contains { $0.role == "user" } })

        await startedGate.open()
        try await waitUntil("send reaches optimistic append marker") {
            await transport.sendPreparationPhases() == [.started, .optimisticAppendCompleted]
        }
        #expect(await MainActor.run { vm.messages.contains { $0.role == "user" } })

        await completedGate.open()
        try await waitUntil("send completes") { await transport.lastSentRunId() != nil }
    }

    @Test func switchingSessionDuringPreparationFinishesOldSendWithoutLeakingMessage() async throws {
        let gate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload(sessionKey: "main"), historyPayload(sessionKey: "other")],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "private to main")
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run { vm.switchSession(to: "other") }
        #expect(await MainActor.run { vm.sessionKey } == "main")
        await gate.open()

        try await waitUntil("old send completes while other session loads") {
            await MainActor.run { vm.sessionKey == "other" && !vm.isLoading && !vm.isSending }
        }
        #expect(await transport.lastSentRunId() != nil)
        #expect(await MainActor.run { vm.messages.allSatisfy { message in
            !message.content.contains { $0.text == "private to main" }
        } })
    }

    @Test func latestSessionTapCancelsQueuedNavigationBackToSource() async throws {
        let gate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload(sessionKey: "main")],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "stay on main")
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run {
            vm.switchSession(to: "other")
            vm.switchSession(to: "main")
        }
        await gate.open()

        try await waitUntil("send settles on source") {
            await MainActor.run { vm.sessionKey == "main" && !vm.isSending }
        }
        #expect(await transport.historyCallCount() == 1)
    }

    @Test func agentEventsAreIgnoredWhileDestinationSessionIdentityIsLoading() async throws {
        let destinationGate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [],
            historyRequestHook: { sessionKey in
                if sessionKey == "other" { await destinationGate.wait() }
                return historyPayload(sessionKey: sessionKey, sessionId: "session-\(sessionKey)")
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm, sessionId: "session-main")

        await MainActor.run { vm.switchSession(to: "other") }
        try await waitUntil("destination bootstrap clears session identity") {
            await MainActor.run { vm.sessionKey == "other" && vm.isLoading && vm.sessionId == nil }
        }
        transport.emit(
            .agent(
                RemAgentEventPayload(
                    runId: "session-main",
                    seq: 1,
                    stream: "assistant",
                    ts: Int(Date().timeIntervalSince1970 * 1000),
                    data: ["text": AnyCodable("private old reply")])))
        try await Task.sleep(for: .milliseconds(20))

        #expect(await MainActor.run { vm.streamingAssistantText } == nil)
        #expect(await MainActor.run { vm.pendingToolCalls.isEmpty })

        await destinationGate.open()
        try await waitUntil("destination loads") { await MainActor.run { !vm.isLoading } }
    }

    @Test func firstAgentEventBindsFreshSessionAndStreamsActivity() async throws {
        let freshSessionID = "fresh-session-id"
        let transport = TestChatTransport(
            historyResponses: [historyPayload(sessionKey: "chat-new", sessionId: nil)])
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "chat-new", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)
        #expect(await MainActor.run { vm.sessionId == nil })

        await sendUserMessage(vm, text: "hello from a new chat")
        try await waitUntil("fresh send is pending") {
            await MainActor.run { vm.pendingRunCount == 1 && !vm.isSending }
        }
        emitAssistantText(transport: transport, runId: freshSessionID, text: "streaming fresh reply")
        emitToolStart(transport: transport, runId: freshSessionID)

        try await waitUntil("fresh activity appears") {
            await MainActor.run {
                vm.sessionId == freshSessionID &&
                    vm.streamingAssistantText == "streaming fresh reply" &&
                    vm.pendingToolCalls.count == 1
            }
        }
    }

    @Test func failedSendStillAppliesQueuedNavigationAndKeepsDraftWithSourceSession() async throws {
        let gate = AsyncGate()
        struct ExpectedFailure: Error {}
        let transport = TestChatTransport(
            historyResponses: [historyPayload(sessionKey: "main"), historyPayload(sessionKey: "other")],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            },
            sendMessageHook: { _ in throw ExpectedFailure() })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "retry on main")
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run { vm.switchSession(to: "other") }
        await gate.open()

        try await waitUntil("failed send settles on requested destination") {
            await MainActor.run { vm.sessionKey == "other" && !vm.isSending }
        }
        #expect(await MainActor.run { vm.input.isEmpty })
        await MainActor.run { vm.switchSession(to: "main") }
        #expect(await MainActor.run { vm.input } == "retry on main")
    }

    @Test func abortedSendStillAppliesQueuedNavigationAndKeepsDraftWithSourceSession() async throws {
        let gate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload(sessionKey: "main"), historyPayload(sessionKey: "other")],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "cancelled on main")
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run {
            vm.switchSession(to: "other")
            vm.abort()
        }
        try await waitUntil("abort requested") { await transport.abortedRunIds().count == 1 }
        await gate.open()

        try await waitUntil("aborted send settles on requested destination") {
            await MainActor.run { vm.sessionKey == "other" && !vm.isSending }
        }
        #expect(await MainActor.run { vm.input.isEmpty })
        await MainActor.run { vm.switchSession(to: "main") }
        #expect(await MainActor.run { vm.input } == "cancelled on main")
    }

    @Test func abortWhilePreparationObserverIsSuspendedNeverSends() async throws {
        let gate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "cancel me")
        try await waitUntil("preparation observer starts") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run { vm.abort() }
        try await waitUntil("preparing run abort requested") {
            await transport.abortedRunIds().count == 1
        }
        #expect(await MainActor.run { vm.pendingRunCount } == 0)

        await gate.open()
        try await waitUntil("cancelled preparation settles") {
            await MainActor.run { !vm.isSending }
        }
        #expect(await transport.lastSentRunId() == nil)
    }

    @Test func cancellationDoesNotMixOldAttachmentIntoNewTextDraft() async throws {
        let gate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.input = "old text"
            vm.attachments = [
                RemPendingAttachment(
                    url: nil,
                    data: Data([0x01]),
                    fileName: "old-private.txt",
                    mimeType: "text/plain",
                    preview: nil),
            ]
            vm.send()
        }
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run {
            vm.input = "new draft"
            vm.abort()
        }
        try await waitUntil("abort requested") { await transport.abortedRunIds().count == 1 }
        await gate.open()
        try await waitUntil("cancelled send settles") { await MainActor.run { !vm.isSending } }

        #expect(await MainActor.run { vm.input } == "new draft")
        #expect(await MainActor.run { vm.attachments.isEmpty })
    }

    @Test func cancellationDoesNotMixOldTextIntoNewAttachmentDraft() async throws {
        let gate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sendPreparationHook: { phase in
                if phase == .started { await gate.wait() }
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "old text")
        try await waitUntil("send reaches start marker") {
            await transport.sendPreparationPhases() == [.started]
        }
        await MainActor.run {
            vm.attachments = [
                RemPendingAttachment(
                    url: nil,
                    data: Data([0x02]),
                    fileName: "new-only.txt",
                    mimeType: "text/plain",
                    preview: nil),
            ]
            vm.abort()
        }
        try await waitUntil("abort requested") { await transport.abortedRunIds().count == 1 }
        await gate.open()
        try await waitUntil("cancelled send settles") { await MainActor.run { !vm.isSending } }

        #expect(await MainActor.run { vm.input.isEmpty })
        #expect(await MainActor.run { vm.attachments.map(\.fileName) } == ["new-only.txt"])
    }

    @Test func abortWhileWaitingForModelPatchSettlesWithoutSending() async throws {
        let modelGate = AsyncGate()
        let now = Date().timeIntervalSince1970 * 1000
        let (transport, vm) = await makeViewModel(
            historyResponses: [historyPayload()],
            sessionsResponses: [
                RemChatSessionsListResponse(
                    ts: now,
                    path: nil,
                    count: 1,
                    defaults: nil,
                    sessions: [sessionEntry(key: "main", updatedAt: now, model: nil)]),
            ],
            modelResponses: [
                [modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai")],
            ],
            setSessionModelHook: { _ in await modelGate.wait() })
        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run { vm.selectModel("openai/gpt-5.4") }
        try await waitUntil("model patch starts") { await transport.patchedModels().count == 1 }
        await sendUserMessage(vm, text: "cancel model wait")
        try await waitUntil("send waits for model patch") {
            await transport.sendPreparationPhases().contains(.modelPatchWaitStarted)
        }

        await MainActor.run { vm.abort() }
        try await waitUntil("cancelled model wait settles") {
            await MainActor.run { !vm.isSending && vm.pendingRunCount == 0 }
        }
        #expect(await transport.lastSentRunId() == nil)
        #expect(await MainActor.run { vm.messages.allSatisfy { $0.role != "user" } })
        #expect(await MainActor.run { vm.input } == "cancel model wait")
        await modelGate.open()
    }

    @Test func failedLatestModelSelectionDoesNotReplayAfterOlderCompletionFinishes() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
            ])
        let models = [
            modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai"),
            modelChoice(id: "gpt-5.4-pro", name: "GPT-5.4 Pro", provider: "openai"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models],
            setSessionModelHook: { model in
                if model == "openai/gpt-5.4" {
                    try await Task.sleep(for: .milliseconds(200))
                    return
                }
                if model == "openai/gpt-5.4-pro" {
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
                }
            })

        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.selectModel("openai/gpt-5.4")
            vm.selectModel("openai/gpt-5.4-pro")
        }

        try await waitUntil("older model completion wins after latest failure") {
            await MainActor.run {
                vm.sessions.first(where: { $0.key == "main" })?.model == "gpt-5.4" &&
                    vm.sessions.first(where: { $0.key == "main" })?.modelProvider == "openai"
            }
        }

        #expect(await MainActor.run { vm.modelSelectionID } == "openai/gpt-5.4")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "main" })?.model } == "gpt-5.4")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "main" })?.modelProvider } == "openai")
        #expect(await transport.patchedModels() == ["openai/gpt-5.4", "openai/gpt-5.4-pro"])
    }

    @Test func failedLatestModelSelectionRestoresEarlierSuccessWithoutReplay() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let history = historyPayload()
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
            ])
        let models = [
            modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai"),
            modelChoice(id: "gpt-5.4-pro", name: "GPT-5.4 Pro", provider: "openai"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions],
            modelResponses: [models],
            setSessionModelHook: { model in
                if model == "openai/gpt-5.4" {
                    try await Task.sleep(for: .milliseconds(100))
                    return
                }
                if model == "openai/gpt-5.4-pro" {
                    try await Task.sleep(for: .milliseconds(200))
                    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
                }
            })

        try await loadAndWaitBootstrap(vm: vm)

        await MainActor.run {
            vm.selectModel("openai/gpt-5.4")
            vm.selectModel("openai/gpt-5.4-pro")
        }

        try await waitUntil("latest failure restores prior successful model") {
            await MainActor.run {
                vm.modelSelectionID == "openai/gpt-5.4" &&
                    vm.sessions.first(where: { $0.key == "main" })?.model == "gpt-5.4" &&
                    vm.sessions.first(where: { $0.key == "main" })?.modelProvider == "openai"
            }
        }

        #expect(await transport.patchedModels() == ["openai/gpt-5.4", "openai/gpt-5.4-pro"])
    }

    @Test func switchingSessionsIgnoresLateModelPatchCompletionFromPreviousSession() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let sessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 2,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
                sessionEntry(key: "other", updatedAt: now - 1000, model: nil),
            ])
        let models = [
            modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [
                historyPayload(sessionKey: "main", sessionId: "sess-main"),
                historyPayload(sessionKey: "other", sessionId: "sess-other"),
            ],
            sessionsResponses: [sessions, sessions],
            modelResponses: [models, models],
            setSessionModelHook: { model in
                if model == "openai/gpt-5.4" {
                    try await Task.sleep(for: .milliseconds(200))
                }
            })

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")

        await MainActor.run { vm.selectModel("openai/gpt-5.4") }
        await MainActor.run { vm.switchSession(to: "other") }

        try await waitUntil("switched sessions") {
            await MainActor.run { vm.sessionKey == "other" && vm.sessionId == "sess-other" }
        }
        try await waitUntil("late model patch finished") {
            let patched = await transport.patchedModels()
            return patched == ["openai/gpt-5.4"]
        }

        #expect(await MainActor.run { vm.modelSelectionID } == RemChatViewModel.defaultModelSelectionID)
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "other" })?.model } == nil)
    }

    @Test func lateModelCompletionDoesNotReplayCurrentSessionSelectionIntoPreviousSession() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let initialSessions = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 2,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
                sessionEntry(key: "other", updatedAt: now - 1000, model: nil),
            ])
        let sessionsAfterOtherSelection = RemChatSessionsListResponse(
            ts: now,
            path: nil,
            count: 2,
            defaults: nil,
            sessions: [
                sessionEntry(key: "main", updatedAt: now, model: nil),
                sessionEntry(key: "other", updatedAt: now - 1000, model: "openai/gpt-5.4-pro"),
            ])
        let models = [
            modelChoice(id: "gpt-5.4", name: "GPT-5.4", provider: "openai"),
            modelChoice(id: "gpt-5.4-pro", name: "GPT-5.4 Pro", provider: "openai"),
        ]

        let (transport, vm) = await makeViewModel(
            historyResponses: [
                historyPayload(sessionKey: "main", sessionId: "sess-main"),
                historyPayload(sessionKey: "other", sessionId: "sess-other"),
                historyPayload(sessionKey: "main", sessionId: "sess-main"),
            ],
            sessionsResponses: [initialSessions, initialSessions, sessionsAfterOtherSelection],
            modelResponses: [models, models, models],
            setSessionModelHook: { model in
                if model == "openai/gpt-5.4" {
                    try await Task.sleep(for: .milliseconds(200))
                }
            })

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")

        await MainActor.run { vm.selectModel("openai/gpt-5.4") }
        await MainActor.run { vm.switchSession(to: "other") }
        try await waitUntil("switched to other session") {
            await MainActor.run { vm.sessionKey == "other" && vm.sessionId == "sess-other" }
        }

        await MainActor.run { vm.selectModel("openai/gpt-5.4-pro") }
        try await waitUntil("both model patches issued") {
            let patched = await transport.patchedModels()
            return patched == ["openai/gpt-5.4", "openai/gpt-5.4-pro"]
        }
        await MainActor.run { vm.switchSession(to: "main") }
        try await waitUntil("switched back to main session") {
            await MainActor.run { vm.sessionKey == "main" && vm.sessionId == "sess-main" }
        }

        try await waitUntil("late model completion updates only the original session") {
            await MainActor.run {
                vm.sessions.first(where: { $0.key == "main" })?.model == "gpt-5.4" &&
                    vm.sessions.first(where: { $0.key == "main" })?.modelProvider == "openai"
            }
        }

        #expect(await MainActor.run { vm.modelSelectionID } == "openai/gpt-5.4")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "main" })?.model } == "gpt-5.4")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "main" })?.modelProvider } == "openai")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "other" })?.model } == "openai/gpt-5.4-pro")
        #expect(await MainActor.run { vm.sessions.first(where: { $0.key == "other" })?.modelProvider } == nil)
        #expect(await transport.patchedModels() == ["openai/gpt-5.4", "openai/gpt-5.4-pro"])
    }

    @Test func explicitThinkingLevelWinsOverHistoryAndPersistsChanges() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [],
            thinkingLevel: "off")
        let callbackState = await MainActor.run { CallbackBox() }

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            initialThinkingLevel: "high",
            onThinkingLevelChanged: { level in
                callbackState.values.append(level)
            })

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")
        #expect(await MainActor.run { vm.thinkingLevel } == "high")

        await MainActor.run { vm.selectThinkingLevel("medium") }

        try await waitUntil("thinking level patched") {
            let patched = await transport.patchedThinkingLevels()
            return patched == ["medium"]
        }

        #expect(await MainActor.run { vm.thinkingLevel } == "medium")
        #expect(await MainActor.run { callbackState.values } == ["medium"])
    }

    @Test func serverProvidedThinkingLevelsOutsideMenuArePreservedForSend() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [],
            thinkingLevel: "xhigh")

        let (transport, vm) = await makeViewModel(historyResponses: [history])

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")
        #expect(await MainActor.run { vm.thinkingLevel } == "xhigh")

        await sendUserMessage(vm, text: "hello")
        try await waitUntil("send uses preserved thinking level") {
            await transport.sentThinkingLevels() == ["xhigh"]
        }
    }

    @Test func decodesGatewayThinkingMetadataFromSessionList() throws {
        let json = """
        {
          "defaults": {
            "modelProvider": "anthropic",
            "model": "claude-opus-4-7",
            "thinkingLevels": [
              { "id": "off", "label": "off" },
              { "id": "adaptive", "label": "adaptive" },
              { "id": "max", "label": "maximum" }
            ],
            "thinkingOptions": ["off", "adaptive", "maximum"],
            "thinkingDefault": "adaptive"
          },
          "sessions": [
            {
              "key": "main",
              "modelProvider": "openrouter",
              "model": "deepseek/deepseek-v4",
              "thinkingLevel": "max",
              "thinkingLevels": [
                { "id": "off", "label": "off" },
                { "id": "xhigh", "label": "xhigh" },
                { "id": "max", "label": "max" }
              ],
              "thinkingOptions": ["off", "xhigh", "max"],
              "thinkingDefault": "max"
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(
            RemChatSessionsListResponse.self,
            from: Data(json.utf8))

        #expect(decoded.defaults?.modelProvider == "anthropic")
        #expect(decoded.defaults?.thinkingLevels?.map(\.id) == ["off", "adaptive", "max"])
        #expect(decoded.defaults?.thinkingLevels?.last?.label == "maximum")
        #expect(decoded.defaults?.thinkingDefault == "adaptive")
        #expect(decoded.sessions.first?.thinkingLevels?.map(\.id) == ["off", "xhigh", "max"])
        #expect(decoded.sessions.first?.thinkingDefault == "max")
    }

    @Test func sessionThinkingLevelsDrivePickerOptions() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [],
            thinkingLevel: "adaptive")
        let sessions = RemChatSessionsListResponse(
            ts: 1,
            path: nil,
            count: 1,
            defaults: RemChatSessionsDefaults(
                modelProvider: "openai-codex",
                model: "gpt-5.5",
                contextTokens: nil,
                thinkingLevels: [
                    thinkingOption("off"),
                    thinkingOption("low"),
                    thinkingOption("xhigh"),
                    thinkingOption("max", label: "maximum"),
                ],
                thinkingOptions: ["off", "low", "xhigh", "maximum"],
                thinkingDefault: "xhigh"),
            sessions: [
                RemChatSessionEntry(
                    key: "main",
                    kind: nil,
                    displayName: nil,
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: 1,
                    sessionId: "sess-main",
                    systemSent: nil,
                    abortedLastRun: nil,
                    thinkingLevel: "adaptive",
                    verboseLevel: nil,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    modelProvider: "anthropic",
                    model: "claude-opus-4-7",
                    contextTokens: nil,
                    thinkingLevels: [
                        thinkingOption("off"),
                        thinkingOption("adaptive"),
                        thinkingOption("max", label: "maximum"),
                    ],
                    thinkingOptions: ["off", "adaptive", "maximum"],
                    thinkingDefault: "adaptive"),
            ])

        let (_, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions])

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")

        #expect(await MainActor.run { vm.thinkingLevel } == "adaptive")
        #expect(await MainActor.run { vm.thinkingLevelOptions.map(\.id) } == ["off", "adaptive", "max"])
        #expect(await MainActor.run { vm.thinkingLevelOptions.map(\.label) } == ["off", "adaptive", "maximum"])
    }

    @Test func thinkingOptionsFallbackAndCurrentUnsupportedLevelStayVisible() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [],
            thinkingLevel: "xhigh")
        let sessions = RemChatSessionsListResponse(
            ts: 1,
            path: nil,
            count: 1,
            defaults: nil,
            sessions: [
                RemChatSessionEntry(
                    key: "main",
                    kind: nil,
                    displayName: nil,
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: 1,
                    sessionId: "sess-main",
                    systemSent: nil,
                    abortedLastRun: nil,
                    thinkingLevel: "xhigh",
                    verboseLevel: nil,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    modelProvider: "openrouter",
                    model: "deepseek/deepseek-v4",
                    contextTokens: nil,
                    thinkingLevels: nil,
                    thinkingOptions: ["off", "max"],
                    thinkingDefault: "max"),
            ])

        let (_, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions])

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")

        #expect(await MainActor.run { vm.thinkingLevel } == "xhigh")
        #expect(await MainActor.run { vm.thinkingLevelOptions.map(\.id) } == ["off", "max", "xhigh"])
        #expect(await MainActor.run { vm.thinkingLevelOptions.map(\.label) } == ["off", "max", "xhigh"])
    }

    @Test func matchingDefaultThinkingLevelsBeatLegacyRowThinkingOptions() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [],
            thinkingLevel: "adaptive")
        let sessions = RemChatSessionsListResponse(
            ts: 1,
            path: nil,
            count: 1,
            defaults: RemChatSessionsDefaults(
                modelProvider: "anthropic",
                model: "claude-opus-4-7",
                contextTokens: nil,
                thinkingLevels: [
                    thinkingOption("off"),
                    thinkingOption("adaptive"),
                    thinkingOption("max"),
                ],
                thinkingOptions: ["off", "adaptive", "max"],
                thinkingDefault: "adaptive"),
            sessions: [
                RemChatSessionEntry(
                    key: "main",
                    kind: nil,
                    displayName: nil,
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: 1,
                    sessionId: "sess-main",
                    systemSent: nil,
                    abortedLastRun: nil,
                    thinkingLevel: "adaptive",
                    verboseLevel: nil,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    modelProvider: "anthropic",
                    model: "claude-opus-4-7",
                    contextTokens: nil,
                    thinkingLevels: nil,
                    thinkingOptions: ["off"],
                    thinkingDefault: "off"),
            ])

        let (_, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions])

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")

        #expect(await MainActor.run { vm.thinkingLevelOptions.map(\.id) } == ["off", "adaptive", "max"])
    }

    @Test func defaultThinkingLevelsDoNotLeakToDifferentSessionModel() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [],
            thinkingLevel: "max")
        let sessions = RemChatSessionsListResponse(
            ts: 1,
            path: nil,
            count: 1,
            defaults: RemChatSessionsDefaults(
                modelProvider: "anthropic",
                model: "claude-opus-4-7",
                contextTokens: nil,
                thinkingLevels: [
                    thinkingOption("off"),
                    thinkingOption("adaptive"),
                    thinkingOption("max"),
                ],
                thinkingOptions: ["off", "adaptive", "max"],
                thinkingDefault: "adaptive"),
            sessions: [
                RemChatSessionEntry(
                    key: "main",
                    kind: nil,
                    displayName: nil,
                    surface: nil,
                    subject: nil,
                    room: nil,
                    space: nil,
                    updatedAt: 1,
                    sessionId: "sess-main",
                    systemSent: nil,
                    abortedLastRun: nil,
                    thinkingLevel: "max",
                    verboseLevel: nil,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    modelProvider: "openai",
                    model: "gpt-5.4",
                    contextTokens: nil),
            ])

        let (_, vm) = await makeViewModel(
            historyResponses: [history],
            sessionsResponses: [sessions])

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")

        #expect(await MainActor.run { vm.thinkingLevel } == "max")
        #expect(await MainActor.run { vm.thinkingLevelOptions.map(\.id) } ==
            ["off", "minimal", "low", "medium", "high", "max"])
    }

    @Test func staleThinkingPatchCompletionReappliesLatestSelection() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [],
            thinkingLevel: "off")

        let (transport, vm) = await makeViewModel(
            historyResponses: [history],
            setSessionThinkingHook: { level in
                if level == "medium" {
                    try await Task.sleep(for: .milliseconds(200))
                }
            })

        try await loadAndWaitBootstrap(vm: vm, sessionId: "sess-main")

        await MainActor.run {
            vm.selectThinkingLevel("medium")
            vm.selectThinkingLevel("high")
        }

        try await waitUntil("thinking patch replayed latest selection") {
            let patched = await transport.patchedThinkingLevels()
            return patched == ["medium", "high", "high"]
        }

        #expect(await MainActor.run { vm.thinkingLevel } == "high")
    }

    @Test func clearsStreamingOnExternalErrorEvent() async throws {
        let sessionId = "sess-main"
        let history = historyPayload(sessionId: sessionId)
        let (transport, vm) = await makeViewModel(historyResponses: [history, history])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)

        emitAssistantText(transport: transport, runId: sessionId, text: "external stream")

        try await waitUntil("streaming active") {
            await MainActor.run { vm.streamingAssistantText == "external stream" }
        }

        transport.emit(
            .chat(
                RemChatEventPayload(
                    runId: "other-run",
                    sessionKey: "main",
                    state: "error",
                    message: nil,
                    errorMessage: "boom")))

        try await waitUntil("streaming cleared") { await MainActor.run { vm.streamingAssistantText == nil } }
    }

    @Test func stripsInboundMetadataFromHistoryMessages() async throws {
        let history = RemChatHistoryPayload(
            sessionKey: "main",
            sessionId: "sess-main",
            messages: [
                AnyCodable([
                    "role": "user",
                    "content": [["type": "text", "text": """
Conversation info (untrusted metadata):
```json
{ \"sender\": \"openclaw-ios\" }
```

Hello?
"""]],
                    "timestamp": Date().timeIntervalSince1970 * 1000,
                ]),
            ],
            thinkingLevel: "off")
        let transport = TestChatTransport(historyResponses: [history])
        let vm = await MainActor.run { RemChatViewModel(sessionKey: "main", transport: transport) }

        await MainActor.run { vm.load() }
        try await waitUntil("history loaded") { await MainActor.run { !vm.messages.isEmpty } }

        let sanitized = await MainActor.run { vm.messages.first?.content.first?.text }
        #expect(sanitized == "Hello?")
    }

    @Test func abortRequestsDoNotClearPendingUntilAbortedEvent() async throws {
        let sessionId = "sess-main"
        let history = historyPayload(sessionId: sessionId)
        let (transport, vm) = await makeViewModel(historyResponses: [history, history])
        try await loadAndWaitBootstrap(vm: vm, sessionId: sessionId)

        await sendUserMessage(vm)
        try await waitUntil("pending run starts") { await MainActor.run { vm.pendingRunCount == 1 } }
        try await waitUntil("chat.send starts") { await transport.lastSentRunId() != nil }

        let runId = try #require(await transport.lastSentRunId())
        await MainActor.run { vm.abort() }

        try await waitUntil("abortRun called") {
            let ids = await transport.abortedRunIds()
            return ids == [runId]
        }

        // Pending remains until the gateway broadcasts an aborted/final chat event.
        #expect(await MainActor.run { vm.pendingRunCount } == 1)

        transport.emit(
            .chat(
                RemChatEventPayload(
                    runId: runId,
                    sessionKey: "main",
                    state: "aborted",
                    message: nil,
                    errorMessage: nil)))

        try await waitUntil("pending run clears") { await MainActor.run { vm.pendingRunCount == 0 } }
    }

    @Test func abortDoesNotCancelAlreadyTransmittedSend() async throws {
        let sendGate = AsyncGate()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sendMessageHook: { runId in
                await sendGate.wait()
                return RemChatSendResponse(runId: runId, status: "ok")
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }
        try await loadAndWaitBootstrap(vm: vm)

        await sendUserMessage(vm, text: "already sent")
        try await waitUntil("chat.send starts") { await transport.lastSentRunId() != nil }
        let runId = try #require(await transport.lastSentRunId())
        await MainActor.run { vm.abort() }
        try await waitUntil("abortRun called") { await transport.abortedRunIds() == [runId] }

        #expect(await MainActor.run { vm.pendingRunCount } == 1)
        await sendGate.open()
        try await waitUntil("transmitted send returns") { await MainActor.run { !vm.isSending } }
        #expect(await MainActor.run { vm.pendingRunCount } == 1)

        transport.emit(
            .chat(
                RemChatEventPayload(
                    runId: runId,
                    sessionKey: "main",
                    state: "aborted",
                    message: nil,
                    errorMessage: nil)))
        try await waitUntil("terminal event clears pending") {
            await MainActor.run { vm.pendingRunCount == 0 }
        }
    }

    @Test func sessionsListDecodesPaginationMetadata() throws {
        let payload = Data("""
        {
          "count": 100,
          "totalCount": 245,
          "limitApplied": 100,
          "hasMore": true,
          "sessions": [
            {
              "key": "agent:main:older-chat",
              "derivedTitle": "Older chat title",
              "lastMessagePreview": "Older chat preview"
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(
            RemChatSessionsListResponse.self,
            from: payload)

        #expect(response.count == 100)
        #expect(response.totalCount == 245)
        #expect(response.limitApplied == 100)
        #expect(response.hasMore == true)
        #expect(response.sessions.first?.derivedTitle == "Older chat title")
        #expect(response.sessions.first?.lastMessagePreview == "Older chat preview")
    }

    @Test func slowerSmallerSessionWindowCannotReplaceLargerWindow() async {
        let transport = TestChatTransport(
            historyResponses: [],
            sessionsRequestHook: { limit in
                if limit == 100 {
                    try await Task.sleep(for: .milliseconds(100))
                } else {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return RemChatSessionsListResponse(
                    ts: nil,
                    path: nil,
                    count: limit,
                    totalCount: limit,
                    limitApplied: limit,
                    hasMore: false,
                    defaults: nil,
                    sessions: [])
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }

        async let smaller = vm.reloadSessions(limit: 100)
        async let larger = vm.reloadSessions(limit: 200)
        _ = await (smaller, larger)

        #expect(await MainActor.run { vm.sessionsTotalCount } == 200)
    }

    @Test func sessionListFailureIsExposedToListSurfaces() async {
        struct ExpectedFailure: LocalizedError {
            var errorDescription: String? { "Could not load sessions" }
        }
        let transport = TestChatTransport(
            historyResponses: [],
            sessionsRequestHook: { _ in throw ExpectedFailure() })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }

        let succeeded = await vm.reloadSessions(limit: 100)

        #expect(!succeeded)
        #expect(await MainActor.run { vm.sessionsLoadError } == "Could not load sessions")
    }

    @Test func chatBootstrapRefreshesMetadataWithoutRefetchingEstablishedSessionWindow() async throws {
        let requestedLimits = OptionalIntRecorder()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sessionsRequestHook: { limit in
                await requestedLimits.append(limit)
                return RemChatSessionsListResponse(
                    ts: nil,
                    path: nil,
                    count: 0,
                    totalCount: limit,
                    limitApplied: limit,
                    hasMore: false,
                    defaults: nil,
                    sessions: [])
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }

        #expect(await vm.reloadSessions(limit: 200))
        #expect(await MainActor.run { vm.sessionsLimitApplied } == 200)
        await MainActor.run { vm.load() }

        try await waitUntil("bootstrap refreshes bounded session metadata") {
            let snapshot = await requestedLimits.snapshot()
            return snapshot.count >= 2
        }
        #expect(await requestedLimits.snapshot() == [200, 50])
        #expect(await MainActor.run { vm.sessionsTotalCount } == 200)
    }

    @Test func olderBoundedBootstrapCannotClearNewerPaginationFailure() async throws {
        struct PaginationFailure: LocalizedError {
            var errorDescription: String? { "Could not load the next conversations" }
        }
        let boundedBootstrapGate = AsyncGate()
        let requestedLimits = OptionalIntRecorder()
        let transport = TestChatTransport(
            historyResponses: [historyPayload()],
            sessionsRequestHook: { limit in
                await requestedLimits.append(limit)
                if limit == 50 {
                    await boundedBootstrapGate.wait()
                } else if limit == 200 {
                    throw PaginationFailure()
                }
                return RemChatSessionsListResponse(
                    ts: nil,
                    path: nil,
                    count: 0,
                    totalCount: 100,
                    limitApplied: limit,
                    hasMore: false,
                    defaults: nil,
                    sessions: [])
            })
        let vm = await MainActor.run {
            RemChatViewModel(sessionKey: "main", transport: transport)
        }

        #expect(await vm.reloadSessions(limit: 100))
        await MainActor.run { vm.load() }
        try await waitUntil("older bounded bootstrap starts") {
            await requestedLimits.snapshot().contains(50)
        }

        #expect(!(await vm.reloadSessions(limit: 200)))
        #expect(await MainActor.run { vm.sessionsLoadError }
            == "Could not load the next conversations")

        await boundedBootstrapGate.open()
        try await waitUntil("older bounded bootstrap finishes") {
            await MainActor.run { !vm.isRefreshingSessions }
        }

        #expect(await MainActor.run { vm.sessionsLoadError }
            == "Could not load the next conversations")
    }
}
