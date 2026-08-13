import Foundation

/// The accepted range for one tunable speech parameter.
///
/// These bounds are not invented here. Each one is enforced upstream immediately
/// before the provider HTTP call — `assertElevenLabsVoiceSettings` in
/// `openclaw/extensions/elevenlabs/tts.ts` calls `requireInRange` with exactly
/// these values, and throws outside them. The gateway's own `resolveTalkSpeed`
/// (`openclaw/src/gateway/server-methods/talk.ts`) uses the same 0.5...2.0 speed
/// window. Clamping here turns an out-of-range value into an impossible UI state
/// instead of a synthesis failure the user sees as "voice didn't work".
struct VoiceTuningRange: Equatable, Sendable {
    let lowerBound: Double
    let upperBound: Double
    let defaultValue: Double

    func clamped(_ value: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }

    /// `talk.speak` `speed`. Consumed by every speech provider that implements
    /// `resolveTalkOverrides`, so this is the one control that is meaningful
    /// regardless of which provider the gateway has active.
    static let speed = VoiceTuningRange(lowerBound: 0.5, upperBound: 2.0, defaultValue: 1.0)

    /// `talk.speak` `stability` → ElevenLabs `voiceSettings.stability`.
    static let stability = VoiceTuningRange(lowerBound: 0, upperBound: 1, defaultValue: 0.5)

    /// `talk.speak` `similarity` → ElevenLabs `voiceSettings.similarityBoost`.
    static let similarity = VoiceTuningRange(lowerBound: 0, upperBound: 1, defaultValue: 0.75)
}

/// User-chosen speech parameters applied to Rem's spoken responses.
///
/// Every field is a parameter the gateway's `talk.speak` RPC accepts *and* the
/// active speech provider actually consumes. Nothing is stored here that the TTS
/// path would silently drop.
///
/// Fields are optional on purpose: `nil` means "the agent decides". An unset value
/// is omitted from the request rather than sent as our idea of the default, so a
/// gateway configured with its own `talk.providers.<provider>.voiceSettings` is
/// never clobbered by a control the user has not touched.
struct VoiceTuningSettings: Equatable, Sendable {
    var speed: Double?
    var stability: Double?
    var similarity: Double?

    init(speed: Double? = nil, stability: Double? = nil, similarity: Double? = nil) {
        self.speed = speed.map(VoiceTuningRange.speed.clamped)
        self.stability = stability.map(VoiceTuningRange.stability.clamped)
        self.similarity = similarity.map(VoiceTuningRange.similarity.clamped)
    }

    /// Nothing overridden — the gateway's own configuration applies unchanged.
    static let agentDefaults = VoiceTuningSettings()

    var hasOverrides: Bool {
        speed != nil || stability != nil || similarity != nil
    }
}

/// Persistence for `VoiceTuningSettings`, mirroring `TaskRuntimeSettingsStore`.
///
/// Device-local (UserDefaults) rather than gateway config, deliberately. Writing
/// these to the gateway would mean a `config.patch` per change, and every Talk
/// config patch queues a gateway restart (see the save path in
/// `SharedVoiceSettingsView`, which polls for ~20s afterwards). That is correct
/// for picking a voice — a rare, deliberate choice — and unusable for a slider.
/// Sending the values as `talk.speak` parameters instead applies them to the very
/// next utterance with no restart, and is the path the provider actually reads:
/// ElevenLabs' `resolveTalkOverrides` reads `params` only, never the stored
/// provider config.
enum VoiceTuningStore {
    /// Documented so other lanes can read the same keys.
    static let speedDefaultsKey = "rem.voice.tuning.speed"
    static let stabilityDefaultsKey = "rem.voice.tuning.stability"
    static let similarityDefaultsKey = "rem.voice.tuning.similarity"

    static var settings: VoiceTuningSettings {
        get { settings(from: .standard) }
        set { write(newValue, to: .standard) }
    }

    /// Testable seam. `object(forKey:)` rather than `double(forKey:)` because the
    /// latter reports a missing key as `0`, which is a legal value for two of
    /// these parameters and would read as "user set it to zero".
    static func settings(from defaults: UserDefaults) -> VoiceTuningSettings {
        VoiceTuningSettings(
            speed: defaults.object(forKey: speedDefaultsKey) as? Double,
            stability: defaults.object(forKey: stabilityDefaultsKey) as? Double,
            similarity: defaults.object(forKey: similarityDefaultsKey) as? Double
        )
    }

    static func write(_ settings: VoiceTuningSettings, to defaults: UserDefaults) {
        set(settings.speed, forKey: speedDefaultsKey, in: defaults)
        set(settings.stability, forKey: stabilityDefaultsKey, in: defaults)
        set(settings.similarity, forKey: similarityDefaultsKey, in: defaults)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        write(.agentDefaults, to: defaults)
    }

    private static func set(_ value: Double?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Which tuning controls are meaningful for the gateway's active speech provider.
///
/// Provider plugins decide what a `talk.speak` parameter turns into. The
/// OpenAI-compatible providers' `resolveTalkOverrides`
/// (`openclaw/src/tts/openai-compatible-speech-provider.ts`) maps only
/// voiceId/modelId/**speed** and drops the rest; ElevenLabs'
/// (`openclaw/extensions/elevenlabs/speech-provider.ts`) additionally maps
/// stability/similarity/style/speakerBoost into `voiceSettings`. Showing a
/// stability slider against an OpenAI-compatible provider would be a control that
/// changes nothing, so it is hidden rather than shipped inert.
enum VoiceTuningProviderSupport {
    static func supportsVoiceCharacter(providerID: String?) -> Bool {
        guard let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty
        else { return false }
        return providerID.caseInsensitiveCompare("elevenlabs") == .orderedSame
    }
}

extension GatewayTalkSpeechRequest {
    /// Fills speech parameters the caller left unset from the user's Voice settings.
    ///
    /// Precedence deliberately favours the directive. A `[[tts:...]]` directive is a
    /// per-utterance choice the agent made on purpose (reading a line slowly, say);
    /// the user's setting is the standing default for everything else. This mirrors
    /// the existing `directive?.voiceId ?? currentVoiceId ?? defaultVoiceId` chain
    /// rather than inventing a second precedence rule.
    ///
    /// Parameters that stay `nil` are omitted from the encoded params, so an
    /// untouched control leaves the gateway's own configuration in charge.
    func applyingTuning(_ tuning: VoiceTuningSettings) -> GatewayTalkSpeechRequest {
        var tuned = self
        tuned.speed = speed ?? tuning.speed
        tuned.stability = stability ?? tuning.stability
        tuned.similarity = similarity ?? tuning.similarity
        return tuned
    }
}
