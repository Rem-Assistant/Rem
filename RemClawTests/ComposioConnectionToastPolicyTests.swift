import Foundation
import Testing
@testable import RemClaw

@MainActor
private final class RapidConnectAdmissionHarness {
    let admission = ComposioConnectAdmissionGate()
    private(set) var serviceConnectCalls = 0
    private(set) var pollCalls = 0
    private(set) var browserOpenCalls = 0
    private(set) var pollPublications = 0
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var pollContinuation: CheckedContinuation<Void, Never>?

    func beginConnect(_ toolkit: String) async {
        guard let generation = admission.admit(toolkit) else { return }
        serviceConnectCalls += 1
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
        }
        guard admission.owns(toolkit, generation: generation) else { return }
        browserOpenCalls += 1
        pollCalls += 1
        await withCheckedContinuation { continuation in
            pollContinuation = continuation
        }
        guard admission.owns(toolkit, generation: generation) else { return }
        pollPublications += 1
        admission.release(toolkit, generation: generation)
    }

    func finishHostedSessionCreation() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func finishPoll() {
        pollContinuation?.resume()
        pollContinuation = nil
    }

    func teardown() {
        _ = admission.invalidateAll()
    }
}

struct ComposioConnectionToastPolicyTests {
    @Test func genuineConnectionCompletionProducesSuccessToast() throws {
        var pending = Set(["gmail"])
        let item = try #require(ComposioConnectionToastPolicy.consumeSuccessItem(
            displayName: "Gmail",
            toolkit: "gmail",
            isConnected: true,
            pendingConfirmations: &pending
        ))

        #expect(item.style == .success)
        #expect(item.message == "Gmail connected.")
        #expect(pending.isEmpty)
    }

    @Test func connectedStatusWithoutPendingAttemptDoesNotReplayToast() {
        var pending: Set<String> = []
        #expect(ComposioConnectionToastPolicy.consumeSuccessItem(
            displayName: "Gmail",
            toolkit: "gmail",
            isConnected: true,
            pendingConfirmations: &pending
        ) == nil)
    }

    @Test func nonTerminalStatusPreservesPendingConfirmationForLaterRefreshOrPoll() {
        var pending = Set(["gmail"])
        #expect(ComposioConnectionToastPolicy.consumeSuccessItem(
            displayName: "Gmail",
            toolkit: "gmail",
            isConnected: false,
            pendingConfirmations: &pending
        ) == nil)
        #expect(pending == Set(["gmail"]))
    }
}

struct ComposioToolkitPresentationTests {
    @Test func discordAndDiscordBotHaveTruthfulDistinctNames() {
        #expect(ComposioToolkitPresentation.displayName(for: "discord") == "Discord")
        #expect(ComposioToolkitPresentation.displayName(for: "discordbot") == "Discord Bot")
    }

    @Test func discordToolkitsShareTheMessagingFallbackIcon() {
        let discordIcon = ComposioToolkitPresentation.iconName(for: "discord")
        #expect(discordIcon == "bubble.left.and.bubble.right.fill")
        #expect(ComposioToolkitPresentation.iconName(for: "discordbot") == discordIcon)
    }
}

struct ComposioAvailabilityPresentationTests {
    @Test @MainActor
    func rapidDoubleConnectAdmitsOneHostedSessionAndPollBeforeRedraw() async {
        let harness = RapidConnectAdmissionHarness()
        let first = Task { await harness.beginConnect("discord") }
        while harness.serviceConnectCalls == 0 { await Task.yield() }

        // This is a separate unstructured task entering before any SwiftUI disabled-state redraw.
        let second = Task { await harness.beginConnect("discord") }
        await Task.yield()
        #expect(harness.serviceConnectCalls == 1)

        harness.finishHostedSessionCreation()
        while harness.pollCalls == 0 { await Task.yield() }
        harness.finishPoll()
        await first.value
        await second.value
        #expect(harness.serviceConnectCalls == 1)
        #expect(harness.pollCalls == 1)
    }

    @Test @MainActor
    func teardownDuringConnectBlocksBrowserAndPollThenAllowsReentry() async {
        let harness = RapidConnectAdmissionHarness()
        let abandoned = Task { await harness.beginConnect("discord") }
        while harness.serviceConnectCalls == 0 { await Task.yield() }
        harness.teardown()
        harness.finishHostedSessionCreation()
        await abandoned.value
        #expect(harness.browserOpenCalls == 0)
        #expect(harness.pollCalls == 0)

        let replacement = Task { await harness.beginConnect("discord") }
        while harness.serviceConnectCalls < 2 { await Task.yield() }
        harness.finishHostedSessionCreation()
        while harness.pollCalls == 0 { await Task.yield() }
        harness.finishPoll()
        await replacement.value
        #expect(harness.browserOpenCalls == 1)
        #expect(harness.pollCalls == 1)
        #expect(harness.pollPublications == 1)
    }

    @Test @MainActor
    func teardownDuringPollBlocksPublicationThenAllowsReentry() async {
        let harness = RapidConnectAdmissionHarness()
        let abandoned = Task { await harness.beginConnect("discord") }
        while harness.serviceConnectCalls == 0 { await Task.yield() }
        harness.finishHostedSessionCreation()
        while harness.pollCalls == 0 { await Task.yield() }
        harness.teardown()
        harness.finishPoll()
        await abandoned.value
        #expect(harness.pollPublications == 0)

        let replacement = Task { await harness.beginConnect("discord") }
        while harness.serviceConnectCalls < 2 { await Task.yield() }
        harness.finishHostedSessionCreation()
        while harness.pollCalls < 2 { await Task.yield() }
        harness.finishPoll()
        await replacement.value
        #expect(harness.browserOpenCalls == 2)
        #expect(harness.pollCalls == 2)
        #expect(harness.pollPublications == 1)
    }

    @Test func catalogFenceRejectsLoadsAdmittedBeforeMutation() {
        var fence = ComposioCatalogLoadGenerationFence()
        let preMutationLoad = fence.begin()

        fence.invalidate()
        #expect(!fence.canPublish(preMutationLoad))

        let postMutationRefresh = fence.begin()
        #expect(fence.canPublish(postMutationRefresh))
    }

    @Test func delayedPreConnectCatalogCannotOverwriteOAuthCompletion() {
        var fence = ComposioCatalogLoadGenerationFence()
        let delayedCatalog = fence.begin()
        var publishedStatus = "not_connected"

        // Connect admission retires every earlier catalog response, and connected status
        // publication advances the fence again before publishing OAuth/runtime truth.
        fence.invalidate()
        fence.invalidate()
        publishedStatus = "connected"
        if fence.canPublish(delayedCatalog) {
            publishedStatus = "not_connected"
        }

        #expect(publishedStatus == "connected")
        #expect(!fence.canPublish(delayedCatalog))
    }

    @Test func delayedOldPollCannotOverwriteNewConnection() {
        let oldConnectionId = "conn-old"
        let newConnectionId = "conn-new"
        var currentConnectionId: String? = oldConnectionId
        var publishedConnectionId = oldConnectionId

        // A replacement Connect supersedes the old poll while its cancellation-ignoring request
        // remains in flight. The old response must fail the post-await identity check.
        currentConnectionId = newConnectionId
        if ComposioPollPublicationPolicy.canPublish(
            isCancelled: true,
            currentConnectionId: currentConnectionId,
            polledConnectionId: oldConnectionId,
            currentPollGeneration: 2,
            polledGeneration: 1
        ) {
            publishedConnectionId = oldConnectionId
        } else {
            publishedConnectionId = newConnectionId
        }

        #expect(publishedConnectionId == newConnectionId)
        #expect(!ComposioPollPublicationPolicy.canPublish(
            isCancelled: false,
            currentConnectionId: currentConnectionId,
            polledConnectionId: oldConnectionId,
            currentPollGeneration: 2,
            polledGeneration: 2
        ))
    }

    @Test func replacedSameConnectionPollCannotPublishOrClearNewerPoll() {
        #expect(!ComposioPollPublicationPolicy.canPublish(
            isCancelled: false,
            currentConnectionId: "conn-same",
            polledConnectionId: "conn-same",
            currentPollGeneration: 2,
            polledGeneration: 1
        ))
    }

    @Test func cancelledOldFifthPollCannotClearNewerConnectionSpinner() {
        #expect(!ComposioPollPublicationPolicy.canClearConnectingAfterExhaustion(
            isCancelled: true,
            currentConnectionId: "conn-new",
            polledConnectionId: "conn-old",
            currentPollGeneration: 6,
            polledGeneration: 5
        ))
        #expect(!ComposioPollPublicationPolicy.canClearConnectingAfterExhaustion(
            isCancelled: false,
            currentConnectionId: "conn-new",
            polledConnectionId: "conn-old",
            currentPollGeneration: 6,
            polledGeneration: 5
        ))
    }

    @Test func delayedPollCannotOverwritePauseAdmission() {
        let admittedPollGeneration = 4
        let pauseGeneration = ComposioPollPublicationPolicy.nextGeneration(
            after: admittedPollGeneration
        )

        #expect(!ComposioPollPublicationPolicy.canPublish(
            isCancelled: false,
            currentConnectionId: "conn-active",
            polledConnectionId: "conn-active",
            currentPollGeneration: pauseGeneration,
            polledGeneration: admittedPollGeneration
        ))
    }

    @Test func delayedPollCannotOverwriteDisconnectAdmission() {
        let admittedPollGeneration = 8
        let disconnectGeneration = ComposioPollPublicationPolicy.nextGeneration(
            after: admittedPollGeneration
        )

        #expect(!ComposioPollPublicationPolicy.canPublish(
            isCancelled: true,
            currentConnectionId: nil,
            polledConnectionId: "conn-revoked",
            currentPollGeneration: disconnectGeneration,
            polledGeneration: admittedPollGeneration
        ))
    }

    @Test func activeGrantRequiresAcknowledgedRuntimeBeforeShowingActive() {
        let unavailable = ComposioConnectionState(
            toolkit: "discord",
            status: "connected",
            connectedAccountId: "acct-discord",
            enabled: true,
            runtimeReady: false,
            runtimeSyncing: false
        )
        let ready = ComposioConnectionState(
            toolkit: "discord",
            status: "connected",
            connectedAccountId: "acct-discord",
            enabled: true,
            runtimeReady: true
        )

        #expect(ComposioAvailabilityPresentation.statusLabel(for: unavailable, isConnecting: false) ==
            "Connected • Runtime unavailable")
        #expect(ComposioAvailabilityPresentation.statusLabel(for: ready, isConnecting: false) ==
            "Connected • Active")
    }

    @Test func activeGrantShowsActivatingWhileBoundedRuntimeSyncContinues() {
        let syncing = ComposioConnectionState(
            toolkit: "discord",
            status: "connected",
            connectedAccountId: "acct-discord",
            enabled: true,
            runtimeReady: false,
            runtimeSyncing: true
        )

        #expect(ComposioAvailabilityPresentation.statusLabel(for: syncing, isConnecting: false) ==
            "Connected • Activating…")
    }

    @Test func pausedGrantRemainsDistinctFromRuntimeFailure() {
        let paused = ComposioConnectionState(
            toolkit: "discord",
            status: "connected",
            connectedAccountId: "acct-discord",
            enabled: false,
            runtimeReady: false
        )

        #expect(ComposioAvailabilityPresentation.statusLabel(for: paused, isConnecting: false) ==
            "Connected • Paused")
    }

    @Test func incompletePauseDoesNotClaimTheToolkitIsAlreadyPaused() {
        let updating = ComposioConnectionState(
            toolkit: "discord",
            status: "connected",
            connectedAccountId: "acct-discord",
            enabled: false,
            runtimeReady: false,
            runtimeSyncing: true
        )

        #expect(ComposioAvailabilityPresentation.statusLabel(for: updating, isConnecting: false) ==
            "Connected • Updating…")
    }

    @Test func olderBackendResponsesDefaultToRuntimeUnavailable() throws {
        let catalog = try JSONDecoder().decode(
            ComposioToolkitsResponse.self,
            from: Data(#"{"configured":true,"toolkits":[]}"#.utf8)
        )
        let mutation = try JSONDecoder().decode(
            ComposioMutationResult.self,
            from: Data(#"{"updated":1}"#.utf8)
        )

        #expect(!catalog.isRuntimeReady)
        #expect(mutation.mutationStatus == nil)
        #expect(!mutation.isRuntimeReady)
        #expect(mutation.isAccepted)
        #expect(mutation.isCompleted)
        #expect(mutation.runtimeState == .unavailable)
    }

    @Test func successfulGrantMutationDecodesBeforeRuntimeFinishes() throws {
        let mutation = try JSONDecoder().decode(
            ComposioMutationResult.self,
            from: Data(#"{"updated":1,"mutationStatus":"completed","mutationAccepted":true,"mutationCompleted":true,"runtimeReady":false,"runtimeSyncing":true}"#.utf8)
        )

        #expect(mutation.mutationStatus == .completed)
        #expect(mutation.isAccepted)
        #expect(mutation.isCompleted)
        #expect(mutation.runtimeState == .syncing)
    }

    @Test func successfulSlowRuntimeMutationKeepsCommittedGrantEnabled() throws {
        let previous = ComposioConnectionState(
            toolkit: "discord",
            status: "connected",
            connectedAccountId: "acct-discord",
            enabled: false,
            runtimeReady: false
        )
        let mutation = try JSONDecoder().decode(
            ComposioMutationResult.self,
            from: Data(#"{"updated":1,"runtimeReady":false,"runtimeSyncing":true}"#.utf8)
        )

        let updated = ComposioAvailabilityPresentation.applying(
            mutation,
            to: previous,
            enabled: true
        )

        #expect(updated.isEnabled)
        #expect(updated.isRuntimeSyncing)
        #expect(ComposioAvailabilityPresentation.statusLabel(for: updated, isConnecting: false) ==
            "Connected • Activating…")
    }

    @Test func outcomeUnknownDoesNotClaimMutationAcceptanceOrCompletion() throws {
        let previous = ComposioConnectionState(
            toolkit: "discord",
            status: "connected",
            connectedAccountId: "acct-discord",
            enabled: true,
            runtimeReady: true
        )
        let outcome = try JSONDecoder().decode(
            ComposioMutationResult.self,
            from: Data(#"{"mutationStatus":"unknown","mutationCompleted":false,"runtimeReady":false,"runtimeSyncing":true}"#.utf8)
        )

        let updated = ComposioAvailabilityPresentation.applying(
            outcome,
            to: previous,
            enabled: false
        )

        #expect(outcome.mutationStatus == .unknown)
        #expect(outcome.mutationAccepted == nil)
        #expect(outcome.isOutcomeUnknown)
        #expect(!outcome.isAccepted)
        #expect(!outcome.isCompleted)
        #expect(!updated.isEnabled)
        #expect(ComposioAvailabilityPresentation.statusLabel(for: updated, isConnecting: false) ==
            "Connected • Updating…")
    }

    @Test func explicitFalseAcceptanceIsReservedForRejection() throws {
        let rejection = try JSONDecoder().decode(
            ComposioMutationResult.self,
            from: Data(#"{"mutationStatus":"rejected","mutationAccepted":false,"mutationCompleted":false}"#.utf8)
        )

        #expect(rejection.mutationStatus == .rejected)
        #expect(rejection.mutationAccepted == false)
        #expect(!rejection.isOutcomeUnknown)
        #expect(!rejection.isAccepted)
        #expect(!rejection.isCompleted)
    }
}

struct ComposioMutationFailurePolicyTests {
    @Test func transportAndServerFailuresDoNotRevertPotentiallyCommittedState() {
        #expect(!ComposioMutationFailurePolicy.shouldRevertOptimisticState(
            for: URLError(.timedOut)
        ))
        #expect(!ComposioMutationFailurePolicy.shouldRevertOptimisticState(
            for: ComposioServiceError.requestFailed(statusCode: 500, message: nil)
        ))
    }

    @Test func definitiveClientRejectionRevertsOptimisticState() {
        #expect(ComposioMutationFailurePolicy.shouldRevertOptimisticState(
            for: ComposioServiceError.requestFailed(statusCode: 400, message: "Unsupported toolkit")
        ))
        #expect(ComposioMutationFailurePolicy.shouldRevertOptimisticState(
            for: ComposioServiceError.requestFailed(statusCode: 401, message: "Unauthorized")
        ))
    }

    @Test func edgeTimeoutAndRateLimitRemainOutcomeUnknown() {
        #expect(!ComposioMutationFailurePolicy.shouldRevertOptimisticState(
            for: ComposioServiceError.requestFailed(statusCode: 408, message: "timeout")
        ))
        #expect(!ComposioMutationFailurePolicy.shouldRevertOptimisticState(
            for: ComposioServiceError.requestFailed(statusCode: 429, message: "slow down")
        ))
    }
}

// MARK: - Connect poll runs to a REAL terminal state (#1310)

/// A freshly-connected toolkit stranded on "Connected • Activating…".
///
/// `/composio/status/:id` bounds its observation of the gateway wire to ~2s, while the FIRST wire
/// after a new grant has to mint a Composio session and round-trip `config.get` + `config.patch` to
/// a Fly machine. So the first `connected` response nearly always carries `runtimeSyncing: true`.
/// The loop used to return right there, and `recheckInFlightConnections()` skipped anything already
/// reading as connected — so nothing ever re-asked and the row never reached "Connected • Active".
@MainActor
struct ComposioConnectPollDriverTests {
    /// No-delay budget so the tests exercise sequencing, not wall-clock.
    private static let budget = ComposioConnectPollDriver.Budget(
        grantAttempts: 5,
        grantDelay: .zero,
        runtimeAttempts: 10,
        runtimeDelay: .zero
    )

    private static func state(
        _ status: String,
        runtimeReady: Bool? = nil,
        runtimeSyncing: Bool? = nil
    ) -> ComposioConnectionState {
        ComposioConnectionState(
            toolkit: "gmail",
            status: status,
            connectedAccountId: status == "connected" ? "acct-1" : nil,
            enabled: status == "connected" ? true : nil,
            runtimeReady: runtimeReady,
            runtimeSyncing: runtimeSyncing
        )
    }

    /// Drives the real driver over a scripted response sequence.
    private static func drive(
        _ script: [ComposioConnectionState],
        publish: @escaping (ComposioConnectionState) -> Bool = { _ in true }
    ) async -> (
        termination: ComposioConnectPollDriver.Termination,
        published: [ComposioConnectionState],
        grantCommits: Int
    ) {
        var index = 0
        var published: [ComposioConnectionState] = []
        var grantCommits = 0
        let termination = await ComposioConnectPollDriver.run(
            budget: budget,
            isCancelled: { false },
            sleep: { _ in },
            fetch: {
                // Hold on the last scripted response once exhausted.
                let next = script[min(index, script.count - 1)]
                index += 1
                return next
            },
            publish: { candidate in
                guard publish(candidate) else { return false }
                published.append(candidate)
                return true
            },
            onGrantCommitted: { _ in grantCommits += 1 }
        )
        return (termination, published, grantCommits)
    }

    /// THE REGRESSION. Stopping at the committed grant leaves the row on "Activating…" forever.
    @Test func keepsPollingAfterTheGrantCommitsUntilTheRuntimeIsAcknowledged() async throws {
        let result = await Self.drive([
            Self.state("connected", runtimeReady: false, runtimeSyncing: true),
            Self.state("connected", runtimeReady: false, runtimeSyncing: true),
            Self.state("connected", runtimeReady: true)
        ])

        #expect(result.termination == .settled)
        // Three responses consumed, not one: the loop did not stop at the committed grant.
        #expect(result.published.count == 3)
        // And the state the row ends on is the ACTIVE one, not the syncing one.
        let final = try #require(result.published.last)
        #expect(ComposioAvailabilityPresentation.statusLabel(for: final, isConnecting: false) ==
            "Connected • Active")
        // The connect attempt still completes exactly once, at the first committed grant — the
        // toast and spinner must not wait for the runtime phase, and must not replay.
        #expect(result.grantCommits == 1)
    }

    /// The runtime phase gets its OWN budget: a slow OAuth must not consume the attempts the
    /// runtime needs. Grant lands on the last grant attempt, runtime still has room to settle.
    @Test func slowGrantStillLeavesTheRuntimePhaseItsFullBudget() async {
        let result = await Self.drive([
            Self.state("pending"),
            Self.state("pending"),
            Self.state("pending"),
            Self.state("pending"),
            Self.state("connected", runtimeReady: false, runtimeSyncing: true),
            Self.state("connected", runtimeReady: false, runtimeSyncing: true),
            Self.state("connected", runtimeReady: true)
        ])

        #expect(result.termination == .settled)
        #expect(result.published.count == 7)
    }

    /// An explicitly unavailable runtime is terminal — it is a verdict, not a waiting state, and
    /// must not spin the loop for its whole budget.
    @Test func runtimeUnavailableIsTerminalRatherThanPolledForever() async throws {
        let result = await Self.drive([
            Self.state("connected", runtimeReady: false, runtimeSyncing: false)
        ])

        #expect(result.termination == .settled)
        #expect(result.published.count == 1)
        let final = try #require(result.published.last)
        #expect(ComposioAvailabilityPresentation.statusLabel(for: final, isConnecting: false) ==
            "Connected • Runtime unavailable")
    }

    /// The runtime phase is BOUNDED — a permanently-syncing backend must not poll forever.
    @Test func perpetuallySyncingRuntimeStopsAtItsBudget() async {
        let result = await Self.drive([
            Self.state("connected", runtimeReady: false, runtimeSyncing: true)
        ])

        #expect(result.termination == .runtimeNotSettled)
        // 1 grant attempt + the full runtime budget, and no more.
        #expect(result.published.count == 1 + Self.budget.runtimeAttempts)
        #expect(result.grantCommits == 1)
    }

    /// A poll superseded on its LAST attempt, where the fetch threw so `publish` never ran and
    /// nothing could observe the supersede, must still report `.abandoned`. Reporting exhaustion
    /// there lets the caller release an admission gate the REPLACEMENT poll is holding — the
    /// replacement then abandons on its next publish and the row is stranded on "Activating…",
    /// which is the very failure this whole change exists to remove.
    @Test func supersededOnTheFinalAttemptAbandonsRatherThanReportingExhaustion() async {
        var cancelled = false
        var published: [ComposioConnectionState] = []
        let termination = await ComposioConnectPollDriver.run(
            budget: ComposioConnectPollDriver.Budget(
                grantAttempts: 5,
                grantDelay: .zero,
                // One runtime attempt, so the throwing fetch below IS the final attempt.
                runtimeAttempts: 1,
                runtimeDelay: .zero
            ),
            isCancelled: { cancelled },
            sleep: { _ in },
            fetch: {
                if published.isEmpty {
                    return Self.state("connected", runtimeReady: false, runtimeSyncing: true)
                }
                // The replacement poll took over while this fetch was in flight.
                cancelled = true
                throw ComposioServiceError.requestFailed(statusCode: 503, message: "superseded")
            },
            publish: { published.append($0); return true },
            onGrantCommitted: { _ in }
        )

        #expect(termination == .abandoned)
        #expect(published.count == 1)
    }

    @Test func failedConnectionIsStillTerminalImmediately() async {
        let result = await Self.drive([Self.state("failed")])

        #expect(result.termination == .failed)
        #expect(result.published.count == 1)
        #expect(result.grantCommits == 0)
    }

    @Test func neverCompletedOAuthExhaustsTheGrantBudgetOnly() async {
        let result = await Self.drive([Self.state("pending")])

        #expect(result.termination == .grantNotObserved)
        #expect(result.published.count == Self.budget.grantAttempts)
        #expect(result.grantCommits == 0)
    }

    /// A supersede (newer poll generation, or a pause/disconnect admission) must abandon the whole
    /// loop — including the new runtime phase, which must not keep republishing stale truth.
    @Test func supersededPollAbandonsWithoutEnteringTheRuntimePhase() async {
        let result = await Self.drive(
            [Self.state("connected", runtimeReady: false, runtimeSyncing: true)],
            publish: { _ in false }
        )

        #expect(result.termination == .abandoned)
        #expect(result.published.isEmpty)
        #expect(result.grantCommits == 0)
    }
}

/// The foreground re-check is the recovery path for a runtime that outlived the poll budget, so it
/// must treat "connected but still syncing" as unfinished business.
@MainActor
struct ComposioConnectPollStepTests {
    @Test func committedGrantWithSyncingRuntimeIsNotSettled() {
        let syncing = ComposioConnectionState(
            toolkit: "gmail",
            status: "connected",
            connectedAccountId: "acct-1",
            enabled: true,
            runtimeReady: false,
            runtimeSyncing: true
        )

        #expect(ComposioConnectPollStep.resolve(syncing) == .grantCommittedRuntimeSyncing)
        // The old `isConnected != true` guard read this as done and skipped the re-check.
        #expect(syncing.isConnected)
    }

    @Test func acknowledgedRuntimeIsSettledSoForegroundStopsReasking() {
        let ready = ComposioConnectionState(
            toolkit: "gmail",
            status: "connected",
            connectedAccountId: "acct-1",
            enabled: true,
            runtimeReady: true
        )

        #expect(ComposioConnectPollStep.resolve(ready) == .settled)
    }

    @Test func pendingAndFailedRemainNonSettled() {
        let pending = ComposioConnectionState(toolkit: "gmail", status: "pending", connectedAccountId: nil)
        let failed = ComposioConnectionState(toolkit: "gmail", status: "failed", connectedAccountId: nil)

        #expect(ComposioConnectPollStep.resolve(pending) == .awaitingGrant)
        #expect(ComposioConnectPollStep.resolve(failed) == .failed)
    }
}
