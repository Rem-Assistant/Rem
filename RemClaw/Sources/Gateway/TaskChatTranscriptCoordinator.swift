import Foundation
import OpenClawChatUI
import OpenClawProtocol

/// Bridges a task's persisted cloud-run transcript (backend `task_chat_messages`,
/// migration 025) into the gateway chat's history-load path so a task-scoped
/// continuation chat opens the REAL prior conversation — the ask + Rem's reply — as
/// actual messages, instead of an empty composer with a prefilled nudge (#869 / #874).
///
/// Why a coordinator (not the transport directly): a cloud run executes in the GMI
/// AgentBox namespace, so its turns aren't a gateway session the transport's
/// `chat.history` can read. The task-scoped session key is the backend-compatible
/// `rem-task-<full UUID>`, which is reversible. The chat opener still registers the
/// `sessionKey → taskId` mapping for compatibility with any previously stored custom
/// key, and the transport asks this coordinator for prior turns when it loads history.
/// Canonical keys resolve without an in-memory registration, so opening a task session
/// from Chat Sessions or after relaunch still resolves the same durable transcript.
/// The fetch goes through the normal authenticated task API
/// (`TaskCommentProviding.chatTranscript`).
///
/// Source of truth: the backend `task_chat_messages` table. This is a read-through
/// adapter — it caches nothing. Non-task sessions resolve to an empty prefix; a
/// task-transcript request failure is propagated so chat shows recoverable loading
/// failure instead of presenting a valid-looking partial thread. A task-not-found
/// response is the one exception: deleting a task removes its backend transcript but
/// intentionally does not delete the gateway session, whose history must stay readable.
@MainActor
final class TaskChatTranscriptCoordinator {
    private let service: any TaskCommentProviding
    private var sessionKeyToTaskId: [String: String] = [:]

    init(service: any TaskCommentProviding) {
        self.service = service
    }

    /// Record that a task-scoped chat session maps to a backend task id. Called by the
    /// chat opener BEFORE it switches the chat to this session, so the transport's
    /// subsequent history load can resolve the task and fetch its transcript.
    func register(sessionKey: String, taskId: String) {
        sessionKeyToTaskId[sessionKey] = taskId
    }

    /// Prior transcript turns for a task-scoped session as raw chat-history message
    /// objects (the shape `OpenClawChatHistoryPayload.messages` decodes), oldest-first.
    /// Empty when the session isn't task-scoped. Throws when a task-scoped transcript
    /// cannot be loaded, preventing a backend outage from masquerading as an empty
    /// execution history.
    func priorHistoryMessages(sessionKey: String) async throws -> [AnyCodable] {
        guard let taskId = sessionKeyToTaskId[sessionKey]
                ?? TaskChatSessionIdentity.taskId(from: sessionKey)
        else { return [] }
        do {
            let messages = try await service.chatTranscript(taskId: taskId)
            return messages.map(Self.historyMessage(from:))
        } catch let error as TaskCommentServiceError {
            if case let .requestFailed(statusCode, _) = error,
               statusCode == 404 {
                return []
            }
            throw error
        }
    }

    /// Convert a persisted transcript turn into the JSON object the chat view model
    /// decodes as an `OpenClawChatMessage` (role + a single text content block).
    private static func historyMessage(from message: TaskChatMessage) -> AnyCodable {
        let role: String
        switch message.role {
        case "assistant": role = "assistant"
        case "tool": role = "tool"
        default: role = "user"
        }

        var dict: [String: Any] = [
            "role": role,
            "content": [["type": "text", "text": message.content]],
        ]
        if let createdAt = message.createdAt,
           let date = TaskComment.parseISO8601(createdAt) {
            // OpenClawChatMessage timestamps are epoch milliseconds (the optimistic
            // chat path uses Date.timeIntervalSince1970 * 1000). Keeping task turns
            // in the same unit is required for chronological source merging.
            dict["timestamp"] = date.timeIntervalSince1970 * 1000
        }
        return AnyCodable(dict)
    }
}

/// Stable identity contract shared by task-detail routing and transcript recovery.
///
/// The backend stamps every task run as `rem-task-<full UUID>`. Using that same key
/// before the first run prevents the old split where a never-run task opened locally
/// as `task-<12-char slug>` and then moved to a different session after AgentBox ran.
enum TaskChatSessionIdentity {
    struct LegacyHistoryRedirect: Equatable {
        let taskId: String
        let canonicalSessionKey: String
    }

    struct GatewayHistoryPlan: Equatable {
        /// All new continuation messages are sent here.
        let activeSessionKey: String
        /// Read-only compatibility histories merged into the active session on load.
        let additionalHistorySessionKeys: [String]
    }

    /// Old clients used this short gateway key before the backend and clients agreed
    /// on `rem-task-<full UUID>`. Keep the derivation centralized so upgrades can
    /// recognize an existing legacy conversation without creating new legacy rows.
    static func legacySessionKey(taskId: String) -> String {
        let taskSlug = taskId
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
            .lowercased()
        return "task-\(taskSlug)"
    }

    /// Durable upgrade plan: continue all new work on the canonical UUID key while
    /// always reading the deterministic legacy key as a compatibility history. This
    /// deliberately does not consult `sessions.list`; that cache loads asynchronously,
    /// is commonly capped to the newest 50 rows, and cannot prove a legacy row absent.
    static func gatewayHistoryPlan(
        taskId: String,
        persistedSessionKey: String?
    ) -> GatewayHistoryPlan {
        let canonical = canonicalSessionKey(
            taskId: taskId,
            persistedSessionKey: persistedSessionKey
        )
        return GatewayHistoryPlan(
            activeSessionKey: canonical,
            additionalHistorySessionKeys: compatibilityHistorySessionKeys(for: canonical)
        )
    }

    /// Derive the legacy read alias from a canonical task key. Preserve the primary
    /// `agent:main:` namespace when a history entry is opened using its fully-qualified
    /// gateway identity; bare app keys remain bare aliases for that same namespace.
    static func compatibilityHistorySessionKeys(for sessionKey: String) -> [String] {
        guard let taskId = taskId(from: sessionKey) else { return [] }
        let legacy = legacySessionKey(taskId: taskId)
        return sessionKey.hasPrefix("agent:main:")
            ? ["agent:main:\(legacy)"]
            : [legacy]
    }

    /// Resolve a legacy row selected from Chat History back to its canonical task
    /// conversation when that task is currently loaded. Legacy keys contain only a
    /// truncated UUID, so require exactly one candidate match rather than risking a
    /// collision that would merge two tasks' conversations.
    static func legacyHistoryRedirect(
        sessionKey: String,
        candidateTaskIds: [String]
    ) -> LegacyHistoryRedirect? {
        let bareKey: String
        if sessionKey.hasPrefix("agent:main:") {
            bareKey = String(sessionKey.dropFirst("agent:main:".count))
        } else if sessionKey.contains(":") {
            return nil
        } else {
            bareKey = sessionKey
        }

        let matches = candidateTaskIds.filter { legacySessionKey(taskId: $0) == bareKey }
        guard matches.count == 1, let taskId = matches.first else { return nil }
        return LegacyHistoryRedirect(
            taskId: taskId,
            canonicalSessionKey: canonicalSessionKey(taskId: taskId, persistedSessionKey: nil)
        )
    }

    static func canonicalSessionKey(taskId: String, persistedSessionKey: String?) -> String {
        if let persistedSessionKey = persistedSessionKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !persistedSessionKey.isEmpty {
            // Repair older/manual backend stamps that preserved uppercase UUID text.
            // Gateway keys are case-sensitive; rebuild every recognizable canonical
            // key from its parsed UUID so pre-run and post-run routing cannot split.
            if let persistedTaskId = Self.taskId(from: persistedSessionKey) {
                return "rem-task-\(persistedTaskId)"
            }
            // A pre-canonical client may have persisted its `task-<12>` key. The full
            // task id supplied by the caller makes that short key safely recognizable;
            // migrate writes to canonical while retaining legacy as a read alias.
            let barePersistedKey = persistedSessionKey.hasPrefix("agent:main:")
                ? String(persistedSessionKey.dropFirst("agent:main:".count))
                : persistedSessionKey
            if barePersistedKey == legacySessionKey(taskId: taskId) {
                return canonicalSessionKey(taskId: taskId, persistedSessionKey: nil)
            }
            return persistedSessionKey
        }
        if let uuid = UUID(uuidString: taskId) {
            return "rem-task-\(uuid.uuidString.lowercased())"
        }
        return "rem-task-\(taskId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    static func taskId(from sessionKey: String) -> String? {
        let bareKey: String
        let canonicalParts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        if canonicalParts.count >= 3,
           canonicalParts[0] == "agent",
           canonicalParts[1] == "main" {
            bareKey = canonicalParts.dropFirst(2).joined(separator: ":")
        } else {
            bareKey = sessionKey
        }

        let prefix = "rem-task-"
        guard bareKey.hasPrefix(prefix) else { return nil }
        let rawTaskId = String(bareKey.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: rawTaskId) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
