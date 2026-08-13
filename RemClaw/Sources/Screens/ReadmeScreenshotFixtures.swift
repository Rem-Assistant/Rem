import SwiftUI

#if DEBUG
/// DEBUG-only fixture entry points used to capture clean README/App Store screenshots
/// with 100% mock data — no real account, no network. These are thin wrappers around
/// the shipping `SharedAgendaView` and `DailyBriefCard` views seeded with the existing
/// `PreviewTaskStore` mock and the brief `#Preview` fixture, so they are structurally
/// incapable of showing real user data.
///
/// Launch args:
/// - `--rem-agenda-fixture`      — Agenda populated with mock scheduled tasks/events.
/// - `--rem-daily-brief-fixture` — Today surface: Daily Brief card + mock agenda rows.

/// Agenda screen with mock scheduled tasks/events (`PreviewTaskStore(.scheduled)`).
struct ReadmeAgendaFixtureView: View {
    var body: some View {
        NavigationStack {
            SharedAgendaView(store: PreviewTaskStore(scenario: .scheduled))
        }
    }
}

/// Today surface: the AI-authored Daily Brief card sitting above the day's mock agenda,
/// mirroring how the real app inserts the brief at the top of today's Agenda.
struct ReadmeDailyBriefFixtureView: View {
    private let brief = DailyBrief(
        generatedAt: nil,
        counts: BriefCounts(blocked: 2, overdue: 3, scheduledToday: 5, completedToday: 2, total: 7, done: 2),
        blocked: [], overdue: [], scheduledToday: [], completedToday: [],
        markdown: "2 tasks blocked and 3 tasks overdue need your attention. You've got 5 things on deck today.",
        summary: "2 tasks blocked and 3 tasks overdue need attention · 5 on deck · 2 of 7 done.",
        briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    DailyBriefCard(brief: brief, onTap: {}, hasCompletedPlayback: false, onRead: {})

                    Divider()

                    ForEach(ReadmeDailyBriefFixtureView.rows, id: \.title) { row in
                        HStack(spacing: DesignTokens.Spacing.md) {
                            Image(systemName: row.icon)
                                .font(.system(size: 17))
                                .foregroundStyle(row.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(DesignTokens.Typography.body)
                                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                                Text(row.time)
                                    .font(DesignTokens.Typography.footnote)
                                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
            .background(DesignTokens.Color.backgroundPrimary)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private struct Row { let icon: String; let tint: Color; let title: String; let time: String }
    private static let rows: [Row] = [
        Row(icon: "circle", tint: DesignTokens.Color.systemOrange,
            title: "Plan tomorrow's rehearsal songs", time: "9:00 AM · 30m"),
        Row(icon: "calendar", tint: DesignTokens.Color.brandBlue,
            title: "Coffee chat with an investor", time: "7:00 PM · 30m"),
        Row(icon: "circle", tint: DesignTokens.Color.systemGreen,
            title: "Review gateway recovery notes", time: "Tomorrow · 2:00 PM"),
    ]
}
#endif
