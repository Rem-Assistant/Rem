import Combine
import Foundation
import SwiftData

/// Real task sync service that pushes changes to the backend and processes offline queue.
class RemTaskSyncService: ObservableObject, TaskSyncServiceProtocol, ScopedSuggestionTaskSyncServiceProtocol {
    private enum DurabilityError: LocalizedError {
        case retryIntentNotPersisted

        var errorDescription: String? {
            "The task change could not be saved for retry."
        }
    }

    private struct PendingOperationSnapshot: Sendable {
        let id: UUID
        let operationType: String
        let taskId: UUID?
        let taskData: Data?
    }

    private let taskApiService: TaskApiServiceProtocol
    private let modelContext: ModelContext
    private let calendarService: RemCalendarService?
    private let notificationService: TaskNotificationService

    @MainActor @Published var isHydrating: Bool = false

    private var isSyncing = false
    private var syncingTaskIds = Set<UUID>()

    init(taskApiService: TaskApiServiceProtocol, modelContext: ModelContext, calendarService: RemCalendarService? = nil, notificationService: TaskNotificationService = .shared) {
        self.taskApiService = taskApiService
        self.modelContext = modelContext
        self.calendarService = calendarService
        self.notificationService = notificationService
    }

    // MARK: - Protocol Methods

    func queueOperation(operationType: String, taskId: UUID?, taskData: Data?) async -> Bool {
        await MainActor.run {
            let existing: [PendingTaskOperation]
            if let taskId {
                let descriptor = FetchDescriptor<PendingTaskOperation>(
                    predicate: #Predicate<PendingTaskOperation> { $0.taskId == taskId },
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                existing = (try? modelContext.fetch(descriptor)) ?? []
            } else {
                existing = []
            }

            // Delete is a sticky tombstone. A delayed/debounced update or an in-flight
            // create callback must never replace an already durable delete intent.
            if operationType != "delete",
               existing.contains(where: { $0.operationType == "delete" }) {
                do {
                    try modelContext.save()
                    return true
                } catch {
                    print("[TaskSync] Failed to preserve delete intent: \(error.localizedDescription)")
                    return false
                }
            }

            // Keep one durable intent per task. An update folds into an offline create;
            // a delete supersedes every older intent (including a POST whose response
            // was lost) and is retried idempotently by treating backend 404 as deleted.
            if operationType == "update",
               let pendingCreate = existing.first(where: { $0.operationType == "create" }) {
                pendingCreate.taskData = Self.foldingUpdateSnapshot(
                    taskData,
                    intoCreateSnapshot: pendingCreate.taskData
                )
                for operation in existing where operation.id != pendingCreate.id {
                    modelContext.delete(operation)
                }
                do {
                    try modelContext.save()
                    return true
                } catch {
                    print("[TaskSync] Failed to persist \(operationType) intent: \(error.localizedDescription)")
                    return false
                }
            }

            for operation in existing {
                modelContext.delete(operation)
            }
            let operation = PendingTaskOperation(
                operationType: operationType,
                taskId: taskId,
                taskData: taskData
            )
            modelContext.insert(operation)
            do {
                try modelContext.save()
                return true
            } catch {
                print("[TaskSync] Failed to persist \(operationType) intent: \(error.localizedDescription)")
                return false
            }
        }
    }

    func discardPendingOperations(for taskId: UUID) async -> Bool {
        await MainActor.run {
            let descriptor = FetchDescriptor<PendingTaskOperation>(
                predicate: #Predicate<PendingTaskOperation> { $0.taskId == taskId }
            )
            let operations = (try? modelContext.fetch(descriptor)) ?? []
            for operation in operations {
                modelContext.delete(operation)
            }
            if !operations.isEmpty {
                do {
                    try modelContext.save()
                } catch {
                    print("[TaskSync] Failed to discard stale task intents: \(error.localizedDescription)")
                    return false
                }
            }
            return true
        }
    }

    @MainActor
    func updateTaskStatus(_ task: TaskEvent, to status: TaskStatus, modelContext: ModelContext) async throws {
        task.statusEnum = status
        task.updatedAt = Date()
        try modelContext.save()

        // Push to backend immediately
        try await syncTaskToBackendImmediately(task)
    }

    func syncTaskToBackendImmediately(_ task: TaskEvent) async throws {
        try await syncTaskToBackendImmediately(task, includeListID: false)
    }

    func syncTaskToBackendImmediately(_ task: TaskEvent, includeListID: Bool) async throws {
        guard !syncingTaskIds.contains(task.id) else {
            let taskData = Self.encodeQueuedTaskSnapshot(task, includeListID: includeListID)
            guard await queueOperation(operationType: "update", taskId: task.id, taskData: taskData) else {
                throw DurabilityError.retryIntentNotPersisted
            }
            return
        }
        syncingTaskIds.insert(task.id)
        defer { syncingTaskIds.remove(task.id) }
        let supersededPendingWrites = await pendingWriteOperationSnapshots(for: task.id)

        do {
            let response = try await taskApiService.updateTask(
                id: task.id.uuidString,
                title: task.title,
                priority: task.priority,
                status: task.status,
                startDate: task.startDate,
                endDate: task.endDate,
                durationMinutes: task.duration.map { Int($0 / 60) },
                alertTime: task.alertTime,
                repeatFrequency: task.repeatFrequency,
                // The USER's half only (migration 120). The backend merges it under a row
                // lock, so pushing it can never overwrite the context a run recorded.
                description: task.taskDescription,
                listID: includeListID ? task.listID?.uuidString : nil,
                includeListID: includeListID,
                includeClearedFields: false
            )
            await removePendingOperationsStillMatching(supersededPendingWrites)

            // The PATCH that just succeeded WAS a user action, so the backend cleared `stale_at` as
            // part of the very same UPDATE (tasks.routes.ts folds the reset in). Mirror that one
            // backend-owned consequence straight back onto the live object. Without it, completing,
            // snoozing or rescheduling a stale task leaves the row dimmed and still wearing its
            // "Stale" pill until the next full pull — the user acts and nothing appears to happen.
            //
            // DELIBERATELY NARROW. Everything else in this response is this client's own write
            // echoing back, and re-applying it would clobber an edit made while the request was in
            // flight — which is why the response was discarded here in the first place. Only fields
            // the BACKEND owns and the client cannot compute belong in this block.
            task.staleAt = Self.parseBackendDate(response.staleAt)

            // Reschedule notification after update
            if task.alertTime != nil, task.status != "completed" {
                await notificationService.scheduleNotification(for: task)
            } else {
                notificationService.cancelNotification(for: task.id)
            }
        } catch {
            guard Self.isRetryableWriteError(error) else { throw error }
            let taskData = Self.encodeQueuedTaskSnapshot(task, includeListID: includeListID)
            guard await queueOperation(operationType: "update", taskId: task.id, taskData: taskData) else {
                throw DurabilityError.retryIntentNotPersisted
            }
        }
    }

    func ensureTaskUpdateIsDurable(_ task: TaskEvent) async -> Bool {
        do {
            try await syncTaskToBackendImmediately(task)
            return true
        } catch {
            return false
        }
    }

    func syncTaskCreateToBackendImmediately(_ task: TaskEvent) async throws -> TaskEventApiResponse? {
        let result = await persistTaskCreate(task)
        guard result.isDurable else { throw DurabilityError.retryIntentNotPersisted }
        return result.response
    }

    func ensureTaskCreateIsDurable(_ task: TaskEvent) async -> Bool {
        (await persistTaskCreate(task)).isDurable
    }

    /// Suggestion mutations never enter the account-agnostic offline queue. They execute with the
    /// immutable tap-time credentials; on failure the proposal remains visible and the stable task
    /// UUID makes a later same-account retry safe.
    func ensureSuggestionTaskCreateIsDurable(
        _ task: TaskEvent,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async -> Bool {
        guard !syncingTaskIds.contains(task.id),
              let scopedApi = taskApiService as? ScopedSuggestionTaskApiServiceProtocol
        else { return false }
        syncingTaskIds.insert(task.id)
        defer { syncingTaskIds.remove(task.id) }

        do {
            _ = try await scopedApi.saveTaskToBackend(
                id: task.id.uuidString,
                title: task.title,
                priority: task.priority,
                status: task.status,
                startDate: task.startDate,
                endDate: task.endDate,
                durationMinutes: task.duration.map { Int($0 / 60) },
                alertTime: task.alertTime,
                repeatFrequency: task.repeatFrequency,
                authority: authority
            )
            // POST may have returned the row committed before a lost acknowledgement. Reapply the
            // current immutable payload before reporting durability, matching offline replay.
            _ = try await scopedApi.updateTask(
                id: task.id.uuidString,
                title: task.title,
                priority: task.priority,
                status: task.status,
                startDate: task.startDate,
                endDate: task.endDate,
                durationMinutes: task.duration.map { Int($0 / 60) },
                alertTime: task.alertTime,
                repeatFrequency: task.repeatFrequency,
                authority: authority
            )
            if task.alertTime != nil {
                await notificationService.scheduleNotification(for: task)
            }
            return true
        } catch {
            return false
        }
    }

    func ensureSuggestionTaskUpdateIsDurable(
        _ task: TaskEvent,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async -> Bool {
        guard !syncingTaskIds.contains(task.id),
              let scopedApi = taskApiService as? ScopedSuggestionTaskApiServiceProtocol
        else { return false }
        syncingTaskIds.insert(task.id)
        defer { syncingTaskIds.remove(task.id) }

        do {
            _ = try await scopedApi.updateTask(
                id: task.id.uuidString,
                title: task.title,
                priority: task.priority,
                status: task.status,
                startDate: task.startDate,
                endDate: task.endDate,
                durationMinutes: task.duration.map { Int($0 / 60) },
                alertTime: task.alertTime,
                repeatFrequency: task.repeatFrequency,
                authority: authority
            )
            return true
        } catch {
            return false
        }
    }

    private func persistTaskCreate(_ task: TaskEvent) async -> (response: TaskEventApiResponse?, isDurable: Bool) {
        guard !syncingTaskIds.contains(task.id) else {
            let taskData = Self.encodeQueuedTaskSnapshot(task)
            let queued = await queueOperation(operationType: "create", taskId: task.id, taskData: taskData)
            return (nil, queued)
        }
        syncingTaskIds.insert(task.id)
        defer { syncingTaskIds.remove(task.id) }
        let supersededPendingWrites = await pendingWriteOperationSnapshots(for: task.id)

        do {
            let response: TaskEventApiResponse
            if task.isEvent {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let dateTime = task.startDate.map { isoFormatter.string(from: $0) } ?? ""
                let durationMinutes = task.duration.map { Int($0 / 60) } ?? 30
                response = try await taskApiService.saveEventToBackend(
                    id: task.id.uuidString,
                    title: task.title,
                    dateTime: dateTime,
                    durationMinutes: durationMinutes,
                    listID: task.listID?.uuidString
                )
            } else {
                response = try await taskApiService.saveTaskToBackend(
                    id: task.id.uuidString,
                    title: task.title,
                    priority: task.priority,
                    status: task.status,
                    startDate: task.startDate,
                    endDate: task.endDate,
                    durationMinutes: task.duration.map { Int($0 / 60) },
                    alertTime: task.alertTime,
                    repeatFrequency: task.repeatFrequency,
                    description: task.taskDescription,
                    listID: task.listID?.uuidString
                )
            }

            // Also sync to EventKit if it's a calendar event
            if task.isEvent, let calendarService {
                do {
                    let eventID = try await calendarService.saveEventToCalendar(task: task)
                    if let eventID {
                        await MainActor.run { task.calendarEventID = eventID }
                    }
                } catch {
                    print("[TaskSync] EventKit save failed: \(error.localizedDescription)")
                }
            }

            // Schedule local notification if task has an alert_time
            if task.alertTime != nil {
                await notificationService.scheduleNotification(for: task)
            }

            // The idempotent POST may return a row committed before a lost acknowledgement.
            // Reapply this exact local snapshot before retiring any older matching intent.
            _ = try await taskApiService.updateTask(
                id: task.id.uuidString,
                title: task.title,
                priority: task.priority,
                status: task.status,
                startDate: task.startDate,
                endDate: task.endDate,
                durationMinutes: task.duration.map { Int($0 / 60) },
                alertTime: task.alertTime,
                repeatFrequency: task.repeatFrequency,
                listID: task.listID?.uuidString,
                includeListID: true,
                includeClearedFields: true
            )

            // A direct create may be reconciling an older durable retry. Retire only
            // the exact snapshots that preceded this upload so a newer edit survives.
            await removePendingOperationsStillMatching(supersededPendingWrites)

            return (response, true)
        } catch {
            guard Self.isRetryableWriteError(error) else { return (nil, false) }
            let taskData = Self.encodeQueuedTaskSnapshot(task)
            let queued = await queueOperation(operationType: "create", taskId: task.id, taskData: taskData)
            return (nil, queued)
        }
    }

    // MARK: - Offline Queue Processing

    func processPendingOperations() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let operations: [PendingOperationSnapshot] = await MainActor.run {
            let descriptor = FetchDescriptor<PendingTaskOperation>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
            return ((try? modelContext.fetch(descriptor)) ?? []).map {
                PendingOperationSnapshot(
                    id: $0.id,
                    operationType: $0.operationType,
                    taskId: $0.taskId,
                    taskData: $0.taskData
                )
            }
        }

        for operation in operations {
            // Durable replay and immediate UI writes share one per-task serialization domain.
            // Register replay before its first suspension point so a newer edit queues behind it
            // instead of racing an older PATCH and being overwritten server-side.
            if let taskId = operation.taskId {
                guard !syncingTaskIds.contains(taskId) else { continue }
                syncingTaskIds.insert(taskId)
            }
            defer {
                if let taskId = operation.taskId {
                    syncingTaskIds.remove(taskId)
                }
            }
            guard await pendingOperationStillMatches(operation) else {
                continue
            }
            let success = await processOperation(operation)
            if success {
                await MainActor.run {
                    let operationID = operation.id
                    let descriptor = FetchDescriptor<PendingTaskOperation>(
                        predicate: #Predicate<PendingTaskOperation> { $0.id == operationID }
                    )
                    guard let current = try? modelContext.fetch(descriptor).first,
                          current.operationType == operation.operationType,
                          current.taskId == operation.taskId,
                          current.taskData == operation.taskData else {
                        return
                    }
                    modelContext.delete(current)
                    try? modelContext.save()
                }
            }
        }
    }

    private func pendingOperationStillMatches(_ operation: PendingOperationSnapshot) async -> Bool {
        await MainActor.run {
            let operationID = operation.id
            let descriptor = FetchDescriptor<PendingTaskOperation>(
                predicate: #Predicate<PendingTaskOperation> { $0.id == operationID }
            )
            guard let current = try? modelContext.fetch(descriptor).first else {
                return false
            }
            return current.operationType == operation.operationType
                && current.taskId == operation.taskId
                && current.taskData == operation.taskData
        }
    }

    private func pendingWriteOperationSnapshots(for taskId: UUID) async -> [PendingOperationSnapshot] {
        await MainActor.run {
            let descriptor = FetchDescriptor<PendingTaskOperation>(
                predicate: #Predicate<PendingTaskOperation> { $0.taskId == taskId }
            )
            return ((try? modelContext.fetch(descriptor)) ?? [])
                .filter { $0.operationType != "delete" }
                .map {
                    PendingOperationSnapshot(
                        id: $0.id,
                        operationType: $0.operationType,
                        taskId: $0.taskId,
                        taskData: $0.taskData
                    )
                }
        }
    }

    private func removePendingOperationsStillMatching(
        _ snapshots: [PendingOperationSnapshot]
    ) async {
        await MainActor.run {
            for snapshot in snapshots {
                let operationID = snapshot.id
                let descriptor = FetchDescriptor<PendingTaskOperation>(
                    predicate: #Predicate<PendingTaskOperation> { $0.id == operationID }
                )
                guard let current = try? modelContext.fetch(descriptor).first,
                      current.operationType == snapshot.operationType,
                      current.taskId == snapshot.taskId,
                      current.taskData == snapshot.taskData else {
                    continue
                }
                modelContext.delete(current)
            }
            try? modelContext.save()
        }
    }

    private func processOperation(_ operation: PendingOperationSnapshot) async -> Bool {
        switch operation.operationType {
        case "create":
            guard let taskData = operation.taskData,
                  let apiResponse = try? JSONDecoder().decode(TaskEventApiResponse.self, from: taskData) else {
                return true // Remove malformed operations
            }
            let listAssignment = await replayListAssignment(
                payload: taskData,
                decodedListID: apiResponse.listID,
                taskID: operation.taskId ?? UUID(uuidString: apiResponse.id)
            )
            do {
                let isoFmt = ISO8601DateFormatter()
                isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let isoPlain = ISO8601DateFormatter()
                isoPlain.formatOptions = [.withInternetDateTime]
                func parseDate(_ s: String?) -> Date? {
                    guard let s else { return nil }
                    return isoFmt.date(from: s) ?? isoPlain.date(from: s)
                }
                let taskID = operation.taskId?.uuidString ?? apiResponse.id
                if apiResponse.type == "calendar_event" {
                    _ = try await taskApiService.saveEventToBackend(
                        id: taskID,
                        title: apiResponse.title,
                        dateTime: apiResponse.startDate ?? "",
                        durationMinutes: apiResponse.durationMinutes ?? 30,
                        listID: listAssignment.listID
                    )
                } else {
                    _ = try await taskApiService.saveTaskToBackend(
                        id: taskID,
                        title: apiResponse.title,
                        priority: apiResponse.priority ?? "medium",
                        status: apiResponse.status ?? "pending",
                        startDate: parseDate(apiResponse.startDate),
                        endDate: parseDate(apiResponse.endDate),
                        durationMinutes: apiResponse.durationMinutes,
                        alertTime: parseDate(apiResponse.alertTime),
                        repeatFrequency: apiResponse.repeatFrequency,
                        description: apiResponse.descriptionUser,
                        listID: listAssignment.listID
                    )
                }
                // A client-owned UUID create is idempotent. After a lost acknowledgement the
                // backend can return the older committed row, so reapply the queued snapshot—including
                // its explicit List assignment—before the durable intent may be deleted.
                _ = try await taskApiService.updateTask(
                    id: taskID,
                    title: apiResponse.title,
                    priority: apiResponse.priority,
                    status: apiResponse.status,
                    startDate: parseDate(apiResponse.startDate),
                    endDate: parseDate(apiResponse.endDate),
                    durationMinutes: apiResponse.durationMinutes,
                    alertTime: parseDate(apiResponse.alertTime),
                    repeatFrequency: apiResponse.repeatFrequency,
                    description: apiResponse.descriptionUser,
                    listID: listAssignment.listID,
                    includeListID: listAssignment.includeInUpdate,
                    includeClearedFields: true
                )
                return true
            } catch {
                return false
            }

        case "update":
            guard let taskId = operation.taskId else { return true }
            guard let taskData = operation.taskData,
                  let apiResponse = try? JSONDecoder().decode(TaskEventApiResponse.self, from: taskData) else {
                return true
            }
            let listAssignment = await replayListAssignment(
                payload: taskData,
                decodedListID: apiResponse.listID,
                taskID: taskId
            )
            do {
                let isoFmt = ISO8601DateFormatter()
                isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let isoPlain = ISO8601DateFormatter()
                isoPlain.formatOptions = [.withInternetDateTime]
                func parseDate(_ s: String?) -> Date? {
                    guard let s else { return nil }
                    return isoFmt.date(from: s) ?? isoPlain.date(from: s)
                }
                _ = try await taskApiService.updateTask(
                    id: taskId.uuidString,
                    title: apiResponse.title,
                    priority: apiResponse.priority,
                    status: apiResponse.status,
                    startDate: parseDate(apiResponse.startDate),
                    endDate: parseDate(apiResponse.endDate),
                    durationMinutes: apiResponse.durationMinutes,
                    alertTime: parseDate(apiResponse.alertTime),
                    repeatFrequency: apiResponse.repeatFrequency,
                    description: apiResponse.descriptionUser,
                    listID: listAssignment.listID,
                    includeListID: listAssignment.includeInUpdate,
                    includeClearedFields: false
                )
                return true
            } catch {
                return false
            }

        case "delete":
            guard let taskId = operation.taskId else { return true }
            do {
                try await taskApiService.deleteTask(id: taskId.uuidString)
                return true
            } catch {
                return false
            }

        default:
            return true
        }
    }

    // MARK: - Full Sync (pull from backend)

    /// Queue snapshots encode `list_id`, including explicit JSON null for unfile, unless
    /// the initiating patch did not mutate organization. The private marker preserves an
    /// intentional omission across replay while old unmarked payloads keep legacy recovery.
    private static func encodeQueuedTaskSnapshot(
        _ task: TaskEvent,
        includeListID: Bool = true
    ) -> Data? {
        guard let encoded = try? JSONEncoder().encode(task.toApiResponse()),
              var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
            return nil
        }
        if includeListID {
            object["list_id"] = task.listID?.uuidString ?? NSNull()
        } else {
            object.removeValue(forKey: "list_id")
            object["rem_list_id_included"] = false
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    private static func payloadListAssignmentMode(_ payload: Data) -> Bool? {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return nil
        }
        if object["rem_list_id_included"] as? Bool == false { return false }
        if object.keys.contains("list_id") { return true }
        return nil
    }

    /// An unrelated update folded into a pending create owns the newer task fields, but not
    /// organization. Preserve the create's List assignment until a newer explicit move/unfile
    /// supplies its own `list_id`. Legacy unmarked creates remain unmarked so replay can recover
    /// their current local assignment.
    private static func foldingUpdateSnapshot(
        _ updatePayload: Data?,
        intoCreateSnapshot createPayload: Data?
    ) -> Data? {
        guard let updatePayload,
              payloadListAssignmentMode(updatePayload) != true,
              let createPayload,
              let createObject = (try? JSONSerialization.jsonObject(with: createPayload)) as? [String: Any],
              var updateObject = (try? JSONSerialization.jsonObject(with: updatePayload)) as? [String: Any]
        else { return updatePayload }

        switch payloadListAssignmentMode(createPayload) {
        case true:
            updateObject["list_id"] = createObject["list_id"] ?? NSNull()
            updateObject.removeValue(forKey: "rem_list_id_included")
        case false:
            updateObject.removeValue(forKey: "list_id")
            updateObject["rem_list_id_included"] = false
        case nil:
            updateObject.removeValue(forKey: "list_id")
            updateObject.removeValue(forKey: "rem_list_id_included")
        }
        return (try? JSONSerialization.data(withJSONObject: updateObject)) ?? updatePayload
    }

    /// A legacy payload without `list_id` must never become an implicit unfile PATCH.
    /// Recover the current local assignment when possible; otherwise omit list_id from
    /// the replayed update so the backend preserves its existing organization.
    private func replayListAssignment(
        payload: Data,
        decodedListID: String?,
        taskID: UUID?
    ) async -> (listID: String?, includeInUpdate: Bool) {
        if Self.payloadListAssignmentMode(payload) == false {
            return (nil, false)
        }
        if Self.payloadListAssignmentMode(payload) == true {
            return (decodedListID, true)
        }
        guard let taskID else { return (nil, false) }
        let localListID: UUID? = await MainActor.run {
            let descriptor = FetchDescriptor<TaskEvent>(
                predicate: #Predicate<TaskEvent> { $0.id == taskID }
            )
            return (try? modelContext.fetch(descriptor).first)?.listID
        }
        if let localListID {
            return (localListID.uuidString, true)
        }
        return (nil, false)
    }

    /// Backend ISO-8601, with and without fractional seconds (the CLAUDE.md gotcha). Shared so the
    /// write-ACK path parses timestamps exactly the way the pull path does.
    private static func parseBackendDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func isRetryableWriteError(_ error: any Error) -> Bool {
        guard case let RemApiError.requestFailed(statusCode, _) = error else {
            return true
        }
        // A PATCH 404 is retryable here: an offline create for the same UUID may still be
        // queued, and queueOperation folds this newer snapshot into that create. Validation
        // failures (400/422) and a deletion tombstone (410) can never succeed unchanged.
        return statusCode != 400 && statusCode != 410 && statusCode != 422
    }

    func syncFromBackend() async {
        await refreshFromBackend()
    }

    /// The same pull as `syncFromBackend()`, but it reports whether the pull actually
    /// completed. Read paths that answer a user's question use the result to say when
    /// they are serving a last-known snapshot instead of current data.
    @discardableResult
    func refreshFromBackend() async -> Bool {
        await MainActor.run { isHydrating = true }
        defer { Task { @MainActor in isHydrating = false } }

        // Process pending operations first (push before pull)
        await processPendingOperations()

        do {
            let remoteTasks = try await taskApiService.fetchTasks()
            let remoteDeletions = try await taskApiService.fetchTaskDeletions()
            // Backend UUID text is lowercase while `UUID.uuidString` is uppercase. Compare typed
            // UUID values throughout reconciliation so casing cannot resurrect a cross-device
            // deletion, duplicate an existing row, or leave a pending create/update misclassified.
            let remoteIds = Set(remoteTasks.compactMap { UUID(uuidString: $0.id) })
            let remoteDeletedIds = Set(remoteDeletions.compactMap { UUID(uuidString: $0.taskID) })
            // A create that still remains in the offline queue is local data awaiting upload,
            // not a server-side deletion. Preserve it during snapshot reconciliation. Once the
            // create succeeds, the operation is removed and the backend row (same UUID) becomes
            // authoritative like every other task. The remote-ID check also handles a lost HTTP
            // acknowledgement: if the POST committed but the response failed, its queued retry
            // gets a duplicate-ID error. Seeing that UUID converts the create to an update so
            // any edits folded into the queued payload are pushed without losing local state.
            let pendingIntents: (writes: Set<UUID>, deletes: Set<UUID>) = await MainActor.run {
                let descriptor = FetchDescriptor<PendingTaskOperation>()
                let operations = (try? modelContext.fetch(descriptor)) ?? []
                var writes = Set<UUID>()
                var deletes = Set<UUID>()
                var convertedAcknowledgedCreate = false

                for operation in operations {
                    guard let taskId = operation.taskId else { continue }
                    if remoteDeletedIds.contains(taskId) {
                        modelContext.delete(operation)
                        convertedAcknowledgedCreate = true
                    } else if operation.operationType == "create", remoteIds.contains(taskId) {
                        operation.operationType = "update"
                        writes.insert(taskId)
                        convertedAcknowledgedCreate = true
                    } else if operation.operationType == "delete" {
                        deletes.insert(taskId)
                    } else if operation.operationType == "create" || operation.operationType == "update" {
                        writes.insert(taskId)
                    }
                }

                if convertedAcknowledgedCreate {
                    try? modelContext.save()
                }
                return (writes, deletes)
            }
            // Whether every remote row actually landed. Reported to callers so a read path
            // cannot claim freshness for a reconcile that held rows back or failed to save.
            var reconciledFully = true
            await MainActor.run {
                let isoWithFrac = ISO8601DateFormatter()
                isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let isoPlain = ISO8601DateFormatter()
                isoPlain.formatOptions = [.withInternetDateTime]
                func parseISO(_ s: String?) -> Date? {
                    guard let s else { return nil }
                    return isoWithFrac.date(from: s) ?? isoPlain.date(from: s)
                }

                let existingDescriptor = FetchDescriptor<TaskEvent>()
                let existing = (try? modelContext.fetch(existingDescriptor)) ?? []
                let existingById = Dictionary(uniqueKeysWithValues: existing.compactMap { task -> (UUID, TaskEvent)? in
                    (task.id, task)
                })

                for remote in remoteTasks {
                    guard let remoteUUID = UUID(uuidString: remote.id),
                          !pendingIntents.deletes.contains(remoteUUID),
                          !remoteDeletedIds.contains(remoteUUID) else {
                        continue
                    }
                    if let local = existingById[remoteUUID] {
                        // A failed local write remains authoritative until its durable queue
                        // entry succeeds; a stale pull must not overwrite the user's edit.
                        if pendingIntents.writes.contains(local.id) {
                            // Correct to hold the row back, but it means this task still
                            // carries pre-pull values — including `runStatus`. A caller that
                            // answers questions must not present that as current.
                            reconciledFully = false
                            continue
                        }
                        // Update existing
                        local.title = remote.title
                        if let s = remote.status { local.status = s }
                        if let p = remote.priority { local.priority = p }
                        if let sd = remote.startDate { local.startDate = parseISO(sd) }
                        if let ed = remote.endDate { local.endDate = parseISO(ed) }
                        if let dm = remote.durationMinutes { local.duration = TimeInterval(dm * 60) }
                        if let at = remote.alertTime { local.alertTime = parseISO(at) }
                        if let rf = remote.repeatFrequency { local.repeatFrequency = rf }
                        if let t = remote.type { local.isEvent = t == "calendar_event" }
                        if let cid = remote.calendarEventID { local.calendarEventID = cid }
                        // Organization: backend is source of truth for list assignment.
                        local.listID = remote.listID.flatMap { UUID(uuidString: $0) }
                        local.isCalendarOnlyMirror = false
                        // Agent run-state (migration 019): backend is the source of truth.
                        // Unconditionally mirror it (including nil) so a reaped/cleared run
                        // clears locally too — the sweep resets stale `running` to nil.
                        local.runStatus = remote.runStatus
                        local.runId = remote.runId
                        local.sessionKey = remote.sessionKey
                        local.runStartedAt = parseISO(remote.runStartedAt)
                        // Staleness (migration 116): backend is the source of truth. Mirror
                        // unconditionally INCLUDING nil — any user action clears `stale_at` there,
                        // and a client that only ever wrote non-nil would leave the row dimmed and
                        // badged forever after the user had already brought it back.
                        local.staleAt = parseISO(remote.staleAt)
                        // Co-authored description (migration 120). Backend owns BOTH halves
                        // because the merge that keeps the two authors apart only exists
                        // there; mirroring unconditionally is safe precisely because a
                        // pending local write short-circuits this whole branch above.
                        local.taskDescription = remote.descriptionUser
                        local.agentContext = remote.descriptionAgent
                        if let ua = remote.updatedAt { local.updatedAt = parseISO(ua) ?? Date() }
                    } else {
                        // Insert new
                        let task = TaskEvent(
                            id: remoteUUID,
                            title: remote.title,
                            startDate: parseISO(remote.startDate),
                            endDate: parseISO(remote.endDate),
                            duration: remote.durationMinutes.map { TimeInterval($0 * 60) },
                            alertTime: parseISO(remote.alertTime),
                            repeatFrequency: remote.repeatFrequency,
                            isEvent: remote.type == "calendar_event",
                            priority: Priority(rawValue: (remote.priority ?? "medium").capitalized) ?? .medium,
                            status: TaskStatus(rawValue: remote.status ?? "pending") ?? .todo,
                            calendarEventID: remote.calendarEventID,
                            isCalendarOnlyMirror: false,
                            listID: remote.listID.flatMap { UUID(uuidString: $0) }
                        )
                        // Agent run-state (migration 019) — read-only from backend.
                        task.runStatus = remote.runStatus
                        task.runId = remote.runId
                        task.sessionKey = remote.sessionKey
                        task.runStartedAt = parseISO(remote.runStartedAt)
                        // Staleness (migration 116) — read-only from backend, distinct from status.
                        task.staleAt = parseISO(remote.staleAt)
                        task.taskDescription = remote.descriptionUser
                        task.agentContext = remote.descriptionAgent
                        modelContext.insert(task)
                    }
                }

                // Cross-device deletion is driven only by explicit, identity-bound backend
                // tombstones. Never infer deletion from absence in the mutable task pages.
                for (id, task) in existingById where remoteDeletedIds.contains(id) {
                    notificationService.cancelNotification(for: task.id)
                    modelContext.delete(task)
                }

                // Absence from a list response is not a deletion tombstone. The response can
                // be stale, scoped to the wrong identity, or mutate between offset pages.
                // Explicit DELETE operations remove local rows; pull sync only upserts.

                do {
                    try modelContext.save()
                } catch {
                    // The pull is only as real as the write. Swallowing this and reporting
                    // success is how a caller ends up presenting pre-pull data as current.
                    print("[TaskSync] Pull sync save failed: \(error.localizedDescription)")
                    reconciledFully = false
                }

                // Reschedule notifications for all tasks after sync
                let allDescriptor = FetchDescriptor<TaskEvent>()
                let allTasks = (try? modelContext.fetch(allDescriptor)) ?? []
                Task {
                    await notificationService.rescheduleAll(tasks: allTasks)
                }
            }
            return reconciledFully
        } catch {
            print("[TaskSync] Pull sync failed: \(error.localizedDescription)")
            return false
        }
    }
}
