import EventKit
import Foundation

/// Handles reminders commands from the gateway AI agent.
/// Uses EKEventStore with the .reminder entity type.
@MainActor
final class RemindersService {
    private let eventStore = EKEventStore()

    // MARK: - Authorization

    private func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            if #available(iOS 17.0, *) {
                let granted = try await eventStore.requestFullAccessToReminders()
                if !granted { throw RemindersServiceError.permissionDenied }
            } else {
                let granted = try await eventStore.requestAccess(to: .reminder)
                if !granted { throw RemindersServiceError.permissionDenied }
            }
        default:
            throw RemindersServiceError.permissionDenied
        }
    }

    // MARK: - List

    func listReminders(params: RemindersListParams?) async throws -> [ReminderPayload] {
        try await ensureAccess()

        let calendars: [EKCalendar]?
        if let listName = params?.listName {
            let all = eventStore.calendars(for: .reminder)
            calendars = all.filter { $0.title == listName }
        } else {
            calendars = nil
        }

        let predicate: NSPredicate
        if params?.includeCompleted == true {
            // Fetch all reminders in the specified calendars
            predicate = eventStore.predicateForReminders(in: calendars)
        } else {
            predicate = eventStore.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: calendars)
        }

        let reminders = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EKReminder], any Error>) in
            eventStore.fetchReminders(matching: predicate) { result in
                cont.resume(returning: result ?? [])
            }
        }

        let limit = params?.limit ?? 50
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return Array(reminders.prefix(limit)).map { reminder in
            let dueDate: String? = {
                guard let comps = reminder.dueDateComponents,
                      let date = Calendar.current.date(from: comps)
                else { return nil }
                return formatter.string(from: date)
            }()
            return ReminderPayload(
                identifier: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                notes: reminder.notes,
                dueDate: dueDate,
                isCompleted: reminder.isCompleted,
                priority: reminder.priority,
                listName: reminder.calendar?.title)
        }
    }

    // MARK: - Add

    func addReminder(params: RemindersAddParams) async throws -> String {
        try await ensureAccess()

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = params.title
        reminder.notes = params.notes
        reminder.priority = params.priority ?? 0

        if let listName = params.listName {
            let calendars = eventStore.calendars(for: .reminder)
            if let match = calendars.first(where: { $0.title == listName }) {
                reminder.calendar = match
            } else {
                reminder.calendar = eventStore.defaultCalendarForNewReminders()
            }
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        if let dueDateStr = params.dueDate {
            // Try with fractional seconds first, then without (AI sends both formats)
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let withoutFrac = ISO8601DateFormatter()
            withoutFrac.formatOptions = [.withInternetDateTime]
            if let date = withFrac.date(from: dueDateStr) ?? withoutFrac.date(from: dueDateStr) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: date)
            }
        }

        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    // MARK: - Update

    func updateReminder(params: RemindersUpdateParams) async throws -> (identifier: String, title: String?) {
        try await ensureAccess()

        guard let item = eventStore.calendarItem(withIdentifier: params.identifier),
              let reminder = item as? EKReminder else {
            throw RemindersServiceError.reminderNotFound
        }

        if let title = params.title { reminder.title = title }
        if let notes = params.notes { reminder.notes = notes }
        if let isCompleted = params.isCompleted { reminder.isCompleted = isCompleted }
        if let priority = params.priority { reminder.priority = priority }

        if let listName = params.listName {
            let calendars = eventStore.calendars(for: .reminder)
            if let match = calendars.first(where: { $0.title == listName }) {
                reminder.calendar = match
            }
        }

        if let dueDateStr = params.dueDate {
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let withoutFrac = ISO8601DateFormatter()
            withoutFrac.formatOptions = [.withInternetDateTime]
            if let date = withFrac.date(from: dueDateStr) ?? withoutFrac.date(from: dueDateStr) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: date)
            }
        }

        try eventStore.save(reminder, commit: true)
        return (reminder.calendarItemIdentifier, reminder.title)
    }

    // MARK: - Delete

    func deleteReminder(identifier: String) async throws -> (identifier: String, title: String?) {
        try await ensureAccess()

        guard let item = eventStore.calendarItem(withIdentifier: identifier),
              let reminder = item as? EKReminder else {
            throw RemindersServiceError.reminderNotFound
        }

        let title = reminder.title
        try eventStore.remove(reminder, commit: true)
        return (identifier, title)
    }
}

enum RemindersServiceError: LocalizedError {
    case permissionDenied
    case reminderNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Reminders access denied. Enable reminders permissions in Settings."
        case .reminderNotFound:
            "Reminder not found."
        }
    }
}
