import Foundation

/// Task collaboration model — shared across iOS and macOS.
///
/// The Task is the long-lived unit of work; multiple runtimes (the human, a GMI
/// AgentBox cloud agent, the local Mac/iOS gateway) leave **attributed comments**
/// against it. Canonical store is the backend `task_comments` table; these types
/// mirror that JSON. See docs/agentbox/CONTRACT.md.
///
/// FROZEN contract — consumers import these, they do not modify them.

// MARK: - Author

/// Who authored a task comment.
public enum TaskAuthorKind: String, Codable, Sendable, Hashable {
    case user
    case cloudAgent = "cloud_agent"
    case localRuntime = "local_runtime"
}

// MARK: - Runtime

/// Where work executes. The same task can be handed between runtimes.
public enum TaskRuntimeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case agentbox          // GMI AgentBox cloud agent (legacy)
    case gateway           // per-user cloud OpenClaw gateway (orchestrator sweep, migration 031)
    case localMac = "local_mac"   // Mac OpenClaw gateway
    case localiOS = "local_ios"   // iOS OpenClaw node

    public var displayName: String {
        switch self {
        case .agentbox, .gateway: "Rem"
        case .localMac: "Mac Runtime"
        case .localiOS: "iPhone Runtime"
        }
    }

    public var isCloud: Bool { self == .agentbox || self == .gateway }

    /// The runtimes a user may actually assign a task to.
    ///
    /// `.gateway` is decodable and displayable but NOT assignable: it exists to attribute
    /// comments the orchestrator sweep wrote, and nothing routes work to it. Leaving it in
    /// the picker (which iterates `allCases`) offered a second option labelled "Rem" —
    /// identical to `.agentbox`, since both render that displayName — and choosing it
    /// persisted an assignment `askCloud()` ignores, because that path always calls
    /// `runCloudAgent` without consulting `assignedRuntime`. The header would then claim the
    /// gateway while AgentBox did the work. Pickers must iterate this; previews/badges can
    /// still use `allCases`. (Caught by Codex on #996.)
    public static var assignableCases: [TaskRuntimeKind] { [.agentbox, .localMac, .localiOS] }
}

// MARK: - Proposed status

/// A status an author (the human, or — the common case — a cloud/local agent) can
/// **propose** for a task. Structured signal (principle 5): the view renders from a
/// known case instead of switching on an open string. Raw values mirror the backend
/// `PROPOSED_STATUSES` set and the `task_comments.proposed_status` CHECK constraint
/// (migrations 015 + 021). See docs/agentbox/CONTRACT.md §3.3.
public enum TaskProposedStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled
    /// The agent cannot proceed — it needs information or is waiting on an input the
    /// user must provide (e.g. it needs details before a filing). A real proposal the
    /// agent emits, NOT an error — the right status when the agent says "I need X".
    case blocked
}

// MARK: - Run status

/// The structured run-state of the agent working a task — grafted from OpenClaw
/// Workboard's `execution.status` onto Rem's richer task model (P1 of
/// docs/rebuild/19-TASKS-VS-WORKBOARD.md). This is DISTINCT from the task's own
/// `status` (pending/in_progress/completed/…): `runStatus` answers "is an agent
/// working this right now, and how did the last run end?" while `status` answers
/// "what is the human-facing state of the work?" They are independent columns
/// (backend migration 019 `tasks.run_status`) and independent fields here.
///
/// Structured signal (principle 5): the view renders from a known case, not a
/// string switch. Raw values mirror the backend CHECK constraint in migration 019.
/// Lifecycle: `idle`/nil → `running` (on dispatch) → `done` | `review` | `blocked`
/// (terminal, on completion). A stale `running` claim is reaped back to nil by the
/// backend orchestrator sweep (`reapStaleRunningClaims`).
public enum TaskRunStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Explicit reset back to no active run (also represented by a nil field).
    case idle
    /// A run is in flight — an agent is working this task right now.
    case running
    /// The run finished and left a comment for the human to review.
    case review
    /// The run could not complete (service unreachable) or the agent is blocked
    /// / needs info. Both land here so a "needs attention" sweep catches either.
    case blocked
    /// The run completed the task.
    case done

    /// True while an agent is actively working the task (drives a live indicator).
    public var isActive: Bool { self == .running }

    /// True when the run needs the human's attention (surfaced more prominently).
    public var needsAttention: Bool { self == .review || self == .blocked }

    /// Short human-facing label for the run-status indicator.
    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .running: "Working"
        case .review: "Needs review"
        case .blocked: "Needs attention"
        case .done: "Done"
        }
    }
}

// MARK: - Comment

/// A single attributed comment on a task. Mirrors backend `task_comments` JSON.
public struct TaskComment: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let taskId: String
    public let authorKind: TaskAuthorKind
    public let authorLabel: String
    public let body: String
    /// A status the author proposes for — or, for an agent run, APPLIED to — the task
    /// (nullable). For a human comment it's a proposal the user can Accept. For a cloud
    /// agent run it's the status the agent already applied (see `previousStatus`).
    public let proposedStatus: String?
    /// The task's status BEFORE an agent run changed it (nullable, backend
    /// `task_comments.previous_status`, migration 028). Non-nil ⇒ the agent APPLIED
    /// `proposedStatus` to the task autonomously, and this is the Undo target — the view
    /// renders "Applied: <status>" + Undo (committing `previousStatus`) instead of
    /// "Proposes: …" + Accept. Nil ⇒ nothing was applied (the legacy propose/Accept path,
    /// human comments, and pre-028 rows).
    public let previousStatus: String?
    /// Which runtime produced this comment (nullable for human comments).
    public let runtime: TaskRuntimeKind?
    /// The session/run id this comment executed in (backend `task_comments.session_id`,
    /// migration 022). The handle that resolves an activity row back to the agent
    /// session/chat that produced it — the task is the "workboard", each comment a
    /// doorway into its session. `nil` for human comments and any comment not produced
    /// by a run; tapping such a row should fall back gracefully, not crash.
    public let sessionId: String?
    /// ISO-8601 string from the backend. Use `createdAtDate` for a parsed value —
    /// kept as String so decoding never depends on a JSONDecoder dateStrategy
    /// (see CLAUDE.md ISO 8601 gotcha).
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case authorKind = "author_kind"
        case authorLabel = "author_label"
        case body
        case proposedStatus = "proposed_status"
        case previousStatus = "previous_status"
        case runtime
        case sessionId = "session_id"
        case createdAt = "created_at"
    }

    /// Tolerant decode: an unknown `runtime` raw value degrades to `nil` instead of
    /// throwing and bricking the entire comments array. The backend's runtime CHECK
    /// constraint is looser than this enum (migration 031 admitted 'gateway' while the
    /// client only knew 'agentbox') — that drift rendered every orchestrator-touched
    /// task's Activity as "data couldn't be read". Decode the string, then map; a value
    /// this client doesn't know yet just loses its badge, not the whole thread.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskId = try c.decode(String.self, forKey: .taskId)
        authorKind = try c.decode(TaskAuthorKind.self, forKey: .authorKind)
        authorLabel = try c.decode(String.self, forKey: .authorLabel)
        body = try c.decode(String.self, forKey: .body)
        proposedStatus = try c.decodeIfPresent(String.self, forKey: .proposedStatus)
        previousStatus = try c.decodeIfPresent(String.self, forKey: .previousStatus)
        runtime = (try? c.decodeIfPresent(String.self, forKey: .runtime))
            .flatMap { TaskRuntimeKind(rawValue: $0) }
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    public init(
        id: String,
        taskId: String,
        authorKind: TaskAuthorKind,
        authorLabel: String,
        body: String,
        proposedStatus: String? = nil,
        previousStatus: String? = nil,
        runtime: TaskRuntimeKind? = nil,
        sessionId: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.authorKind = authorKind
        self.authorLabel = authorLabel
        self.body = body
        self.proposedStatus = proposedStatus
        self.previousStatus = previousStatus
        self.runtime = runtime
        self.sessionId = sessionId
        self.createdAt = createdAt
    }

    /// Structured form of `proposedStatus` when it matches a known case (principle 5).
    /// `nil` when no status is proposed, or when the backend sent a value this client
    /// doesn't recognize yet — the view should fall back to the raw `proposedStatus`
    /// string in that case rather than dropping the chip.
    public var proposedTaskStatus: TaskProposedStatus? {
        guard let proposedStatus else { return nil }
        return TaskProposedStatus(rawValue: proposedStatus)
    }

    /// True when this comment's run autonomously APPLIED its `proposedStatus` to the
    /// task (the agent changed the status itself). Drives the view's "Applied + Undo"
    /// treatment vs. the legacy "Proposes + Accept". A non-empty `previousStatus` is the
    /// structured marker (and the Undo target), so the view doesn't infer intent.
    public var didApplyStatus: Bool {
        guard let previousStatus else { return false }
        return !previousStatus.isEmpty
    }

    /// Parsed timestamp. Tries fractional seconds first, then falls back —
    /// AI agents and Postgres emit both forms.
    public var createdAtDate: Date? {
        guard let createdAt else { return nil }
        return TaskComment.parseISO8601(createdAt)
    }

    static func parseISO8601(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let withoutFrac = ISO8601DateFormatter()
        withoutFrac.formatOptions = [.withInternetDateTime]
        return withoutFrac.date(from: s)
    }
}

// MARK: - Chat transcript message

/// One replayable turn of a task's cloud-run conversation. Mirrors backend
/// `task_chat_messages` JSON (migration 025), served by `GET /tasks/:id/chat`.
///
/// Why this exists: a cloud (AgentBox) run executes in the GMI namespace, never on
/// the user's gateway, so its turns can't be replayed as a gateway session — only the
/// final reply was kept (as a `TaskComment` body). These rows are the device-reachable
/// home for the *whole* exchange (the ask + Rem's reply), so opening a task's chat can
/// render the REAL prior conversation instead of an empty composer (#869 / #874).
public struct TaskChatMessage: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let taskId: String
    /// "user" | "assistant" | "tool" (mirrors the backend CHECK constraint).
    public let role: String
    public let content: String
    /// The run this turn belongs to (nullable). Same id as the `TaskComment.sessionId`
    /// the run stamped, so turns and the activity row share a handle.
    public let runId: String?
    /// ISO-8601 string from the backend. Parse with `TaskComment.parseISO8601`.
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case role
        case content
        case runId = "run_id"
        case createdAt = "created_at"
    }

    public init(
        id: String,
        taskId: String,
        role: String,
        content: String,
        runId: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.role = role
        self.content = content
        self.runId = runId
        self.createdAt = createdAt
    }
}
