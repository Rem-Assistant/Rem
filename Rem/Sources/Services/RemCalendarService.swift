import Combine
import EventKit
import Foundation
import SwiftUI

@MainActor
public class RemCalendarService: ObservableObject, CalendarSyncService {
    private static let selectedCalendarDefaultsKey = "selectedCalendarID"
    private var eventStore = EKEventStore()
    @Published private var authorizationStatus: EKAuthorizationStatus = .notDetermined
    private var eventStoreChangedObserver: NSObjectProtocol?

    public init() {
        checkAuthorizationStatus()
        observeEventStoreChanges()
    }

    deinit {
        if let eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(eventStoreChangedObserver)
        }
    }

    // MARK: - Authorization

    private func checkAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private func requestCalendarAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await eventStore.requestFullAccessToEvents()
        } else {
            return try await eventStore.requestAccess(to: .event)
        }
    }

    private func ensureCalendarReadAccess() async throws {
        checkAuthorizationStatus()

        switch authorizationStatus {
        case .notDetermined:
            let granted = try await requestCalendarAccess()
            if !granted { throw CalendarError.permissionDenied }
            checkAuthorizationStatus()
            if !authorizationAllowsRead() { throw CalendarError.permissionDenied }
        case .denied, .restricted, .writeOnly:
            throw CalendarError.permissionDenied
        case .fullAccess, .authorized:
            return
        @unknown default:
            throw CalendarError.permissionDenied
        }
    }

    private func ensureCalendarWriteAccess() async throws {
        checkAuthorizationStatus()

        switch authorizationStatus {
        case .notDetermined:
            let granted = try await requestCalendarAccess()
            if !granted { throw CalendarError.permissionDenied }
            checkAuthorizationStatus()
            if !authorizationAllowsWrite() { throw CalendarError.permissionDenied }
        case .denied, .restricted:
            throw CalendarError.permissionDenied
        case .fullAccess, .writeOnly, .authorized:
            return
        @unknown default:
            throw CalendarError.permissionDenied
        }
    }

    private func observeEventStoreChanges() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .remCalendarStoreChanged, object: nil)
        }
    }

    private func publishCalendarChange() {
        NotificationCenter.default.post(name: .remCalendarStoreChanged, object: nil)
    }

    private func authorizationAllowsWrite() -> Bool {
        CalendarAuthorizationPolicy.allowsWrite(authorizationStatus)
    }

    private func authorizationAllowsRead() -> Bool {
        CalendarAuthorizationPolicy.allowsRead(authorizationStatus)
    }

    enum CalendarAuthorizationPolicy {
        static func allowsRead(_ status: EKAuthorizationStatus) -> Bool {
            switch status {
            case .fullAccess, .authorized:
                return true
            default:
                return false
            }
        }

        static func allowsWrite(_ status: EKAuthorizationStatus) -> Bool {
            switch status {
            case .fullAccess, .writeOnly, .authorized:
                return true
            default:
                return false
            }
        }
    }

    private func eventAccess(for event: EKEvent) -> CalendarEventAccess {
        let calendarAllowsChanges = event.calendar.allowsContentModifications
        let canModify = authorizationAllowsWrite() && calendarAllowsChanges
        let isRecurring = !(event.recurrenceRules ?? []).isEmpty

        if canModify {
            return CalendarEventAccess(
                canEdit: true,
                canDelete: true,
                isReadOnly: false,
                isRecurring: isRecurring
            )
        }
        return CalendarEventAccess(
            canEdit: false,
            canDelete: false,
            isReadOnly: true,
            isRecurring: isRecurring,
            failureReason: "This event belongs to a read-only or shared calendar that doesn't allow changes."
        )
    }

    private func ekSpan(for scope: CalendarDeleteScope, event: EKEvent) -> EKSpan {
        guard scope == .futureEvents, !(event.recurrenceRules ?? []).isEmpty else {
            return .thisEvent
        }
        return .futureEvents
    }

    private func deleteEvent(_ event: EKEvent, scope: CalendarDeleteScope) async -> CalendarDeleteResult {
        do {
            try await ensureCalendarWriteAccess()
        } catch {
            return CalendarDeleteResult(
                deleted: false,
                eventID: event.eventIdentifier,
                title: event.title,
                failureReason: .permissionDenied,
                message: CalendarError.permissionDenied.errorDescription
            )
        }

        let access = eventAccess(for: event)
        guard access.canDelete else {
            return CalendarDeleteResult(
                deleted: false,
                eventID: event.eventIdentifier,
                title: event.title,
                failureReason: .readOnlyCalendar,
                message: access.failureReason ?? "This event can't be deleted from Rem."
            )
        }

        do {
            try eventStore.remove(event, span: ekSpan(for: scope, event: event), commit: true)
            publishCalendarChange()
            return CalendarDeleteResult(
                deleted: true,
                eventID: event.eventIdentifier,
                title: event.title
            )
        } catch {
            return CalendarDeleteResult(
                deleted: false,
                eventID: event.eventIdentifier,
                title: event.title,
                failureReason: .unknown,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - CalendarSyncService Protocol

    public func getAvailableCalendars() async -> [CalendarInfo] {
        checkAuthorizationStatus()
        let status = authorizationStatus

        // If not yet determined, request access (may show system dialog)
        if status == .notDetermined {
            do {
                let granted = try await requestCalendarAccess()
                guard granted else { return [] }
                checkAuthorizationStatus()
            } catch {
                return []
            }
        } else if status == .denied || status == .restricted {
            return []
        }

        // Try existing store first
        var all = eventStore.calendars(for: .event)

        // If empty, the store might have a stale cache from before permission
        // was granted. Create a fresh one.
        if all.isEmpty {
            eventStore = EKEventStore()
            all = eventStore.calendars(for: .event)
        }

        let writable = all.filter { $0.allowsContentModifications }
        let source = writable.isEmpty ? all : writable
        return source.map { CalendarInfo(id: $0.calendarIdentifier, name: $0.title, color: Color(cgColor: $0.cgColor)) }
    }

    public func getDefaultCalendarIdentifier() async -> String? {
        if let selectedID = UserDefaults.standard.string(forKey: Self.selectedCalendarDefaultsKey),
           !selectedID.isEmpty,
           eventStore.calendar(withIdentifier: selectedID) != nil {
            return selectedID
        }
        return eventStore.defaultCalendarForNewEvents?.calendarIdentifier
    }

    public func saveEventToCalendar(task: TaskEvent) async throws -> String? {
        guard task.isEvent else { return nil }
        guard let startDate = task.startDate, let endDate = task.endDate else { return nil }

        try await ensureCalendarWriteAccess()

        let calendar = try resolveCalendar(named: task.category)
        let event = EKEvent(eventStore: eventStore)
        event.title = task.title
        event.notes = task.notes
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar
        event.isAllDay = false

        try eventStore.save(event, span: .thisEvent, commit: true)
        publishCalendarChange()
        return event.eventIdentifier
    }

    public func updateEventInCalendar(task: TaskEvent) async throws {
        guard task.isEvent else { return }
        try await ensureCalendarWriteAccess()

        guard let calendarEventID = task.calendarEventID else {
            _ = try await saveEventToCalendar(task: task)
            return
        }
        guard let startDate = task.startDate, let endDate = task.endDate else { return }
        guard let event = eventStore.event(withIdentifier: calendarEventID) else {
            _ = try await saveEventToCalendar(task: task)
            return
        }

        event.title = task.title
        event.notes = task.notes
        event.startDate = startDate
        event.endDate = endDate

        try eventStore.save(event, span: .thisEvent, commit: true)
        publishCalendarChange()
    }

    public func deleteEventFromCalendar(task: TaskEvent, scope: CalendarDeleteScope = .thisEvent) async -> CalendarDeleteResult {
        guard task.isEvent else {
            return CalendarDeleteResult(
                deleted: false,
                eventID: task.calendarEventID,
                title: task.title,
                failureReason: .unknown,
                message: "Only calendar events can be deleted from Calendar."
            )
        }
        guard let calendarEventID = task.calendarEventID else {
            return CalendarDeleteResult(
                deleted: false,
                eventID: nil,
                title: task.title,
                failureReason: .eventNotFound,
                message: CalendarError.eventNotFound.errorDescription
            )
        }
        return await deleteEventFromCalendar(calendarEventID: calendarEventID, scope: scope)
    }

    public func getCalendarInfo(forEvent eventID: String) async -> CalendarInfo? {
        checkAuthorizationStatus()
        guard authorizationAllowsRead() else { return nil }
        guard let event = eventStore.event(withIdentifier: eventID),
              let calendar = event.calendar else { return nil }
        return CalendarInfo(id: calendar.calendarIdentifier, name: calendar.title, color: Color(cgColor: calendar.cgColor))
    }

    public func getEventAccess(forEvent eventID: String) async -> CalendarEventAccess {
        checkAuthorizationStatus()
        guard authorizationAllowsRead() || authorizationAllowsWrite() || authorizationStatus == .denied || authorizationStatus == .restricted else {
            return CalendarEventAccess(
                canEdit: false,
                canDelete: false,
                isReadOnly: true,
                isRecurring: false,
                failureReason: "Calendar access hasn't been granted yet."
            )
        }
        guard authorizationAllowsWrite() else {
            return CalendarEventAccess(
                canEdit: false,
                canDelete: false,
                isReadOnly: true,
                isRecurring: false,
                failureReason: CalendarError.permissionDenied.errorDescription
            )
        }
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return CalendarEventAccess(
                canEdit: false,
                canDelete: false,
                allowsLocalCleanup: true,
                isReadOnly: true,
                isRecurring: false,
                failureReason: CalendarError.eventNotFound.errorDescription
            )
        }
        return eventAccess(for: event)
    }

    public func findEventID(title: String, startDate: Date) async -> String? {
        checkAuthorizationStatus()
        guard authorizationAllowsRead() else { return nil }
        let searchStart = Calendar.current.date(byAdding: .day, value: -1, to: startDate) ?? startDate
        let searchEnd = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate
        let predicate = eventStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: nil)
        let events = eventStore.events(matching: predicate)

        if let match = events.first(where: { $0.title == title }) {
            return match.eventIdentifier
        }
        if let match = events.first(where: { $0.title?.lowercased() == title.lowercased() }) {
            return match.eventIdentifier
        }
        return nil
    }

    public func fetchEventsFromDevice(start: Date, end: Date) async throws -> [DeviceCalendarEventSummary] {
        try await ensureCalendarReadAccess()
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).compactMap { event -> DeviceCalendarEventSummary? in
            guard let id = event.eventIdentifier else { return nil }
            let startDate = event.startDate ?? start
            let endDate = event.endDate ?? start
            let durationMinutes = max(0, Int(endDate.timeIntervalSince(startDate) / 60))
            return DeviceCalendarEventSummary(
                title: event.title ?? "",
                startDate: startDate,
                endDate: endDate,
                durationMinutes: durationMinutes,
                calendarEventID: id
            )
        }
    }

    public func getEventFromDevice(calendarEventID: String) async -> DeviceCalendarEventSummary? {
        guard let event = eventStore.event(withIdentifier: calendarEventID),
              let id = event.eventIdentifier else { return nil }
        let startDate = event.startDate ?? Date()
        let endDate = event.endDate ?? startDate
        let durationMinutes = max(0, Int(endDate.timeIntervalSince(startDate) / 60))
        return DeviceCalendarEventSummary(
            title: event.title ?? "",
            startDate: startDate,
            endDate: endDate,
            durationMinutes: durationMinutes,
            calendarEventID: id
        )
    }

    public func updateEventInCalendar(calendarEventID: String, title: String?, startDate: Date?, endDate: Date?) async throws {
        try await ensureCalendarWriteAccess()
        guard let event = eventStore.event(withIdentifier: calendarEventID) else {
            throw CalendarError.eventNotFound
        }
        if let title { event.title = title }
        if let startDate { event.startDate = startDate }
        if let endDate { event.endDate = endDate }
        try eventStore.save(event, span: .thisEvent, commit: true)
        publishCalendarChange()
    }

    public func deleteEventFromCalendar(calendarEventID: String, scope: CalendarDeleteScope = .thisEvent) async -> CalendarDeleteResult {
        do {
            try await ensureCalendarWriteAccess()
        } catch {
            return CalendarDeleteResult(
                deleted: false,
                eventID: calendarEventID,
                title: nil,
                failureReason: .permissionDenied,
                message: CalendarError.permissionDenied.errorDescription
            )
        }

        guard let event = eventStore.event(withIdentifier: calendarEventID) else {
            return CalendarDeleteResult(
                deleted: false,
                eventID: calendarEventID,
                title: nil,
                failureReason: .eventNotFound,
                message: "This event was already removed from your calendar."
            )
        }
        return await deleteEvent(event, scope: scope)
    }

    // MARK: - Voice Agent Helper

    /// Schedules a calendar event from voice agent RPC input.
    func scheduleEvent(title: String, startDate: Date, durationMinutes: Int) async throws -> String {
        try await ensureCalendarWriteAccess()

        let endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let calendar = try resolveCalendar(named: nil)

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = calendar
        event.isAllDay = false

        try eventStore.save(event, span: .thisEvent, commit: true)
        publishCalendarChange()

        guard let eventID = event.eventIdentifier else {
            throw CalendarError.eventNotFound
        }
        return eventID
    }

    // MARK: - Private Helpers

    private func resolveCalendar(named name: String?) throws -> EKCalendar {
        if let selectedID = UserDefaults.standard.string(forKey: Self.selectedCalendarDefaultsKey),
           !selectedID.isEmpty,
           let selected = eventStore.calendar(withIdentifier: selectedID) {
            return selected
        }
        if let name {
            let all = eventStore.calendars(for: .event)
            if let match = all.first(where: { $0.title == name }) { return match }
        }
        if let defaultCal = eventStore.defaultCalendarForNewEvents {
            return defaultCal
        }
        if let firstCal = eventStore.calendars(for: .event).first {
            return firstCal
        }
        throw CalendarError.noCalendarAccount
    }
}

extension Notification.Name {
    static let remCalendarStoreChanged = Notification.Name("remCalendarStoreChanged")
}

// MARK: - Error

public enum CalendarError: LocalizedError {
    case setupFailed
    case unknown
    case eventNotFound
    case permissionDenied
    case noCalendarAccount

    public var errorDescription: String? {
        switch self {
        case .setupFailed: "Failed to set up calendar. Check permissions in Settings."
        case .unknown: "An unknown calendar error occurred."
        case .eventNotFound: "Calendar event not found."
        case .permissionDenied: "Calendar access denied. Enable calendar permissions in Settings."
        case .noCalendarAccount: "No calendar accounts found. Add a calendar account in iOS Settings."
        }
    }
}
