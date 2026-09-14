import CoreGraphics

/// Resolves the bottom inset reserved beneath the chat transcript so the last message can always
/// scroll clear of the pinned bottom controls (composer + optional browser card + voice bar).
///
/// The controls are overlaid on the transcript in a `ZStack`, so the transcript must reserve an
/// equal amount of bottom space itself. `SharedRemChatView` measures the real laid-out control
/// height via a `GeometryReader` and passes it here; because that measurement covers the *current*
/// composer (which grows with multi-line input and the voice bar), a grown composer no longer tucks
/// the final message behind itself. Before the first measurement lands the resolver falls back to a
/// fixed estimate so the very first frame still reserves roughly the right amount.
///
/// Pure and free of view/UIKit dependencies so it is testable in isolation — mirrors the other chat
/// resolvers (`ChatEmptyStateGate`, `SessionsListViewStateResolver`).
enum ChatTranscriptInsetResolver {
    /// Fixed fallbacks used only until the live measurement arrives.
    static let fallbackComposerHeight: CGFloat = 116
    static let fallbackVoiceComposerHeight: CGFloat = 168
    static let fallbackBrowserCardHeight: CGFloat = 72

    static func resolve(
        measuredBottomControlsHeight: CGFloat,
        isVoiceModeActive: Bool,
        browserLiveHere: Bool,
        gap: CGFloat
    ) -> CGFloat {
        // Prefer the live-measured height of the whole bottom-controls stack. It already includes
        // the browser card and voice bar (they live inside the same stack), so no per-element
        // addition is needed. A small gap keeps the last message off the composer's top edge.
        if measuredBottomControlsHeight > 0 {
            return measuredBottomControlsHeight + gap
        }
        var inset = isVoiceModeActive ? fallbackVoiceComposerHeight : fallbackComposerHeight
        if browserLiveHere { inset += fallbackBrowserCardHeight }
        return inset
    }
}
