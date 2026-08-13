import Foundation
import OpenClawKit

/// Pure decisions shared by the iOS and macOS next-sentence TTS prefetch pipelines.
///
/// OpenClaw buffers prefetched PCM requests as MP3 before playback. That keeps prefetch network
/// work independent from the single live PCM player while preserving the configured format when
/// the configured format is already stream-bufferable.
enum IncrementalSpeechPrefetchPolicy {
    static let canonicalMP3RequestFormat = "mp3_44100_128"

    static func bufferedOutputFormat(for playbackOutputFormat: String?) -> String? {
        let normalized = playbackOutputFormat?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "mp3" || normalized?.hasPrefix("mp3_") == true ||
            normalized?.hasSuffix("-mp3") == true
        {
            return playbackOutputFormat
        }
        return ElevenLabsTTSClient.validatedOutputFormat(canonicalMP3RequestFormat)
    }

    static func canReuse<Context: Equatable>(
        prefetchedSegment: String,
        prefetchedContext: Context,
        nextSegment: String,
        nextContext: Context
    ) -> Bool {
        prefetchedSegment == nextSegment && prefetchedContext == nextContext
    }
}
