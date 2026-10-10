import SwiftUI
import RemDesignSystem

/// Phase 1a of the design-system adapter: proves the canonical `RemDesignSystem` package resolves,
/// links into the iOS target and renders its resources. Nothing routes here yet. The Chat adapter
/// (phase 1b) replaces this probe behind a debug flag.
///
/// Types are module-qualified on purpose: the app module defines its own `RemFaceMark`,
/// `MessageBubble`, `DesignTokens` and others, and app types shadow imported ones.
struct DesignSystemProbeView: View {
    var body: some View {
        VStack(spacing: RemDesignSystem.DesignTokens.Spacing.lg) {
            RemDesignSystem.ChatHeader(activity: "Connected")
            RemDesignSystem.RemFaceMark(
                mode: .idle,
                tint: RemDesignSystem.DesignTokens.Color.brandBlue,
                size: 48
            )
        }
        .padding(RemDesignSystem.DesignTokens.Spacing.lg)
        .accessibilityIdentifier("designSystem.probe")
    }
}
