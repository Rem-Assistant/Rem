import Foundation
import OpenClawKit
import Testing
@testable import RemClaw

@Suite
struct ExplicitSpeechPlaybackPlanTests {
    @Test @MainActor
    func largeSingleParagraphAudioStaysWholeUntilAudibleCompletion() async {
        // A 160 KiB buffered paragraph exceeds the streaming player's three 32 KiB queue buffers.
        // The regression was packet loss inside one paragraph, so exercise payload conservation and
        // the audible-completion boundary directly rather than merely asserting narration chunk count.
        let paragraphAudio = Data(repeating: 0x5a, count: 160 * 1_024)
        let player = SuspendedBufferedMP3Player()
        let manager = RemTalkModeManager()
        manager.isMuted = true
        manager.bufferedMP3Player = player
        let gatewayAudio = GatewayTalkSpeechAudio(
            audioBase64: paragraphAudio.base64EncodedString(),
            provider: "test",
            outputFormat: "mp3",
            mimeType: "audio/mpeg",
            fileExtension: ".mp3"
        )
        var playbackReturned = false

        let playback = Task { @MainActor in
            let result = await manager.playGatewaySpeechAudio(gatewayAudio)
            playbackReturned = true
            return result
        }
        await player.waitUntilStarted()

        #expect(player.receivedData == paragraphAudio)
        #expect(!playbackReturned)

        player.finishSuccessfully()
        let result = await playback.value
        #expect(result)
        #expect(playbackReturned)
    }

    @Test func deliveredDailyBriefRetainsItsFinalSentenceThroughNarrationPlanning() throws {
        let brief = """
        Saturday morning, and your task list has a few things that could use your attention.

        **Blocked**

        - **Attend community event** — reply with the date, location, and event details.

        **Overdue**

        - **Catch up with family members** — choose a specific person and time.
        - **Check recruiter emails** — review the inbox and draft replies.

        Tell me which one you want to handle first.
        """
        let history = try #require(
            """
            {"messages":[{"role":"assistant","provider":"minimax","model":"minimax-m2.7","timestamp":1786204800000,"content":[{"type":"text","text":\(String(reflecting: brief))}]}]}
            """.data(using: .utf8)
        )
        let artifact = try #require(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: history,
            matching: brief,
            now: Date(timeIntervalSince1970: 1_786_204_800),
            calendar: Calendar(identifier: .gregorian)
        ))

        let chunks = ExplicitSpeechPlaybackPlan.chunks(from: artifact.markdown)

        #expect(chunks.count > 2)
        #expect(chunks.joined(separator: "\n\n") == brief)
        #expect(chunks.last == "Tell me which one you want to handle first.")
    }

    @Test func multiParagraphBriefRetainsEveryParagraphInOrder() {
        let text = "Morning context.\n\nMidday decisions.\n\nNight follow-up."
        let chunks = ExplicitSpeechPlaybackPlan.chunks(from: text)

        #expect(chunks == ["Morning context.", "Midday decisions.", "Night follow-up."])
        #expect(chunks.dropFirst().isEmpty == false)
    }

    @Test func longParagraphIsBoundedWithoutDroppingItsTail() {
        let text = "One two three four five six seven eight nine ten."
        let chunks = ExplicitSpeechPlaybackPlan.chunks(from: text, maximumCharacters: 12)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 12 })
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func emptyNarrationProducesNoSuccessfulPlaybackStep() {
        #expect(ExplicitSpeechPlaybackPlan.chunks(from: " \n\n ").isEmpty)
    }

    @Test func intermediateUtteranceCompletionDoesNotCompleteNarration() {
        var progress = ExplicitSpeechPlaybackProgress(totalChunks: 3)
        progress.completeNextChunk()
        #expect(!progress.isComplete)
        progress.completeNextChunk()
        #expect(!progress.isComplete)
        progress.completeNextChunk()
        #expect(progress.isComplete)
    }

    @Test func stoppedNarrationNeverCompletesOrEarnsAReceipt() {
        var progress = ExplicitSpeechPlaybackProgress(totalChunks: 2)
        progress.completeNextChunk()
        progress.interrupt()
        progress.completeNextChunk()
        #expect(!progress.isComplete)
    }

    @Test func playbackOutcomeSeparatesCompletionStopAndFailure() {
        #expect(!ExplicitSpeechPlaybackCompletionPolicy.shouldResumeListening(
            after: .failed,
            voiceSessionEnabled: true
        ))
        #expect(!ExplicitSpeechPlaybackCompletionPolicy.shouldResumeListening(
            after: .completed,
            voiceSessionEnabled: false
        ))
        #expect(ExplicitSpeechPlaybackCompletionPolicy.shouldResumeListening(
            after: .completed,
            voiceSessionEnabled: true
        ))
        #expect(ExplicitSpeechPlaybackCompletionPolicy.shouldResumeListening(
            after: .stoppedByUser,
            voiceSessionEnabled: true
        ))

        #expect(ExplicitSpeechPlaybackCompletionPolicy.shouldRecordReadReceipt(after: .completed))
        #expect(!ExplicitSpeechPlaybackCompletionPolicy.shouldRecordReadReceipt(after: .stoppedByUser))
        #expect(!ExplicitSpeechPlaybackCompletionPolicy.shouldRecordReadReceipt(after: .failed))
    }

    @Test func executorSynthesizesAndPlaysEveryChunkInOrderBeforeCompletion() async {
        let chunks = ["Morning", "Midday", "Night"]
        var played: [String] = []
        var intermediateCompletions: [Int] = []

        let outcome = await ExplicitSpeechPlaybackExecutor.run(
            chunks: chunks,
            shouldContinue: { true },
            play: { chunk in
                played.append(chunk)
                return true
            },
            onChunkCompleted: { completed, total in
                #expect(total == 3)
                if completed < total {
                    intermediateCompletions.append(completed)
                    #expect(ExplicitSpeechPlaybackPresentationState.resolve(after: nil) == .init(
                        isReading: true,
                        isMuted: true,
                        isListening: false,
                        canRetry: false
                    ))
                }
            }
        )

        #expect(played == chunks)
        #expect(intermediateCompletions == [1, 2])
        #expect(outcome == .completed)
        #expect(ExplicitSpeechPlaybackCompletionPolicy.shouldRecordReadReceipt(after: outcome))
    }

    @Test func executorStopCancelsLaterChunksAndFailureBecomesRetryableOnlyInSameSession() async {
        let chunks = ["First", "Second", "Third"]
        var played: [String] = []
        var continuationChecks = 0
        let stopped = await ExplicitSpeechPlaybackExecutor.run(
            chunks: chunks,
            shouldContinue: {
                continuationChecks += 1
                return continuationChecks == 1
            },
            play: { chunk in played.append(chunk); return true }
        )
        #expect(stopped == .stoppedByUser)
        #expect(played == ["First"])

        played.removeAll()
        let failed = await ExplicitSpeechPlaybackExecutor.run(
            chunks: chunks,
            shouldContinue: { true },
            play: { chunk in
                played.append(chunk)
                return chunk != "Second"
            }
        )
        #expect(failed == .failed)
        #expect(played == ["First", "Second"])
        #expect(!ExplicitSpeechPlaybackCompletionPolicy.shouldResumeListening(
            after: failed,
            voiceSessionEnabled: true
        ))
        #expect(ExplicitSpeechPlaybackPresentationState.resolve(after: failed) == .init(
            isReading: false,
            isMuted: true,
            isListening: false,
            canRetry: true
        ))

        let context = ExplicitSpeechRetryContext(
            accountID: "account-a",
            gatewayID: "gateway-a",
            sessionKey: "rem-orchestrator",
            localDayKey: "2026-08-07",
            briefKey: "content:night"
        )
        let retry = ExplicitSpeechRetryToken(
            text: chunks.joined(separator: " "),
            context: context,
            generation: 7
        )
        #expect(ExplicitSpeechRetryPolicy.canRetry(
            retry,
            expectedContext: context,
            currentGeneration: 7,
            voiceSessionEnabled: true
        ))
        #expect(!ExplicitSpeechRetryPolicy.canRetry(
            retry,
            expectedContext: nil,
            currentGeneration: 7,
            voiceSessionEnabled: true
        ))
        #expect(!ExplicitSpeechRetryPolicy.canRetry(
            retry,
            expectedContext: context,
            currentGeneration: 8,
            voiceSessionEnabled: true
        ))

        let newerBriefSameSession = ExplicitSpeechRetryContext(
            accountID: context.accountID,
            gatewayID: context.gatewayID,
            sessionKey: context.sessionKey,
            localDayKey: context.localDayKey,
            briefKey: "content:newer-midday"
        )
        #expect(!ExplicitSpeechRetryPolicy.canRetry(
            retry,
            expectedContext: newerBriefSameSession,
            currentGeneration: 7,
            voiceSessionEnabled: true
        ))

        let switchedGateway = ExplicitSpeechRetryContext(
            accountID: context.accountID,
            gatewayID: "gateway-b",
            sessionKey: context.sessionKey,
            localDayKey: context.localDayKey,
            briefKey: context.briefKey
        )
        #expect(!ExplicitSpeechRetryPolicy.canRetry(
            retry,
            expectedContext: switchedGateway,
            currentGeneration: 7,
            voiceSessionEnabled: true
        ))

        let switchedAccount = ExplicitSpeechRetryContext(
            accountID: "account-b",
            gatewayID: context.gatewayID,
            sessionKey: context.sessionKey,
            localDayKey: context.localDayKey,
            briefKey: context.briefKey
        )
        #expect(!ExplicitSpeechRetryPolicy.canRetry(
            retry,
            expectedContext: switchedAccount,
            currentGeneration: 7,
            voiceSessionEnabled: true
        ))
    }

    @Test func retryContextFailsClosedAcrossArtifactGatewaySessionAccountAndRootTeardown() {
        let original = ExplicitSpeechRetryContext(
            accountID: "account-a",
            gatewayID: "gateway-a",
            sessionKey: "rem-orchestrator",
            localDayKey: "2026-08-07",
            briefKey: "content:morning"
        )
        let token = ExplicitSpeechRetryToken(text: "Morning brief", context: original, generation: 3)

        func changing(
            accountID: String? = nil,
            gatewayID: String? = nil,
            sessionKey: String? = nil,
            briefKey: String? = nil
        ) -> ExplicitSpeechRetryContext {
            ExplicitSpeechRetryContext(
                accountID: accountID ?? original.accountID,
                gatewayID: gatewayID ?? original.gatewayID,
                sessionKey: sessionKey ?? original.sessionKey,
                localDayKey: original.localDayKey,
                briefKey: briefKey ?? original.briefKey
            )
        }

        for invalidContext in [
            changing(briefKey: "content:midday"),
            changing(gatewayID: "gateway-b"),
            changing(sessionKey: "another-session"),
            changing(accountID: "account-b"),
        ] {
            #expect(!ExplicitSpeechRetryPolicy.canRetry(
                token,
                expectedContext: invalidContext,
                currentGeneration: 3,
                voiceSessionEnabled: true
            ))
        }

        // A nil session and authenticated-root teardown both remove the expected context entirely.
        #expect(!ExplicitSpeechRetryPolicy.canRetry(
            token,
            expectedContext: nil,
            currentGeneration: 3,
            voiceSessionEnabled: true
        ))
        #expect(!ExplicitSpeechRetryPolicy.canRetry(
            token,
            expectedContext: original,
            currentGeneration: 3,
            voiceSessionEnabled: false
        ))
    }

    @Test func activePlaybackContextChangeCancelsAndCannotRecordReceipt() {
        let original = ExplicitSpeechRetryContext(
            accountID: "account-a",
            gatewayID: "gateway-a",
            sessionKey: "rem-orchestrator",
            localDayKey: "2026-08-07",
            briefKey: "content:morning"
        )
        let gatewayChanged = ExplicitSpeechRetryContext(
            accountID: original.accountID,
            gatewayID: "gateway-b",
            sessionKey: original.sessionKey,
            localDayKey: original.localDayKey,
            briefKey: original.briefKey
        )
        let sessionChanged = ExplicitSpeechRetryContext(
            accountID: original.accountID,
            gatewayID: original.gatewayID,
            sessionKey: "another-session",
            localDayKey: original.localDayKey,
            briefKey: original.briefKey
        )

        for changed in [gatewayChanged, sessionChanged] {
            #expect(ExplicitSpeechPlaybackContextPolicy.shouldCancel(
                expected: original,
                current: changed,
                playbackIsActive: true
            ))
            #expect(!ExplicitSpeechPlaybackContextPolicy.canRecordReceipt(
                expected: original,
                current: changed,
                outcome: .completed
            ))
        }

        #expect(ExplicitSpeechPlaybackContextPolicy.shouldCancel(
            expected: original,
            current: nil,
            playbackIsActive: true
        ))
        #expect(!ExplicitSpeechPlaybackContextPolicy.canRecordReceipt(
            expected: original,
            current: nil,
            outcome: .completed
        ))
        #expect(!ExplicitSpeechPlaybackContextPolicy.canRecordReceipt(
            expected: original,
            current: original,
            outcome: .failed
        ))
        #expect(ExplicitSpeechPlaybackContextPolicy.canRecordReceipt(
            expected: original,
            current: original,
            outcome: .completed
        ))
    }
}

@MainActor
private final class SuspendedBufferedMP3Player: BufferedMP3AudioPlaying {
    private(set) var receivedData: Data?
    private var continuation: CheckedContinuation<StreamingPlaybackResult, Never>?

    func play(data: Data) async -> StreamingPlaybackResult {
        receivedData = data
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() -> Double? {
        continuation?.resume(returning: StreamingPlaybackResult(finished: false, interruptedAt: 0))
        continuation = nil
        return 0
    }

    func waitUntilStarted() async {
        while receivedData == nil || continuation == nil {
            await Task.yield()
        }
    }

    func finishSuccessfully() {
        continuation?.resume(returning: StreamingPlaybackResult(finished: true, interruptedAt: nil))
        continuation = nil
    }
}
