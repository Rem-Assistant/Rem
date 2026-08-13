import Foundation
import SwiftData

/// Pulls Folders + Lists from the backend and upserts them into local SwiftData.
/// Mirrors `TaskSyncManager` (the task-sync pattern): pull → upsert → prune. Called
/// on app launch / refresh alongside the task sync.
@MainActor
final class OrganizationSyncManager {
    private let apiService: OrganizationApiService
    private let modelContext: ModelContext

    init(apiService: OrganizationApiService, modelContext: ModelContext) {
        self.apiService = apiService
        self.modelContext = modelContext
    }

    func syncFromBackend() async {
        do {
            let folders = try await apiService.fetchFolders()
            let lists = try await apiService.fetchLists()
            upsertFolders(folders)
            try upsertLists(lists)
            try modelContext.save()
        } catch {
            print("[OrgSync] Failed to sync organization from backend: \(error.localizedDescription)")
        }
    }

    // MARK: - Folders

    private func upsertFolders(_ responses: [FolderApiResponse]) {
        let existing = (try? modelContext.fetch(FetchDescriptor<TaskFolder>())) ?? []
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var remoteIDs = Set<UUID>()

        for r in responses {
            guard let uuid = UUID(uuidString: r.id) else { continue }
            remoteIDs.insert(uuid)
            if let folder = byID[uuid] {
                folder.name = r.name
                folder.sortOrder = r.sortOrder ?? folder.sortOrder
                if let updated = Self.parseDate(r.updatedAt) { folder.updatedAt = updated }
            } else {
                modelContext.insert(TaskFolder(
                    id: uuid,
                    name: r.name,
                    sortOrder: r.sortOrder ?? 0,
                    createdAt: Self.parseDate(r.createdAt) ?? Date(),
                    updatedAt: Self.parseDate(r.updatedAt) ?? Date()
                ))
            }
        }

        for folder in existing where !remoteIDs.contains(folder.id) {
            modelContext.delete(folder)
        }
    }

    // MARK: - Lists

    private func upsertLists(_ responses: [ListApiResponse]) throws {
        let existing = (try? modelContext.fetch(FetchDescriptor<TaskList>())) ?? []
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var remoteIDs = Set<UUID>()

        for r in responses {
            guard let uuid = UUID(uuidString: r.id) else { continue }
            remoteIDs.insert(uuid)
            let folderUUID = r.folderID.flatMap { UUID(uuidString: $0) }
            if let list = byID[uuid] {
                list.name = r.name
                list.folderID = folderUUID
                list.sortOrder = r.sortOrder ?? list.sortOrder
                if let updated = Self.parseDate(r.updatedAt) { list.updatedAt = updated }
            } else {
                modelContext.insert(TaskList(
                    id: uuid,
                    name: r.name,
                    folderID: folderUUID,
                    sortOrder: r.sortOrder ?? 0,
                    createdAt: Self.parseDate(r.createdAt) ?? Date(),
                    updatedAt: Self.parseDate(r.updatedAt) ?? Date()
                ))
            }
        }

        for list in existing where !remoteIDs.contains(list.id) {
            modelContext.delete(list)
        }

        // A completed Lists pull is authoritative. Backend list deletion unfiles its
        // tasks, so mirror that state in both live rows and durable write snapshots.
        try Self.reconcileDeletedListReferences(
            remoteListIDs: remoteIDs,
            in: modelContext
        )
    }

    static func reconcileDeletedListReferences(
        remoteListIDs: Set<UUID>,
        in modelContext: ModelContext
    ) throws {
        for task in try modelContext.fetch(FetchDescriptor<TaskEvent>()) {
            if let listID = task.listID, !remoteListIDs.contains(listID) {
                task.listID = nil
            }
        }

        for operation in try modelContext.fetch(FetchDescriptor<PendingTaskOperation>())
        where operation.operationType == "create" || operation.operationType == "update" {
            guard let data = operation.taskData,
                  let decoded = try? JSONSerialization.jsonObject(with: data),
                  var object = decoded as? [String: Any],
                  let rawListID = object["list_id"] as? String,
                  let listID = UUID(uuidString: rawListID),
                  !remoteListIDs.contains(listID) else {
                continue
            }
            object["list_id"] = NSNull()
            if let rewritten = try? JSONSerialization.data(withJSONObject: object) {
                operation.taskData = rewritten
            }
        }
    }

    // MARK: - Date parsing (fractional + plain — see CLAUDE.md gotcha)

    private static let isoWithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoWithFrac.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
