import SwiftUI

/// Pure presentation contract shared by the pre-view-model loading surface and
/// the fully initialized chat. Connection state stays the source of truth; the
/// UI never infers pairing or reachability from error copy.
struct ChatConnectionPresentation: Equatable {
    enum Accent: Equatable {
        case info
        case pairing
        case warning
        case error

        var color: Color {
            switch self {
            case .info: DesignTokens.Color.brandBlue
            case .pairing: DesignTokens.Color.systemYellow
            case .warning: DesignTokens.Color.systemOrange
            case .error: DesignTokens.Color.systemRed
            }
        }
    }

    let icon: String
    let accent: Accent
    let title: String
    let subtitle: String
    let showsRetry: Bool
    let showsReviewConnection: Bool

    static func resolve(_ state: GatewayConnectionState) -> Self {
        switch state {
        case .pairingRequired:
            return Self(
                icon: "person.badge.key",
                accent: .pairing,
                title: "Finish connecting this device",
                subtitle: "Approve this device to start chatting.",
                showsRetry: false,
                showsReviewConnection: true)
        case .unauthorized:
            return Self(
                icon: "lock.fill",
                accent: .error,
                title: "Sign-in needed",
                subtitle: "Your session expired — review the connection to continue.",
                showsRetry: false,
                showsReviewConnection: true)
        case .unreachable:
            return Self(
                icon: "exclamationmark.triangle.fill",
                accent: .error,
                title: "Can't reach your gateway",
                subtitle: "We couldn't reach Rem. Review the connection or try again shortly.",
                showsRetry: true,
                showsReviewConnection: true)
        case .connected:
            return Self(
                icon: "bubble.left.and.bubble.right.fill",
                accent: .info,
                title: "Preparing chat",
                subtitle: "Getting your conversation ready.",
                showsRetry: false,
                showsReviewConnection: false)
        case .connecting, .disconnected:
            return Self(
                icon: "wifi.exclamationmark",
                accent: .warning,
                title: "Waiting for your gateway",
                subtitle: "Rem is waking up — this usually takes a few seconds.",
                showsRetry: true,
                showsReviewConnection: false)
        }
    }
}

/// Canonical connection presenter for Sessions, the pre-view-model bridge, and initialized chat.
/// Owning surfaces decide placement; this component owns state copy and the Retry/Review actions.
struct ChatConnectionRecoveryCard: View {
    let connectionState: GatewayConnectionState
    var onRetry: (() -> Void)?
    var onReviewConnection: (() -> Void)?

    private var presentation: ChatConnectionPresentation {
        .resolve(connectionState)
    }

    var body: some View {
        RemContextualMessage(
            icon: presentation.icon,
            iconColor: presentation.accent.color,
            title: presentation.title,
            subtitle: presentation.subtitle
        ) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                if presentation.showsReviewConnection, let onReviewConnection {
                    Button("Review Connection", action: onReviewConnection)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(presentation.accent.color)
                }

                if presentation.showsRetry, let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(presentation.accent.color)
                }
            }
        }
        .accessibilityIdentifier("chat-connection-recovery")
    }
}

/// Full-screen bridge used before `OpenClawChatViewModel` exists. It preserves
/// the established chat skeleton instead of switching to a bare spinner, and
/// gives terminal trust/reachability states a route to recovery.
struct ChatConnectionLoadingView: View {
    let connectionState: GatewayConnectionState
    var onRetry: (() -> Void)?
    var onReviewConnection: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ChatWakingSkeleton()
            }

            ChatConnectionRecoveryCard(
                connectionState: connectionState,
                onRetry: onRetry,
                onReviewConnection: onReviewConnection
            )
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.lg)
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .accessibilityIdentifier("chat-connection-loading")
    }
}

#if DEBUG
#Preview("Chat connection — pairing") {
    ChatConnectionLoadingView(connectionState: .pairingRequired, onReviewConnection: {})
}

#Preview("Chat connection — waking") {
    ChatConnectionLoadingView(connectionState: .connecting)
}

#Preview("Chat connection — preparing") {
    ChatConnectionLoadingView(connectionState: .connected)
}
#endif
