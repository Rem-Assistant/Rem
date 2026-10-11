import SwiftUI
import RemDesignSystem

/// Phase 2 of the design-system adapter: the Inbox (unscheduled tasks) rendered through the canonical
/// `RemDesignSystem.InboxScreen`, from the same `InboxViewModel` as the classic `InboxView`. Reached
/// only from `ContentView`'s Inbox tab in DEBUG builds launched with `--rem-ds-chat`.
///
/// Rows show each task's reported run state (`TaskDisplayMapper.inboxState`). A tap opens the same
/// task detail destination as the classic row (the task's UUID on the navigation path), from which
/// the existing task chat opens. Pull to refresh is the classic `pullToRefresh()`. The classic swipe
/// actions (complete, snooze, delete) and inline scheduling have no design-system equivalent yet and
/// are not offered here; they remain in the task detail and the classic Inbox.
struct RemInboxScreenAdapter: View {
    @ObservedObject var viewModel: InboxViewModel
    /// Pushes task detail for a task id (`navigationPath.append`).
    let onOpenTask: (UUID) -> Void

    var body: some View {
        let records: [DesignSystemTaskRecord] = viewModel.unscheduledTasks.map { TaskDisplayMapper.record($0) }
        RemDesignSystem.InboxScreen(
            items: TaskDisplayMapper.inboxItems(records),
            onAction: { (action: RemDesignSystem.InboxAction) in
                switch action {
                case .open(let itemID):
                    if let taskID = TaskDisplayMapper.taskID(forInboxItemID: itemID, in: records) {
                        onOpenTask(taskID)
                    }
                }
            },
            empty: {
                // The classic Inbox's empty copy.
                RemDesignSystem.RemContentUnavailableView(
                    symbol: "tray",
                    title: "Inbox is empty",
                    message: "Tasks you capture will appear here"
                )
                .frame(maxWidth: .infinity)
                .padding(.top, RemDesignSystem.DesignTokens.Spacing.xl)
                .accessibilityIdentifier("designSystem.inbox.empty")
            }
        )
        .refreshable {
            await viewModel.pullToRefresh()
        }
    }
}
