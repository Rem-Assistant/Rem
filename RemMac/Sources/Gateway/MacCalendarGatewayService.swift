import EventKit
import Foundation

enum MacCalendarCommand: String {
    case events = "calendar.events"
    case add = "calendar.add"
    case update = "calendar.update"
    case delete = "calendar.delete"
}

struct MacCalendarEventsParams: Codable, Sendable {
    var startDate: String?
    var endDate: String?
    var calendarId: String?
    var limit: Int?
}

struct MacCalendarAddParams: Codable, Sendable {
    var title: String
    var startDate: String
    var endDate: String?
    var durationMinutes: Int?
    var notes: String?
    var calendarName: String?
    var isAllDay: Bool?
}

struct MacCalendarAddResponse: Codable, Sendable {
    var eventId: String
    var title: String?
}

struct MacCalendarUpdateParams: Codable, Sendable {
    var eventId: String
    var title: String?
    var startDate: String?
    var endDate: String?
    var durationMinutes: Int?
    var notes: String?
    var calendarName: String?
    var isAllDay: Bool?
}

struct MacCalendarUpdateResponse: Codable, Sendable {
    var eventId: String
    var title: String?
}

struct MacCalendarDeleteParams: Codable, Sendable {
    var eventId: String
}

struct MacCalendarDeleteResponse: Codable, Sendable {
    var deleted: Bool
    var eventId: String
    var title: String?
}

enum MacCalendarGatewayError: Error, Equatable {
    case permissionDenied
    case readOnly(String)
    case eventNotFound
    case setupFailed(String)

    var userMessage: String {
        switch self {
        case .permissionDenied:
            return "Calendar access denied. Enable Calendar permission for Rem in System Settings."
        case .readOnly(let message), .setupFailed(let message):
            return message
        case .eventNotFound:
            return "This calendar event is no longer available."
        }
    }
}

@MainActor
protocol MacCalendarGatewayServicing: AnyObject {
    func fetchEvents(params: MacCalendarEventsParams) async throws -> [CalendarEventPayload]
    func addEvent(params: MacCalendarAddParams) async throws -> MacCalendarAddResponse
    func updateEvent(params: MacCalendarUpdateParams) async throws -> MacCalendarUpdateResponse
    func deleteEvent(params: MacCalendarDeleteParams) async throws -> MacCalendarDeleteResponse
}

@MainActor
final class MacCalendarGatewayService: MacCalendarGatewayServicing {
    private let eventStore = EKEventStore()

    nonisolated static var currentAuthorizationSupportsCommands: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly, .authorized, .notDetermined:
            return true
        default:
            return false
        }
    }

    func fetchEvents(params: MacCalendarEventsParams) async throws -> [CalendarEventPayload] {
        try await ensureReadAccess()

        let start = params.startDate.flatMap(Self.parseISO8601)
            ?? Calendar.current.startOfDay(for: Date())
        let end = params.endDate.flatMap(Self.parseISO8601)
            ?? Calendar.current.date(byAdding: .day, value: 7, to: start)
            ?? start

        var calendars: [EKCalendar]?
        if let calendarId = params.calendarId,
           let calendar = eventStore.calendar(withIdentifier: calendarId) {
            calendars = [calendar]
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        let limit = params.limit ?? 50
        let formatter = Self.outputFormatter()

        return Array(events.prefix(limit)).map { event in
            let eventStart = event.startDate ?? start
            let eventEnd = event.endDate ?? eventStart
            let duration = max(0, Int(eventEnd.timeIntervalSince(eventStart) / 60))
            return CalendarEventPayload(
                eventId: event.eventIdentifier ?? "",
                title: event.title ?? "",
                startDate: formatter.string(from: eventStart),
                endDate: formatter.string(from: eventEnd),
                durationMinutes: duration,
                isAllDay: event.isAllDay,
                calendarName: event.calendar?.title
            )
        }
    }

    func addEvent(params: MacCalendarAddParams) async throws -> MacCalendarAddResponse {
        try await ensureWriteAccess()

        guard let startDate = Self.parseISO8601(params.startDate) else {
            throw MacCalendarGatewayError.setupFailed("calendar.add requires a valid ISO-8601 startDate.")
        }

        let endDate = resolvedEndDate(
            startDate: startDate,
            endDate: params.endDate,
            durationMinutes: params.durationMinutes
        )

        let event = EKEvent(eventStore: eventStore)
        event.title = params.title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = params.notes
        event.isAllDay = params.isAllDay ?? false
        event.calendar = writableCalendar(named: params.calendarName)

        guard event.calendar != nil else {
            if let calendarName = params.calendarName {
                throw MacCalendarGatewayError.readOnly("Calendar \"\(calendarName)\" is unavailable or read-only.")
            }
            throw MacCalendarGatewayError.readOnly("No writable Calendar is available on this Mac.")
        }

        try eventStore.save(event, span: .thisEvent, commit: true)

        guard let eventId = event.eventIdentifier else {
            throw MacCalendarGatewayError.eventNotFound
        }
        return MacCalendarAddResponse(eventId: eventId, title: params.title)
    }

    func updateEvent(params: MacCalendarUpdateParams) async throws -> MacCalendarUpdateResponse {
        try await ensureReadWriteAccess()

        guard let event = eventStore.event(withIdentifier: params.eventId) else {
            throw MacCalendarGatewayError.eventNotFound
        }
        guard event.calendar?.allowsContentModifications == true else {
            throw MacCalendarGatewayError.readOnly("This event belongs to a read-only Calendar.")
        }

        if let title = params.title { event.title = title }
        if let notes = params.notes { event.notes = notes }
        if let isAllDay = params.isAllDay { event.isAllDay = isAllDay }

        if let startDate = params.startDate.flatMap(Self.parseISO8601) {
            event.startDate = startDate
            if params.endDate == nil, let minutes = params.durationMinutes {
                event.endDate = startDate.addingTimeInterval(TimeInterval(minutes * 60))
            }
        }
        if let endDate = params.endDate.flatMap(Self.parseISO8601) {
            event.endDate = endDate
        } else if params.startDate == nil,
                  let minutes = params.durationMinutes,
                  let startDate = event.startDate {
            event.endDate = startDate.addingTimeInterval(TimeInterval(minutes * 60))
        }
        if let calendarName = params.calendarName {
            guard let calendar = writableCalendar(named: calendarName) else {
                throw MacCalendarGatewayError.readOnly("Calendar \"\(calendarName)\" is unavailable or read-only.")
            }
            event.calendar = calendar
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        return MacCalendarUpdateResponse(eventId: params.eventId, title: event.title)
    }

    func deleteEvent(params: MacCalendarDeleteParams) async throws -> MacCalendarDeleteResponse {
        try await ensureReadWriteAccess()

        guard let event = eventStore.event(withIdentifier: params.eventId) else {
            throw MacCalendarGatewayError.eventNotFound
        }
        guard event.calendar?.allowsContentModifications == true else {
            throw MacCalendarGatewayError.readOnly("This event belongs to a read-only Calendar.")
        }

        let title = event.title
        try eventStore.remove(event, span: .thisEvent, commit: true)
        return MacCalendarDeleteResponse(deleted: true, eventId: params.eventId, title: title)
    }

    private func ensureReadAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            if !granted { throw MacCalendarGatewayError.permissionDenied }
        case .writeOnly:
            throw MacCalendarGatewayError.readOnly("Calendar read access is required to fetch events.")
        default:
            throw MacCalendarGatewayError.permissionDenied
        }
    }

    private func ensureWriteAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly, .authorized:
            return
        case .notDetermined:
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            if !granted { throw MacCalendarGatewayError.permissionDenied }
        default:
            throw MacCalendarGatewayError.permissionDenied
        }
    }

    private func ensureReadWriteAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            if !granted { throw MacCalendarGatewayError.permissionDenied }
        case .writeOnly:
            throw MacCalendarGatewayError.readOnly("Full Calendar access is required to update or delete existing events.")
        default:
            throw MacCalendarGatewayError.permissionDenied
        }
    }

    private func writableCalendar(named name: String?) -> EKCalendar? {
        let writable = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)

        if let name {
            return writable.first(where: { $0.title == name })
        }
        return eventStore.defaultCalendarForNewEvents ?? writable.first
    }

    private func resolvedEndDate(
        startDate: Date,
        endDate: String?,
        durationMinutes: Int?
    ) -> Date {
        if let endDate, let parsed = Self.parseISO8601(endDate) {
            return parsed
        }
        if let durationMinutes {
            return startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        }
        return startDate.addingTimeInterval(3600)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }

        let withoutFractionalSeconds = ISO8601DateFormatter()
        withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
        return withoutFractionalSeconds.date(from: string)
    }

    private static func outputFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
