import Foundation
import SwiftData
import SwiftUI

// MARK: - Stub Task API Service

/// Stub implementation that returns empty data.
/// Replace with real Express/PostgreSQL backend calls in Phase B.
@MainActor
final class StubTaskApiService: TaskApiServiceProtocol {
    func saveTaskToBackend(id: String?, title: String, priority: String, status: String, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, status: status, priority: priority, listID: listID, descriptionUser: description)
    }

    func saveEventToBackend(id: String?, title: String, dateTime: String, durationMinutes: Int, listID: String?) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, listID: listID)
    }

    func fetchTasks() async throws -> [TaskEventApiResponse] { [] }

    func getTask(id: String) async throws -> TaskEventApiResponse {
        throw StubServiceError.notImplemented
    }

    func updateTask(id: String, title: String?, priority: String?, status: String?, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?, includeListID: Bool, includeClearedFields: Bool) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: id, title: title ?? "", listID: listID, descriptionUser: description)
    }

    func deleteTask(id: String) async throws {}

    func ensureEventBacking(calendarEventID: String, title: String, startDate: Date?, durationMinutes: Int?, listID: String?) async throws -> TaskEventApiResponse {
        TaskEventApiResponse(id: UUID().uuidString, title: title, type: "calendar_event", calendarEventID: calendarEventID)
    }
}

// MARK: - Stub Task Sync Service

/// Stub that performs local-only status updates.
/// Replace with real sync in Phase B.
final class StubTaskSyncService: TaskSyncServiceProtocol {
    func queueOperation(operationType: String, taskId: UUID?, taskData: Data?) async -> Bool { true }

    @MainActor
    func updateTaskStatus(_ task: TaskEvent, to status: TaskStatus, modelContext: ModelContext) async throws {
        task.statusEnum = status
        task.updatedAt = Date()
        try modelContext.save()
    }

    func syncTaskToBackendImmediately(_ task: TaskEvent) async throws {}

    func syncTaskCreateToBackendImmediately(_ task: TaskEvent) async throws -> TaskEventApiResponse? { nil }
}

// MARK: - Stub Calendar Sync Service

/// Stub that returns empty calendar data.
/// Replace with EventKit implementation in Phase B/C.
@MainActor
final class StubCalendarSyncService: CalendarSyncService {
    func getAvailableCalendars() async -> [CalendarInfo] { [] }
    func saveEventToCalendar(task: TaskEvent) async throws -> String? { nil }
    func updateEventInCalendar(task: TaskEvent) async throws {}
    func deleteEventFromCalendar(task: TaskEvent, scope: CalendarDeleteScope) async -> CalendarDeleteResult {
        CalendarDeleteResult(deleted: false, eventID: task.calendarEventID, title: task.title, failureReason: .unknown, message: "Calendar service unavailable.")
    }
    func getCalendarInfo(forEvent eventID: String) async -> CalendarInfo? { nil }
    func getEventAccess(forEvent eventID: String) async -> CalendarEventAccess {
        CalendarEventAccess(canEdit: false, canDelete: false, isReadOnly: true, isRecurring: false, failureReason: "Calendar service unavailable.")
    }
    func findEventID(title: String, startDate: Date) async -> String? { nil }
    func getDefaultCalendarIdentifier() async -> String? { nil }
    func fetchEventsFromDevice(start: Date, end: Date) async throws -> [DeviceCalendarEventSummary] { [] }
    func getEventFromDevice(calendarEventID: String) async -> DeviceCalendarEventSummary? { nil }
    func updateEventInCalendar(calendarEventID: String, title: String?, startDate: Date?, endDate: Date?) async throws {}
    func deleteEventFromCalendar(calendarEventID: String, scope: CalendarDeleteScope) async -> CalendarDeleteResult {
        CalendarDeleteResult(deleted: false, eventID: calendarEventID, title: nil, failureReason: .unknown, message: "Calendar service unavailable.")
    }
}

// MARK: - Error

enum StubServiceError: Error {
    case notImplemented
}
