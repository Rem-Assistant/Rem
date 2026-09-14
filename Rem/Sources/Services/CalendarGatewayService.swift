import Combine
import EventKit
import Foundation

/// Adapter that translates between the gateway's calendar command types
/// and the existing RemCalendarService / EKEventStore.
@MainActor
final class CalendarGatewayService {
    private let eventStore = EKEventStore()

    private func publishCalendarChange() {
        NotificationCenter.default.post(name: .remCalendarStoreChanged, object: nil)
    }

    // MARK: - Authorization

    private func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return
        case .notDetermined:
            if #available(iOS 17.0, *) {
                let granted = try await eventStore.requestFullAccessToEvents()
                if !granted { throw CalendarError.permissionDenied }
            } else {
                let granted = try await eventStore.requestAccess(to: .event)
                if !granted { throw CalendarError.permissionDenied }
            }
        default:
            throw CalendarError.permissionDenied
        }
    }

    // MARK: - ISO 8601 parsing (lenient)

    /// Parses ISO 8601 dates with or without fractional seconds.
    /// AI agents commonly send both formats.
    private static func parseISO8601(_ string: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: string) { return d }

        let withoutFrac = ISO8601DateFormatter()
        withoutFrac.formatOptions = [.withInternetDateTime]
        return withoutFrac.date(from: string)
    }

    // MARK: - calendar.events

    func fetchEvents(params: CalendarEventsParams) async throws -> [CalendarEventPayload] {
        try await ensureAccess()

        let start: Date
        if let s = params.startDate, let d = Self.parseISO8601(s) {
            start = d
        } else {
            start = Calendar.current.startOfDay(for: Date())
        }

        let end: Date
        if let e = params.endDate, let d = Self.parseISO8601(e) {
            end = d
        } else {
            end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        }

        var calendars: [EKCalendar]?
        if let calId = params.calendarId {
            if let cal = eventStore.calendar(withIdentifier: calId) {
                calendars = [cal]
            }
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = eventStore.events(matching: predicate)
        let limit = params.limit ?? 50

        let outFormatter = ISO8601DateFormatter()
        outFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return Array(events.prefix(limit)).map { event in
            let eventStart = event.startDate ?? start
            let eventEnd = event.endDate ?? eventStart
            let duration = max(0, Int(eventEnd.timeIntervalSince(eventStart) / 60))
            return CalendarEventPayload(
                eventId: event.eventIdentifier ?? "",
                title: event.title ?? "",
                startDate: outFormatter.string(from: eventStart),
                endDate: outFormatter.string(from: eventEnd),
                durationMinutes: duration,
                isAllDay: event.isAllDay,
                calendarName: event.calendar?.title)
        }
    }

    // MARK: - calendar.add

    func addEvent(params: CalendarAddParams) async throws -> String {
        try await ensureAccess()

        guard let startDate = Self.parseISO8601(params.startDate) else {
            throw CalendarError.setupFailed
        }

        let endDate: Date
        if let e = params.endDate, let d = Self.parseISO8601(e) {
            endDate = d
        } else if let mins = params.durationMinutes {
            endDate = startDate.addingTimeInterval(TimeInterval(mins * 60))
        } else {
            endDate = startDate.addingTimeInterval(3600)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = params.title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = params.notes
        event.isAllDay = params.isAllDay ?? false

        let allCalendars = eventStore.calendars(for: .event)
        let writableCalendars = allCalendars.filter { $0.allowsContentModifications }

        if let calName = params.calendarName {
            event.calendar = writableCalendars.first(where: { $0.title == calName })
                ?? eventStore.defaultCalendarForNewEvents
                ?? writableCalendars.first
        } else {
            event.calendar = eventStore.defaultCalendarForNewEvents
                ?? writableCalendars.first
        }

        guard event.calendar != nil else {
            throw CalendarError.setupFailed
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        publishCalendarChange()

        guard let eventId = event.eventIdentifier else {
            throw CalendarError.eventNotFound
        }
        return eventId
    }

    // MARK: - calendar.update

    func updateEvent(params: CalendarUpdateParams) async throws -> (eventId: String, title: String?) {
        try await ensureAccess()

        guard let event = eventStore.event(withIdentifier: params.eventId) else {
            throw CalendarError.eventNotFound
        }

        if let title = params.title { event.title = title }
        if let notes = params.notes { event.notes = notes }
        if let isAllDay = params.isAllDay { event.isAllDay = isAllDay }

        if let startStr = params.startDate, let start = Self.parseISO8601(startStr) {
            event.startDate = start
            // Recompute end from new start if no explicit end provided
            if params.endDate == nil, let mins = params.durationMinutes {
                event.endDate = start.addingTimeInterval(TimeInterval(mins * 60))
            }
        }

        if let endStr = params.endDate, let end = Self.parseISO8601(endStr) {
            event.endDate = end
        } else if params.startDate == nil, let mins = params.durationMinutes, let start = event.startDate {
            event.endDate = start.addingTimeInterval(TimeInterval(mins * 60))
        }

        if let calName = params.calendarName {
            let writable = eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
            if let match = writable.first(where: { $0.title == calName }) {
                event.calendar = match
            }
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        publishCalendarChange()
        return (params.eventId, event.title)
    }

    // MARK: - calendar.delete

    func deleteEvent(eventId: String) async throws -> (eventId: String, title: String?) {
        try await ensureAccess()

        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw CalendarError.eventNotFound
        }

        let title = event.title
        try eventStore.remove(event, span: .thisEvent, commit: true)
        publishCalendarChange()
        return (eventId, title)
    }
}
