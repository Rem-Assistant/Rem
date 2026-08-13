import SwiftUI

// MARK: - Bring Your Own Key (shared across iOS and macOS)

/// "Provider Keys" — a multi-provider BYOK surface. A user may bring keys for
/// any subset of providers (Anthropic, OpenAI, Google, GMI, ...). Each key runs
/// Rem on the **unlimited** tier for that provider (they pay the provider
/// directly; Rem's request quota no longer applies).
///
/// Lives under **Agents → Controls** (the gateway/agent runtime owns provider
/// auth), next to Connections / Capabilities / Memory — not under Billing.
///
/// Design mirrors OpenClaw upstream's `auth-profiles` shape
/// (`openclaw/src/agents/auth-profiles/types.ts` `ApiKeyCredential`): each
/// credential is `{ provider, key, displayName }`. Storage is fully shared via
/// `BYOKCredentialStore` (Keychain only — iOS `RemCredentialStore`, Mac
/// `MacBYOKKeychain`), one row per provider at `byok.{provider}.apiKey`.
struct SharedBYOKSettingsView: View {

    @State private var configured: [BYOKProvider] = BYOKCredentialStore.configuredProviders
    @State private var isAddingKey = false
    @State private var editingProvider: BYOKProvider?

    private var available: [BYOKProvider] { BYOKCredentialStore.availableProviders }

    private static let footerText = "Each key runs Rem on the unlimited tier for that provider — you pay the provider directly, so usage isn't capped by your plan quota. Add keys for as many providers as you like."

    @ViewBuilder
    private var content: some View {
        if configured.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("No provider keys yet")
                        .font(DesignTokens.Typography.bodyBold)
                    Text("Tap + to add a key for a provider.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
                .padding(.vertical, 2)
            } footer: {
                Text(Self.footerText)
                    .font(DesignTokens.Typography.caption1)
            }
        } else {
            Section {
                ForEach(configured) { provider in
                    Button {
                        editingProvider = provider
                    } label: {
                        providerRow(provider)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("byok-provider-row-\(provider.id)")
                }
            } header: {
                Text("Your Keys")
            } footer: {
                Text(Self.footerText)
                    .font(DesignTokens.Typography.caption1)
            }
        }
    }

    private func providerRow(_ provider: BYOKProvider) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelPrimary)
                Text(provider.detail)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Circle()
                .fill(DesignTokens.Color.brandBlue)
                .frame(width: 8, height: 8)
            Text("Saved")
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(DesignTokens.Color.labelTertiary)
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        platformContainer
            .navigationTitle("Provider Keys")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingKey = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(available.isEmpty)
                    .accessibilityLabel("Add Provider Key")
                    .accessibilityIdentifier("byok-add-key-button")
                }
            }
            .sheet(isPresented: $isAddingKey) {
                BYOKAddKeySheet(providers: available) { providerID, key in
                    BYOKCredentialStore.setKey(key, for: providerID)
                    refresh()
                }
            }
            .sheet(item: $editingProvider) { provider in
                BYOKEditKeySheet(
                    provider: provider,
                    onSave: { key in
                        BYOKCredentialStore.setKey(key, for: provider.id)
                        refresh()
                    },
                    onRemove: {
                        BYOKCredentialStore.setKey(nil, for: provider.id)
                        refresh()
                    }
                )
            }
            .onAppear { refresh() }
    }

    /// iOS uses `List` + insetGrouped; macOS uses `Form` + grouped in the
    /// centered settings column — matching `SharedSettingsView`.
    @ViewBuilder
    private var platformContainer: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { content }
            .listStyle(.insetGrouped)
        #endif
    }

    private func refresh() {
        configured = BYOKCredentialStore.configuredProviders
    }
}

// MARK: - Add Key sheet (pick a provider, enter its key)
// Internal (not private) so the Models page can reuse the same key-entry sheet
// when its collapsible "API Keys" section adds a provider key.

struct BYOKAddKeySheet: View {
    let providers: [BYOKProvider]
    let onSave: (_ providerID: String, _ key: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var keyInput: String = ""

    init(providers: [BYOKProvider], onSave: @escaping (_ providerID: String, _ key: String) -> Void) {
        self.providers = providers
        self.onSave = onSave
        _selectedID = State(initialValue: providers.first?.id ?? "")
    }

    private var selectedProvider: BYOKProvider? { BYOKProvider.provider(id: selectedID) }

    private var canSave: Bool {
        !selectedID.isEmpty && !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $selectedID) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                } header: {
                    Text("Provider")
                }

                Section {
                    SecureField(selectedProvider?.keyPlaceholder ?? "API key", text: $keyInput)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        #endif
                } header: {
                    Text("API Key")
                } footer: {
                    if let detail = selectedProvider?.detail {
                        Text(detail)
                            .font(DesignTokens.Typography.caption1)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 240)
            #endif
            .navigationTitle("Add Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selectedID, keyInput)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

// MARK: - Edit Key sheet (replace or remove an existing provider key)
// Internal (not private) so the Models page can reuse it (see BYOKAddKeySheet).

struct BYOKEditKeySheet: View {
    let provider: BYOKProvider
    let onSave: (_ key: String) -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyInput: String = ""

    private var canSave: Bool {
        !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Circle()
                            .fill(DesignTokens.Color.brandBlue)
                            .frame(width: 8, height: 8)
                        Text("A key is saved for \(provider.displayName).")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                        Spacer(minLength: 0)
                    }
                }

                Section {
                    SecureField("Replace \(provider.displayName) key", text: $keyInput)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        #endif
                    Button("Update Key") {
                        onSave(keyInput)
                        dismiss()
                    }
                    .disabled(!canSave)
                } header: {
                    Text("API Key")
                } footer: {
                    Text(provider.detail)
                        .font(DesignTokens.Typography.caption1)
                }

                Section {
                    Button("Remove Key", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 280)
            #endif
            .navigationTitle(provider.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
