import Foundation
import SwiftData

/// Task organization (Sorted-style): a **Folder** groups Lists; a **List** groups Tasks.
///
/// Foundation slice. Both are user-managed and mirror the backend `folders` / `lists`
/// tables (migration 021). The backend is the source of truth; these SwiftData models
/// are the local cache synced via `OrganizationSyncManager` (same pattern as `TaskEvent`).
///
/// `TaskEvent.listID` is the (nullable) link from a task to its List.

// MARK: - Folder

@Model
public final class TaskFolder {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - List

@Model
public final class TaskList {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// The Folder this List is filed under, if any. `nil` = ungrouped.
    public var folderID: UUID?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        folderID: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folderID = folderID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - API responses (mirror backend organization.service.ts row shapes)

public struct FolderApiResponse: Codable, Sendable {
    public let id: String
    public let name: String
    public let sortOrder: Int?
    public let createdAt: String?
    public let updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case id, name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct ListApiResponse: Codable, Sendable {
    public let id: String
    public let name: String
    public let folderID: String?
    public let sortOrder: Int?
    public let createdAt: String?
    public let updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case id, name
        case folderID = "folder_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct FoldersIndexResponse: Codable { let folders: [FolderApiResponse] }
struct ListsIndexResponse: Codable { let lists: [ListApiResponse] }
