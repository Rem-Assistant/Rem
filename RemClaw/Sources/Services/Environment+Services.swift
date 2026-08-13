import SwiftUI

extension EnvironmentValues {
    var taskSyncService: TaskSyncServiceProtocol? {
        get { self[TaskSyncServiceKey.self] }
        set { self[TaskSyncServiceKey.self] = newValue }
    }

    var taskApiService: TaskApiServiceProtocol? {
        get { self[TaskApiServiceKey.self] }
        set { self[TaskApiServiceKey.self] = newValue }
    }
}

// MARK: - Environment Keys

private struct TaskSyncServiceKey: EnvironmentKey {
    static let defaultValue: TaskSyncServiceProtocol? = nil
}

private struct TaskApiServiceKey: EnvironmentKey {
    static let defaultValue: TaskApiServiceProtocol? = nil
}
