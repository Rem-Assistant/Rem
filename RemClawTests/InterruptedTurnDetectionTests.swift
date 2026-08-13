import Foundation
import Testing
import OpenClawChatUI
import OpenClawProtocol
@testable import RemClaw

/// Unit tests for the pure interrupted-turn predicate that drives the inline
/// "Response interrupted — Retry" affordance (SharedRemChatView). The predicate
/// classifies the SHAPE of the trailing turn; the view ANDs it with idle gating,
/// so these tests only exercise the message-shape logic.
struct InterruptedTurnDetectionTests {
    // MARK: - Fixtures

    private func text(_ s: String, type: String = "text") -> OpenClawChatMessageContent {
        OpenClawChatMessageContent(type: type, text: s, mimeType: nil, fileName: nil, content: nil)
    }

    private func thinking(_ s: String) -> OpenClawChatMessageContent {
        OpenClawChatMessageContent(
            type: "thinking", text: nil, thinking: s, mimeType: nil, fileName: nil, content: nil)
    }

    private func toolCall(name: String) -> OpenClawChatMessageContent {
        OpenClawChatMessageContent(
            type: "tool_use", text: nil, mimeType: nil, fileName: nil, content: nil,
            name: name, arguments: AnyCodable(["x": 1]))
    }

    /// A produced media item (e.g. a generated image / attached file) with no text —
    /// exercises the media-only healthy-reply path.
    private func attachment(type: String = "file") -> OpenClawChatMessageContent {
        OpenClawChatMessageContent(
            type: type, text: nil, mimeType: "image/png", fileName: "chart.png",
            content: AnyCodable("<base64>"))
    }

    private func message(
        role: String,
        _ content: [OpenClawChatMessageContent],
        stopReason: String? = nil
    ) -> OpenClawChatMessage {
        OpenClawChatMessage(
            role: role, content: content, timestamp: 0, stopReason: stopReason)
    }

    // MARK: - Completed turns must NOT be flagged (no false positives)

    @Test func emptyTranscriptIsNotInterrupted() {
        #expect(SharedRemChatView.interruptedTurnRetryPrompt([]) == nil)
    }

    @Test func healthyAnsweredTurnIsNotInterrupted() {
        let msgs = [
            message(role: "user", [text("what's 2+2?")]),
            message(role: "assistant", [text("It's 4.")], stopReason: "end_turn"),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    @Test func answeredTurnWithNoStopReasonIsNotInterrupted() {
        // History replay doesn't always populate stopReason; visible final text alone
        // proves the turn produced an answer.
        let msgs = [
            message(role: "user", [text("hi")]),
            message(role: "assistant", [thinking("pondering"), text("Hello!")]),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    @Test func turnEndingOnToolResultIsNotInterrupted() {
        // Agent legitimately finished on an action; the trailing message is a tool
        // result, not an orphaned assistant turn.
        let msgs = [
            message(role: "user", [text("mark it done")]),
            message(role: "assistant", [toolCall(name: "reminders.update")], stopReason: "tool_use"),
            message(role: "toolResult", [text("{\"status\":\"ok\"}", type: "tool_result")]),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    @Test func abortedStopReasonButVisibleTextIsNotInterrupted() {
        // There is real content to read, so don't nag the user with Retry.
        let msgs = [
            message(role: "user", [text("summarize")]),
            message(role: "assistant", [text("Here is a partial summary")], stopReason: "aborted"),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    @Test func mediaOnlyReplyIsNotInterrupted() {
        // A healthy text-free image/attachment reply (nil stopReason) IS an answer —
        // it must not be hidden behind a Retry card. Regression guard for the media
        // false-positive.
        let msgs = [
            message(role: "user", [text("make me a chart")]),
            message(role: "assistant", [attachment()], stopReason: nil),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    @Test func mediaWithReasoningButNoTextIsNotInterrupted() {
        // Reasoning + a produced image, still no text, nil stopReason → completed.
        let msgs = [
            message(role: "user", [text("chart it")]),
            message(role: "assistant", [thinking("plotting"), attachment(type: "attachment")], stopReason: nil),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    @Test func reasoningOnlyTurnWithTerminalStopReasonIsNotInterrupted() {
        // No visible content, but a terminal non-aborted stopReason marks the turn
        // complete via the best-effort secondary path.
        let msgs = [
            message(role: "user", [text("ok")]),
            message(role: "assistant", [thinking("acknowledged")], stopReason: "end_turn"),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    @Test func modelRoleAnsweredTurnIsNotInterrupted() {
        // The `role: "model"` branch, completed shape.
        let msgs = [
            message(role: "user", [text("hi")]),
            message(role: "model", [text("Hello!")], stopReason: nil),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == nil)
    }

    // MARK: - Interrupted turns MUST be flagged + preserve the prompt

    @Test func orphanedThoughtOnlyTurnIsInterrupted() {
        // The observed bug: user asked to "drop it", the turn rendered only a Thought
        // that ends mid-plan, then nothing — no final content, no stop reason.
        let msgs = [
            message(role: "user", [text("drop it")]),
            message(
                role: "assistant",
                [thinking("Let me first list tasks to find the Q3 metrics review task.")],
                stopReason: nil),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == "drop it")
    }

    @Test func userTurnWithNoReplyIsInterrupted() {
        // chat.send accepted but the gateway died before any assistant output landed.
        let msgs = [message(role: "user", [text("what's on my calendar?")])]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == "what's on my calendar?")
    }

    @Test func emptyAssistantTurnIsInterrupted() {
        let msgs = [
            message(role: "user", [text("hello")]),
            message(role: "assistant", [], stopReason: nil),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == "hello")
    }

    @Test func abortedStopReasonWithNoTextIsInterrupted() {
        let msgs = [
            message(role: "user", [text("do the thing")]),
            message(role: "assistant", [thinking("starting…")], stopReason: "interrupted"),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == "do the thing")
    }

    @Test func retryPromptComesFromTheMostRecentUserTurn() {
        let msgs = [
            message(role: "user", [text("first question")]),
            message(role: "assistant", [text("first answer")], stopReason: "end_turn"),
            message(role: "user", [text("second question")]),
            message(role: "assistant", [thinking("thinking…")], stopReason: nil),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == "second question")
    }

    @Test func modelRoleReasoningOnlyTurnIsInterrupted() {
        // The `role: "model"` branch, interrupted shape.
        let msgs = [
            message(role: "user", [text("do it")]),
            message(role: "model", [thinking("planning…")], stopReason: nil),
        ]
        #expect(SharedRemChatView.interruptedTurnRetryPrompt(msgs) == "do it")
    }

    // MARK: - Helpers

    @Test func assistantHasFinalContentCountsTextAndMediaButNotReasoningOrTools() {
        // Reasoning + tool-call only → no answer.
        #expect(SharedRemChatView.assistantHasFinalContent(
            message(role: "assistant", [thinking("x"), toolCall(name: "t")])) == false)
        // Visible text → answer.
        #expect(SharedRemChatView.assistantHasFinalContent(
            message(role: "assistant", [thinking("x"), text("answer")])) == true)
        // Produced media, no text → still an answer.
        #expect(SharedRemChatView.assistantHasFinalContent(
            message(role: "assistant", [attachment()])) == true)
    }
}
