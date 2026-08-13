import Foundation
import SwiftData

/// Fetches tasks from the Express backend and upserts into local SwiftData.
/// Called on app launch and pull-to-refresh.
@MainActor
final class TaskSyncManager {
    private let apiService: TaskApiServiceProtocol
    private let modelContext: ModelContext

    init(apiService: TaskApiServiceProtocol, modelContext: ModelContext) {
        self.apiService = apiService
        self.modelContext = modelContext
    }

    /// Pull all tasks from backend → upsert into SwiftData
    func syncFromBackend() async {
        do {
            let responses = try await apiService.fetchTasks()
            let existingTasks = try modelContext.fetch(FetchDescriptor<TaskEvent>())
            let existingByBackendId = Dictionary(grouping: existingTasks, by: { $0.id.uuidString })

            for response in responses {
                guard let backendUUID = UUID(uuidString: response.id) else { continue }

                if let existing = existingByBackendId[response.id]?.first {
                    // Update existing
                    applyResponse(response, to: existing)
                } else {
                    // Insert new
                    let task = TaskEvent(id: backendUUID)
                    applyResponse(response, to: task)
                    modelContext.insert(task)
                }
            }

            // Remove local tasks that no longer exist on backend
            let backendIds = Set(responses.map(\.id))
            for task in existingTasks where task.isCalendarOnlyMirror != true && !backendIds.contains(task.id.uuidString) {
                modelContext.delete(task)
            }

            try modelContext.save()
        } catch {
            print("[TaskSync] Failed to sync from backend: \(error.localizedDescription)")
        }
    }

    /// Push a local task to the backend (create)
    func pushToBackend(_ task: TaskEvent) async {
        do {
            let durationMinutes: Int? = task.duration.map { Int($0 / 60) }
            _ = try await apiService.saveTaskToBackend(
                id: task.id.uuidString,
                title: task.title,
                priority: task.priority,
                status: task.status,
                startDate: task.startDate,
                endDate: task.endDate,
                durationMinutes: durationMinutes,
                alertTime: task.alertTime,
                repeatFrequency: task.repeatFrequency
            )
        } catch {
            print("[TaskSync] Failed to push task to backend: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return Self.iso8601.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func applyResponse(_ response: TaskEventApiResponse, to task: TaskEvent) {
        task.title = response.title
        task.status = response.status ?? "pending"
        task.priority = response.priority ?? "medium"
        // Only overwrite the schedule when the backend actually carries one.
        // A pull whose payload omits start_date must NOT clear the local value,
        // or a locally-scheduled task reverts to unscheduled on refresh. Mirrors
        // the guarded merge in RemTaskSyncService.syncFromBackend.
        if let sd = response.startDate { task.startDate = parseDate(sd) }
        if let ed = response.endDate { task.endDate = parseDate(ed) }
        task.isEvent = response.type == "calendar_event"
        task.isCalendarOnlyMirror = false

        if let minutes = response.durationMinutes {
            task.duration = TimeInterval(minutes * 60)
        }
        if let at = response.alertTime { task.alertTime = parseDate(at) }
        if let rf = response.repeatFrequency { task.repeatFrequency = rf }
        task.calendarEventID = response.calendarEventID
        // The co-authored description (migration 120): backend is the source of truth for
        // BOTH halves, because the merge that keeps them from clobbering each other only
        // exists there. Mirror unconditionally (including nil) so a cleared half clears
        // locally too.
        task.taskDescription = response.descriptionUser
        task.agentContext = response.descriptionAgent
        // Organization: backend is source of truth for list assignment.
        task.listID = response.listID.flatMap { UUID(uuidString: $0) }
        // Agent run-state (migration 019): backend is source of truth. Mirror
        // unconditionally (including nil) so a reaped/cleared run clears locally too.
        task.runStatus = response.runStatus
        task.runId = response.runId
        task.sessionKey = response.sessionKey
        task.runStartedAt = parseDate(response.runStartedAt)
        // Staleness (migration 116): backend is source of truth. Mirror unconditionally, INCLUDING
        // nil — a task that was un-staled server-side must lose its dim and its badge here, and a
        // client that only ever wrote non-nil values would keep both forever.
        //
        // This is the FULL-PULL path only (`applyResponse` is called solely from
        // `syncFromBackend`), so it is not the ACK of any particular user write. The write-ACK is
        // handled where the PATCH actually happens — `RemTaskSyncService.syncTaskToBackendImmediately`
        // — because waiting for the next pull would leave a just-touched task looking stale.
        task.staleAt = parseDate(response.staleAt)

        if let created = parseDate(response.createdAt) { task.createdAt = created }
        if let updated = parseDate(response.updatedAt) { task.updatedAt = updated }
    }
}
