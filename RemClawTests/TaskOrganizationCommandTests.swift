import Foundation
import OpenClawKit
import SwiftData
import Testing
@testable import RemClaw

@Suite("Task organization commands", .serialized)
@MainActor
struct TaskOrganizationCommandTests {
    private final class DurableTaskSyncStub: TaskSyncServiceProtocol {
        var createTaskIDs: [UUID] = []
        var updateTaskIDs: [UUID] = []
        var holdCreates = false
        var holdUpdates = false
        var createError: Error?
        var updateError: Error?
        var createContinuation: CheckedContinuation<Void, Never>?
        var updateContinuation: CheckedContinuation<Void, Never>?

        func queueOperation(operationType: String, taskId: UUID?, taskData: Data?) async -> Bool { true }

        @MainActor
        func updateTaskStatus(
            _ task: TaskEvent,
            to status: TaskStatus,
            modelContext: ModelContext
        ) async throws {}

        func syncTaskToBackendImmediately(_ task: TaskEvent) async throws {
            updateTaskIDs.append(task.id)
            if holdUpdates {
                await withCheckedContinuation { updateContinuation = $0 }
            }
            if let updateError { throw updateError }
        }

        func syncTaskCreateToBackendImmediately(
            _ task: TaskEvent
        ) async throws -> TaskEventApiResponse? {
            createTaskIDs.append(task.id)
            if holdCreates {
                await withCheckedContinuation { createContinuation = $0 }
            }
            if let createError { throw createError }
            return task.toApiResponse()
        }

        func releaseCreate() {
            holdCreates = false
            createContinuation?.resume()
            createContinuation = nil
        }

        func releaseUpdate() {
            holdUpdates = false
            updateContinuation?.resume()
            updateContinuation = nil
        }
    }

    @Test func hierarchyIsDiscoverableByName() async throws {
        let context = try makeContext()
        let folder = TaskFolder(name: "Work")
        let list = TaskList(name: "Launch", folderID: folder.id)
        context.insert(folder)
        context.insert(list)
        try context.save()
        configure(context)

        let folders = try await decode(
            FoldersListResponse.self,
            from: FoldersCommandHandler.handleList(request(command: "folders.list"))
        )
        let lists = try await decode(
            ListsListResponse.self,
            from: ListsCommandHandler.handleList(request(command: "lists.list"))
        )

        #expect(folders.folders.map(\.name) == ["Work"])
        #expect(lists.lists.first?.name == "Launch")
        #expect(lists.lists.first?.folderName == "Work")
    }

    @Test func invalidListReferenceDoesNotCreateAnUnfiledTask() async throws {
        let context = try makeContext()
        configure(context)

        let response = await TasksCommandHandler.handleCreate(request(
            command: "tasks.create",
            params: ["title": "Prepare launch", "listId": "not-a-list"]
        ))

        #expect(response.ok == false)
        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).isEmpty)
    }

    @Test func missingListReferenceDoesNotCreateAnUnfiledTask() async throws {
        let context = try makeContext()
        configure(context)

        let response = await TasksCommandHandler.handleCreate(request(
            command: "tasks.create",
            params: ["title": "Prepare launch", "listId": UUID().uuidString]
        ))

        #expect(response.ok == false)
        #expect(response.error?.message.contains("LIST_NOT_FOUND") == true)
        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).isEmpty)
    }

    @Test func rejectedUpdateDoesNotMutateAnyOtherTaskField() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Original title")
        context.insert(task)
        try context.save()
        configure(context)

        let response = await TasksCommandHandler.handleUpdate(request(
            command: "tasks.update",
            params: [
                "id": task.id.uuidString,
                "title": "Must not stick",
                "listId": UUID().uuidString,
            ]
        ))

        #expect(response.ok == false)
        #expect(task.title == "Original title")
        #expect(task.listID == nil)
    }

    @Test func completedAliasAndBlockedStatusAreApplied() async throws {
        let context = try makeContext()
        let completedTask = TaskEvent(title: "Complete me")
        let blockedTask = TaskEvent(title: "Needs input")
        context.insert(completedTask)
        context.insert(blockedTask)
        try context.save()
        configure(context)

        let completedResponse = await TasksCommandHandler.handleUpdate(request(
            command: "tasks.update",
            params: ["id": completedTask.id.uuidString, "completed": true]
        ))
        #expect(completedResponse.ok == true)
        #expect(completedTask.status == "completed")

        let blockedResponse = await TasksCommandHandler.handleUpdate(request(
            command: "tasks.update",
            params: ["id": blockedTask.id.uuidString, "status": "blocked"]
        ))
        let reopenedResponse = await TasksCommandHandler.handleUpdate(request(
            command: "tasks.update",
            params: ["id": completedTask.id.uuidString, "completed": false]
        ))

        #expect(blockedResponse.ok == true)
        #expect(blockedTask.status == "blocked")
        #expect(reopenedResponse.ok == true)
        #expect(completedTask.status == "pending")
    }

    @Test func unsupportedOrConflictingStatusIsRejectedWithoutMutation() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Original title")
        context.insert(task)
        try context.save()
        configure(context)

        let unsupported = await TasksCommandHandler.handleUpdate(request(
            command: "tasks.update",
            params: [
                "id": task.id.uuidString,
                "title": "Must not stick",
                "status": "waiting_for_magic",
            ]
        ))
        let conflicting = await TasksCommandHandler.handleUpdate(request(
            command: "tasks.update",
            params: [
                "id": task.id.uuidString,
                "status": "blocked",
                "completed": true,
            ]
        ))

        #expect(unsupported.ok == false)
        #expect(conflicting.ok == false)
        #expect(task.title == "Original title")
        #expect(task.status == "pending")
    }

    @Test func createRejectsUnsupportedStatusWithoutInsertingTask() async throws {
        let context = try makeContext()
        configure(context)

        let response = await TasksCommandHandler.handleCreate(request(
            command: "tasks.create",
            params: [
                "title": "Must not exist",
                "status": "waiting_for_magic",
            ]
        ))

        #expect(response.ok == false)
        let tasks = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(tasks.isEmpty)
    }

    @Test func resourceIdentityIsStablePerInvocationAndCommand() {
        let invocationID = "tool-call-42"
        let folderRequest = request(command: "folders.create", params: ["name": "Work"])
        let repeatedFolderRequest = BridgeInvokeRequest(
            id: invocationID,
            command: "folders.create",
            paramsJSON: folderRequest.paramsJSON
        )
        let sameRetry = BridgeInvokeRequest(
            id: invocationID,
            command: "folders.create",
            paramsJSON: folderRequest.paramsJSON
        )
        let listRequest = BridgeInvokeRequest(
            id: invocationID,
            command: "lists.create",
            paramsJSON: folderRequest.paramsJSON
        )

        let folderID = InvocationHelpers.stableResourceID(
            for: repeatedFolderRequest,
            namespace: "folders.create"
        )
        #expect(folderID == InvocationHelpers.stableResourceID(
            for: sameRetry,
            namespace: "folders.create"
        ))
        #expect(folderID != InvocationHelpers.stableResourceID(
            for: listRequest,
            namespace: "lists.create"
        ))
    }

    @Test func repeatedTaskCreateInvocationReturnsOneDurableTask() async throws {
        let context = try makeContext()
        let syncService = DurableTaskSyncStub()
        configure(context, syncService: syncService)
        let invocationID = "task-tool-call-42"
        let firstRequest = BridgeInvokeRequest(
            id: invocationID,
            command: "tasks.create",
            paramsJSON: #"{"title":"Prepare launch"}"#
        )
        let repeatedRequest = BridgeInvokeRequest(
            id: invocationID,
            command: "tasks.create",
            paramsJSON: firstRequest.paramsJSON
        )

        let first = try await decode(
            TasksCreateResponse.self,
            from: TasksCommandHandler.handleCreate(firstRequest)
        )
        let repeated = try await decode(
            TasksCreateResponse.self,
            from: TasksCommandHandler.handleCreate(repeatedRequest)
        )
        let tasks = try context.fetch(FetchDescriptor<TaskEvent>())
        let persistedTask = try #require(tasks.first)

        #expect(tasks.count == 1)
        #expect(first.task.id == repeated.task.id)
        #expect(persistedTask.id == InvocationHelpers.stableResourceID(
            for: firstRequest,
            namespace: RemTasksCommand.create.rawValue
        ))
        #expect(syncService.createTaskIDs == [persistedTask.id, persistedTask.id])
    }

    @Test func concurrentTaskCreateRedeliveriesShareOneSuccessfulFlight() async throws {
        let context = try makeContext()
        let syncService = DurableTaskSyncStub()
        syncService.holdCreates = true
        configure(context, syncService: syncService)
        let request = BridgeInvokeRequest(
            id: "overlapping-task-create",
            command: RemTasksCommand.create.rawValue,
            paramsJSON: #"{"title":"Create once"}"#
        )

        let first = Task { await TasksCommandHandler.handleCreate(request) }
        while syncService.createTaskIDs.isEmpty { await Task.yield() }
        let second = Task { await TasksCommandHandler.handleCreate(request) }
        await Task.yield()
        #expect(syncService.createTaskIDs.count == 1)

        syncService.releaseCreate()
        let responses = await (first.value, second.value)

        #expect(responses.0.ok == true)
        #expect(responses.1.ok == true)
        #expect(responses.0.payloadJSON == responses.1.payloadJSON)
        #expect(syncService.createTaskIDs.count == 1)
        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).count == 1)
    }

    @Test func concurrentTaskCreateRedeliveriesShareOneTerminalFailure() async throws {
        let context = try makeContext()
        let syncService = DurableTaskSyncStub()
        syncService.holdCreates = true
        syncService.createError = RemApiError.requestFailed(statusCode: 400, message: "invalid list")
        configure(context, syncService: syncService)
        let request = BridgeInvokeRequest(
            id: "overlapping-failed-task-create",
            command: RemTasksCommand.create.rawValue,
            paramsJSON: #"{"title":"Cannot persist"}"#
        )

        let first = Task { await TasksCommandHandler.handleCreate(request) }
        while syncService.createTaskIDs.isEmpty { await Task.yield() }
        let second = Task { await TasksCommandHandler.handleCreate(request) }
        await Task.yield()
        syncService.releaseCreate()
        let responses = await (first.value, second.value)

        #expect(responses.0.ok == false)
        #expect(responses.1.ok == false)
        #expect(responses.0.error?.message == responses.1.error?.message)
        #expect(syncService.createTaskIDs.count == 1)
        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).isEmpty)
    }

    @Test func failedTaskUpdatePreservesNewerConcurrentFieldValue() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "Original")
        context.insert(task)
        try context.save()
        let syncService = DurableTaskSyncStub()
        syncService.holdUpdates = true
        syncService.updateError = RemApiError.requestFailed(statusCode: 400, message: "terminal")
        configure(context, syncService: syncService)

        let update = Task { await TasksCommandHandler.handleUpdate(request(
            command: RemTasksCommand.update.rawValue,
            params: [
                "id": task.id.uuidString,
                "title": "Gateway edit",
                "status": "blocked",
            ]
        )) }
        while syncService.updateTaskIDs.isEmpty { await Task.yield() }
        task.title = "Newer user edit"
        task.notes = "Newer independent note"
        try context.save()

        syncService.releaseUpdate()
        let response = await update.value

        #expect(response.ok == false)
        #expect(task.title == "Newer user edit")
        #expect(task.notes == "Newer independent note")
        #expect(task.status == "pending")
    }

    @Test func preexistingStableTaskReconcilesBackendDurabilityBeforeSuccess() async throws {
        let context = try makeContext()
        let request = BridgeInvokeRequest(
            id: "interrupted-task-tool-call",
            command: RemTasksCommand.create.rawValue,
            paramsJSON: #"{"title":"Survive interrupted persistence"}"#
        )
        let stableID = InvocationHelpers.stableResourceID(
            for: request,
            namespace: RemTasksCommand.create.rawValue
        )
        context.insert(TaskEvent(id: stableID, title: "Survive interrupted persistence"))
        try context.save()
        let syncService = DurableTaskSyncStub()
        configure(context, syncService: syncService)

        let response = try await decode(
            TasksCreateResponse.self,
            from: TasksCommandHandler.handleCreate(request)
        )

        #expect(response.task.id.lowercased() == stableID.uuidString.lowercased())
        #expect(syncService.createTaskIDs == [stableID])
        #expect(try context.fetch(FetchDescriptor<TaskEvent>()).count == 1)
    }

    @Test func createdTaskReportsItsHumanOrganizationPath() async throws {
        let context = try makeContext()
        let folder = TaskFolder(name: "Work")
        let list = TaskList(name: "Launch", folderID: folder.id)
        context.insert(folder)
        context.insert(list)
        try context.save()
        configure(context)

        let response = await TasksCommandHandler.handleCreate(request(
            command: "tasks.create",
            params: ["title": "Prepare launch", "listId": list.id.uuidString]
        ))
        let decoded = try await decode(TasksCreateResponse.self, from: response)

        #expect(decoded.task.listId?.lowercased() == list.id.uuidString.lowercased())
        #expect(decoded.task.listName == "Launch")
        #expect(decoded.task.folderName == "Work")
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TaskEvent.self, TaskList.self, TaskFolder.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func configure(
        _ context: ModelContext,
        syncService: DurableTaskSyncStub = DurableTaskSyncStub()
    ) {
        TasksCommandHandler.configure(
            modelContext: { context },
            taskSyncService: { syncService },
            taskApiService: { nil },
            organizationApiService: { nil }
        )
        ListsCommandHandler.configure(
            modelContext: { context },
            organizationApiService: { nil }
        )
        FoldersCommandHandler.configure(
            modelContext: { context },
            organizationApiService: { nil }
        )
    }

    private func request(
        command: String,
        params: [String: Any]? = nil
    ) -> BridgeInvokeRequest {
        let paramsJSON = params.flatMap { dictionary in
            try? JSONSerialization.data(withJSONObject: dictionary)
        }.flatMap { String(data: $0, encoding: .utf8) }
        return BridgeInvokeRequest(id: UUID().uuidString, command: command, paramsJSON: paramsJSON)
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from response: BridgeInvokeResponse
    ) async throws -> T {
        #expect(response.ok == true)
        let json = try #require(response.payloadJSON)
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
