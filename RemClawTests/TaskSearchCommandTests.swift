import Foundation
import OpenClawKit
import SwiftData
import Testing
@testable import RemClaw

/// `tasks.search` exists so the agent can resolve a task it only knows by NAME.
///
/// The daily brief is authored from the user's tasks but delivered as prose: the
/// backend renders titles only, and `chat.inject` carries no metadata. So the chat
/// turn receives names and never ids. `tasks.get` demands a UUID and `tasks.list`
/// has no title filter — which is why the agent, asked about a line in its own
/// brief, could truthfully report having no record of it.
///
/// Every fixture here is synthetic.
@Suite("tasks.search — resolving a task by name", .serialized)
@MainActor
struct TaskSearchCommandTests {

    // MARK: - The defect

    /// The load-bearing test: a name that exists ONLY in this user's task list
    /// resolves to that exact task, carrying the run state that explains why a brief
    /// would have called it blocked.
    @Test func resolvesABriefNamedTaskThatOnlyExistsInTheUsersList() async throws {
        let context = try makeContext()
        let target = task(titled: "Retry queue backoff")
        target.status = "in_progress"
        target.runStatus = "blocked"
        target.runId = "run_8842"
        target.sessionKey = "rem-orchestrator"
        context.insert(target)
        for decoy in ["Draft onboarding email", "Review pricing page copy", "Renew domain registration"] {
            context.insert(task(titled: decoy))
        }
        try context.save()
        configure(context)

        let response = try await search(query: "Retry queue backoff")

        // Exactly one task, and it is the right one — resolved from the name alone.
        #expect(response.matches.count == 1)
        let match = try #require(response.matches.first)
        #expect(match.task.id == target.id.uuidString)
        #expect(match.task.title == "Retry queue backoff")
        #expect(match.score == 1.0)
        #expect(match.matchedOn == "exact")

        // And it can explain the brief's red line, which `status` alone cannot:
        // the Blocked bucket is built from `runStatus`, not `status`.
        #expect(match.task.status == "in_progress")
        #expect(match.task.runStatus == "blocked")
        #expect(match.task.runId == "run_8842")
        #expect(match.task.sessionKey == "rem-orchestrator")
    }

    /// The discriminator for the test above. If search returned the task list (or
    /// matched too loosely) this would also come back populated, and the test above
    /// would prove nothing. A name the user does not have must resolve to nothing.
    @Test func aNameTheUserDoesNotHaveReturnsNoMatches() async throws {
        let context = try makeContext()
        for title in ["Retry queue backoff", "Draft onboarding email", "Review pricing page copy"] {
            context.insert(task(titled: title))
        }
        try context.save()
        configure(context)

        let response = try await search(query: "Quarterly tax filing")

        #expect(response.matches.isEmpty)
        #expect(response.total == 0)
        // Proves the store was non-empty, so "no matches" is selectivity, not an
        // empty database.
        let all = try await decode(
            TasksListResponse.self,
            from: TasksCommandHandler.handleList(request(command: "tasks.list"))
        )
        #expect(all.total == 3)
    }

    // MARK: - Freshness (the snapshot the app is sitting on is not the truth)

    /// The scenario the command exists for: the app stays resident, the backend
    /// orchestrator creates the task and authors a brief naming it, and the user asks
    /// about it. The task exists ONLY on the backend at the moment of the question.
    /// Searching the local snapshot alone finds nothing and the agent says "I have no
    /// record" — the original defect, reproduced through the fix.
    @Test func findsATaskTheBackendCreatedAfterTheAppLastSynced() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Draft onboarding email"))
        try context.save()

        let serverTaskID = UUID()
        let sync = RefreshingSyncStub()
        sync.applyServerSideChange = {
            let arrived = TaskEvent(id: serverTaskID, title: "Retry queue backoff")
            arrived.runStatus = "blocked"
            arrived.sessionKey = "rem-orchestrator"
            context.insert(arrived)
            try? context.save()
        }
        configure(context, sync: sync)

        let response = try await search(query: "Retry queue backoff")

        #expect(sync.refreshCount == 1)
        #expect(response.matches.count == 1)
        #expect(response.matches.first?.task.id == serverTaskID.uuidString)
        #expect(response.matches.first?.task.runStatus == "blocked")
        #expect(response.stale == false)
    }

    /// Staleness is not only about missing tasks. A task the device already knows about
    /// can have been moved to blocked server-side, which is precisely what makes the
    /// brief render it red — so a stale `runStatus` answers the question wrongly.
    @Test func reportsRunStatusThatChangedServerSide() async throws {
        let context = try makeContext()
        let known = task(titled: "Retry queue backoff")
        known.runStatus = nil
        context.insert(known)
        try context.save()

        let sync = RefreshingSyncStub()
        sync.applyServerSideChange = {
            known.runStatus = "blocked"
            try? context.save()
        }
        configure(context, sync: sync)

        let response = try await search(query: "Retry queue backoff")

        #expect(response.matches.first?.task.runStatus == "blocked")
    }

    /// A failed refresh must not cost the answer. A stale answer that admits it is stale
    /// beats "I have no record" — that is the entire point of the command.
    @Test func aFailedRefreshStillAnswersAndSaysItMayBeStale() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff"))
        try context.save()

        let sync = RefreshingSyncStub()
        sync.refreshSucceeds = false
        configure(context, sync: sync)

        let response = try await search(query: "Retry queue backoff")

        #expect(sync.refreshCount == 1)
        #expect(response.matches.count == 1, "a failed refresh must not swallow the answer")
        #expect(response.stale == true)
        #expect(response.staleReason?.isEmpty == false)
    }

    /// Same contract when the device has no sync service at all.
    @Test func answersAndFlagsStalenessWithNoSyncService() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff"))
        try context.save()
        configure(context, sync: nil)

        let response = try await search(query: "Retry queue backoff")

        #expect(response.matches.count == 1)
        #expect(response.stale == true)
    }

    /// A brief naming three tasks is three lookups in one turn. Refreshing per call would
    /// put a network round-trip in front of each, so a completed refresh is trusted
    /// briefly.
    @Test func aMultiLookupTurnSyncsOnce() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff"))
        context.insert(task(titled: "Draft onboarding email"))
        try context.save()
        let sync = configure(context)

        _ = try await search(query: "Retry queue backoff")
        _ = try await search(query: "Draft onboarding email")
        _ = try await search(query: "Retry queue backoff")

        #expect(sync.refreshCount == 1)
    }

    /// A successful pull that yields nothing still leaves the device unable to support a
    /// negative — wrong account scoping and backend regressions both look like success.
    /// The agent is told an empty `matches` means no such task, so without this the
    /// staleness escape hatch never fires and "I have no record" comes back by another
    /// route.
    @Test func anEmptyStoreCannotClaimTheTaskDoesNotExist() async throws {
        let context = try makeContext()
        try context.save()
        let sync = configure(context)

        let response = try await search(query: "Retry queue backoff")

        #expect(sync.refreshCount == 1)
        #expect(response.matches.isEmpty)
        #expect(response.stale == true, "an empty store must not license a confident negative")
        #expect(response.staleReason?.isEmpty == false)
    }

    /// `aMultiLookupTurnSyncsOnce` passes for any window above roughly zero, because three
    /// awaits land in the same millisecond. This pins the window's effect in both
    /// directions.
    @Test func theFreshnessWindowIsWhatSuppressesTheSecondSync() async throws {
        let original = TasksCommandHandler.taskFreshnessWindow
        defer { TasksCommandHandler.taskFreshnessWindow = original }

        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff"))
        try context.save()

        let wide = configure(context)
        TasksCommandHandler.taskFreshnessWindow = 600
        _ = try await search(query: "Retry queue backoff")
        _ = try await search(query: "Retry queue backoff")
        #expect(wide.refreshCount == 1)

        let none = configure(context)
        TasksCommandHandler.taskFreshnessWindow = 0
        _ = try await search(query: "Retry queue backoff")
        _ = try await search(query: "Retry queue backoff")
        #expect(none.refreshCount == 2)
    }

    /// `ensureFreshTasks` reads the timestamp, awaits, then writes it. Two searches
    /// arriving together would both pass the window check and both reconcile. Today the
    /// gateway happens to serialize invokes, but that is upstream's invariant, not ours.
    @Test func concurrentSearchesShareOnePull() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff"))
        try context.save()

        let sync = RefreshingSyncStub()
        sync.hold = true
        configure(context, sync: sync)

        async let first = search(query: "Retry queue backoff")
        async let second = search(query: "Draft onboarding email")
        try await Task.sleep(nanoseconds: 80_000_000)
        sync.release()
        _ = try await (first, second)

        #expect(sync.refreshCount == 1)
    }

    // MARK: - Not answering confidently about the wrong task

    /// Raw-substring matching made a task titled `It` or `A` a hit for nearly any query
    /// ("subm-IT the report"), at a score the agent reads as strong. Matching is
    /// token-aligned, and a title of pure function words can only match exactly.
    @Test func shortTitlesDoNotMatchInsideLongerWords() async throws {
        let context = try makeContext()
        let target = task(titled: "Submit the quarterly report")
        context.insert(target)
        for tiny in ["It", "A", "PR", "Gym"] {
            context.insert(task(titled: tiny))
        }
        try context.save()
        configure(context)

        let response = try await search(query: "Submit the quarterly report")

        #expect(response.matches.count == 1)
        #expect(response.matches.first?.task.id == target.id.uuidString)
    }

    /// A flat 0.9 for any prefix made a one-word task and the real one indistinguishable
    /// for a truncated brief name, so the tie broke on `updatedAt` and the wrong task
    /// could rank first. Scores scale with how much of the title the query covers.
    @Test func aTruncatedNameRanksTheFullerTitleFirst() async throws {
        let context = try makeContext()
        let short = task(titled: "Call", createdAt: Date())
        let full = task(
            titled: "Call Dana about the lease renewal",
            createdAt: Date().addingTimeInterval(-3 * 24 * 60 * 60)
        )
        context.insert(short)
        context.insert(full)
        try context.save()
        configure(context)

        let response = try await search(query: "Call Dana about the lease…")

        #expect(response.matches.first?.task.id == full.id.uuidString)
        let fullScore = try #require(response.matches.first?.score)
        let shortScore = response.matches.first { $0.task.id == short.id.uuidString }?.score
        if let shortScore {
            #expect(fullScore > shortScore, "coverage must break the tie, not updatedAt")
        }
    }

    // MARK: - Why equality matching would not have been enough

    /// The brief wraps titles in `**…**`, separates them with em-dashes, and
    /// truncates long ones with an ellipsis. A name pasted back out of that prose
    /// must still resolve.
    @Test func matchesThroughTheBriefsOwnDecorations() async throws {
        let context = try makeContext()
        let target = task(titled: "Retry queue backoff")
        context.insert(target)
        try context.save()
        configure(context)

        for quoted in ["**Retry queue backoff**", "retry queue backoff", "Retry  queue—backoff"] {
            let response = try await search(query: quoted)
            #expect(response.matches.first?.task.id == target.id.uuidString, "failed for \(quoted)")
        }
    }

    /// Long titles reach the brief truncated with a trailing ellipsis, so the name
    /// the agent has is a PREFIX of the stored title.
    @Test func matchesATitleTheBriefTruncated() async throws {
        let context = try makeContext()
        let target = task(titled: "Retry queue backoff for the webhook delivery pipeline")
        context.insert(target)
        context.insert(task(titled: "Draft onboarding email"))
        try context.save()
        configure(context)

        let response = try await search(query: "Retry queue backoff for the webhook…")

        #expect(response.matches.count == 1)
        #expect(response.matches.first?.task.id == target.id.uuidString)
        #expect(response.matches.first?.matchedOn == "prefix")
    }

    /// Ranking has to be meaningful, not incidental: the exact title must outrank a
    /// task that merely shares words with the query.
    @Test func exactTitleOutranksPartialOverlap() async throws {
        let context = try makeContext()
        let exact = task(titled: "Retry queue backoff")
        let overlapping = task(titled: "Retry queue metrics dashboard")
        context.insert(overlapping)
        context.insert(exact)
        try context.save()
        configure(context)

        let response = try await search(query: "Retry queue backoff")

        #expect(response.matches.first?.task.id == exact.id.uuidString)
        #expect(response.matches.first?.score == 1.0)
        let exactScore = try #require(response.matches.first?.score)
        for other in response.matches.dropFirst() {
            #expect(other.score < exactScore)
        }
    }

    // MARK: - Why `tasks.list` could not have done this

    /// `tasks.list` pages at 50, newest-first. A task older than the newest 50 is
    /// invisible to the default page — so "just call tasks.list and read the titles"
    /// silently fails exactly when the brief references older work.
    @Test func findsATaskTheDefaultListPageWouldMiss() async throws {
        let context = try makeContext()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let target = task(titled: "Retry queue backoff", createdAt: old)
        context.insert(target)
        for index in 0..<60 {
            context.insert(task(
                titled: "Filler task \(index)",
                createdAt: old.addingTimeInterval(Double(index + 1) * 60)
            ))
        }
        try context.save()
        configure(context)

        let listed = try await decode(
            TasksListResponse.self,
            from: TasksCommandHandler.handleList(request(command: "tasks.list"))
        )
        #expect(listed.tasks.count == 50)
        #expect(listed.tasks.contains { $0.id == target.id.uuidString } == false)

        let response = try await search(query: "Retry queue backoff")
        #expect(response.matches.first?.task.id == target.id.uuidString)
    }

    /// `tasks.get` is id-only; handing it a title is a hard failure. This is the
    /// gap `tasks.search` fills.
    @Test func getStillRejectsATitle() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff"))
        try context.save()
        configure(context)

        let response = await TasksCommandHandler.handleGet(request(
            command: "tasks.get",
            params: ["id": "Retry queue backoff"]
        ))

        #expect(response.ok == false)
    }

    // MARK: - Run state on the wire

    /// `runStatus` / `runId` / `sessionKey` have to survive into the payload, or the
    /// agent can find the task and still not know why the brief called it blocked.
    @Test func runStateReachesTheWireForListAndGet() async throws {
        let context = try makeContext()
        let target = task(titled: "Retry queue backoff")
        target.runStatus = "blocked"
        target.sessionKey = "rem-orchestrator"
        context.insert(target)
        try context.save()
        configure(context)

        let listed = try await decode(
            TasksListResponse.self,
            from: TasksCommandHandler.handleList(request(command: "tasks.list"))
        )
        #expect(listed.tasks.first?.runStatus == "blocked")
        #expect(listed.tasks.first?.sessionKey == "rem-orchestrator")

        let fetched = try await decode(
            TasksGetResponse.self,
            from: TasksCommandHandler.handleGet(request(
                command: "tasks.get",
                params: ["id": target.id.uuidString]
            ))
        )
        #expect(fetched.task.runStatus == "blocked")
    }

    // MARK: - Privacy / untrusted content

    /// Notes are untrusted in both halves (user-pasted and model-written) and can
    /// reach an unattended turn through a search result. The search path neither
    /// matches against them nor returns them; `tasks.get` remains the deliberate,
    /// id-addressed way to read full detail.
    @Test func searchNeitherMatchesNorReturnsNotes() async throws {
        let context = try makeContext()
        let target = task(titled: "Retry queue backoff")
        target.notes = "Vendor escalation ref SPQR-4471"
        context.insert(target)
        try context.save()
        configure(context)

        // A term that appears ONLY in the notes must not resolve the task.
        let byNotes = try await search(query: "SPQR-4471")
        #expect(byNotes.matches.isEmpty)

        // And a hit found by title must not carry the note body back.
        let byTitle = try await search(query: "Retry queue backoff")
        #expect(byTitle.matches.count == 1)
        let encoded = await TasksCommandHandler.handleSearch(request(
            command: "tasks.search",
            params: ["query": "Retry queue backoff"]
        ))
        let json = try #require(encoded.payloadJSON)
        #expect(json.contains("SPQR-4471") == false)
        #expect(json.contains("Retry queue backoff"))
    }

    // MARK: - Input handling

    @Test func emptyQueryIsRejectedRatherThanMatchingEverything() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff"))
        try context.save()
        configure(context)

        for empty in ["", "   ", "—"] {
            let response = await TasksCommandHandler.handleSearch(request(
                command: "tasks.search",
                params: ["query": empty]
            ))
            #expect(response.ok == false, "empty query \(empty.debugDescription) should be rejected")
        }
    }

    /// A fragment of pure function words is a substring of half the task list. Without
    /// a noise floor it resolves — confidently and wrongly — to whichever task happens
    /// to contain those words, which is worse than returning nothing.
    @Test func aQueryOfOnlyFunctionWordsResolvesToNothing() async throws {
        let context = try makeContext()
        context.insert(task(titled: "Retry queue backoff for the webhook delivery pipeline"))
        context.insert(task(titled: "Draft onboarding email for the design review"))
        // A title the noise query is a literal PREFIX of. The floor has to gate the
        // prefix tier, not merely the tiers below it, or this resolves at 0.9.
        context.insert(task(titled: "For the win"))
        try context.save()
        configure(context)

        for noise in ["for the", "to the", "and", "of"] {
            let response = try await search(query: noise)
            #expect(response.matches.isEmpty, "\(noise.debugDescription) should not resolve")
        }
    }

    @Test func statusFilterNarrowsResults() async throws {
        let context = try makeContext()
        let done = task(titled: "Retry queue backoff")
        done.status = "completed"
        let open = task(titled: "Retry queue backoff rollout")
        open.status = "pending"
        context.insert(done)
        context.insert(open)
        try context.save()
        configure(context)

        let response = try await search(query: "Retry queue backoff", params: ["status": "pending"])

        #expect(response.matches.count == 1)
        #expect(response.matches.first?.task.id == open.id.uuidString)
    }

    // MARK: - Helpers

    private func task(titled title: String, createdAt: Date = Date()) -> TaskEvent {
        TaskEvent(title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    private func search(
        query: String,
        params extra: [String: Any] = [:]
    ) async throws -> TasksSearchResponse {
        var params: [String: Any] = ["query": query]
        for (key, value) in extra { params[key] = value }
        return try await decode(
            TasksSearchResponse.self,
            from: TasksCommandHandler.handleSearch(request(command: "tasks.search", params: params))
        )
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TaskEvent.self, TaskList.self, TaskFolder.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    /// Stands in for the backend pull. `applyServerSideChange` is the work the
    /// orchestrator did while the app sat resident — it lands in the store only if the
    /// handler actually refreshes before reading.
    private final class RefreshingSyncStub: TaskSyncServiceProtocol {
        var refreshCount = 0
        var refreshSucceeds = true
        var applyServerSideChange: (@MainActor () -> Void)?
        var hold = false
        // An array, not a single slot: if the shared flight regresses, both callers enter
        // here and a single slot would strand one forever — a hang instead of a failure.
        private var continuations: [CheckedContinuation<Void, Never>] = []

        @MainActor
        func release() {
            let pending = continuations
            continuations = []
            for continuation in pending { continuation.resume() }
        }

        func queueOperation(operationType: String, taskId: UUID?, taskData: Data?) async -> Bool { true }

        @MainActor
        func updateTaskStatus(
            _ task: TaskEvent,
            to status: TaskStatus,
            modelContext: ModelContext
        ) async throws {}

        func syncTaskToBackendImmediately(_ task: TaskEvent) async throws {}

        func syncTaskCreateToBackendImmediately(
            _ task: TaskEvent
        ) async throws -> TaskEventApiResponse? { nil }

        @MainActor
        func refreshFromBackend() async -> Bool {
            refreshCount += 1
            if hold {
                await withCheckedContinuation { continuations.append($0) }
            }
            guard refreshSucceeds else { return false }
            applyServerSideChange?()
            return true
        }
    }

    @discardableResult
    private func configure(_ context: ModelContext) -> RefreshingSyncStub {
        let stub = RefreshingSyncStub()
        configure(context, sync: stub)
        return stub
    }

    private func configure(_ context: ModelContext, sync: RefreshingSyncStub?) {
        TasksCommandHandler.configure(
            modelContext: { context },
            taskSyncService: { sync },
            taskApiService: { nil },
            organizationApiService: { nil }
        )
        ListsCommandHandler.configure(
            modelContext: { context },
            organizationApiService: { nil }
        )
        FoldersCommandHandler.configure(
            modelContext: { context },
            organizationApiService: { nil }
        )
    }

    private func request(
        command: String,
        params: [String: Any]? = nil
    ) -> BridgeInvokeRequest {
        let paramsJSON = params.flatMap { dictionary in
            try? JSONSerialization.data(withJSONObject: dictionary)
        }.flatMap { String(data: $0, encoding: .utf8) }
        return BridgeInvokeRequest(id: UUID().uuidString, command: command, paramsJSON: paramsJSON)
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        from response: BridgeInvokeResponse
    ) async throws -> T {
        #expect(response.ok == true)
        let json = try #require(response.payloadJSON)
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
