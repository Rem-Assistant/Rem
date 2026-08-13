import Foundation
import SwiftData
import Testing
@testable import RemClaw

/// The device half of the co-authored task description (backend migration 120).
///
/// The merge that keeps the user's text and Rem's context from overwriting each other
/// lives on the backend, and is proven there (`task-description.db.test.ts`). What has to
/// be true HERE is narrower but just as easy to get wrong:
///   - the two halves are actually decoded off the wire (a missing CodingKey silently
///     yields nil forever, and the UI would just look empty);
///   - the device pushes only the USER's half, so a sync can never carry Rem's block back
///     up as if the client had authored it;
///   - a pull mirrors both halves onto the model, including clearing them.
@MainActor
struct TaskDescriptionSyncTests {
    private final class TaskApiStub: TaskApiServiceProtocol {
        var remoteTasks: [TaskEventApiResponse] = []
        /// Every `description` value the device sent on a PATCH, in order.
        var updatedDescriptions: [String?] = []

        /// Every `description` value the device sent on a CREATE, in order.
        var createdDescriptions: [String?] = []

        func saveTaskToBackend(id: String?, title: String, priority: String, status: String, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?) async throws -> TaskEventApiResponse {
            createdDescriptions.append(description)
            return TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, descriptionUser: description)
        }

        func saveEventToBackend(id: String?, title: String, dateTime: String, durationMinutes: Int, listID: String?) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id ?? UUID().uuidString, title: title)
        }

        func fetchTasks() async throws -> [TaskEventApiResponse] { remoteTasks }
        func fetchTaskDeletions() async throws -> [TaskDeletionApiResponse] { [] }

        func getTask(id: String) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id, title: "")
        }

        func updateTask(id: String, title: String?, priority: String?, status: String?, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?, includeListID: Bool, includeClearedFields: Bool) async throws -> TaskEventApiResponse {
            updatedDescriptions.append(description)
            return TaskEventApiResponse(id: id, title: title ?? "", descriptionUser: description)
        }

        func deleteTask(id: String) async throws {}

        func ensureEventBacking(calendarEventID: String, title: String, startDate: Date?, durationMinutes: Int?, listID: String?) async throws -> TaskEventApiResponse {
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

    // MARK: - The wire

    @Test func decodesBothHalvesOfTheDescriptionFromTheBackendPayload() throws {
        // Exactly what `formatTask` emits: the whole column plus the two halves, so the
        // block delimiter is never parsed on the client.
        let payload = Data("""
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "title": "File visa paperwork",
          "description": "Attorney is Ada.\\n\\n<!-- rem:agent-context -->\\nCover letter drafted.\\n<!-- /rem:agent-context -->",
          "description_user": "Attorney is Ada.",
          "description_agent": "Cover letter drafted."
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(TaskEventApiResponse.self, from: payload)

        #expect(decoded.descriptionUser == "Attorney is Ada.")
        #expect(decoded.descriptionAgent == "Cover letter drafted.")
        #expect(decoded.taskDescription?.contains("rem:agent-context") == true)
    }

    @Test func aPayloadWithoutADescriptionDecodesAsAbsent() throws {
        let payload = Data("""
        { "id": "11111111-1111-4111-8111-111111111111", "title": "Older task" }
        """.utf8)

        let decoded = try JSONDecoder().decode(TaskEventApiResponse.self, from: payload)

        #expect(decoded.descriptionUser == nil)
        #expect(decoded.descriptionAgent == nil)
    }

    // MARK: - The push

    @Test func pushesTheUsersHalfOfTheDescription() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "File visa paperwork", taskDescription: "Attorney is Ada.")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        try await service.syncTaskToBackendImmediately(task)

        #expect(api.updatedDescriptions == ["Attorney is Ada."])
    }

    @Test func neverPushesRemsHalfBackUpAsIfTheDeviceWroteIt() async throws {
        let context = try makeContext()
        let task = TaskEvent(
            title: "File visa paperwork",
            taskDescription: "Attorney is Ada.",
            agentContext: "Cover letter drafted; need the receipt number."
        )
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        try await service.syncTaskToBackendImmediately(task)

        // Only the user's half goes out. Rem's context is the backend's record, and the
        // PATCH the device sends is understood there as "set MY half" — sending the
        // agent's text under that key is exactly the clobber the design forbids.
        #expect(api.updatedDescriptions == ["Attorney is Ada."])
        let sent = try #require(api.updatedDescriptions.first ?? nil)
        #expect(!sent.contains("receipt number"))
        #expect(!sent.contains("rem:agent-context"))
    }

    @Test func theOfflineQueueSnapshotCarriesTheUsersHalfOnly() throws {
        let task = TaskEvent(
            title: "File visa paperwork",
            taskDescription: "Attorney is Ada.",
            agentContext: "Cover letter drafted."
        )

        let snapshot = task.toApiResponse()

        // A replayed queued write must reinstate what the USER typed, and must not carry
        // Rem's context — a replay is a re-send of the device's own intent.
        #expect(snapshot.descriptionUser == "Attorney is Ada.")
        #expect(snapshot.descriptionAgent == nil)
    }

    // MARK: - The pull

    @Test func pullMirrorsBothHalvesOntoTheLocalTask() async throws {
        let context = try makeContext()
        let id = UUID()
        let api = TaskApiStub()
        api.remoteTasks = [
            TaskEventApiResponse(
                id: id.uuidString,
                title: "File visa paperwork",
                descriptionUser: "Attorney is Ada.",
                descriptionAgent: "Cover letter drafted; need the receipt number."
            ),
        ]

        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        await service.syncFromBackend()

        let stored = try #require(try context.fetch(FetchDescriptor<TaskEvent>()).first)
        #expect(stored.taskDescription == "Attorney is Ada.")
        #expect(stored.agentContext == "Cover letter drafted; need the receipt number.")
    }

    // MARK: - Create, and erase

    @Test func aDescriptionTypedAtCreateTimeIsSentWithTheTask() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "File visa paperwork", taskDescription: "Attorney is Ada.")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        _ = try await service.syncTaskCreateToBackendImmediately(task)

        // `POST /tasks` has accepted and sanitized `description` all along; the client was
        // building the value and dropping it on the floor.
        #expect(api.createdDescriptions == ["Attorney is Ada."])
    }

    @Test func erasingADescriptionSendsAnExplicitClearRatherThanOmittingTheField() async throws {
        let context = try makeContext()
        // "" is what the editor leaves behind when the user erases a description they had.
        let task = TaskEvent(title: "File visa paperwork", taskDescription: "")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        try await service.syncTaskToBackendImmediately(task)

        // Not `[nil]`. A nil is omitted from the PATCH body, the backend reads the omission
        // as "not edited", and the erased text comes straight back on the next pull.
        #expect(api.updatedDescriptions == [""])
    }

    @Test func aTaskThatNeverHadADescriptionSendsNoClear() async throws {
        let context = try makeContext()
        let task = TaskEvent(title: "File visa paperwork")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        try await service.syncTaskToBackendImmediately(task)

        // The other half of the same distinction: an untouched task must not be able to
        // wipe a description written on another device just by being synced.
        #expect(api.updatedDescriptions == [nil])
    }

    @Test func aLaterRunsContextReplacesTheOneHeldLocally() async throws {
        let context = try makeContext()
        let id = UUID()
        let task = TaskEvent(id: id, title: "File visa paperwork", agentContext: "First state.")
        context.insert(task)
        try context.save()

        let api = TaskApiStub()
        api.remoteTasks = [
            TaskEventApiResponse(id: id.uuidString, title: "File visa paperwork", descriptionAgent: "Second state."),
        ]
        let service = RemTaskSyncService(taskApiService: api, modelContext: context)
        await service.syncFromBackend()

        let stored = try #require(try context.fetch(FetchDescriptor<TaskEvent>()).first)
        #expect(stored.agentContext == "Second state.")
    }
}
