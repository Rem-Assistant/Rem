import Foundation

/// Real HTTP client that talks to the RemClaw Express backend.
/// Calls /api/v1/tasks/* endpoints with JWT authentication.
@MainActor
final class RemTaskApiService: TaskApiServiceProtocol, ScopedSuggestionTaskApiServiceProtocol {
    private let decoder = JSONDecoder()
    // NOTE: Do NOT use .convertFromSnakeCase — it conflicts with
    // TaskEventApiResponse's explicit CodingKeys (e.g. startDate = "start_date"),
    // causing all snake_case fields to silently decode as nil.

    private var tasksPath: String { "/api/v1/tasks" }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func dateToISO(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.iso8601.string(from: date)
    }

    // MARK: - TaskApiServiceProtocol

    func saveTaskToBackend(
        id: String? = nil,
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
        try await saveTaskToBackend(
            id: id,
            title: title,
            priority: priority,
            status: status,
            startDate: startDate,
            endDate: endDate,
            durationMinutes: durationMinutes,
            alertTime: alertTime,
            repeatFrequency: repeatFrequency,
            description: description,
            listID: listID,
            authority: nil
        )
    }

    func saveTaskToBackend(
        id: String,
        title: String,
        priority: String,
        status: String,
        startDate: Date?,
        endDate: Date?,
        durationMinutes: Int?,
        alertTime: Date?,
        repeatFrequency: String?,
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async throws -> TaskEventApiResponse {
        try await saveTaskToBackend(
            id: id,
            title: title,
            priority: priority,
            status: status,
            startDate: startDate,
            endDate: endDate,
            durationMinutes: durationMinutes,
            alertTime: alertTime,
            repeatFrequency: repeatFrequency,
            description: nil,
            listID: nil,
            authority: Optional(authority)
        )
    }

    private func saveTaskToBackend(
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
        listID: String?,
        authority: AuthenticatedHttpClient.RequestAuthority?
    ) async throws -> TaskEventApiResponse {
        var payload: [String: Any] = [
            "title": title,
            "priority": priority,
            "status": status,
        ]
        if let id { payload["id"] = id }
        if let sd = dateToISO(startDate) { payload["start_date"] = sd }
        if let ed = dateToISO(endDate) { payload["end_date"] = ed }
        if let dm = durationMinutes { payload["duration_minutes"] = dm }
        if let at = dateToISO(alertTime) { payload["alert_time"] = at }
        if let rf = repeatFrequency { payload["repeat_frequency"] = rf }
        // A description typed in the create sheet is persisted WITH the task (backend
        // `POST /tasks` sanitizes it in the same statement). Without this the value was
        // constructed locally and silently dropped on the way to the server.
        if let d = description, !d.isEmpty { payload["description"] = d }
        if let listID { payload["list_id"] = listID }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = if let authority {
            try await AuthenticatedHttpClient.request(
                path: tasksPath, method: "POST", body: body, authority: authority
            )
        } else {
            try await AuthenticatedHttpClient.request(path: tasksPath, method: "POST", body: body)
        }
        try checkResponse(http, data: data)
        return try decoder.decode(TaskEventApiResponse.self, from: data)
    }

    func saveEventToBackend(
        id: String? = nil,
        title: String,
        dateTime: String,
        durationMinutes: Int,
        listID: String?
    ) async throws -> TaskEventApiResponse {
        var payload: [String: Any] = [
            "type": "calendar_event",
            "title": title,
            "date_time": dateTime,
            "duration_minutes": durationMinutes,
        ]
        if let id { payload["id"] = id }
        if let listID { payload["list_id"] = listID }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: tasksPath, method: "POST", body: body
        )
        try checkResponse(http, data: data)
        return try decoder.decode(TaskEventApiResponse.self, from: data)
    }

    func fetchTasks() async throws -> [TaskEventApiResponse] {
        try await Self.collectAllTaskPages { limit, offset in
            try await self.fetchTasksPage(limit: limit, offset: offset, since: nil)
        }
    }

    func fetchTaskDeletions() async throws -> [TaskDeletionApiResponse] {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "\(tasksPath)/deletions", method: "GET"
        )
        // Backward-compatible rollout: an older backend routes this path through
        // GET /tasks/:id and rejects `deletions` as a non-UUID. Do not mask any other
        // server error; once the route exists, tombstone failures must fail hydration.
        let errorMessage = (try? decoder.decode([String: String].self, from: data))?["error"]
        if http.statusCode == 404
            || (http.statusCode == 500
                && errorMessage?.contains("invalid input syntax for type uuid") == true
                && errorMessage?.contains("deletions") == true) {
            return []
        }
        try checkResponse(http, data: data)
        return try decoder.decode(TaskDeletionsEnvelope.self, from: data).deletions
    }

    private func fetchTasksPage(limit: Int, offset: Int, since: Date?) async throws -> PaginatedTasksResponse {
        var path = "\(tasksPath)?limit=\(limit)&offset=\(offset)"
        if let since {
            let isoString = Self.iso8601.string(from: since)
            path += "&since=\(isoString)"
        }
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: path, method: "GET"
        )
        try checkResponse(http, data: data)
        return try decoder.decode(PaginatedTasksResponse.self, from: data)
    }

    /// Fetch every visible page so hydration is not silently capped at 200 tasks.
    /// Reconciliation remains non-destructive because offset pages are not a deletion snapshot.
    static func collectAllTaskPages(
        pageSize: Int = 200,
        fetchPage: (_ limit: Int, _ offset: Int) async throws -> PaginatedTasksResponse
    ) async throws -> [TaskEventApiResponse] {
        var tasks: [TaskEventApiResponse] = []
        var offset = 0

        while true {
            let page = try await fetchPage(pageSize, offset)
            tasks.append(contentsOf: page.tasks)

            guard page.pagination.hasMore else { return tasks }
            guard !page.tasks.isEmpty else { throw RemApiError.invalidResponse }
            offset += page.tasks.count
        }
    }

    func getTask(id: String) async throws -> TaskEventApiResponse {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "\(tasksPath)/\(id)", method: "GET"
        )
        try checkResponse(http, data: data)
        return try decoder.decode(TaskEventApiResponse.self, from: data)
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
        try await updateTask(
            id: id,
            title: title,
            priority: priority,
            status: status,
            startDate: startDate,
            endDate: endDate,
            durationMinutes: durationMinutes,
            alertTime: alertTime,
            repeatFrequency: repeatFrequency,
            description: description,
            listID: listID,
            includeListID: includeListID,
            includeClearedFields: includeClearedFields,
            authority: nil
        )
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
        authority: AuthenticatedHttpClient.RequestAuthority
    ) async throws -> TaskEventApiResponse {
        try await updateTask(
            id: id,
            title: title,
            priority: priority,
            status: status,
            startDate: startDate,
            endDate: endDate,
            durationMinutes: durationMinutes,
            alertTime: alertTime,
            repeatFrequency: repeatFrequency,
            description: nil,
            listID: nil,
            includeListID: false,
            includeClearedFields: false,
            authority: Optional(authority)
        )
    }

    private func updateTask(
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
        includeClearedFields: Bool,
        authority: AuthenticatedHttpClient.RequestAuthority?
    ) async throws -> TaskEventApiResponse {
        var payload: [String: Any] = [:]
        if let t = title { payload["title"] = t }
        if let p = priority { payload["priority"] = p }
        if let s = status { payload["status"] = s }
        if let sd = dateToISO(startDate) { payload["start_date"] = sd }
        else if includeClearedFields { payload["start_date"] = NSNull() }
        if let ed = dateToISO(endDate) { payload["end_date"] = ed }
        else if includeClearedFields { payload["end_date"] = NSNull() }
        if let dm = durationMinutes { payload["duration_minutes"] = dm }
        else if includeClearedFields { payload["duration_minutes"] = NSNull() }
        if let at = dateToISO(alertTime) { payload["alert_time"] = at }
        else if includeClearedFields { payload["alert_time"] = NSNull() }
        if let rf = repeatFrequency { payload["repeat_frequency"] = rf }
        else if includeClearedFields { payload["repeat_frequency"] = NSNull() }
        if includeListID { payload["list_id"] = listID ?? NSNull() }
        // The USER's half of the co-authored description (backend migration 120).
        //   nil → key omitted   → backend leaves the user's half alone ("not edited").
        //   ""  → key sent empty → backend CLEARS the user's half; Rem's block survives.
        // Both branches are reachable from the editor: `TaskEventViewModel` keeps ""
        // (rather than collapsing it to nil) when the user erases a description they
        // actually had, so the erase reaches the backend instead of being undone by the
        // next pull. Deliberately NOT part of `includeClearedFields` — a task the device
        // has no description for must not be able to blank one written elsewhere.
        if let d = description { payload["description"] = d }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = if let authority {
            try await AuthenticatedHttpClient.request(
                path: "\(tasksPath)/\(id)", method: "PATCH", body: body, authority: authority
            )
        } else {
            try await AuthenticatedHttpClient.request(
                path: "\(tasksPath)/\(id)", method: "PATCH", body: body
            )
        }
        try checkResponse(http, data: data)
        return try decoder.decode(TaskEventApiResponse.self, from: data)
    }

    func deleteTask(id: String) async throws {
        let (_, http) = try await AuthenticatedHttpClient.request(
            path: "\(tasksPath)/\(id)", method: "DELETE"
        )
        // DELETE is idempotent for queue replay. A 404 means the desired state already holds
        // (including an offline create that never reached the backend).
        guard (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            throw RemApiError.requestFailed(statusCode: http.statusCode)
        }
    }

    func ensureEventBacking(
        calendarEventID: String,
        title: String,
        startDate: Date?,
        durationMinutes: Int?,
        listID: String?
    ) async throws -> TaskEventApiResponse {
        var payload: [String: Any] = [
            "calendar_event_id": calendarEventID,
            "title": title,
        ]
        if let sd = dateToISO(startDate) { payload["start_date"] = sd }
        if let dm = durationMinutes { payload["duration_minutes"] = dm }
        if let listID { payload["list_id"] = listID }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "\(tasksPath)/event-backing", method: "POST", body: body
        )
        try checkResponse(http, data: data)
        return try decoder.decode(TaskEventApiResponse.self, from: data)
    }

    // MARK: - Helpers

    private func checkResponse(_ response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw RemApiError.requestFailed(statusCode: response.statusCode, message: message)
        }
    }
}

private struct TaskDeletionsEnvelope: Decodable {
    let deletions: [TaskDeletionApiResponse]
}

// MARK: - Paginated Response

struct PaginatedTasksResponse: Codable {
    let tasks: [TaskEventApiResponse]
    let pagination: PaginationMeta

    struct PaginationMeta: Codable {
        let total: Int
        let limit: Int
        let offset: Int
        let hasMore: Bool
    }
}

enum RemApiError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String? = nil)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid server response"
        case .requestFailed(let code, let msg): msg ?? "Request failed (HTTP \(code))"
        }
    }
}
