import SwiftUI

/// Multi-step setup flow for configuring a local OpenClaw gateway.
/// Steps: Install CLI -> Start Gateway -> Configure AI Key -> Done.
struct LocalGatewaySetupView: View {
    let localGateway: LocalGatewayManager
    let onComplete: (GatewayConfig) -> Void
    let onCancel: () -> Void

    @State private var port = LocalGatewayManager.defaultPort
    @State private var isInstalling = false
    @State private var isStarting = false
    @State private var copied = false

    // BYOK state
    @State private var aiProvider: AIProvider = .anthropic
    @State private var apiKey = ""
    @State private var isSavingKey = false
    @State private var keySaveError: String?

    enum AIProvider: String, CaseIterable {
        case anthropic = "anthropic"
        case openai = "openai"

        var displayName: String {
            switch self {
            case .anthropic: "Anthropic (Claude)"
            case .openai: "OpenAI"
            }
        }

        var keyPlaceholder: String {
            switch self {
            case .anthropic: "sk-ant-..."
            case .openai: "sk-..."
            }
        }

        var envVarName: String {
            switch self {
            case .anthropic: "ANTHROPIC_API_KEY"
            case .openai: "OPENAI_API_KEY"
            }
        }
    }

    /// Current step based on gateway state.
    private var currentStep: Int {
        if !localGateway.isCLIInstalled { return 1 }
        if !localGateway.status.isRunning { return 2 }
        return 3
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("Local Gateway")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Run an OpenClaw gateway on this Mac -- no cloud needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Divider()

            // Step content
            Group {
                switch currentStep {
                case 1: installStep
                case 2: startStep
                default: apiKeyStep
                }
            }
            .frame(maxWidth: 420)

            Spacer()

            // Footer
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.horizontal)
        }
        .padding(32)
        .frame(width: 520, height: 580)
        .onAppear {
            localGateway.detectCLI()
        }
    }

    // MARK: - Step 1: Install CLI

    private var installStep: some View {
        VStack(spacing: 16) {
            stepHeader(number: 1, title: "Install OpenClaw CLI")

            Text("The OpenClaw CLI is required to run a local gateway.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if case .installingCLI(let message) = localGateway.status {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let reason) = localGateway.status {
                errorText(reason)
            }

            HStack(spacing: 12) {
                Button("Install Automatically") {
                    isInstalling = true
                    Task {
                        await localGateway.installCLI()
                        isInstalling = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)

                Button("Re-detect") {
                    localGateway.detectCLI()
                }
            }

            Divider()

            DisclosureGroup("Or install manually in Terminal") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run this command in Terminal:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(LocalGatewayManager.installCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        copyButton(LocalGatewayManager.installCommand)
                    }

                    Button("Open Terminal") {
                        LocalGatewayManager.openTerminal()
                    }
                    .font(.caption)
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    // MARK: - Step 2: Start Gateway

    private var startStep: some View {
        VStack(spacing: 16) {
            stepHeader(number: 2, title: "Start Gateway")

            LabeledContent("Port") {
                TextField("Port", value: $port, format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }

            if case .starting = localGateway.status {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting gateway...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let reason) = localGateway.status {
                errorText(reason)
            }

            Button("Start Gateway") {
                guard (1...65535).contains(port) else { return }
                isStarting = true
                Task {
                    // Let the CLI generate and persist the gateway token in
                    // the config file — we read it back via `currentGatewayToken()`.
                    await localGateway.start(port: port)
                    isStarting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isStarting)
        }
    }

    // MARK: - Step 3: API Key + Finish

    private var apiKeyStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Text("Gateway Running")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            stepHeader(number: 3, title: "Connect Your AI")

            Text("Provide an API key so the gateway can talk to your AI provider.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Provider", selection: $aiProvider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            SecureField(aiProvider.keyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)

            if let error = keySaveError {
                errorText(error)
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    finishSetup()
                }

                Button("Save & Finish") {
                    saveApiKeyAndFinish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKey)
            }

            Text("You can also set \(aiProvider.envVarName) as an environment variable.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func saveApiKeyAndFinish() {
        isSavingKey = true
        keySaveError = nil
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Persist provider choice in UserDefaults so we can display it later
        // in settings. The actual key wiring goes through the upstream config
        // path (models.providers.<provider>.apiKey) via `openclaw config set`.
        UserDefaults.standard.set(aiProvider.rawValue, forKey: "local_gateway_ai_provider")

        Task {
            do {
                try await localGateway.setProviderApiKey(
                    provider: aiProvider.rawValue,
                    apiKey: key
                )
                await localGateway.reloadWithApiKey()
                finishSetup()
            } catch {
                keySaveError = "Failed to save API key: \(error.localizedDescription)"
                isSavingKey = false
            }
        }
    }

    private func finishSetup() {
        // Read the canonical gateway token from the config file the CLI
        // just populated (gateway.auth.token). This is the single source
        // of truth upstream expects — we no longer generate our own.
        guard let token = LocalGatewayManager.currentGatewayToken(), !token.isEmpty else {
            // Empty / missing token means `openclaw gateway install` hasn't
            // written the token yet (or wrote a SecretRef, which we don't
            // resolve). Surface as an error rather than producing a
            // GatewayConfig that's guaranteed to fail auth.
            keySaveError = "Gateway installed but no auth token found in config. Try restarting the setup."
            isSavingKey = false
            return
        }
        let config = GatewayConfig(
            url: LocalGatewayManager.gatewayURL(port: port),
            token: token,
            provider: .local,
            displayName: "Local Gateway",
            isActive: true
        )
        onComplete(config)
    }

    // MARK: - Helpers

    private func stepHeader(number: Int, title: String) -> some View {
        Label("Step \(number): \(title)", systemImage: "\(number).circle.fill")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            LocalGatewayManager.copyToClipboard(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
        }
        .buttonStyle(.borderless)
    }
}
