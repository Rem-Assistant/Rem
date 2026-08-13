import SwiftUI

/// Softer full-width CTA for inline recovery cards and permission nudges.
/// Uses a neutral elevated fill instead of the app-wide primary black fill.
struct RemInlineRecoveryCTAButtonStyle: ButtonStyle {
    enum Role: Sendable { case primary, destructive }

    var role: Role = .primary

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.Typography.body.weight(.semibold))
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.Spacing.md)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
            .opacity(isEnabled ? 1 : 0.55)
    }

    private var labelColor: Color {
        guard isEnabled else { return DesignTokens.Color.labelSecondary }
        return role == .primary ? DesignTokens.Color.brandBlue : .red
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(isPressed ? 0.16 : 0.11)
        }

        return Color.black.opacity(isPressed ? 0.08 : 0.05)
    }
}

extension View {
    func remInlineRecoveryCTA(_ role: RemInlineRecoveryCTAButtonStyle.Role = .primary) -> some View {
        buttonStyle(RemInlineRecoveryCTAButtonStyle(role: role))
    }
}
