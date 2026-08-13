import Foundation
import Testing
@testable import RemClaw

struct BufferedMP3WatchdogPolicyTests {
    @Test func progressingPlaybackHasNoFiveMinuteCeiling() {
        #expect(BufferedMP3WatchdogPolicy.decision(
            isPlaying: true,
            currentTime: 5 * 60,
            duration: 12 * 60,
            secondsWithoutProgress: 0
        ) == .keepMonitoring)
        #expect(BufferedMP3WatchdogPolicy.decision(
            isPlaying: true,
            currentTime: 11 * 60,
            duration: 12 * 60,
            secondsWithoutProgress: 1
        ) == .keepMonitoring)
    }

    @Test func missingDelegateAtNaturalDurationCompletesSuccessfully() {
        #expect(BufferedMP3WatchdogPolicy.decision(
            isPlaying: false,
            currentTime: 719.8,
            duration: 720,
            secondsWithoutProgress: 1
        ) == .completed)
    }

    @Test func stoppedEarlyOrNonAdvancingPlaybackFailsSafely() {
        #expect(BufferedMP3WatchdogPolicy.decision(
            isPlaying: false,
            currentTime: 120,
            duration: 720,
            secondsWithoutProgress: 1
        ) == .failed)
        #expect(BufferedMP3WatchdogPolicy.decision(
            isPlaying: true,
            currentTime: 120,
            duration: 720,
            secondsWithoutProgress: BufferedMP3WatchdogPolicy.stallTimeout
        ) == .failed)
    }
}
