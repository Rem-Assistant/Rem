import Foundation
import UserNotifications

/// Schedules and manages local notifications for tasks with alert_time.
/// Uses UNCalendarNotificationTrigger and registers actionable notification categories
/// ("Mark Complete" and "Snooze 15 min").
///
/// No APNs/FCM — purely local UNUserNotificationCenter.
@MainActor
final class TaskNotificationService {
    static let shared = TaskNotificationService()

    // MARK: - Category & Action Identifiers

    static let categoryIdentifier = "TASK_REMINDER"
    static let completeActionIdentifier = "TASK_COMPLETE"
    static let snoozeActionIdentifier = "TASK_SNOOZE"

    private let center = UNUserNotificationCenter.current()
    private var hasRegisteredCategories = false

    private init() {}

    // MARK: - Permission

    /// Requests notification permission if not yet determined.
    /// Call this when the first task with an alert_time is created.
    func requestPermissionIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    registerCategories()
                    // Permission just granted — register for APNs so the backend
                    // can deliver proactive routine pushes (#830).
                    await MainActor.run { AppDelegate.registerForRemoteNotificationsIfAuthorized() }
                }
                return granted
            } catch {
                print("[TaskNotif] Permission request failed: \(error.localizedDescription)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Category Registration

    /// Registers the "TASK_REMINDER" category with "Mark Complete" and "Snooze" actions.
    func registerCategories() {
        guard !hasRegisteredCategories else { return }

        let completeAction = UNNotificationAction(
            identifier: Self.completeActionIdentifier,
            title: "Mark Complete",
            options: [.destructive]
        )

        let snoozeAction = UNNotificationAction(
            identifier: Self.snoozeActionIdentifier,
            title: "Snooze 15 min",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [completeAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
        hasRegisteredCategories = true
    }

    // MARK: - Schedule

    /// Schedules a local notification for a task's alert_time using UNCalendarNotificationTrigger.
    /// If the task already has a scheduled notification, it is replaced.
    func scheduleNotification(for task: TaskEvent) async {
        guard let alertTime = task.alertTime else { return }
        guard alertTime > Date() else { return }

        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        registerCategories()

        // Remove any existing notification for this task
        let identifier = notificationIdentifier(for: task.id)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = task.isEvent ? "Upcoming Event" : "Task Reminder"
        content.body = task.title
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["taskId": task.id.uuidString]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: alertTime
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            print("[TaskNotif] Scheduled notification for '\(task.title)' at \(alertTime)")
        } catch {
            print("[TaskNotif] Failed to schedule: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancel

    /// Removes the pending notification for a specific task.
    func cancelNotification(for taskId: UUID) {
        let identifier = notificationIdentifier(for: taskId)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Removes all task reminder notifications.
    func cancelAllTaskNotifications() {
        center.removeAllPendingNotificationRequests()
    }

    // MARK: - Reschedule After Sync

    /// After a backend sync pull, reschedule notifications for all tasks that have an alert_time.
    func rescheduleAll(tasks: [TaskEvent]) async {
        // Get current pending notifications to avoid unnecessary work
        let pending = await center.pendingNotificationRequests()
        let pendingIds = Set(pending.map(\.identifier))

        for task in tasks {
            guard let alertTime = task.alertTime, alertTime > Date() else {
                // If no alert time or it's past, cancel any existing notification
                let id = notificationIdentifier(for: task.id)
                if pendingIds.contains(id) {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                }
                continue
            }

            // Skip completed tasks
            guard task.status != "completed" else {
                cancelNotification(for: task.id)
                continue
            }

            await scheduleNotification(for: task)
        }
    }

    // MARK: - Snooze

    /// Snoozes a task notification by 15 minutes from now.
    func snoozeNotification(taskId: UUID, taskTitle: String) async {
        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        let identifier = notificationIdentifier(for: taskId)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let content = UNMutableNotificationContent()
        content.title = "Task Reminder (Snoozed)"
        content.body = taskTitle
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["taskId": taskId.uuidString]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            print("[TaskNotif] Snoozed notification for task \(taskId) by 15 min")
        } catch {
            print("[TaskNotif] Failed to snooze: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func notificationIdentifier(for taskId: UUID) -> String {
        "task-reminder-\(taskId.uuidString)"
    }
}
