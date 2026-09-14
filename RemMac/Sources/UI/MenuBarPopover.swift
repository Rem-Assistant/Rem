import SwiftUI

/// Main popover content for Rem for Mac's menu bar extra.
/// Shows gateway configuration, connection status, and quick entry points.
struct MenuBarPopover: View {
    @Environment(MacGatewaySessionManager.self) private var session
    @Environment(\.openWindow) private var openWindow

    @State private var urlInput: String = ""
    @State private var tokenInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if session.isConfigured {
                connectedView
            } else {
                configurationView
            }

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            urlInput = session.storedGatewayURL ?? ""
            tokenInput = session.storedGatewayToken ?? ""
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: session.menuBarIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("Rem")
                    .font(.headline)
                Text(session.connectionState.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            statusBadge
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusBadge: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .pairingRequired: .yellow
        case .unauthorized: .red
        case .unreachable: .red
        case .disconnected: .gray
        }
    }

    // MARK: - Connected view

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = session.gatewayHostDisplay {
                LabeledContent("Connection", value: host)
                    .font(.caption)
            }

            quickActionsList

            HStack(spacing: 8) {
                if session.connectionState.isConnected {
                    Button {
                        openMainWindow(screen: .chat)
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("menu-bar-chat-button")

                    Button("Reconnect") {
                        session.reconnect()
                    }
                    .controlSize(.small)
                } else {
                    Button("Connect") {
                        session.connectIfConfigured()
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button("Disconnect") {
                    session.clearConfiguration()
                }
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    private func openMainWindow(screen: MainWindowScreenRoute) {
        MacMainWindowPresenter.openMainWindow(
            route: screen,
            openWindow: openWindow
        )
    }

    private var quickActionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quick Actions")
                .font(.caption2)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            quickActionButton(icon: "calendar", label: "Open Agenda", screen: .agenda)
            quickActionButton(icon: "tray", label: "Open Inbox", screen: .inbox)
            quickActionButton(icon: "clock.arrow.circlepath", label: "Open Sessions", screen: .sessions)
            quickActionButton(icon: "square.and.pencil", label: "Start New Chat", screen: .chat)
        }
    }

    private func quickActionButton(icon: String, label: String, screen: MainWindowScreenRoute) -> some View {
        Button {
            openMainWindow(screen: screen)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .frame(width: 14)
                Text(label)
                    .font(.caption)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Configuration view

    private var configurationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configure Gateway")
                .font(.subheadline)
                .fontWeight(.medium)

            TextField("Gateway URL", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            SecureField("Token", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Button("Connect") {
                guard !urlInput.isEmpty, !tokenInput.isEmpty else { return }
                session.configure(gatewayURL: urlInput, gatewayToken: tokenInput)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(urlInput.isEmpty || tokenInput.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("v\(appVersion)")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
