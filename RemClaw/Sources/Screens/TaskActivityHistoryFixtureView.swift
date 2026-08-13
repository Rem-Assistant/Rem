import SwiftUI

#if DEBUG
/// Drives `TaskActivityHistoryView` (the "View history" destination) on a seeded mock
/// thread, so the removal of the standalone "Continue in chat" bottom button (#1367
/// item 2) can be driven and screenshotted without auth. Rows remain the entry point
/// into the task-scoped chat.
///
/// Launch arg: `--rem-activity-history-fixture`.
struct TaskActivityHistoryFixtureView: View {
    var body: some View {
        NavigationStack {
            TaskActivityHistoryView(
                taskId: "task-fixture",
                service: MockTaskCommentService(
                    thread: MockTaskCommentService.sampleThread(),
                    simulatedDelay: .zero
                ),
                onContinueInChat: { _ in }
            )
        }
    }
}
#endif
