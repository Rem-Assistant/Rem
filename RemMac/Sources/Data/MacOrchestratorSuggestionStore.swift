import Foundation

struct MacOrchestratorBriefPayload: Decodable, Sendable {
    let generatedAt: String?
    let markdown: String?
    /// The brief's authored headline (`daily_brief_artifacts.headline`) — the one title string
    /// shared with iOS's Agenda card and with the orchestrator chat on both platforms.
    let headline: String?
    let briefRevision: String?
    let suggestionSnapshotID: String?
    let suggestions: [TaskSuggestion]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case markdown
        case headline
        case briefRevision = "brief_revision"
        case suggestionSnapshotID = "suggestion_snapshot_id"
        case suggestions
    }

    init(
        generatedAt: String?,
        markdown: String?,
        headline: String? = nil,
        briefRevision: String? = nil,
        suggestionSnapshotID: String? = nil,
        suggestions: [TaskSuggestion] = []
    ) {
        self.generatedAt = generatedAt
        self.markdown = markdown
        self.headline = headline
        self.briefRevision = briefRevision
        self.suggestionSnapshotID = suggestionSnapshotID
        self.suggestions = suggestions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        briefRevision = try container.decodeIfPresent(String.self, forKey: .briefRevision)
        suggestionSnapshotID = try container.decodeIfPresent(String.self, forKey: .suggestionSnapshotID)
        suggestions = try container.decodeIfPresent([TaskSuggestion].self, forKey: .suggestions) ?? []
    }
}

/// One macOS owner for the Today brief identity and its attributed task proposals. It uses the
/// same authenticated backend and the existing window-owned `MacTaskStore`; no second task cache
/// or transcript timeline is created for Chat.
@MainActor @Observable
final class MacOrchestratorSuggestionStore {
    enum AcceptanceResult {
        case alreadyApplied
        case publish(MacTask)
    }

    typealias BriefLoader = @MainActor () async throws -> MacOrchestratorBriefPayload
    typealias Dismissal = @MainActor (
        String,
        MacAuthenticatedHttpClient.RequestAuthority
    ) async throws -> Void
    typealias Acceptance = @MainActor (
        TaskSuggestion,
        MacTaskStore,
        MacAuthenticatedHttpClient.RequestAuthority
    ) async -> AcceptanceResult?
    typealias AuthorityProvider = @MainActor (String) -> MacAuthenticatedHttpClient.RequestAuthority?

    private struct ActionAuthority {
        let scopeID: String
        let refreshGeneration: UInt64
        let suggestion: TaskSuggestion
        let requestAuthority: MacAuthenticatedHttpClient.RequestAuthority
    }

    private struct MutationClaim: Hashable {
        let scopeID: String
        let actionID: String
    }

    private(set) var snapshot: OrchestratorSuggestionSnapshot?
    private(set) var scopeID: String?
    /// Backend JWT subject for the scope currently loaded, retained so a midnight refresh can
    /// re-publish the headline under the same account without the caller re-supplying it.
    private(set) var accountID: String?
    private var refreshGeneration: UInt64 = 0
    private var snapshotCalendar: Calendar = .current
    private var mutationClaimsInFlight: Set<MutationClaim> = []

    private let briefLoader: BriefLoader
    private let dismissal: Dismissal
    private let acceptance: Acceptance
    private let authorityProvider: AuthorityProvider
    private let now: @MainActor () -> Date

    init(
        briefLoader: @escaping BriefLoader = MacOrchestratorSuggestionStore.loadBrief,
        dismissal: @escaping Dismissal = MacOrchestratorSuggestionStore.dismiss,
        acceptance: Acceptance? = nil,
        authorityProvider: AuthorityProvider? = nil,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.briefLoader = briefLoader
        self.dismissal = dismissal
        self.acceptance = acceptance ?? { suggestion, taskStore, authority in
            await MacOrchestratorSuggestionStore.performAccept(
                suggestion,
                taskStore: taskStore,
                authority: authority
            )
        }
        self.authorityProvider = authorityProvider ?? { scopeID in
            let pieces = scopeID.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count >= 2 else { return nil }
            return MacAuthenticatedHttpClient.captureRequestAuthority(
                expectedBackendURL: String(pieces[1])
            )
        }
        self.now = now
    }

    func snapshot(for scopeID: String, calendar: Calendar = .current) -> OrchestratorSuggestionSnapshot? {
        guard self.scopeID == scopeID,
              let snapshot,
              snapshot.isCurrentLocalDay(now: now(), calendar: calendar)
        else { return nil }
        return snapshot
    }

    func invalidate() {
        refreshGeneration &+= 1
        snapshot = nil
        scopeID = nil
        accountID = nil
        // The published headline belongs to the scope being retired. Leaving it would let the
        // previous account's prose title the chat until the next brief lands.
        BriefContext.clearOrchestratorHeadline()
    }

    /// SwiftUI delivers the live account/backend/gateway change synchronously, before the Task
    /// that loads its replacement snapshot begins. Retire the old generation in that synchronous
    /// callback so a suspended action cannot reach dismissal during the scheduling gap.
    func invalidateForScopeChange(to liveScopeID: String) {
        guard scopeID != liveScopeID else { return }
        invalidate()
    }

    /// Midnight invalidation must also begin a new authoritative Today refresh. Retain the
    /// authenticated account/backend/gateway scope while replacing the prior-day snapshot.
    func refreshForCalendarDayChange(calendar: Calendar = .current) async {
        guard let scopeID else {
            invalidate()
            return
        }
        await refresh(scopeID: scopeID, accountID: accountID, calendar: calendar)
    }

    /// Refresh the canonical brief before its suggestions. Clearing first prevents a retained
    /// same-day snapshot from a previous gateway or an older check-in from flashing during load.
    /// `accountID` is the backend JWT subject the chat views read the headline back with
    /// (`authenticatedAccountIDForRecovery`). `scopeID` is a broader account+backend+gateway
    /// fence and is NOT interchangeable with it.
    func refresh(scopeID: String, accountID: String?, calendar: Calendar = .current) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        self.scopeID = scopeID
        self.accountID = accountID
        snapshot = nil
        do {
            let brief = try await briefLoader()
            guard generation == refreshGeneration,
                  self.scopeID == scopeID,
                  let identity = OrchestratorSuggestionBriefIdentity(
                    generatedAt: brief.generatedAt,
                    authoredMarkdown: brief.markdown,
                    authoredRevision: brief.briefRevision
                  ),
                  identity.isCurrentLocalDay(now: now(), calendar: calendar)
            else { return }

            // Publish the authored headline so the Mac orchestrator chat titles itself with the
            // same string iOS shows — one field, not a per-platform derivation.
            //
            // BELOW the guard, deliberately. `BriefContext` is process-wide shared state, so
            // publishing before the generation/scope check let a late response from a SUPERSEDED
            // scope title the chat with the previous account's headline while its snapshot was
            // correctly discarded — a visible cross-scope leak of model-authored prose. Anything
            // that fails the guard must publish nothing; the refresh that wins publishes instead.
            BriefContext.setOrchestratorHeadline(brief.headline, accountID: accountID)

            snapshot = OrchestratorSuggestionSnapshot(
                identity: identity,
                snapshotID: brief.suggestionSnapshotID,
                briefMarkdown: brief.markdown,
                suggestions: brief.suggestions
            )
            snapshotCalendar = calendar
        } catch {
            guard generation == refreshGeneration, self.scopeID == scopeID else { return }
            snapshot = nil
        }
    }

    func accept(
        _ suggestion: TaskSuggestion,
        taskStore: MacTaskStore,
        scopeID: String
    ) async {
        guard let authority = beginAction(suggestion, scopeID: scopeID) else { return }
        let claim = MutationClaim(scopeID: scopeID, actionID: suggestion.actionId)
        defer {
            mutationClaimsInFlight.remove(claim)
        }
        removeOptimistically(suggestion, authority: authority)
        let result = await acceptance(suggestion, taskStore, authority.requestAuthority)
        guard isCurrent(authority) else { return }
        guard let result else {
            await refresh(scopeID: scopeID, accountID: accountID)
            return
        }
        if case let .publish(task) = result {
            // Suggestion-scoped network helpers deliberately return an unpublished task. Commit
            // it to the window cache only while the owner that captured the request is current.
            taskStore.publishSuggestionMutation(task)
        }
        do {
            try await dismissal(suggestion.key, authority.requestAuthority)
        } catch {
            guard isCurrent(authority) else { return }
            // The task mutation is already authoritative. Refetch so a failed durable dismissal is
            // visible/retryable instead of silently pretending the proposal lifecycle completed.
            await refresh(scopeID: scopeID, accountID: accountID)
        }
    }

    func dismissSuggestion(_ suggestion: TaskSuggestion, scopeID: String) async {
        guard let authority = beginAction(suggestion, scopeID: scopeID) else { return }
        let claim = MutationClaim(scopeID: scopeID, actionID: suggestion.actionId)
        defer {
            mutationClaimsInFlight.remove(claim)
        }
        removeOptimistically(suggestion, authority: authority)
        do {
            try await dismissal(suggestion.key, authority.requestAuthority)
        } catch {
            guard isCurrent(authority) else { return }
            await refresh(scopeID: scopeID, accountID: accountID)
        }
    }

    private static func performAccept(
        _ suggestion: TaskSuggestion,
        taskStore: MacTaskStore,
        authority: MacAuthenticatedHttpClient.RequestAuthority
    ) async -> AcceptanceResult? {
        let startDate = suggestion.action.startDate.flatMap(TaskComment.parseISO8601)
        switch suggestion.action.kind {
        case "createTask":
            guard UUID(uuidString: suggestion.actionId) != nil else { return nil }
            let title = suggestion.action.taskTitle ?? suggestion.title
            if taskStore.allTasks.contains(where: {
                TaskSuggestionCreateDeduplication.matchesExistingTask(
                    for: suggestion,
                    taskID: $0.id
                )
            }) { return .alreadyApplied }
            var params: [String: Any] = ["id": suggestion.actionId, "title": title]
            if let startDate {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                params["start_date"] = formatter.string(from: startDate)
            }
            guard let task = await taskStore.createSuggestionTask(params, authority: authority) else {
                return nil
            }
            return .publish(task)

        case "rescheduleTask":
            guard let targetID = suggestion.action.targetTaskId,
                  let task = taskStore.allTasks.first(where: { $0.id == targetID }),
                  let startDate
            else { return nil }
            guard let task = await taskStore.scheduleSuggestionTask(
                task,
                startDate: startDate,
                authority: authority
            ) else { return nil }
            return .publish(task)

        default:
            return nil
        }
    }

    private func beginAction(
        _ suggestion: TaskSuggestion,
        scopeID: String
    ) -> ActionAuthority? {
        guard self.scopeID == scopeID,
              let snapshot,
              snapshot.isCurrentLocalDay(now: now(), calendar: snapshotCalendar),
              snapshot.suggestions.contains(suggestion),
              let requestAuthority = authorityProvider(scopeID)
        else { return nil }
        let authority = ActionAuthority(
            scopeID: scopeID,
            refreshGeneration: refreshGeneration,
            suggestion: suggestion,
            requestAuthority: requestAuthority
        )
        let claim = MutationClaim(scopeID: scopeID, actionID: suggestion.actionId)
        guard mutationClaimsInFlight.insert(claim).inserted else { return nil }
        return authority
    }

    private func isCurrent(_ authority: ActionAuthority) -> Bool {
        scopeID == authority.scopeID && refreshGeneration == authority.refreshGeneration
    }

    private func removeOptimistically(
        _ suggestion: TaskSuggestion,
        authority: ActionAuthority
    ) {
        guard isCurrent(authority), let snapshot else { return }
        self.snapshot = OrchestratorSuggestionSnapshot(
            identity: snapshot.identity,
            snapshotID: snapshot.snapshotID,
            briefMarkdown: snapshot.briefMarkdown,
            suggestions: snapshot.suggestions.filter { $0.key != suggestion.key }
        )
    }

    private static func loadBrief() async throws -> MacOrchestratorBriefPayload {
        let (data, response) = try await MacAuthenticatedHttpClient.request(
            path: "/api/v1/brief",
            method: "GET",
            customHeaders: [
                "X-Rem-Conversation-Continuity": "durable-orchestrator-v1",
                "X-Rem-Suggestion-Contract": "atomic-v1"
            ]
        )
        guard (200...299).contains(response.statusCode) else {
            throw MacAuthenticatedHttpError.httpError(statusCode: response.statusCode)
        }
        return try JSONDecoder().decode(MacOrchestratorBriefPayload.self, from: data)
    }

    private static func dismiss(
        _ key: String,
        authority: MacAuthenticatedHttpClient.RequestAuthority
    ) async throws {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let (data, response) = try await MacAuthenticatedHttpClient.request(
            path: "/api/v1/suggestions/\(encoded)/dismiss",
            method: "POST",
            authority: authority
        )
        _ = data
        guard (200...299).contains(response.statusCode) else {
            throw MacAuthenticatedHttpError.httpError(statusCode: response.statusCode)
        }
    }
}
