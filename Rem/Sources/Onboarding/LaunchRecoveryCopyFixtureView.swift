import SwiftUI

#if DEBUG
struct LaunchRecoveryCopyFixtureView: View {
    private let fixtureGateway = RemGatewaySessionManager()
    private let showBannerOnly = ProcessInfo.processInfo.arguments.contains("--rem-launch-recovery-banner-section")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                fixtureHeader

                if showBannerOnly {
                    bannerSection
                } else {
                    launchSection

                    bannerSection
                }
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .environment(fixtureGateway)
    }

    private var fixtureHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Launch Recovery Copy")
                .font(DesignTokens.Typography.title3Bold)
                .foregroundColor(DesignTokens.Color.labelPrimary)
            Text("Deterministic fixture for local and managed cloud gateway recovery screenshots.")
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Launch")
                .font(DesignTokens.Typography.bodyBold)
                .foregroundColor(DesignTokens.Color.labelPrimary)

            launchFailureFrame("Mac gateway unreachable") {
                LaunchScreenView(
                    state: .failed,
                    connectionState: .unreachable(nil),
                    gatewayProvider: .local,
                    onRetry: {},
                    onOpenSettings: {},
                    onContinue: {}
                )
            }

            launchFailureFrame("Cloud approval required") {
                LaunchScreenView(
                    state: .failed,
                    connectionState: .pairingRequired,
                    gatewayProvider: .fly,
                    onRetry: {},
                    onOpenSettings: {},
                    onContinue: {}
                )
            }

            launchFrame("Mac gateway connecting") {
                LaunchScreenView(state: .connecting, gatewayProvider: .local)
            }

            launchFrame("Cloud gateway waking") {
                LaunchScreenView(state: .connecting, gatewayProvider: .fly)
            }
        }
    }

    private var bannerSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Disconnected Banner")
                .font(DesignTokens.Typography.bodyBold)
                .foregroundColor(DesignTokens.Color.labelPrimary)

            bannerFrame("Mac gateway unreachable") {
                GatewayDisconnectedBanner(
                    gatewayProvider: .local,
                    fixtureConnectionState: .unreachable(nil),
                    fixtureIsAutoRePairing: false,
                    onOpenRecovery: {}
                )
            }

            bannerFrame("Cloud gateway connecting") {
                GatewayDisconnectedBanner(
                    gatewayProvider: .fly,
                    fixtureConnectionState: .connecting,
                    fixtureIsAutoRePairing: false,
                    onOpenRecovery: {}
                )
            }

            bannerFrame("Cloud trust refresh") {
                GatewayDisconnectedBanner(
                    gatewayProvider: .fly,
                    fixtureConnectionState: .connecting,
                    fixtureIsAutoRePairing: true,
                    onOpenRecovery: {}
                )
            }
        }
    }

    private func launchFailureFrame<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        fixtureFrame(title: title, height: 360) {
            content()
        }
    }

    private func launchFrame<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        fixtureFrame(title: title, height: 240) {
            content()
        }
    }

    private func bannerFrame<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        fixtureFrame(title: title, height: 112) {
            content()
        }
    }

    private func fixtureFrame<Content: View>(
        title: String,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)

            content()
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                )
        }
    }
}

struct LaunchConnectionRecoveryRouteFixtureView: View {
    @State private var showConnectionRecovery = false
    private let entryPoint = LaunchConnectionRecoveryRouteFixtureEntryPoint.fromLaunchArguments()
    private let startsOpen = ProcessInfo.processInfo.arguments.contains("--rem-launch-connection-recovery-open-fixture")
    private let fixtureGateway = RemGatewaySessionManager()

    var body: some View {
        routeContent
            .environment(fixtureGateway)
            .sheet(isPresented: $showConnectionRecovery) {
                NavigationStack {
                    SharedGatewayRecoveryDestinationFixtureView(scenario: .cloudApprovalPending)
                }
            }
            .task {
                guard startsOpen, !showConnectionRecovery else { return }
                try? await Task.sleep(for: .milliseconds(250))
                showConnectionRecovery = true
            }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch entryPoint {
        case .launch:
            LaunchScreenView(
                state: .failed,
                connectionState: .pairingRequired,
                gatewayProvider: .fly,
                onRetry: {},
                onOpenSettings: { showConnectionRecovery = true },
                onContinue: {}
            )
        case .banner:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Cloud gateway needs approval")
                        .font(DesignTokens.Typography.title3Bold)
                    Text("Banner recovery should open the gateway-owned approval surface, not a separate connection hub.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
                GatewayDisconnectedBanner(
                    gatewayProvider: .fly,
                    fixtureConnectionState: .pairingRequired,
                    fixtureIsAutoRePairing: false,
                    onOpenRecovery: { showConnectionRecovery = true }
                )
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DesignTokens.Color.backgroundPrimary)
        }
    }
}

private enum LaunchConnectionRecoveryRouteFixtureEntryPoint {
    case launch
    case banner

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        arguments.contains("--rem-launch-connection-recovery-banner-fixture") ? .banner : .launch
    }
}
#endif
