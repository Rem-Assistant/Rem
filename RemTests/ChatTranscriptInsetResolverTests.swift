import CoreGraphics
import Testing
@testable import Rem

struct ChatTranscriptInsetResolverTests {
    // MARK: - Measured height wins

    @Test func measuredHeightPlusGapWhenAvailable() {
        let inset = ChatTranscriptInsetResolver.resolve(
            measuredBottomControlsHeight: 240,
            isVoiceModeActive: false,
            browserLiveHere: false,
            gap: 12
        )
        #expect(inset == 252)
    }

    @Test func measuredHeightIgnoresFixedVoiceAndBrowserAdditions() {
        // The measured stack already contains the voice bar and browser card, so the fixed
        // per-element additions must NOT be layered on top of a real measurement.
        let inset = ChatTranscriptInsetResolver.resolve(
            measuredBottomControlsHeight: 300,
            isVoiceModeActive: true,
            browserLiveHere: true,
            gap: 12
        )
        #expect(inset == 312)
    }

    @Test func aGrownComposerReservesMoreThanTheFixedFallback() {
        // Regression for the reported bug: once the composer grew past the old 116pt estimate, the
        // fixed inset under-reserved and hid content. A live measurement must track the growth.
        let grown = ChatTranscriptInsetResolver.resolve(
            measuredBottomControlsHeight: 200,
            isVoiceModeActive: false,
            browserLiveHere: false,
            gap: 12
        )
        #expect(grown > ChatTranscriptInsetResolver.fallbackComposerHeight)
    }

    // MARK: - Fixed fallback before first measurement

    @Test func fallbackComposerHeightWhenUnmeasured() {
        let inset = ChatTranscriptInsetResolver.resolve(
            measuredBottomControlsHeight: 0,
            isVoiceModeActive: false,
            browserLiveHere: false,
            gap: 12
        )
        #expect(inset == ChatTranscriptInsetResolver.fallbackComposerHeight)
    }

    @Test func fallbackVoiceHeightWhenUnmeasured() {
        let inset = ChatTranscriptInsetResolver.resolve(
            measuredBottomControlsHeight: 0,
            isVoiceModeActive: true,
            browserLiveHere: false,
            gap: 12
        )
        #expect(inset == ChatTranscriptInsetResolver.fallbackVoiceComposerHeight)
    }

    @Test func fallbackAddsBrowserCardWhenUnmeasured() {
        let inset = ChatTranscriptInsetResolver.resolve(
            measuredBottomControlsHeight: 0,
            isVoiceModeActive: false,
            browserLiveHere: true,
            gap: 12
        )
        #expect(inset == ChatTranscriptInsetResolver.fallbackComposerHeight
            + ChatTranscriptInsetResolver.fallbackBrowserCardHeight)
    }

    @Test func negativeOrZeroMeasurementFallsBack() {
        let inset = ChatTranscriptInsetResolver.resolve(
            measuredBottomControlsHeight: -5,
            isVoiceModeActive: false,
            browserLiveHere: false,
            gap: 12
        )
        #expect(inset == ChatTranscriptInsetResolver.fallbackComposerHeight)
    }
}
