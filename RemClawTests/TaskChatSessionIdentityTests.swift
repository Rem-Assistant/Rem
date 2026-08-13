import Foundation
import OpenClawChatUI
import OpenClawProtocol
import Testing
@testable import RemClaw

@Suite("Task chat session identity")
@MainActor
struct TaskChatSessionIdentityTests {
    private let taskId = "A4A34D76-EC33-4BB2-A25B-61D705713255"

    @Test func neverRunTaskUsesTheSameCanonicalKeyAsBackendRuns() {
        let expected = "rem-task-a4a34d76-ec33-4bb2-a25b-61d705713255"
        #expect(TaskChatSessionIdentity.canonicalSessionKey(
            taskId: taskId,
            persistedSessionKey: nil
        ) == expected)
        #expect(TaskChatSessionIdentity.canonicalSessionKey(
            taskId: taskId,
            persistedSessionKey: "rem-task-\(taskId)"
        ) == expected)
    }

    @Test func canonicalKeyIsReversibleAfterRelaunchOrSessionListEntry() {
        let expected = taskId.lowercased()
        #expect(TaskChatSessionIdentity.taskId(
            from: "rem-task-\(expected)"
        ) == expected)
        #expect(TaskChatSessionIdentity.taskId(
            from: "agent:main:rem-task-\(expected)"
        ) == expected)
        #expect(TaskChatSessionIdentity.taskId(from: "task-a4a34d76ec33") == nil)
        #expect(TaskChatSessionIdentity.taskId(from: "main") == nil)
    }

    @Test func upgradedTaskWritesCanonicalAndAlwaysReadsLegacyHistory() {
        let legacy = "task-a4a34d76ec33"
        let canonical = "rem-task-a4a34d76-ec33-4bb2-a25b-61d705713255"

        #expect(TaskChatSessionIdentity.legacySessionKey(taskId: taskId) == legacy)
        #expect(TaskChatSessionIdentity.gatewayHistoryPlan(
            taskId: taskId,
            persistedSessionKey: nil
        ) == TaskChatSessionIdentity.GatewayHistoryPlan(
            activeSessionKey: canonical,
            additionalHistorySessionKeys: [legacy]
        ))
        #expect(TaskChatSessionIdentity.gatewayHistoryPlan(
            taskId: taskId,
            persistedSessionKey: legacy
        ) == TaskChatSessionIdentity.GatewayHistoryPlan(
            activeSessionKey: canonical,
            additionalHistorySessionKeys: [legacy]
        ))
        #expect(TaskChatSessionIdentity.gatewayHistoryPlan(
            taskId: taskId,
            persistedSessionKey: canonical
        ) == TaskChatSessionIdentity.GatewayHistoryPlan(
            activeSessionKey: canonical,
            additionalHistorySessionKeys: [legacy]
        ))
    }

    @Test func unloadedOrTop50TruncatedSessionCacheCannotHideLegacyReadAlias() {
        let canonical = "rem-task-a4a34d76-ec33-4bb2-a25b-61d705713255"
        let legacy = "task-a4a34d76ec33"
        let unloadedCache: Set<String> = []
        let truncatedTop50Cache = Set((0..<50).map { "chat-recent-\($0)" })

        let plan = TaskChatSessionIdentity.gatewayHistoryPlan(
            taskId: taskId,
            persistedSessionKey: nil
        )

        #expect(plan.activeSessionKey == canonical)
        #expect(plan.additionalHistorySessionKeys == [legacy])
        #expect(!unloadedCache.contains(legacy))
        #expect(!truncatedTop50Cache.contains(legacy))
    }

    @Test func namespacedCanonicalAndLegacyKeysStayInTheSameGatewayNamespace() {
        let canonical = "rem-task-a4a34d76-ec33-4bb2-a25b-61d705713255"
        let namespacedCanonical = "agent:main:\(canonical)"
        let namespacedLegacy = "agent:main:task-a4a34d76ec33"

        #expect(TaskChatSessionIdentity.compatibilityHistorySessionKeys(
            for: namespacedCanonical
        ) == [namespacedLegacy])
        #expect(TaskChatSessionIdentity.canonicalSessionKey(
            taskId: taskId,
            persistedSessionKey: namespacedLegacy
        ) == canonical)
        #expect(TaskChatSessionIdentity.compatibilityHistorySessionKeys(for: "main").isEmpty)
    }

    @Test func selectingLoadedLegacyHistoryRedirectsToCanonicalTaskThread() throws {
        let canonical = "rem-task-a4a34d76-ec33-4bb2-a25b-61d705713255"
        let redirect = try #require(TaskChatSessionIdentity.legacyHistoryRedirect(
            sessionKey: "agent:main:task-a4a34d76ec33",
            candidateTaskIds: [taskId]
        ))

        #expect(redirect == TaskChatSessionIdentity.LegacyHistoryRedirect(
            taskId: taskId,
            canonicalSessionKey: canonical
        ))
        #expect(TaskChatSessionIdentity.compatibilityHistorySessionKeys(
            for: redirect.canonicalSessionKey
        ) == ["task-a4a34d76ec33"])
    }

    @Test func ambiguousLegacyHistoryDoesNotRedirectAcrossTasks() {
        let collidingTaskId = "A4A34D76-EC33-4BB2-BBBB-BBBBBBBBBBBB"

        #expect(TaskChatSessionIdentity.legacyHistoryRedirect(
            sessionKey: "task-a4a34d76ec33",
            candidateTaskIds: [taskId, collidingTaskId]
        ) == nil)
    }

    @Test func legacyAndCanonicalGatewayHistoriesAreBothPreserved() throws {
        let legacyFirst = message(id: "legacy-first", timestamp: 1_000)
        let canonicalSecond = message(id: "canonical-second", timestamp: 2_000)

        let merged = TaskChatHistoryMerge.mergedGatewayCompatibility(
            legacyHistory: [legacyFirst],
            canonicalHistory: [canonicalSecond]
        )

        #expect(try merged.map(messageID) == ["legacy-first", "canonical-second"])
    }

    @Test func unregisteredCanonicalSessionLoadsTheTaskTranscript() async throws {
        let service = RecordingTaskCommentService()
        let coordinator = TaskChatTranscriptCoordinator(service: service)

        let messages = try await coordinator.priorHistoryMessages(
            sessionKey: "agent:main:rem-task-\(taskId.lowercased())"
        )

        #expect(service.requestedTaskIds == [taskId.lowercased()])
        #expect(messages.count == 1)
    }

    @Test func taskTranscriptFailurePropagatesInsteadOfLookingEmpty() async {
        let service = RecordingTaskCommentService(chatError: TestFailure.unavailable)
        let coordinator = TaskChatTranscriptCoordinator(service: service)

        await #expect(throws: TestFailure.self) {
            _ = try await coordinator.priorHistoryMessages(
                sessionKey: "rem-task-\(taskId.lowercased())"
            )
        }
    }

    @Test func deletedTaskKeepsItsGatewayConversationReadable() async throws {
        let service = RecordingTaskCommentService(
            chatError: TaskCommentServiceError.requestFailed(statusCode: 404, message: "Task not found")
        )
        let coordinator = TaskChatTranscriptCoordinator(service: service)

        let messages = try await coordinator.priorHistoryMessages(
            sessionKey: "rem-task-\(taskId.lowercased())"
        )

        #expect(messages.isEmpty)
        #expect(service.requestedTaskIds == [taskId.lowercased()])
    }

    @Test func ordinaryChatDoesNotCallTaskBackend() async throws {
        let service = RecordingTaskCommentService(chatError: TestFailure.unavailable)
        let coordinator = TaskChatTranscriptCoordinator(service: service)

        let messages = try await coordinator.priorHistoryMessages(sessionKey: "chat-general")

        #expect(messages.isEmpty)
        #expect(service.requestedTaskIds.isEmpty)
    }

    @Test func cloudRunsAndGatewayContinuationMergeByTimeNotSource() throws {
        let taskBefore = message(id: "task-before", timestamp: 1_000)
        let gatewayMiddle = message(id: "gateway-middle", timestamp: 2_000)
        let taskAfter = message(id: "task-after", timestamp: 3_000)

        let merged = TaskChatHistoryMerge.merged(
            taskTranscript: [taskBefore, taskAfter],
            gatewayHistory: [gatewayMiddle]
        )

        #expect(try merged.map(messageID) == ["task-before", "gateway-middle", "task-after"])
    }

    @Test func epochSecondsAndMillisecondsShareOneChronology() throws {
        let taskSeconds = message(id: "task", timestamp: 1_700_000_001)
        let gatewayMilliseconds = message(id: "gateway", timestamp: 1_700_000_000_500)

        let merged = TaskChatHistoryMerge.merged(
            taskTranscript: [taskSeconds],
            gatewayHistory: [gatewayMilliseconds]
        )

        #expect(try merged.map(messageID) == ["gateway", "task"])
        let normalizedTask = try #require(merged.last)
        let data = try JSONEncoder().encode(normalizedTask)
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)
        #expect(decoded.timestamp == 1_700_000_001_000)
        let timestamp = try #require(decoded.timestamp)
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        #expect(date == Date(timeIntervalSince1970: 1_700_000_001))
    }

    @Test func untimestampedToolResultStaysBetweenItsGatewayTurns() throws {
        let taskMiddle = message(id: "task-middle", timestamp: 2_000)
        let gatewayUser = message(id: "gateway-user", timestamp: 1_000)
        let gatewayToolResult = message(id: "gateway-tool-result", timestamp: nil)
        let gatewayAssistant = message(id: "gateway-assistant", timestamp: 3_000)

        let merged = TaskChatHistoryMerge.merged(
            taskTranscript: [taskMiddle],
            gatewayHistory: [gatewayUser, gatewayToolResult, gatewayAssistant]
        )

        #expect(try merged.map(messageID) == [
            "gateway-user", "task-middle", "gateway-tool-result", "gateway-assistant",
        ])
    }

    @Test func malformedSourceTimestampsNeverReverseItsOwnMessages() throws {
        let gatewayFirst = message(id: "gateway-first", timestamp: 3_000)
        let gatewaySecond = message(id: "gateway-second", timestamp: 1_000)

        let merged = TaskChatHistoryMerge.merged(
            taskTranscript: [],
            gatewayHistory: [gatewayFirst, gatewaySecond]
        )

        #expect(try merged.map(messageID) == ["gateway-first", "gateway-second"])
    }

    @Test func malformedTimestampDoesNotDropTheTurnDuringChatDecoding() throws {
        let malformed = AnyCodable([
            "role": "toolResult",
            "content": [["type": "text", "text": "Finished the step"]],
            "timestamp": "not-a-number",
        ])

        let merged = TaskChatHistoryMerge.merged(
            taskTranscript: [],
            gatewayHistory: [malformed]
        )
        let data = try JSONEncoder().encode(try #require(merged.first))
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        #expect(decoded.role == "toolResult")
        #expect(decoded.timestamp == nil)
        #expect(decoded.content.first?.text == "Finished the step")
    }

    @Test func booleanTimestampDoesNotDropTheTurnDuringChatDecoding() throws {
        let malformed = AnyCodable([
            "role": "assistant",
            "content": [["type": "text", "text": "Still visible"]],
            "timestamp": true,
        ])

        let merged = TaskChatHistoryMerge.merged(
            taskTranscript: [],
            gatewayHistory: [malformed]
        )
        let data = try JSONEncoder().encode(try #require(merged.first))
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        #expect(decoded.timestamp == nil)
        #expect(decoded.content.first?.text == "Still visible")
    }

    @Test func directGatewayHistoryScrubsMalformedTimestampWithoutAnAlias() throws {
        let malformed = AnyCodable([
            "role": "assistant",
            "content": [["type": "text", "text": "Direct legacy turn"]],
            "timestamp": "legacy-date",
        ])

        let normalized = TaskChatHistoryMerge.normalizedGatewayHistory([malformed])
        let data = try JSONEncoder().encode(try #require(normalized.first))
        let decoded = try JSONDecoder().decode(OpenClawChatMessage.self, from: data)

        #expect(decoded.timestamp == nil)
        #expect(decoded.content.first?.text == "Direct legacy turn")
    }

    private func message(id: String, timestamp: Double?) -> AnyCodable {
        var payload: [String: Any] = [
            "id": id,
            "role": "assistant",
            "content": [["type": "text", "text": id]],
        ]
        if let timestamp { payload["timestamp"] = timestamp }
        return AnyCodable(payload)
    }

    private func messageID(_ message: AnyCodable) throws -> String {
        let data = try JSONEncoder().encode(message)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["id"] as? String)
    }
}

private enum TestFailure: Error {
    case unavailable
}

@MainActor
private final class RecordingTaskCommentService: TaskCommentProviding {
    var requestedTaskIds: [String] = []
    let chatError: Error?

    init(chatError: Error? = nil) {
        self.chatError = chatError
    }

    func comments(taskId: String) async throws -> [TaskComment] { [] }

    func postComment(
        taskId: String,
        body: String,
        proposedStatus: String?
    ) async throws -> TaskComment {
        throw TestFailure.unavailable
    }

    func runCloudAgent(
        taskId: String,
        instruction: String?
    ) async throws -> CloudAgentRunResult {
        throw TestFailure.unavailable
    }

    func chatTranscript(taskId: String) async throws -> [TaskChatMessage] {
        requestedTaskIds.append(taskId)
        if let chatError { throw chatError }
        return [TaskChatMessage(
            id: "message-1",
            taskId: taskId,
            role: "assistant",
            content: "Finished the task execution step."
        )]
    }
}
