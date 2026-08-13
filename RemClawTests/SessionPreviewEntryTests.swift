import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import RemClaw

struct SessionPreviewEntryTests {
    @Test func chatStateMapsToActivityPreview() {
        let entry = SessionPreviewEntry.fromChatState(
            "final",
            sessionId: "agent:session-abcdef123456",
            gatewayId: "gateway-abcdef123456",
            gatewayProvider: .mac,
            deviceId: "device-abcdef123456",
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(entry.mode == .activity)
        #expect(entry.capability == .chat)
        #expect(entry.status == .succeeded)
        #expect(entry.retention == .actionLogMetadata)
        #expect(entry.sessionId == "agent:...3456")
        #expect(entry.gatewayId == "gatewa...3456")
        #expect(entry.deviceId == "device...3456")
    }

    @Test func toolEventInfersBrowserCapabilityAndRedactsSecrets() {
        let entry = SessionPreviewEntry.fromAgentEvent(
            stream: "tool",
            runId: "run-1234567890abcdef",
            data: [
                "tool": "browser.open",
                "url": "https://example.com/private/path?token=abcdef123456",
                "message": "Bearer sk-live-secret-token should not leak",
            ],
            gatewayProvider: .mac,
            now: Date(timeIntervalSince1970: 2)
        )

        #expect(entry.mode == .toolPhase)
        #expect(entry.capability == .browserAutomation)
        #expect(entry.status == .running)
        #expect(entry.approvalClass == .askEveryTime)
        #expect(entry.targetSummary == "browser.open")
        #expect(entry.resultSummary == "Bearer [redacted] should not leak")
        #expect(entry.resultSummary?.contains("sk-live-secret-token") == false)
    }

    @Test func redactionRemovesUrlsTokensPasswordsAndLongOutput() throws {
        let raw = """
        Open https://rem.example.com/path/to/private?token=abcdef with SETUP_PASSWORD=hunter2 and api_key: sk_1234567890abcdefghijklmnopqrstuvwxyz
        \(String(repeating: "x", count: 240))
        """

        let summary = try #require(SessionPreviewEntry.redactedSummary(raw, limit: 120))
        #expect(summary.contains("[redacted URL]"))
        #expect(summary.contains("rem.example.com") == false)
        #expect(summary.contains("hunter2") == false)
        #expect(summary.contains("sk_1234567890") == false)
        #expect(summary.hasSuffix("..."))
        #expect(summary.count <= 123)
    }

    @Test func cloudGatewayProducesUnsupportedMacLocalPreviewEntry() {
        let entry = SessionPreviewEntry.unsupportedMacLocalPreview(
            sessionId: "session-cloud-123456789",
            gatewayId: "cloud-gateway-abcdef",
            gatewayProvider: .cloud,
            requestedMode: .screenshotThumbnail,
            now: Date(timeIntervalSince1970: 3)
        )

        #expect(entry.mode == .blocked)
        #expect(entry.capability == .screenContext)
        #expect(entry.status == .unavailable)
        #expect(entry.approvalClass == .unavailable)
        #expect(entry.resultSummary?.contains("cloud gateway cannot inspect Mac-local screen") == true)
    }

    @Test func blockedScreenEventStaysPolicyBlocked() {
        let entry = SessionPreviewEntry.fromAgentEvent(
            stream: "screen.capture",
            runId: "run-screen",
            data: [
                "phase": "blocked by policy",
                "window": "Mail - Inbox",
            ],
            gatewayProvider: .mac
        )

        #expect(entry.mode == .toolPhase)
        #expect(entry.capability == .screenContext)
        #expect(entry.status == .blocked)
        #expect(entry.approvalClass == .blockedByPolicy)
        #expect(entry.targetSummary == "Mail - Inbox")
    }

    @Test func cloudScreenEventFailsClosedAsMacLocalUnavailable() {
        let entry = SessionPreviewEntry.fromAgentEvent(
            stream: "screen.capture",
            runId: "run-cloud-screen",
            data: [
                "phase": "running",
                "window": "Mail - Inbox",
            ],
            gatewayProvider: .cloud
        )

        #expect(entry.mode == .blocked)
        #expect(entry.capability == .screenContext)
        #expect(entry.status == .unavailable)
        #expect(entry.approvalClass == .unavailable)
        #expect(entry.targetSummary == "screenContext requires paired Mac")
        #expect(entry.resultSummary?.contains("Cloud gateway cannot inspect Mac-local screen") == true)
        #expect(entry.resultSummary?.contains("Mail - Inbox") == false)
    }

    @Test func pendingToolCallMapsToRedactedRunningEntry() {
        let entry = SessionPreviewEntry.fromPendingTool(
            name: "browser.open",
            args: AnyCodable([
                "url": "https://example.com/private?token=abcdef123456",
                "action": "open",
            ]),
            toolCallId: "tool-call-abcdef123456",
            sessionId: "session-abcdef123456",
            gatewayProvider: .mac,
            now: Date(timeIntervalSince1970: 4)
        )

        #expect(entry.mode == .toolPhase)
        #expect(entry.capability == .browserAutomation)
        #expect(entry.status == .running)
        #expect(entry.targetSummary == "browser.open")
        #expect(entry.resultSummary == "running")
        #expect(entry.sessionId == "tool-c...3456")
        #expect(entry.resultSummary?.contains("abcdef123456") == false)
    }

    @Test func pendingToolCallRedactsGatewayAndDeviceIdentity() {
        let entry = SessionPreviewEntry.fromPendingTool(
            name: "browser.open",
            args: AnyCodable(["url": "https://example.com"]),
            toolCallId: "tool-call-abcdef123456",
            sessionId: "session-abcdef123456",
            gatewayId: "gateway-abcdef123456",
            gatewayProvider: .mac,
            deviceId: "device-abcdef123456",
            now: Date(timeIntervalSince1970: 5)
        )

        #expect(entry.gatewayId == "gatewa...3456")
        #expect(entry.deviceId == "device...3456")
        #expect(entry.sessionId == "tool-c...3456")
    }

    @Test func completedToolCallMapsToLoggedActionMetadata() {
        let entry = SessionPreviewEntry.fromCompletedTool(
            name: "browser.open",
            toolCallId: "tool-call-abcdef123456",
            sessionId: "session-abcdef123456",
            gatewayId: "gateway-abcdef123456",
            gatewayProvider: .mac,
            deviceId: "device-abcdef123456",
            now: Date(timeIntervalSince1970: 6)
        )

        #expect(entry.mode == .toolPhase)
        #expect(entry.capability == .browserAutomation)
        #expect(entry.status == .logged)
        #expect(entry.retention == .actionLogMetadata)
        #expect(entry.resultSummary == "completed")
        #expect(entry.gatewayId == "gatewa...3456")
        #expect(entry.deviceId == "device...3456")
    }

    @Test func completedToolCallPreservesFailedStatus() {
        let entry = SessionPreviewEntry.fromCompletedTool(
            name: "calendar.add",
            resultStatus: "error",
            toolCallId: "tool-call-error",
            sessionId: "session-error",
            gatewayProvider: .mac
        )

        #expect(entry.status == .failed)
        #expect(entry.retention == .actionLogMetadata)
        #expect(entry.resultSummary == "failed")
    }

    @Test func completedToolCallDoesNotExposeRawResultOutput() {
        let entry = SessionPreviewEntry.fromCompletedTool(
            name: "shell.run",
            resultStatus: "ok",
            toolCallId: "tool-call-shell",
            sessionId: "session-shell",
            gatewayProvider: .mac
        )

        #expect(entry.status == .logged)
        #expect(entry.resultSummary == "completed")
        #expect(entry.resultSummary?.contains("private") == false)
    }

    @Test func cloudPendingMacLocalToolFailsClosed() {
        let entry = SessionPreviewEntry.fromPendingTool(
            name: "nodes",
            args: AnyCodable([
                "action": "screen_record",
                "window": "Mail - Inbox",
            ]),
            toolCallId: "tool-call-screen",
            sessionId: "session-cloud",
            gatewayProvider: .cloud
        )

        #expect(entry.mode == .blocked)
        #expect(entry.capability == .screenContext)
        #expect(entry.status == .unavailable)
        #expect(entry.targetSummary == "screenContext requires paired Mac")
        #expect(entry.resultSummary?.contains("Mail - Inbox") == false)
    }

    @Test func unknownPendingMacLocalToolFailsClosed() {
        let entry = SessionPreviewEntry.fromPendingTool(
            name: "shell.run",
            args: AnyCodable([
                "command": "cat ~/Desktop/private.txt",
            ]),
            toolCallId: "tool-call-shell",
            sessionId: "session-unknown",
            gatewayProvider: .unknown
        )

        #expect(entry.mode == .blocked)
        #expect(entry.capability == .shell)
        #expect(entry.status == .unavailable)
        #expect(entry.approvalClass == .unavailable)
        #expect(entry.targetSummary == "shell requires paired Mac")
        #expect(entry.resultSummary?.contains("private.txt") == false)
    }
}
