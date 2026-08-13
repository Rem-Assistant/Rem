import Foundation
import Testing
@testable import RemClaw

struct VoiceTuningSettingsTests {
    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Storage

    @Test func unsetSettingsSendNothing() {
        let settings = VoiceTuningStore.settings(from: makeDefaults())
        #expect(settings == .agentDefaults)
        #expect(settings.speed == nil)
        #expect(settings.stability == nil)
        #expect(settings.similarity == nil)
        #expect(!settings.hasOverrides)
    }

    @Test func settingsRoundTripThroughDefaults() {
        let defaults = makeDefaults()
        VoiceTuningStore.write(
            VoiceTuningSettings(speed: 1.35, stability: 0.2, similarity: 0.9),
            to: defaults
        )
        let restored = VoiceTuningStore.settings(from: defaults)
        #expect(restored.speed == 1.35)
        #expect(restored.stability == 0.2)
        #expect(restored.similarity == 0.9)
        #expect(restored.hasOverrides)
    }

    /// `UserDefaults.double(forKey:)` reports a missing key as `0`, which is a legal
    /// value for stability and likeness. A stored zero must stay distinguishable
    /// from "never set", or resetting would be impossible to represent.
    @Test func storedZeroIsDistinctFromUnset() {
        let defaults = makeDefaults()
        VoiceTuningStore.write(VoiceTuningSettings(stability: 0), to: defaults)
        let restored = VoiceTuningStore.settings(from: defaults)
        #expect(restored.stability == 0)
        #expect(restored.hasOverrides)
        #expect(restored.speed == nil)
    }

    @Test func resetClearsEveryOverride() {
        let defaults = makeDefaults()
        VoiceTuningStore.write(
            VoiceTuningSettings(speed: 1.8, stability: 0.1, similarity: 0.4),
            to: defaults
        )
        VoiceTuningStore.reset(in: defaults)
        #expect(VoiceTuningStore.settings(from: defaults) == .agentDefaults)
    }

    // MARK: - Ranges

    /// Bounds must match what the provider enforces immediately before the HTTP
    /// call (`assertElevenLabsVoiceSettings` → `requireInRange`). Out-of-range
    /// values throw there, so clamping is what keeps a slider from producing a
    /// synthesis failure.
    @Test func valuesClampToTheRangeTheProviderAccepts() {
        let tooFast = VoiceTuningSettings(speed: 9, stability: 5, similarity: -3)
        #expect(tooFast.speed == 2.0)
        #expect(tooFast.stability == 1.0)
        #expect(tooFast.similarity == 0.0)

        let tooSlow = VoiceTuningSettings(speed: 0.1)
        #expect(tooSlow.speed == 0.5)
    }

    @Test func rangeDefaultsMatchUpstreamProviderDefaults() {
        #expect(VoiceTuningRange.speed.defaultValue == 1.0)
        #expect(VoiceTuningRange.stability.defaultValue == 0.5)
        #expect(VoiceTuningRange.similarity.defaultValue == 0.75)
        #expect(VoiceTuningRange.speed.lowerBound == 0.5)
        #expect(VoiceTuningRange.speed.upperBound == 2.0)
    }

    // MARK: - Provider gating

    @Test func onlyElevenLabsConsumesCharacterParameters() {
        #expect(VoiceTuningProviderSupport.supportsVoiceCharacter(providerID: "elevenlabs"))
        #expect(VoiceTuningProviderSupport.supportsVoiceCharacter(providerID: "ElevenLabs"))
        #expect(!VoiceTuningProviderSupport.supportsVoiceCharacter(providerID: "openai"))
        #expect(!VoiceTuningProviderSupport.supportsVoiceCharacter(providerID: "  "))
        #expect(!VoiceTuningProviderSupport.supportsVoiceCharacter(providerID: nil))
    }

    // MARK: - Request merge (the path the value actually travels)

    @Test func tuningFillsParametersTheDirectiveLeftUnset() {
        let request = GatewayTalkSpeechRequest(text: "hello")
            .applyingTuning(VoiceTuningSettings(speed: 1.25, stability: 0.3, similarity: 0.8))
        #expect(request.speed == 1.25)
        #expect(request.stability == 0.3)
        #expect(request.similarity == 0.8)
    }

    /// An explicit `[[tts:...]]` directive is a deliberate per-utterance choice by
    /// the agent and must outrank the standing user preference, matching the
    /// existing voiceId precedence chain.
    @Test func directiveValuesOutrankTheUserSetting() {
        let request = GatewayTalkSpeechRequest(
            text: "hello",
            speed: 0.75,
            stability: 0.1
        )
        .applyingTuning(VoiceTuningSettings(speed: 1.25, stability: 0.3, similarity: 0.8))

        #expect(request.speed == 0.75)
        #expect(request.stability == 0.1)
        // Untouched by the directive, so the user's setting still applies.
        #expect(request.similarity == 0.8)
    }

    @Test func agentDefaultsLeaveTheRequestUntouched() {
        let request = GatewayTalkSpeechRequest(text: "hello")
            .applyingTuning(.agentDefaults)
        #expect(request.speed == nil)
        #expect(request.stability == nil)
        #expect(request.similarity == nil)
    }

    /// Unset parameters must be absent from the wire payload, not sent as nulls or
    /// as our idea of the default — the gateway's own configuration decides.
    @Test func unsetParametersAreOmittedFromEncodedParams() throws {
        let request = GatewayTalkSpeechRequest(text: "hello").applyingTuning(.agentDefaults)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any]
        #expect(json?["speed"] == nil)
        #expect(json?["stability"] == nil)
        #expect(json?["similarity"] == nil)

        let tuned = GatewayTalkSpeechRequest(text: "hello")
            .applyingTuning(VoiceTuningSettings(speed: 1.5))
        let tunedJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(tuned)
        ) as? [String: Any]
        #expect(tunedJSON?["speed"] as? Double == 1.5)
        #expect(tunedJSON?["stability"] == nil)
    }
}
