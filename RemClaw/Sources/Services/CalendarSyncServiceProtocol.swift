import Foundation
import SwiftUI

public struct DeviceCalendarEventSummary: Sendable {
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let durationMinutes: Int
    public let calendarEventID: String
}

public struct CalendarInfo: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let color: Color
}

public struct CalendarEventAccess: Sendable {
    public let canEdit: Bool
    public let canDelete: Bool
    public let allowsLocalCleanup: Bool
    public let isReadOnly: Bool
    public let isRecurring: Bool
    public let failureReason: String?

    public init(
        canEdit: Bool,
        canDelete: Bool,
        allowsLocalCleanup: Bool = false,
        isReadOnly: Bool,
        isRecurring: Bool,
        failureReason: String? = nil
    ) {
        self.canEdit = canEdit
        self.canDelete = canDelete
        self.allowsLocalCleanup = allowsLocalCleanup
        self.isReadOnly = isReadOnly
        self.isRecurring = isRecurring
        self.failureReason = failureReason
    }
}

public enum CalendarDeleteFailureReason: Sendable {
    case permissionDenied
    case readOnlyCalendar
    case eventNotFound
    case unknown
}

public enum CalendarDeleteScope: Sendable {
    case thisEvent
    case futureEvents
}

public struct CalendarDeleteResult: Sendable {
    public let deleted: Bool
    public let eventID: String?
    public let title: String?
    public let failureReason: CalendarDeleteFailureReason?
    public let message: String?

    public init(
        deleted: Bool,
        eventID: String?,
        title: String?,
        failureReason: CalendarDeleteFailureReason? = nil,
        message: String? = nil
    ) {
        self.deleted = deleted
        self.eventID = eventID
        self.title = title
        self.failureReason = failureReason
        self.message = message
    }
}

@MainActor
public protocol CalendarSyncService {
    func getAvailableCalendars() async -> [CalendarInfo]
    func saveEventToCalendar(task: TaskEvent) async throws -> String?
    func updateEventInCalendar(task: TaskEvent) async throws
    func deleteEventFromCalendar(task: TaskEvent, scope: CalendarDeleteScope) async -> CalendarDeleteResult
    func getCalendarInfo(forEvent eventID: String) async -> CalendarInfo?
    func getEventAccess(forEvent eventID: String) async -> CalendarEventAccess
    func findEventID(title: String, startDate: Date) async -> String?
    func getDefaultCalendarIdentifier() async -> String?
    func fetchEventsFromDevice(start: Date, end: Date) async throws -> [DeviceCalendarEventSummary]
    func getEventFromDevice(calendarEventID: String) async -> DeviceCalendarEventSummary?
    func updateEventInCalendar(calendarEventID: String, title: String?, startDate: Date?, endDate: Date?) async throws
    func deleteEventFromCalendar(calendarEventID: String, scope: CalendarDeleteScope) async -> CalendarDeleteResult
}
