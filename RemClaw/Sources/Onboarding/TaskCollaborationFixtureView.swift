import SwiftUI

#if DEBUG
/// Deterministic fixture mirroring the real `TaskEventView` comments layout: the task
/// header + comment **thread** scroll inline, and only the **composer** docks at the
/// bottom as a card with rounded top corners (fill bleeds into the bottom safe area,
/// no bottom shadow). Seeded by a `MockTaskCommentService`.
///
/// Launch args:
/// - `--rem-collaboration-fixture` — populated (default).
/// - `--rem-collaboration-empty` — empty state.
struct TaskCollaborationFixtureView: View {
    private let showEmpty = ProcessInfo.processInfo.arguments.contains("--rem-collaboration-empty")
    @State private var model = TaskCommentsModel()

    var body: some View {
        NavigationStack {
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
        }
        .task {
            model.configure(
                taskId: "task-fixture",
                service: MockTaskCommentService(
                    thread: showEmpty ? [] : MockTaskCommentService.sampleThread(),
                    simulatedDelay: .zero
                ),
                commitStatus: { _ in }
            )
            await model.load()
        }
    }
}
#endif
