import SwiftUI

/// Shared "Delete Account" confirmation sheet for iOS and macOS.
/// Requires the user to type "delete" before the destructive action is enabled.
struct SharedDeleteAccountSheet: View {
    @Binding var confirmText: String
    @Binding var isDeleting: Bool
    var onDelete: () -> Void
    var onCancel: () -> Void

    private var isConfirmed: Bool {
        confirmText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("This will permanently delete your account, your AI gateway, and all conversation history. This action cannot be undone.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Type **delete** to confirm")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("delete", text: $confirmText)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(8)
                }

                Button {
                    onDelete()
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                                #if os(iOS)
                                .tint(.white)
                                #endif
                        } else {
                            Text("Delete Account")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(isConfirmed ? .red : .gray)
                .disabled(!isConfirmed || isDeleting)

                Spacer()
            }
            .padding(16)
            .navigationTitle("Delete Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .disabled(isDeleting)
                }
            }
        }
        #if os(macOS)
        .frame(width: 400, height: 280)
        #endif
    }
}

#if DEBUG
private struct SharedDeleteAccountSheetPreview: View {
    @State private var confirmText = ""
    @State private var isDeleting = false

    var body: some View {
        SharedDeleteAccountSheet(
            confirmText: $confirmText,
            isDeleting: $isDeleting,
            onDelete: {},
            onCancel: {}
        )
    }
}

#Preview("Delete Account") {
    SharedDeleteAccountSheetPreview()
}
#endif

// MARK: - Shared Account Deletion Logic

#if os(iOS)
/// Calls DELETE /api/v1/auth/me on the backend via iOS AuthenticatedHttpClient.
/// Returns `nil` on success, or an error message string on failure.
/// On macOS, account deletion is handled by MacGatewaySessionManager.deleteAccount().
@MainActor
func performAccountDeletion() async -> String? {
    do {
        #if os(iOS)
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/auth/me",
            method: "DELETE"
        )
        #else
        guard let token = KeychainStore.loadString(service: "app.remclaw.mac", account: "backend.token"),
              let baseURL = UserDefaults.standard.string(forKey: "backend_url") else {
            return "Not signed in."
        }
        guard let url = URL(string: baseURL + "/api/v1/auth/me") else {
            return "Invalid backend URL"
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        ClientVersion.setHeaders(on: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return "Unexpected server response"
        }
        #endif
        if (200...299).contains(http.statusCode) {
            return nil // success
        } else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            return "Failed to delete account: \(body)"
        }
    } catch {
        return "Network error: \(error.localizedDescription)"
    }
}
#endif
