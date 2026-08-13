import Foundation
import OpenClawChatUI
import Testing
@testable import RemClawMac

private final class MacChatLatencyTestClock: @unchecked Sendable {
    var now: UInt64
    init(now: UInt64) { self.now = now }
}

struct MacChatLatencyAgentEventMetadataTests {
    @Test func agentRoutingRejectsPreviousConversationAndRewritesCurrentRunID() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"execution-run","stream":"assistant","data":{"text":"hello"}}"#.utf8)
        )

        #expect(MacChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: "agent:main:chat-a",
            activeSessionKey: "chat-b",
            sessionId: "history-b") == nil)

        let current = MacChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: "agent:main:chat-b",
            activeSessionKey: "chat-b",
            sessionId: "history-b")
        #expect(current?.runId == "history-b")

        #expect(MacChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: "agent:other:chat-b",
            activeSessionKey: "chat-b",
            sessionId: "history-b") == nil)
    }

    @Test func agentRoutingFailsClosedWithoutSessionKeyButAllowsFreshMatchingRoute() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"fresh-session","stream":"assistant","data":{"text":"hello"}}"#.utf8)
        )

        #expect(MacChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: nil,
            activeSessionKey: "chat-b",
            sessionId: nil) == nil)

        let fresh = MacChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: "agent:main:chat-b",
            activeSessionKey: "chat-b",
            sessionId: nil)
        #expect(fresh?.runId == "fresh-session")
    }

    @Test func chatFinalCannotRouteOrPatchFromAnotherCanonicalAgent() throws {
        let foreign = try JSONDecoder().decode(
            OpenClawChatEventPayload.self,
            from: Data(#"{"runId":"run-other","sessionKey":"agent:other:chat-b","state":"final","message":{"role":"assistant","content":[{"type":"text","text":"foreign"}]}}"#.utf8))

        #expect(MacChatTransport.routedChatEvent(
            foreign,
            activeSessionKey: "chat-b") == nil)

        let primary = try JSONDecoder().decode(
            OpenClawChatEventPayload.self,
            from: Data(#"{"runId":"run-main","sessionKey":"agent:main:chat-b","state":"final"}"#.utf8))
        #expect(MacChatTransport.routedChatEvent(
            primary,
            activeSessionKey: "chat-b")?.sessionKey == "chat-b")
    }

    @Test func assistantAndReasoningOutputRemainDistinctPrivacySafeMetadata() throws {
        let assistant = try decode(
            """
            {
              "sessionKey": "agent:main:chat-1",
              "runId": "run-1",
              "stream": "assistant",
              "ts": 1234,
              "data": { "text": "Hello", "delta": "Hel" }
            }
            """
        )
        let reasoning = try decode(
            """
            { "runId": "run-1", "stream": "thinking", "data": { "text": "Private reasoning", "delta": "Private" } }
            """
        )

        #expect(assistant.hasAssistantOutput)
        #expect(!assistant.hasReasoningOutput)
        #expect(reasoning.hasReasoningOutput)
        #expect(!reasoning.hasAssistantOutput)
        #expect(assistant.dataKeys == ["delta", "text"])
    }

    @Test func toolSourceTimingUsesStructuredFields() throws {
        let event = try decode(
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

        #expect(event.isToolEvent)
        #expect(!event.isDirectToolEvent)
        #expect(event.sourceDurationMs == 750)
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

    @Test func disabledStoreHasCheapPrivateFastPath() async {
        let store = ChatLatencyTraceStore(enabled: false)
        let trace = await store.begin(
            platform: "macOS",
            sessionKey: "private-session",
            idempotencyKey: "private-idempotency",
            messageLength: 42,
            attachmentsCount: 0
        )
        let counts = await store.counts()
        let message = ChatLatencyTrace.formattedMessage(
            platform: "macOS",
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

    @Test func overlappingRunsAndEveryTerminalPathCleanUpExactly() async {
        let store = ChatLatencyTraceStore(enabled: true)
        let outcomes = ["final", "aborted", "error"]
        var traces: [ChatLatencyTrace] = []
        for index in outcomes.indices {
            let trace = await store.begin(
                platform: "macOS",
                sessionKey: "chat-1",
                idempotencyKey: "key-\(index)",
                messageLength: 1,
                attachmentsCount: 0
            )
            if let trace { traces.append(trace) }
            await store.bind(
                runID: "run-\(index)",
                idempotencyKey: "key-\(index)",
                sessionKey: "chat-1"
            )
        }

        let before = await store.counts()
        #expect(before.active == 3)
        for index in outcomes.indices {
            let routed = await store.active(runID: "run-\(index)", sessionKey: "chat-1")
            #expect(routed === traces[index])
            await store.terminate(
                runID: "run-\(index)",
                sessionKey: "chat-1",
                outcome: outcomes[index]
            )
        }
        let after = await store.counts()
        #expect(after.pending == 0)
        #expect(after.active == 0)
    }

    @Test func pendingSendFailureRemovesOnlyItsCorrelation() async {
        let store = ChatLatencyTraceStore(enabled: true)
        _ = await store.begin(
            platform: "macOS",
            sessionKey: "chat-1",
            idempotencyKey: "key-1",
            messageLength: 1,
            attachmentsCount: 0
        )
        _ = await store.begin(
            platform: "macOS",
            sessionKey: "chat-1",
            idempotencyKey: "key-2",
            messageLength: 1,
            attachmentsCount: 0
        )
        await store.failPending(idempotencyKey: "key-1")
        let counts = await store.counts()
        #expect(counts.pending == 1)
        #expect(counts.active == 0)
    }

    @Test func preAckTerminalRemovesPendingCorrelation() async {
        let store = ChatLatencyTraceStore(enabled: true)
        _ = await store.begin(
            platform: "macOS",
            sessionKey: "chat-1",
            idempotencyKey: "run-race",
            messageLength: 1,
            attachmentsCount: 0
        )
        let routedBeforeAck = await store.active(runID: "run-race", sessionKey: "chat-1")
        #expect(routedBeforeAck != nil)
        await store.terminate(runID: "run-race", sessionKey: "chat-1", outcome: "error")
        await store.bind(runID: "run-race", idempotencyKey: "run-race", sessionKey: "chat-1")
        let counts = await store.counts()
        #expect(counts.pending == 0)
        #expect(counts.active == 0)
    }

    @Test func deduplicatedResponseAfterTerminalDoesNotRecreateRun() async {
        let store = ChatLatencyTraceStore(enabled: true)
        _ = await store.begin(platform: "macOS", sessionKey: "chat-1", idempotencyKey: "key-a", messageLength: 1, attachmentsCount: 0)
        await store.bind(runID: "run-a", idempotencyKey: "key-a", sessionKey: "chat-1")
        _ = await store.begin(platform: "macOS", sessionKey: "chat-1", idempotencyKey: "key-b", messageLength: 1, attachmentsCount: 0)
        await store.terminate(runID: "run-a", sessionKey: "chat-1", outcome: "final")
        let rebound = await store.bind(runID: "run-a", idempotencyKey: "key-b", sessionKey: "chat-1")
        let counts = await store.counts()
        #expect(rebound == nil)
        #expect(counts.pending == 0)
        #expect(counts.active == 0)
        #expect(counts.terminal == 1)
    }

    @Test func retentionBoundsAndInvalidCorrelationCleanUpStore() async {
        let clock = MacChatLatencyTestClock(now: 10)
        let store = ChatLatencyTraceStore(
            enabled: true,
            maximumTraceCount: 1,
            maximumTombstoneCount: 1,
            retentionNanos: 5,
            nowNanos: { clock.now }
        )
        _ = await store.begin(platform: "macOS", sessionKey: "chat-1", idempotencyKey: "key-1", messageLength: 1, attachmentsCount: 0)
        clock.now = 11
        _ = await store.begin(platform: "macOS", sessionKey: "chat-1", idempotencyKey: "key-2", messageLength: 1, attachmentsCount: 0)
        let bounded = await store.counts()
        #expect(bounded.pending == 1)

        clock.now = 17
        let expired = await store.counts()
        #expect(expired.pending == 0)

        _ = await store.begin(platform: "macOS", sessionKey: "chat-a", idempotencyKey: "invalid", messageLength: 1, attachmentsCount: 0)
        _ = await store.bind(runID: "run-invalid", idempotencyKey: "invalid", sessionKey: "chat-b")
        let invalid = await store.counts()
        #expect(invalid.pending == 0)
        #expect(invalid.active == 0)

        await store.terminate(runID: "terminal-1", sessionKey: "chat-1", outcome: "final")
        clock.now = 18
        await store.terminate(runID: "terminal-2", sessionKey: "chat-1", outcome: "final")
        let boundedTombstones = await store.counts()
        #expect(boundedTombstones.terminal == 1)
    }

    private func decode(_ json: String) throws -> ChatLatencyAgentEventMetadata {
        try JSONDecoder().decode(ChatLatencyAgentEventMetadata.self, from: Data(json.utf8))
    }
}
