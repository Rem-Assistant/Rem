import SwiftUI
import SwiftData

#if DEBUG
/// Create-mode `TaskEventView` backed by an in-memory SwiftData store, so the
/// task-detail description / notes layout (#1367 item 1) can be driven and screenshotted
/// without auth or a backend. Create mode (`task == nil`) needs only a `ModelContext`;
/// no calendar / API services are injected. The single free-text field ("Add your notes
/// here") is now bound to the task **description** — there is no separate "Description"
/// field.
///
/// Launch arg: `--rem-task-detail-fixture`.
struct TaskDetailCreateFixtureView: View {
    private let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        // Same schema the app registers (`RemClawApp.makeModelContainer`).
        return try! ModelContainer(
            for: TaskEvent.self, StoredFocusSession.self, PendingTaskOperation.self,
                TaskFolder.self, TaskList.self,
            configurations: config
        )
    }()

    var body: some View {
        NavigationStack {
            TaskEventView(viewModel: TaskEventViewModel(modelContext: container.mainContext))
        }
    }
}
#endif
