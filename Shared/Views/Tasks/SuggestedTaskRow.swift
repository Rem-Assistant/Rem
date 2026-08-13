import SwiftUI

/// A suggestion in the Agenda (WS2, doc 38), rendered to **mirror `TaskEventRowView`** — the same
/// row paradigm the app enforces everywhere — with three deliberate substitutions:
///   • the left **time slot becomes a CTA** (accept): a suggestion's whole point is its action;
///   • the trailing **disclosure chevron becomes a dismiss ✕**: this is not a drill-down;
///   • a **dashed border** rings the row, signalling "proposed, not yet real".
///
/// Every row states WHY (`suggestion.subtitle`, e.g. "'File visa paperwork' · overdue 3d"): an unattributed
/// suggestion is indistinguishable from the app inventing work, which destroys trust faster than
/// showing nothing (doc 38 §6).
///
/// Self-contained (DesignTokens only, no platform APIs) so it works on iOS and macOS.
struct SuggestedTaskRow: View {
    let suggestion: TaskSuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    /// Accepting a calendar suggestion creates a task ("Add"); an overdue one moves it onto today
    /// ("Move"). One short verb so it fits the narrow left slot.
    private var acceptLabel: String {
        suggestion.action.kind == "createTask" ? "Add" : "Move"
    }

    private var acceptIcon: String {
        suggestion.action.kind == "createTask" ? "plus" : "arrow.turn.up.right"
    }

    /// Matches `TaskEventRowView`'s time-indicator width so a suggestion row's content column
    /// lines up flush with the task rows above it.
    private let leftSlotWidth: CGFloat = 64

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            // LEFT ADD-ON — a CTA where a task row shows the time.
            Button(action: onAccept) {
                VStack(spacing: 3) {
                    Image(systemName: acceptIcon)
                        .font(.system(size: 18, weight: .semibold))
                    Text(acceptLabel)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(DesignTokens.Color.brandBlue)
                .frame(width: leftSlotWidth)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(acceptLabel): \(suggestion.title)")

            // MIDDLE — title + attribution, mirroring `TaskEventRowView.taskContent`.
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(suggestion.title)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(suggestion.subtitle)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Claim the row's full width. Without this the HStack hugs its content, so the dashed
            // ring shrink-wraps each row to the length of its own title — the rows come out ragged
            // and inset from their container by an amount nobody chose, which reads as a layout
            // bug rather than a design. A `maxWidth` frame (not a `Spacer`) does it without
            // tripping the `SuggestedTaskRowLayoutContractTests` ban on unbounded space claims.
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIGHT — dismiss ✕, replacing the drill-down disclosure chevron.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(6)
        .overlay(
            // The dashed ring is the "this is a suggestion" signal — the row is otherwise a
            // faithful copy of a task/event row.
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                .strokeBorder(
                    DesignTokens.Color.separator,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
    }
}
