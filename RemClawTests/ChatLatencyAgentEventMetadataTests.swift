import Foundation
import OpenClawChatUI
import Testing
@testable import RemClaw

private final class ChatLatencyTestClock: @unchecked Sendable {
    var now: UInt64
    init(now: UInt64) { self.now = now }
}

struct ChatLatencyAgentEventMetadataTests {
    @Test func assistantOutputUsesStructuredStreamWithoutRetainingText() throws {
        let event = try decode(
            """
            {
              "runId": "run-1",
              "sessionKey": "agent:main:chat-1",
              "stream": "assistant",
              "ts": 1234,
              "data": { "text": "Hello", "delta": "Hel" }
            }
            """
        )

        #expect(event.sessionKey == "agent:main:chat-1")
        #expect(event.sourceTimestampMs == 1234)
        #expect(event.dataKeys == ["delta", "text"])
        #expect(event.hasAssistantOutput)
        #expect(!event.hasReasoningOutput)
        #expect(!event.isToolEvent)
    }

    @Test func lifecycleAndBlankAssistantEventsAreNotFirstVisibleOutput() throws {
        let lifecycle = try decode(
            """
            { "runId": "run-1", "stream": "lifecycle", "data": { "phase": "start" } }
            """
        )
        let blankAssistant = try decode(
            """
            { "runId": "run-1", "stream": "assistant", "data": { "delta": "  " } }
            """
        )

        #expect(!lifecycle.hasAssistantOutput)
        #expect(!lifecycle.hasReasoningOutput)
        #expect(!blankAssistant.hasAssistantOutput)
    }

    @Test func reasoningOutputIsDistinguishedFromAssistantOutput() throws {
        let event = try decode(
            """
            { "runId": "run-1", "stream": "thinking", "data": { "text": "Private reasoning", "delta": "Private" } }
            """
        )

        #expect(event.hasReasoningOutput)
        #expect(!event.hasAssistantOutput)
        #expect(event.dataKeys == ["delta", "text"])
    }

    @Test func directToolAndItemTimingMetadataRemainStructured() throws {
        let direct = try decode(
            """
            {
              "sessionKey": "chat-1",
              "runId": "run-1",
              "stream": "tool",
              "data": { "phase": "start", "name": "browser", "toolCallId": "tool-1", "args": {} }
            }
            """
        )
        let item = try decode(
            """
            {
              "sessionKey": "chat-1",
              "runId": "run-1",
              "stream": "item",
              "data": {
                "phase": "end",
                "kind": "tool",
                "toolCallId": "tool-1",
                "startedAt": 1000,
                "endedAt": 1750,
                "summary": "content that diagnostics must not expose"
              }
            }
            """
        )

        #expect(direct.isDirectToolEvent)
        #expect(direct.isToolEvent)
        #expect(direct.phase == "start")
        #expect(direct.toolCallID == "tool-1")
        #expect(!item.isDirectToolEvent)
        #expect(item.isToolEvent)
        #expect(item.sourceDurationMs == 750)
        #expect(item.dataKeys == ["endedAt", "kind", "phase", "startedAt", "summary", "toolCallId"])
    }

    @Test func reversedToolTimestampsAreRejected() throws {
        let event = try decode(
            """
            {
              "runId": "run-1",
              "stream": "item",
              "data": { "phase": "end", "kind": "tool", "startedAt": 2000, "endedAt": 1000 }
            }
            """
        )

        #expect(event.sourceDurationMs == nil)
        #expect(event.sourceDurationInvalidReason == "end_before_start")
    }

    @Test func disabledStoreIsAllocationFreeAndPublicLogHasNoIdentifiers() async {
        let store = ChatLatencyTraceStore(enabled: false)
        let trace = await store.begin(
            platform: "iOS",
            sessionKey: "private-session",
            idempotencyKey: "private-idempotency",
            messageLength: 42,
            attachmentsCount: 0
        )
        let counts = await store.counts()
        let message = ChatLatencyTrace.formattedMessage(
            platform: "iOS",
            phase: "send.start",
            elapsedMs: "1.0",
            details: "messageLength=42 attachments=0"
        )

        #expect(trace == nil)
        #expect(counts.pending == 0)
        #expect(counts.active == 0)
        #expect(!message.contains("private-session"))
        #expect(!message.contains("private-idempotency"))
        #expect(!message.contains("Suffix"))
    }

    @Test func overlappingSameSessionRunsRouteAndTerminateIndependently() async {
        let store = ChatLatencyTraceStore(enabled: true)
        let first = await store.begin(
            platform: "iOS",
            sessionKey: "chat-1",
            idempotencyKey: "key-1",
            messageLength: 1,
            attachmentsCount: 0
        )
        let second = await store.begin(
            platform: "iOS",
            sessionKey: "chat-1",
            idempotencyKey: "key-2",
            messageLength: 1,
            attachmentsCount: 0
        )

        await store.bind(runID: "run-1", idempotencyKey: "key-1", sessionKey: "chat-1")
        await store.bind(runID: "run-2", idempotencyKey: "key-2", sessionKey: "chat-1")
        let routedFirst = await store.active(runID: "run-1", sessionKey: "chat-1")
        let routedSecond = await store.active(runID: "run-2", sessionKey: "chat-1")

        #expect(first === routedFirst)
        #expect(second === routedSecond)
        #expect(first !== routedSecond)

        await store.terminate(runID: "run-1", sessionKey: "chat-1", outcome: "final")
        let afterFirstTerminal = await store.counts()
        let removedFirst = await store.active(runID: "run-1", sessionKey: "chat-1")
        let preservedSecond = await store.active(runID: "run-2", sessionKey: "chat-1")
        #expect(afterFirstTerminal.active == 1)
        #expect(removedFirst == nil)
        #expect(preservedSecond === second)

        await store.terminate(runID: "run-2", sessionKey: "chat-1", outcome: "aborted")
        let afterBothTerminal = await store.counts()
        #expect(afterBothTerminal.active == 0)
    }

    @Test func errorTerminalAndSendFailureCleanUpTheirExactTrace() async {
        let store = ChatLatencyTraceStore(enabled: true)
        _ = await store.begin(
            platform: "iOS",
            sessionKey: "chat-1",
            idempotencyKey: "key-error",
            messageLength: 1,
            attachmentsCount: 0
        )
        await store.bind(runID: "run-error", idempotencyKey: "key-error", sessionKey: "chat-1")
        await store.terminate(runID: "run-error", sessionKey: "chat-1", outcome: "error")

        _ = await store.begin(
            platform: "iOS",
            sessionKey: "chat-1",
            idempotencyKey: "key-send-failure",
            messageLength: 1,
            attachmentsCount: 0
        )
        await store.failPending(idempotencyKey: "key-send-failure")
        let counts = await store.counts()
        #expect(counts.pending == 0)
        #expect(counts.active == 0)
    }

    @Test func terminalEventRacingAheadOfSendAckCannotReviveTrace() async {
        let store = ChatLatencyTraceStore(enabled: true)
        _ = await store.begin(
            platform: "iOS",
            sessionKey: "chat-1",
            idempotencyKey: "run-race",
            messageLength: 1,
            attachmentsCount: 0
        )
        let routedBeforeAck = await store.active(runID: "run-race", sessionKey: "chat-1")
        #expect(routedBeforeAck != nil)

        await store.terminate(runID: "run-race", sessionKey: "chat-1", outcome: "final")
        await store.bind(runID: "run-race", idempotencyKey: "run-race", sessionKey: "chat-1")
        let counts = await store.counts()
        #expect(counts.pending == 0)
        #expect(counts.active == 0)
    }

    @Test func deduplicatedResponseCannotReviveAPreviouslyTerminatedRun() async {
        let store = ChatLatencyTraceStore(enabled: true)
        _ = await store.begin(platform: "iOS", sessionKey: "chat-1", idempotencyKey: "key-a", messageLength: 1, attachmentsCount: 0)
        await store.bind(runID: "run-a", idempotencyKey: "key-a", sessionKey: "chat-1")
        _ = await store.begin(platform: "iOS", sessionKey: "chat-1", idempotencyKey: "key-b", messageLength: 1, attachmentsCount: 0)

        await store.terminate(runID: "run-a", sessionKey: "chat-1", outcome: "final")
        let rebound = await store.bind(runID: "run-a", idempotencyKey: "key-b", sessionKey: "chat-1")
        let counts = await store.counts()

        #expect(rebound == nil)
        #expect(counts.pending == 0)
        #expect(counts.active == 0)
        #expect(counts.terminal == 1)
    }

    @Test func retentionPrunesExpiredInvalidAndOverCapacityEntries() async {
        let clock = ChatLatencyTestClock(now: 100)
        let store = ChatLatencyTraceStore(
            enabled: true,
            maximumTraceCount: 2,
            maximumTombstoneCount: 2,
            retentionNanos: 10,
            nowNanos: { clock.now }
        )
        for index in 1...3 {
            clock.now = UInt64(99 + index)
            _ = await store.begin(
                platform: "iOS",
                sessionKey: "chat-1",
                idempotencyKey: "key-\(index)",
                messageLength: 1,
                attachmentsCount: 0
            )
        }
        let afterCapacity = await store.counts()
        let evictedOldest = await store.active(runID: "key-1", sessionKey: "chat-1")
        #expect(afterCapacity.pending == 2)
        #expect(evictedOldest == nil)

        clock.now = 113
        let afterExpiry = await store.counts()
        #expect(afterExpiry.pending == 0)

        _ = await store.begin(platform: "iOS", sessionKey: "chat-a", idempotencyKey: "invalid", messageLength: 1, attachmentsCount: 0)
        let invalid = await store.bind(runID: "invalid-run", idempotencyKey: "invalid", sessionKey: "chat-b")
        let afterInvalid = await store.counts()
        #expect(invalid == nil)
        #expect(afterInvalid.pending == 0)
        #expect(afterInvalid.active == 0)

        for index in 1...3 {
            clock.now = UInt64(120 + index)
            await store.terminate(
                runID: "terminal-\(index)",
                sessionKey: "chat-1",
                outcome: "final"
            )
        }
        let boundedTombstones = await store.counts()
        #expect(boundedTombstones.terminal == 2)
    }

    @Test func preparationObserverCreatesOneCorrelatedPendingTrace() async {
        let store = ChatLatencyTraceStore(enabled: true)
        for phase in [
            OpenClawChatSendPreparationPhase.started,
            .optimisticAppendCompleted,
            .modelPatchWaitStarted,
            .modelPatchWaitEnded,
        ] {
            await store.recordPreparation(
                platform: "iOS",
                sessionKey: "chat-1",
                idempotencyKey: "key-1",
                phase: phase,
                messageLength: 5,
                attachmentsCount: 0
            )
        }
        let counts = await store.counts()
        #expect(counts.pending == 1)
        #expect(counts.active == 0)
    }

    private func decode(_ json: String) throws -> ChatLatencyAgentEventMetadata {
        try JSONDecoder().decode(ChatLatencyAgentEventMetadata.self, from: Data(json.utf8))
    }
}
