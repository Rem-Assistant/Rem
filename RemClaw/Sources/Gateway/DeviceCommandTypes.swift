import Foundation

// MARK: - Command enums for capabilities not yet in OpenClawKit
// These mirror the convention used by OpenClawKit's existing command enums.

enum RemCalendarCommand: String {
    case events = "calendar.events"
    case add = "calendar.add"
    case update = "calendar.update"
    case delete = "calendar.delete"
}

enum RemRemindersCommand: String {
    case list = "reminders.list"
    case add = "reminders.add"
    case update = "reminders.update"
    case delete = "reminders.delete"
}

enum RemDeviceCommand: String {
    case status = "device.status"
    case info = "device.info"
}

enum RemTasksCommand: String {
    case list = "tasks.list"
    case get = "tasks.get"
    case search = "tasks.search"
    case create = "tasks.create"
    case update = "tasks.update"
    case delete = "tasks.delete"
}

enum RemListsCommand: String {
    case list = "lists.list"
    case create = "lists.create"
}

enum RemFoldersCommand: String {
    case list = "folders.list"
    case create = "folders.create"
}

// MARK: - Calendar command params/payloads

struct CalendarEventsParams: Codable, Sendable {
    var startDate: String?
    var endDate: String?
    var calendarId: String?
    var limit: Int?
}

struct CalendarAddParams: Codable, Sendable {
    var title: String
    var startDate: String
    var endDate: String?
    var durationMinutes: Int?
    var notes: String?
    var calendarName: String?
    var isAllDay: Bool?
}

// CalendarEventPayload and CalendarEventsResponse are defined in
// Shared/Models/ToolResultPayloads.swift so the chat tool-result cards in
// Shared/Views/Chat/ToolResultCards/ can render them on both platforms.

struct CalendarAddResponse: Codable, Sendable {
    var eventId: String
    var title: String?
}

struct CalendarUpdateParams: Codable, Sendable {
    var eventId: String
    var title: String?
    var startDate: String?
    var endDate: String?
    var durationMinutes: Int?
    var notes: String?
    var calendarName: String?
    var isAllDay: Bool?
}

struct CalendarUpdateResponse: Codable, Sendable {
    var eventId: String
    var title: String?
}

struct CalendarDeleteParams: Codable, Sendable {
    var eventId: String
}

struct CalendarDeleteResponse: Codable, Sendable {
    var deleted: Bool
    var eventId: String
    var title: String?
}

// MARK: - Reminders command params/payloads

struct RemindersListParams: Codable, Sendable {
    var listName: String?
    var includeCompleted: Bool?
    var limit: Int?
}

struct RemindersAddParams: Codable, Sendable {
    var title: String
    var dueDate: String?
    var notes: String?
    var listName: String?
    var priority: Int?
}

// ReminderPayload and RemindersListResponse are defined in
// Shared/Models/ToolResultPayloads.swift (see note on CalendarEventPayload above).

struct RemindersAddResponse: Codable, Sendable {
    var identifier: String
    var title: String?
}

struct RemindersUpdateParams: Codable, Sendable {
    var identifier: String
    var title: String?
    var dueDate: String?
    var notes: String?
    var isCompleted: Bool?
    var priority: Int?
    var listName: String?
}

struct RemindersUpdateResponse: Codable, Sendable {
    var identifier: String
    var title: String?
}

struct RemindersDeleteParams: Codable, Sendable {
    var identifier: String
}

struct RemindersDeleteResponse: Codable, Sendable {
    var deleted: Bool
    var identifier: String
    var title: String?
}

// MARK: - Device command payloads
//
// DeviceStatusPayload, DeviceInfoPayload, and DeviceProcessInfo are defined in
// Shared/Models/ToolResultPayloads.swift (see note on CalendarEventPayload above).

// MARK: - Task command params/payloads

struct TasksListParams: Codable, Sendable {
    var limit: Int?
    var offset: Int?
    var status: String?
    var type: String?
    var since: String?
}

struct TasksGetParams: Codable, Sendable {
    var id: String
}

/// Resolve a task by NAME. `tasks.get` needs a UUID, and the only identifier that
/// survives into brief prose is the title (`renderBucket` in
/// `backend/src/services/brief-authoring.service.ts` interpolates `it.title` and
/// nothing else, and `chat.inject` carries no metadata) — so without this the agent
/// is handed a name it has no way to look up. See `TasksCommandHandler.handleSearch`.
struct TasksSearchParams: Codable, Sendable {
    /// Free text matched against task titles. Matching is fuzzy: the brief's author
    /// model may reword a title, and `inlineTitle` truncates at 120 chars.
    var query: String
    var limit: Int?
    /// Same vocabulary as `TasksListParams.status` (nil = every status).
    var status: String?
    /// "task" or "calendar_event" (nil = both).
    var type: String?
}

struct TasksCreateParams: Codable, Sendable {
    var title: String
    var priority: String?
    var status: String?
    var startDate: String?
    var endDate: String?
    var durationMinutes: Int?
    var alertTime: String?
    var repeatFrequency: String?
    var type: String?
    var notes: String?
    var isAnyTime: Bool?
    /// Alias for startDate — AI hook documents this as "dueDate"
    var dueDate: String?
    /// Organization: file the new task into a List (Sorted-style). Accepts a list id.
    var listId: String?

    /// Resolved start date: prefers startDate, falls back to dueDate
    var resolvedStartDate: String? { startDate ?? dueDate }
}

struct TasksUpdateParams: Codable, Sendable {
    var id: String
    var title: String?
    var priority: String?
    var status: String?
    /// Convenience alias advertised to the agent contract. `true` completes the task;
    /// `false` moves it back to pending.
    var completed: Bool?
    var startDate: String?
    var endDate: String?
    var durationMinutes: Int?
    var alertTime: String?
    var repeatFrequency: String?
    var type: String?
    /// Alias for startDate
    var dueDate: String?
    var notes: String?
    var isAnyTime: Bool?
    /// Organization: move the task into a List (Sorted-style). Accepts a list id.
    var listId: String?
}

struct TasksDeleteParams: Codable, Sendable {
    var id: String
}

struct TaskPayload: Codable, Sendable {
    var id: String
    var title: String
    var priority: String
    var status: String
    var startDate: String?
    var endDate: String?
    var durationMinutes: Int?
    var alertTime: String?
    var repeatFrequency: String?
    var type: String
    var notes: String?
    var isAnyTime: Bool
    var listId: String?
    var listName: String?
    var folderId: String?
    var folderName: String?
    var calendarEventID: String?
    /// Agent-run state, distinct from `status` (the human-facing task state).
    /// The daily brief's "🔴 Blocked" bucket is driven by this column, NOT by
    /// `status` (`backend/src/services/brief.service.ts` buckets on
    /// `run_status === 'blocked'`), so an agent that can only see `status` cannot
    /// account for a line in a brief it is being asked about.
    var runStatus: String?
    var runId: String?
    /// The chat session the run for this task happened in — what links a task to the
    /// conversation where an agent worked it.
    var sessionKey: String?
    var createdAt: String
    var updatedAt: String
}

// MARK: - List (organization) command params/payloads

struct ListsListParams: Codable, Sendable {}

struct ListsCreateParams: Codable, Sendable {
    var name: String
    /// Optional Folder to file the new List under (Sorted-style). Accepts a folder id.
    var folderId: String?
}

struct ListPayload: Codable, Sendable {
    var id: String
    var name: String
    var folderId: String?
    var folderName: String?
    var createdAt: String
    var updatedAt: String
}

struct ListsListResponse: Codable, Sendable {
    var lists: [ListPayload]
    var total: Int
}

struct ListsCreateResponse: Codable, Sendable {
    var list: ListPayload
}

// MARK: - Folder (organization) command params/payloads

struct FoldersListParams: Codable, Sendable {}

struct FoldersCreateParams: Codable, Sendable {
    var name: String
}

struct FolderPayload: Codable, Sendable {
    var id: String
    var name: String
    var createdAt: String
    var updatedAt: String
}

struct FoldersListResponse: Codable, Sendable {
    var folders: [FolderPayload]
    var total: Int
}

struct FoldersCreateResponse: Codable, Sendable {
    var folder: FolderPayload
}

struct TasksListResponse: Codable, Sendable {
    var tasks: [TaskPayload]
    var total: Int
    var limit: Int
    var offset: Int
    var hasMore: Bool
}

struct TasksGetResponse: Codable, Sendable {
    var task: TaskPayload
}

/// A search hit. Deliberately NARROWER than `TaskPayload`: it carries identity and
/// run state but **not** `notes`. Two reasons, both deliberate:
///  1. Privacy — a name lookup should not spill free-text note bodies.
///  2. Prompt-injection surface — notes are untrusted text (user-pasted and
///     model-written). Search results can reach an unattended turn, so the search
///     path neither matches against nor returns them. The agent can call
///     `tasks.get` with the returned `id` when it genuinely needs full detail.
struct TaskSearchPayload: Codable, Sendable {
    var id: String
    var title: String
    var status: String
    var priority: String
    var runStatus: String?
    var runId: String?
    var sessionKey: String?
    var type: String
    var startDate: String?
    var listName: String?
    var folderName: String?
    var createdAt: String
    var updatedAt: String
}

struct TaskSearchMatch: Codable, Sendable {
    var task: TaskSearchPayload
    /// 0…1. 1.0 = exact title match after normalization.
    var score: Double
    /// How the hit was made: "exact" | "prefix" | "contains" | "tokens".
    var matchedOn: String
}

struct TasksSearchResponse: Codable, Sendable {
    /// Echoed back so the agent can tell which phrasing produced the hits.
    var query: String
    var matches: [TaskSearchMatch]
    /// Matches above the relevance floor, before `limit` was applied.
    var total: Int
    var limit: Int
    var hasMore: Bool
    /// `true` when the device could not refresh from the backend and answered from its
    /// last-known copy. The agent should say the answer may be out of date rather than
    /// present it as current — and must not read it as "no such task".
    var stale: Bool
    var staleReason: String?
}

struct TasksCreateResponse: Codable, Sendable {
    var task: TaskPayload
}

struct TasksUpdateResponse: Codable, Sendable {
    var task: TaskPayload
}

struct TasksDeleteResponse: Codable, Sendable {
    var deleted: Bool
    var id: String
}
