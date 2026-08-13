import Foundation

/// Service seam for the **task collaboration thread** (CONTRACT.md §4).
///
/// The Task is the long-lived unit of work; the human, a GMI AgentBox cloud agent,
/// and the local Mac/iOS gateway all leave attributed `TaskComment`s against it.
/// This protocol is the read/write surface the comment-thread UI talks to.
///
/// Canonical store is the backend `task_comments` table. Concrete implementation
/// hits the REST endpoints under `/api/v1/tasks/:id/*`; a mock returns seeded
/// sample comments for previews and demos.
/// Result of a cloud agent run: the persisted reply comment plus the stable
/// per-task session key the backend stamped at run start (`task_run.session_key`,
/// #971). The session key lets the client route "Open conversation" to the same
/// gateway session the backend ran against BEFORE the next full task sync lands —
/// without it, the local task's `sessionKey` stays `nil` and the continuation chat
/// opens on the pre-run `task-<slug>` key, then switches after sync, splitting the
/// conversation across two sessions.
public struct CloudAgentRunResult: Sendable {
    public let comment: TaskComment
    /// The stamped `rem-task-<taskId>` key from the run response, or `nil` if the
    /// backend omitted `task_run` (e.g. an older backend) — the caller then leaves
    /// the local task untouched and falls back to sync as before.
    public let stampedSessionKey: String?

    public init(comment: TaskComment, stampedSessionKey: String?) {
        self.comment = comment
        self.stampedSessionKey = stampedSessionKey
    }
}

@MainActor
public protocol TaskCommentProviding: AnyObject {
    /// Read the full thread for a task (oldest → newest).
    func comments(taskId: String) async throws -> [TaskComment]

    /// Post a human comment. `proposedStatus` lets the user propose a status
    /// change without committing it (committing is a separate `PATCH /tasks/:id`).
    /// Returns the persisted comment (`author_kind == .user`).
    func postComment(taskId: String, body: String, proposedStatus: String?) async throws -> TaskComment

    /// Trigger the GMI AgentBox cloud agent to act on the task. The backend runs
    /// the agent and persists its reply as a comment, which is returned here
    /// (`author_kind == .cloud_agent`). Recovery: backend returns a labelled stub
    /// comment rather than failing, so the thread never dead-ends (CONTRACT §8).
    ///
    /// Returns the reply comment PLUS the stable session key the backend stamped
    /// on the task at run start (`task_run.session_key` = `rem-task-<taskId>`, #971).
    /// The caller writes that key onto the local task immediately so "Open
    /// conversation" resolves to the SAME session the backend ran against, instead
    /// of the pre-run `task-<slug>` fallback until the next sync (the split-session
    /// bug this decode fixes — the comment's own `session_id` is the per-run runId,
    /// NOT the session key, so only `task_run.session_key` carries the stamped handle).
    func runCloudAgent(taskId: String, instruction: String?) async throws -> CloudAgentRunResult

    /// Read the replayable cloud-run transcript for a task (oldest → newest). These
    /// are the actual conversation turns (the ask + Rem's reply) a cloud run produced,
    /// which the task-scoped chat renders as REAL prior messages so opening it
    /// continues the conversation rather than landing in an empty composer (#869).
    func chatTranscript(taskId: String) async throws -> [TaskChatMessage]
}

// MARK: - Concrete (backend REST)

/// Talks to the RemClaw Express backend task-comment endpoints (CONTRACT.md §4).
///
/// Reuses the app's existing authenticated HTTP client for base-URL + JWT +
/// 401-refresh, exactly like `RemTaskApiService` and the other shared sheets:
/// - iOS:   `AuthenticatedHttpClient.request(...)`
///          (RemClaw/Sources/Services/Auth/AuthenticatedHttpClient.swift:53)
/// - macOS: `MacAuthenticatedHttpClient.request(...)`
///          (RemClawMac/Sources/Gateway/MacAuthenticatedHttpClient.swift:78)
///
/// This is the same `#if os(iOS)` split that `Shared/Views/CloudGatewayDeploySheet.swift`
/// and `Shared/Views/SharedDeleteAccountSheet.swift` already use — no new auth path.
@MainActor
public final class TaskCommentService: TaskCommentProviding {

    private let decoder: JSONDecoder = {
        // NOTE: no `.convertFromSnakeCase` — TaskComment declares explicit
        // CodingKeys (task_id, author_kind, …); a global strategy would conflict
        // with them and silently null the fields (same gotcha as RemTaskApiService).
        JSONDecoder()
    }()

    public init() {}

    private func tasksPath(_ id: String, _ suffix: String) -> String {
        "/api/v1/tasks/\(id)\(suffix)"
    }

    // MARK: TaskCommentProviding

    public func comments(taskId: String) async throws -> [TaskComment] {
        let (data, http) = try await Self.request(
            path: tasksPath(taskId, "/comments"),
            method: "GET"
        )
        try Self.check(http, data: data)
        return try decoder.decode(CommentsEnvelope.self, from: data).comments
    }

    public func postComment(
        taskId: String,
        body: String,
        proposedStatus: String?
    ) async throws -> TaskComment {
        var payload: [String: Any] = ["body": body]
        if let proposedStatus { payload["proposed_status"] = proposedStatus }
        let httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try await Self.request(
            path: tasksPath(taskId, "/comments"),
            method: "POST",
            body: httpBody
        )
        try Self.check(http, data: data)
        return try decoder.decode(TaskComment.self, from: data)
    }

    public func runCloudAgent(
        taskId: String,
        instruction: String?
    ) async throws -> CloudAgentRunResult {
        var payload: [String: Any] = [:]
        if let instruction, !instruction.isEmpty { payload["instruction"] = instruction }
        // runtime is optional in the contract; backend defaults to agentbox.
        let httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try await Self.request(
            path: tasksPath(taskId, "/agent-run"),
            method: "POST",
            body: httpBody
        )
        try Self.check(http, data: data)
        // The response is `{ ...comment fields, task_run: { ..., session_key } }`
        // (backend tasks.routes.ts agent-run handler). Decode the comment from the
        // envelope's top level and the stamped session key from the nested `task_run`
        // in one pass. `task_run` (and its session_key) may be absent on older
        // backends → stampedSessionKey is nil and the caller falls back to sync.
        let envelope = try decoder.decode(AgentRunEnvelope.self, from: data)
        let comment = try decoder.decode(TaskComment.self, from: data)
        return CloudAgentRunResult(
            comment: comment,
            stampedSessionKey: envelope.taskRun?.sessionKey
        )
    }

    /// The nested `task_run` object the agent-run endpoint returns alongside the
    /// comment fields. We only need its `session_key` here (the stable
    /// `rem-task-<taskId>` handle); the rest of the run/task DTO is decoded elsewhere
    /// via the full task sync.
    private struct AgentRunEnvelope: Decodable {
        struct TaskRun: Decodable {
            let sessionKey: String?
            enum CodingKeys: String, CodingKey { case sessionKey = "session_key" }
        }
        let taskRun: TaskRun?
        enum CodingKeys: String, CodingKey { case taskRun = "task_run" }
    }

    public func chatTranscript(taskId: String) async throws -> [TaskChatMessage] {
        let (data, http) = try await Self.request(
            path: tasksPath(taskId, "/chat"),
            method: "GET"
        )
        try Self.check(http, data: data)
        return try decoder.decode(ChatTranscriptEnvelope.self, from: data).messages
    }

    // MARK: Transport (platform-split, mirrors existing shared sheets)

    private static func request(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        #if os(iOS)
        return try await AuthenticatedHttpClient.request(path: path, method: method, body: body)
        #else
        return try await MacAuthenticatedHttpClient.request(path: path, method: method, body: body)
        #endif
    }

    private static func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw TaskCommentServiceError.requestFailed(statusCode: response.statusCode, message: message)
        }
    }

    /// `GET /comments` returns `{ "comments": [...] }` (CONTRACT §4).
    private struct CommentsEnvelope: Decodable {
        let comments: [TaskComment]
    }

    /// `GET /chat` returns `{ "messages": [...] }` (migration 025).
    private struct ChatTranscriptEnvelope: Decodable {
        let messages: [TaskChatMessage]
    }
}

public enum TaskCommentServiceError: LocalizedError {
    case requestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(code, message):
            message ?? "Request failed (HTTP \(code))"
        }
    }
}

// MARK: - Mock (previews + demos)

/// In-memory `TaskCommentProviding` seeded with one comment per author kind.
/// Used by SwiftUI previews and as a safe stand-in before the backend is wired.
@MainActor
public final class MockTaskCommentService: TaskCommentProviding {

    public private(set) var thread: [TaskComment]

    /// Artificial latency so previews exercise the loading/spinner states.
    public var simulatedDelay: Duration

    public init(
        thread: [TaskComment]? = nil,
        simulatedDelay: Duration = .milliseconds(350)
    ) {
        self.thread = thread ?? MockTaskCommentService.sampleThread()
        self.simulatedDelay = simulatedDelay
    }

    public func comments(taskId: String) async throws -> [TaskComment] {
        try? await Task.sleep(for: simulatedDelay)
        return thread
    }

    public func postComment(
        taskId: String,
        body: String,
        proposedStatus: String?
    ) async throws -> TaskComment {
        try? await Task.sleep(for: simulatedDelay)
        let comment = TaskComment(
            id: UUID().uuidString,
            taskId: taskId,
            authorKind: .user,
            authorLabel: "You",
            body: body,
            proposedStatus: proposedStatus,
            runtime: nil,
            createdAt: MockTaskCommentService.nowISO()
        )
        thread.append(comment)
        return comment
    }

    public func runCloudAgent(
        taskId: String,
        instruction: String?
    ) async throws -> CloudAgentRunResult {
        try? await Task.sleep(for: simulatedDelay)
        let detail = instruction.map { " (\($0))" } ?? ""
        let comment = TaskComment(
            id: UUID().uuidString,
            taskId: taskId,
            authorKind: .cloudAgent,
            authorLabel: TaskRuntimeKind.agentbox.displayName,
            body: "Looked at the task\(detail). Drafted 3 steps to move it forward and set it to in progress.",
            proposedStatus: "in_progress",
            // Agent applied the status autonomously; previousStatus is the Undo target.
            previousStatus: "pending",
            runtime: .agentbox,
            createdAt: MockTaskCommentService.nowISO()
        )
        thread.append(comment)
        // Mirror the backend's stamped `rem-task-<taskId>` handle so previews exercise
        // the immediate-stamp path.
        return CloudAgentRunResult(comment: comment, stampedSessionKey: "rem-task-\(taskId)")
    }

    public func chatTranscript(taskId: String) async throws -> [TaskChatMessage] {
        try? await Task.sleep(for: simulatedDelay)
        // Project the cloud-agent comments in the seeded thread into a simple
        // ask/reply transcript so previews exercise the real-prior-turns rendering.
        var messages: [TaskChatMessage] = []
        for comment in thread where comment.authorKind == .cloudAgent {
            messages.append(
                TaskChatMessage(
                    id: "\(comment.id)-ask",
                    taskId: taskId,
                    role: "user",
                    content: "Let's keep working on this task.",
                    runId: comment.sessionId,
                    createdAt: comment.createdAt
                )
            )
            messages.append(
                TaskChatMessage(
                    id: "\(comment.id)-reply",
                    taskId: taskId,
                    role: "assistant",
                    content: comment.body,
                    runId: comment.sessionId,
                    createdAt: comment.createdAt
                )
            )
        }
        return messages
    }

    // MARK: Sample data

    /// One comment per `TaskAuthorKind`: human, cloud agent (with proposed
    /// status), and local runtime. Exposed for previews and snapshot tests.
    public static func sampleThread(taskId: String = "task-preview") -> [TaskComment] {
        [
            TaskComment(
                id: "c1",
                taskId: taskId,
                authorKind: .user,
                authorLabel: "You",
                body: "Can you help me clear out my inbox before Friday?",
                proposedStatus: nil,
                runtime: nil,
                createdAt: "2026-06-26T16:58:00.000Z"
            ),
            TaskComment(
                id: "c2",
                taskId: taskId,
                authorKind: .cloudAgent,
                authorLabel: TaskRuntimeKind.agentbox.displayName,
                body: "Drafted 3 steps to clear your inbox: triage by sender, archive newsletters, and reply to the 4 threads that need you. Marked this in progress.",
                proposedStatus: "in_progress",
                previousStatus: "pending",
                runtime: .agentbox,
                createdAt: "2026-06-26T17:00:00.000Z"
            ),
            TaskComment(
                id: "c3",
                taskId: taskId,
                authorKind: .localRuntime,
                authorLabel: TaskRuntimeKind.localMac.displayName,
                body: "Archived 38 newsletters and snoozed 5 low-priority threads on this Mac.",
                proposedStatus: nil,
                runtime: .localMac,
                createdAt: "2026-06-26T17:04:30.000Z"
            ),
        ]
    }

    private static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
