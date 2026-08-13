import Foundation
import Testing
@testable import RemClaw

struct IncrementalSpeechPrefetchPolicyTests {
    @Test func pcmPlaybackPrefetchesAsBufferedMP3() {
        #expect(IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(for: "pcm_44100") == "mp3_44100_128")
    }

    @Test func existingCompressedFormatIsPreserved() {
        #expect(
            IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(for: "mp3_22050_32") ==
                "mp3_22050_32")
    }

    @Test func missingOrNonMP3FormatsRequestCanonicalBufferedMP3() {
        #expect(
            IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(for: nil) ==
                "mp3_44100_128")
        #expect(
            IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(for: "wav") ==
                "mp3_44100_128")
        #expect(
            IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(for: "opus") ==
                "mp3_44100_128")
    }

    @Test func reuseRequiresExactSegmentAndContext() {
        struct Context: Equatable {
            let voice: String
            let speed: Double
        }
        let original = Context(voice: "rem", speed: 1)

        #expect(IncrementalSpeechPrefetchPolicy.canReuse(
            prefetchedSegment: "Second sentence.",
            prefetchedContext: original,
            nextSegment: "Second sentence.",
            nextContext: original))
        #expect(!IncrementalSpeechPrefetchPolicy.canReuse(
            prefetchedSegment: "Second sentence.",
            prefetchedContext: original,
            nextSegment: "Different sentence.",
            nextContext: original))
        #expect(!IncrementalSpeechPrefetchPolicy.canReuse(
            prefetchedSegment: "Second sentence.",
            prefetchedContext: original,
            nextSegment: "Second sentence.",
            nextContext: Context(voice: "rem", speed: 1.2)))
    }

    @Test func bothVoiceManagersWirePrefetchCancellationAndCompletionBackedPlayback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "RemClaw/Sources/Voice/RemTalkModeManager.swift",
            "RemClawMac/Sources/Voice/RemMacTalkModeManager.swift",
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8)
            #expect(source.contains("startIncrementalPrefetchMonitor(context:"))
            #expect(source.contains("consumeIncrementalPrefetchedAudioIfAvailable("))
            #expect(source.contains("cancelIncrementalPrefetch()"))
            #expect(source.contains("IncrementalSpeechPrefetchPolicy.bufferedOutputFormat("))
            let incrementalPlayback = try #require(
                source.range(of: "private func speakIncrementalSegment(")
                    .flatMap { start in
                        source.range(of: "// MARK: - Config loading", range: start.lowerBound..<source.endIndex)
                            .map { source[start.lowerBound..<$0.lowerBound] }
                    }
            )
            #expect(incrementalPlayback.contains(
                "let result = await self.bufferedMP3Player.play(data: data)"))
            #expect(!source.contains("mp3Player.play("))
        }
    }

    @Test func iOSIncrementalPlaybackRevalidatesAuthorityAfterAudibleCompletion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "RemClaw/Sources/Voice/RemTalkModeManager.swift"),
            encoding: .utf8)
        let function = try #require(
            source.range(of: "private func speakIncrementalSegment(")
                .flatMap { start in
                    source.range(of: "// MARK: - Config loading", range: start.lowerBound..<source.endIndex)
                        .map { source[start.lowerBound..<$0.lowerBound] }
                }
        )
        let playback = try #require(function.range(of:
            "let result = await self.bufferedMP3Player.play(data: data)"))
        let postAwaitGuard = try #require(function.range(
            of: "guard Self.incrementalTaskCanMutate(",
            range: playback.upperBound..<function.endIndex))
        let interruptionMutation = try #require(function.range(
            of: "self.lastInterruptedAtSeconds = interruptedAt",
            range: playback.upperBound..<function.endIndex))

        #expect(postAwaitGuard.lowerBound < interruptionMutation.lowerBound)
    }
}
