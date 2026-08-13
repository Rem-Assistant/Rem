import SwiftUI

/// Loading placeholder for the chat Sessions list — a column of shimmering
/// skeleton rows shown while sessions load and none are cached yet. Mirrors the
/// real session-row layout (title + timestamp on top, one-line preview below) so
/// the swap from skeleton to content doesn't visually jump.
///
/// Cross-platform: used by both iOS `ChatHistoryView` and Mac `MacSessionsView`,
/// so it must avoid platform-only APIs (no `Color(uiColor:)`). Styling mirrors
/// `TaskEventRowSkeleton` / `ChatWakingSkeleton` — grey rounded bars filled with
/// `DesignTokens.Color.fillTertiary` under a single `.shimmering()` sweep.
struct SessionListLoadingSkeleton: View {
    /// Fixed (title, subtitle) bar widths per row so the mock list reads as a set
    /// of varied conversations rather than identical bars. Point widths (not
    /// fractions) keep the layout simple across the two platforms and mirror the
    /// fixed-width approach in `TaskEventRowSkeleton`.
    private let rows: [(title: CGFloat, subtitle: CGFloat)] = [
        (140, 230),
        (110, 180),
        (170, 210),
        (95, 150),
        (150, 240),
        (120, 175),
        (135, 205),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                skeletonRow(titleWidth: row.title, subtitleWidth: row.subtitle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shimmering()
        // The bars are decorative, but the container must still announce the
        // loading status — the old spinner branch had an accessible
        // "Loading conversations…" Text, so collapse the skeleton into a single
        // labeled element rather than hiding it from VoiceOver entirely.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading conversations…")
    }

    @ViewBuilder
    private func skeletonRow(titleWidth: CGFloat, subtitleWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                bar(width: titleWidth, height: 15)
                Spacer(minLength: DesignTokens.Spacing.md)
                bar(width: 30, height: 11)
            }
            bar(width: subtitleWidth, height: 12)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: height)
    }
}

#if DEBUG
#Preview("Session list loading skeleton") {
    SessionListLoadingSkeleton()
        .background(DesignTokens.Color.backgroundPrimary)
}
#endif
