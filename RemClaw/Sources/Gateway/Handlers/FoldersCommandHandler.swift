import Foundation
import OpenClawKit
import SwiftData

/// Handles the top-level `folders.*` task-organization commands. Folders group
/// Lists; exposing them to the agent keeps its organization model aligned with
/// the same hierarchy the human sees in Rem.
@MainActor
enum FoldersCommandHandler {
    private static var modelContextProvider: (() -> ModelContext?)?
    private static var organizationApiServiceProvider: (() -> OrganizationApiService?)?

    static func configure(
        modelContext: @escaping @MainActor () -> ModelContext?,
        organizationApiService: @escaping @MainActor () -> OrganizationApiService?
    ) {
        modelContextProvider = modelContext
        organizationApiServiceProvider = organizationApiService
    }

    static func handleList(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "folders are unavailable before app initialization")
        }

        let descriptor = FetchDescriptor<TaskFolder>(
            sortBy: [
                SortDescriptor(\TaskFolder.sortOrder, order: .forward),
                SortDescriptor(\TaskFolder.createdAt, order: .forward),
            ]
        )
        do {
            let folders = try modelContext.fetch(descriptor)
            return InvocationHelpers.encodeSuccess(req, FoldersListResponse(
                folders: folders.map(payload(from:)),
                total: folders.count
            ))
        } catch {
            return InvocationHelpers.error(req, "failed to load folders")
        }
    }

    static func handleCreate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?(),
              let organizationApi = organizationApiServiceProvider?() else {
            return InvocationHelpers.unavailable(req, "folders are unavailable before app initialization")
        }
        guard let params: FoldersCreateParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "folders.create requires a name")
        }
        let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return InvocationHelpers.invalidParams(req, "folders.create requires a non-empty name")
        }

        let folderID = InvocationHelpers.stableResourceID(for: req, namespace: RemFoldersCommand.create.rawValue)
        let descriptor = FetchDescriptor<TaskFolder>(predicate: #Predicate { $0.id == folderID })
        let folder: TaskFolder
        do {
            let remote = try await organizationApi.createFolder(
                id: folderID.uuidString,
                name: name
            )
            if let existing = try modelContext.fetch(descriptor).first {
                folder = existing
                folder.name = remote.name
                folder.sortOrder = remote.sortOrder ?? folder.sortOrder
                folder.updatedAt = InvocationHelpers.parseISODate(remote.updatedAt) ?? folder.updatedAt
            } else {
                folder = TaskFolder(
                    id: folderID,
                    name: remote.name,
                    sortOrder: remote.sortOrder ?? 0,
                    createdAt: InvocationHelpers.parseISODate(remote.createdAt) ?? Date(),
                    updatedAt: InvocationHelpers.parseISODate(remote.updatedAt) ?? Date()
                )
                modelContext.insert(folder)
            }
            try modelContext.save()
        } catch {
            return InvocationHelpers.error(req, "failed to create folder")
        }

        return InvocationHelpers.encodeSuccess(req, FoldersCreateResponse(folder: payload(from: folder)))
    }

    private static func payload(from folder: TaskFolder) -> FolderPayload {
        FolderPayload(
            id: folder.id.uuidString,
            name: folder.name,
            createdAt: InvocationHelpers.formatISODate(folder.createdAt) ?? "",
            updatedAt: InvocationHelpers.formatISODate(folder.updatedAt) ?? ""
        )
    }
}
