import SwiftUI

/// A small, reusable badge for a `TaskRuntimeKind` — shows where a task's work
/// executes. Cloud (AgentBox) and local (Mac/iOS gateway) get distinct visual
/// treatments so the runtime is legible at a glance in headers, rows, and chips.
///
/// Cross-platform: uses `DesignTokens` only, no UIKit/AppKit. Drop into both
/// iOS and Mac surfaces.
struct TaskRuntimeBadge: View {
    let runtime: TaskRuntimeKind

    /// Compact hides the text label and shows only the icon (for dense rows).
    var compact: Bool = false

    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 11

    private var tint: Color {
        runtime.isCloud ? DesignTokens.Color.brandBlue : DesignTokens.Color.systemGreen
    }

    private var iconName: String {
        switch runtime {
        case .agentbox, .gateway: "cloud.fill"
        case .localMac: "desktopcomputer"
        case .localiOS: "iphone"
        }
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: iconName)
                .font(.system(size: iconSize, weight: .semibold))
                .imageScale(.small)

            if !compact {
                Text(runtime.displayName)
                    .font(DesignTokens.Typography.caption1Bold)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? DesignTokens.Spacing.xs : DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let where_ = runtime.isCloud ? "Cloud runtime" : "Local runtime"
        return "\(where_): \(runtime.displayName)"
    }
}

// MARK: - Preview

#Preview("Runtime Badges") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        ForEach(TaskRuntimeKind.allCases, id: \.self) { runtime in
            HStack(spacing: DesignTokens.Spacing.md) {
                TaskRuntimeBadge(runtime: runtime)
                TaskRuntimeBadge(runtime: runtime, compact: true)
            }
        }
    }
    .padding()
}

#Preview("Runtime Badges — Dark") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        ForEach(TaskRuntimeKind.allCases, id: \.self) { runtime in
            TaskRuntimeBadge(runtime: runtime)
        }
    }
    .padding()
    .preferredColorScheme(.dark)
}
