import SwiftUI
import SwiftData

/// Unified Task model for RemClaw
///
/// **Routing Logic:**
/// - Tasks WITH startDate → Appear in AgendaView on the appropriate date
/// - Tasks WITHOUT startDate → Appear in InboxView (unscheduled tasks)

// MARK: - Priority Enum
public enum Priority: String, Codable, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

// MARK: - TaskStatus Enum
public enum TaskStatus: String, Codable {
    case todo = "To Do"
    case unscheduled = "Unscheduled"
    case scheduled = "Scheduled"
    case inProgress = "In Progress"
    case completed = "Completed"
    case rescheduled = "Rescheduled"
    /// The task can't proceed — it needs information or is waiting on an input. A real
    /// status (not an error), selectable from the status menu and applied by an agent
    /// run. Backend value `blocked` (migrations 027 + 021). See principle 5.
    case blocked = "Blocked"
}

// MARK: - Task Model
@Model
public final class TaskEvent {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var category: String
    public var startDate: Date?
    public var endDate: Date?
    public var duration: TimeInterval?
    public var estimatedDuration: TimeInterval?
    public var alertTime: Date?
    public var repeatFrequency: String?
    public var notes: String?
    /// The USER's half of the co-authored description (backend migration 120) — "what I
    /// know now" about this task. DISTINCT from `notes`, which is local-only scratch that
    /// never leaves the device; this round-trips to the backend and is read by every agent
    /// run, which is what makes a task RUNNABLE rather than merely titled.
    public var taskDescription: String?
    /// REM's half of the same description: the current state the last run recorded.
    /// Backend is the source of truth and the client only READS it — the two halves are
    /// merged server-side precisely so neither author can clobber the other.
    public var agentContext: String?
    public var isEvent: Bool
    public var isBusy: Bool
    public var isAnyTime: Bool
    public var priority: String
    public var status: String
    public var calendarEventID: String?
    public var isCalendarOnlyMirror: Bool?
    /// Organization (Sorted-style): the List this task belongs to, if any.
    /// `nil` = unfiled (shows in Inbox / "No List"). Mirrors backend `tasks.list_id`.
    public var listID: UUID?
    /// When set, this calendar event has been "opted into being worked": the id of the
    /// backend backing task (type `calendar_event`, keyed by `calendarEventID`) that
    /// carries its Activity thread + agent runs. `nil` = never worked, so a read-only /
    /// pure-mirror event shows no Activity surface. Drives `supportsActivity` so an
    /// opted-in event keeps Activity across reopens while an un-worked one stays quiet.
    /// See backend migration 024 / `POST /tasks/event-backing`.
    public var workBackingTaskID: UUID?
    /// Structured agent run-state (backend `tasks.run_status`, migration 019 — grafted
    /// from OpenClaw Workboard's `execution`). DISTINCT from `status`: `status` is the
    /// human-facing task state, `runStatus` is "is an agent working this right now, and
    /// how did the last run end?" (running/review/blocked/done/idle). See `TaskRunStatus`.
    /// Backend is the source of truth; the app only reads these (set by agent-run dispatch
    /// + the orchestrator sweep). All optional → SwiftData lightweight-migration safe.
    public var runStatus: String?
    /// Identifier for the current/last run — correlates the task with its run comment.
    public var runId: String?
    /// Live session handle for the "Open conversation" jump (Workboard card→session
    /// duality). `nil` for cloud-agent dispatch; reserved for a live-session path.
    public var sessionKey: String?
    /// When the current/last run started.
    public var runStartedAt: Date?
    /// Backend `tasks.stale_at` (migration 116). Non-nil ⟺ the brief surfaced this task
    /// `BRIEF_STALE_THRESHOLD` (3) times running and the user never acted, so it stopped asking.
    ///
    /// A SEPARATE STORED FIELD FROM `status`, ON PURPOSE. Staleness is orthogonal to workflow
    /// state — a task can be `blocked` AND stale — and a `'stale'` status value would (a) destroy
    /// whatever status the user actually set, (b) drop the row from the five backend consumers that
    /// filter on `status`, and (c) decode here as an ordinary `.todo` via `statusFromBackend`'s
    /// fallback, so the phone would disagree with the server in silence. Render this ALONGSIDE
    /// `status`, never instead of it: see `TaskDeemphasisReason`.
    ///
    /// Backend is the source of truth; the app only reads it, and any user action clears it there.
    /// Optional → SwiftData lightweight-migration safe.
    public var staleAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        category: String = "Personal",
        startDate: Date? = nil,
        endDate: Date? = nil,
        duration: TimeInterval? = nil,
        estimatedDuration: TimeInterval? = nil,
        alertTime: Date? = nil,
        repeatFrequency: String? = nil,
        notes: String? = nil,
        taskDescription: String? = nil,
        agentContext: String? = nil,
        isEvent: Bool = false,
        isBusy: Bool = false,
        isAnyTime: Bool = false,
        priority: Priority = .medium,
        status: TaskStatus = .todo,
        calendarEventID: String? = nil,
        isCalendarOnlyMirror: Bool = false,
        listID: UUID? = nil,
        workBackingTaskID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.estimatedDuration = estimatedDuration
        self.alertTime = alertTime
        self.repeatFrequency = repeatFrequency
        self.notes = notes
        self.taskDescription = taskDescription
        self.agentContext = agentContext
        self.isEvent = isEvent
        self.isBusy = isBusy
        self.isAnyTime = isAnyTime
        self.priority = Self.priorityToBackend(priority)
        self.status = Self.statusToBackend(status)
        self.calendarEventID = calendarEventID
        self.isCalendarOnlyMirror = isCalendarOnlyMirror
        self.listID = listID
        self.workBackingTaskID = workBackingTaskID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Backend Format Conversion

    private static func priorityToBackend(_ priority: Priority) -> String {
        priority.rawValue.lowercased()
    }

    private static func priorityFromBackend(_ backendValue: String) -> Priority {
        Priority(rawValue: backendValue.capitalized) ?? .medium
    }

    private static func statusToBackend(_ status: TaskStatus) -> String {
        switch status {
        case .todo, .unscheduled: "pending"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .blocked: "blocked"
        case .scheduled, .rescheduled: "pending"
        }
    }

    private static func statusFromBackend(_ backendValue: String) -> TaskStatus {
        switch backendValue.lowercased() {
        case "pending": .todo
        case "in_progress": .inProgress
        case "completed": .completed
        case "blocked": .blocked
        case "cancelled": .todo
        default: TaskStatus(rawValue: backendValue) ?? .todo
        }
    }

    // MARK: - Convenience Computed Properties

    public var priorityEnum: Priority {
        get { Self.priorityFromBackend(priority) }
        set { priority = Self.priorityToBackend(newValue) }
    }

    public var statusEnum: TaskStatus {
        get { Self.statusFromBackend(status) }
        set { status = Self.statusToBackend(newValue) }
    }

    // MARK: - Routing

    public var shouldAppearInAgenda: Bool { startDate != nil }
    public var shouldAppearInInbox: Bool { startDate == nil }

    public func shouldAppear(on date: Date) -> Bool {
        guard let taskStartDate = startDate else { return false }
        return Calendar.current.isDate(taskStartDate, inSameDayAs: date)
    }

    // MARK: - Display Helpers

    public var isScheduledToday: Bool {
        guard let taskStartDate = startDate else { return false }
        return Calendar.current.isDateInToday(taskStartDate)
    }

    public var formattedDuration: String? {
        guard let duration else { return nil }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    public var endTime: Date? {
        guard let start = startDate, let duration else { return nil }
        return start.addingTimeInterval(duration)
    }

    public var isPast: Bool {
        guard let taskStartDate = startDate else { return false }
        return taskStartDate < Date()
    }

    public var isCompleted: Bool { statusEnum == .completed }

    /// The backend "type" field: "calendar_event" or "task"
    public var type: String { isEvent ? "calendar_event" : "task" }

    // MARK: - API Response Conversion

    public func toApiResponse() -> TaskEventApiResponse {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return TaskEventApiResponse(
            id: id.uuidString,
            title: title,
            status: status,
            priority: priority,
            startDate: startDate.map { isoFormatter.string(from: $0) },
            endDate: endDate.map { isoFormatter.string(from: $0) },
            durationMinutes: duration.map { Int($0 / 60) },
            alertTime: alertTime.map { isoFormatter.string(from: $0) },
            repeatFrequency: repeatFrequency,
            type: type,
            listID: listID?.uuidString,
            createdAt: isoFormatter.string(from: createdAt),
            updatedAt: isoFormatter.string(from: updatedAt),
            calendarEventID: calendarEventID,
            runStatus: runStatus,
            runId: runId,
            sessionKey: sessionKey,
            runStartedAt: runStartedAt.map { isoFormatter.string(from: $0) },
            staleAt: staleAt.map { isoFormatter.string(from: $0) },
            // Only the USER's half round-trips out of the device. Rem's block is
            // server-owned; echoing it back would be the client asserting authorship of
            // text it did not write.
            descriptionUser: taskDescription
        )
    }
}
