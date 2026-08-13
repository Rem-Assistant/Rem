import SwiftUI

// MARK: - Root Settings View (shared across iOS and macOS)

/// Unified settings view used by both iOS and macOS.
/// Generic over `GatewaySessionProviding` so it works with either session manager.
struct SharedSettingsView<Gateway: GatewaySessionProviding, PermissionsView: View, AboutView: View>: View {
    let gateway: Gateway

    /// Callbacks for platform-specific actions
    var onSignOut: () -> String? // returns an actionable error message or nil
    var onDeleteAccount: () async -> String? // returns error message or nil

    /// Profile info (passed in since auth is platform-specific)
    var profileName: String = "Account"
    var profileSubtitle: String = ""
    var profileImageURL: URL? = nil

    /// Platform-specific detail views
    @ViewBuilder var permissionsView: () -> PermissionsView
    @ViewBuilder var aboutView: () -> AboutView
    /// Gateway-scoped backup/restore lives under Gateway Detail. Root Settings
    /// stays account/app-scoped so platform-specific gateway tools do not look
    /// like global account preferences.
    var gatewayBackupView: (() -> AnyView)? = nil

    /// Optional debug section appended after the standard sections. Used by
    /// iOS DEBUG builds for internal-only entry points (e.g. the SomeClaw
    /// relay client, #94). Mac and release builds pass `nil`.
    var debugSectionContent: (() -> AnyView)?

    @State private var showSignOutConfirmation = false
    @State private var showSignOutError = false
    @State private var signOutErrorMessage = ""
    @State private var showDeleteAccountSheet = false
    @State private var deleteConfirmText = ""
    @State private var isDeletingAccount = false
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""
    @State private var showAccountDeletedAlert = false

    /// iOS: `List` + **insetGrouped** (unavailable on macOS). macOS: `Form` + `.grouped`
    /// in the shared centered column used by settings detail screens.
    @ViewBuilder
    private var settingsListOrForm: some View {
        #if os(macOS)
        Form { settingsRoot }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { settingsRoot }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var settingsRoot: some View {
        // MARK: - Section 1: Profile

        Section {
            profileRow
        }

        // MARK: - Section 2: Agent runtime

        // Keep the runtime entry in its own group so it reads as the primary
        // place to configure Rem, rather than one peer in a long root list.
        Section {
            NavigationLink {
                SharedOpenClawGatewayHomeView(
                    gateway: gateway,
                    backupView: gatewayBackupView
                )
            } label: {
                HStack(spacing: 12) {
                    OpenClawRuntimeIcon()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenClaw")
                        connectionBadge
                    }
                }
            }
            .accessibilityLabel("Agent settings, OpenClaw, \(gateway.connectionState.shortStatusText)")
            .accessibilityHint("Opens settings for your agent runtime")
        } header: {
            Text("Your agent runtime")
        }

        // MARK: - Section 3: Account and device

        Section {
            // Cloud browser moved to Agent settings → Connectivity (it's an agent capability, not a
            // global app preference). See SharedGatewayDetailView.

            // Provider Keys (BYOK) moved to Agents → Controls: provider auth
            // belongs to the agent runtime, not Billing. See
            // SharedGatewayDetailView's Controls section.

            NavigationLink {
                permissionsDestination
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(icon: "hand.raised.fill", color: .blue)
                    Text("Permissions")
                }
            }

            // Automations (Daily Check-ins) now lives under Settings → Agent settings →
            // Connectivity. The founder groups scheduled agent behavior with the agent,
            // not as a top-level app preference. See SharedGatewayDetailView.

            // Memory lives under Settings → Agent settings. Channels are no
            // longer part of the product IA. Tasks & Cloud
            // (SharedTaskRuntimeSettingsView) is not surfaced from Settings;
            // the view file is retained.

            // Connectors and Skills are runtime-scoped and intentionally live
            // under Agent settings. Do not duplicate them at the root.
        }

        // MARK: - Section 4: About

        Section {
            NavigationLink {
                aboutDestination
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(icon: "info.circle.fill", color: .gray)
                    Text("About")
                }
            }
        }

        // MARK: - Section 5: Feedback

        Section {
            ShareLink(
                item: remAppStoreURL,
                subject: Text("Try Rem"),
                message: Text("Check out Rem on the App Store.")
            ) {
                SettingsActionRowLabel(
                    title: "Share Rem",
                    icon: "square.and.arrow.up.fill",
                    color: .green
                )
            }
            .buttonStyle(.plain)

            Button {
                if let url = SharedFeedback.feedbackURL(appVersion: appVersion, buildNumber: buildNumber) {
                    openURL(url)
                }
            } label: {
                SettingsActionRowLabel(
                    title: "Send Feedback",
                    icon: "envelope.fill",
                    color: .blue
                )
            }
            .buttonStyle(.plain)

            Button {
                if let url = SharedFeedback.bugReportURL(
                    appVersion: appVersion,
                    buildNumber: buildNumber,
                    includeLogs: true,
                    diagnostics: diagnosticsString
                ) {
                    openURL(url)
                }
            } label: {
                SettingsActionRowLabel(
                    title: "Report a Bug",
                    icon: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }
            .buttonStyle(.plain)
        }

        // MARK: - Section 6: Sign Out

        Section {
            Button {
                showSignOutConfirmation = true
            } label: {
                Text("Sign Out")
            }
            .remSettingsCTA(.destructive)
            .remSettingsCtaListRow()
        }

        // MARK: - Section 7: Delete Account

        Section {
            Button {
                deleteConfirmText = ""
                showDeleteAccountSheet = true
            } label: {
                Text("Delete Account")
            }
            .remSettingsCTA(.destructive)
            .remSettingsCtaListRow()
        }

        // MARK: - Section 7: Debug (iOS DEBUG only — see #94)

        if let debugSectionContent {
            Section {
                debugSectionContent()
            } header: {
                Text("Debug")
            } footer: {
                Text("Internal tools — only present in DEBUG builds.")
            }
        }
    }

    var body: some View {
        settingsListOrForm
            .navigationTitle("Settings")
            .confirmationDialog("Sign Out", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                performSignOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your gateway will keep running. Sign back in to reconnect.")
        }
        .sheet(isPresented: $showDeleteAccountSheet) {
            SharedDeleteAccountSheet(
                confirmText: $deleteConfirmText,
                isDeleting: $isDeletingAccount,
                onDelete: {
                    Task {
                        isDeletingAccount = true
                        let error = await onDeleteAccount()
                        isDeletingAccount = false
                        showDeleteAccountSheet = false
                        if let error {
                            deleteErrorMessage = error
                            showDeleteError = true
                        } else {
                            showAccountDeletedAlert = true
                        }
                    }
                },
                onCancel: { showDeleteAccountSheet = false }
            )
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .alert("Account Deleted", isPresented: $showAccountDeletedAlert) {
            Button("OK") { performSignOut() }
        } message: {
            Text("Your account and all associated data have been deleted.")
        }
        .alert("Couldn’t Sign Out", isPresented: $showSignOutError) {
            Button("OK") {}
        } message: {
            Text(signOutErrorMessage)
        }
        .alert("Error", isPresented: $showDeleteError) {
            Button("OK") {}
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private func performSignOut() {
        if let error = onSignOut() {
            signOutErrorMessage = error
            showSignOutError = true
        }
    }

    // MARK: - Profile Row

    private var profileRow: some View {
        HStack(spacing: 12) {
            if let imageURL = profileImageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                fallbackAvatar
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profileName)
                    .font(.body.bold())
                Text(profileSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: - Connection Badge

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(GatewayStatusHelper.color(for: gateway.connectionState))
                .frame(width: 8, height: 8)
            Text(gateway.connectionState.shortStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                // One line only, so a status can never cram-wrap sideways in the row (the old
                // `.unreachable` case leaked a multi-line raw wire error into this badge).
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Platform-specific destinations

    @ViewBuilder
    private var permissionsDestination: some View {
        permissionsView()
    }

    @ViewBuilder
    private var aboutDestination: some View {
        aboutView()
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var remAppStoreURL: URL {
        URL(string: "https://apps.apple.com/us/app/rem-ai-personal-assistant/id6759550315")!
    }

    private var diagnosticsString: String {
        let gatewayStatus = gateway.connectionState.statusText
        #if os(iOS)
        return """
        ---
        App: Rem \(appVersion) (\(buildNumber))
        iOS: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        Gateway: \(gatewayStatus)
        """
        #else
        let host = Host.current().localizedName ?? "Unknown"
        return """
        ---
        App: Rem for Mac \(appVersion) (\(buildNumber))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Host: \(host)
        Gateway: \(gatewayStatus)
        """
        #endif
    }

    private func openURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if DEBUG
#Preview("Settings — Fixture") {
    SharedSettingsFixtureView()
}
#endif

private struct SettingsActionRowLabel: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, color: color)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
