import Foundation
import SwiftUI
import SwiftData
import Combine

public enum TaskType: String, CaseIterable {
    case task = "New Task"
    case event = "New Event"
}

@MainActor
class TaskEventViewModel: ObservableObject {
    // MARK: - Published State

    @Published var taskType: TaskType = .task
    @Published var title: String = ""
    @Published var category: String = "Personal"
    @Published var startDate: Date?
    @Published var endDate: Date?
    @Published var duration: TimeInterval?
    @Published var alertTime: Date?
    @Published var repeatFrequency: String?
    @Published var notes: String = ""
    /// The USER's half of the co-authored description (backend migration 120) — "what I
    /// know now" about this task, the text every agent run reads before it starts. Bound
    /// to an editor; Rem's half is `agentContext` and is never written from here.
    @Published var taskDescription: String = ""
    /// REM's half, read-only. Nil/empty until a run has recorded something.
    @Published var agentContext: String?
    /// The RAW `taskDescription` this view loaded, before it was flattened to "" for the
    /// editor. Kept because nil and "" are different facts on the wire: nil means the task
    /// has no description (send nothing), "" means the user ERASED one (send the clear).
    /// Without the distinction an erase is a no-op and the old text returns on next pull.
    private var loadedDescription: String?
    @Published var isBusy: Bool = false
    @Published var selectedCalendarID: String?
    @Published var calendarColor: Color = DesignTokens.Color.labelSecondary
    @Published var availableCalendars: [CalendarInfo] = []
    @Published var isAnyTime: Bool = false
    @Published var hasChanges: Bool = false
    /// The List this task is filed into (mirrors `task.listID`). Drives the list chip's
    /// label and is the local source of truth the chip reads; `assignToList` keeps it,
    /// the SwiftData task, and the backend in sync.
    @Published var selectedListID: UUID?
    @Published var showDeleteConfirmation: Bool = false
    @Published var actionErrorMessage: String?
    @Published var eventAccess: CalendarEventAccess?

    // MARK: - Private State

    private var originalState: (title: String, notes: String, taskDescription: String, startDate: Date?, endDate: Date?, duration: TimeInterval?, alertTime: Date?, repeatFrequency: String?, isAnyTime: Bool, selectedCalendarID: String?)?
    private var cancellables = Set<AnyCancellable>()
    private var saveDebounceTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let modelContext: ModelContext
    let task: TaskEvent?
    private let calendarService: CalendarSyncService?
    private let taskApiService: (any TaskApiServiceProtocol)?
    private let taskSyncService: TaskSyncServiceProtocol?
    /// Backend client for filing a task into a List (`PATCH /tasks/:id` with `list_id`).
    /// Parameterless — it auths via the shared `AuthenticatedHttpClient`. Lazy so previews
    /// and tasks that never touch the list chip don't build it.
    private lazy var organizationApiService = OrganizationApiService()

    var onSave: ((TaskEvent) -> Void)?
    var onDelete: (() -> Void)?

    // MARK: - Computed

    var isNewTask: Bool { task == nil }
    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canDeleteTask: Bool {
        guard let task else { return false }
        guard task.isEvent else { return true }
        guard task.calendarEventID != nil else { return true }
        guard let eventAccess else { return true }
        return eventAccess.canDelete || eventAccess.allowsLocalCleanup
    }
    var canEditTask: Bool {
        guard let task else { return true }
        guard task.isEvent else { return true }
        guard task.calendarEventID != nil else { return task.isCalendarOnlyMirror != true }
        return eventAccess?.canEdit ?? true
    }
    var isReadOnlyCalendarEvent: Bool {
        guard let task else { return false }
        return task.isEvent && !canEditTask
    }
    var readOnlyCalendarMessage: String? {
        guard isReadOnlyCalendarEvent else { return nil }
        return eventAccess?.failureReason ?? "This event belongs to a calendar you can view but not edit."
    }
    /// A real app-side task that already owns a backend row keyed by `task.id` (so its
    /// Activity log + agent runs work directly). Pure calendar mirrors and read-only
    /// calendar events are NOT real app tasks — they have no backend `tasks` row of
    /// their own, so they reach Activity only after opting in (see `workBackingTaskID`).
    private var isRealAppTask: Bool {
        guard let task else { return false }
        if isReadOnlyCalendarEvent { return false }
        if task.isCalendarOnlyMirror == true { return false }
        return true
    }

    /// The backend task id the Activity surface (comments + agent-run) should target,
    /// or `nil` when there is none. A real app task uses its own id; an event that has
    /// been opted into being worked uses its backing task id (`workBackingTaskID`,
    /// backend migration 024). `nil` means "no Activity" — used to gate the surface so
    /// an un-worked calendar event never hits `/tasks/:id/comments` and 404s.
    var activityTaskId: String? {
        if let backing = task?.workBackingTaskID { return backing.uuidString }
        return isRealAppTask ? task?.id.uuidString : nil
    }

    /// Whether the shared Activity surface (log + composer + Run now) should show.
    /// True for real app tasks and for events that have been opted into being worked.
    /// (#868 hid this for read-only / mirror events to avoid a "Task not found" error;
    /// now an opted-in event shows it via its backing while an un-worked one stays off.)
    var supportsActivity: Bool { activityTaskId != nil }

    /// Whether this event can be (lazily) worked: an event that isn't yet a real app
    /// task and hasn't been opted into being worked. Requires a `calendarEventID` (the
    /// idempotency key for its backing). Read-only events qualify too — working an event
    /// is app-side only and never mutates the underlying calendar. #875 drops the
    /// explicit "Let Rem work this" card; this now just gates whether the event detail
    /// presents the Activity surface directly and creates the backing lazily.
    var canOptEventIntoWork: Bool {
        guard let task, task.isEvent, !isRealAppTask else { return false }
        guard task.workBackingTaskID == nil else { return false }
        return task.calendarEventID != nil
    }

    /// Whether the event/task detail renders the shared Activity surface (log + Run now
    /// + composer). True for real app tasks and already-worked events
    /// (`supportsActivity`), and now ALSO for an un-worked but workable calendar event
    /// (`canOptEventIntoWork`): #875 drops the "Let Rem work this" opt-in card so the
    /// event detail looks/behaves like a task detail. #872's backing task is still the
    /// mechanism, but created lazily on first interaction (Run now / reply / open chat)
    /// via `ensureWorkBacking`, never behind an explicit opt-in tap.
    var showsActivitySurface: Bool { supportsActivity || canOptEventIntoWork }
    var requiresRecurringDeleteConfirmation: Bool {
        (task?.isEvent == true) && (eventAccess?.isRecurring == true)
    }

    /// Whether the List-assignment chip should appear. Filing into a List is a
    /// task-only concept and PATCHes the task's own backend row, so it shows for a
    /// real, saved app task — not for events (read-only or otherwise), pure calendar
    /// mirrors, or the unsaved create form (which has no `/tasks/:id` row yet).
    var canAssignList: Bool {
        guard let task else { return false }
        return !task.isEvent && task.isCalendarOnlyMirror != true
    }

    var canSaveEvent: Bool {
        guard taskType == .event else { return canSave }
        guard isNewTask else { return canSave }
        return canSave && selectedCalendarID != nil
    }

    var formattedDuration: String {
        guard let duration else { return "None" }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    // MARK: - Init

    init(
        modelContext: ModelContext,
        task: TaskEvent? = nil,
        calendarService: CalendarSyncService? = nil,
        taskApiService: (any TaskApiServiceProtocol)? = nil,
        taskSyncService: TaskSyncServiceProtocol? = nil
    ) {
        self.modelContext = modelContext
        self.task = task
        self.calendarService = calendarService
        self.taskApiService = taskApiService
        self.taskSyncService = taskSyncService

        if let task {
            populateFromTask(task)
        }

        setupChangeTracking()
    }

    // MARK: - Collaboration

    /// Commit a status proposed in the task collaboration thread (CONTRACT §4 —
    /// accepting a proposal is a separate write from the comment that proposed it).
    /// Mirrors the status onto the local SwiftData task and PATCHes the backend so
    /// the cloud agent and other devices see the same canonical state.
    /// `backendStatus` is already in backend form ("pending" | "in_progress" | "completed").
    func commitCollaborationStatus(_ backendStatus: String) async {
        guard let task else { return }
        task.status = backendStatus
        task.updatedAt = Date()
        try? modelContext.save()

        // PATCH the backend row that actually owns this Activity thread: a real app task
        // uses its own id; an opted-into-work event uses its backing task id. A pure
        // mirror with no backing has no backend row to update, so we stop at local.
        let backendId: String?
        if let backing = task.workBackingTaskID {
            backendId = backing.uuidString
        } else if task.isCalendarOnlyMirror != true {
            backendId = task.id.uuidString
        } else {
            backendId = nil
        }
        guard let backendId, let taskApiService else { return }
        do {
            _ = try await taskApiService.updateTask(
                id: backendId,
                title: nil,
                priority: nil,
                status: backendStatus,
                startDate: nil,
                endDate: nil,
                durationMinutes: nil,
                alertTime: nil,
                repeatFrequency: nil
            )
        } catch {
            actionErrorMessage = "Couldn't update status: \(error.localizedDescription)"
        }
    }

    /// Opt this calendar event into being worked: find-or-create its backend backing
    /// task (idempotent on `calendarEventID`, backend migration 024), persist the
    /// returned id on the local event so the Activity surface targets it now and across
    /// reopens, and return the activity task id. Returns the existing id immediately if
    /// already opted in. On failure, surfaces an inline error and returns `nil` so the
    /// caller can keep the un-worked state rather than dead-end (CONTRACT §8).
    func ensureWorkBacking() async -> String? {
        guard let task else { return nil }
        if let backing = task.workBackingTaskID { return backing.uuidString }
        guard let calendarEventID = task.calendarEventID else { return nil }
        guard let taskApiService else { return nil }
        do {
            let response = try await taskApiService.ensureEventBacking(
                calendarEventID: calendarEventID,
                title: task.title,
                startDate: task.startDate,
                durationMinutes: task.duration.map { Int($0 / 60) },
                listID: task.listID?.uuidString
            )
            let backingID = UUID(uuidString: response.id) ?? task.id
            task.workBackingTaskID = backingID
            task.updatedAt = Date()
            try? modelContext.save()
            return backingID.uuidString
        } catch {
            actionErrorMessage = "Rem couldn't start working this event: \(error.localizedDescription)"
            return nil
        }
    }

    /// Apply the backend-stamped stable session key (`rem-task-<taskId>`, #971) to the
    /// local SwiftData task **immediately** after a cloud run, so "Open conversation"
    /// resolves to the SAME gateway session the backend ran against — instead of the
    /// pre-run `task-<slug>` fallback until the next full sync (which split the
    /// conversation across two sessions). `taskId` is the Activity target (a real app
    /// task's own id, or an event's backing task id), matching how the backend keyed the
    /// stamp. We fetch by id so this works whether or not it's the hosted `task`; if no
    /// local row matches (e.g. an event backing that isn't mirrored locally), we fall
    /// back to the hosted task when its id matches, otherwise no-op — the next sync
    /// still stamps it. Idempotent: re-running writes the same stable key.
    func applyStampedSessionKey(taskId: String, sessionKey: String) {
        guard !sessionKey.isEmpty, let uuid = UUID(uuidString: taskId) else { return }
        let target: TaskEvent?
        if let task, task.id == uuid {
            target = task
        } else {
            let descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == uuid })
            target = try? modelContext.fetch(descriptor).first
        }
        guard let target, target.sessionKey != sessionKey else { return }
        target.sessionKey = sessionKey
        target.updatedAt = Date()
        try? modelContext.save()
    }

    private func populateFromTask(_ task: TaskEvent) {
        taskType = task.isEvent ? .event : .task
        title = task.title
        category = task.category
        startDate = task.startDate
        endDate = task.endDate
        duration = task.duration
        alertTime = task.alertTime
        repeatFrequency = task.repeatFrequency
        notes = task.notes ?? ""
        loadedDescription = task.taskDescription
        taskDescription = task.taskDescription ?? ""
        agentContext = task.agentContext
        isBusy = task.isBusy
        isAnyTime = task.isAnyTime
        selectedCalendarID = nil
        selectedListID = task.listID

        originalState = (title, notes, taskDescription, startDate, endDate, duration, alertTime, repeatFrequency, isAnyTime, selectedCalendarID)
    }

    private func setupChangeTracking() {
        Publishers.CombineLatest4(
            $title, $notes, $startDate, $endDate
        )
        .dropFirst()
        .sink { [weak self] _ in self?.updateHasChanges() }
        .store(in: &cancellables)

        $taskDescription
            .dropFirst()
            .sink { [weak self] _ in self?.updateHasChanges() }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            $duration, $alertTime, $repeatFrequency
        )
        .dropFirst()
        .sink { [weak self] _ in self?.updateHasChanges() }
        .store(in: &cancellables)

        $isAnyTime
            .dropFirst()
            .sink { [weak self] _ in self?.updateHasChanges() }
            .store(in: &cancellables)
    }

    private func updateHasChanges() {
        guard let original = originalState else {
            hasChanges = true
            return
        }
        hasChanges = title != original.title ||
            notes != original.notes ||
            taskDescription != original.taskDescription ||
            startDate != original.startDate ||
            endDate != original.endDate ||
            duration != original.duration ||
            alertTime != original.alertTime ||
            repeatFrequency != original.repeatFrequency ||
            isAnyTime != original.isAnyTime ||
            selectedCalendarID != original.selectedCalendarID
    }

    // MARK: - Auto-save (edit mode only)

    func debouncedSave() {
        guard task != nil else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard !Task.isCancelled else { return }
            _ = await save()
        }
    }

    // MARK: - Actions

    func save() async -> TaskEvent? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let isEvent = taskType == .event
        let now = Date()

        // Calculate end date from start + duration for events
        var resolvedEndDate = endDate
        if isEvent, let start = startDate, let dur = duration, endDate == nil {
            resolvedEndDate = start.addingTimeInterval(dur)
        }

        if let existingTask = task {
            if existingTask.isEvent, !canEditTask {
                actionErrorMessage = readOnlyCalendarMessage ?? "This event can't be edited from Rem."
                return nil
            }

            // Update existing
            existingTask.title = trimmedTitle
            existingTask.isEvent = isEvent
            existingTask.startDate = startDate
            existingTask.endDate = resolvedEndDate
            existingTask.duration = duration
            existingTask.alertTime = alertTime
            existingTask.repeatFrequency = repeatFrequency
            existingTask.notes = notes.isEmpty ? nil : notes
            // Only the user's half is written locally. `agentContext` is never assigned
            // here — the merge lives on the backend, and a client that wrote both halves
            // would be the clobber this design exists to prevent.
            //
            // "" and nil are DIFFERENT and both have to survive to the wire. Collapsing an
            // erased description to nil made the API layer omit the key, the backend read
            // the omission as "not edited", and the deleted text reappeared on the next
            // pull. Keep "" when the task actually HAD a description, so the clear
            // propagates; keep nil when it never did, so an untouched task never sends a
            // clear that could wipe text written on another device.
            existingTask.taskDescription = taskDescription.isEmpty
                ? (loadedDescription == nil ? nil : "")
                : taskDescription
            loadedDescription = existingTask.taskDescription
            existingTask.isBusy = isBusy
            existingTask.isAnyTime = isAnyTime
            existingTask.updatedAt = now

            try? modelContext.save()

            // Push to backend
            if existingTask.isCalendarOnlyMirror != true {
                try? await taskSyncService?.syncTaskToBackendImmediately(existingTask)
            }

            // Sync calendar if event
            if isEvent {
                do {
                    try await calendarService?.updateEventInCalendar(task: existingTask)
                    await loadEventAccess()
                } catch {
                    actionErrorMessage = error.localizedDescription
                }
            }

            if isEvent {
                TelemetryService.shared.track(
                    eventName: TelemetryEvent.eventUpdated,
                    properties: [
                        "source": "manual",
                        "type": "event",
                    ]
                )
            }

            onSave?(existingTask)
            hasChanges = false
            return existingTask
        } else {
            // Create new
            let newTask = TaskEvent(
                title: trimmedTitle,
                category: category,
                startDate: startDate,
                endDate: resolvedEndDate,
                duration: duration,
                alertTime: alertTime,
                repeatFrequency: repeatFrequency,
                notes: notes.isEmpty ? nil : notes,
                // A description typed in the create sheet has to reach the new task —
                // it was being constructed and dropped here, and `POST /tasks` has
                // accepted the field all along.
                taskDescription: taskDescription.isEmpty ? nil : taskDescription,
                isEvent: isEvent,
                isBusy: isBusy,
                isAnyTime: isAnyTime,
                priority: .medium,
                status: startDate != nil ? .scheduled : .todo
            )

            modelContext.insert(newTask)
            try? modelContext.save()

            // Push to backend
            _ = try? await taskSyncService?.syncTaskCreateToBackendImmediately(newTask)

            // Sync to calendar if event
            if isEvent, newTask.calendarEventID == nil {
                if let eventID = try? await calendarService?.saveEventToCalendar(task: newTask) {
                    newTask.calendarEventID = eventID
                    try? modelContext.save()
                }
            }

            TelemetryService.shared.track(
                eventName: isEvent ? TelemetryEvent.eventCreated : TelemetryEvent.taskCreated,
                properties: [
                    "source": "manual",
                    "type": isEvent ? "event" : "task",
                    "has_due_date": startDate != nil,
                    "has_alert": alertTime != nil,
                    "has_repeat": repeatFrequency != nil,
                ]
            )

            onSave?(newTask)
            hasChanges = false
            return newTask
        }
    }

    func deleteTask(scope: CalendarDeleteScope = .thisEvent) async -> Bool {
        guard let task else { return false }

        let isEvent = task.isEvent

        // Delete from calendar if event
        var deleteResult = CalendarDeleteResult(deleted: true, eventID: task.calendarEventID, title: task.title)
        if isEvent {
            if let calendarEventID = task.calendarEventID {
                deleteResult = await calendarService?.deleteEventFromCalendar(calendarEventID: calendarEventID, scope: scope)
                    ?? CalendarDeleteResult(deleted: false, eventID: calendarEventID, title: task.title, failureReason: .unknown, message: "Calendar service unavailable.")
            } else if task.isCalendarOnlyMirror == true {
                deleteResult = CalendarDeleteResult(
                    deleted: false,
                    eventID: nil,
                    title: task.title,
                    failureReason: .eventNotFound,
                    message: "This calendar event is no longer available."
                )
            }
        }

        guard deleteResult.deleted || deleteResult.failureReason == .eventNotFound else {
            actionErrorMessage = deleteResult.message ?? "This event can't be deleted from Rem."
            return false
        }

        // Delete from backend
        if task.isCalendarOnlyMirror != true {
            if let apiService = taskApiService {
                do {
                    try await apiService.deleteTask(id: task.id.uuidString)
                    if let taskSyncService,
                       await taskSyncService.recordConfirmedDelete(for: task.id) == false {
                        actionErrorMessage = "Rem couldn't save this deletion locally. The task was kept on this device."
                        return false
                    }
                } catch {
                    guard await taskSyncService?.queueOperation(operationType: "delete", taskId: task.id, taskData: nil) == true else {
                        actionErrorMessage = "Rem couldn't save this deletion for retry. The task was kept on this device."
                        return false
                    }
                }
            } else if await taskSyncService?.queueOperation(
                operationType: "delete", taskId: task.id, taskData: nil
            ) != true {
                actionErrorMessage = "Rem couldn't save this deletion for retry. The task was kept on this device."
                return false
            }
        }

        TaskNotificationService.shared.cancelNotification(for: task.id)
        modelContext.delete(task)
        try? modelContext.save()

        TelemetryService.shared.track(
            eventName: isEvent ? TelemetryEvent.eventDeleted : TelemetryEvent.taskDeleted,
            properties: [
                "source": "manual",
            ]
        )

        onDelete?()
        return true
    }

    func revertChanges() {
        guard let original = originalState else { return }
        title = original.title
        notes = original.notes
        taskDescription = original.taskDescription
        startDate = original.startDate
        endDate = original.endDate
        duration = original.duration
        alertTime = original.alertTime
        repeatFrequency = original.repeatFrequency
        isAnyTime = original.isAnyTime
        selectedCalendarID = original.selectedCalendarID
        hasChanges = false
    }

    /// File this task into a List (or unfile it, when `listID` is nil). Source of truth
    /// is the backend `tasks.list_id`; we update the local SwiftData task + `selectedListID`
    /// optimistically so the chip reflects the choice immediately, then PATCH the backend
    /// (`OrganizationApiService.assignTask`). On failure we surface an inline error — the
    /// next sync reconciles the local cache back to the server's truth.
    func assignToList(_ listID: UUID?) async {
        guard let task, canAssignList else { return }
        guard listID != task.listID else { return }

        selectedListID = listID
        task.listID = listID
        task.updatedAt = Date()
        try? modelContext.save()

        do {
            try await organizationApiService.assignTask(
                taskID: task.id.uuidString,
                toListID: listID?.uuidString
            )
        } catch {
            actionErrorMessage = "Couldn't update the list: \(error.localizedDescription)"
        }
    }

    func loadCalendars() async {
        guard let calendarService else { return }
        availableCalendars = await calendarService.getAvailableCalendars()

        if selectedCalendarID == nil {
            selectedCalendarID = await calendarService.getDefaultCalendarIdentifier()
        }

        if let id = selectedCalendarID,
           let info = availableCalendars.first(where: { $0.id == id }) {
            calendarColor = info.color
        }
    }

    func loadEventAccess() async {
        guard let task, task.isEvent, let eventID = task.calendarEventID else {
            eventAccess = nil
            return
        }
        eventAccess = await calendarService?.getEventAccess(forEvent: eventID)
    }

    // MARK: - Duration Helpers

    func setDuration(minutes: Int) {
        duration = TimeInterval(minutes * 60)
        if let start = startDate {
            endDate = start.addingTimeInterval(duration!)
        }
    }

    func updateEndDateFromDuration() {
        guard let start = startDate, let dur = duration else { return }
        endDate = start.addingTimeInterval(dur)
    }

    func updateDurationFromEndDate() {
        guard let start = startDate, let end = endDate else { return }
        let interval = end.timeIntervalSince(start)
        if interval > 0 { duration = interval }
    }
}
