import AVFAudio
import Foundation
import OpenClawKit

@MainActor
protocol BufferedMP3AudioPlaying {
    func play(data: Data) async -> StreamingPlaybackResult
    func stop() -> Double?
}

enum BufferedMP3WatchdogPolicy {
    enum Decision: Equatable {
        case keepMonitoring
        case completed
        case failed
    }

    /// A genuinely playing asset has no duration ceiling. Recovery is based only on audible-clock
    /// progress: a missing delegate callback at the natural end is completed, while a player whose
    /// clock has not advanced for this interval is considered stalled.
    static let stallTimeout: TimeInterval = 15

    static func decision(
        isPlaying: Bool,
        currentTime: TimeInterval,
        duration: TimeInterval,
        secondsWithoutProgress: TimeInterval
    ) -> Decision {
        if isPlaying {
            return secondsWithoutProgress >= stallTimeout ? .failed : .keepMonitoring
        }
        guard duration > 0 else { return .failed }
        let completionTolerance = max(0.1, min(0.5, duration * 0.02))
        return currentTime >= duration - completionTolerance ? .completed : .failed
    }
}

/// Plays a complete gateway MP3 as one immutable asset on iOS and macOS.
///
/// Gateway `talk.speak` returns a fully buffered MP3, so feeding that payload through the
/// incremental AudioFileStream/AudioQueue player only adds a lossy packet-buffer boundary. An
/// `AVAudioPlayer` owns the complete asset and its delegate completion means the audible file has
/// drained, which is the completion boundary ordered Talk playback needs.
/// Mirrors upstream macOS `TalkAudioPlayer`, including its once-only completion and watchdog.
@MainActor
final class BufferedMP3AudioPlayer: NSObject, BufferedMP3AudioPlaying,
    @preconcurrency AVAudioPlayerDelegate {
    static let shared = BufferedMP3AudioPlayer()

    private var player: AVAudioPlayer?
    private var playback: Playback?

    private final class Playback: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<StreamingPlaybackResult, Never>?
        private var watchdog: Task<Void, Never>?

        func setContinuation(_ continuation: CheckedContinuation<StreamingPlaybackResult, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func setWatchdog(_ task: Task<Void, Never>?) {
            lock.lock()
            let old = watchdog
            watchdog = task
            lock.unlock()
            old?.cancel()
        }

        func finish(_ result: StreamingPlaybackResult) {
            let continuation: CheckedContinuation<StreamingPlaybackResult, Never>?
            lock.lock()
            if finished {
                continuation = nil
            } else {
                finished = true
                continuation = self.continuation
                self.continuation = nil
            }
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    func play(data: Data) async -> StreamingPlaybackResult {
        stopInternal()
        let playback = Playback()
        self.playback = playback

        return await withCheckedContinuation { continuation in
            playback.setContinuation(continuation)
            do {
                let player = try AVAudioPlayer(data: data)
                self.player = player
                player.delegate = self
                player.prepareToPlay()
                armWatchdog(playback: playback)
                guard player.play() else {
                    finish(
                        playback: playback,
                        result: StreamingPlaybackResult(finished: false, interruptedAt: nil))
                    return
                }
            } catch {
                finish(
                    playback: playback,
                    result: StreamingPlaybackResult(finished: false, interruptedAt: nil))
            }
        }
    }

    func stop() -> Double? {
        guard let player else { return nil }
        let interruptedAt = player.currentTime
        stopInternal(interruptedAt: interruptedAt)
        return interruptedAt
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        stopInternal(finished: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
        guard self.player === player else { return }
        stopInternal(interruptedAt: player.currentTime)
    }

    private func stopInternal(finished: Bool = false, interruptedAt: Double? = nil) {
        guard let playback else { return }
        finish(
            playback: playback,
            result: StreamingPlaybackResult(finished: finished, interruptedAt: interruptedAt))
    }

    private func stopInternal() {
        if let playback {
            finish(
                playback: playback,
                result: StreamingPlaybackResult(
                    finished: false,
                    interruptedAt: player?.currentTime))
            return
        }
        player?.stop()
        player = nil
    }

    private func finish(playback: Playback, result: StreamingPlaybackResult) {
        playback.setWatchdog(nil)
        playback.finish(result)
        guard self.playback === playback else { return }
        self.playback = nil
        player?.delegate = nil
        player?.stop()
        player = nil
    }

    private func armWatchdog(playback: Playback) {
        playback.setWatchdog(Task { @MainActor [weak self] in
            guard let self else { return }
            var lastPlayerTime = self.player?.currentTime ?? 0
            var lastProgressUptime = ProcessInfo.processInfo.systemUptime

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard self.playback === playback, let player = self.player else { return }

                let currentTime = player.currentTime
                let now = ProcessInfo.processInfo.systemUptime
                if currentTime > lastPlayerTime + 0.01 {
                    lastPlayerTime = currentTime
                    lastProgressUptime = now
                }
                let decision = BufferedMP3WatchdogPolicy.decision(
                    isPlaying: player.isPlaying,
                    currentTime: currentTime,
                    duration: player.duration,
                    secondsWithoutProgress: now - lastProgressUptime)
                switch decision {
                case .keepMonitoring:
                    continue
                case .completed:
                    self.finish(
                        playback: playback,
                        result: StreamingPlaybackResult(finished: true, interruptedAt: nil))
                    return
                case .failed:
                    self.finish(
                        playback: playback,
                        result: StreamingPlaybackResult(
                            finished: false,
                            interruptedAt: currentTime))
                    return
                }
            }
        })
    }
}
