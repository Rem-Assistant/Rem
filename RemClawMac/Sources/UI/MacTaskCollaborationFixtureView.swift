import SwiftUI

#if DEBUG
/// Deterministic fixture for the **inline task Comments section** on macOS — the same
/// shared `TaskCommentsSection` the Mac task detail hosts, rendered with an in-memory
/// `MockTaskCommentService` (no auth/backend). Mirrors iOS `TaskCollaborationFixtureView`.
///
/// Launch args:
/// - `--rem-collaboration-fixture` — populated (default).
/// - `--rem-collaboration-empty` — empty state.
struct MacTaskCollaborationFixtureView: View {
    private let showEmpty = ProcessInfo.processInfo.arguments.contains("--rem-collaboration-empty")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text("File visa paperwork")
                    .font(DesignTokens.Typography.title1Bold)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.top, DesignTokens.Spacing.md)

                Text("Add your notes here")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                    .padding(.horizontal, DesignTokens.Spacing.md)

                Divider().padding(.horizontal, DesignTokens.Spacing.md)

                TaskCommentsSection(
                    taskId: "task-fixture",
                    service: MockTaskCommentService(
                        thread: showEmpty ? [] : MockTaskCommentService.sampleThread(),
                        simulatedDelay: .zero
                    )
                )
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .background(DesignTokens.Color.backgroundPrimary)
    }
}
#endif
