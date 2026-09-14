import Foundation
import SwiftUI
import SwiftData
import Combine

/// ViewModel for InboxView — manages unscheduled task filtering and calendar info.
@MainActor
public class InboxViewModel: ObservableObject {
    // MARK: - Published State

    @Published var calendarInfoCache: [String: CalendarInfo] = [:]

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let calendarService: CalendarSyncService?
    private let taskApiService: TaskApiServiceProtocol?
    private let taskSyncService: TaskSyncServiceProtocol?
    let taskStore: TaskStore

    // MARK: - Initialization

    public init(
        modelContext: ModelContext,
        taskStore: TaskStore,
        calendarService: CalendarSyncService? = nil,
        taskApiService: TaskApiServiceProtocol? = nil,
        taskSyncService: TaskSyncServiceProtocol? = nil
    ) {
        self.modelContext = modelContext
        self.taskStore = taskStore
        self.calendarService = calendarService
        self.taskApiService = taskApiService
        self.taskSyncService = taskSyncService
    }

    // MARK: - Computed Properties

    var unscheduledTasks: [TaskEvent] {
        taskStore.unscheduledTasks
    }

    // MARK: - Calendar Info

    func loadCalendarInfo(for tasks: [TaskEvent]) async {
        guard let syncService = calendarService else { return }

        var newCache: [String: CalendarInfo] = [:]

        for task in tasks where task.isEvent {
            var eventID = task.calendarEventID

            if eventID == nil, let startDate = task.startDate {
                if let foundEventID = await syncService.findEventID(title: task.title, startDate: startDate) {
                    eventID = foundEventID
                    task.calendarEventID = foundEventID
                }
            }

            if let eventID,
               let calendarInfo = await syncService.getCalendarInfo(forEvent: eventID) {
                newCache[eventID] = calendarInfo
            }
        }

        calendarInfoCache = newCache
    }

    func getCalendarInfo(for task: TaskEvent) -> CalendarInfo? {
        guard let eventID = task.calendarEventID else { return nil }
        return calendarInfoCache[eventID]
    }

    // MARK: - Pull-to-Refresh

    @Published var isRefreshing: Bool = false

    func pullToRefresh() async {
        isRefreshing = true
        await taskStore.sync()
        isRefreshing = false
    }

    // MARK: - Task Actions

    func completeTask(_ task: TaskEvent) async {
        do {
            try await taskSyncService?.updateTaskStatus(task, to: .completed, modelContext: modelContext)
            TaskNotificationService.shared.cancelNotification(for: task.id)
            TelemetryService.shared.track(
                eventName: TelemetryEvent.taskCompleted,
                properties: [
                    "source": "manual",
                    "type": task.isEvent ? "event" : "task",
                ]
            )
        } catch {
            print("[Inbox] Failed to complete task: \(error.localizedDescription)")
        }
    }

    func scheduleTask(_ task: TaskEvent, at date: Date) async {
        task.startDate = date
        task.isAnyTime = false
        task.updatedAt = Date()
        try? modelContext.save()
        try? await taskSyncService?.syncTaskToBackendImmediately(task)
    }

    func snoozeTask(_ task: TaskEvent, minutes: Int = 15) async {
        let newAlertTime = Date().addingTimeInterval(TimeInterval(minutes * 60))
        task.alertTime = newAlertTime
        task.updatedAt = Date()
        try? modelContext.save()
        await TaskNotificationService.shared.snoozeNotification(
            taskId: task.id,
            taskTitle: task.title
        )
        try? await taskSyncService?.syncTaskToBackendImmediately(task)
    }

    func deleteTask(_ task: TaskEvent) async {
        if task.isEvent {
            let result: CalendarDeleteResult
            if let calendarEventID = task.calendarEventID {
                result = await calendarService?.deleteEventFromCalendar(calendarEventID: calendarEventID, scope: .thisEvent)
                    ?? CalendarDeleteResult(deleted: false, eventID: calendarEventID, title: task.title, failureReason: .unknown, message: "Calendar service unavailable.")
            } else if task.isCalendarOnlyMirror == true {
                result = CalendarDeleteResult(deleted: false, eventID: nil, title: task.title, failureReason: .eventNotFound, message: "This calendar event is no longer available.")
            } else {
                result = CalendarDeleteResult(deleted: true, eventID: nil, title: task.title)
            }

            guard result.deleted || result.failureReason == .eventNotFound else {
                print("[Inbox] Event delete blocked: \(result.message ?? "Unknown error")")
                return
            }
        }

        if task.isCalendarOnlyMirror != true {
            if let apiService = taskApiService {
                do {
                    try await apiService.deleteTask(id: task.id.uuidString)
                    if let taskSyncService,
                       await taskSyncService.recordConfirmedDelete(for: task.id) == false {
                        print("[Inbox] Could not persist confirmed delete cleanup; keeping task locally")
                        return
                    }
                } catch {
                    guard await taskSyncService?.queueOperation(operationType: "delete", taskId: task.id, taskData: nil) == true else {
                        print("[Inbox] Could not persist delete for retry; keeping task locally")
                        return
                    }
                    print("[Inbox] Backend delete failed: \(error.localizedDescription)")
                }
            } else if await taskSyncService?.queueOperation(
                operationType: "delete", taskId: task.id, taskData: nil
            ) != true {
                return
            }
        }
        TaskNotificationService.shared.cancelNotification(for: task.id)
        modelContext.delete(task)
        try? modelContext.save()
    }
}
