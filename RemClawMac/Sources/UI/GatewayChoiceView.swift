import SwiftUI

/// Gateway choice screen — used for both onboarding (post-sign-in) and
/// "Add Gateway" from settings. Thin Mac wrapper around the shared
/// `SharedChooseGatewayView` so the cards, layout, and copy stay in lock-step
/// with iOS. Handles the Mac-specific Cloud Deploy + LocalGatewaySetup flows.
struct GatewayChoiceView: View {
    @Environment(MacGatewaySessionManager.self) private var session
    let localGateway: LocalGatewayManager
    let configStore: GatewayConfigStore
    /// Called when a gateway is successfully added. Nil = embedded in onboarding (no dismiss).
    var onDismiss: (() -> Void)?

    @State private var discovery = LocalGatewayDiscovery()
    @State private var showLocalSetup = false

    /// Whether a local gateway config already exists.
    private var hasLocalGateway: Bool {
        configStore.configs.contains(where: { $0.provider == .local })
    }

    var body: some View {
        ZStack {
            SharedChooseGatewayView(
                onCloudDeploy: {
                    Task { await runCloudDeploy() }
                },
                onLocalGateway: { showLocalSetup = true },
                localGatewayActionLabel: "Run Locally on This Mac",
                localGatewaySubtitle: hasLocalGateway
                    ? "A local gateway is already configured."
                    : "Runs as a local process. Fast, private, no hosting costs.",
                localGatewayDisabled: hasLocalGateway,
                discovery: discovery,
                onConnect: { config in
                    configStore.save(config)
                    configStore.setActive(id: config.id)
                    session.configure(gatewayURL: config.url, gatewayToken: config.token, provider: config.provider)
                    onDismiss?()
                },
                onCancel: onDismiss
            )

            // Mac shows a deploy-progress overlay while the cloud deploy runs.
            if session.deployPhase.isDeploying {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(session.deployPhase.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLocalSetup) {
            LocalGatewaySetupView(
                localGateway: localGateway,
                onComplete: { config in
                    configStore.save(config)
                    configStore.setActive(id: config.id)
                    session.configure(gatewayURL: config.url, gatewayToken: config.token, provider: config.provider)
                    showLocalSetup = false
                    onDismiss?()
                },
                onCancel: {
                    showLocalSetup = false
                }
            )
        }
    }

    /// Runs the existing Mac cloud-deploy two-step: try fetch credentials,
    /// fall back to deploy if no gateway is provisioned yet. Errors leave
    /// the session state to surface (deployPhase, etc.) and don't dismiss.
    private func runCloudDeploy() async {
        do {
            try await session.fetchGatewayCredentials()
            onDismiss?()
        } catch MacGatewayError.noGatewayDeployed {
            do {
                try await session.deployGateway()
                onDismiss?()
            } catch {
                // deployPhase is set to .failed by deployGateway()
            }
        } catch {
            // fetchGatewayCredentials failed; session state reflects the error
        }
    }
}
