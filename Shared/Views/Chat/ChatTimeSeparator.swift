import SwiftUI

/// A "mini divider" marking the start of a new group of messages, e.g. `Today 2:30 PM`.
///
/// Deliberately a bare label with **no rules**: it is punctuation between deliveries, not a heading,
/// so it reads as a quiet timestamp rather than a section break. Two briefs on the same day
/// previously abutted with nothing between them and read as one long message.
///
/// `LazyVStack` sizes children at their ideal width unless the child explicitly accepts the
/// available proposal, so the `maxWidth: .infinity` frame is part of this component's layout
/// contract — it is what centres the label across the transcript instead of leaving it hugging
/// its own text at the leading edge.
struct ChatTimeSeparator: View {
    let label: String

    var body: some View {
        Text(label)
            .font(DesignTokens.Typography.caption1.weight(.medium))
            .foregroundStyle(DesignTokens.Color.labelSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Chat time separator") {
    VStack(spacing: DesignTokens.Spacing.md) {
        ChatTimeSeparator(label: "Today 8:00 AM")
        ChatTimeSeparator(label: "Today 2:30 PM")
        ChatTimeSeparator(label: "Yesterday 6:00 PM")
        ChatTimeSeparator(label: "Fri, Aug 7 9:15 AM")
    }
    .padding()
    .background(DesignTokens.Color.backgroundPrimary)
}
