import Foundation
import OpenClawKit
import SwiftData

/// Handles the `lists.*` node commands — task organization (Sorted-style).
/// A **List** groups tasks; the agent can list existing Lists and create new ones,
/// then file a task into a List via `tasks.create` / `tasks.update` (`listId`).
///
/// Lists are stored locally in SwiftData (`TaskList`) and persisted to the backend
/// (`/api/v1/lists`) before success is reported. The backend is the source of truth.
@MainActor
enum ListsCommandHandler {

    private static var modelContextProvider: (() -> ModelContext?)?
    private static var organizationApiServiceProvider: (() -> OrganizationApiService?)?

    static func configure(
        modelContext: @escaping @MainActor () -> ModelContext?,
        organizationApiService: @escaping @MainActor () -> OrganizationApiService?
    ) {
        modelContextProvider = modelContext
        organizationApiServiceProvider = organizationApiService
    }

    // MARK: - List

    static func handleList(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "lists are unavailable before app initialization")
        }

        let descriptor = FetchDescriptor<TaskList>(
            sortBy: [SortDescriptor(\TaskList.sortOrder, order: .forward),
                     SortDescriptor(\TaskList.createdAt, order: .forward)]
        )
        do {
            let lists = try modelContext.fetch(descriptor)
            let folders = try modelContext.fetch(FetchDescriptor<TaskFolder>())
            let folderNames = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
            return InvocationHelpers.encodeSuccess(req, ListsListResponse(
                lists: lists.map { payload(from: $0, folderNames: folderNames) },
                total: lists.count
            ))
        } catch {
            return InvocationHelpers.error(req, "failed to load lists")
        }
    }

    // MARK: - Create

    static func handleCreate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?(),
              let organizationApi = organizationApiServiceProvider?() else {
            return InvocationHelpers.unavailable(req, "lists are unavailable before app initialization")
        }
        guard let params: ListsCreateParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "lists.create requires a name")
        }
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return InvocationHelpers.invalidParams(req, "lists.create requires a non-empty name")
        }

        let folderID: UUID?
        if let rawFolderID = params.folderId {
            let trimmed = rawFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = UUID(uuidString: trimmed) else {
                return InvocationHelpers.invalidParams(req, "lists.create requires a valid folder id")
            }
            let descriptor = FetchDescriptor<TaskFolder>(predicate: #Predicate { $0.id == parsed })
            guard (try? modelContext.fetch(descriptor).first) != nil else {
                return InvocationHelpers.invalidParams(req, "FOLDER_NOT_FOUND")
            }
            folderID = parsed
        } else {
            folderID = nil
        }
        let listID = InvocationHelpers.stableResourceID(for: req, namespace: RemListsCommand.create.rawValue)
        let listDescriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        let list: TaskList
        do {
            let remote = try await organizationApi.createList(
                id: listID.uuidString,
                name: name,
                folderID: folderID?.uuidString
            )
            let canonicalFolderID = remote.folderID.flatMap(UUID.init(uuidString:))
            if let existing = try modelContext.fetch(listDescriptor).first {
                list = existing
                list.name = remote.name
                list.folderID = canonicalFolderID
                list.sortOrder = remote.sortOrder ?? list.sortOrder
                list.updatedAt = InvocationHelpers.parseISODate(remote.updatedAt) ?? list.updatedAt
            } else {
                list = TaskList(
                    id: listID,
                    name: remote.name,
                    folderID: canonicalFolderID,
                    sortOrder: remote.sortOrder ?? 0,
                    createdAt: InvocationHelpers.parseISODate(remote.createdAt) ?? Date(),
                    updatedAt: InvocationHelpers.parseISODate(remote.updatedAt) ?? Date()
                )
                modelContext.insert(list)
            }
            try modelContext.save()
        } catch {
            return InvocationHelpers.error(req, "failed to create list")
        }

        let folderNames: [UUID: String]
        do {
            folderNames = Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<TaskFolder>()).map { ($0.id, $0.name) }
            )
        } catch {
            return InvocationHelpers.error(req, "failed to load list organization")
        }
        return InvocationHelpers.encodeSuccess(req, ListsCreateResponse(
            list: payload(from: list, folderNames: folderNames)
        ))
    }

    // MARK: - Payload

    private static func payload(from list: TaskList, folderNames: [UUID: String]) -> ListPayload {
        ListPayload(
            id: list.id.uuidString,
            name: list.name,
            folderId: list.folderID?.uuidString,
            folderName: list.folderID.flatMap { folderNames[$0] },
            createdAt: InvocationHelpers.formatISODate(list.createdAt) ?? "",
            updatedAt: InvocationHelpers.formatISODate(list.updatedAt) ?? ""
        )
    }
}
