import SwiftUI

/// macOS Settings — thin wrapper around SharedSettingsView.
struct MacFullSettingsView: View {
    @Environment(MacGatewaySessionManager.self) private var session
    @Environment(\.localGateway) private var localGateway

    var body: some View {
        NavigationStack {
            SharedSettingsView(
                gateway: session,
                onSignOut: {
                    session.signOutWithRecovery()
                },
                onDeleteAccount: {
                    await session.deleteAccount()
                },
                profileName: session.userProfile?.displayName ?? "Account",
                profileSubtitle: session.userProfile?.email ?? "",
                profileImageURL: profileImageURL,
                permissionsView: {
                    PermissionsTab(calendarConnectorDestination: calendarConnectorDestination)
                },
                aboutView: { SharedAboutView() },
                gatewayBackupView: backupDestination
            )
        }
        .frame(
            minWidth: DesignTokens.Layout.settingsTabbedMinWidth,
            minHeight: 420
        )
        .task {
            session.restoreCachedProfile()
            await session.fetchUserProfile()
        }
        .accessibilityIdentifier("MacFullSettingsView")
    }

    private var profileImageURL: URL? {
        guard let raw = session.userProfile?.profile_picture_url,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var backupDestination: (() -> AnyView)? {
        guard let localGateway else { return nil }
        return {
            AnyView(MacBackupView(localGateway: localGateway))
        }
    }

    private var calendarConnectorDestination: (() -> AnyView)? {
        guard session.userProfile?.id != nil else { return nil }
        return {
            AnyView(SharedComposioConnectionsView(service: ComposioService()))
        }
    }
}
