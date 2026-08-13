import SwiftUI

#if DEBUG
/// Auth-free visual acceptance for the chat time separator inside its production LazyVStack context.
///
/// Reproduces the reported case directly: a morning delivery and an afternoon one on the same day,
/// which previously abutted with nothing between them and read as a single message.
struct ChatDayDividerFixtureView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.md) {
                ChatTimeSeparator(label: "Yesterday 6:00 PM")
                    .accessibilityIdentifier("ChatTimeSeparatorFixture-Yesterday")
                fixtureBubble(width: 208, alignment: .leading)
                fixtureBubble(width: 164, alignment: .trailing)

                ChatTimeSeparator(label: "Today 8:00 AM")
                    .accessibilityIdentifier("ChatTimeSeparatorFixture-Morning")
                fixtureBubble(width: 232, alignment: .leading)

                ChatTimeSeparator(label: "Today 2:30 PM")
                    .accessibilityIdentifier("ChatTimeSeparatorFixture-Afternoon")
                fixtureBubble(width: 196, alignment: .leading)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .navigationTitle("Time separator")
    }

    private func fixtureBubble(width: CGFloat, alignment: Alignment) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: 54)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

#Preview("Chat time separator") {
    NavigationStack {
        ChatDayDividerFixtureView()
    }
}
#endif
