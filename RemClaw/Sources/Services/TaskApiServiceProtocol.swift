import Foundation

public struct TaskEventApiResponse: Codable, Sendable {
    public let id: String
    public let title: String
    public let status: String?
    public let priority: String?
    public let startDate: String?
    public let endDate: String?
    public let durationMinutes: Int?
    public let alertTime: String?
    public let repeatFrequency: String?
    public let type: String?
    public let listID: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let calendarEventID: String?
    // Structured agent run-state (backend migration 019, serialized by `formatTask`).
    // Lets the task views show "being worked right now" / "needs attention" without
    // parsing a comment body. DISTINCT from `status` — see `TaskRunStatus`.
    /// One of `running`/`review`/`blocked`/`done`/`idle`, or nil if no run touched it.
    public let runStatus: String?
    /// Identifier for the current/last run; correlates the task with its run comment.
    public let runId: String?
    /// Live session handle (Workboard's card→session duality). Reserved for the
    /// "Open conversation" jump; nil for cloud-agent dispatch (no live session).
    public let sessionKey: String?
    /// ISO-8601 timestamp of when the current/last run started.
    public let runStartedAt: String?
    /// Backend `tasks.stale_at` (migration 116), ISO-8601. Non-nil ⟺ the brief surfaced this task
    /// `BRIEF_STALE_THRESHOLD` times with no user action and stopped asking.
    ///
    /// Carried ALONGSIDE `status`, never folded into it: a task can be `blocked` AND stale, and a
    /// `'stale'` status would decode to `.todo` here (`TaskEvent.statusFromBackend` ends in a
    /// `?? .todo` fallback) while the backend believed the phone had been told.
    public let staleAt: String?
    // The CO-AUTHORED description (backend migration 120) — "what I know NOW", as
    // opposed to the Activity thread, which logs what happened each run.
    //
    // The backend stores ONE column and serializes it three ways so the block delimiter
    // that separates the two authors is parsed in exactly one place (its
    // `task-description.ts`) and never re-implemented here — two parsers is how the two
    // would drift.
    /// The whole stored column, both halves. For display of the complete picture.
    public let taskDescription: String?
    /// The half the USER wrote. This is what a text editor binds to, and the value to
    /// send back as `description` on a PATCH — the backend preserves Rem's half.
    public let descriptionUser: String?
    /// The half REM maintains: the current state the last run recorded. Read-only on the
    /// client; a user edit can never overwrite it and it can never overwrite a user edit.
    public let descriptionAgent: String?

    public init(
        id: String,
        title: String,
        status: String? = nil,
        priority: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        durationMinutes: Int? = nil,
        alertTime: String? = nil,
        repeatFrequency: String? = nil,
        type: String? = nil,
        listID: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        calendarEventID: String? = nil,
        runStatus: String? = nil,
        runId: String? = nil,
        sessionKey: String? = nil,
        runStartedAt: String? = nil,
        staleAt: String? = nil,
        taskDescription: String? = nil,
        descriptionUser: String? = nil,
        descriptionAgent: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.startDate = startDate
        self.endDate = endDate
        self.durationMinutes = durationMinutes
        self.alertTime = alertTime
        self.repeatFrequency = repeatFrequency
        self.type = type
        self.listID = listID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.calendarEventID = calendarEventID
        self.runStatus = runStatus
        self.runId = runId
        self.sessionKey = sessionKey
        self.runStartedAt = runStartedAt
        self.staleAt = staleAt
        self.taskDescription = taskDescription
        self.descriptionUser = descriptionUser
        self.descriptionAgent = descriptionAgent
    }

    public enum CodingKeys: String, CodingKey {
        case id, title, status, priority, type
        // `description` is spelled out because the decoder does NOT use
        // `.convertFromSnakeCase` (see RemTaskApiService), and because a Swift property
        // literally named `description` collides with `CustomStringConvertible`.
        case taskDescription = "description"
        case descriptionUser = "description_user"
        case descriptionAgent = "description_agent"
        case startDate = "start_date"
        case endDate = "end_date"
        case durationMinutes = "duration_minutes"
        case alertTime = "alert_time"
        case repeatFrequency = "repeat_frequency"
        case listID = "list_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case calendarEventID = "calendar_event_id"
        case runStatus = "run_status"
        case runId = "run_id"
        case sessionKey = "session_key"
        case runStartedAt = "run_started_at"
        case staleAt = "stale_at"
    }
}

public struct TaskDeletionApiResponse: Codable, Sendable {
    public let taskID: String
    public let deletedAt: String

    public init(taskID: String, deletedAt: String) {
        self.taskID = taskID
        self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case deletedAt = "deleted_at"
    }
}

@MainActor
public protocol TaskApiServiceProtocol {
    /// `description` is the USER's half of the co-authored description (backend
    /// migration 120). `POST /tasks` sanitizes and stores it in the same statement as the
    /// rest of the task, so a description typed in the create sheet is persisted with the
    /// task rather than silently dropped and left to a follow-up PATCH that may never happen.
    func saveTaskToBackend(id: String?, title: String, priority: String, status: String, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?) async throws -> TaskEventApiResponse
    func saveEventToBackend(id: String?, title: String, dateTime: String, durationMinutes: Int, listID: String?) async throws -> TaskEventApiResponse
    func fetchTasks() async throws -> [TaskEventApiResponse]
    func fetchTaskDeletions() async throws -> [TaskDeletionApiResponse]
    func getTask(id: String) async throws -> TaskEventApiResponse
    /// `description` here means the USER's half of the co-authored description (backend
    /// migration 120). The backend merges it with Rem's block rather than replacing the
    /// column, so sending it can never clobber what a run recorded.
    ///
    /// `nil` and `""` are DIFFERENT and both reachable:
    ///   nil → omit the key entirely → the backend leaves the user's half alone.
    ///   ""  → send an empty string → the backend CLEARS the user's half (Rem's block
    ///         survives). This is how erasing a description actually propagates; without
    ///         it the old text reappears on the next pull.
    func updateTask(id: String, title: String?, priority: String?, status: String?, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, description: String?, listID: String?, includeListID: Bool, includeClearedFields: Bool) async throws -> TaskEventApiResponse
    func deleteTask(id: String) async throws

    /// Find-or-create the lightweight **backing task** that lets a calendar event carry
    /// an Activity thread + agent runs (backend `POST /tasks/event-backing`, migration
    /// 024). Idempotent on `calendarEventID`, so repeated "Run now" on the same event
    /// reuses one row. Returns the backing task; its `id` is the activity task id.
    func ensureEventBacking(calendarEventID: String, title: String, startDate: Date?, durationMinutes: Int?, listID: String?) async throws -> TaskEventApiResponse
}

public extension TaskApiServiceProtocol {
    func fetchTaskDeletions() async throws -> [TaskDeletionApiResponse] { [] }

    func saveTaskToBackend(id: String?, title: String, priority: String, status: String, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?) async throws -> TaskEventApiResponse {
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
            listID: nil
        )
    }

    /// Pre-description call sites keep compiling: omitting `description` sends no key.
    func saveTaskToBackend(id: String?, title: String, priority: String, status: String, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?, listID: String?) async throws -> TaskEventApiResponse {
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
            listID: listID
        )
    }

    func saveEventToBackend(id: String?, title: String, dateTime: String, durationMinutes: Int) async throws -> TaskEventApiResponse {
        try await saveEventToBackend(
            id: id,
            title: title,
            dateTime: dateTime,
            durationMinutes: durationMinutes,
            listID: nil
        )
    }

    func updateTask(id: String, title: String?, priority: String?, status: String?, startDate: Date?, endDate: Date?, durationMinutes: Int?, alertTime: Date?, repeatFrequency: String?) async throws -> TaskEventApiResponse {
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
            includeClearedFields: false
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
        listID: String?,
        includeListID: Bool
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
            listID: listID,
            includeListID: includeListID,
            includeClearedFields: false
        )
    }

    /// Pre-description call sites keep compiling unchanged: omitting `description` sends
    /// no `description` key at all, which the backend reads as "the user did not edit
    /// their half" — never as "clear it".
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
            description: nil,
            listID: listID,
            includeListID: includeListID,
            includeClearedFields: includeClearedFields
        )
    }
}

/// Narrow API used by suggestion acceptance. Its immutable request authority ensures an actor hop
/// or account switch cannot replace the credentials between the tap-time scope check and the write.
@MainActor
protocol ScopedSuggestionTaskApiServiceProtocol {
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
    ) async throws -> TaskEventApiResponse

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
    ) async throws -> TaskEventApiResponse
}
