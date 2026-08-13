import Foundation

// MARK: - Suggested-task models (mirror backend/src/services/suggestions.service.ts)
//
// These live in Shared/ because `SuggestedTaskRow` is a shared view compiled into BOTH the iOS
// and macOS targets (per the DRY rule in CLAUDE.md). The networking layer that fetches them
// (`SuggestionsApiService`) can stay iOS-only, but the model it decodes must be visible to Mac.

/// How the app turns an accepted suggestion into a real task. The backend never mutates the
/// tasks table — the app performs the action through its own SwiftData + sync path, then
/// dismisses the suggestion so it won't re-derive.
public struct SuggestionAction: Codable, Sendable, Hashable {
    /// "createTask" | "rescheduleTask".
    public let kind: String
    /// createTask: title of the NEW task to create ("Prep for Standup").
    public let taskTitle: String?
    /// rescheduleTask: the existing task to move.
    public let targetTaskId: String?
    /// ISO 8601 — createTask: when to schedule the new task; rescheduleTask: the new start.
    public let startDate: String?

    public init(kind: String, taskTitle: String?, targetTaskId: String?, startDate: String?) {
        self.kind = kind
        self.taskTitle = taskTitle
        self.targetTaskId = targetTaskId
        self.startDate = startDate
    }

    public enum CodingKeys: String, CodingKey {
        case kind
        case taskTitle
        case targetTaskId
        case startDate
    }
}

/// A single suggested task shown in the Agenda. Every suggestion states WHY (`subtitle`) — an
/// unattributed suggestion is indistinguishable from the app inventing things (doc 38 §6).
public struct TaskSuggestion: Codable, Identifiable, Sendable, Hashable {
    /// Stable, source-prefixed identity ("cal:<id>" / "overdue:<id>"); also the dismissal key.
    public let key: String
    /// Backend-issued stable UUID for this action. For `createTask`, this is also the canonical
    /// task UUID, making retries idempotent even when a freshly derived schedule has moved.
    public let actionId: String
    /// "calendar" | "overdue".
    public let source: String
    /// The card headline ("Prep for Standup" / "Reschedule to today").
    public let title: String
    /// The WHY / attribution line ("Standup · 9:00 AM · Calendar" / "'File visa paperwork' · overdue 3d").
    public let subtitle: String
    public let action: SuggestionAction

    public var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, actionId, source, title, subtitle, action
    }

    public init(
        key: String,
        actionId: String,
        source: String,
        title: String,
        subtitle: String,
        action: SuggestionAction
    ) {
        self.key = key
        self.actionId = actionId
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        actionId = try container.decodeIfPresent(String.self, forKey: .actionId) ?? ""
        source = try container.decode(String.self, forKey: .source)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        action = try container.decode(SuggestionAction.self, forKey: .action)
    }
}

/// Exact local idempotency check for an already-accepted `createTask` proposal. The backend-issued
/// action id is also the created task id, so retries remain safe across refreshes and devices even
/// after that task is completed. Title and schedule comparisons are intentionally insufficient:
/// both can legitimately change while the canonical proposal remains the same.
public enum TaskSuggestionCreateDeduplication {
    public static func matchesExistingTask(
        for suggestion: TaskSuggestion,
        taskID existingTaskID: String
    ) -> Bool {
        guard suggestion.action.kind == "createTask",
              UUID(uuidString: suggestion.actionId) != nil
        else { return false }
        return existingTaskID.caseInsensitiveCompare(suggestion.actionId) == .orderedSame
    }
}

/// The backend-authored brief identity under which a set of suggestions was fetched.
/// Suggestions are actionable only while this identity still matches the current local-day brief;
/// keeping the identity beside the rows prevents an older Agenda cache from attaching yesterday's
/// Add/Move actions to today's durable conversation.
public struct OrchestratorSuggestionBriefIdentity: Sendable, Hashable {
    public let generatedAt: String
    /// Exact prose when a brief artifact exists. Connected-source signals may legitimately be the
    /// only thing to surface on an otherwise empty day, so revision identity must not invent prose.
    public let authoredMarkdown: String?
    public let authoredRevision: String

    public init?(generatedAt: String?, authoredMarkdown: String?, authoredRevision: String?) {
        guard let generatedAt = generatedAt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !generatedAt.isEmpty,
              let authoredRevision = authoredRevision?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authoredRevision.isEmpty
        else { return nil }
        self.generatedAt = generatedAt
        self.authoredMarkdown = authoredMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.authoredRevision = authoredRevision
    }

    public func isCurrentLocalDay(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let generatedDate = Self.parseISO8601(generatedAt) else { return false }
        return calendar.isDate(generatedDate, inSameDayAs: now)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }
}

/// One coherent render snapshot: the exact brief identity, the prose that must match durable
/// history (or temporarily bridge it), and the suggestions derived under that identity.
public struct OrchestratorSuggestionSnapshot: Sendable, Hashable {
    public let identity: OrchestratorSuggestionBriefIdentity
    public let snapshotID: String
    /// Nil for a truthful connected-source-only snapshot with no Daily Brief prose to anchor to.
    public let briefMarkdown: String?
    public let suggestions: [TaskSuggestion]

    public init?(
        identity: OrchestratorSuggestionBriefIdentity,
        snapshotID: String?,
        briefMarkdown: String?,
        suggestions: [TaskSuggestion]
    ) {
        guard let snapshotID = snapshotID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshotID.isEmpty,
              !suggestions.isEmpty,
              suggestions.allSatisfy({ UUID(uuidString: $0.actionId) != nil })
        else { return nil }
        self.identity = identity
        self.snapshotID = snapshotID
        self.briefMarkdown = briefMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.suggestions = suggestions
    }

    public func isCurrentLocalDay(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        identity.isCurrentLocalDay(now: now, calendar: calendar)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
