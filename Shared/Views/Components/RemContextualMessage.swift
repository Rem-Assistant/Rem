import SwiftUI

/// A reusable "contextual message" card — a status icon, a title, an optional
/// subtitle, and an optional footer action area. This is the canonical primitive
/// for surfacing an in-context state to the user (connection problems, empty /
/// loading states, inline notices) with consistent house styling.
///
/// The card is intentionally generic and platform-neutral: it lives in `Shared/`,
/// depends only on `DesignTokens`, and is driven entirely by its inputs — no
/// session managers, no platform APIs. It reads correctly on iOS and macOS in
/// both light and dark appearances (the `.ultraThinMaterial` fill and semantic
/// `DesignTokens` colors adapt to the environment).
///
/// The `iconColor` doubles as the card's status accent: it tints the leading
/// glyph and the hairline border, so a single semantic color (red / orange /
/// yellow / blue / green) sets the tone of the whole card.
///
/// Styling mirrors the app's existing cards (`DailyBriefCard`,
/// `SharedBrowserLiveView`'s `BrowserLiveCard`): `DesignTokens` spacing, a
/// rounded-rect surface, and semantic label colors.
///
/// The `actions` builder renders beneath the title/subtitle as a footer row, so
/// a card can carry zero, one, or several controls (buttons, a `ProgressView`,
/// etc.). Callers that need no action can use the convenience initializer.
///
/// First adopter: `GatewayDisconnectedBanner`. Next: the chat null / loading
/// state.
struct RemContextualMessage<Actions: View>: View {
    /// SF Symbol name for the leading status glyph.
    let icon: String
    /// Status accent — tints the leading glyph.
    let iconColor: Color
    /// Primary line. Kept to one line.
    let title: String
    /// Optional supporting line. Wraps up to three lines.
    var subtitle: String?
    /// Optional footer action row (buttons, progress, etc.). Defaults to none.
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(title)
                    .font(DesignTokens.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        // No stroke: the accent lives in the glyph only. A bordered card reads as heavier chrome
        // than we want for a transient status message.
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xlarge, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}

// MARK: - No-action convenience

extension RemContextualMessage where Actions == EmptyView {
    /// A contextual message with no footer action — just icon, title, and an
    /// optional subtitle.
    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("Contextual — with action") {
    RemContextualMessage(
        icon: "exclamationmark.triangle.fill",
        iconColor: DesignTokens.Color.systemRed,
        title: "Gateway Unreachable",
        subtitle: "We couldn't reach your gateway. Check your connection and try again."
    ) {
        Button("Retry") {}
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(DesignTokens.Color.systemRed)
    }
    .padding()
    .background(DesignTokens.Color.backgroundPrimary)
}

#Preview("Contextual — progress, no action") {
    RemContextualMessage(
        icon: "wifi.exclamationmark",
        iconColor: DesignTokens.Color.systemOrange,
        title: "Connecting...",
        subtitle: "Reaching your gateway."
    ) {
        ProgressView()
            .controlSize(.small)
            .tint(DesignTokens.Color.systemOrange)
    }
    .padding()
    .background(DesignTokens.Color.backgroundPrimary)
}

#Preview("Contextual — no subtitle, no action") {
    RemContextualMessage(
        icon: "checkmark.circle.fill",
        iconColor: DesignTokens.Color.systemGreen,
        title: "Connected"
    )
    .padding()
    .background(DesignTokens.Color.backgroundPrimary)
}
#endif
