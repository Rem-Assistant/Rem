import Foundation
import SwiftData
import Testing
@testable import RemClaw

/// Regression coverage for the "scheduled task reverts to unscheduled on refresh"
/// bug. A task scheduled locally (startDate set) must keep its schedule when a
/// backend pull returns the same task WITHOUT a start_date — the pull must not
/// clobber the local value. See TaskSyncManager.applyResponse /
/// RemTaskSyncService.syncFromBackend (guarded merge).
@MainActor
struct TaskScheduleSyncTests {

    /// Minimal API stub whose fetchTasks payload is configurable per test.
    final class FetchStubApi: TaskApiServiceProtocol {
        var fetchResult: [TaskEventApiResponse] = []
        func saveTaskToBackend(id: String?, title: String, priority: String, status: String, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, listID: listID)
        }
        func saveEventToBackend(id: String?, title: String, dateTime: String, durationMinutes: Int, listID: String?) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, listID: listID)
        }
        func fetchTasks() async throws -> [TaskEventApiResponse] { fetchResult }
        func getTask(id: String) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id, title: "")
        }
        func updateTask(id: String, title: String?, priority: String?, status: String?, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?, includeListID: Bool, includeClearedFields: Bool) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id, title: title ?? "", listID: listID, descriptionUser: description)
        }
        func deleteTask(id: String) async throws {}
        func ensureEventBacking(calendarEventID: String, title: String, startDate: Date?, durationMinutes: Int?, listID: String?) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: UUID().uuidString, title: title, type: "calendar_event", calendarEventID: calendarEventID)
        }
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        return ModelContext(container)
    }

    @Test func pullWithoutStartDateKeepsLocalSchedule() async throws {
        let context = try makeContext()
        let id = UUID()
        let scheduledDate = Date(timeIntervalSince1970: 1_765_324_800)
        let local = TaskEvent(id: id, title: "ello", startDate: scheduledDate)
        context.insert(local)
        try context.save()

        // Backend returns the task but with no start_date (the schedule was never
        // pushed server-side). This must NOT unschedule the local task.
        let api = FetchStubApi()
        api.fetchResult = [
            TaskEventApiResponse(id: id.uuidString, title: "ello", status: "pending", startDate: nil)
        ]

        let manager = TaskSyncManager(apiService: api, modelContext: context)
        await manager.syncFromBackend()

        let refreshed = try context.fetch(FetchDescriptor<TaskEvent>()).first
        #expect(refreshed?.startDate == scheduledDate)
        #expect(refreshed?.shouldAppearInInbox == false)
    }

    @Test func pullWithStartDateAppliesSchedule() async throws {
        let context = try makeContext()
        let id = UUID()
        let local = TaskEvent(id: id, title: "ello", startDate: nil)
        context.insert(local)
        try context.save()

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let remoteDate = Date(timeIntervalSince1970: 1_765_411_200)
        let api = FetchStubApi()
        api.fetchResult = [
            TaskEventApiResponse(id: id.uuidString, title: "ello", status: "pending", startDate: iso.string(from: remoteDate))
        ]

        let manager = TaskSyncManager(apiService: api, modelContext: context)
        await manager.syncFromBackend()

        let refreshed = try context.fetch(FetchDescriptor<TaskEvent>()).first
        #expect(refreshed?.startDate != nil)
        #expect(refreshed?.shouldAppearInInbox == false)
    }
}
