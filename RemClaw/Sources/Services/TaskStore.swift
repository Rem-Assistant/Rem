import Foundation
import SwiftUI

/// Single source of truth for all tasks in the app.
/// ContentView feeds it from @Query; view models read from it instead of
/// maintaining their own duplicate arrays.
@Observable
@MainActor
public final class TaskStore {
    // MARK: - Canonical Task List

    private(set) var allTasks: [TaskEvent] = []

    // MARK: - Dependencies

    private let taskSyncService: RemTaskSyncService

    // MARK: - Init

    init(taskSyncService: RemTaskSyncService) {
        self.taskSyncService = taskSyncService
    }

    // MARK: - Update (called by ContentView when @Query changes)

    func update(_ tasks: [TaskEvent]) {
        allTasks = tasks
    }

    // MARK: - Sync (single entry point — replaces per-VM syncs)

    func sync() async {
        await taskSyncService.syncFromBackend()
    }

    // MARK: - Computed Filters

    /// Tasks with no start date (matches existing VM filter exactly).
    var unscheduledTasks: [TaskEvent] {
        allTasks.filter { $0.startDate == nil }
    }

    /// Completed tasks.
    var completedTasks: [TaskEvent] {
        allTasks.filter { $0.statusEnum == .completed }
    }

    /// Append a task that was created outside of the @Query cycle
    /// (e.g. a mirrored calendar-only event inserted into SwiftData).
    func appendIfMissing(_ task: TaskEvent) {
        if !allTasks.contains(where: { $0.id == task.id }) {
            allTasks.append(task)
        }
    }
}
