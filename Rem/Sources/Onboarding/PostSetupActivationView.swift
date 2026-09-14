import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct PostSetupActivationView: View {
    struct EducationPage: Identifiable, Equatable {
        let id: String
        let systemImage: String
        let title: String
        let subtitle: String
    }

    static let educationPages: [EducationPage] = [
        EducationPage(
            id: "chat",
            systemImage: "message.badge.waveform.fill",
            title: "Start in chat",
            subtitle: "Use text or voice to capture a loose plan, task, or reminder. Rem will help turn it into something you can act on."
        ),
        EducationPage(
            id: "lock-screen",
            systemImage: "lock.iphone",
            title: "Capture from the Lock Screen",
            subtitle: "Add Rem as a Lock Screen control so you can talk through an idea before it disappears."
        ),
        EducationPage(
            id: "gateway",
            systemImage: "server.rack",
            title: "Check your gateway",
            subtitle: "Open Settings, then Gateways, to see your cloud gateway status, paired devices, and what Rem can run."
        )
    ]

    let onContinue: () -> Void

    @State private var selectedPage = Self.educationPages.first?.id ?? "chat"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.xl) {
                    pagedEducation
                }
                .padding(DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .frame(maxWidth: 560, alignment: .leading)
            }

            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Color.backgroundPrimary.ignoresSafeArea())
        .accessibilityIdentifier("PostSetupActivationView")
    }

    private var pagedEducation: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            TabView(selection: $selectedPage) {
                ForEach(Self.educationPages) { page in
                    EducationPageCard(page: page)
                        .tag(page.id)
                        .padding(.bottom, DesignTokens.Spacing.xs)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 500)

            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Self.educationPages) { page in
                    Circle()
                        .fill(page.id == selectedPage ? DesignTokens.Color.brandBlue : DesignTokens.Color.separator)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityIdentifier("PostSetupPagedEducation")
    }

    private var continueButton: some View {
        Button {
            onContinue()
        } label: {
            Text("Start Using Rem")
        }
        .remPrimaryActionButton()
        .accessibilityIdentifier("PostSetupContinueButton")
    }

    private var bottomBar: some View {
        continueButton
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.md)
            .background(DesignTokens.Color.backgroundPrimary)
    }

}

private struct EducationPageCard: View {
    let page: PostSetupActivationView.EducationPage

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            educationMedia

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text(title)
                    .font(DesignTokens.Typography.title1Bold)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("PostSetupEducationPage-\(page.id)")
    }

    private var educationMedia: some View {
        VStack {
            PhoneFrameEducationMedia(
                placeholderID: page.id
            )
        }
        .frame(height: 292)
    }

    private var title: String {
        page.title
    }

    private var subtitle: String {
        page.subtitle
    }

}

private struct PhoneFrameEducationMedia: View {
    let placeholderID: String

    private let phoneHeight: CGFloat = 276
    private var phoneWidth: CGFloat { phoneHeight * 439 / 892 }
    private var screenWidth: CGFloat { phoneHeight * 0.42 }
    private var screenHeight: CGFloat { screenWidth * 16 / 9 }

    var body: some View {
        ZStack {
            Image("iPhone14ProWithoutNotch")
                .resizable()
                .scaledToFit()
                .frame(width: phoneWidth, height: phoneHeight)
                .accessibilityHidden(true)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black)
                .frame(width: screenWidth, height: screenHeight)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityIdentifier("PostSetupEducationBlankMedia-\(placeholderID)")
                .accessibilityHidden(true)
        }
        .frame(width: phoneWidth, height: phoneHeight)
    }
}

#if DEBUG
struct PostSetupActivationFixtureView: View {
    var body: some View {
        PostSetupActivationView {}
    }
}
#endif

#Preview("NUX — Light") {
    PostSetupActivationView {}
}

#Preview("NUX — Dark") {
    PostSetupActivationView {}
        .preferredColorScheme(.dark)
}
