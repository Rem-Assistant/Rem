import Foundation
import Testing
@testable import RemClaw

struct StreamingAssistantHandoffPolicyTests {
    private func snapshot(
        _ role: String,
        userFingerprint: String? = nil,
        final: Bool = false
    ) -> StreamingAssistantHandoffPolicy.MessageSnapshot {
        .init(role: role, userFingerprint: userFingerprint, hasFinalAssistantContent: final)
    }

    private func anchor(_ fingerprint: String) -> StreamingAssistantHandoffPolicy.UserTurnAnchor {
        .init(fingerprint: fingerprint)
    }

    @Test func toolResultAppendDoesNotClearStreamedAnswer() {
        #expect(!StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("prompt"),
            messages: [snapshot("user", userFingerprint: "prompt"), snapshot("tool")]
        ))
    }

    @Test func persistedAssistantAppendClearsHandoff() {
        #expect(StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("prompt"),
            messages: [
                snapshot("user", userFingerprint: "prompt"),
                snapshot("tool"),
                snapshot("assistant", final: true)
            ]
        ))
    }

    @Test func assistantPreambleBeforeToolResultDoesNotClearHandoff() {
        #expect(!StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("prompt"),
            messages: [
                snapshot("user", userFingerprint: "prompt"),
                snapshot("assistant", final: true),
                snapshot("tool")
            ]
        ))
    }

    @Test func nextUserTurnClearsPriorHandoff() {
        #expect(StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("prompt"),
            messages: [
                snapshot("user", userFingerprint: "prompt"),
                snapshot("user", userFingerprint: "next")
            ]
        ))
    }

    @Test func sameCountReplacementWithTerminalAnswerClearsHandoff() {
        #expect(StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("prompt"),
            messages: [snapshot("user", userFingerprint: "prompt"), snapshot("assistant", final: true)]
        ))
    }

    @Test func missingOriginClearsRatherThanMisattributingCachedText() {
        #expect(StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("prompt"),
            messages: [snapshot("user", userFingerprint: "different"), snapshot("assistant", final: true)]
        ))
    }

    @Test func canonicalTimestampReplacementKeepsHandoffDespiteNewMessageIdentity() {
        #expect(!StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("prompt"),
            messages: [snapshot("user", userFingerprint: "prompt"), snapshot("tool")]
        ))
    }

    @Test func repeatedIdenticalPromptAnchorsToTranscriptTail() {
        #expect(!StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("same"),
            messages: [
                snapshot("user", userFingerprint: "same"),
                snapshot("assistant", final: true),
                snapshot("user", userFingerprint: "same"),
                snapshot("tool")
            ]
        ))
    }

    @Test func cappedHistoryPrefixTruncationKeepsCurrentRepeatedPromptHandoff() {
        var messages = (0..<198).map { index in
            snapshot(index.isMultiple(of: 2) ? "user" : "assistant", userFingerprint: index == 0 ? "same" : "old-\(index)", final: !index.isMultiple(of: 2))
        }
        messages.append(snapshot("user", userFingerprint: "same"))
        messages.append(snapshot("tool"))

        #expect(messages.count == 200)
        #expect(!StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("same"),
            messages: messages
        ))
    }

    @Test func differentLatestUserClearsPriorHandoff() {
        #expect(StreamingAssistantHandoffPolicy.shouldClearCachedText(
            originatingUserAnchor: anchor("same"),
            messages: [
                snapshot("user", userFingerprint: "same"),
                snapshot("assistant", final: true),
                snapshot("user", userFingerprint: "different")
            ]
        ))
    }

    @Test func repeatedIdenticalCrossDeviceAppendIsNewTurnAuthority() {
        let prior = [
            snapshot("user", userFingerprint: "same"),
            snapshot("tool")
        ]
        let current = prior + [snapshot("user", userFingerprint: "same")]

        #expect(StreamingAssistantHandoffPolicy.appendedUserTurn(from: prior, to: current))
    }

    @Test func cappedPrefixTruncationStillRecognizesCrossDeviceAppend() {
        let prior = [
            snapshot("assistant", final: true),
            snapshot("user", userFingerprint: "same"),
            snapshot("tool")
        ]
        let current = [
            snapshot("user", userFingerprint: "same"),
            snapshot("tool"),
            snapshot("user", userFingerprint: "same")
        ]

        #expect(StreamingAssistantHandoffPolicy.appendedUserTurn(from: prior, to: current))
    }

    @Test func canonicalAttachmentEchoGrowthDoesNotBecomeNewTurnAfterDisplayDeduplication() {
        let prior = [snapshot("user", userFingerprint: "attachment")]
        let displayCanonicalRefresh = prior + [snapshot("tool")]

        #expect(!StreamingAssistantHandoffPolicy.appendedUserTurn(
            from: prior,
            to: displayCanonicalRefresh
        ))
    }

    @Test func hiddenBriefCanonicalEchoIsOneDisplayTurn() {
        let plain = "Help me prioritize today."
        let canonical = """
        <<BRIEF_CONTEXT>>
        # Morning brief

        Two tasks need attention.
        <<END_BRIEF_CONTEXT>>

        Help me prioritize today.
        """

        #expect(StreamingAssistantHandoffPolicy.isHiddenBriefEchoPair(plain, canonical))
        #expect(StreamingAssistantHandoffPolicy.isHiddenBriefEchoPair(canonical, plain))
        #expect(!StreamingAssistantHandoffPolicy.isHiddenBriefEchoPair(plain, plain))
        #expect(!StreamingAssistantHandoffPolicy.isHiddenBriefEchoPair(
            "Help me prioritize tomorrow.",
            canonical
        ))
    }

    @Test func toolAppendAndCanonicalReplacementAreNotNewUserAuthority() {
        let prior = [snapshot("user", userFingerprint: "same")]
        #expect(!StreamingAssistantHandoffPolicy.appendedUserTurn(
            from: prior,
            to: prior + [snapshot("tool")]
        ))
        #expect(!StreamingAssistantHandoffPolicy.appendedUserTurn(
            from: prior,
            to: [snapshot("user", userFingerprint: "same")]
        ))
    }
}
