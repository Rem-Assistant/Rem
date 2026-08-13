import SwiftUI

#if DEBUG

/// Debug-only entry point: lets the user configure the SomeClaw relay
/// endpoint, toggle self-signed cert acceptance, see live connection state,
/// and open the chat surface. Endpoint and cert toggle persist across
/// launches via `UserDefaults` (debug-only key, never bundled in release).
struct SomeClawSettingsView: View {

    @AppStorage("debug.someclaw.endpoint")
    private var endpointString: String = SomeClawSettingsView.defaultEndpoint

    @AppStorage("debug.someclaw.allowSelfSignedCert")
    private var allowSelfSignedCert: Bool = true

    @State private var draftEndpoint: String = ""
    @State private var client: SomeClawClient?
    @State private var viewModel: SomeClawChatViewModel?
    @State private var showInvalidURLAlert = false

    static let defaultEndpoint = "wss://192.168.1.100:8888/ws"

    var body: some View {
        Form {
            Section {
                TextField("Relay URL", text: $draftEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Toggle("Allow self-signed certificate", isOn: $allowSelfSignedCert)

                Button("Save & Reconnect") {
                    saveEndpoint()
                }
                .disabled(draftEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Relay endpoint")
            } footer: {
                Text(
                    "Self-signed cert support keeps the channel TLS-encrypted "
                    + "but skips identity verification. Use only for "
                    + "local-network development relays."
                )
            }

            Section {
                statusRow

                Button(buttonTitle) {
                    toggleConnection()
                }
                .disabled(client == nil)
            } header: {
                Text("Connection")
            }

            Section {
                NavigationLink {
                    chatDestination
                } label: {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(.tint)
                        Text("Open Chat")
                    }
                }
                .disabled(viewModel == nil)
            } header: {
                Text("Chat")
            } footer: {
                Text("Messages are kept in memory only — the relay does not expose a history endpoint.")
            }
        }
        .navigationTitle("SomeClaw Relay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configureIfNeeded() }
        .alert("Invalid URL", isPresented: $showInvalidURLAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Use a wss:// or ws:// URL, e.g. wss://192.168.1.100:8888/ws")
        }
    }

    @ViewBuilder
    private var chatDestination: some View {
        if let viewModel {
            SomeClawChatView(viewModel: viewModel)
        } else {
            Text("Configure a relay URL first.")
        }
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
            Spacer()
            if case .failed(let message) = client?.connectionState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var statusText: String {
        switch client?.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected, .none: return "Disconnected"
        case .failed: return "Connection error"
        }
    }

    private var statusColor: Color {
        switch client?.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected, .none: return .gray
        }
    }

    private var buttonTitle: String {
        switch client?.connectionState {
        case .connected, .connecting: return "Disconnect"
        default: return "Connect"
        }
    }

    private func toggleConnection() {
        guard let client else { return }
        switch client.connectionState {
        case .connected, .connecting:
            client.disconnect()
        default:
            client.connect()
        }
    }

    private func configureIfNeeded() {
        if draftEndpoint.isEmpty { draftEndpoint = endpointString }
        guard client == nil, let url = URL(string: endpointString) else { return }
        let newClient = SomeClawClient(endpoint: url, allowSelfSignedCert: allowSelfSignedCert)
        client = newClient
        viewModel = SomeClawChatViewModel(client: newClient)
    }

    private func saveEndpoint() {
        let trimmed = draftEndpoint.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws" else {
            showInvalidURLAlert = true
            return
        }
        endpointString = trimmed
        if let client {
            client.updateEndpoint(url, allowSelfSignedCert: allowSelfSignedCert)
        } else {
            configureIfNeeded()
        }
    }
}

#endif
