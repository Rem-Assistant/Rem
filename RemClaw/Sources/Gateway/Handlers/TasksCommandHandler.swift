import Foundation
import OpenClawKit
import SwiftData

@MainActor
enum TasksCommandHandler {

    private enum DurabilityError: LocalizedError {
        case serviceUnavailable

        var errorDescription: String? { "Task persistence is unavailable." }
    }

    private static var modelContextProvider: (() -> ModelContext?)?
    private static var taskSyncServiceProvider: (() -> TaskSyncServiceProtocol?)?
    private static var taskApiServiceProvider: (() -> TaskApiServiceProtocol?)?
    private static var organizationApiServiceProvider: (() -> OrganizationApiService?)?
    private static var createFlights: [UUID: Task<BridgeInvokeResponse, Never>] = [:]
    private static let calendarService = CalendarGatewayService()

    static func configure(
        modelContext: @escaping @MainActor () -> ModelContext?,
        taskSyncService: @escaping @MainActor () -> TaskSyncServiceProtocol?,
        taskApiService: @escaping @MainActor () -> TaskApiServiceProtocol?,
        organizationApiService: @escaping @MainActor () -> OrganizationApiService? = { nil }
    ) {
        modelContextProvider = modelContext
        taskSyncServiceProvider = taskSyncService
        taskApiServiceProvider = taskApiService
        organizationApiServiceProvider = organizationApiService
        // Reconfiguration means a different store or account: nothing learned about the
        // old one's freshness carries over, and an in-flight pull belongs to the old one.
        lastTaskRefreshAt = nil
        refreshFlight = nil
    }

    // MARK: - List

    static func handleList(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "tasks are unavailable before app initialization")
        }

        let params: TasksListParams
        if let decoded: TasksListParams = InvocationHelpers.decodeParams(req) {
            params = decoded
        } else {
            params = TasksListParams()
        }

        let descriptor = FetchDescriptor<TaskEvent>(
            sortBy: [SortDescriptor(\TaskEvent.createdAt, order: .reverse)]
        )
        let allTasks: [TaskEvent]
        do {
            allTasks = try modelContext.fetch(descriptor)
        } catch {
            return InvocationHelpers.error(req, "failed to load tasks")
        }

        let filtered = allTasks.filter { task in
            if let status = params.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !status.isEmpty,
               task.status.lowercased() != status {
                return false
            }

            if let type = normalizeTaskType(params.type) {
                if type == "calendar_event", !task.isEvent {
                    return false
                }
                if type == "task", task.isEvent {
                    return false
                }
            }

            if let sinceDate = InvocationHelpers.parseISODate(params.since), task.updatedAt <= sinceDate {
                return false
            }

            return true
        }

        let total = filtered.count
        let limit = min(max(params.limit ?? 50, 1), 200)
        let offset = max(params.offset ?? 0, 0)
        let page = Array(filtered.dropFirst(offset).prefix(limit))
        let organization: OrganizationLookup
        do {
            organization = try organizationLookup(in: modelContext)
        } catch {
            return InvocationHelpers.error(req, "failed to load task organization")
        }

        return InvocationHelpers.encodeSuccess(req, TasksListResponse(
            tasks: page.map { taskPayload(from: $0, organization: organization) },
            total: total,
            limit: limit,
            offset: offset,
            hasMore: offset + limit < total
        ))
    }

    // MARK: - Get

    static func handleGet(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "tasks are unavailable before app initialization")
        }
        guard let params: TasksGetParams = InvocationHelpers.decodeParams(req),
              let taskID = UUID(uuidString: params.id) else {
            return InvocationHelpers.invalidParams(req, "tasks.get requires a valid task id")
        }

        let descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.id == taskID }
        )
        let task: TaskEvent
        do {
            guard let found = try modelContext.fetch(descriptor).first else {
                return InvocationHelpers.invalidParams(req, "TASK_NOT_FOUND")
            }
            task = found
        } catch {
            return InvocationHelpers.error(req, "failed to load task")
        }
        let organization: OrganizationLookup
        do {
            organization = try organizationLookup(in: modelContext)
        } catch {
            return InvocationHelpers.error(req, "failed to load task organization")
        }
        return InvocationHelpers.encodeSuccess(req, TasksGetResponse(
            task: taskPayload(from: task, organization: organization)
        ))
    }

    // MARK: - Search

    /// Resolve a task by NAME.
    ///
    /// Why this exists: the daily brief names tasks in prose and nothing else.
    /// `renderBucket` (`backend/src/services/brief-authoring.service.ts`) interpolates
    /// only `it.title`, and `chat.inject` (`backend/src/services/gateway-agent.service.ts`)
    /// posts `{ sessionKey, message }` with no metadata — so ids never reach the chat
    /// turn. `tasks.get` requires a UUID and `tasks.list` has no title filter, which
    /// left the agent holding a name it could not look up: asked how it knew about an
    /// item in its own brief, it would truthfully report no record of the work and
    /// blame "an earlier agent run".
    ///
    /// Matching is fuzzy on purpose. The brief's author model may reword a title, and
    /// `inlineTitle` truncates at 120 chars with an ellipsis, so equality would miss.
    /// Read-only: this never mutates, and it matches titles only — never `notes`.
    static func handleSearch(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "tasks are unavailable before app initialization")
        }
        guard let params: TasksSearchParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "tasks.search requires a query")
        }

        let rawQuery = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalizeForSearch(rawQuery)
        guard !normalizedQuery.isEmpty else {
            return InvocationHelpers.invalidParams(req, "tasks.search requires a non-empty query")
        }

        // Refresh BEFORE reading. The whole point of this command is answering about work
        // the backend orchestrator did — it updates a task, authors a brief naming it, and
        // the user asks about it while the app has been sitting resident. Searching the
        // local snapshot alone would miss that task, or report its old runStatus, and the
        // agent would fall back to "I have no record" — the defect, reproduced through
        // the fix. Foregrounding reconnects the gateway but does not refresh tasks.
        var freshness = await ensureFreshTasks()

        let descriptor = FetchDescriptor<TaskEvent>(
            sortBy: [SortDescriptor(\TaskEvent.updatedAt, order: .reverse)]
        )
        let allTasks: [TaskEvent]
        do {
            allTasks = try modelContext.fetch(descriptor)
        } catch {
            return InvocationHelpers.error(req, "failed to load tasks")
        }

        // A pull that succeeds and yields nothing still leaves the device unable to
        // support a negative. Wrong account scoping or a backend regression returns an
        // empty list as a success, and the agent is told elsewhere that an empty
        // `matches` means the user has no such task — which would rebuild "I have no
        // record" through a path where `stale` never fires.
        if allTasks.isEmpty, !freshness.stale {
            freshness = (
                true,
                "the device has no tasks stored at all, so it cannot confirm that a task does not exist"
            )
        }

        let statusFilter = normalizedOptionalString(params.status)?.lowercased()
        let typeFilter = normalizeTaskType(params.type)

        let candidates = allTasks.filter { task in
            if let statusFilter, task.status.lowercased() != statusFilter { return false }
            if let typeFilter {
                if typeFilter == "calendar_event", !task.isEvent { return false }
                if typeFilter == "task", task.isEvent { return false }
            }
            return true
        }

        let organization: OrganizationLookup
        do {
            organization = try organizationLookup(in: modelContext)
        } catch {
            return InvocationHelpers.error(req, "failed to load task organization")
        }

        // Score, drop everything under the relevance floor, then rank. `fetch` already
        // sorted by `updatedAt` descending, and `sorted(by:)` is stable in practice for
        // our sizes — but ties are broken explicitly so ranking can't drift.
        let scored: [(task: TaskEvent, score: Double, matchedOn: String)] = candidates.compactMap { task in
            guard let hit = scoreTitle(task.title, against: normalizedQuery) else { return nil }
            return (task, hit.score, hit.matchedOn)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.task.updatedAt > rhs.task.updatedAt
        }

        let limit = min(max(params.limit ?? 10, 1), 50)
        let page = scored.prefix(limit)

        return InvocationHelpers.encodeSuccess(req, TasksSearchResponse(
            query: rawQuery,
            matches: page.map { hit in
                TaskSearchMatch(
                    task: searchPayload(from: hit.task, organization: organization),
                    score: hit.score,
                    matchedOn: hit.matchedOn
                )
            },
            total: scored.count,
            limit: limit,
            hasMore: scored.count > limit,
            stale: freshness.stale,
            staleReason: freshness.reason
        ))
    }

    // MARK: - Freshness

    /// How long a completed refresh is trusted. An agent commonly calls `tasks.search`
    /// several times inside one turn (a brief naming three tasks is three lookups), and
    /// a full pull per call would put a network round-trip in front of each one. 15s is
    /// long enough that a multi-call turn syncs once, and short enough that any fresh
    /// user question crosses it — the window is scoped to a turn, not to a session.
    ///
    /// Settable so tests can pin its effect in both directions; nothing in the app
    /// changes it.
    static var taskFreshnessWindow: TimeInterval = 15

    private static var lastTaskRefreshAt: Date?

    /// The one in-flight pull. `ensureFreshTasks` reads `lastTaskRefreshAt`, awaits, then
    /// writes it, so two searches arriving together would both pass the window check and
    /// both start a reconcile. Today that is unreachable only because upstream's
    /// `GatewayChannel.listen()` re-arms `receive` after `await handle(msg)` — an
    /// invariant Rem neither owns nor documents, so this does not rely on it. Same flight
    /// pattern this file already uses for `tasks.create`.
    private static var refreshFlight: Task<Bool, Never>?

    /// Pulls the backend snapshot before a read, and reports whether the answer is being
    /// served from stale data. Failure is deliberately NOT fatal: a stale answer that
    /// says it might be stale is far better than "I have no record", which is the exact
    /// failure this command exists to end.
    private static func ensureFreshTasks() async -> (stale: Bool, reason: String?) {
        if let lastTaskRefreshAt,
           Date().timeIntervalSince(lastTaskRefreshAt) < taskFreshnessWindow {
            return (false, nil)
        }
        guard let syncService = taskSyncServiceProvider?() else {
            return (true, "task sync is unavailable on this device, so this is its last-known copy")
        }

        let flight: Task<Bool, Never>
        if let existing = refreshFlight {
            flight = existing
        } else {
            // The flight records its own outcome and retires itself, so a caller that
            // stops waiting cannot leave a stale flight or a phantom freshness behind.
            flight = Task { @MainActor in
                let reconciled = await syncService.refreshFromBackend()
                refreshFlight = nil
                if reconciled { lastTaskRefreshAt = Date() }
                return reconciled
            }
            refreshFlight = flight
        }

        if await flight.value {
            return (false, nil)
        }
        // Deliberately not "could not reach the backend": the refresh may have completed
        // the network round-trip and still not reconciled — a held-back local edit, a
        // failed save. Claiming a cause we did not observe hands the model a false fact.
        return (true, "the device could not complete a refresh, so this is its last-known copy")
    }

    // MARK: - Search scoring

    /// Case-, diacritic-, and punctuation-insensitive normalization.
    ///
    /// Every non-alphanumeric scalar collapses to a single space, which is what makes
    /// the brief's own decorations survive the round trip: `**bold**` emphasis
    /// (`brief.service.ts` wraps titles in `**…**`), the `—` em-dashes in
    /// "🔴 Blocked — <title> — <activity>", and the `…` that `inlineTitle` appends when
    /// it truncates at 120 chars all normalize away instead of blocking a match.
    static func normalizeForSearch(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var out = ""
        out.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Function words carry no identifying signal, so a query made only of them must
    /// not resolve to anything. Deliberately small: this is a noise floor, not stemming.
    private static let searchStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "in",
        "into", "is", "it", "of", "on", "or", "the", "this", "that", "to", "was",
        "were", "with",
    ]

    private static func substantiveTokens<S: Sequence>(in tokens: S) -> [String]
    where S.Element == String {
        tokens.filter { !searchStopwords.contains($0) }
    }

    private static func substantiveTokens(in normalized: String) -> [String] {
        substantiveTokens(in: normalized.split(separator: " ").map(String.init))
    }

    /// Tiered relevance. Returns `nil` when the title is below the floor, so a search
    /// for a task the user does not have comes back empty rather than confidently wrong.
    private static func scoreTitle(
        _ title: String,
        against normalizedQuery: String
    ) -> (score: Double, matchedOn: String)? {
        let normalizedTitle = normalizeForSearch(title)
        guard !normalizedTitle.isEmpty else { return nil }

        if normalizedTitle == normalizedQuery {
            return (1.0, "exact")
        }

        // Below exact match BOTH sides must carry real signal. Guarding only the query was
        // a bug: a task titled "It" or "A" is a raw substring of nearly every query
        // ("subm-IT the report"), so it matched everything at a confident-looking score.
        // A title of pure function words can only ever match exactly.
        guard !substantiveTokens(in: normalizedQuery).isEmpty,
              !substantiveTokens(in: normalizedTitle).isEmpty else { return nil }

        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        let titleTokens = normalizedTitle.split(separator: " ").map(String.init)
        guard !queryTokens.isEmpty, !titleTokens.isEmpty else { return nil }

        // Matching is token-aligned rather than raw-substring, which is what supplies the
        // word boundary: "it" no longer matches inside "submit".
        //
        // Scores scale with coverage instead of being flat. A flat 0.9 made "Call" and
        // "Call Dana about the lease renewal" indistinguishable for a truncated query, so
        // the tie broke on `updatedAt` and the wrong task could rank first.
        if let coverage = prefixCoverage(titleTokens: titleTokens, queryTokens: queryTokens) {
            return (0.55 + 0.35 * coverage, "prefix")
        }

        if let coverage = containmentCoverage(titleTokens: titleTokens, queryTokens: queryTokens) {
            return (0.45 + 0.30 * coverage, "contains")
        }

        // Reworded titles: how much of the query is present in the title?
        let titleTokenSet = Set(titleTokens)
        let matched = queryTokens.filter { titleTokenSet.contains($0) }
        // The overlap itself must be substantive — matching only on "to the" is noise.
        guard !substantiveTokens(in: matched).isEmpty else { return nil }

        let coverage = Double(matched.count) / Double(queryTokens.count)
        guard coverage >= 0.6 else { return nil }
        return (0.4 + coverage * 0.3, "tokens")
    }

    /// One side is a leading run of whole words of the other. The final token may be a
    /// partial word, because the brief truncates at 120 chars and can cut mid-word.
    /// Returns shorter/longer token coverage, so a one-word query against a six-word title
    /// scores far below a near-complete quotation of it.
    private static func prefixCoverage(titleTokens: [String], queryTokens: [String]) -> Double? {
        func isPrefix(_ needle: [String], of haystack: [String]) -> Bool {
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            for index in 0..<(needle.count - 1) where needle[index] != haystack[index] {
                return false
            }
            return haystack[needle.count - 1].hasPrefix(needle[needle.count - 1])
        }

        if isPrefix(queryTokens, of: titleTokens) {
            return Double(queryTokens.count) / Double(titleTokens.count)
        }
        if isPrefix(titleTokens, of: queryTokens) {
            return Double(titleTokens.count) / Double(queryTokens.count)
        }
        return nil
    }

    /// One side appears as a contiguous run of whole words inside the other.
    private static func containmentCoverage(titleTokens: [String], queryTokens: [String]) -> Double? {
        func contains(_ haystack: [String], _ needle: [String]) -> Bool {
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            for start in 0...(haystack.count - needle.count) {
                var matches = true
                for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                    matches = false
                    break
                }
                if matches { return true }
            }
            return false
        }

        if contains(titleTokens, queryTokens) {
            return Double(queryTokens.count) / Double(titleTokens.count)
        }
        if contains(queryTokens, titleTokens) {
            return Double(titleTokens.count) / Double(queryTokens.count)
        }
        return nil
    }

    // MARK: - Create

    static func handleCreate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let taskID = InvocationHelpers.stableResourceID(
            for: req,
            namespace: RemTasksCommand.create.rawValue
        )
        if let flight = createFlights[taskID] {
            return await flight.value
        }

        let flight = Task { @MainActor in
            await performCreate(req, taskID: taskID)
        }
        createFlights[taskID] = flight
        let response = await flight.value
        createFlights[taskID] = nil
        return response
    }

    private static func performCreate(
        _ req: BridgeInvokeRequest,
        taskID: UUID
    ) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "tasks are unavailable before app initialization")
        }
        guard let params: TasksCreateParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "tasks.create requires at least a title")
        }

        let title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return InvocationHelpers.invalidParams(req, "tasks.create requires a non-empty title")
        }

        let startDate = InvocationHelpers.parseISODate(params.resolvedStartDate)
        var endDate = InvocationHelpers.parseISODate(params.endDate)
        let durationSeconds = params.durationMinutes.map { TimeInterval(max(0, $0) * 60) }
        if endDate == nil, let startDate, let durationSeconds {
            endDate = startDate.addingTimeInterval(durationSeconds)
        }

        #if DEBUG
        print("[TaskCreate] startDate=\(params.startDate ?? "nil") dueDate=\(params.dueDate ?? "nil") resolved=\(params.resolvedStartDate ?? "nil") parsed=\(startDate?.description ?? "nil")")
        #endif

        let normalizedType = normalizeTaskType(params.type)
        let isEvent = normalizedType == "calendar_event"
        let resolvedStatus: String?
        if let rawStatus = params.status {
            guard let normalized = normalizeBackendStatus(rawStatus) else {
                return InvocationHelpers.invalidParams(req, "tasks.create requires a supported status")
            }
            resolvedStatus = normalized
        } else {
            resolvedStatus = nil
        }

        let existingDescriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == taskID })
        do {
            if let existing = try modelContext.fetch(existingDescriptor).first {
                // A stable local row is not itself proof that the backend create committed:
                // the app may have stopped after the local save, or this may be a concurrent
                // redelivery while the first create is suspended. Re-enter the durable sync
                // path so success requires either backend persistence or a saved retry intent.
                try await syncTaskCreate(existing)
                let organization = try organizationLookup(in: modelContext)
                return InvocationHelpers.encodeSuccess(req, TasksCreateResponse(
                    task: taskPayload(from: existing, organization: organization)
                ))
            }
        } catch {
            return InvocationHelpers.error(req, "failed to reconcile retried task creation")
        }

        let task = TaskEvent(
            id: taskID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            duration: durationSeconds,
            alertTime: InvocationHelpers.parseISODate(params.alertTime),
            repeatFrequency: normalizedOptionalString(params.repeatFrequency),
            notes: normalizedOptionalString(params.notes),
            isEvent: isEvent,
            isAnyTime: params.isAnyTime ?? false,
            priority: priorityEnum(from: params.priority),
            status: startDate != nil ? .scheduled : .todo
        )

        if let normalizedPriority = normalizeBackendPriority(params.priority) {
            task.priority = normalizedPriority
        }
        if let resolvedStatus {
            task.status = resolvedStatus
        }
        // Organization: never silently turn a malformed/missing List into "unfiled".
        if let rawListID = params.listId {
            let trimmed = rawListID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let listID = UUID(uuidString: trimmed) else {
                return InvocationHelpers.invalidParams(req, "tasks.create requires a valid list id")
            }
            do {
                guard try listExists(listID, in: modelContext) else {
                    return InvocationHelpers.invalidParams(req, "LIST_NOT_FOUND")
                }
            } catch {
                return InvocationHelpers.error(req, "failed to validate list")
            }
            task.listID = listID
        }

        modelContext.insert(task)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(task)
            return InvocationHelpers.error(req, "failed to save task locally")
        }

        do {
            try await syncTaskCreate(task)
        } catch {
            modelContext.delete(task)
            try? modelContext.save()
            return InvocationHelpers.error(req, "failed to persist task")
        }
        let organization: OrganizationLookup
        do {
            organization = try organizationLookup(in: modelContext)
        } catch {
            return InvocationHelpers.error(req, "failed to load task organization")
        }
        return InvocationHelpers.encodeSuccess(req, TasksCreateResponse(
            task: taskPayload(from: task, organization: organization)
        ))
    }

    // MARK: - Update

    static func handleUpdate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "tasks are unavailable before app initialization")
        }
        guard let params: TasksUpdateParams = InvocationHelpers.decodeParams(req),
              let taskID = UUID(uuidString: params.id) else {
            return InvocationHelpers.invalidParams(req, "tasks.update requires a valid task id")
        }

        let hasUpdateField =
            params.title != nil ||
            params.priority != nil ||
            params.status != nil ||
            params.completed != nil ||
            params.startDate != nil ||
            params.dueDate != nil ||
            params.endDate != nil ||
            params.durationMinutes != nil ||
            params.alertTime != nil ||
            params.repeatFrequency != nil ||
            params.type != nil ||
            params.notes != nil ||
            params.isAnyTime != nil ||
            params.listId != nil
        guard hasUpdateField else {
            return InvocationHelpers.invalidParams(req, "tasks.update requires at least one field to update")
        }

        let descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.id == taskID }
        )
        let task: TaskEvent
        do {
            guard let found = try modelContext.fetch(descriptor).first else {
                return InvocationHelpers.invalidParams(req, "TASK_NOT_FOUND")
            }
            task = found
        } catch {
            return InvocationHelpers.error(req, "failed to load task")
        }

        // Resolve and validate organization before mutating any managed field. A rejected
        // List reference must leave the task unchanged in the live ModelContext.
        let resolvedListID: UUID?
        if let rawListID = params.listId {
            let trimmed = rawListID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                resolvedListID = nil
            } else {
                guard let parsed = UUID(uuidString: trimmed) else {
                    return InvocationHelpers.invalidParams(req, "tasks.update requires a valid list id")
                }
                do {
                    guard try listExists(parsed, in: modelContext) else {
                        return InvocationHelpers.invalidParams(req, "LIST_NOT_FOUND")
                    }
                } catch {
                    return InvocationHelpers.error(req, "failed to validate list")
                }
                resolvedListID = parsed
            }
        } else {
            resolvedListID = task.listID
        }

        // Resolve status aliases before touching the managed task. Unsupported values and
        // contradictory `status`/`completed` pairs are invalid input, not successful no-ops.
        var resolvedStatus: String?
        if let rawStatus = params.status {
            guard let normalized = normalizeBackendStatus(rawStatus) else {
                return InvocationHelpers.invalidParams(req, "tasks.update requires a supported status")
            }
            resolvedStatus = normalized
        }
        if let completed = params.completed {
            let completedStatus = completed ? "completed" : "pending"
            if let resolvedStatus, resolvedStatus != completedStatus {
                return InvocationHelpers.invalidParams(req, "tasks.update status conflicts with completed")
            }
            resolvedStatus = completedStatus
        }
        let original = TaskMutationSnapshot(task)

        if let title = params.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            task.title = title
        }
        if let priority = normalizeBackendPriority(params.priority) {
            task.priority = priority
        }
        if let status = resolvedStatus {
            task.status = status
        }
        if let startDate = InvocationHelpers.parseISODate(params.startDate) ?? InvocationHelpers.parseISODate(params.dueDate) {
            task.startDate = startDate
        }
        if let endDate = InvocationHelpers.parseISODate(params.endDate) {
            task.endDate = endDate
        }
        if let durationMinutes = params.durationMinutes {
            task.duration = TimeInterval(max(0, durationMinutes) * 60)
        }
        if let alertTime = InvocationHelpers.parseISODate(params.alertTime) {
            task.alertTime = alertTime
        }
        if let repeatFrequency = normalizedOptionalString(params.repeatFrequency) {
            task.repeatFrequency = repeatFrequency
        }
        if let notes = params.notes {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            task.notes = trimmed.isEmpty ? nil : trimmed
        }
        if let isAnyTime = params.isAnyTime {
            task.isAnyTime = isAnyTime
        }
        if let type = normalizeTaskType(params.type) {
            task.isEvent = type == "calendar_event"
            if !task.isEvent {
                task.calendarEventID = nil
            }
        }

        if task.endDate == nil,
           let startDate = task.startDate,
           let duration = task.duration {
            task.endDate = startDate.addingTimeInterval(duration)
        }

        task.listID = resolvedListID

        task.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            original.restore(task)
            try? modelContext.save()
            return InvocationHelpers.error(req, "failed to update task locally")
        }

        let attempted = TaskMutationSnapshot(task)
        do {
            try await syncTaskUpdate(task, includeListID: params.listId != nil)
        } catch {
            original.restoreValuesStillMatching(attempted, on: task)
            try? modelContext.save()
            return InvocationHelpers.error(req, "failed to persist task update")
        }
        let organization: OrganizationLookup
        do {
            organization = try organizationLookup(in: modelContext)
        } catch {
            return InvocationHelpers.error(req, "failed to load task organization")
        }
        return InvocationHelpers.encodeSuccess(req, TasksUpdateResponse(
            task: taskPayload(from: task, organization: organization)
        ))
    }

    // MARK: - Delete

    static func handleDelete(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let modelContext = modelContextProvider?() else {
            return InvocationHelpers.unavailable(req, "tasks are unavailable before app initialization")
        }
        guard let params: TasksDeleteParams = InvocationHelpers.decodeParams(req),
              let taskID = UUID(uuidString: params.id) else {
            return InvocationHelpers.invalidParams(req, "tasks.delete requires a valid task id")
        }

        let descriptor = FetchDescriptor<TaskEvent>(
            predicate: #Predicate<TaskEvent> { $0.id == taskID }
        )
        guard let task = try? modelContext.fetch(descriptor).first else {
            return InvocationHelpers.invalidParams(req, "TASK_NOT_FOUND")
        }

        if task.isEvent, let calendarEventID = task.calendarEventID {
            do {
                _ = try await calendarService.deleteEvent(eventId: calendarEventID)
            } catch CalendarError.eventNotFound {
                // Stale EventKit identifier — treat as already deleted
            } catch {
                return InvocationHelpers.permissionOrError(req, error)
            }
        } else if task.isEvent, task.isCalendarOnlyMirror == true {
            TaskNotificationService.shared.cancelNotification(for: task.id)
            modelContext.delete(task)
            try? modelContext.save()
            return InvocationHelpers.encodeSuccess(req, TasksDeleteResponse(deleted: true, id: taskID.uuidString))
        }

        if task.isCalendarOnlyMirror != true {
            if let taskApiService = taskApiServiceProvider?() {
                do {
                    try await taskApiService.deleteTask(id: task.id.uuidString)
                    if let syncService = taskSyncServiceProvider?(),
                       await syncService.recordConfirmedDelete(for: task.id) == false {
                        return InvocationHelpers.error(req, "failed to persist confirmed task deletion")
                    }
                } catch {
                    let queued = await taskSyncServiceProvider?()?.queueOperation(
                        operationType: "delete",
                        taskId: task.id,
                        taskData: nil
                    ) ?? false
                    guard queued else {
                        return InvocationHelpers.error(req, "failed to persist task deletion for retry")
                    }
                }
            } else {
                let queued = await taskSyncServiceProvider?()?.queueOperation(
                    operationType: "delete",
                    taskId: task.id,
                    taskData: nil
                ) ?? false
                guard queued else {
                    return InvocationHelpers.error(req, "failed to persist task deletion for retry")
                }
            }
        }

        TaskNotificationService.shared.cancelNotification(for: task.id)
        modelContext.delete(task)
        do {
            try modelContext.save()
        } catch {
            return InvocationHelpers.error(req, "failed to delete task locally")
        }

        return InvocationHelpers.encodeSuccess(req, TasksDeleteResponse(deleted: true, id: taskID.uuidString))
    }

    // MARK: - Sync Helpers

    private static func syncTaskCreate(_ task: TaskEvent) async throws {
        if let taskSyncService = taskSyncServiceProvider?() {
            _ = try await taskSyncService.syncTaskCreateToBackendImmediately(task)
            return
        }

        if let taskApiService = taskApiServiceProvider?() {
            if task.isEvent {
                let dateTime = InvocationHelpers.formatISODate(task.startDate) ?? ""
                let durationMinutes = task.duration.map { Int($0 / 60) } ?? 30
                _ = try await taskApiService.saveEventToBackend(
                    id: task.id.uuidString,
                    title: task.title,
                    dateTime: dateTime,
                    durationMinutes: durationMinutes,
                    listID: task.listID?.uuidString
                )
            } else {
                _ = try await taskApiService.saveTaskToBackend(
                    id: task.id.uuidString,
                    title: task.title,
                    priority: task.priority,
                    status: task.status,
                    startDate: task.startDate,
                    endDate: task.endDate,
                    durationMinutes: task.duration.map { Int($0 / 60) },
                    alertTime: task.alertTime,
                    repeatFrequency: task.repeatFrequency,
                    listID: task.listID?.uuidString
                )
            }
            return
        }
        throw DurabilityError.serviceUnavailable
    }

    private static func syncTaskUpdate(_ task: TaskEvent, includeListID: Bool) async throws {
        if let taskSyncService = taskSyncServiceProvider?() {
            try await taskSyncService.syncTaskToBackendImmediately(
                task,
                includeListID: includeListID
            )
            return
        }

        if let taskApiService = taskApiServiceProvider?() {
            _ = try await taskApiService.updateTask(
                id: task.id.uuidString,
                title: task.title,
                priority: task.priority,
                status: task.status,
                startDate: task.startDate,
                endDate: task.endDate,
                durationMinutes: task.duration.map { Int($0 / 60) },
                alertTime: task.alertTime,
                repeatFrequency: task.repeatFrequency,
                listID: includeListID ? task.listID?.uuidString : nil,
                includeListID: includeListID
            )
            return
        }
        throw DurabilityError.serviceUnavailable
    }

    // MARK: - Normalization Helpers

    private static func normalizeTaskType(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "task", "calendar_event": return trimmed
        default: return nil
        }
    }

    private static func normalizeBackendPriority(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "low", "medium", "high": return trimmed
        default: return nil
        }
    }

    private static func priorityEnum(from raw: String?) -> Priority {
        switch normalizeBackendPriority(raw) {
        case "low": .low
        case "high": .high
        default: .medium
        }
    }

    private static func normalizeBackendStatus(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "pending", "todo", "to do", "scheduled", "unscheduled", "rescheduled": return "pending"
        case "in_progress", "in progress", "progress": return "in_progress"
        case "blocked": return "blocked"
        case "completed", "complete", "done": return "completed"
        case "cancelled", "canceled": return "cancelled"
        default: return nil
        }
    }

    private static func normalizedOptionalString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct OrganizationLookup {
        let lists: [UUID: TaskList]
        let folderNames: [UUID: String]
    }

    private struct TaskMutationSnapshot {
        let title: String
        let priority: String
        let status: String
        let startDate: Date?
        let endDate: Date?
        let duration: TimeInterval?
        let alertTime: Date?
        let repeatFrequency: String?
        let notes: String?
        let isAnyTime: Bool
        let isEvent: Bool
        let listID: UUID?
        let calendarEventID: String?
        let updatedAt: Date

        init(_ task: TaskEvent) {
            title = task.title
            priority = task.priority
            status = task.status
            startDate = task.startDate
            endDate = task.endDate
            duration = task.duration
            alertTime = task.alertTime
            repeatFrequency = task.repeatFrequency
            notes = task.notes
            isAnyTime = task.isAnyTime
            isEvent = task.isEvent
            listID = task.listID
            calendarEventID = task.calendarEventID
            updatedAt = task.updatedAt
        }

        func restore(_ task: TaskEvent) {
            task.title = title
            task.priority = priority
            task.status = status
            task.startDate = startDate
            task.endDate = endDate
            task.duration = duration
            task.alertTime = alertTime
            task.repeatFrequency = repeatFrequency
            task.notes = notes
            task.isAnyTime = isAnyTime
            task.isEvent = isEvent
            task.listID = listID
            task.calendarEventID = calendarEventID
            task.updatedAt = updatedAt
        }

        func restoreValuesStillMatching(_ attempted: Self, on task: TaskEvent) {
            if task.title == attempted.title { task.title = title }
            if task.priority == attempted.priority { task.priority = priority }
            if task.status == attempted.status { task.status = status }
            if task.startDate == attempted.startDate { task.startDate = startDate }
            if task.endDate == attempted.endDate { task.endDate = endDate }
            if task.duration == attempted.duration { task.duration = duration }
            if task.alertTime == attempted.alertTime { task.alertTime = alertTime }
            if task.repeatFrequency == attempted.repeatFrequency { task.repeatFrequency = repeatFrequency }
            if task.notes == attempted.notes { task.notes = notes }
            if task.isAnyTime == attempted.isAnyTime { task.isAnyTime = isAnyTime }
            if task.isEvent == attempted.isEvent { task.isEvent = isEvent }
            if task.listID == attempted.listID { task.listID = listID }
            if task.calendarEventID == attempted.calendarEventID { task.calendarEventID = calendarEventID }
            if task.updatedAt == attempted.updatedAt { task.updatedAt = updatedAt }
        }
    }

    private static func organizationLookup(in modelContext: ModelContext) throws -> OrganizationLookup {
        let lists = try modelContext.fetch(FetchDescriptor<TaskList>())
        let folders = try modelContext.fetch(FetchDescriptor<TaskFolder>())
        return OrganizationLookup(
            lists: Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) }),
            folderNames: Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        )
    }

    private static func listExists(_ listID: UUID, in modelContext: ModelContext) throws -> Bool {
        let descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })
        return try modelContext.fetch(descriptor).first != nil
    }

    private static func taskPayload(
        from task: TaskEvent,
        organization: OrganizationLookup
    ) -> TaskPayload {
        let list = task.listID.flatMap { organization.lists[$0] }
        return TaskPayload(
            id: task.id.uuidString,
            title: task.title,
            priority: task.priority,
            status: task.status,
            startDate: InvocationHelpers.formatISODate(task.startDate),
            endDate: InvocationHelpers.formatISODate(task.endDate),
            durationMinutes: task.duration.map { Int($0 / 60) },
            alertTime: InvocationHelpers.formatISODate(task.alertTime),
            repeatFrequency: task.repeatFrequency,
            type: task.isEvent ? "calendar_event" : "task",
            notes: task.notes,
            isAnyTime: task.isAnyTime,
            listId: task.listID?.uuidString,
            listName: list?.name,
            folderId: list?.folderID?.uuidString,
            folderName: list?.folderID.flatMap { organization.folderNames[$0] },
            calendarEventID: task.calendarEventID,
            runStatus: task.runStatus,
            runId: task.runId,
            sessionKey: task.sessionKey,
            createdAt: InvocationHelpers.formatISODate(task.createdAt) ?? "",
            updatedAt: InvocationHelpers.formatISODate(task.updatedAt) ?? ""
        )
    }

    /// Compact projection for search hits. Carries identity and run state; omits
    /// `notes` by design — see `TaskSearchPayload`.
    private static func searchPayload(
        from task: TaskEvent,
        organization: OrganizationLookup
    ) -> TaskSearchPayload {
        let list = task.listID.flatMap { organization.lists[$0] }
        return TaskSearchPayload(
            id: task.id.uuidString,
            title: task.title,
            status: task.status,
            priority: task.priority,
            runStatus: task.runStatus,
            runId: task.runId,
            sessionKey: task.sessionKey,
            type: task.isEvent ? "calendar_event" : "task",
            startDate: InvocationHelpers.formatISODate(task.startDate),
            listName: list?.name,
            folderName: list?.folderID.flatMap { organization.folderNames[$0] },
            createdAt: InvocationHelpers.formatISODate(task.createdAt) ?? "",
            updatedAt: InvocationHelpers.formatISODate(task.updatedAt) ?? ""
        )
    }
}
