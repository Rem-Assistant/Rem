import SwiftUI

/// A small, reusable indicator for a task's structured agent **run-state**
/// (`TaskRunStatus`) — "an agent is working this right now / it needs attention".
///
/// This is DISTINCT from `TaskRuntimeBadge`, which shows *where* work executes
/// (cloud vs local runtime). This badge shows *how the run is going*: `running`
/// (live), `review` / `blocked` (needs attention), `done` (finished). It's the P1
/// surface from docs/rebuild/19-TASKS-VS-WORKBOARD.md — promoting run-state from a
/// buried comment to a glanceable indicator on the task.
///
/// Cross-platform: uses `DesignTokens` only, no UIKit/AppKit. `idle` renders nothing.
struct TaskRunStatusBadge: View {
    let runStatus: TaskRunStatus

    /// Compact hides the text label and shows only the icon (for dense rows).
    var compact: Bool = false

    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 11

    private var tint: Color {
        switch runStatus {
        case .running: DesignTokens.Color.brandBlue
        case .review: DesignTokens.Color.systemOrange
        case .blocked: DesignTokens.Color.systemRed
        case .done: DesignTokens.Color.systemGreen
        case .idle: DesignTokens.Color.labelSecondary
        }
    }

    private var iconName: String {
        switch runStatus {
        case .running: "arrow.triangle.2.circlepath"
        case .review: "eye.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        }
    }

    var body: some View {
        // Idle / no active run — surface nothing (keeps the row quiet).
        if runStatus == .idle {
            EmptyView()
        } else {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: iconName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .imageScale(.small)
                    .symbolEffectRunningIfAvailable(runStatus == .running)

                if !compact {
                    Text(runStatus.displayName)
                        .font(DesignTokens.Typography.caption1Bold)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? DesignTokens.Spacing.xs : DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Run status: \(runStatus.displayName)")
        }
    }
}

private extension View {
    /// Apply a gentle looping animation to the icon while a run is live, where the
    /// symbol-effect API is available; a no-op fallback otherwise.
    @ViewBuilder
    func symbolEffectRunningIfAvailable(_ active: Bool) -> some View {
        if #available(iOS 17.0, macOS 14.0, *), active {
            self.symbolEffect(.pulse, options: .repeating)
        } else {
            self
        }
    }
}

// MARK: - Preview

#Preview("Run Status Badges") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        ForEach(TaskRunStatus.allCases, id: \.self) { status in
            HStack(spacing: DesignTokens.Spacing.md) {
                TaskRunStatusBadge(runStatus: status)
                TaskRunStatusBadge(runStatus: status, compact: true)
                Text(status.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    .padding()
}
