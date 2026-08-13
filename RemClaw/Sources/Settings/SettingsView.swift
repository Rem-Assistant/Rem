import SwiftUI
import SwiftData
import OpenClawKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Root Settings View

struct SettingsView: View {
    @Environment(RemGatewaySessionManager.self) private var gateway
    @Environment(RemAuthService.self) private var authService
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        SharedSettingsView(
            gateway: gateway,
            onSignOut: {
                guard RemAuthService.clearAllUserData(from: modelContext) else {
                    return "Rem couldn’t clear this account’s local data, so you’re still signed in to keep it safe. Check available storage and try again."
                }
                authService.signOut()
                gateway.clearConfiguration()
                RemCredentialStore.clearAll()
                return nil
            },
            onDeleteAccount: { await deleteAccount() },
            profileName: profileDisplayName,
            profileSubtitle: profileSubtitle,
            profileImageURL: profileImageURL,
            permissionsView: { DevicePermissionsView() },
            aboutView: { AboutSettingsView() },
            debugSectionContent: debugSectionContent
        )
    }

    /// Debug-only entry points appended after sign-out/delete account. The
    /// initial entry is the SomeClaw relay client (#94) for internal use.
    private var debugSectionContent: (() -> AnyView)? {
        #if DEBUG
        return {
            AnyView(
                Group {
                    NavigationLink {
                        AssistantMarkdownFixtureView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "text.bubble.fill", color: .blue)
                            Text("Assistant Markdown Fixture")
                        }
                    }

                    NavigationLink {
                        SomeClawSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "antenna.radiowaves.left.and.right", color: .pink)
                            Text("SomeClaw Relay")
                        }
                    }
                }
            )
        }
        #else
        return nil
        #endif
    }

    // MARK: - Account Deletion

    private func deleteAccount() async -> String? {
        let result = await performAccountDeletion()
        if result == nil {
            // Success — clear local data (SwiftData cleanup handled by onSignOut
            // which runs after the deletion alert, and the onChange safety net)
            RemCredentialStore.gatewayURL = nil
            RemCredentialStore.gatewayToken = nil
        }
        return result
    }

    // MARK: - Helpers

    private var profileDisplayName: String {
        if let user = authService.currentUser {
            let name = user.full_name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
            // Fall back to the email local part (before @) as a friendlier name
            if let email = user.email, !email.isEmpty {
                return email.components(separatedBy: "@").first ?? email
            }
            return "Account"
        }
        // Signed in but user info not cached — show email from token if available
        return "Account"
    }

    private var profileSubtitle: String {
        authService.currentUser?.email ?? ""
    }

    private var profileImageURL: URL? {
        guard let raw = authService.currentUser?.profile_picture_url,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

}

// MARK: - Gateway Settings (drill-down)

// MARK: - About Settings (drill-down)

struct AboutSettingsView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Group {
                        if let appIcon = UIImage(named: "AppIcon") ?? Bundle.main.remAppIcon {
                            Image(uiImage: appIcon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Color(.systemBlue).opacity(0.2))
                                    .frame(width: 80, height: 80)
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 40))
                                    .foregroundColor(Color(.systemBlue))
                            }
                        }
                    }

                    VStack(spacing: 4) {
                        Text("Rem")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(Color(.label))
                        Text("Turn your thoughts into actions")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(Color(.secondaryLabel))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

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

            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildNumber)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

}

struct LegalSection {
    let title: String
    let body: String
}

struct LegalDocumentView: View {
    let title: String
    let lastUpdated: String
    let sections: [LegalSection]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Last updated: \(lastUpdated)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DesignTokens.Color.labelSecondary)

                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(titleColor)
                        Text(section.body)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(bodyColor)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var titleColor: Color {
        colorScheme == .dark ? .white : DesignTokens.Color.labelPrimary
    }

    private var bodyColor: Color {
        colorScheme == .dark ? Color(.systemGray) : DesignTokens.Color.labelSecondary
    }
}

// MARK: - Shared Legal Content

enum LegalContent {
    static let termsLastUpdated = "3/28/2026"
    static let privacyLastUpdated = "3/30/2026"

    static var termsOfServiceSections: [LegalSection] {
        [
            LegalSection(
                title: "Use of the service",
                body: "By using Rem, you agree to use the service in a lawful manner and in accordance with these terms. You are responsible for maintaining the confidentiality of your account and for all activities that occur under your account."),
            LegalSection(
                title: "Limitation of liability",
                body: "To the maximum extent permitted by law, Rem and its providers shall not be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of profits or revenues, whether incurred directly or indirectly, or any loss of data, use, goodwill, or other intangible losses resulting from your use of the service."),
            LegalSection(
                title: "Subscriptions and payments",
                body: "Rem offers auto-renewable subscriptions through the Apple App Store. By subscribing:\n\n• Payment is charged to your Apple ID account at confirmation of purchase.\n• Your subscription automatically renews unless you cancel at least 24 hours before the end of the current billing period.\n• Your account will be charged for renewal within 24 hours prior to the end of the current period at the same price.\n• You can manage and cancel your subscription in your device's Settings > Apple ID > Subscriptions at any time.\n• Any unused portion of a free trial period, if offered, will be forfeited when you purchase a subscription.\n\nRefunds are handled by Apple in accordance with their refund policies."),
            LegalSection(
                title: "Account deletion",
                body: "You may delete your account at any time from the app's Settings. Deleting your account permanently removes your user data, AI gateway server, and conversation history. This action cannot be undone."),
            LegalSection(
                title: "Changes to the service",
                body: "We reserve the right to modify, suspend, or discontinue the service, or any part of it, at any time with or without notice. We may also update these terms from time to time. Continued use of the service after changes to the terms constitutes acceptance of those changes."),
            LegalSection(
                title: "Contact",
                body: "If you have questions about these Terms of Service, contact us at admin@userem.site.")
        ]
    }

    static var privacyPolicySections: [LegalSection] {
        [
            LegalSection(
                title: "Who we are",
                body: "Rem (\"we\", \"our\", \"us\") is an AI assistant app and supporting backend service. If you have questions about this policy, contact us at admin@userem.site."),
            LegalSection(
                title: "Information we collect",
                body: "Information you provide:\n\n• Account information: Your name and email address when you sign in with Apple or Google.\n• Messages and prompts: The text you send to the AI assistant through chat or voice input.\n• Device permissions: Access you grant to calendars, reminders, and notifications so the assistant can help manage them on your behalf.\n\nInformation collected automatically:\n\n• Device information: Device type, operating system version, and app version.\n• Usage data: How you interact with the app (e.g., features used, session activity).\n• Diagnostic data: Error logs and performance information to help us fix issues.\n\nInformation we do not collect:\n\n• We do not collect or store your full chat history on our servers. Conversation history is stored on your personal AI gateway.\n• We do not access the content of your calendars, reminders, or other device data on our servers. That data is accessed locally on your device by the assistant and is not transmitted to us."),
            LegalSection(
                title: "Third-party services that receive your data",
                body: "Rem shares your data with the following named third-party services to provide the AI assistant. Before using the app, you are asked to explicitly consent to this data sharing.\n\nMiniMax, served via GMI (AI Model) — When you send a message to the assistant, your message text and relevant conversation context are sent to a MiniMax large language model, hosted on GMI's inference infrastructure, to generate responses. If you configure your own model provider with your own API key, your messages are sent to that provider instead. Data handling by these AI model providers is governed by their respective terms; see minimax.io and gmi.cloud for current policies.\n\nElevenLabs (Voice Synthesis) — If you use voice features, the AI assistant's text responses are sent to ElevenLabs to convert them into spoken audio. Voice features are optional. If you do not use voice mode, no data is sent to ElevenLabs.\n\nApple (Speech Recognition) — If you use voice input, your speech is processed using Apple's Speech Recognition framework. Depending on your device and settings, speech recognition may be performed on-device or may use Apple's servers.\n\nInfrastructure Providers — Fly.io hosts your personal AI gateway, which stores your conversation history and assistant configuration. Each user gets a dedicated, isolated gateway instance. Railway hosts our backend service that manages authentication and gateway deployment. These providers process data as part of hosting infrastructure. They do not access the content of your messages."),
            LegalSection(
                title: "Where your data lives",
                body: "Your personal AI gateway: Your assistant's primary data — including conversation history, session state, and assistant memory — is stored on a dedicated gateway instance. Each user has their own isolated instance. We do not access this data except as needed for technical support or troubleshooting.\n\nOur backend stores only:\n• Your authentication credentials and session tokens\n• Your gateway connection URL and configuration metadata\n• Operational logs (timestamps, request metadata, errors) retained for a limited time\n\nOur backend does not store your messages, conversation history, or the content of device data accessed by the assistant.\n\nOn your device: The app stores authentication tokens securely on your device. Device data (calendars, reminders) is accessed locally and sent to your gateway only when the assistant needs it to fulfill a request."),
            LegalSection(
                title: "How we use your data",
                body: "We use the information we collect to:\n\n• Provide the service: Authenticate you, connect you to your AI gateway, process your messages through the AI model that powers the assistant (MiniMax, served via GMI, by default), and deliver voice responses via ElevenLabs.\n• Maintain and improve the app: Debug issues, monitor performance, and improve reliability.\n• Communicate with you: Send service-related notifications about your account, security, or significant changes.\n\nWe do not:\n• Sell your personal information\n• Use your conversations for advertising\n• Use your data to train AI models"),
            LegalSection(
                title: "Device permissions and on-device data",
                body: "Rem may request access to the following device capabilities so the AI assistant can help manage them on your behalf:\n\n• Calendars: View and create calendar events\n• Reminders: View and create reminders\n• Notifications: Deliver assistant notifications\n• Microphone: Enable voice conversations with the assistant\n• Camera: Scan setup-code QR codes for gateway pairing\n\nThis data is accessed locally on your device. When the assistant acts on a request (e.g., \"add a reminder\"), the relevant data is sent to your personal gateway and to the AI model that powers the assistant (MiniMax, served via GMI, by default) as part of the conversation context. You control which permissions to grant, and you can revoke them at any time in your device's Settings."),
            LegalSection(
                title: "Data sharing",
                body: "We share data only in these circumstances:\n\n• With third-party services described above, as required to provide the service.\n• For legal reasons: If required by law, subpoena, or valid legal process, or to protect our rights, property, or safety.\n• With your consent: If you opt into specific integrations that require additional sharing.\n\nWe do not sell your personal information."),
            LegalSection(
                title: "Data retention",
                body: "• Our backend: Account and authentication data is retained while your account is active. Operational logs are retained for a limited period, then deleted.\n• Your gateway: Conversation history and assistant state persist on your gateway instance as long as your account is active. When you delete your account, your gateway and its data are removed.\n• Third-party services: Data retention by MiniMax, GMI, ElevenLabs, Apple, and infrastructure providers is governed by their respective policies."),
            LegalSection(
                title: "Your rights and controls",
                body: "• Delete your account: You can request deletion of your account and all associated data, including your gateway instance, from within the app's settings. This permanently removes your conversation history and assistant data.\n• Manage permissions: You can grant or revoke device permissions (calendar, reminders, etc.) at any time through your device's Settings.\n• Disable voice: If you do not use voice features, no audio data is sent to Apple's speech services and no text is sent to ElevenLabs."),
            LegalSection(
                title: "Security",
                body: "We take reasonable measures to protect your data, including encrypting data in transit, restricting access to authorized personnel, and isolating each user's data on a dedicated gateway instance.\n\nNo system is perfectly secure. If we become aware of a data breach affecting your information, we will notify you in accordance with applicable laws."),
            LegalSection(
                title: "Children's privacy",
                body: "Rem is not intended for use by children under 13 (or the minimum age required by your jurisdiction). We do not knowingly collect personal information from children. If you believe a child has provided us with personal data, please contact us so we can delete it."),
            LegalSection(
                title: "International data transfers",
                body: "Your data may be processed in multiple countries depending on the locations of our infrastructure providers and third-party services. We take reasonable steps to ensure transfers comply with applicable data protection laws."),
            LegalSection(
                title: "Changes to this policy",
                body: "We may update this Privacy Policy from time to time. If we make material changes, we will update the \"Last updated\" date and notify you in the app or by email where appropriate. Your continued use of Rem after changes take effect means you accept the updated policy."),
            LegalSection(
                title: "Contact",
                body: "If you have questions about this Privacy Policy, contact us at admin@userem.site.")
        ]
    }
}

// Bundle.remAppIcon extension is now in Shared/Views/Settings/SharedAboutView.swift

// MARK: - Paired Devices (drill-down)

struct PairedDevicesSettingsView: View {
    @Environment(RemGatewaySessionManager.self) private var gateway

    var body: some View {
        List {
            if gateway.connectionState.isConnected {
                Section {
                    Text("Devices that connect to your gateway will appear here.")
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                } footer: {
                    Text("Mac and other nodes can pair with your account through the OpenClaw gateway.")
                }
            } else {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "laptopcomputer.and.iphone")
                                .font(.system(size: 36))
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                            Text("Connect to Gateway")
                                .font(DesignTokens.Typography.body)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                            Text("Pair your devices by connecting to the gateway first.")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle("Paired Devices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Device Permissions (drill-down)

struct DevicePermissionsView: View {
    var body: some View {
        List {
            Section {
                PermissionRow(title: "Notifications", icon: "bell.fill", color: .red, permissionType: .notifications)
            } footer: {
                Text("Tap a row to grant access. If denied, you'll be taken to Settings.")
            }

            Section {
                CalendarPermissionRow()
                PermissionRow(title: "Reminders", icon: "AppleRemindersLogo", color: .purple, permissionType: .reminders, usesAssetIcon: true)
            } header: {
                Text("Device Data")
            } footer: {
                Text("Allow Rem to view and edit your calendars and reminders on your behalf.")
            }

            Section {
                PermissionRow(title: "Microphone", icon: "mic.fill", color: .orange, permissionType: .microphone)
                PermissionRow(title: "Speech Recognition", icon: "waveform", color: .indigo, permissionType: .speechRecognition)
                PermissionRow(title: "Camera", icon: "camera.fill", color: .gray, permissionType: .camera)
            } header: {
                Text("Media & Voice")
            } footer: {
                Text("Needed for voice conversations and scanning QR codes.")
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CalendarPermissionRow: View {
    @StateObject private var calendarService = RemCalendarService()
    @AppStorage("selectedCalendarID") private var selectedCalendarID = ""
    @State private var status: String = "Checking..."
    @State private var availableCalendars: [CalendarInfo] = []
    @State private var isSheetPresented = false
    @State private var isLoadingCalendars = false
    #if canImport(UIKit)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                PermissionChecker.openAppSettings()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(icon: "calendar", color: .red)
                    Text("Calendars")
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Spacer()
                    PermissionStatusBadge(status: status)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DesignTokens.Color.fillTertiary)
                }
            }

            if showsDefaultCalendarEntry {
                Button {
                    Task { await presentCalendarSheet() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Default calendar: \(selectedCalendarSubtitle)")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 40)
            }
        }
        .task {
            await refreshStatus()
            await loadCalendarsIfAuthorized()
        }
        #if canImport(UIKit)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await refreshStatus()
                    await loadCalendarsIfAuthorized()
                }
            }
        }
        #endif
        .sheet(isPresented: $isSheetPresented) {
            CalendarSelectionSheet(
                selectedCalendarID: $selectedCalendarID,
                availableCalendars: availableCalendars,
                isLoading: isLoadingCalendars,
                onReload: {
                    Task { await loadCalendarsIfAuthorized(force: true) }
                }
            )
            .presentationDetents([.height(preferredSheetHeight)])
            .presentationDragIndicator(.visible)
        }
    }

    private var showsDefaultCalendarEntry: Bool {
        status == "Granted" || status == "Limited"
    }

    private var selectedCalendarSubtitle: String {
        if let selected = availableCalendars.first(where: { $0.id == selectedCalendarID }) {
            return selected.name
        }
        return "Select default calendar"
    }

    private var preferredSheetHeight: CGFloat {
        if isLoadingCalendars {
            return 220
        }
        if availableCalendars.isEmpty {
            return 250
        }

        let visibleRows = min(availableCalendars.count, 5)
        let baseHeight: CGFloat = 170
        let rowHeight: CGFloat = 44
        return min(420, baseHeight + (CGFloat(visibleRows) * rowHeight))
    }

    @MainActor
    private func refreshStatus() async {
        status = await PermissionChecker.checkStatus(for: .calendar)
    }

    @MainActor
    private func loadCalendarsIfAuthorized(force: Bool = false) async {
        guard force || availableCalendars.isEmpty else { return }
        guard status == "Granted" || status == "Limited" else {
            availableCalendars = []
            return
        }

        isLoadingCalendars = true
        let calendars = await calendarService.getAvailableCalendars()
        availableCalendars = calendars

        if calendars.isEmpty {
            selectedCalendarID = ""
        } else if selectedCalendarID.isEmpty || calendars.contains(where: { $0.id == selectedCalendarID }) == false {
            selectedCalendarID = await calendarService.getDefaultCalendarIdentifier() ?? calendars.first?.id ?? ""
        }

        isLoadingCalendars = false
    }

    @MainActor
    private func presentCalendarSheet() async {
        await loadCalendarsIfAuthorized(force: true)
        isSheetPresented = true
    }

}

private struct CalendarSelectionSheet: View {
    @Binding var selectedCalendarID: String
    let availableCalendars: [CalendarInfo]
    let isLoading: Bool
    let onReload: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if availableCalendars.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No Calendars Available")
                                .font(DesignTokens.Typography.bodyBold)
                                .foregroundColor(DesignTokens.Color.labelPrimary)
                            Text("Add a calendar account in iOS Settings to continue.")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(availableCalendars) { calendar in
                            Button {
                                selectedCalendarID = calendar.id
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(calendar.color)
                                        .frame(width: 12, height: 12)
                                    Text(calendar.name)
                                        .foregroundColor(DesignTokens.Color.labelPrimary)
                                    Spacer()
                                    if selectedCalendarID == calendar.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Default Calendar")
                } footer: {
                    Text("New events will be created in this calendar.")
                }
            }
            .navigationTitle("Calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Refresh", action: onReload)
                        .disabled(isLoading)
                }
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let icon: String
    let color: Color
    let permissionType: PermissionType
    var usesAssetIcon = false

    @State private var status: PermissionStatus = .checking
    #if canImport(UIKit)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        Button {
            Task {
                await PermissionChecker.requestOrOpenSettings(for: permissionType, currentStatus: status)
                status = await PermissionChecker.permissionStatus(for: permissionType)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    permissionIcon
                    Text(title)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Spacer()
                    PermissionStatusBadge(status: status)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DesignTokens.Color.fillTertiary)
                }

                if permissionType == .speechRecognition, status == .denied || status == .restricted {
                    Text("Enable Speech Recognition in Settings > Privacy & Security > Speech Recognition.")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 44)
                }
            }
        }
        .task { status = await PermissionChecker.permissionStatus(for: permissionType) }
        #if canImport(UIKit)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { status = await PermissionChecker.permissionStatus(for: permissionType) }
            }
        }
        #endif
    }

    @ViewBuilder
    private var permissionIcon: some View {
        if usesAssetIcon {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            SettingsIcon(icon: icon, color: color)
        }
    }
}

// MARK: - Delete Account Confirmation Sheet

private struct DeleteAccountSheet: View {
    @Binding var confirmText: String
    @Binding var isDeleting: Bool
    var onDelete: () -> Void
    var onCancel: () -> Void

    private var isConfirmed: Bool {
        confirmText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                Text("This will permanently delete your account, your AI gateway, and all conversation history. This action cannot be undone.")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("Type **delete** to confirm")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundColor(DesignTokens.Color.labelSecondary)

                    TextField("delete", text: $confirmText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(DesignTokens.Spacing.md)
                        .background(DesignTokens.Color.backgroundSecondary)
                        .cornerRadius(DesignTokens.CornerRadius.small)
                }

                Button {
                    onDelete()
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Text("Delete Account")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, DesignTokens.Spacing.md)
                }
                .buttonStyle(.borderedProminent)
                .tint(isConfirmed ? .red : .gray)
                .disabled(!isConfirmed || isDeleting)

                Spacer()
            }
            .padding(DesignTokens.Spacing.lg)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .disabled(isDeleting)
                }
            }
        }
    }
}
