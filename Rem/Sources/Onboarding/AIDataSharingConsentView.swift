import SwiftUI

/// Fourth onboarding step — obtains explicit user consent for sharing data
/// with the AI model provider (MiniMax, served via GMI, by default) and other
/// third-party services before the app can be used.
/// Required by App Store Guidelines 5.1.1(i) and 5.1.2(i).
struct AIDataSharingConsentView: View {
    let onConsent: () -> Void

    @State private var showTerms = false
    @State private var showPrivacy = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    Spacer(minLength: DesignTokens.Spacing.xxl)

                    hero
                    legalList
                }
                .padding(DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .frame(maxWidth: 560)
            }

            bottomBar
        }
        .background(DesignTokens.Color.backgroundPrimary.ignoresSafeArea())
        .accessibilityIdentifier("AIDataSharingConsentView")
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                LegalDocumentView(
                    title: "Terms of Service",
                    lastUpdated: LegalContent.termsLastUpdated,
                    sections: LegalContent.termsOfServiceSections)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showTerms = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                LegalDocumentView(
                    title: "Privacy Policy",
                    lastUpdated: LegalContent.privacyLastUpdated,
                    sections: LegalContent.privacyPolicySections)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showPrivacy = false }
                    }
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(DesignTokens.Color.brandBlue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("Privacy by design")
                    .font(DesignTokens.Typography.title1.weight(.semibold))
                    .foregroundColor(DesignTokens.Color.labelPrimary)
                    .multilineTextAlignment(.center)

                Text("Rem uses your data to answer requests and run approved actions through your personal cloud gateway. You can review or delete your account data in Settings.")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var legalList: some View {
        VStack(spacing: 0) {
            legalRow(
                icon: "doc.text",
                title: "Terms of Service",
                subtitle: "How Rem accounts, subscriptions, and approved actions work.",
                action: { showTerms = true }
            )

            Divider()
                .padding(.leading, 60)

            legalRow(
                icon: "shield",
                title: "Privacy Policy",
                subtitle: "What Rem, your gateway, and AI or voice providers process.",
                action: { showPrivacy = true }
            )
        }
        .background(DesignTokens.Color.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                .stroke(DesignTokens.Color.separator.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("AIDataSharingLegalList")
    }

    private func legalRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .frame(width: 38, height: 38)
                    .background(DesignTokens.Color.fillTertiary, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DesignTokens.Typography.body.weight(.semibold))
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Text(subtitle)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var continueButton: some View {
        Button {
            onConsent()
        } label: {
            Text("Accept and Continue")
        }
        .remPrimaryActionButton()
        .accessibilityIdentifier("AIDataSharingConsentButton")
    }

    private var bottomBar: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            continueButton

            Text("By tapping \"Accept and Continue,\" you agree to our Terms of Service and Privacy Policy.")
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.md)
        .background(DesignTokens.Color.backgroundPrimary)
    }
}

#if DEBUG
struct AIDataSharingConsentFixtureView: View {
    var body: some View {
        AIDataSharingConsentView {}
    }
}
#endif

#Preview("Privacy Consent — Light") {
    AIDataSharingConsentView(onConsent: {})
}

#Preview("Privacy Consent — Dark") {
    AIDataSharingConsentView(onConsent: {})
        .preferredColorScheme(.dark)
}
