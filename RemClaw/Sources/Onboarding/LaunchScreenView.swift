import Combine
import SwiftUI

private let launchLogoBaseSize: CGFloat = 48
private let launchLogoRefDimension: CGFloat = 375

enum GatewayRecoveryCopy {
    static func launchConnectingText(provider: GatewayProvider?) -> String {
        switch provider {
        case .local:
            return "Connecting to your Mac gateway..."
        case .fly:
            return "Waking your cloud gateway..."
        default:
            return "Connecting to your gateway..."
        }
    }

    static func launchFailedText(
        for state: RemGatewayConnectionState,
        provider: GatewayProvider?
    ) -> String {
        switch state {
        case .pairingRequired:
            return provider == .fly
                ? "Cloud gateway approval needs attention"
                : "Approve this device on your gateway"
        case .unreachable:
            switch provider {
            case .local:
                return "Your Mac gateway isn't reachable"
            case .fly:
                return "Your cloud gateway isn't reachable"
            default:
                return "Can't reach your gateway"
            }
        case .connecting:
            return launchConnectingText(provider: provider)
        default:
            return provider == .local
                ? "Your Mac gateway isn't connected"
                : "Can't reach your gateway"
        }
    }

    static func launchFailedSubtitle(
        for state: RemGatewayConnectionState,
        provider: GatewayProvider?
    ) -> String {
        switch state {
        case .pairingRequired:
            return provider == .fly
                ? "Approve this device for your cloud gateway before continuing."
                : "Open Rem on your Mac and approve this iPhone before Mac-local actions can run."
        case .unauthorized:
            return provider == .fly
                ? "Your cloud pairing may have expired. Review the connection before retrying."
                : "This iPhone may no longer be trusted by your Mac gateway. Review the connection before retrying."
        case .unreachable:
            switch provider {
            case .local:
                return "Wake your Mac, keep Rem open, and make sure this iPhone is on the same network."
            case .fly:
                return "Your cloud gateway may still be waking up. You can continue after it reconnects."
            default:
                return "Check the gateway device, network, and pairing state before retrying."
            }
        case .disconnected:
            return provider == .local
                ? "Open Rem on your Mac, then retry from this iPhone."
                : "Reconnect the selected gateway, then retry."
        case .connecting:
            return provider == .local
                ? "Reaching the gateway running on your Mac."
                : "Reaching the selected gateway."
        case .connected:
            return "Your gateway is online."
        }
    }

    static func bannerAutoRePairSubtitle(provider: GatewayProvider?) -> String {
        switch provider {
        case .local:
            return "Restoring trust with your Mac gateway. Mac-local actions need that Mac running and reachable."
        case .fly:
            return "Restoring trust with your cloud gateway. This takes a few seconds."
        default:
            return "Restoring trust with your gateway. This takes a few seconds."
        }
    }

    static func bannerSubtitle(
        for state: RemGatewayConnectionState,
        provider: GatewayProvider?
    ) -> String {
        switch state {
        case .pairingRequired:
            return provider == .fly
                ? "Review cloud approval before resetting pairing or retrying."
                : "Review the pending approval on the gateway before resetting pairing or retrying."
        case .connecting:
            switch provider {
            case .local:
                return "Reaching the gateway running on your Mac. Cloud gateways cannot perform Mac-local actions for it."
            case .fly:
                return "Reaching your cloud gateway."
            default:
                return "Establishing connection to your gateway."
            }
        case .unauthorized:
            return "Your pairing may have expired. Review connection recovery or reset pairing."
        case .unreachable:
            if state.needsDeviceRePair {
                return "This device token is no longer trusted by the gateway. Review recovery before resetting trust."
            }
            switch provider {
            case .local:
                return "Your Mac gateway is unreachable. Cloud gateways cannot perform Mac-local actions for it."
            case .fly:
                return "Your cloud gateway is unreachable. Check your connection or retry."
            default:
                return "Cannot reach your gateway. Review recovery options or retry."
            }
        case .disconnected:
            switch provider {
            case .local:
                return "Reconnect to your Mac gateway or review connection recovery."
            case .fly:
                return "Reconnect to your cloud gateway or review recovery."
            default:
                return "Reconnect to your gateway or review connection recovery."
            }
        case .connected:
            return "Your gateway is online."
        }
    }
}

struct LaunchScreenView: View {
    enum State: Equatable {
        /// Initial splash — logo only, no status text.
        case splash
        /// Gateway is configured; waiting for WebSocket to connect.
        case connecting
        /// Connection failed after timeout.
        case failed
        /// Auth + connection resolved — ready to show main app.
        case ready
    }

    var state: State = .splash
    var connectionState: RemGatewayConnectionState = .disconnected
    var gatewayProvider: GatewayProvider?
    var onRetry: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onContinue: (() -> Void)?

    /// Seconds of `.connecting` before the bail-out controls (Retry / Continue
    /// Anyway) fade in. The auto-retry keeps running in the background the whole
    /// time — this only gives a genuinely-offline user an escape hatch without
    /// waiting out the full cold-boot budget. Overridable for previews/tests.
    var escapeHatchDelay: TimeInterval = 11

    /// Revealed after `escapeHatchDelay` while `.connecting`, so the bail-out
    /// controls appear without the screen flipping to the honest `.failed` state.
    @SwiftUI.State private var showConnectingEscapeHatch = false

    var body: some View {
        GeometryReader { geometry in
            let short = min(geometry.size.width, geometry.size.height)
            let scale = min(max(short / launchLogoRefDimension, 0.85), 1.35)
            let logoSize = launchLogoBaseSize * scale
            let cornerRadius = (logoSize / launchLogoBaseSize) * 12

            VStack(spacing: 0) {
                Spacer()

                // Logo + title (centered)
                HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                    launchIcon(size: logoSize, cornerRadius: cornerRadius)
                    Text("Rem")
                        .font(.system(size: logoSize, weight: .bold).width(.standard))
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                        .tracking(DesignTokens.Typography.title3Tracking)
                }

                Spacer()

                // Connection status (bottom-aligned)
                if state != .splash && state != .ready {
                    connectionStatusView
                        .padding(.bottom, DesignTokens.Spacing.xxl)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .task(id: state) {
                            // Reveal the bail-out controls after a short delay while
                            // connecting; reset whenever the state changes.
                            showConnectingEscapeHatch = false
                            guard state == .connecting else { return }
                            try? await Task.sleep(
                                nanoseconds: UInt64(escapeHatchDelay * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showConnectingEscapeHatch = true
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.Color.backgroundPrimary)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: state)
    }

    // MARK: - Connection Status

    @ViewBuilder
    private var connectionStatusView: some View {
        switch state {
        case .splash, .ready:
            EmptyView()

        case .connecting:
            VStack(spacing: DesignTokens.Spacing.md) {
                Text(GatewayRecoveryCopy.launchConnectingText(provider: gatewayProvider))
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)

                // Escape hatch for a genuinely-offline user: the auto-retry keeps
                // running in the background, but after a short delay we let the
                // user bail (Retry re-warms + reconnects, Continue enters the app).
                if showConnectingEscapeHatch {
                    recoveryButtons
                        .padding(.top, DesignTokens.Spacing.xs)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)

        case .failed:
            VStack(spacing: DesignTokens.Spacing.md) {
                Text(failedStatusText)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .multilineTextAlignment(.center)

                Text(failedStatusSubtitle)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, DesignTokens.Spacing.xs)

                recoveryButtons
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
        }
    }

    /// Retry + Continue Anyway controls, shared by the delayed `.connecting`
    /// escape hatch and the terminal `.failed` state so both look identical.
    @ViewBuilder
    private var recoveryButtons: some View {
        Button {
            primaryRecoveryAction()
        } label: {
            Text(primaryRecoveryButtonLabel)
                .font(DesignTokens.Typography.bodyBold)
                .foregroundColor(DesignTokens.Color.labelPrimary)
                .frame(maxWidth: .infinity)
                .padding(DesignTokens.Spacing.md)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .cornerRadius(DesignTokens.CornerRadius.medium)
        }

        Button {
            onContinue?()
        } label: {
            Text("Continue Anyway")
                .font(DesignTokens.Typography.bodyBold)
                .foregroundColor(DesignTokens.Color.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(DesignTokens.Spacing.md)
                .background(DesignTokens.Color.buttonBackground)
                .cornerRadius(DesignTokens.CornerRadius.medium)
        }
    }

    // MARK: - Helpers

    private var failedStatusText: String {
        GatewayRecoveryCopy.launchFailedText(for: connectionState, provider: gatewayProvider)
    }

    private var failedStatusSubtitle: String {
        GatewayRecoveryCopy.launchFailedSubtitle(for: connectionState, provider: gatewayProvider)
    }

    private var primaryRecoveryButtonLabel: String {
        switch connectionState {
        case .pairingRequired:
            return "Review Connection"
        default:
            return "Retry Gateway"
        }
    }

    private func primaryRecoveryAction() {
        switch connectionState {
        case .unauthorized, .unreachable:
            onRetry?()
        case .pairingRequired:
            onOpenSettings?()
        case .connected, .connecting, .disconnected:
            onRetry?()
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private func launchIcon(size: CGFloat, cornerRadius: CGFloat) -> some View {
        if let appIcon = UIImage(named: "AppIcon") ?? Bundle.main.launchAppIcon {
            Image(uiImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: size * 0.55))
                        .foregroundColor(Color.accentColor)
                )
        }
    }
}

private extension Bundle {
    var launchAppIcon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last {
            return UIImage(named: lastIcon)
        }
        return nil
    }
}

#Preview("Splash") {
    LaunchScreenView(state: .splash)
}

#Preview("Connecting") {
    LaunchScreenView(state: .connecting)
}

#Preview("Failed — Can't reach server") {
    LaunchScreenView(
        state: .failed,
        connectionState: .unreachable(nil),
        onRetry: {},
        onOpenSettings: {},
        onContinue: {}
    )
}

#Preview("Failed — Pairing required") {
    LaunchScreenView(
        state: .failed,
        connectionState: .pairingRequired,
        onRetry: {},
        onOpenSettings: {},
        onContinue: {}
    )
}
