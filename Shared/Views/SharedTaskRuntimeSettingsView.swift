import SwiftUI

// MARK: - Task & Cloud Settings (shared across iOS and macOS)

/// Settings detail for task collaboration: the GMI BYOK key (Keychain only)
/// and the default task runtime (UserDefaults `rem.task.defaultRuntime`).
///
/// Fully shared (DRY rule): the only platform branching lives in
/// `TaskRuntimeSettingsStore`, which routes the secret to the correct
/// Keychain accessor and offers the platform-appropriate runtime options.
struct SharedTaskRuntimeSettingsView: View {
    @State private var keyInput: String = ""
    @State private var hasKey: Bool = TaskRuntimeSettingsStore.hasGMIKey
    @State private var selectedRuntime: TaskRuntimeKind = TaskRuntimeSettingsStore.defaultRuntime

    private var content: some View {
        Group {
            // MARK: Model provider API key

            Section {
                SecureField("Provider API key", text: $keyInput)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Circle()
                        .fill(hasKey ? DesignTokens.Color.brandBlue : DesignTokens.Color.labelSecondary)
                        .frame(width: 8, height: 8)
                    Text(hasKey ? "A model provider key is saved in the Keychain." : "No model provider key saved.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Spacer(minLength: 0)
                }

                Button("Save Key") { saveKey() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasKey {
                    Button("Clear Key", role: .destructive) { clearKey() }
                }
            } header: {
                Text("Model Provider Key")
            } footer: {
                Text("Used by the Rem runtime. Stored only in the Keychain — never written to a config file or plist.")
                    .font(DesignTokens.Typography.caption1)
            }

            // MARK: Default Task Runtime

            Section {
                Picker("Default runtime", selection: $selectedRuntime) {
                    ForEach(TaskRuntimeSettingsStore.selectableRuntimes, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: selectedRuntime) { _, newValue in
                    TaskRuntimeSettingsStore.defaultRuntime = newValue
                }
            } header: {
                Text("Default Task Runtime")
            } footer: {
                Text("Where new tasks run by default. You can still hand an individual task to another runtime.")
                    .font(DesignTokens.Typography.caption1)
            }
        }
    }

    var body: some View {
        platformContainer
            .navigationTitle("Tasks & Cloud")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                hasKey = TaskRuntimeSettingsStore.hasGMIKey
                selectedRuntime = TaskRuntimeSettingsStore.defaultRuntime
            }
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

    // MARK: - Actions

    private func saveKey() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        TaskRuntimeSettingsStore.gmiApiKey = trimmed
        keyInput = ""
        hasKey = TaskRuntimeSettingsStore.hasGMIKey
    }

    private func clearKey() {
        TaskRuntimeSettingsStore.gmiApiKey = nil
        keyInput = ""
        hasKey = TaskRuntimeSettingsStore.hasGMIKey
    }
}
