import SwiftUI

/// Rem-native permissions screen for local Mac capabilities.
struct PermissionsTab: View {
    var calendarConnectorDestination: (() -> AnyView)? = nil

    @State private var monitor = MacPermissionMonitor()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Device access stays on this Mac")
                                .font(DesignTokens.Typography.body.weight(.semibold))
                                .foregroundColor(DesignTokens.Color.labelPrimary)
                            Text("Use this page for local macOS permissions. Account integrations such as Google Calendar, Gmail, and GitHub live in Connectors.")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }

            Section {
                ForEach(MacPermission.permissionsTabRows, id: \.id) { perm in
                    MacPermissionRow(
                        permission: perm,
                        status: monitor.status[perm] ?? .checking,
                        onGrant: {
                            Task {
                                _ = await MacPermissionChecker.request(perm)
                                await monitor.refresh()
                            }
                        },
                        onOpenSettings: {
                            openSettings(for: perm)
                        }
                    )
                }
            } header: {
                Text("Local Mac Access")
            } footer: {
                Text("These permissions let Rem understand your screen, automate UI actions, capture voice input, and notify you when assistant work needs attention.")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }

            Section {
                if let calendarConnectorDestination {
                    NavigationLink {
                        calendarConnectorDestination()
                    } label: {
                        calendarConnectorLabel(statusText: "Open Connector")
                    }
                } else {
                    calendarConnectorLabel(statusText: "Connector")
                }

                Text("Calendar access is account/capability readiness, not a standalone Mac permission row. Use Connectors to review local Apple Calendar and provider-backed calendars such as Google Calendar.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            } header: {
                Text("Managed Elsewhere")
            }

            Section {
                NavigationLink {
                    MacPermissionAdvancedView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(icon: "terminal.fill", color: .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Advanced")
                                .foregroundColor(DesignTokens.Color.labelPrimary)
                            Text("Runtime and upstream permission notes")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                        }
                    }
                }
            } header: {
                Text("Reference")
            }
        }
        .formStyle(.grouped)
        .macSettingsCenteredColumn()
        .navigationTitle("Permissions")
        .onAppear { monitor.startMonitoring() }
        .onDisappear { monitor.stopMonitoring() }
    }

    // MARK: - Settings navigation

    private func calendarConnectorLabel(statusText: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: MacPermission.calendar.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(MacPermission.calendar.tintColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Calendar")
                    .foregroundColor(DesignTokens.Color.labelPrimary)
                Text("Managed in Connectors")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }

            Spacer()

            Text(statusText)
                .font(DesignTokens.Typography.body)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
    }

    private func openSettings(for permission: MacPermission) {
        switch permission {
        case .accessibility:
            MacPermissionChecker.openAccessibilitySettings()
        case .screenRecording:
            MacPermissionChecker.openScreenRecordingSettings()
        case .microphone:
            MacPermissionChecker.openMicrophoneSettings()
        case .speechRecognition:
            MacPermissionChecker.openSpeechRecognitionSettings()
        case .calendar:
            MacPermissionChecker.openCalendarSettings()
        case .notifications:
            MacPermissionChecker.openNotificationSettings()
        }
    }
}

// MARK: - Permission Row

private struct MacPermissionRow: View {
    let permission: MacPermission
    let status: MacPermissionStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: 12) {
                Image(systemName: permission.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(permission.tintColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.displayName)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Text(permission.scopeLabel)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }

                Spacer()

                MacPermissionStatusBadge(status: status)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.subtitle)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !status.isGranted {
                    HStack(spacing: DesignTokens.Spacing.md) {
                        Button(primaryActionTitle) { onGrant() }
                            .remSettingsCTA(.primary, size: .compact)

                        Button("Open System Settings") { onOpenSettings() }
                            .buttonStyle(.plain)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.leading, 40)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private var primaryActionTitle: String {
        status == .denied ? "Review Access" : "Grant Access"
    }
}

private extension MacPermission {
    static var permissionsTabRows: [MacPermission] {
        [.accessibility, .screenRecording, .microphone, .speechRecognition, .notifications]
    }

    var tintColor: Color {
        switch self {
        case .accessibility: .blue
        case .screenRecording: .indigo
        case .microphone: .teal
        case .speechRecognition: .purple
        case .calendar: .red
        case .notifications: .orange
        }
    }

    var scopeLabel: String {
        switch self {
        case .accessibility:
            "System automation"
        case .screenRecording:
            "Screen context"
        case .microphone:
            "Voice input"
        case .speechRecognition:
            "Voice transcription"
        case .calendar:
            "Local Apple Calendar"
        case .notifications:
            "Desktop alerts"
        }
    }
}

private struct MacPermissionStatusBadge: View {
    let status: MacPermissionStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(status.label)
                .font(DesignTokens.Typography.body)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
    }

    private var dotColor: Color {
        switch status {
        case .checking, .notDetermined:
            .gray
        case .granted:
            .green
        case .denied:
            .red
        case .limited:
            .orange
        }
    }
}

private struct MacPermissionAdvancedView: View {
    var body: some View {
        Form {
            Section {
                LabelRow(icon: "shield.lefthalf.filled", title: "App Sandbox", detail: "Disabled")
                LabelRow(icon: "network", title: "Network", detail: "Allowed")
                LabelRow(icon: "folder", title: "Files", detail: "App-managed")
                LabelRow(icon: "terminal", title: "Shell", detail: "Gateway-managed")
            } footer: {
                Text("These runtime details are mostly useful for debugging gateway behavior. The main Permissions screen only shows access decisions users can grant or review.")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }

            Section {
                LabelRow(icon: "applescript", title: "Automation", detail: "Future capability")
                LabelRow(icon: "camera", title: "Camera", detail: "Not advertised")
                LabelRow(icon: "location", title: "Location", detail: "Not advertised")
            } header: {
                Text("Upstream parity")
            } footer: {
                Text("OpenClaw tracks additional macOS permissions. Rem only promotes rows here when they map to a user-visible Rem capability.")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
        }
        .formStyle(.grouped)
        .macSettingsCenteredColumn()
        .navigationTitle("Advanced")
    }
}

private struct LabelRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, color: .gray)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
    }
}
