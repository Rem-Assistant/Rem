import Testing
@testable import RemClaw

struct VoiceAssistantTailPolicyTests {
    @Test func earlyStreamKeepsWorkingVisibleAndBelowSentVoiceTurn() {
        for phase in [VoiceResponsePhase.thinking, .generatingVoice] {
            let policy = VoiceAssistantTailPolicy.resolve(
                sentTurnIsPending: true,
                isVoiceModeActive: true,
                phase: phase,
                hasStreamingAssistantText: true,
                hasPendingRun: false
            )

            #expect(policy.showsStreamingBubble)
            #expect(policy.showsWorkingIndicator)
            #expect(policy.rendersStreamingBeforeVoicePlaceholder == false)
        }
    }

    @Test func playbackEndsWorkingWithoutReorderingReply() {
        let policy = VoiceAssistantTailPolicy.resolve(
            sentTurnIsPending: true,
            isVoiceModeActive: true,
            phase: .speaking,
            hasStreamingAssistantText: true,
            hasPendingRun: true
        )

        #expect(policy.showsStreamingBubble)
        #expect(policy.showsWorkingIndicator == false)
        #expect(policy.rendersStreamingBeforeVoicePlaceholder == false)
    }

    @Test func ordinaryTextStreamDoesNotGainASecondWorkingIndicator() {
        let policy = VoiceAssistantTailPolicy.resolve(
            sentTurnIsPending: false,
            isVoiceModeActive: false,
            phase: .idle,
            hasStreamingAssistantText: true,
            hasPendingRun: true
        )

        #expect(policy.showsStreamingBubble)
        #expect(policy.showsWorkingIndicator == false)
    }

    @Test func ordinaryPendingTextTurnStillShowsWorkingBeforeStreamingBegins() {
        let policy = VoiceAssistantTailPolicy.resolve(
            sentTurnIsPending: false,
            isVoiceModeActive: false,
            phase: .idle,
            hasStreamingAssistantText: false,
            hasPendingRun: true
        )

        #expect(policy.showsStreamingBubble == false)
        #expect(policy.showsWorkingIndicator)
    }

    @Test func priorAssistantStreamStaysAboveActiveTranscription() {
        let policy = VoiceAssistantTailPolicy.resolve(
            sentTurnIsPending: false,
            isVoiceModeActive: true,
            phase: .idle,
            hasStreamingAssistantText: true,
            hasPendingRun: false
        )

        #expect(policy.rendersStreamingBeforeVoicePlaceholder)
    }
}
