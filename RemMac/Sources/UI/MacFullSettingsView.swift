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
                billingView: { MacBillingView() },
                aboutView: { SharedAboutView() },
                gatewayBackupView: backupDestination,
                debugSectionContent: debugSectionContent
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

    /// DEBUG-only entry points appended to Settings, mirroring the iOS `SettingsView`
    /// debug section. The initial Mac entry is the Rem-owned conversation path
    /// (`MacRemConversationDebugEntryView`) for internal use. Release builds pass `nil`.
    private var debugSectionContent: (() -> AnyView)? {
        #if DEBUG
        return {
            AnyView(
                Group {
                    NavigationLink {
                        MacRemConversationDebugEntryView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(icon: "bubble.left.and.bubble.right.fill", color: .indigo)
                            Text("Rem Conversation")
                        }
                    }
                }
            )
        }
        #else
        return nil
        #endif
    }
}

// MARK: - Mac Billing & Usage View

private struct MacBillingView: View {
    @Environment(MacGatewaySessionManager.self) private var session

    var body: some View {
        Group {
            switch BillingSummaryPresentationState.resolve(
                hasSummary: session.usageSummary != nil,
                isLoading: session.isLoadingUsage,
                hasError: session.usageLoadError != nil || session.usageSummaryIsStale
            ) {
            case .loading:
                billingSkeleton
            case .available:
                if let summary = session.usageSummary {
                    billingForm(summary: summary)
                } else {
                    unavailableForm
                }
            case .unavailable:
                unavailableForm
            }
        }
        .formStyle(.grouped)
        .macSettingsCenteredColumn()
        .navigationTitle("Billing & Usage")
        .task {
            await session.fetchUsageSummary()
        }
    }

    private func billingForm(summary: UsageSummary) -> some View {
        Form {
            Section {
                HStack {
                    Text("Plan")
                        .font(DesignTokens.Typography.body)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(BillingPlanPresentation.planName(summary.plan))
                            .font(DesignTokens.Typography.bodyBold)
                            .foregroundColor(summary.plan.lowercased() == "pro"
                                             ? DesignTokens.Color.brandBlue
                                             : DesignTokens.Color.labelSecondary)
                        if let status = BillingPlanPresentation.statusLabel(
                            plan: summary.plan,
                            status: summary.status
                        ) {
                            Text(status)
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.systemOrange)
                        }
                    }
                }
            } header: {
                Text("Current Plan")
            }

            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs + 2) {
                    HStack {
                        Text("Today")
                            .font(DesignTokens.Typography.body)
                        Spacer()
                        Text("\(summary.usage.day) / \(summary.limits.requestsPerDay) used")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(summary.remaining.day < 10
                                             ? DesignTokens.Color.systemOrange
                                             : DesignTokens.Color.labelSecondary)
                    }
                    ProgressView(
                        value: Double(summary.usage.day),
                        total: Double(max(summary.limits.requestsPerDay, 1))
                    )
                    .tint(summary.remaining.day < 10
                          ? DesignTokens.Color.systemOrange
                          : DesignTokens.Color.brandBlue)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs + 2) {
                    HStack {
                        Text("This Month")
                            .font(DesignTokens.Typography.body)
                        Spacer()
                        Text("\(summary.usage.month) / \(summary.limits.requestsPerMonth) used")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(summary.remaining.month < 50
                                             ? DesignTokens.Color.systemOrange
                                             : DesignTokens.Color.labelSecondary)
                    }
                    ProgressView(
                        value: Double(summary.usage.month),
                        total: Double(max(summary.limits.requestsPerMonth, 1))
                    )
                    .tint(summary.remaining.month < 50
                          ? DesignTokens.Color.systemOrange
                          : DesignTokens.Color.brandBlue)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            } header: {
                Text("Usage")
            }

            Section {
                Text("Subscription management is available in the iOS app.")
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            } header: {
                Text("Manage Subscription")
            }
        }
    }

    private var billingSkeleton: some View {
        Form {
            Section("Current Plan") {
                skeletonRow(width: 110)
            }
            Section("Usage") {
                skeletonRow(width: 210)
                skeletonRow(width: 190)
            }
        }
    }

    private func skeletonRow(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: 16)
            .redacted(reason: .placeholder)
            .shimmering()
            .padding(.vertical, 7)
    }

    private var unavailableForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("Billing is unavailable")
                        .font(DesignTokens.Typography.bodyBold)
                    Text(session.usageLoadError ?? "Rem couldn't load your plan and usage right now.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                    Button("Try Again") {
                        Task { await session.fetchUsageSummary() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
        }
    }
}
