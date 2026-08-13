import Foundation
import Testing
@testable import RemClaw

/// Tests for `VoiceSpeechActivity` — the pure "is TTS output active?" decision that the voice
/// inactivity monitor (`RemTalkModeManager.checkInactivity`) consults before advancing the 5-min
/// idle auto-close clock.
///
/// Root cause this guards (founder report: voice bar hung well past 5 min): the incremental-speech
/// flags (`incrementalSpeechActive` / task / queue) are cleared only when a chat run reports `final`
/// (via `finishIncrementalSpeech`). When `final` never fires — a stream error, an abnormally-ended
/// turn, the #1092 race — the flags stayed set forever, so `isSpeechOutputActive` returned `true` on
/// every 2s inactivity poll, `lastAudioActivity` was re-armed each time, `idle` never grew, and the
/// 300s auto-close was NEVER reached.
///
/// The fix makes pending-but-silent speech time out (`staleWindow`) so the idle clock can advance,
/// while genuinely-playing audio (`isSpeaking`) short-circuits `true` so an active reply is never
/// clipped. These tests pin both halves of that contract.
struct VoiceSpeechActivityTests {

    private let window: TimeInterval = 8
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: - Active speech is never clipped

    /// Genuinely playing audio is always active, regardless of the staleness clock. This is the
    /// guarantee that a real, still-playing multi-sentence reply keeps the session alive.
    @Test func speakingIsAlwaysActiveEvenWithAncientProgress() {
        let active = VoiceSpeechActivity.isActive(
            isSpeaking: true,
            hasPendingSpeech: true,
            lastProgress: now.addingTimeInterval(-3600), // an hour ago — irrelevant while speaking
            now: now,
            staleWindow: window)
        #expect(active == true)
    }

    /// A reply that just queued/played a segment (progress within the window) stays active — the
    /// normal inter-segment gap where the task momentarily isn't `isSpeaking` must NOT read as idle.
    @Test func recentProgressKeepsPendingSpeechActive() {
        let active = VoiceSpeechActivity.isActive(
            isSpeaking: false,
            hasPendingSpeech: true,
            lastProgress: now.addingTimeInterval(-2), // 2s ago, inside the 8s window
            now: now,
            staleWindow: window)
        #expect(active == true)
    }

    // MARK: - The stuck-flag path: run ends without `final`

    /// The bug: `incrementalSpeechActive` is stuck `true` but nothing has actually played for longer
    /// than the window. Output must read INACTIVE so the idle clock can finally advance.
    @Test func stuckFlagWithStaleProgressReadsInactive() {
        let active = VoiceSpeechActivity.isActive(
            isSpeaking: false,
            hasPendingSpeech: true,
            lastProgress: now.addingTimeInterval(-30), // 30s of silence — the flag is stuck
            now: now,
            staleWindow: window)
        #expect(active == false)
    }

    /// End-to-end at the pure-logic layer: a run that ends without `final` leaves the flag set but no
    /// progress; once the staleness window elapses, `isSpeechOutputActive` flips to `false`, which is
    /// exactly what lets `checkInactivity` stop re-arming `lastAudioActivity` so `idle` grows to 300s.
    @Test func idleClockCanAdvanceAfterStuckFlagGoesStale() {
        let runEndedWithoutFinal = now // flag set, last progress = now, nothing playing
        // Just after the run stalls: still considered active (within window) — no premature idle.
        #expect(VoiceSpeechActivity.isActive(
            isSpeaking: false, hasPendingSpeech: true,
            lastProgress: runEndedWithoutFinal,
            now: runEndedWithoutFinal.addingTimeInterval(5),
            staleWindow: window) == true)
        // Past the window: inactive → the inactivity monitor's `idle` clock is free to advance and,
        // after voiceIdleTimeout (300s), reach the auto-close.
        #expect(VoiceSpeechActivity.isActive(
            isSpeaking: false, hasPendingSpeech: true,
            lastProgress: runEndedWithoutFinal,
            now: runEndedWithoutFinal.addingTimeInterval(window + 1),
            staleWindow: window) == false)
    }

    // MARK: - No pending speech at all

    /// No flags set and not speaking → definitively inactive.
    @Test func noPendingSpeechIsInactive() {
        #expect(VoiceSpeechActivity.isActive(
            isSpeaking: false, hasPendingSpeech: false,
            lastProgress: now, now: now, staleWindow: window) == false)
    }

    /// Flags set but no progress timestamp ever recorded (a leftover flag with no real speech) is
    /// treated as inactive — a stuck flag must never pin the clock just because a boolean is `true`.
    @Test func pendingSpeechWithoutProgressTimestampIsInactive() {
        #expect(VoiceSpeechActivity.isActive(
            isSpeaking: false, hasPendingSpeech: true,
            lastProgress: nil, now: now, staleWindow: window) == false)
    }

    /// Boundary: exactly at the window is treated as stale (not active) — `< staleWindow` is strict.
    @Test func progressExactlyAtWindowIsInactive() {
        #expect(VoiceSpeechActivity.isActive(
            isSpeaking: false, hasPendingSpeech: true,
            lastProgress: now.addingTimeInterval(-window),
            now: now, staleWindow: window) == false)
    }

    // MARK: - Streaming-but-no-boundary-yet turn must stay active across a >8s window (Defect 1)

    /// A still-generating reply streams many assistant deltas before its first sentence boundary
    /// (slow first sentence / long reasoning / slow synthesis), so NO audio is queued and
    /// `isSpeaking` is `false` for well over the stale window. Because `streamAssistant` now stamps
    /// progress on EVERY delta (not only on a boundary enqueue), each delta keeps the turn ACTIVE.
    /// This is the composer-path regression the fix targets: the session must NOT auto-close while
    /// the model is still producing the reply. Simulate deltas every 2s over a 14s span (> the 8s
    /// window) and assert the turn reads active at each delta and in the sub-window gaps between them.
    @Test func streamingWithoutBoundaryStaysActiveAcrossLongWindow() {
        let turnStart = now
        // Deltas arrive at t = 0, 2, 4, …, 14 — none crossing a sentence boundary, so no audio yet.
        for deltaOffset in stride(from: 0.0, through: 14.0, by: 2.0) {
            let lastDelta = turnStart.addingTimeInterval(deltaOffset)
            // Checked the instant the delta lands (progress just stamped).
            #expect(VoiceSpeechActivity.isActive(
                isSpeaking: false, hasPendingSpeech: true,
                lastProgress: lastDelta, now: lastDelta, staleWindow: window) == true)
            // Checked 1s later, still before the next delta and well inside the window.
            #expect(VoiceSpeechActivity.isActive(
                isSpeaking: false, hasPendingSpeech: true,
                lastProgress: lastDelta, now: lastDelta.addingTimeInterval(1),
                staleWindow: window) == true)
        }
    }

    /// The reverse path still holds: once deltas STOP (reply finished producing) and no audio is
    /// playing, progress goes stale after the window and the turn reads inactive — so the idle clock
    /// can advance to the 300s auto-close. Guards that the per-delta stamp did not re-pin the flag.
    @Test func streamStopsThenGoesInactiveAfterWindow() {
        let lastDelta = now
        // Just after the last delta: still active.
        #expect(VoiceSpeechActivity.isActive(
            isSpeaking: false, hasPendingSpeech: true,
            lastProgress: lastDelta, now: lastDelta.addingTimeInterval(window - 1),
            staleWindow: window) == true)
        // Past the window with no further deltas and nothing playing: inactive → idle clock advances.
        #expect(VoiceSpeechActivity.isActive(
            isSpeaking: false, hasPendingSpeech: true,
            lastProgress: lastDelta, now: lastDelta.addingTimeInterval(window + 1),
            staleWindow: window) == false)
    }
}
