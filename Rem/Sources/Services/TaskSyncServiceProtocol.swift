import Foundation
import SwiftData

public protocol TaskSyncServiceProtocol {
    @discardableResult
    func queueOperation(operationType: String, taskId: UUID?, taskData: Data?) async -> Bool
    @discardableResult
    func discardPendingOperations(for taskId: UUID) async -> Bool
    func updateTaskStatus(_ task: TaskEvent, to status: TaskStatus, modelContext: ModelContext) async throws
    func syncTaskToBackendImmediately(_ task: TaskEvent) async throws
    func syncTaskToBackendImmediately(_ task: TaskEvent, includeListID: Bool) async throws
    func syncTaskCreateToBackendImmediately(_ task: TaskEvent) async throws -> TaskEventApiResponse?
    /// Persists a suggestion mutation remotely or in the durable offline queue.
    /// Returning `true` is the fence that permits the proposal dismissal.
    func ensureTaskUpdateIsDurable(_ task: TaskEvent) async -> Bool
    func ensureTaskCreateIsDurable(_ task: TaskEvent) async -> Bool
    /// Pulls the backend snapshot into the local store, reporting whether it completed.
    ///
    /// `syncFromBackend()` swallows its failure, which is fine for background refreshes
    /// but not for a read path answering a question: silently serving a stale snapshot is
    /// how the agent ends up unable to account for work the backend already recorded.
    /// Callers that must not do that use the result to say the answer may be out of date.
    @discardableResult
    func refreshFromBackend() async -> Bool
}

/// Suggestion writes are stricter than ordinary background sync: they may only execute with the
/// exact credential/backend authority captured with the rendered account scope.
protocol ScopedSuggestionTaskSyncServiceProtocol: TaskSyncServiceProtocol {
    func ensureSuggestionTaskUpdateIsDurable(
        _ task: TaskEvent,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async -> Bool
    func ensureSuggestionTaskCreateIsDurable(
        _ task: TaskEvent,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async -> Bool
}

public extension TaskSyncServiceProtocol {
    /// Conformers that cannot pull report `false` rather than `true`: a read path should
    /// flag the answer as possibly stale, never claim a freshness it did not get.
    @discardableResult
    func refreshFromBackend() async -> Bool { false }

    func discardPendingOperations(for taskId: UUID) async -> Bool { true }

    func syncTaskToBackendImmediately(_ task: TaskEvent, includeListID: Bool) async throws {
        try await syncTaskToBackendImmediately(task)
    }

    func ensureTaskUpdateIsDurable(_ task: TaskEvent) async -> Bool {
        do {
            try await syncTaskToBackendImmediately(task)
            return true
        } catch {
            return false
        }
    }

    func ensureTaskCreateIsDurable(_ task: TaskEvent) async -> Bool {
        (try? await syncTaskCreateToBackendImmediately(task)) != nil
    }

    /// After the backend confirms deletion, remove any stale create/update intent. If
    /// that cleanup cannot be persisted, retain an idempotent delete intent instead.
    func recordConfirmedDelete(for taskId: UUID) async -> Bool {
        if await discardPendingOperations(for: taskId) { return true }
        return await queueOperation(operationType: "delete", taskId: taskId, taskData: nil)
    }
}
