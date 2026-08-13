import Foundation
import SwiftData
import UserNotifications

/// Handles notification action responses (Mark Complete, Snooze) from the task reminder category.
/// Set as UNUserNotificationCenterDelegate in the app lifecycle.
final class TaskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let modelContextProvider: @Sendable () -> ModelContext?
    private let taskSyncServiceProvider: @Sendable () -> TaskSyncServiceProtocol?

    init(
        modelContextProvider: @escaping @Sendable () -> ModelContext?,
        taskSyncServiceProvider: @escaping @Sendable () -> TaskSyncServiceProtocol?
    ) {
        self.modelContextProvider = modelContextProvider
        self.taskSyncServiceProvider = taskSyncServiceProvider
    }

    // Show notifications while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if DailyBriefNotificationRouting.isBriefNotification(notification.request.content.userInfo) {
            await DailyBriefNotificationLifecycle.removeOlderDeliveredBriefs(center: center)
        }
        return [.banner, .sound, .list]
    }

    // Handle notification action taps
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let deepLink = DailyBriefNotificationRouting.deepLink(from: userInfo) {
            await MainActor.run {
                AppDelegate.routeOpenedURL(deepLink)
            }
            return
        }

        guard let taskIdString = userInfo["taskId"] as? String,
              let taskId = UUID(uuidString: taskIdString) else { return }

        switch response.actionIdentifier {
        case TaskNotificationService.completeActionIdentifier:
            await handleComplete(taskId: taskId)

        case TaskNotificationService.snoozeActionIdentifier:
            await handleSnooze(taskId: taskId)

        case UNNotificationDefaultActionIdentifier:
            // User tapped notification body — no special action needed, app opens
            break

        default:
            break
        }
    }

    // MARK: - Action Handlers

    @MainActor
    private func handleComplete(taskId: UUID) async {
        guard let context = modelContextProvider(),
              let syncService = taskSyncServiceProvider() else { return }

        let descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.id == taskId }
        )
        guard let task = try? context.fetch(descriptor).first else { return }

        do {
            try await syncService.updateTaskStatus(task, to: .completed, modelContext: context)
            TaskNotificationService.shared.cancelNotification(for: taskId)
        } catch {
            print("[TaskNotifDelegate] Complete failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleSnooze(taskId: UUID) async {
        guard let context = modelContextProvider() else { return }

        let descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.id == taskId }
        )
        guard let task = try? context.fetch(descriptor).first else { return }

        await TaskNotificationService.shared.snoozeNotification(
            taskId: taskId,
            taskTitle: task.title
        )
    }
}

/// Remote Daily Brief notifications are doorways into the same explicit in-app playback flow.
/// Payload prose is intentionally ignored: a stale notification always resolves forward by asking
/// the app to fetch the newest canonical artifact from Today before it scrolls or speaks.
enum DailyBriefNotificationRouting {
    static let notificationThread = "rem-daily-brief"

    static func isBriefNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = userInfo["type"] as? String else { return false }
        return type == "daily_brief" || type == "checkin"
    }

    static func deepLink(from userInfo: [AnyHashable: Any]) -> URL? {
        guard isBriefNotification(userInfo),
              let accountID = userInfo["accountId"] as? String,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // Never trust payload prose or a legacy URL. The account identity is the only retained
        // notification claim; the app resolves forward to that account's newest canonical brief.
        return LatestBriefDeepLink.listenURL(accountID: accountID)
    }
}

enum DailyBriefNotificationLifecycle {
    /// Remove previously delivered Daily Brief notifications before presenting a newer one. APNs'
    /// collapse id coalesces pending delivery; this handles notifications already in Notification
    /// Center while the app is active. Taps still resolve forward if iOS preserves an older alert.
    static func removeOlderDeliveredBriefs(center: UNUserNotificationCenter) async {
        let delivered = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
        let identifiers = delivered.compactMap { notification -> String? in
            guard notification.request.content.threadIdentifier
                    == DailyBriefNotificationRouting.notificationThread else { return nil }
            return notification.request.identifier
        }
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
