import Foundation

// MARK: - Daily Brief models (mirror backend/src/services/brief.service.ts)

/// Latest non-user activity on a brief item — what Rem last did/said on the task.
/// Powers the one-line preview the brief shows so the user can tap in to unblock.
public struct BriefActivity: Codable, Sendable, Hashable {
    public let authorLabel: String
    public let authorKind: String
    public let summary: String
    public let createdAt: String?

    public enum CodingKeys: String, CodingKey {
        case summary
        case authorLabel = "author_label"
        case authorKind = "author_kind"
        case createdAt = "created_at"
    }
}

/// A single actionable item in the Daily Brief, tagged with the bucket it fell into.
public struct BriefItem: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let status: String?
    public let priority: String?
    public let runStatus: String?
    public let startDate: String?
    public let type: String
    public let bucket: String
    /// Latest AI comment/status on this task, or nil when Rem hasn't acted yet.
    public let latestActivity: BriefActivity?
    /// Backend `is_stale` — `tasks.stale_at != null`, derived in `gatherBrief` (migration 116).
    /// True ⟺ the brief surfaced this task three times running with no user action, so it stopped
    /// handing it to the authoring model. The item is still IN the buckets, flagged rather than
    /// hidden, which is why this must be rendered: otherwise the user sees a task the brief has
    /// silently gone quiet about and nothing says so.
    ///
    /// Optional so an older backend that predates the field decodes rather than failing the whole
    /// brief; absent is read as "not stale", the same default a fresh task has.
    public let isStale: Bool?

    public enum CodingKeys: String, CodingKey {
        case id, title, status, priority, type, bucket
        case runStatus = "run_status"
        case startDate = "start_date"
        case latestActivity = "latest_activity"
        case isStale = "is_stale"
    }

    /// Blocked and/or stale, resolved by the same shared rule the task rows use so the brief and
    /// the agenda cannot disagree about what a stale task looks like.
    public var deemphasisReasons: [TaskDeemphasisReason] {
        TaskDeemphasisReason.reasons(status: status, isStale: isStale == true)
    }

    /// SwiftData `TaskEvent.id` is a UUID; the brief carries it as a string. Only
    /// real tasks (not calendar events) can be acted on locally.
    public var taskUUID: UUID? { UUID(uuidString: id) }
    public var isEvent: Bool { type == "calendar_event" }
}

/// Summary counts the agenda card renders (progress ring + chips).
public struct BriefCounts: Codable, Sendable, Hashable {
    public let blocked: Int
    public let overdue: Int
    public let scheduledToday: Int
    public let completedToday: Int
    /// Today's workload (scheduled + completed) — the ring denominator.
    public let total: Int
    /// Items finished today — the ring numerator.
    public let done: Int

    public enum CodingKeys: String, CodingKey {
        case blocked, overdue, total, done
        case scheduledToday = "scheduled_today"
        case completedToday = "completed_today"
    }

    /// 0...1 fraction of today's workload finished. 0 when nothing is scheduled yet.
    public var progress: Double {
        guard total > 0 else { return 0 }
        return min(Double(done) / Double(total), 1)
    }

    public var hasAnything: Bool {
        blocked + overdue + scheduledToday + completedToday > 0
    }
}

/// Today's Daily Brief for the authed user.
public struct DailyBrief: Codable, Sendable, Hashable {
    public let generatedAt: String?
    /// Immutable backend identity of the exact authored/deterministic brief returned with proposals.
    public let briefRevision: String?
    /// Exact identity of the atomic brief + suggestions response.
    public let suggestionSnapshotID: String?
    public let suggestions: [TaskSuggestion]
    public let counts: BriefCounts
    public let blocked: [BriefItem]
    public let overdue: [BriefItem]
    public let scheduledToday: [BriefItem]
    public let completedToday: [BriefItem]
    /// The brief as a living markdown *prose* document — the full brief the card expands
    /// into (#916). Optional so an older backend (counts-only) still decodes cleanly.
    public let markdown: String?
    /// One/two-line condensed prose for the agenda summary card (shown beside the capsules).
    /// When AI authoring is on, this mirrors the brief chat's latest message (founder FR).
    public let summary: String?
    /// The brief's authored HEADLINE — `daily_brief_artifacts.headline`, written with the brief
    /// (backend migration 119). This is the single title string: the Agenda summary card and the
    /// orchestrator chat both render it, and neither derives its own from the clock or the prose.
    /// Nil for a pre-migration artifact with no heading, or before any artifact is delivered;
    /// each surface then keeps the fallback title it used before.
    public let headline: String?
    /// Latest assistant prose delivered in the durable daily conversation. This is
    /// display/playback state only; `markdown` remains the authored brief used for
    /// first-turn hidden context.
    public let transcriptMarkdown: String?
    public let transcriptSummary: String?
    /// The stable gateway chat session containing the delivered brief (`rem-orchestrator`).
    /// The backend withholds this authority marker until exact canonical delivery is visible.
    public let briefSessionKey: String?

    public enum CodingKeys: String, CodingKey {
        case counts, blocked, overdue, markdown, summary, headline, suggestions
        case transcriptMarkdown = "transcript_markdown"
        case transcriptSummary = "transcript_summary"
        case generatedAt = "generated_at"
        case briefRevision = "brief_revision"
        case suggestionSnapshotID = "suggestion_snapshot_id"
        case scheduledToday = "scheduled_today"
        case completedToday = "completed_today"
        case briefSessionKey = "brief_session_key"
    }

    public init(
        generatedAt: String?,
        briefRevision: String? = nil,
        suggestionSnapshotID: String? = nil,
        suggestions: [TaskSuggestion] = [],
        counts: BriefCounts,
        blocked: [BriefItem],
        overdue: [BriefItem],
        scheduledToday: [BriefItem],
        completedToday: [BriefItem],
        markdown: String? = nil,
        summary: String? = nil,
        headline: String? = nil,
        transcriptMarkdown: String? = nil,
        transcriptSummary: String? = nil,
        briefSessionKey: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.briefRevision = briefRevision
        self.suggestionSnapshotID = suggestionSnapshotID
        self.suggestions = suggestions
        self.counts = counts
        self.blocked = blocked
        self.overdue = overdue
        self.scheduledToday = scheduledToday
        self.completedToday = completedToday
        self.markdown = markdown
        self.summary = summary
        self.headline = headline
        self.transcriptMarkdown = transcriptMarkdown
        self.transcriptSummary = transcriptSummary
        self.briefSessionKey = briefSessionKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        briefRevision = try container.decodeIfPresent(String.self, forKey: .briefRevision)
        suggestionSnapshotID = try container.decodeIfPresent(String.self, forKey: .suggestionSnapshotID)
        suggestions = try container.decodeIfPresent([TaskSuggestion].self, forKey: .suggestions) ?? []
        counts = try container.decode(BriefCounts.self, forKey: .counts)
        blocked = try container.decode([BriefItem].self, forKey: .blocked)
        overdue = try container.decode([BriefItem].self, forKey: .overdue)
        scheduledToday = try container.decode([BriefItem].self, forKey: .scheduledToday)
        completedToday = try container.decode([BriefItem].self, forKey: .completedToday)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        transcriptMarkdown = try container.decodeIfPresent(String.self, forKey: .transcriptMarkdown)
        transcriptSummary = try container.decodeIfPresent(String.self, forKey: .transcriptSummary)
        briefSessionKey = try container.decodeIfPresent(String.self, forKey: .briefSessionKey)
    }

    /// Full prose, trimmed; nil when the backend sent no markdown or only whitespace.
    public var briefMarkdown: String? {
        guard let markdown = markdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !markdown.isEmpty else { return nil }
        return markdown
    }

    /// The ONE title for this brief, or nil when the artifact carries no authored headline.
    ///
    /// Every surface that names the brief reads THIS — the Agenda summary card header and the
    /// orchestrator chat title. Before this existed the card synthesized a clock-based greeting
    /// ("Good morning") while the chat showed the brief's own first heading ("The Day"): two
    /// derivations of one artifact, guaranteed to disagree. Nil keeps each surface's prior
    /// fallback, so an artifact without a headline is never worse off than before.
    public var briefHeadline: String? {
        trimmed(headline)
    }

    /// Condensed prose, trimmed; nil when the backend sent no summary or only whitespace.
    public var briefSummary: String? {
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    /// Candidate prose for brief consumers. Durable transcript delivery wins while the
    /// backend-authored brief remains available separately for internal context; Agenda gates
    /// visibility with `hasAgendaSurface` so this fallback is never presented as delivered.
    public var displayedBriefMarkdown: String? {
        trimmed(transcriptMarkdown) ?? briefMarkdown
    }

    public var displayedBriefSummary: String? {
        trimmed(transcriptSummary) ?? briefSummary
    }

    /// The authored cache is useful only when the durable conversation has not
    /// delivered assistant prose yet. Once history exists, injecting any brief
    /// again would duplicate context already owned by that session.
    public var firstTurnContextMarkdown: String? {
        trimmed(transcriptMarkdown) == nil ? briefMarkdown : nil
    }

    /// Whether today's brief has a truthful, displayable Agenda surface. The backend advertises the
    /// durable session key only after proving canonical delivery, so that authority plus actual
    /// prose (or legacy structured counts) is enough to keep the doorway visible while client-side
    /// transcript reconciliation catches up. A route hint without content, or deterministic
    /// fallback content without canonical authority, remains hidden.
    public var hasAgendaSurface: Bool {
        guard briefSessionKey?.trimmingCharacters(in: .whitespacesAndNewlines) ==
            DailyBriefTranscriptReconciler.durableSessionKey
        else { return false }

        return displayedBriefSummary != nil ||
            displayedBriefMarkdown != nil ||
            counts.hasAnything
    }

    /// Preserve the authored brief and structured task snapshot while layering the
    /// latest delivered conversation prose onto the Agenda/read-aloud surface.
    public func replacingTranscriptProse(markdown: String?, summary: String?) -> DailyBrief {
        DailyBrief(
            generatedAt: generatedAt,
            briefRevision: briefRevision,
            suggestionSnapshotID: suggestionSnapshotID,
            suggestions: suggestions,
            counts: counts,
            blocked: blocked,
            overdue: overdue,
            scheduledToday: scheduledToday,
            completedToday: completedToday,
            markdown: self.markdown,
            summary: self.summary,
            headline: self.headline,
            transcriptMarkdown: markdown,
            transcriptSummary: summary,
            briefSessionKey: briefSessionKey
        )
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - API service

@MainActor
protocol BriefApiServiceProtocol {
    func fetchBrief() async throws -> DailyBrief
}

/// HTTP client for GET /api/v1/brief — the Daily Brief orchestrator surface.
@MainActor
final class RemBriefApiService: BriefApiServiceProtocol {
    /// Explicit capability handshake for the two-phase daily-chat rollout. Backends that
    /// understand it return the durable route; older backends ignore it and keep returning their
    /// legacy `rem-today-*` key (or no key), which the client continues to honor safely.
    static let conversationContinuityHeader = [
        "X-Rem-Conversation-Continuity": "durable-orchestrator-v1",
        "X-Rem-Suggestion-Contract": "atomic-v1"
    ]

    private let decoder = JSONDecoder()

    func fetchBrief() async throws -> DailyBrief {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/brief",
            method: "GET",
            customHeaders: Self.conversationContinuityHeader
        )
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw RemApiError.requestFailed(statusCode: http.statusCode, message: message)
        }
        return try decoder.decode(DailyBrief.self, from: data)
    }
}
