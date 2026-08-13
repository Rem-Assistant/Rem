import Foundation

/// Input mode for Mac voice capture (#321 PR 3).
///
/// Mac-only for now — iOS `RemTalkModeManager` is VAD-only and has no PTT path.
/// Adding this to Mac first gives us the lighter-weight "hold to speak" UX that
/// Mac users expect from voice desktop apps (Slack huddles, Discord, etc.) and
/// avoids the silence-timer roundtrip.
///
/// Source of truth: `UserDefaults.standard` keyed under `VoiceInputMode.storageKey`
/// (`rem.voice.mode`). Read/written via `VoiceInputMode.stored` / `store()` —
/// those are the only two touch points on disk. `RemMacTalkModeManager` owns
/// the in-memory copy and re-reads on lifecycle start.
enum VoiceInputMode: String, CaseIterable, Equatable {
    /// Voice-activity-detection — existing behavior. Capture while listening;
    /// send after 1.5s of silence post-utterance.
    case vad

    /// Push-to-talk — user holds a key (spacebar) to capture; release sends
    /// immediately, bypassing the silence timer.
    case pushToTalk

    // MARK: - Persistence
    //
    // UserDefaults per-user storage (per #321 PR 3 locked design #3). Keyed
    // under `rem.voice.mode`; values are the raw strings of the enum
    // (`vad` / `pushToTalk`). Unknown values fall back to `.vad` so an old
    // build's value can never brick a fresh build.

    static let storageKey = "rem.voice.mode"
    static let defaultMode: VoiceInputMode = .vad

    static var stored: VoiceInputMode {
        guard let raw = UserDefaults.standard.string(forKey: Self.storageKey),
              let mode = VoiceInputMode(rawValue: raw) else {
            return Self.defaultMode
        }
        return mode
    }

    /// Persists the chosen mode. Called from the mini-bar toggle.
    func store() {
        UserDefaults.standard.set(self.rawValue, forKey: Self.storageKey)
    }
}
