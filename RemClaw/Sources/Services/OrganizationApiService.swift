import Foundation

/// HTTP client for task organization (Folders + Lists) against the Express backend.
/// Calls `/api/v1/folders/*` and `/api/v1/lists/*` with JWT auth — mirrors
/// `RemTaskApiService`. Assigning a task to a list is a PATCH on the tasks route.
@MainActor
final class OrganizationApiService {
    private let decoder = JSONDecoder()

    private var foldersPath: String { "/api/v1/folders" }
    private var listsPath: String { "/api/v1/lists" }
    private var tasksPath: String { "/api/v1/tasks" }

    // MARK: - Folders

    func fetchFolders() async throws -> [FolderApiResponse] {
        let (data, http) = try await AuthenticatedHttpClient.request(path: foldersPath, method: "GET")
        try checkResponse(http, data: data)
        return try decoder.decode(FoldersIndexResponse.self, from: data).folders
    }

    @discardableResult
    func createFolder(id: String?, name: String, sortOrder: Int = 0) async throws -> FolderApiResponse {
        var payload: [String: Any] = ["name": name, "sort_order": sortOrder]
        if let id { payload["id"] = id }
        let body = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, http) = try await AuthenticatedHttpClient.request(path: foldersPath, method: "POST", body: body)
            try checkResponse(http, data: data)
            return try decoder.decode(FolderApiResponse.self, from: data)
        } catch {
            let createError = error
            if let id,
               let requestedID = UUID(uuidString: id),
               let existing = (try? await fetchFolders())?.first(where: {
                   UUID(uuidString: $0.id) == requestedID
               }) {
                return existing
            }
            throw createError
        }
    }

    func deleteFolder(id: String) async throws {
        let (_, http) = try await AuthenticatedHttpClient.request(path: "\(foldersPath)/\(id)", method: "DELETE")
        guard (200...299).contains(http.statusCode) else {
            throw RemApiError.requestFailed(statusCode: http.statusCode)
        }
    }

    // MARK: - Lists

    func fetchLists() async throws -> [ListApiResponse] {
        let (data, http) = try await AuthenticatedHttpClient.request(path: listsPath, method: "GET")
        try checkResponse(http, data: data)
        return try decoder.decode(ListsIndexResponse.self, from: data).lists
    }

    @discardableResult
    func createList(id: String?, name: String, folderID: String?, sortOrder: Int = 0) async throws -> ListApiResponse {
        var payload: [String: Any] = ["name": name, "sort_order": sortOrder]
        if let id { payload["id"] = id }
        if let folderID { payload["folder_id"] = folderID }
        let body = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, http) = try await AuthenticatedHttpClient.request(path: listsPath, method: "POST", body: body)
            try checkResponse(http, data: data)
            return try decoder.decode(ListApiResponse.self, from: data)
        } catch {
            let createError = error
            if let id,
               let requestedID = UUID(uuidString: id),
               let existing = (try? await fetchLists())?.first(where: {
                   UUID(uuidString: $0.id) == requestedID
               }) {
                return existing
            }
            throw createError
        }
    }

    func deleteList(id: String) async throws {
        let (_, http) = try await AuthenticatedHttpClient.request(path: "\(listsPath)/\(id)", method: "DELETE")
        guard (200...299).contains(http.statusCode) else {
            throw RemApiError.requestFailed(statusCode: http.statusCode)
        }
    }

    // MARK: - Assign a task to a list

    /// Files (or un-files, when `listID` is nil) a task into a List via the tasks route.
    func assignTask(taskID: String, toListID listID: String?) async throws {
        // JSONSerialization can't encode Swift `nil`; use NSNull to send JSON null (unfile).
        let payload: [String: Any] = ["list_id": listID ?? NSNull()]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "\(tasksPath)/\(taskID)", method: "PATCH", body: body
        )
        try checkResponse(http, data: data)
    }

    // MARK: - Helpers

    private func checkResponse(_ response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw RemApiError.requestFailed(statusCode: response.statusCode, message: message)
        }
    }
}
