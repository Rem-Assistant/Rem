import Foundation
import SwiftData
import Testing
@testable import RemClaw

@MainActor
struct TaskPersistenceSyncTests {
    private enum StubError: Error { case offline }

    private final class TaskApiStub: TaskApiServiceProtocol {
        var remoteTasks: [TaskEventApiResponse] = []
        var remoteDeletions: [TaskDeletionApiResponse] = []
        var createShouldFail = false
        var createResponseOverride: TaskEventApiResponse?
        var eventCreateResponseOverride: TaskEventApiResponse?
        var updateShouldFail = false
        var deleteShouldFail = false
        var savedTaskIDs: [String?] = []
        var savedEventIDs: [String?] = []
        var savedListIDs: [String?] = []
        /// The USER's half of the description sent on each CREATE (migration 120).
        var savedDescriptions: [String?] = []
        var updatedTaskIDs: [String] = []
        var updatedTaskTitles: [String?] = []
        /// The USER's half of the co-authored description sent on each PATCH (migration 120).
        var updatedDescriptions: [String?] = []
        var updatedListIDs: [String?] = []
        var updatedIncludesListID: [Bool] = []
        var updatedIncludesClearedFields: [Bool] = []
        var deletedTaskIDs: [String] = []
        var holdUpdates = false
        var updateStarted = false
        var updateContinuation: CheckedContinuation<Void, Never>?
        var holdCreates = false
        var createStarted = false
        var createContinuation: CheckedContinuation<Void, Never>?

        func saveTaskToBackend(
            id: String?,
            title: String,
            priority: String,
            status: String,
            startDate: Date?,
            endDate: Date?,
            durationMinutes: Int?,
            alertTime: Date?,
            repeatFrequency: String?,
            description: String?,
            listID: String?
        ) async throws -> TaskEventApiResponse {
            savedTaskIDs.append(id)
            savedDescriptions.append(description)
            savedListIDs.append(listID)
            createStarted = true
            if holdCreates {
                await withCheckedContinuation { continuation in
                    createContinuation = continuation
                }
            }
            if createShouldFail { throw StubError.offline }
            if let createResponseOverride { return createResponseOverride }
            let response = TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, listID: listID)
            remoteTasks.append(response)
            return response
        }

        func saveEventToBackend(
            id: String?,
            title: String,
            dateTime: String,
            durationMinutes: Int,
            listID: String?
        ) async throws -> TaskEventApiResponse {
            savedEventIDs.append(id)
            savedListIDs.append(listID)
            if createShouldFail { throw StubError.offline }
            if let eventCreateResponseOverride { return eventCreateResponseOverride }
            let response = TaskEventApiResponse(
                id: id ?? UUID().uuidString,
                title: title,
                type: "calendar_event",
                listID: listID
            )
            remoteTasks.append(response)
            return response
        }

        func fetchTasks() async throws -> [TaskEventApiResponse] { remoteTasks }
        func fetchTaskDeletions() async throws -> [TaskDeletionApiResponse] { remoteDeletions }
        func getTask(id: String) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id, title: "")
        }
        func updateTask(
            id: String,
            title: String?,
            priority: String?,
            status: String?,
            startDate: Date?,
            endDate: Date?,
            durationMinutes: Int?,
            alertTime: Date?,
            repeatFrequency: String?,
            description: String?,
            listID: String?,
            includeListID: Bool,
            includeClearedFields: Bool
        ) async throws -> TaskEventApiResponse {
            updatedTaskIDs.append(id)
            updatedTaskTitles.append(title)
            updatedDescriptions.append(description)
            updatedListIDs.append(listID)
            updatedIncludesListID.append(includeListID)
            updatedIncludesClearedFields.append(includeClearedFields)
            updateStarted = true
            if holdUpdates {
                await withCheckedContinuation { continuation in
                    updateContinuation = continuation
                }
            }
            if updateShouldFail { throw StubError.offline }
            let existingListID = remoteTasks.first(where: { $0.id == id })?.listID
            let response = TaskEventApiResponse(
                id: id,
                title: title ?? "",
                startDate: startDate.map { ISO8601DateFormatter().string(from: $0) }
                    ?? (includeClearedFields ? nil : remoteTasks.first(where: { $0.id == id })?.startDate),
                endDate: endDate.map { ISO8601DateFormatter().string(from: $0) }
                    ?? (includeClearedFields ? nil : remoteTasks.first(where: { $0.id == id })?.endDate),
                durationMinutes: durationMinutes
                    ?? (includeClearedFields ? nil : remoteTasks.first(where: { $0.id == id })?.durationMinutes),
                alertTime: alertTime.map { ISO8601DateFormatter().string(from: $0) }
                    ?? (includeClearedFields ? nil : remoteTasks.first(where: { $0.id == id })?.alertTime),
                repeatFrequency: repeatFrequency
                    ?? (includeClearedFields ? nil : remoteTasks.first(where: { $0.id == id })?.repeatFrequency),
                listID: includeListID ? listID : existingListID
            )
            if let index = remoteTasks.firstIndex(where: { $0.id == id }) {
                remoteTasks[index] = response
            }
            return response
        }
        func deleteTask(id: String) async throws {
            deletedTaskIDs.append(id)
            if deleteShouldFail { throw StubError.offline }
        }
        func releaseUpdate() {
            holdUpdates = false
            updateContinuation?.resume()
            updateContinuation = nil
        }
        func releaseCreate() {
            holdCreates = false
            createContinuation?.resume()
            createContinuation = nil
        }
        func ensureEventBacking(
            calendarEventID: String,
            title: String,
            startDate: Date?,
            durationMinutes: Int?,
            listID: String?
        ) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: UUID().uuidString, title: title)
        }
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TaskEvent.self,
            PendingTaskOperation.self,
            TaskList.self,
            TaskFolder.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func legacyPayloadWithoutListID(for task: TaskEvent) throws -> Data {
        let encoded = try JSONEncoder().encode(task.toApiResponse())
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(decoded as? [String: Any])
        object.removeValue(forKey: "list_id")
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func makePersistentContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: TaskEvent.self,
            PendingTaskOperation.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    @Test func savedTaskSurvivesPersistentStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemTaskPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tasks.store")
        let taskID = UUID()

        do {
            let container = try makePersistentContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(TaskEvent(id: taskID, title: "Still here after reopen"))
            try context.save()
        }

        do {
            let reopened = try makePersistentContainer(at: storeURL)
            let context = ModelContext(reopened)
            let tasks = try context.fetch(FetchDescriptor<TaskEvent>())
            #expect(tasks.map(\.id) == [taskID])
            #expect(tasks.first?.title == "Still here after reopen")
        }
    }

    @Test func failedQueuedCreateKeepsLocalTaskAndStableID() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Survive offline sync")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        api.createShouldFail = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        let tasks = try context.fetch(FetchDescriptor<TaskEvent>())
        let operations = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(tasks.map(\.id) == [task.id])
        #expect(operations.count == 1)
        #expect(api.savedTaskIDs == [task.id.uuidString])
    }

    @Test func lowercaseRemoteUUIDUpdatesExistingTaskWithoutDuplicate() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Old local title")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        api.remoteTasks = [TaskEventApiResponse(
            id: task.id.uuidString.lowercased(),
            title: "Updated on another device"
        )]
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        let tasks = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(tasks.count == 1)
        #expect(tasks.first?.id == task.id)
        #expect(tasks.first?.title == "Updated on another device")
    }

    @Test func successfulQueuedCreateRoundTripsWithStableID() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Restore on another device")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        let tasks = try context.fetch(FetchDescriptor<TaskEvent>())
        let operations = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(tasks.map(\.id) == [task.id])
        #expect(operations.isEmpty)
        #expect(api.remoteTasks.map(\.id) == [task.id.uuidString])
        #expect(api.savedTaskIDs == [task.id.uuidString])
    }

    @Test func offlineCreateRetainsListAssignmentThroughReplay() async throws {
        let context = try makeContext()
        let listID = UUID()
        let task = TaskEvent(title: "Filed offline", listID: listID)
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        api.createShouldFail = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        _ = try await service.syncTaskCreateToBackendImmediately(task)
        let queued = try #require(context.fetch(FetchDescriptor<PendingTaskOperation>()).first)
        let payload = try #require(queued.taskData)
        #expect(try JSONDecoder().decode(TaskEventApiResponse.self, from: payload).listID == listID.uuidString)

        api.createShouldFail = false
        await service.processPendingOperations()

        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
        #expect(api.savedListIDs == [listID.uuidString, listID.uuidString])
    }

    @Test func ordinaryEditFoldedIntoOfflineCreatePreservesCreateListOwnership() async throws {
        let context = try makeContext()
        let listID = UUID()
        let task = TaskEvent(title: "Filed before going offline", listID: listID)
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        api.createShouldFail = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        _ = try await service.syncTaskCreateToBackendImmediately(task)

        task.title = "Ordinary title edit while offline"
        api.updateShouldFail = true
        try await service.syncTaskToBackendImmediately(task)

        let queued = try #require(context.fetch(FetchDescriptor<PendingTaskOperation>()).first)
        #expect(queued.operationType == "create")
        let payload = try #require(queued.taskData)
        let snapshot = try JSONDecoder().decode(TaskEventApiResponse.self, from: payload)
        #expect(snapshot.title == task.title)
        #expect(snapshot.listID == listID.uuidString)

        api.createShouldFail = false
        api.updateShouldFail = false
        await service.processPendingOperations()

        #expect(api.savedListIDs == [listID.uuidString, listID.uuidString])
        #expect(api.updatedListIDs == [nil, listID.uuidString])
        #expect(api.updatedIncludesListID == [false, true])
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func deletedListReconciliationUnfilesQueuedCreateBeforeReplay() async throws {
        let context = try makeContext()
        let deletedList = TaskList(name: "Deleted elsewhere")
        let task = TaskEvent(title: "Keep durable create", listID: deletedList.id)
        context.insert(deletedList)
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        try OrganizationSyncManager.reconcileDeletedListReferences(
            remoteListIDs: [],
            in: context
        )
        try context.save()
        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        await service.processPendingOperations()

        #expect(task.listID == nil)
        #expect(api.savedListIDs == [nil])
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func unrelatedImmediatePatchOmitsStaleListThroughReplay() async throws {
        let context = try makeContext()
        let deletedList = TaskList(name: "Deleted elsewhere")
        let task = TaskEvent(title: "Keep unrelated edit", listID: deletedList.id)
        context.insert(deletedList)
        context.insert(task)
        try context.save()

        task.title = "Edited after organization refresh"
        try context.save()
        let api = TaskApiStub()
        api.updateShouldFail = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        try await service.syncTaskToBackendImmediately(task)

        let queued = try #require(context.fetch(FetchDescriptor<PendingTaskOperation>()).first)
        let payload = try #require(queued.taskData)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(!object.keys.contains("list_id"))
        #expect(object["rem_list_id_included"] as? Bool == false)

        api.updateShouldFail = false
        await service.processPendingOperations()

        #expect(task.listID == deletedList.id)
        #expect(api.updatedListIDs == [nil, nil])
        #expect(api.updatedIncludesListID == [false, false])
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func completionOmitsStaleCachedListByDefault() async throws {
        let context = try makeContext()
        let staleListID = UUID()
        let task = TaskEvent(title: "Complete without refiling", listID: staleListID)
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        try await service.updateTaskStatus(task, to: .completed, modelContext: context)

        #expect(task.status == "completed")
        #expect(task.listID == staleListID)
        #expect(api.updatedListIDs == [nil])
        #expect(api.updatedIncludesListID == [false])
    }

    @Test func successfulDirectCreateRetiresMatchingQueuedCreate() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Retry once")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        _ = try await service.syncTaskCreateToBackendImmediately(task)

        #expect(api.savedTaskIDs == [task.id.uuidString])
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func offlineUpdateRetainsListAssignmentThroughReplay() async throws {
        let context = try makeContext()
        let listID = UUID()
        let task = TaskEvent(title: "Move offline", listID: listID)
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        api.updateShouldFail = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        try await service.syncTaskToBackendImmediately(task, includeListID: true)
        let queued = try #require(context.fetch(FetchDescriptor<PendingTaskOperation>()).first)
        let payload = try #require(queued.taskData)
        #expect(try JSONDecoder().decode(TaskEventApiResponse.self, from: payload).listID == listID.uuidString)

        api.updateShouldFail = false
        await service.processPendingOperations()

        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
        #expect(api.updatedListIDs == [listID.uuidString, listID.uuidString])
    }

    @Test func newlyQueuedUnfileUsesExplicitNullListAssignment() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Explicitly unfiled")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        api.updateShouldFail = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        try await service.syncTaskToBackendImmediately(task, includeListID: true)

        let operation = try #require(context.fetch(FetchDescriptor<PendingTaskOperation>()).first)
        let payload = try #require(operation.taskData)
        let decoded = try JSONSerialization.jsonObject(with: payload)
        let object = try #require(decoded as? [String: Any])
        #expect(object.keys.contains("list_id"))
        #expect(object["list_id"] is NSNull)
    }

    @Test func legacyQueuedCreateRecoversLocalListAssignment() async throws {
        let context = try makeContext()
        let listID = UUID()
        let task = TaskEvent(title: "Legacy filed create", listID: listID)
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try legacyPayloadWithoutListID(for: task)
        ))
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        await service.processPendingOperations()

        #expect(api.savedListIDs == [listID.uuidString])
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func legacyQueuedUpdateRecoversLocalListAssignment() async throws {
        let context = try makeContext()
        let listID = UUID()
        let task = TaskEvent(title: "Legacy filed update", listID: listID)
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "update",
            taskId: task.id,
            taskData: try legacyPayloadWithoutListID(for: task)
        ))
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        await service.processPendingOperations()

        #expect(api.updatedListIDs == [listID.uuidString])
        #expect(api.updatedIncludesListID == [true])
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func legacyQueuedUpdateWithoutRecoverableAssignmentPreservesBackendList() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Legacy unknown organization")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "update",
            taskId: task.id,
            taskData: try legacyPayloadWithoutListID(for: task)
        ))
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        await service.processPendingOperations()

        #expect(api.updatedListIDs == [nil])
        #expect(api.updatedIncludesListID == [false])
    }

    @Test func remoteSnapshotConvertsLostCreateAcknowledgementIntoUpdate() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Already committed remotely")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        api.createShouldFail = true
        api.remoteTasks = [TaskEventApiResponse(id: task.id.uuidString.lowercased(), title: "Older committed value")]
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).first?.title == task.title)
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).first?.operationType == "update")
        #expect(api.savedTaskIDs == [task.id.uuidString])

        api.createShouldFail = false
        await service.syncFromBackend()

        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
        #expect(api.updatedTaskIDs == [task.id.uuidString])
        #expect(api.remoteTasks.first?.title == task.title)
    }

    @Test func successfulDuplicateCreateReplayAppliesNewerQueuedPayloadAndListBeforeDeletion() async throws {
        let context = try makeContext()
        let newerListID = UUID()
        let task = TaskEvent(
            title: "Edited after the lost acknowledgement",
            listID: newerListID
        )
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        api.remoteTasks = [TaskEventApiResponse(
            id: task.id.uuidString,
            title: "Original committed suggestion title",
            startDate: "2026-08-08T20:00:00Z",
            endDate: "2026-08-08T20:30:00Z",
            durationMinutes: 30,
            alertTime: "2026-08-08T19:45:00Z",
            repeatFrequency: "daily"
        )]
        api.createResponseOverride = api.remoteTasks[0]
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        #expect(api.savedTaskIDs == [task.id.uuidString])
        #expect(api.updatedTaskIDs == [task.id.uuidString])
        #expect(api.updatedTaskTitles == [task.title])
        #expect(api.updatedListIDs == [newerListID.uuidString])
        #expect(api.updatedIncludesListID == [true])
        #expect(api.updatedIncludesClearedFields == [true])
        #expect(api.remoteTasks.first?.title == task.title)
        #expect(api.remoteTasks.first?.listID == newerListID.uuidString)
        #expect(api.remoteTasks.first?.startDate == nil)
        #expect(api.remoteTasks.first?.endDate == nil)
        #expect(api.remoteTasks.first?.durationMinutes == nil)
        #expect(api.remoteTasks.first?.alertTime == nil)
        #expect(api.remoteTasks.first?.repeatFrequency == nil)
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).first?.title == task.title)
    }

    @Test func successfulDuplicateEventReplayAppliesQueuedPayloadAndListBeforeDeletion() async throws {
        let context = try makeContext()
        let newerListID = UUID()
        let newerStart = Date(timeIntervalSince1970: 1_786_304_400)
        let event = TaskEvent(
            title: "Edited event after lost acknowledgement",
            startDate: newerStart,
            duration: 45 * 60,
            isEvent: true,
            listID: newerListID
        )
        context.insert(event)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: event.id,
            taskData: try JSONEncoder().encode(event.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        let older = TaskEventApiResponse(
            id: event.id.uuidString,
            title: "Older committed event",
            startDate: "2026-08-08T20:00:00Z",
            durationMinutes: 30,
            type: "calendar_event"
        )
        api.remoteTasks = [older]
        api.eventCreateResponseOverride = older
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        #expect(api.savedEventIDs == [event.id.uuidString])
        #expect(api.updatedTaskIDs == [event.id.uuidString])
        #expect(api.updatedTaskTitles == [event.title])
        #expect(api.updatedListIDs == [newerListID.uuidString])
        #expect(api.updatedIncludesListID == [true])
        #expect(api.updatedIncludesClearedFields == [true])
        #expect(api.remoteTasks.first?.title == event.title)
        #expect(api.remoteTasks.first?.startDate == ISO8601DateFormatter().string(from: newerStart))
        #expect(api.remoteTasks.first?.durationMinutes == 45)
        #expect(api.remoteTasks.first?.listID == newerListID.uuidString)
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func staleSnapshotCannotDeleteOrOverwriteTaskWithPendingUpdate() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Keep my offline edit")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "update",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        api.updateShouldFail = true
        api.remoteTasks = [TaskEventApiResponse(id: task.id.uuidString, title: "Stale server title")]
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        let tasks = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(tasks.map(\.id) == [task.id])
        #expect(tasks.first?.title == "Keep my offline edit")
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).count == 1)
    }

    @Test func failedDeleteCannotBeResurrectedByPull() async throws {
        let context = try makeContext()
        let taskID = UUID()
        context.insert(PendingTaskOperation(
            operationType: "delete",
            taskId: taskID,
            taskData: nil
        ))
        try context.save()

        let api = TaskApiStub()
        api.deleteShouldFail = true
        api.remoteTasks = [TaskEventApiResponse(id: taskID.uuidString, title: "Already deleted locally")]
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).isEmpty)
    }

    @Test func remoteDeletionTombstoneRemovesLocalTaskAndPendingIntent() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Deleted on another device")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "update",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        api.updateShouldFail = true
        api.remoteDeletions = [TaskDeletionApiResponse(
            taskID: task.id.uuidString.lowercased(),
            deletedAt: ISO8601DateFormatter().string(from: Date())
        )]
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)

        await service.syncFromBackend()

        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }

    @Test func laterEditDuringInFlightUpdateIsDurablyQueued() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "First edit")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        api.holdUpdates = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        let firstUpdate = Task { try? await service.syncTaskToBackendImmediately(task) }
        while !api.updateStarted { await Task.yield() }

        task.title = "Newer edit"
        try await service.syncTaskToBackendImmediately(task)
        api.releaseUpdate()
        await firstUpdate.value

        let queued = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(queued.count == 1)
        #expect(queued.first?.operationType == "update")
        let payload = try #require(queued.first?.taskData)
        #expect(try JSONDecoder().decode(TaskEventApiResponse.self, from: payload).title == "Newer edit")
    }

    @Test func editDuringQueuedCreateUploadPreservesNewerPayload() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Original queued title")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        api.holdCreates = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        let upload = Task { await service.processPendingOperations() }
        while !api.createStarted { await Task.yield() }

        task.title = "Edited while create was uploading"
        let newerPayload = try JSONEncoder().encode(task.toApiResponse())
        #expect(await service.queueOperation(
            operationType: "update",
            taskId: task.id,
            taskData: newerPayload
        ))

        api.releaseCreate()
        await upload.value

        let queued = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(queued.count == 1)
        #expect(queued.first?.operationType == "create")
        let payload = try #require(queued.first?.taskData)
        #expect(try JSONDecoder().decode(TaskEventApiResponse.self, from: payload).title == task.title)
    }

    @Test func immediateEditQueuesBehindOlderUpdateReplay() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Older queued edit")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "update",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        api.holdUpdates = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        let replay = Task { await service.processPendingOperations() }
        while !api.updateStarted { await Task.yield() }

        task.title = "Newest immediate edit"
        try await service.syncTaskToBackendImmediately(task)
        #expect(api.updatedTaskTitles == ["Older queued edit"])

        api.releaseUpdate()
        await replay.value

        var queued = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(queued.count == 1)
        let payload = try #require(queued.first?.taskData)
        #expect(try JSONDecoder().decode(TaskEventApiResponse.self, from: payload).title == task.title)

        await service.processPendingOperations()
        queued = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(queued.isEmpty)
        #expect(api.updatedTaskTitles == ["Older queued edit", "Newest immediate edit"])
    }

    @Test func successfulImmediateEditRetiresOlderQueuedReplay() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Newest immediate edit")
        context.insert(task)
        let staleResponse = TaskEventApiResponse(id: task.id.uuidString, title: "Older queued edit")
        context.insert(PendingTaskOperation(
            operationType: "update",
            taskId: task.id,
            taskData: try JSONEncoder().encode(staleResponse)
        ))
        try context.save()

        let api = TaskApiStub()
        api.holdUpdates = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        let immediate = Task { try? await service.syncTaskToBackendImmediately(task) }
        while !api.updateStarted { await Task.yield() }

        await service.processPendingOperations()
        api.releaseUpdate()
        await immediate.value

        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
        await service.processPendingOperations()
        #expect(api.updatedTaskTitles == ["Newest immediate edit"])
    }

    @Test func replacingLaterQueuedCreateWhileEarlierUploadRunsSuppressesStaleUpload() async throws {
        let context = try makeContext()
        let firstTask = TaskEvent(title: "First upload")
        let replacedTask = TaskEvent(title: "Must stay deleted")
        let firstOperation = PendingTaskOperation(
            operationType: "create",
            taskId: firstTask.id,
            taskData: try JSONEncoder().encode(firstTask.toApiResponse())
        )
        firstOperation.createdAt = Date(timeIntervalSinceNow: -1)
        let replacedOperation = PendingTaskOperation(
            operationType: "create",
            taskId: replacedTask.id,
            taskData: try JSONEncoder().encode(replacedTask.toApiResponse())
        )
        context.insert(firstOperation)
        context.insert(replacedOperation)
        try context.save()

        let api = TaskApiStub()
        api.holdCreates = true
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        let upload = Task { await service.processPendingOperations() }
        while !api.createStarted { await Task.yield() }

        #expect(await service.queueOperation(
            operationType: "delete",
            taskId: replacedTask.id,
            taskData: nil
        ))
        api.releaseCreate()
        await upload.value

        #expect(api.savedTaskIDs == [firstTask.id.uuidString])
        #expect(api.deletedTaskIDs.isEmpty)
        let queued = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(queued.count == 1)
        #expect(queued.first?.operationType == "delete")
        #expect(queued.first?.taskId == replacedTask.id)
    }

    @Test func deleteIntentSupersedesQueuedCreate() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Do not resurrect")
        context.insert(task)
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        await service.queueOperation(operationType: "delete", taskId: task.id, taskData: nil)

        let queued = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(queued.count == 1)
        #expect(queued.first?.operationType == "delete")

        await service.processPendingOperations()
        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
        #expect(api.savedTaskIDs.isEmpty)
        #expect(api.deletedTaskIDs == [task.id.uuidString])
    }

    @Test func delayedUpdateCannotReplaceQueuedDelete() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Delete stays final")
        context.insert(PendingTaskOperation(
            operationType: "delete",
            taskId: task.id,
            taskData: nil
        ))
        try context.save()

        let service = RemTaskSyncService(taskApiService: TaskApiStub(), modelContext: context)
        let queued = await service.queueOperation(
            operationType: "update",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        )

        #expect(queued)
        let operations = try context.fetch(FetchDescriptor<PendingTaskOperation>())
        #expect(operations.count == 1)
        #expect(operations.first?.operationType == "delete")
    }

    @Test func confirmedDeleteCancelsLostCreateRetry() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Deleted remotely")
        context.insert(PendingTaskOperation(
            operationType: "create",
            taskId: task.id,
            taskData: try JSONEncoder().encode(task.toApiResponse())
        ))
        try context.save()

        let service = RemTaskSyncService(taskApiService: TaskApiStub(), modelContext: context)
        await service.discardPendingOperations(for: task.id)

        #expect(try context.fetch(FetchDescriptor<PendingTaskOperation>()).isEmpty)
    }
}

@MainActor
struct TaskPaginationTests {
    @Test func completeSnapshotCollectsEveryPage() async throws {
        let first = TaskEventApiResponse(id: UUID().uuidString, title: "First")
        let second = TaskEventApiResponse(id: UUID().uuidString, title: "Second")
        var requestedOffsets: [Int] = []

        let tasks = try await RemTaskApiService.collectAllTaskPages(pageSize: 1) { limit, offset in
            requestedOffsets.append(offset)
            if offset == 0 {
                return PaginatedTasksResponse(
                    tasks: [first],
                    pagination: .init(total: 2, limit: limit, offset: offset, hasMore: true)
                )
            }
            return PaginatedTasksResponse(
                tasks: [second],
                pagination: .init(total: 2, limit: limit, offset: offset, hasMore: false)
            )
        }

        #expect(tasks.map(\.id) == [first.id, second.id])
        #expect(requestedOffsets == [0, 1])
    }

    @Test func malformedEmptyContinuationFailsClosed() async {
        await #expect(throws: RemApiError.self) {
            _ = try await RemTaskApiService.collectAllTaskPages { limit, offset in
                PaginatedTasksResponse(
                    tasks: [],
                    pagination: .init(total: 1, limit: limit, offset: offset, hasMore: true)
                )
            }
        }
    }
}
