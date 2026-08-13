import SwiftUI

/// Generic sign-in button with a custom icon and title, styled using DesignTokens.
struct SignInButton<Icon: View>: View {
    let icon: Icon
    let title: String
    let action: () -> Void

    init(@ViewBuilder icon: () -> Icon, title: String, action: @escaping () -> Void) {
        self.icon = icon()
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                icon
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(DesignTokens.Typography.bodyBold)
                    .foregroundColor(DesignTokens.Color.backgroundPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.Spacing.md)
            .background(DesignTokens.Color.buttonBackground)
            .cornerRadius(DesignTokens.CornerRadius.medium)
        }
    }
}
