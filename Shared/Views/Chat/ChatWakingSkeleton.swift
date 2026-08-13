import SwiftUI

/// The "waking up" placeholder shown in the transcript while the gateway connects — replaces the
/// bare `ProgressView` spinner. It mocks a back-and-forth conversation as grey skeleton bubbles
/// with a shimmer sweeping across them, so a cold/waking gateway reads as "Rem is coming up" rather
/// than "nothing is happening."
///
/// Both sides are grey on purpose: the real user bubble is brand-blue, so a blue skeleton would
/// look like a real (but empty) sent message. Grey on both sides reads unambiguously as a
/// placeholder. Paired with the `RemContextualMessage` + disabled composer above the input.
struct ChatWakingSkeleton: View {
    /// (isFromUser, line width fractions) — a plausible-looking alternating exchange.
    private let rows: [(fromUser: Bool, widths: [CGFloat])] = [
        (false, [0.72, 0.50]),
        (true,  [0.44]),
        (false, [0.80, 0.66, 0.42]),
        (true,  [0.55, 0.34]),
        (false, [0.60]),
    ]

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                bubble(fromUser: row.fromUser, widths: row.widths)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, DesignTokens.Spacing.lg)
        .shimmering()
        // Decorative placeholder — the "Rem is waking up" RemContextualMessage below is the single
        // spoken announcement, so hide the skeleton from VoiceOver to avoid saying it twice.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bubble(fromUser: Bool, widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            if fromUser { Spacer(minLength: 0) }
            VStack(alignment: fromUser ? .trailing : .leading, spacing: 7) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DesignTokens.Color.fillTertiary)
                        .frame(height: 11)
                        .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
                        .scaleEffect(x: w, anchor: fromUser ? .trailing : .leading)
                }
            }
            // The user (right) side keeps a grey bubble; the AI (left) side is bubble-LESS — just the
            // shimmering lines on the chat background, mirroring how real assistant messages render.
            .padding(fromUser ? EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14)
                              : EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .background {
                if fromUser {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(DesignTokens.Color.backgroundSecondary)
                }
            }
            // Half-width bubbles (was ~300) so the mock exchange reads as short messages, not
            // full-width paragraphs.
            .frame(maxWidth: 150, alignment: fromUser ? .trailing : .leading)
            if !fromUser { Spacer(minLength: 0) }
        }
    }
}

// `.shimmering()` is the shared modifier from DesignTokens.swift (ShimmerModifier).

#if DEBUG
#Preview("Chat waking skeleton") {
    ChatWakingSkeleton()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Color.backgroundPrimary)
}
#endif
