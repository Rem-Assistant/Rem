import SwiftUI

/// Banner shown when the gateway is not fully connected but credentials exist.
/// Displays state-specific messaging and an actionable CTA for each connection state.
struct GatewayDisconnectedBanner: View {
    @Environment(RemGatewaySessionManager.self) private var gateway
    var gatewayProvider: GatewayProvider? = nil
    #if DEBUG
    var fixtureConnectionState: RemGatewayConnectionState?
    var fixtureIsAutoRePairing: Bool?
    #endif
    var onOpenRecovery: (() -> Void)?

    var body: some View {
        // #306 (Pairing recovery UX epic): automatic pairing recovery wins
        // over the state-based banner while we recover a signature-expired or
        // scope-upgrade pairing on their behalf.
        #if DEBUG
        let connectionState = fixtureConnectionState ?? gateway.connectionState
        let isAutoRePairInProgress = fixtureIsAutoRePairing ?? gateway.isAutoRePairInProgress
        #else
        let connectionState = gateway.connectionState
        let isAutoRePairInProgress = gateway.isAutoRePairInProgress
        #endif

        let info = isAutoRePairInProgress
            ? autoRePairInfo(provider: gatewayProvider)
            : bannerInfo(for: connectionState, provider: gatewayProvider)

        // Rendering is delegated to the canonical shared `RemContextualMessage`
        // card. This view owns only the *content* (state → icon/color/title/
        // subtitle/action) and the *placement* (the outer inset below); the card
        // owns the house styling (material surface, DesignTokens spacing/typography).
        RemContextualMessage(
            icon: info.icon,
            iconColor: info.iconColor,
            title: info.title,
            subtitle: info.subtitle
        ) {
            // Auto-re-pair banner has no CTA — the system is the actor, not the
            // user. See autoRePairInfo for the copy.
            HStack(spacing: 8) {
                if let onOpenRecovery, info.showsRecovery {
                    Button {
                        onOpenRecovery()
                    } label: {
                        Text("Review")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(info.iconColor)
                }

                if !info.actionLabel.isEmpty {
                    Button {
                        info.action(gateway)
                    } label: {
                        Text(info.actionLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(info.iconColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(info.iconColor)
                }
            }
        }
        // Outer inset — where/how the banner sits in the layout. Unchanged from
        // the pre-`RemContextualMessage` implementation so placement is identical.
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - State-specific banner content

    private struct BannerInfo {
        let icon: String
        let iconColor: Color
        let title: String
        let subtitle: String
        let actionLabel: String
        var showsRecovery = true
        let action: (RemGatewaySessionManager) -> Void
    }

    /// Shown whenever `gateway.isAutoRePairInProgress` is true. Fixed label,
    /// no CTA — the system is already handling recovery and we don't want
    /// the user to race us. See #306 (Pairing recovery UX epic).
    private func autoRePairInfo(provider: GatewayProvider?) -> BannerInfo {
        BannerInfo(
            icon: "arrow.clockwise.circle",
            iconColor: .blue,
            title: "Restoring connection...",
            subtitle: GatewayRecoveryCopy.bannerAutoRePairSubtitle(provider: provider),
            actionLabel: "",
            showsRecovery: false,
            action: { _ in })
    }

    private func bannerInfo(for state: RemGatewayConnectionState, provider: GatewayProvider?) -> BannerInfo {
        switch state {
        case .pairingRequired:
            // Plain `reconnect()` here loops — the gateway will reject the
            // reconnect for the same reason that triggered `.pairingRequired`
            // (stale token, narrower scopes than requested, invalid
            // signature). `resetPairing()` clears the stored device-auth
            // token so the next connect pairs fresh. See #288.
            //
            // Verb: reset this device's pairing — consistent across Settings,
            // banner, and copy. See #306 (Pairing recovery UX epic).
            return BannerInfo(
                icon: "person.badge.key",
                iconColor: .yellow,
                title: "Finish connecting this device",
                subtitle: GatewayRecoveryCopy.bannerSubtitle(for: state, provider: provider),
                actionLabel: "Reset",
                action: { $0.resetPairing() })
        case .connecting:
            return BannerInfo(
                icon: "wifi.exclamationmark",
                iconColor: .orange,
                title: provider == .local ? "Connecting to your Mac" : "Connecting...",
                subtitle: GatewayRecoveryCopy.bannerSubtitle(for: state, provider: provider),
                actionLabel: "Retry",
                action: { $0.reconnect() })
        case .unauthorized:
            // `.unauthorized` commonly means a stale device-auth token or
            // signature mismatch (#229). Re-pairing mints a fresh token.
            // If the gateway token itself is wrong, reconnect won't help
            // either — re-pair is the right recovery in both cases.
            return BannerInfo(
                icon: "lock.fill",
                iconColor: .red,
                title: "Unauthorized",
                subtitle: GatewayRecoveryCopy.bannerSubtitle(for: state, provider: provider),
                actionLabel: "Reset",
                action: { $0.resetPairing() })
        case .unreachable:
            if state.needsDeviceRePair {
                return BannerInfo(
                    icon: "person.badge.key",
                    iconColor: .orange,
                    title: "Device trust mismatch",
                    subtitle: GatewayRecoveryCopy.bannerSubtitle(for: state, provider: provider),
                    actionLabel: "Reset",
                    action: { $0.resetPairing() })
            }
            // Deemphasized from destructive red to a softer warning amber: an
            // unreachable cloud gateway is usually transient (auto-suspended,
            // waking, flaky network) and the app auto-retries, so alarm-red
            // over-signals. Still clearly noticeable — the glyph + Review/Retry
            // buttons inherit this accent via `RemContextualMessage`. Routed
            // through `DesignTokens` rather than a bare SwiftUI color so the tone
            // stays consistent with the rest of the design system.
            return BannerInfo(
                icon: "exclamationmark.triangle.fill",
                iconColor: DesignTokens.Color.systemOrange,
                title: provider == .local ? "Mac Gateway Unreachable" : "Gateway Unreachable",
                subtitle: GatewayRecoveryCopy.bannerSubtitle(for: state, provider: provider),
                actionLabel: "Retry",
                action: { $0.reconnect() })
        case .disconnected:
            return BannerInfo(
                icon: "wifi.slash",
                iconColor: .orange,
                title: provider == .local ? "Mac Gateway Disconnected" : "Gateway Disconnected",
                subtitle: GatewayRecoveryCopy.bannerSubtitle(for: state, provider: provider),
                actionLabel: "Connect",
                action: { $0.reconnect() })
        case .connected:
            // Shouldn't normally show, but handle gracefully
            return BannerInfo(
                icon: "checkmark.circle.fill",
                iconColor: .green,
                title: "Connected",
                subtitle: "Your gateway is online.",
                actionLabel: "OK",
                action: { _ in })
        }
    }
}

#if DEBUG
#Preview("Banner — Cloud Approval") {
    GatewayDisconnectedBanner(
        gatewayProvider: .fly,
        fixtureConnectionState: .pairingRequired,
        fixtureIsAutoRePairing: false,
        onOpenRecovery: {}
    )
    .environment(RemGatewaySessionManager())
    .padding(.vertical)
}

#Preview("Banner — Cloud Connecting") {
    GatewayDisconnectedBanner(
        gatewayProvider: .fly,
        fixtureConnectionState: .connecting,
        fixtureIsAutoRePairing: false,
        onOpenRecovery: {}
    )
    .environment(RemGatewaySessionManager())
    .padding(.vertical)
}

#Preview("Banner — Cloud Unreachable") {
    GatewayDisconnectedBanner(
        gatewayProvider: .fly,
        fixtureConnectionState: .unreachable(nil),
        fixtureIsAutoRePairing: false,
        onOpenRecovery: {}
    )
    .environment(RemGatewaySessionManager())
    .padding(.vertical)
}

#Preview("Banner — Local Mac Unreachable") {
    GatewayDisconnectedBanner(
        gatewayProvider: .local,
        fixtureConnectionState: .unreachable(nil),
        fixtureIsAutoRePairing: false,
        onOpenRecovery: {}
    )
    .environment(RemGatewaySessionManager())
    .padding(.vertical)
}
#endif
