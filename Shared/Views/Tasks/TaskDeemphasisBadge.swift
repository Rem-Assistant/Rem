import SwiftUI

/// The label half of the founder's decision: *same visual de-emphasis as `blocked`, different word*.
/// `TaskDeemphasisReason` owns the words; this owns the pill, and `View.taskDeemphasized(_:)` owns
/// the dimming. Keeping them in one file is what stops the two treatments drifting apart.
///
/// Styled as a `SharedPillView` sibling (same font, padding, radius) so a stale task reads as a
/// normal row wearing one more pill — not as an error state. Staleness is "Rem went quiet", not
/// "something went wrong", so it gets no red.
struct TaskDeemphasisBadge: View {
    let reason: TaskDeemphasisReason

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: reason.systemImage)
                .font(DesignTokens.Typography.caption1)
            Text(reason.label)
                .font(DesignTokens.Typography.caption1)
        }
        .foregroundColor(DesignTokens.Color.labelSecondary)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 6)
        .background(DesignTokens.Color.pillBackground)
        .cornerRadius(DesignTokens.CornerRadius.xlarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reason.accessibilityLabel)
    }
}

/// Both badges for a task, in reading order, or nothing when it is neither blocked nor stale.
///
/// A blocked-AND-stale task shows BOTH. They answer different questions — "you said this can't
/// move" and "I stopped bringing it up" — and collapsing them to one pill would delete a fact the
/// user set themselves.
struct TaskDeemphasisBadges: View {
    let reasons: [TaskDeemphasisReason]

    var body: some View {
        ForEach(reasons, id: \.self) { reason in
            TaskDeemphasisBadge(reason: reason)
        }
    }
}

extension View {
    /// The de-emphasis half of the decision. Fades a row's CONTENT so it recedes without hiding.
    ///
    /// Apply to the title and the ordinary metadata — **not** to the `TaskDeemphasisBadge`. Dimming
    /// the badge too would fade the one element that explains why the row is dim, which is the bug
    /// this feature exists to fix: a task nobody can tell is stale.
    ///
    /// `.allowsHitTesting` is deliberately untouched. A stale task is fully interactive — tapping it
    /// is precisely the user action that clears `stale_at` and brings it back into the brief.
    func taskDeemphasized(_ isDeemphasized: Bool) -> some View {
        opacity(isDeemphasized ? DesignTokens.Opacity.deemphasized : 1)
    }
}

#if DEBUG
#Preview("Task de-emphasis — blocked, stale, both") {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
        ForEach([[TaskDeemphasisReason.blocked], [.stale], [.blocked, .stale]], id: \.self) { reasons in
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Renew the domain")
                    .font(.headline)
                    .taskDeemphasized(true)
                HStack(spacing: DesignTokens.Spacing.xs) {
                    TaskDeemphasisBadges(reasons: reasons)
                    SharedPillView(text: "30m").taskDeemphasized(true)
                }
            }
        }
    }
    .padding()
}
#endif
