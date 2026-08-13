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

// MARK: - Pushed-state fixtures (real back chevron)

/// Agenda parent → pushes the task detail via a real `NavigationLink`, so the
/// captured screenshot shows the true pushed nav bar (back chevron + "Task"),
/// not a standalone root. Launch, then tap the task row before screenshotting.
struct ReadmeTaskDetailNavFixtureView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    NavigationLink {
                        ReadmeTaskDetailContent()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Check emails and update on the latest recruiter thread")
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Color.labelPrimary)
                            Text("Jun 27 at 12:00 PM")
                                .font(DesignTokens.Typography.footnote)
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                        }
                    }
                    .accessibilityIdentifier("readme-task-row")
                }
            }
            .navigationTitle("Agenda")
        }
    }
}

/// The task-detail body, mirroring `TaskCollaborationFixtureView` but WITHOUT its
/// own `NavigationStack`, so it can be pushed as a `NavigationLink` destination and
/// inherit a back chevron. Reuses the same mock comment components.
private struct ReadmeTaskDetailContent: View {
    @State private var model = TaskCommentsModel()

    var body: some View {
        ZStack {
            DesignTokens.Color.backgroundPrimary.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("Check emails and update on the latest recruiter thread")
                        .font(DesignTokens.Typography.title1Bold)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Jun 27, 2026 at 12:00 PM", systemImage: "clock")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                    Text("Add your notes here")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelTertiary)
                        .padding(.top, DesignTokens.Spacing.sm)

                    TaskCommentsThread(model: model)
                        .padding(.top, DesignTokens.Spacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.md)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TaskCommentComposer(model: model)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.top, DesignTokens.Spacing.md)
                    .padding(.bottom, DesignTokens.Spacing.sm)
                    .background(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                            .fill(DesignTokens.Color.backgroundPrimary)
                            .overlay(alignment: .top) {
                                UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                                    .strokeBorder(DesignTokens.Color.separator, lineWidth: 0.5)
                            }
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.configure(
                taskId: "task-fixture",
                service: MockTaskCommentService(
                    thread: MockTaskCommentService.sampleThread(),
                    simulatedDelay: .zero
                ),
                commitStatus: { _ in }
            )
            await model.load()
        }
    }
}

/// Agent-settings parent → pushes the Connectors screen via a real `NavigationLink`,
/// so the capture shows the pushed nav bar (back chevron + "Connectors"). Launch,
/// then tap the Connectors row before screenshotting.
struct ReadmeConnectorsNavFixtureView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Agent settings") {
                    NavigationLink {
                        SharedComposioConnectionsView(service: MockComposioService())
                            .environment(\.openURL, OpenURLAction { _ in .handled })
                    } label: {
                        Label("Connectors", systemImage: "puzzlepiece.extension.fill")
                    }
                    .accessibilityIdentifier("readme-connectors-row")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
#endif
