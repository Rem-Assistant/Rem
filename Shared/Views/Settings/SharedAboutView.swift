import SwiftUI

// MARK: - Shared About View

/// About section shared between iOS and macOS.
struct SharedAboutView: View {
    var body: some View {
        Group {
            #if os(iOS)
            iOSAboutContent
            #else
            macAboutContent
            #endif
        }
    }

    #if os(iOS)
    private var iOSAboutContent: some View {
        List {
            SharedAboutHeroView(title: "Rem")

            Section {
                NavigationLink {
                    LegalDocumentView(
                        title: "Terms of Service",
                        lastUpdated: LegalContent.termsLastUpdated,
                        sections: LegalContent.termsOfServiceSections)
                } label: {
                    Text("Terms of Service")
                }

                NavigationLink {
                    LegalDocumentView(
                        title: "Privacy Policy",
                        lastUpdated: LegalContent.privacyLastUpdated,
                        sections: LegalContent.privacyPolicySections)
                } label: {
                    Text("Privacy Policy")
                }
            }

            SharedAboutVersionSection()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    #if os(macOS)
    private var macAboutContent: some View {
        Form {
            SharedAboutHeroView(title: "Rem for Mac")
            SharedAboutLegalLinksSection()
            SharedAboutVersionSection()
        }
        .formStyle(.grouped)
        .macSettingsCenteredColumn()
        .navigationTitle("About")
    }
    #endif

}

#if DEBUG
#Preview("About") {
    NavigationStack {
        SharedAboutView()
    }
}
#endif

// MARK: - Shared About Building Blocks

struct SharedAboutHeroView: View {
    var title: String
    var subtitle: String = "Turn your thoughts into actions"

    var body: some View {
        Section {
            VStack(spacing: 12) {
                appIcon

                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            #if os(iOS)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            #endif
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        #if os(iOS)
        if let appIcon = UIImage(named: "AppIcon") ?? Bundle.main.remAppIcon {
            Image(uiImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            appIconFallback
        }
        #else
        if let appIcon = NSImage(named: "AppIcon") {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            appIconFallback
        }
        #endif
    }

    private var appIconFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.blue.opacity(0.2))
                .frame(width: 80, height: 80)
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundColor(.blue)
        }
    }
}

struct SharedAboutVersionSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: appVersion)
            LabeledContent("Build", value: buildNumber)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

#if os(macOS)
struct SharedAboutLegalLinksSection: View {
    var body: some View {
        Section {
            HStack {
                Text("Terms of Service")
                Spacer()
                Link("View", destination: URL(string: "https://userem.site/terms-of-service")!)
                    .font(.callout)
            }

            HStack {
                Text("Privacy Policy")
                Spacer()
                Link("View", destination: URL(string: "https://userem.site/privacy-policy")!)
                    .font(.callout)
            }
        }
    }
}
#endif

// MARK: - Shared Feedback Helpers

enum SharedFeedback {
    static let feedbackEmail = "admin@userem.site"

    static func feedbackURL(appVersion: String, buildNumber: String) -> URL? {
        let subject = "Rem Feedback v\(appVersion) (\(buildNumber))"
        let body = "Hi Rem team,\n\nI'd like to share feedback:"
        return mailtoURL(subject: subject, body: body)
    }

    static func bugReportURL(appVersion: String, buildNumber: String, includeLogs: Bool, diagnostics: String? = nil) -> URL? {
        let subject = "Rem Bug Report v\(appVersion) (\(buildNumber))"
        var body = """
        Hi Rem team,

        I'm reporting a bug.

        What happened:


        Steps to reproduce:


        Expected result:


        Actual result:

        """
        if includeLogs, let diagnostics {
            body += "\n\n\(diagnostics)"
        }
        return mailtoURL(subject: subject, body: body)
    }

    private static func mailtoURL(subject: String, body: String) -> URL? {
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "mailto:\(feedbackEmail)?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}

#if os(iOS)
// MARK: - iOS App Icon Helper

extension Bundle {
    var remAppIcon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last {
            return UIImage(named: lastIcon)
        }
        return nil
    }
}
#endif
