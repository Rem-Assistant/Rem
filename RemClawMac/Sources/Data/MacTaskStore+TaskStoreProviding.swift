import Foundation

// MARK: - TaskStoreProviding conformance for MacTaskStore

/// Adapter that wraps MacTaskStore as a TaskStoreProviding.
/// Auth credentials are handled internally by MacAuthenticatedHttpClient,
/// so the adapter is a thin pass-through.
@MainActor @Observable
final class MacTaskStoreAdapter: TaskStoreProviding {
    typealias TaskItem = MacTask

    private let store: MacTaskStore

    init(store: MacTaskStore) {
        self.store = store
    }

    var isLoading: Bool { store.isLoading }
    var lastSyncDate: Date? { store.lastSyncDate }
    var unscheduledTasks: [MacTask] { store.unscheduledTasks }

    func tasks(for date: Date) -> [MacTask] {
        store.tasks(for: date)
    }

    func completeTask(_ task: MacTask) async {
        await store.completeTask(task)
    }

    func deleteTask(_ task: MacTask) async {
        await store.deleteTask(task)
    }

    func snoozeTask(_ task: MacTask) async {
        await store.snoozeTask(task)
    }

    func refresh() async {
        await store.fetchTasks()
    }
}
