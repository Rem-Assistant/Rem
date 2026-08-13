import Foundation
import Testing
@testable import RemClawMac

@MainActor
struct MacOrchestratorSuggestionStoreTests {
    @Test func effectiveGatewayScopePrefersActiveLocalRuntimeOverRetainedCloudURL() {
        let cloud = MacGatewaySuggestionScopeIdentity.resolve(
            activeLocalURL: nil,
            storedGatewayURL: "HTTPS://CLOUD.EXAMPLE",
            provider: .fly
        )
        let local = MacGatewaySuggestionScopeIdentity.resolve(
            activeLocalURL: "HTTP://127.0.0.1:18789",
            storedGatewayURL: "HTTPS://CLOUD.EXAMPLE",
            provider: .fly
        )

        #expect(cloud == "fly|https://cloud.example")
        #expect(local == "local|http://127.0.0.1:18789")
        #expect(local != cloud)
    }

    @Test func refreshPublishesOneCurrentBriefBoundSnapshotForItsScope() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let suggestion = Self.suggestion
        let store = MacOrchestratorSuggestionStore(
            briefLoader: {
                Self.payload(
                    generatedAt: "2026-08-16T08:00:00Z",
                    markdown: "Canonical brief"
                )
            },
            dismissal: { _, _ in },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )

        await store.refresh(scopeID: "account|backend|gateway", accountID: "account")

        #expect(store.snapshot(for: "account|backend|gateway")?.briefMarkdown == "Canonical brief")
        #expect(store.snapshot(for: "account|backend|gateway")?.suggestions == [suggestion])
        #expect(store.snapshot(for: "other-scope") == nil)
    }

    @Test func refreshRejectsPriorDayBriefBeforeLoadingSuggestions() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-17T00:01:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = MacOrchestratorSuggestionStore(
            briefLoader: {
                Self.payload(
                    generatedAt: "2026-08-16T23:59:00Z",
                    markdown: "Yesterday's brief"
                )
            },
            dismissal: { _, _ in },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )

        await store.refresh(scopeID: "account|backend|gateway", accountID: "account", calendar: calendar)

        #expect(store.snapshot(for: "account|backend|gateway", calendar: calendar) == nil)
    }

    @Test func refreshPublishesConnectedSourceSuggestionsWithoutBriefProse() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let store = MacOrchestratorSuggestionStore(
            briefLoader: {
                Self.payload(
                    generatedAt: "2026-08-16T08:00:00Z",
                    markdown: nil
                )
            },
            dismissal: { _, _ in },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )

        await store.refresh(scopeID: "account|backend|gateway", accountID: "account")

        #expect(store.snapshot(for: "account|backend|gateway")?.briefMarkdown == nil)
        #expect(store.snapshot(for: "account|backend|gateway")?.suggestions == [Self.suggestion])
    }

    @Test func calendarDayChangeActivelyRefreshesRetainedDurableScope() async throws {
        let formatter = ISO8601DateFormatter()
        var now = try #require(formatter.date(from: "2026-08-16T12:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var briefLoadCount = 0
        let store = MacOrchestratorSuggestionStore(
            briefLoader: {
                briefLoadCount += 1
                return Self.payload(
                    generatedAt: briefLoadCount == 1
                        ? "2026-08-16T08:00:00Z"
                        : "2026-08-17T08:00:00Z",
                    markdown: briefLoadCount == 1 ? "Sunday brief" : "Monday brief"
                )
            },
            dismissal: { _, _ in },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        let scopeID = "account|backend|gateway"
        await store.refresh(scopeID: scopeID, accountID: "account", calendar: calendar)
        now = try #require(formatter.date(from: "2026-08-17T12:00:00Z"))

        await store.refreshForCalendarDayChange(calendar: calendar)

        #expect(store.scopeID == scopeID)
        #expect(store.snapshot(for: scopeID, calendar: calendar)?.briefMarkdown == "Monday brief")
        #expect(briefLoadCount == 2)
    }

    @Test func acceptDoesNotDismissAcrossNewerRefreshGeneration() async throws {
        var brief = Self.payload(
            generatedAt: "2026-08-16T08:00:00Z",
            markdown: "Account A brief"
        )
        var acceptanceContinuation: CheckedContinuation<
            MacOrchestratorSuggestionStore.AcceptanceResult?, Never
        >?
        var dismissalCount = 0
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let store = MacOrchestratorSuggestionStore(
            briefLoader: { brief },
            dismissal: { _, _ in dismissalCount += 1 },
            acceptance: { _, _, _ in
                await withCheckedContinuation { continuation in
                    acceptanceContinuation = continuation
                }
            },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        let taskStore = MacTaskStore()
        await store.refresh(scopeID: "account-a|backend|gateway", accountID: "account-a")

        let pendingAccept = Task {
            await store.accept(
                Self.suggestion,
                taskStore: taskStore,
                scopeID: "account-a|backend|gateway"
            )
        }
        while acceptanceContinuation == nil { await Task.yield() }
        brief = Self.payload(
            generatedAt: "2026-08-16T09:00:00Z",
            markdown: "Account B brief"
        )
        await store.refresh(scopeID: "account-a|backend|gateway", accountID: "account-a")
        acceptanceContinuation?.resume(returning: .alreadyApplied)
        await pendingAccept.value

        #expect(dismissalCount == 0)
        #expect(store.scopeID == "account-a|backend|gateway")
        #expect(store.snapshot(for: "account-a|backend|gateway")?.briefMarkdown == "Account B brief")
    }

    @Test func acceptUsesOneCapturedAuthorityForTaskMutationAndDismissal() async throws {
        var mutationAuthority: MacAuthenticatedHttpClient.RequestAuthority?
        var dismissalAuthority: MacAuthenticatedHttpClient.RequestAuthority?
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let store = MacOrchestratorSuggestionStore(
            briefLoader: {
                Self.payload(generatedAt: "2026-08-16T08:00:00Z", markdown: "Brief")
            },
            dismissal: { _, authority in dismissalAuthority = authority },
            acceptance: { _, _, authority in
                mutationAuthority = authority
                return .alreadyApplied
            },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        let scope = "account|backend|gateway"
        await store.refresh(scopeID: scope, accountID: "account")

        await store.accept(Self.suggestion, taskStore: MacTaskStore(), scopeID: scope)

        #expect(mutationAuthority == Self.requestAuthority)
        #expect(dismissalAuthority == mutationAuthority)
    }

    @Test func liveScopeInvalidationRetiresSuspendedActionBeforeRefreshTaskStarts() async throws {
        var acceptanceContinuation: CheckedContinuation<
            MacOrchestratorSuggestionStore.AcceptanceResult?, Never
        >?
        var dismissalCount = 0
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let store = MacOrchestratorSuggestionStore(
            briefLoader: {
                Self.payload(generatedAt: "2026-08-16T08:00:00Z", markdown: "Account A")
            },
            dismissal: { _, _ in dismissalCount += 1 },
            acceptance: { _, _, _ in
                await withCheckedContinuation { acceptanceContinuation = $0 }
            },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        let oldScope = "account-a|backend|gateway"
        await store.refresh(scopeID: oldScope, accountID: "account")
        let pending = Task {
            await store.accept(Self.suggestion, taskStore: MacTaskStore(), scopeID: oldScope)
        }
        while acceptanceContinuation == nil { await Task.yield() }

        store.invalidateForScopeChange(to: "account-b|backend|gateway")
        acceptanceContinuation?.resume(returning: .alreadyApplied)
        await pending.value

        #expect(dismissalCount == 0)
        #expect(store.scopeID == nil)
        #expect(store.snapshot == nil)
    }

    @Test func retiredAccountCannotPublishSuspendedMutationIntoNewAccountTaskCache() async throws {
        var acceptanceContinuation: CheckedContinuation<
            MacOrchestratorSuggestionStore.AcceptanceResult?, Never
        >?
        var dismissalCount = 0
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let store = MacOrchestratorSuggestionStore(
            briefLoader: {
                Self.payload(generatedAt: "2026-08-16T08:00:00Z", markdown: "Account A")
            },
            dismissal: { _, _ in dismissalCount += 1 },
            acceptance: { _, _, _ in
                await withCheckedContinuation { acceptanceContinuation = $0 }
            },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        let taskStore = MacTaskStore()
        let oldScope = "account-a|backend|gateway"
        await store.refresh(scopeID: oldScope, accountID: "account")
        let pending = Task {
            await store.accept(Self.suggestion, taskStore: taskStore, scopeID: oldScope)
        }
        while acceptanceContinuation == nil { await Task.yield() }

        store.invalidateForScopeChange(to: "account-b|backend|gateway")
        let accountBTask = Self.task(id: Self.suggestion.actionId, title: "Account B task")
        taskStore.publishSuggestionMutation(accountBTask)
        let staleAccountATask = Self.task(id: Self.suggestion.actionId, title: "Account A task")
        acceptanceContinuation?.resume(returning: .publish(staleAccountATask))
        await pending.value

        #expect(taskStore.allTasks == [accountBTask])
        #expect(dismissalCount == 0)
    }

    @Test func failedDismissDoesNotRefreshRetiredScopeOverNewerScope() async throws {
        enum DismissError: Error { case failed }
        var brief = Self.payload(
            generatedAt: "2026-08-16T08:00:00Z",
            markdown: "Account A brief"
        )
        var dismissalContinuation: CheckedContinuation<Void, Error>?
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let store = MacOrchestratorSuggestionStore(
            briefLoader: { brief },
            dismissal: { _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    dismissalContinuation = continuation
                }
            },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        await store.refresh(scopeID: "account-a|backend|gateway", accountID: "account-a")

        let pendingDismiss = Task {
            await store.dismissSuggestion(
                Self.suggestion,
                scopeID: "account-a|backend|gateway"
            )
        }
        while dismissalContinuation == nil { await Task.yield() }
        brief = Self.payload(
            generatedAt: "2026-08-16T09:00:00Z",
            markdown: "Account B brief"
        )
        await store.refresh(scopeID: "account-b|backend|gateway", accountID: "account-b")
        dismissalContinuation?.resume(throwing: DismissError.failed)
        await pendingDismiss.value

        #expect(store.scopeID == "account-b|backend|gateway")
        #expect(store.snapshot(for: "account-b|backend|gateway")?.briefMarkdown == "Account B brief")
    }

    @Test func sameScopeRefreshKeepsCanonicalActionClaimUntilAcceptanceFinishes() async throws {
        var acceptanceContinuations: [CheckedContinuation<
            MacOrchestratorSuggestionStore.AcceptanceResult?, Never
        >] = []
        var acceptanceCount = 0
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let store = MacOrchestratorSuggestionStore(
            briefLoader: { Self.payload(generatedAt: "2026-08-16T08:00:00Z", markdown: "Brief") },
            dismissal: { _, _ in },
            acceptance: { _, _, _ in
                acceptanceCount += 1
                return await withCheckedContinuation { acceptanceContinuations.append($0) }
            },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        let scope = "account|backend|gateway"
        let taskStore = MacTaskStore()
        await store.refresh(scopeID: scope, accountID: "account")
        let first = Task { await store.accept(Self.suggestion, taskStore: taskStore, scopeID: scope) }
        while acceptanceContinuations.isEmpty { await Task.yield() }

        await store.refresh(scopeID: scope, accountID: "account")
        await store.accept(Self.suggestion, taskStore: taskStore, scopeID: scope)

        #expect(acceptanceCount == 1)
        acceptanceContinuations[0].resume(returning: nil)
        await first.value
    }

    @Test func midnightMakesPreviouslyRenderedActionNonAuthoritative() async throws {
        let formatter = ISO8601DateFormatter()
        var now = try #require(formatter.date(from: "2026-08-16T23:59:00Z"))
        var acceptanceCount = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = MacOrchestratorSuggestionStore(
            briefLoader: { Self.payload(generatedAt: "2026-08-16T20:00:00Z", markdown: "Sunday") },
            dismissal: { _, _ in },
            acceptance: { _, _, _ in acceptanceCount += 1; return .alreadyApplied },
            authorityProvider: { _ in Self.requestAuthority },
            now: { now }
        )
        let scope = "account|backend|gateway"
        await store.refresh(scopeID: scope, accountID: "account", calendar: calendar)
        now = try #require(formatter.date(from: "2026-08-17T00:01:00Z"))

        await store.accept(Self.suggestion, taskStore: MacTaskStore(), scopeID: scope)

        #expect(acceptanceCount == 0)
    }

    private static func payload(generatedAt: String, markdown: String?) -> MacOrchestratorBriefPayload {
        MacOrchestratorBriefPayload(
            generatedAt: generatedAt,
            markdown: markdown,
            briefRevision: "revision:\(markdown ?? "connected-only")",
            suggestionSnapshotID: "snapshot:\(markdown ?? "connected-only")",
            suggestions: [suggestion]
        )
    }

    private static let suggestion = TaskSuggestion(
        key: "cal:one",
        actionId: "44444444-4444-5444-8444-444444444444",
        source: "calendar",
        title: "Prep for Standup",
        subtitle: "Standup · Calendar",
        action: SuggestionAction(
            kind: "createTask",
            taskTitle: "Prep for Standup",
            targetTaskId: nil,
            startDate: nil
        )
    )

    private static let requestAuthority = MacAuthenticatedHttpClient.RequestAuthority(
        token: "fixture-token",
        baseURL: "https://backend.example"
    )

    private static func task(id: String, title: String) -> MacTask {
        MacTask(
            id: id,
            title: title,
            status: "pending",
            category: nil,
            startDate: nil,
            endDate: nil,
            dueDate: nil,
            notes: nil,
            taskDescription: nil,
            agentContext: nil,
            isEvent: false,
            priority: nil,
            createdAt: nil,
            updatedAt: nil,
            runStatus: nil,
            runId: nil,
            sessionKey: nil,
            runStartedAt: nil
        )
    }
}
