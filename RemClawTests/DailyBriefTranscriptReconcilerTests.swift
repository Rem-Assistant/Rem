import Foundation
import SwiftData
import Testing
@testable import RemClaw

@Suite
struct DailyBriefTranscriptReconcilerTests {
    private let counts = BriefCounts(
        blocked: 0,
        overdue: 0,
        scheduledToday: 0,
        completedToday: 0,
        total: 0,
        done: 0
    )

    @Test func reconciliationPreservesStructuredSnapshotAndUsesTranscriptProse() throws {
        let original = DailyBrief(
            generatedAt: "2026-08-06T20:00:00Z",
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "# Evening recap\n\nThree overdue items need your call.\n\nHere is what I suggest next.",
            summary: "You're all clear.",
            briefSessionKey: "rem-today-20260806"
        )
        let delivered = "# Evening recap\n\nThree overdue items need your call.\n\nHere is what I suggest next."
        let data = try history([
            message(role: "assistant", content: [["type": "text", "text": delivered]]),
            message(role: "user", content: [["type": "text", "text": "What should I do first?"]]),
            message(role: "assistant", content: [["type": "text", "text": "Start with the filing."]])
        ])

        let reconciled = DailyBriefTranscriptReconciler.reconcile(original, with: data)

        #expect(reconciled.counts == original.counts)
        #expect(reconciled.briefSessionKey == original.briefSessionKey)
        #expect(reconciled.briefMarkdown == delivered)
        #expect(reconciled.briefSummary == "You're all clear.")
        #expect(reconciled.displayedBriefMarkdown == delivered)
        #expect(reconciled.displayedBriefSummary == "Three overdue items need your call.")
        #expect(reconciled.firstTurnContextMarkdown == nil)
    }

    @Test func authoredArtifactGateRejectsSameDayReplacement() {
        let current = DailyBrief(
            generatedAt: "2026-08-08T17:30:00Z",
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "A newer empty-day artifact.",
            summary: "A newer empty-day artifact."
        )

        #expect(DailyBriefTranscriptReconciler.isCurrentAuthoredArtifact(
            expectedMarkdown: "A newer empty-day artifact.",
            currentBrief: current
        ))
        #expect(!DailyBriefTranscriptReconciler.isCurrentAuthoredArtifact(
            expectedMarkdown: "An older work brief.",
            currentBrief: current
        ))
    }

    @MainActor
    @Test func staleResolvedTranscriptCannotOverwriteNewerAgendaArtifact() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: StubTaskApiService(),
                modelContext: context
            )
        )
        let newer = DailyBrief(
            generatedAt: "2026-08-08T17:30:00Z",
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "A newer empty-day artifact.",
            summary: "A newer empty-day artifact."
        )
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefLoader: { newer }
        )
        await viewModel.loadBrief()

        let applied = viewModel.applyDurableBriefTranscript(
            "An older delivered work brief.",
            sessionKey: "rem-orchestrator",
            expectedAuthoredMarkdown: "An older work brief."
        )

        #expect(!applied)
        #expect(viewModel.brief?.briefMarkdown == "A newer empty-day artifact.")
        #expect(viewModel.brief?.transcriptMarkdown == nil)
    }

    @MainActor
    @Test func explicitPlaybackRefreshesStaleAgendaBeforeMatchingNewerHistory() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: StubTaskApiService(),
                modelContext: context
            )
        )
        let stale = DailyBrief(
            generatedAt: "2026-08-08T15:00:00Z",
            counts: counts,
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: "Stale all-clear.",
            summary: "Stale all-clear."
        )
        let newest = DailyBrief(
            generatedAt: "2026-08-08T18:00:00Z",
            counts: counts,
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: "Saturday brief with real work.",
            summary: "Saturday brief with real work."
        )
        let history = try JSONSerialization.data(withJSONObject: [
            "messages": [[
                "role": "assistant",
                "timestamp": Date().timeIntervalSince1970 * 1_000,
                "content": [["type": "text", "text": "Saturday brief with real work."]],
            ]],
        ])
        var backendBrief = stale
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { _ in history },
            briefLoader: { backendBrief }
        )

        await viewModel.loadBrief()
        #expect(viewModel.brief?.displayedBriefMarkdown == stale.markdown)

        backendBrief = newest
        let refresh = try await viewModel.fetchBriefForExplicitPlayback()
        let refreshed = try #require(viewModel.commitBriefForExplicitPlayback(refresh))

        #expect(refreshed.briefMarkdown == newest.markdown)
        #expect(refreshed.displayedBriefMarkdown == newest.markdown)
        #expect(viewModel.brief?.displayedBriefMarkdown == newest.markdown)
    }

    @MainActor
    @Test func explicitPlaybackRefreshWinsOverLateOrdinaryAgendaLoad() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: StubTaskApiService(),
                modelContext: context
            )
        )
        let stale = DailyBrief(
            generatedAt: "2026-08-08T15:00:00Z", counts: counts,
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: "Old all-clear.", summary: "Old all-clear."
        )
        let newest = DailyBrief(
            generatedAt: "2026-08-08T18:00:00Z", counts: counts,
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: "Newest Saturday brief.", summary: "Newest Saturday brief."
        )
        var invocation = 0
        var firstLoadContinuation: CheckedContinuation<DailyBrief, Never>?
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefLoader: {
                invocation += 1
                if invocation == 1 {
                    return await withCheckedContinuation { continuation in
                        firstLoadContinuation = continuation
                    }
                }
                return newest
            }
        )

        let olderLoad = Task { await viewModel.loadBrief() }
        while firstLoadContinuation == nil { await Task.yield() }

        let refresh = try await viewModel.fetchBriefForExplicitPlayback()
        let committed = try #require(viewModel.commitBriefForExplicitPlayback(refresh))
        firstLoadContinuation?.resume(returning: stale)
        await olderLoad.value

        #expect(committed.briefMarkdown == newest.briefMarkdown)
        #expect(viewModel.brief?.briefMarkdown == newest.briefMarkdown)
    }

    @MainActor
    @Test func fetchedExplicitBriefDoesNotPublishBeforeAccountRevalidationCommit() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: StubTaskApiService(),
                modelContext: context
            )
        )
        let privateBrief = DailyBrief(
            generatedAt: "2026-08-08T18:00:00Z", counts: counts,
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: "Former account private brief.", summary: "Former account private brief."
        )
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefLoader: { privateBrief }
        )

        _ = try await viewModel.fetchBriefForExplicitPlayback()

        #expect(viewModel.brief == nil)
    }

    @Test func completedPlaybackReceiptMatchesOnlyTheSameAccountBriefAndLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let formatter = ISO8601DateFormatter()
        let completedAt = formatter.date(from: "2026-08-08T06:30:00Z")!
        let nextLocalDay = formatter.date(from: "2026-08-08T07:01:00Z")!

        let completed = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T15:00:00Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "First brief",
            date: completedAt,
            calendar: calendar
        ))
        let encoded = DailyBriefPlaybackReceipt.recording(completed, in: "")

        #expect(DailyBriefPlaybackReceipt.contains(completed, in: encoded))
        #expect(!DailyBriefPlaybackReceipt.contains(DailyBriefPlaybackReceipt.identity(
            accountID: "account-b",
            generatedAt: "2026-08-07T15:00:00Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "First brief",
            date: completedAt,
            calendar: calendar
        ), in: encoded))
        #expect(!DailyBriefPlaybackReceipt.contains(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T15:00:00Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "First brief",
            date: nextLocalDay,
            calendar: calendar
        ), in: encoded))
        #expect(!DailyBriefPlaybackReceipt.contains(nil, in: encoded))
    }

    @Test func regeneratedBriefOnSameDayRequiresItsOwnCompletion() throws {
        let date = Date(timeIntervalSince1970: 1_786_089_600)
        let first = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T15:00:00Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "First brief",
            date: date
        ))
        let regenerated = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T18:00:00Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "Updated brief",
            date: date
        ))
        let encoded = DailyBriefPlaybackReceipt.recording(first, in: "")

        #expect(DailyBriefPlaybackReceipt.contains(first, in: encoded))
        #expect(!DailyBriefPlaybackReceipt.contains(regenerated, in: encoded))
    }

    @Test func generatedTimestampChurnDoesNotMakeIdenticalTranscriptUnread() throws {
        let date = Date(timeIntervalSince1970: 1_786_089_600)
        let completed = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T15:00:00Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "The durable authored brief",
            date: date
        ))
        let refreshed = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T15:04:31Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "The durable authored brief",
            date: date
        ))
        let changed = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T15:04:31Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "A genuinely changed authored brief",
            date: date
        ))
        let encoded = DailyBriefPlaybackReceipt.recording(completed, in: "")

        #expect(refreshed == completed)
        #expect(DailyBriefPlaybackReceipt.contains(refreshed, in: encoded))
        #expect(changed != completed)
        #expect(!DailyBriefPlaybackReceipt.contains(changed, in: encoded))
    }

    @Test func completionReceiptUsesSpokenDurableTranscriptInsteadOfAgendaCache() throws {
        let tapped = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "2026-08-07T15:00:00Z",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "Stale Agenda all-clear copy"
        ))
        let spoken = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: tapped.accountID,
            localDayKey: tapped.localDayKey,
            sessionKey: "rem-orchestrator",
            briefMarkdown: "Durable transcript with overdue work"
        ))
        let reconciledAgenda = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "a later volatile GET timestamp",
            sessionKey: "rem-orchestrator",
            briefMarkdown: "Durable transcript with overdue work"
        ))
        let encoded = DailyBriefPlaybackReceipt.recording(spoken, in: "")

        #expect(spoken != tapped)
        #expect(reconciledAgenda == spoken)
        #expect(DailyBriefPlaybackReceipt.contains(reconciledAgenda, in: encoded))
        #expect(!DailyBriefPlaybackReceipt.contains(tapped, in: encoded))
    }

    @Test func accountLedgerRetainsIndependentLatestReceipts() throws {
        let accountA = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "brief-a",
            sessionKey: nil,
            briefMarkdown: nil
        ))
        let accountB = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-b",
            generatedAt: "brief-b",
            sessionKey: nil,
            briefMarkdown: nil
        ))
        let afterA = DailyBriefPlaybackReceipt.recording(accountA, in: "")
        let afterB = DailyBriefPlaybackReceipt.recording(accountB, in: afterA)

        #expect(DailyBriefPlaybackReceipt.contains(accountA, in: afterB))
        #expect(DailyBriefPlaybackReceipt.contains(accountB, in: afterB))
        #expect(DailyBriefPlaybackReceipt.identity(
            accountID: "   ",
            generatedAt: "brief",
            sessionKey: nil,
            briefMarkdown: nil
        ) == nil)
    }

    @Test func contentFingerprintDistinguishesBriefsWithoutGeneratedIdentity() throws {
        let first = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: nil,
            sessionKey: "rem-orchestrator",
            briefMarkdown: "First brief"
        ))
        let updated = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: nil,
            sessionKey: "rem-orchestrator",
            briefMarkdown: "Updated brief"
        ))

        #expect(first != updated)
        #expect(!DailyBriefPlaybackReceipt.contains(
            updated,
            in: DailyBriefPlaybackReceipt.recording(first, in: "")
        ))
    }

    @Test func malformedReceiptLedgerFailsClosed() throws {
        let identity = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "brief",
            sessionKey: nil,
            briefMarkdown: nil
        ))

        #expect(!DailyBriefPlaybackReceipt.contains(identity, in: "not-json"))
    }

    @Test func playbackGateRejectsAnAccountSwitchWhileHistoryLoads() {
        let requestID = UUID()

        #expect(!LatestBriefPlaybackGate.shouldStart(
            requestID: requestID,
            activeRequestID: requestID,
            destinationDepth: 1,
            currentDepth: 1,
            expectedSessionKey: "rem-orchestrator",
            currentSessionKey: "rem-orchestrator",
            expectedAccountID: "account-a",
            currentAccountID: "account-b"
        ))
        #expect(!LatestBriefPlaybackGate.shouldStart(
            requestID: requestID,
            activeRequestID: requestID,
            destinationDepth: 1,
            currentDepth: 1,
            expectedSessionKey: "rem-orchestrator",
            currentSessionKey: "rem-orchestrator",
            expectedAccountID: "account-a",
            currentAccountID: nil
        ))
    }

    @Test func activeBriefPlaybackCancelsAndCannotRecordAcrossAccountSwitch() {
        #expect(DailyBriefPlaybackAccountBoundary.shouldCancelActivePlayback(
            previousAccountID: "account-a",
            currentAccountID: "account-b",
            isBriefVoiceSession: true,
            isTalkModeEnabled: true
        ))
        #expect(DailyBriefPlaybackAccountBoundary.shouldCancelActivePlayback(
            previousAccountID: "account-a",
            currentAccountID: nil,
            isBriefVoiceSession: true,
            isTalkModeEnabled: true
        ))
        #expect(!DailyBriefPlaybackAccountBoundary.shouldCancelActivePlayback(
            previousAccountID: "account-a",
            currentAccountID: "account-b",
            isBriefVoiceSession: false,
            isTalkModeEnabled: true
        ))
        #expect(!DailyBriefPlaybackAccountBoundary.shouldCancelActivePlayback(
            previousAccountID: "account-a",
            currentAccountID: "account-b",
            isBriefVoiceSession: true,
            isTalkModeEnabled: false
        ))
        #expect(!DailyBriefPlaybackAccountBoundary.canRecordCompletion(
            expectedAccountID: "account-a",
            currentAccountID: "account-b"
        ))
        #expect(!DailyBriefPlaybackAccountBoundary.canRecordCompletion(
            expectedAccountID: "account-a",
            currentAccountID: nil
        ))
        #expect(DailyBriefPlaybackAccountBoundary.canRecordCompletion(
            expectedAccountID: "account-a",
            currentAccountID: "account-a"
        ))
    }

    @Test @MainActor
    func gatePassedRequestSuspendedForChatSessionCannotStartAfterTeardown() async throws {
        let controller = LatestBriefPlaybackController()
        let gate = BriefPlaybackSuspensionGate()
        let requestID = try #require(controller.beginRequest())
        var didEnablePlayback = false

        let task = Task { @MainActor in
            // This represents the first gate in openAndReadLatestBrief passing.
            guard controller.canContinue(requestID) else { return }
            // gateway.client.chatSession can suspend here without throwing on cancellation.
            await gate.suspend()
            guard controller.canContinue(requestID) else { return }
            guard controller.markBriefVoiceSessionStarted(for: requestID) else { return }
            didEnablePlayback = true
        }
        controller.retain(task, for: requestID)
        while !(await gate.hasSuspended()) {
            await Task.yield()
        }

        #expect(!controller.invalidateAll())
        await gate.resume()
        await task.value

        #expect(!didEnablePlayback)
        #expect(!controller.hasPendingRequest)
        #expect(!controller.isBriefVoiceSession)
    }

    @Test @MainActor
    func manualVoiceStartSupersedesPendingBriefBeforeLateHistoryCanNarrate() async throws {
        let controller = LatestBriefPlaybackController()
        let gate = BriefPlaybackSuspensionGate()
        let requestID = try #require(controller.beginRequest())
        var didNarrateBrief = false

        let task = Task { @MainActor in
            await gate.suspend()
            guard controller.canContinue(requestID) else { return }
            guard controller.markBriefVoiceSessionStarted(for: requestID) else { return }
            didNarrateBrief = true
        }
        controller.retain(task, for: requestID)
        while !(await gate.hasSuspended()) {
            await Task.yield()
        }

        // `startVoiceSession` performs this invalidation before starting manual Talk Mode.
        #expect(!controller.invalidateAll())
        await gate.resume()
        await task.value

        #expect(!didNarrateBrief)
        #expect(!controller.hasPendingRequest)
        #expect(!controller.isBriefVoiceSession)
    }

    @Test @MainActor
    func newerNotificationReadSupersedesOlderSuspendedRead() async throws {
        let controller = LatestBriefPlaybackController()
        let olderGate = BriefPlaybackSuspensionGate()
        let olderRequestID = try #require(controller.beginRequest())
        var narratedRequestIDs: [UUID] = []

        let olderTask = Task { @MainActor in
            await olderGate.suspend()
            guard controller.canContinue(olderRequestID),
                  controller.markBriefVoiceSessionStarted(for: olderRequestID)
            else { return }
            narratedRequestIDs.append(olderRequestID)
        }
        controller.retain(olderTask, for: olderRequestID)
        while !(await olderGate.hasSuspended()) {
            await Task.yield()
        }

        let newerRequestID = try #require(controller.beginRequest(
            supersedingActiveRequest: true
        ))
        #expect(newerRequestID != olderRequestID)
        #expect(controller.activeRequestID == newerRequestID)
        #expect(!controller.canContinue(olderRequestID))

        let newerTask = Task { @MainActor in
            guard controller.canContinue(newerRequestID),
                  controller.markBriefVoiceSessionStarted(for: newerRequestID)
            else { return }
            narratedRequestIDs.append(newerRequestID)
        }
        controller.retain(newerTask, for: newerRequestID)
        await olderGate.resume()
        await olderTask.value
        await newerTask.value

        #expect(narratedRequestIDs == [newerRequestID])
        #expect(controller.isBriefVoiceSession)
        controller.finishRequest(newerRequestID)
    }

    @Test @MainActor
    func newerNotificationStopsActiveAudioEvenWhenReplacementLaterFails() throws {
        let controller = LatestBriefPlaybackController()
        let olderRequestID = try #require(controller.beginRequest())
        #expect(controller.markBriefVoiceSessionStarted(for: olderRequestID))
        var staleAudioIsPlaying = true
        var stoppedBeforeReplacementWasMinted = false

        let replacementRequestID = try #require(controller.beginRequest(
            supersedingActiveRequest: true,
            onSupersedeActivePlayback: {
                staleAudioIsPlaying = false
                stoppedBeforeReplacementWasMinted = controller.activeRequestID == olderRequestID
            }
        ))

        #expect(stoppedBeforeReplacementWasMinted)
        #expect(!staleAudioIsPlaying)
        #expect(!controller.isBriefVoiceSession)
        #expect(controller.activeRequestID == replacementRequestID)

        // Model a failed refresh/history lookup. The old audio stays stopped even though the
        // replacement never reaches Talk Mode.
        controller.finishRequest(replacementRequestID)
        #expect(!staleAudioIsPlaying)
        #expect(!controller.hasPendingRequest)
        #expect(!controller.isBriefVoiceSession)
    }

    @Test @MainActor
    func authTransitionStillOwnsBriefVoiceAfterReadingBecomesListening() throws {
        let controller = LatestBriefPlaybackController()
        let requestID = try #require(controller.beginRequest())
        #expect(controller.markBriefVoiceSessionStarted(for: requestID))

        // The request task finishes when narration completes, while Talk Mode intentionally stays
        // enabled and listening. The brief origin must survive that transition.
        controller.finishRequest(requestID)
        #expect(!controller.hasPendingRequest)
        #expect(controller.isBriefVoiceSession)
        #expect(DailyBriefPlaybackAccountBoundary.shouldCancelActivePlayback(
            previousAccountID: "account-a",
            currentAccountID: "account-b",
            isBriefVoiceSession: controller.invalidateAll(),
            isTalkModeEnabled: true
        ))
    }

    @Test func authenticatedRootDisappearanceTearsDownOnceThenBecomesANoOp() {
        let active = DailyBriefPlaybackLifecycle.teardownDecision(
            hasPendingRequest: true,
            isTalkModeEnabled: true
        )
        #expect(active == DailyBriefPlaybackTeardownDecision(
            invalidatePendingRequest: true,
            stopTalkMode: true
        ))

        // After applying the first decision, repeating the lifecycle callback is harmless.
        let alreadyTornDown = DailyBriefPlaybackLifecycle.teardownDecision(
            hasPendingRequest: false,
            isTalkModeEnabled: false
        )
        #expect(alreadyTornDown == DailyBriefPlaybackTeardownDecision(
            invalidatePendingRequest: false,
            stopTalkMode: false
        ))
    }

    @Test func disappearanceStillInvalidatesHistoryBeforeNarrationStarts() {
        #expect(DailyBriefPlaybackLifecycle.teardownDecision(
            hasPendingRequest: true,
            isTalkModeEnabled: false
        ) == DailyBriefPlaybackTeardownDecision(
            invalidatePendingRequest: true,
            stopTalkMode: false
        ))
    }

    @Test func completedReceiptCapturesTheTappedDayAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let completedAt = try #require(ISO8601DateFormatter().date(
            from: "2026-08-08T06:59:00Z"
        ))
        let identity = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            generatedAt: "brief",
            sessionKey: nil,
            briefMarkdown: nil,
            date: completedAt,
            calendar: calendar
        ))

        #expect(identity.localDayKey == "1-2026-8-7")
    }

    @Test func exactBriefMatchIgnoresOrdinaryRepliesAndChoosesLatestDuplicate() throws {
        let data = try history([
            message(role: "user", content: [["type": "text", "text": "Before the brief"]]),
            message(role: "assistant", content: [["type": "text", "text": "Morning artifact"]]),
            message(role: "assistant", content: [["type": "text", "text": "Ordinary reply before"]]),
            message(role: "assistant", content: [["type": "text", "text": "Night artifact"]]),
            message(role: "user", content: [["type": "text", "text": "Tell me more"]]),
            message(role: "assistant", content: [["type": "text", "text": "Ordinary reply after"]]),
            message(role: "assistant", content: [["type": "text", "text": "Night artifact"]]),
        ])

        let artifact = try #require(DailyBriefTranscriptReconciler.latestExactArtifact(
            from: data,
            matching: "Night artifact"
        ))
        #expect(artifact.markdown == "Night artifact")
        #expect(!artifact.fingerprint.isEmpty)
    }

    @Test func exactBriefMatchNormalizesModelRoleAndImplicitTextType() throws {
        let data = try history([[
            "role": " Model ",
            "timestamp": Date().timeIntervalSince1970 * 1_000,
            "content": [["text": "Delivered by a model-role gateway"]],
        ]])

        #expect(
            DailyBriefTranscriptReconciler.latestExactArtifact(
                from: data,
                matching: "Delivered by a model-role gateway"
            )?.markdown == "Delivered by a model-role gateway"
        )
    }

    @Test func staleAgendaCacheCannotSelectAnotherAssistantMessageAsBrief() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_786_204_800) // 2026-08-08 16:00 UTC
        let data = try history([
            message(
                role: "assistant",
                content: [["type": "text", "text": "Saturday brief with overdue work"]],
                provider: "minimax",
                model: "minimax-m2.7"
            ),
            message(
                role: "assistant",
                content: [["type": "text", "text": "You're all clear — nothing needs you today."]],
                provider: "openclaw",
                model: "gateway-injected"
            ),
        ])

        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: data,
            matching: "Stale Agenda all-clear cache",
            now: now,
            calendar: calendar
        ) == nil)
    }

    @Test func gatewayInjectedArtifactIsAcceptedWhenItExactlyMatchesBackendIdentity() throws {
        let data = try history([
            message(
                role: "assistant",
                content: [["type": "text", "text": "Friday prose retried on Saturday"]],
                provider: "openclaw",
                model: "gateway-injected"
            ),
        ])

        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: data,
            matching: "Friday prose retried on Saturday"
        )?.markdown == "Friday prose retried on Saturday")
    }

    @Test func userReplyIsNeverReclassifiedAsTheDailyBrief() throws {
        let data = try history([
            message(
                role: "assistant",
                content: [["type": "text", "text": "Saturday proactive brief"]],
                provider: "minimax",
                model: "minimax-m2.7"
            ),
            message(role: "user", content: [["type": "text", "text": "Help with the first one"]]),
            message(
                role: "assistant",
                content: [["type": "text", "text": "Here is the next step"]],
                provider: "minimax",
                model: "minimax-m2.7"
            ),
        ])

        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: data,
            matching: "Saturday proactive brief"
        )?.markdown == "Saturday proactive brief")
    }

    @Test func proactiveBriefAfterEarlierConversationStillWins() throws {
        let data = try history([
            message(role: "user", content: [["type": "text", "text": "My father-in-law"]]),
            message(
                role: "assistant",
                content: [["type": "text", "text": "What about him?"]],
                provider: "minimax",
                model: "minimax-m2.7"
            ),
            message(
                role: "assistant",
                content: [["type": "text", "text": "Saturday brief with blocked work"]],
                provider: "minimax",
                model: "minimax-m2.7"
            ),
            message(
                role: "assistant",
                content: [["type": "text", "text": "You're all clear."]],
                provider: "openclaw",
                model: "gateway-injected"
            ),
        ])

        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: data,
            matching: "Saturday brief with blocked work"
        )?.markdown == "Saturday brief with blocked work")
    }

    @Test func toolAssistedReplyIsNeverInferredToBeABrief() throws {
        let data = try history([
            message(role: "user", content: [["type": "text", "text": "Check my Gmail"]]),
            message(
                role: "assistant",
                content: [["type": "toolCall", "name": "gmail.search"]],
                provider: "minimax",
                model: "minimax-m2.7"
            ),
            message(role: "toolResult", content: [["type": "text", "text": "3 messages"]]),
            message(
                role: "assistant",
                content: [["type": "text", "text": "I found three messages."]],
                provider: "minimax",
                model: "minimax-m2.7"
            ),
        ])

        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: data,
            matching: "A backend brief that is not present"
        ) == nil)
    }

    @Test func staleBriefCacheFailsClosedInsteadOfChoosingAnAssistantByPosition() throws {
        let data = try history([
            message(role: "assistant", content: [["type": "text", "text": "Morning artifact"]]),
            message(role: "assistant", content: [["type": "text", "text": "Night artifact"]]),
            message(role: "assistant", content: [["type": "text", "text": "Ordinary reply"]]),
        ])
        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: data,
            matching: "Stale all-clear cache"
        ) == nil)
    }

    @Test func malformedOrEmptyHistoryKeepsCachedBrief() throws {
        let original = DailyBrief(
            generatedAt: nil,
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "Cached brief",
            summary: "Cached brief",
            briefSessionKey: "rem-today-20260806"
        )

        #expect(
            DailyBriefTranscriptReconciler.reconcile(original, with: Data("not json".utf8)) == original
        )
        #expect(
            DailyBriefTranscriptReconciler.reconcile(original, with: try history([
                message(role: "assistant", content: [["type": "thinking", "thinking": "only thought"]])
            ])) == original
        )
    }

    @Test func priorDayAssistantDoesNotReplaceTodaysBrief() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_786_665_600) // 2026-08-14 00:00 UTC
        let yesterday = now.addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000
        let data = try history([[
            "role": "assistant",
            "timestamp": yesterday,
            "provider": "openclaw",
            "model": "gateway-injected",
            "content": [["type": "text", "text": "Yesterday's reply"]],
        ]])

        #expect(
            DailyBriefTranscriptReconciler.latestDeliveredArtifact(
                from: data,
                matching: "Yesterday's reply",
                now: now,
                calendar: calendar
            ) == nil
        )
    }

    @Test func readLatestResolvesBackendCanonicalArtifactWhenVisibleHistoryOmitsTimestamp() throws {
        let canonical = "# Today\n\nThe same-day canonical brief is visibly present."
        let data = try history([[
            "role": "assistant",
            "provider": "openclaw",
            "model": "gateway-injected",
            "content": [["type": "text", "text": canonical]],
        ]])

        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: data,
            matching: canonical
        ) == nil)
        #expect(DailyBriefTranscriptReconciler.currentCanonicalArtifact(
            from: data,
            matching: canonical
        )?.markdown == canonical)
    }

    @Test func nilBackendAuthorityRejectsHistoricalExactMatchForExplicitRead() throws {
        let fallback = "You're all clear."
        let backendResponse = DailyBrief(
            generatedAt: "2026-08-08T18:00:00Z",
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: fallback,
            summary: fallback,
            briefSessionKey: nil
        )
        let historicalHistory = try history([[
            "role": "assistant",
            "timestamp": 1_700_000_000_000,
            "content": [["type": "text", "text": fallback]],
        ]])

        // Discovery without backend authority still rejects a prior-device-day equality. The
        // low-level canonical matcher may ignore device-day presentation, but the composed API
        // below must withhold it because no current gateway artifact was authorized.
        #expect(DailyBriefTranscriptReconciler.latestDeliveredArtifact(
            from: historicalHistory,
            matching: fallback
        ) == nil)
        #expect(DailyBriefTranscriptReconciler.backendAuthorizedCanonicalMarkdown(
            from: backendResponse
        ) == nil)
        #expect(DailyBriefTranscriptReconciler.currentBackendAuthorizedArtifact(
            from: historicalHistory,
            for: backendResponse
        ) == nil)
    }

    @MainActor
    @Test func agendaDoesNotPromoteNilKeyFallbackFromSameDayExactEquality() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: StubTaskApiService(),
                modelContext: context
            )
        )
        let fallback = "You're all clear."
        let backendResponse = DailyBrief(
            generatedAt: "2026-08-08T18:00:00Z",
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: fallback,
            summary: fallback,
            briefSessionKey: nil
        )
        let sameDayHistory = try history([[
            "role": "assistant",
            "timestamp": Date().timeIntervalSince1970 * 1_000,
            "content": [["type": "text", "text": fallback]],
        ]])
        var requestedHistory = false
        var clearedSessionKeys: [String] = []
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { _ in
                requestedHistory = true
                return sameDayHistory
            },
            briefLoader: { backendResponse },
            briefContextClearer: { clearedSessionKeys.append($0) }
        )

        await viewModel.loadBrief()

        #expect(!requestedHistory)
        #expect(viewModel.brief?.displayedBriefMarkdown == fallback)
        #expect(viewModel.brief?.transcriptMarkdown == nil)
        #expect(viewModel.brief?.firstTurnContextMarkdown == fallback)
        #expect(viewModel.brief?.hasAgendaSurface == false)
        #expect(clearedSessionKeys.isEmpty)
    }

    @Test func durableBackendAuthorityAllowsExactTimestampLessArtifactForExplicitRead() throws {
        let canonical = "# Today\n\nThe backend-authorized artifact is visible."
        let backendResponse = DailyBrief(
            generatedAt: "2026-08-08T18:00:00Z",
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: canonical,
            summary: canonical,
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        let visibleHistory = try history([[
            "role": "assistant",
            "content": [["type": "text", "text": canonical]],
        ]])

        #expect(DailyBriefTranscriptReconciler.backendAuthorizedCanonicalMarkdown(
            from: backendResponse
        ) == canonical)
        #expect(DailyBriefTranscriptReconciler.currentBackendAuthorizedArtifact(
            from: visibleHistory,
            for: backendResponse
        )?.markdown == canonical)
    }

    @Test func durableBackendAuthorityAllowsCrossTimezoneLateTapOnNextDeviceDay() throws {
        let canonical = "# Today\n\nThe current prose happens to equal an older artifact."
        let backendResponse = DailyBrief(
            generatedAt: "2026-08-16T08:00:00Z",
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: canonical,
            summary: canonical,
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        let priorDay = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let priorDayHistory = try history([[
            "role": "assistant",
            "timestamp": priorDay.timeIntervalSince1970 * 1_000,
            "content": [["type": "text", "text": canonical]],
        ]])

        #expect(DailyBriefTranscriptReconciler.currentBackendAuthorizedArtifact(
            from: priorDayHistory,
            for: backendResponse
        )?.markdown == canonical)
    }

    @Test func requestParametersEscapesSessionKey() throws {
        let params = try #require(
            DailyBriefTranscriptReconciler.requestParameters(sessionKey: "rem-today-\"quoted\"")
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: String]
        )
        #expect(object["sessionKey"] == "rem-today-\"quoted\"")
    }

    @Test func agendaHistoryAlwaysUsesTheSameDurableConversationAsSummaryNavigation() {
        #expect(DailyBriefTranscriptReconciler.historySessionKeys(
            advertisedSessionKey: nil
        ) == ["rem-orchestrator"])
        #expect(DailyBriefTranscriptReconciler.historySessionKeys(
            advertisedSessionKey: "rem-today-20260807"
        ) == ["rem-orchestrator"])
        #expect(DailyBriefTranscriptReconciler.historySessionKeys(
            advertisedSessionKey: "rem-orchestrator"
        ) == ["rem-orchestrator"])
    }

    @Test func accessibilityUsesDurableSummaryAndDoesNotAnnounceMeaninglessZeroProgress() {
        let stale = DailyBrief(
            generatedAt: nil,
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "You're all clear.",
            summary: "You're all clear.",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        let reconciled = stale.replacingTranscriptProse(
            markdown: "Friday morning has four items that need your call.",
            summary: "Four items need your call."
        )

        let label = DailyBriefAgendaAccessibility.summary(for: reconciled)

        #expect(label == "Daily brief. Four items need your call.")
        #expect(!label.contains("0 of 0"))
    }

    @Test func playbackGateRequiresTheOriginalVisibleTodayDestination() {
        let requestID = UUID()
        let sessionKey = "rem-today-20260807"

        #expect(LatestBriefPlaybackGate.shouldStart(
            requestID: requestID,
            activeRequestID: requestID,
            destinationDepth: 1,
            currentDepth: 1,
            expectedSessionKey: sessionKey,
            currentSessionKey: sessionKey,
            expectedAccountID: "account-a",
            currentAccountID: "account-a"
        ))
        #expect(!LatestBriefPlaybackGate.shouldStart(
            requestID: requestID,
            activeRequestID: requestID,
            destinationDepth: 1,
            currentDepth: 2,
            expectedSessionKey: sessionKey,
            currentSessionKey: sessionKey,
            expectedAccountID: "account-a",
            currentAccountID: "account-a"
        ))
        #expect(!LatestBriefPlaybackGate.shouldStart(
            requestID: requestID,
            activeRequestID: UUID(),
            destinationDepth: 1,
            currentDepth: 1,
            expectedSessionKey: sessionKey,
            currentSessionKey: sessionKey,
            expectedAccountID: "account-a",
            currentAccountID: "account-a"
        ))
        #expect(!LatestBriefPlaybackGate.shouldStart(
            requestID: requestID,
            activeRequestID: requestID,
            destinationDepth: 1,
            currentDepth: 1,
            expectedSessionKey: sessionKey,
            currentSessionKey: "another-chat",
            expectedAccountID: "account-a",
            currentAccountID: "account-a"
        ))
    }

    private func history(_ messages: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "sessionKey": "rem-today-20260806",
            "sessionId": "fixture-session-id",
            "thinkingLevel": "low",
            "messages": messages,
        ])
    }

    private func message(
        role: String,
        content: [[String: Any]],
        provider: String? = nil,
        model: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "role": role,
            "timestamp": Date().timeIntervalSince1970 * 1_000,
            "content": content,
        ]
        if let provider { value["provider"] = provider }
        if let model { value["model"] = model }
        return value
    }
}

private actor BriefPlaybackSuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasSuspended() -> Bool { suspended }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite
struct AgendaBriefReconciliationRetryTests {
    private enum RetryError: Error { case transient }

    private final class NoopTaskApi: TaskApiServiceProtocol {
        func saveTaskToBackend(
            id: String?, title: String, priority: String, status: String,
            startDate: Date?, endDate: Date?, durationMinutes: Int?,
            alertTime: Date?, repeatFrequency: String?, description: String?,
            listID: String?
        ) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, listID: listID, descriptionUser: description)
        }

        func saveEventToBackend(
            id: String?, title: String, dateTime: String, durationMinutes: Int,
            listID: String?
        ) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id ?? UUID().uuidString, title: title, listID: listID)
        }

        func fetchTasks() async throws -> [TaskEventApiResponse] { [] }

        func getTask(id: String) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id, title: "")
        }

        func updateTask(
            id: String, title: String?, priority: String?, status: String?,
            startDate: Date?, endDate: Date?, durationMinutes: Int?,
            alertTime: Date?, repeatFrequency: String?, description: String?,
            listID: String?, includeListID: Bool, includeClearedFields: Bool
        ) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(id: id, title: title ?? "", listID: listID, descriptionUser: description)
        }

        func deleteTask(id: String) async throws {}

        func ensureEventBacking(
            calendarEventID: String, title: String, startDate: Date?,
            durationMinutes: Int?, listID: String?
        ) async throws -> TaskEventApiResponse {
            TaskEventApiResponse(
                id: UUID().uuidString,
                title: title,
                type: "calendar_event",
                calendarEventID: calendarEventID
            )
        }
    }

    @Test func failedNormalAgendaRefreshDoesNotRepublishSuggestionsForRetainedBrief() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskApi = NoopTaskApi()
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(taskApiService: taskApi, modelContext: context)
        )
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        var retainedBrief = DailyBrief(
            generatedAt: generatedAt,
            counts: BriefCounts(
                blocked: 0, overdue: 0, scheduledToday: 0,
                completedToday: 0, total: 0, done: 0
            ),
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "Retained authored brief",
            summary: "Retained authored brief"
        )
        let suggestion = TaskSuggestion(
            key: "cal:retained",
            actionId: "22222222-2222-5222-8222-222222222222",
            source: "calendar",
            title: "Prepare",
            subtitle: "Calendar",
            action: SuggestionAction(
                kind: "createTask",
                taskTitle: "Prepare",
                targetTaskId: nil,
                startDate: nil
            )
        )
        retainedBrief = DailyBrief(
            generatedAt: generatedAt,
            briefRevision: "revision-retained",
            suggestionSnapshotID: "snapshot-retained",
            suggestions: [suggestion],
            counts: retainedBrief.counts,
            blocked: retainedBrief.blocked,
            overdue: retainedBrief.overdue,
            scheduledToday: retainedBrief.scheduledToday,
            completedToday: retainedBrief.completedToday,
            markdown: retainedBrief.markdown,
            summary: retainedBrief.summary
        )
        var briefLoadCount = 0
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefLoader: {
                briefLoadCount += 1
                if briefLoadCount > 1 { throw RetryError.transient }
                return retainedBrief
            },
            suggestionMutationScope: { Self.suggestionScope }
        )

        await viewModel.refreshBriefAndSuggestions()
        #expect(viewModel.orchestratorSuggestionSnapshot() != nil)

        await viewModel.refreshBriefAndSuggestions()

        #expect(viewModel.brief?.briefMarkdown == retainedBrief.briefMarkdown)
        #expect(viewModel.suggestions.isEmpty)
        #expect(viewModel.orchestratorSuggestionSnapshot() == nil)
        #expect(briefLoadCount == 2)
    }

    @MainActor
    @Test func failedExplicitDismissRestoresSuggestionThroughFreshBrief() async throws {
        let fixture = try makeSuggestionLifecycleFixture(dismissalFails: true)

        await fixture.viewModel.refreshBriefAndSuggestions()
        await fixture.viewModel.dismissSuggestion(fixture.suggestion, snapshotID: "snapshot-current")

        #expect(fixture.briefLoadCount() == 2)
        #expect(fixture.viewModel.suggestions == [fixture.suggestion])
        #expect(fixture.viewModel.orchestratorSuggestionSnapshot() != nil)
    }

    @MainActor
    @Test func failedAcceptDismissRestoresSuggestionWithoutCreatingDuplicate() async throws {
        let fixture = try makeSuggestionLifecycleFixture(dismissalFails: true)

        await fixture.viewModel.refreshBriefAndSuggestions()
        await fixture.viewModel.acceptSuggestion(fixture.suggestion, snapshotID: "snapshot-current")

        #expect(fixture.briefLoadCount() == 2)
        #expect(fixture.taskStore.allTasks.count == 1)
        #expect(fixture.viewModel.suggestions == [fixture.suggestion])

        await fixture.viewModel.acceptSuggestion(fixture.suggestion, snapshotID: "snapshot-current")

        #expect(fixture.taskStore.allTasks.count == 1)
    }

    /// TIMEBLOCKING — one tap on Add must create the task ALREADY SCHEDULED.
    ///
    /// A task's `startDate` IS its timeblock, so "accepting a suggestion applies the recommended
    /// time" is exactly this: the instant the backend put on `action.startDate` reaches the created
    /// `TaskEvent`, and the task lands `.scheduled` rather than sitting untimed in the inbox.
    ///
    /// The fixture has always BUILT its suggestion with a real `startDate`, and `performAccept` has
    /// always read it — but nothing asserted the result, so deleting `startDate:` from the
    /// `TaskEvent(...)` call left every suggestion test green while shipping untimed tasks. This is
    /// that guard.
    @MainActor
    @Test func acceptingASuggestionSchedulesTheTaskAtTheProposedTime() async throws {
        let now = Date(timeIntervalSince1970: 1_786_620_600)
        let fixture = try makeSuggestionLifecycleFixture(
            dismissalFails: false,
            suggestionNow: { now }
        )

        await fixture.viewModel.refreshBriefAndSuggestions()
        await fixture.viewModel.acceptSuggestion(fixture.suggestion, snapshotID: "snapshot-current")

        let created = try #require(fixture.taskStore.allTasks.first)
        // Compared against the PROPOSAL parsed back, not against `now + 3600`: the wire format
        // carries whole seconds, so the round trip is the only honest expectation.
        let proposed = try #require(fixture.suggestion.action.startDate)
        let expected = try #require(TaskComment.parseISO8601(proposed))
        #expect(created.startDate == expected)
        // The user-visible consequence, and the predicate that actually routes the row:
        // `shouldAppearInAgenda` is `startDate != nil`, so a timed task lands on the agenda
        // instead of the inbox. Deliberately NOT `statusEnum == .scheduled` — `statusToBackend`
        // maps `.scheduled` and `.todo` to the same "pending", so that assertion could never
        // fail and would be a green signal measuring nothing.
        #expect(created.shouldAppearInAgenda)
        #expect(!created.shouldAppearInInbox)
    }

    @MainActor
    @Test func localSaveFailureDoesNotDismissAcceptedSuggestion() async throws {
        enum SaveError: Error { case failed }
        let fixture = try makeSuggestionLifecycleFixture(
            dismissalFails: false,
            suggestionLocalSaver: { throw SaveError.failed }
        )

        await fixture.viewModel.refreshBriefAndSuggestions()
        await fixture.viewModel.acceptSuggestion(fixture.suggestion, snapshotID: "snapshot-current")

        #expect(fixture.dismissalCount() == 0)
        #expect(fixture.taskStore.allTasks.isEmpty)
        #expect(fixture.viewModel.suggestions == [fixture.suggestion])
    }

    @MainActor
    @Test func failedDurableQueueDoesNotDismissAcceptedSuggestion() async throws {
        let sync = ControlledSuggestionSyncService(createDurableResult: false)
        let fixture = try makeSuggestionLifecycleFixture(
            dismissalFails: false,
            taskSyncService: sync
        )

        await fixture.viewModel.refreshBriefAndSuggestions()
        await fixture.viewModel.acceptSuggestion(fixture.suggestion, snapshotID: "snapshot-current")

        #expect(fixture.dismissalCount() == 0)
        #expect(fixture.taskStore.allTasks.count == 1)
        #expect(fixture.viewModel.suggestions == [fixture.suggestion])
    }

    @MainActor
    @Test func accountScopeChangeDuringDurabilityAwaitPreventsCrossAccountDismissal() async throws {
        let sync = ControlledSuggestionSyncService(createDurableResult: true, suspendsCreate: true)
        var currentScope = Self.suggestionScope
        let fixture = try makeSuggestionLifecycleFixture(
            dismissalFails: false,
            suggestionMutationScope: { currentScope },
            taskSyncService: sync
        )
        await fixture.viewModel.refreshBriefAndSuggestions()

        let pending = Task {
            await fixture.viewModel.acceptSuggestion(
                fixture.suggestion,
                snapshotID: "snapshot-current"
            )
        }
        while !sync.hasPendingCreate { await Task.yield() }
        currentScope = AgendaSuggestionMutationScope(
            accountID: "account-b",
            backendURL: "https://backend.example",
            gatewayURL: "https://gateway.example"
        )!
        fixture.viewModel.invalidateSuggestionAuthority()
        sync.resumeCreate()
        await pending.value

        #expect(fixture.dismissalCount() == 0)
        #expect(fixture.viewModel.orchestratorSuggestionSnapshot() == nil)
    }

    @MainActor
    @Test func acceptUsesOneCapturedAuthorityForTaskMutationAndDismissal() async throws {
        let sync = ControlledSuggestionSyncService(createDurableResult: true)
        let fixture = try makeSuggestionLifecycleFixture(
            dismissalFails: false,
            taskSyncService: sync
        )
        await fixture.viewModel.refreshBriefAndSuggestions()

        await fixture.viewModel.acceptSuggestion(
            fixture.suggestion,
            snapshotID: "snapshot-current"
        )

        #expect(sync.createAuthority != nil)
        #expect(fixture.dismissalAuthority() == sync.createAuthority)
    }

    @MainActor
    @Test func staleSnapshotAndMidnightActionsFailClosedBeforeTaskMutation() async throws {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = try #require(formatter.date(from: "2026-08-16T23:59:00Z"))
        let fixture = try makeSuggestionLifecycleFixture(
            dismissalFails: false,
            suggestionNow: { now },
            suggestionCalendar: { calendar }
        )
        await fixture.viewModel.refreshBriefAndSuggestions()

        await fixture.viewModel.acceptSuggestion(fixture.suggestion, snapshotID: "stale-snapshot")
        #expect(fixture.taskStore.allTasks.isEmpty)

        now = try #require(formatter.date(from: "2026-08-17T00:01:00Z"))
        await fixture.viewModel.acceptSuggestion(fixture.suggestion, snapshotID: "snapshot-current")
        #expect(fixture.taskStore.allTasks.isEmpty)
    }

    @MainActor
    private func makeSuggestionLifecycleFixture(
        dismissalFails: Bool,
        suggestionNow: @escaping @MainActor () -> Date = Date.init,
        suggestionCalendar: @escaping @MainActor () -> Calendar = { .current },
        suggestionMutationScope: @escaping @MainActor () -> AgendaSuggestionMutationScope? = {
            Self.suggestionScope
        },
        suggestionLocalSaver: AgendaViewModel.SuggestionLocalSaver? = nil,
        taskSyncService: TaskSyncServiceProtocol? = nil
    ) throws -> (
        viewModel: AgendaViewModel,
        taskStore: TaskStore,
        suggestion: TaskSuggestion,
        briefLoadCount: () -> Int,
        dismissalCount: () -> Int,
        dismissalAuthority: () -> AuthenticatedHttpClient.RequestAuthority?
    ) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskApi = NoopTaskApi()
        let concreteSyncService = RemTaskSyncService(taskApiService: taskApi, modelContext: context)
        let suggestionSyncService: TaskSyncServiceProtocol = taskSyncService ?? concreteSyncService
        let taskStore = TaskStore(taskSyncService: concreteSyncService)
        let formatter = ISO8601DateFormatter()
        let generatedAt = formatter.string(from: suggestionNow())
        // DISTINCTLY not `now + 1h`. That is exactly the backend's `laterToday` fallback, so a
        // regression where the client computed the start itself instead of reading
        // `action.startDate` would produce the same instant and the accept test would still pass.
        // Three days out at a different time of day makes the proposal unmistakably the source.
        let startDate = formatter.string(from: suggestionNow().addingTimeInterval(3 * 86_400 + 4 * 3_600))
        let suggestion = TaskSuggestion(
            key: "gmail:one",
            actionId: "33333333-3333-5333-8333-333333333333",
            source: "gmail",
            title: "Reply to Ada",
            subtitle: "Ada · Gmail",
            action: SuggestionAction(
                kind: "createTask",
                taskTitle: "Reply to Ada",
                targetTaskId: nil,
                startDate: startDate
            )
        )
        let lifecycleCounts = BriefCounts(
            blocked: 0, overdue: 0, scheduledToday: 0,
            completedToday: 0, total: 0, done: 0
        )
        let brief = DailyBrief(
            generatedAt: generatedAt,
            briefRevision: "revision-current",
            suggestionSnapshotID: "snapshot-current",
            suggestions: [suggestion],
            counts: lifecycleCounts,
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: "Current authored brief",
            summary: "Current authored brief"
        )
        final class Counts {
            var brief = 0
            var dismissal = 0
            var dismissalAuthority: AuthenticatedHttpClient.RequestAuthority?
        }
        let loads = Counts()
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            taskSyncService: suggestionSyncService,
            briefLoader: {
                loads.brief += 1
                return brief
            },
            suggestionDismissal: { _, authority in
                loads.dismissal += 1
                loads.dismissalAuthority = authority
                if dismissalFails { throw RetryError.transient }
            },
            suggestionNow: suggestionNow,
            suggestionCalendar: suggestionCalendar,
            suggestionMutationScope: suggestionMutationScope,
            suggestionRequestAuthority: { _ in
                AuthenticatedHttpClient.RequestAuthority(
                    token: "fixture-token",
                    baseURL: "https://backend.example"
                )
            },
            suggestionLocalSaver: suggestionLocalSaver
        )
        return (
            viewModel,
            taskStore,
            suggestion,
            { loads.brief },
            { loads.dismissal },
            { loads.dismissalAuthority }
        )
    }

    @MainActor
    private final class ControlledSuggestionSyncService: ScopedSuggestionTaskSyncServiceProtocol {
        private let createDurableResult: Bool
        private let suspendsCreate: Bool
        private var createContinuation: CheckedContinuation<Void, Never>?
        private(set) var createAuthority: AuthenticatedHttpClient.RequestAuthority?

        init(createDurableResult: Bool, suspendsCreate: Bool = false) {
            self.createDurableResult = createDurableResult
            self.suspendsCreate = suspendsCreate
        }

        var hasPendingCreate: Bool { createContinuation != nil }

        func resumeCreate() {
            createContinuation?.resume()
            createContinuation = nil
        }

        func queueOperation(operationType: String, taskId: UUID?, taskData: Data?) async -> Bool { false }
        func discardPendingOperations(for taskId: UUID) async -> Bool { true }
        func updateTaskStatus(_ task: TaskEvent, to status: TaskStatus, modelContext: ModelContext) async throws {}
        func syncTaskToBackendImmediately(_ task: TaskEvent) async {}
        func syncTaskCreateToBackendImmediately(_ task: TaskEvent) async throws -> TaskEventApiResponse? { nil }
        func ensureTaskUpdateIsDurable(_ task: TaskEvent) async -> Bool { false }

        func ensureTaskCreateIsDurable(_ task: TaskEvent) async -> Bool {
            if suspendsCreate {
                await withCheckedContinuation { createContinuation = $0 }
            }
            return createDurableResult
        }

        func ensureSuggestionTaskCreateIsDurable(
            _ task: TaskEvent,
            authority: AuthenticatedHttpClient.RequestAuthority
        ) async -> Bool {
            createAuthority = authority
            return await ensureTaskCreateIsDurable(task)
        }

        func ensureSuggestionTaskUpdateIsDurable(
            _ task: TaskEvent,
            authority: AuthenticatedHttpClient.RequestAuthority
        ) async -> Bool {
            await ensureTaskUpdateIsDurable(task)
        }
    }

    private static let suggestionScope = AgendaSuggestionMutationScope(
        accountID: "account-a",
        backendURL: "https://backend.example",
        gatewayURL: "https://gateway.example"
    )!

    @Test func transientHistoryFailureRetriesOnceWithoutAnotherReadinessEdge() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskApi = NoopTaskApi()
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(taskApiService: taskApi, modelContext: context)
        )
        let counts = BriefCounts(
            blocked: 0,
            overdue: 0,
            scheduledToday: 0,
            completedToday: 0,
            total: 0,
            done: 0
        )
        let delivered = "# Evening recap\n\nOne durable item needs your decision."
        let cached = DailyBrief(
            generatedAt: nil,
            counts: counts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: delivered,
            summary: "Cached all-clear",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        let history = try JSONSerialization.data(withJSONObject: [
            "sessionKey": "rem-today-20260807",
            "messages": [[
                "role": "assistant",
                "timestamp": Date().timeIntervalSince1970 * 1_000,
                "content": [["type": "text", "text": delivered]],
            ]],
        ])
        var attempts = 0
        var persistedContext = ["rem-orchestrator": cached.briefMarkdown!]
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { _ in
                attempts += 1
                if attempts == 1 { throw RetryError.transient }
                return history
            },
            briefLoader: { cached },
            briefRetryDelay: {},
            briefContextClearer: { persistedContext.removeValue(forKey: $0) }
        )

        await viewModel.loadBrief()
        await viewModel.waitForScheduledBriefRetryForTesting()

        #expect(attempts == 2)
        #expect(viewModel.brief?.displayedBriefMarkdown == delivered)
        #expect(viewModel.brief?.firstTurnContextMarkdown == nil)
        #expect(persistedContext["rem-orchestrator"] == nil)
    }

    @Test func repeatedHistoryFailurePreservesSameReconciledCanonicalArtifact() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: NoopTaskApi(),
                modelContext: context
            )
        )
        let delivered = "# Morning brief\n\nThe same canonical item still needs attention."
        let payload = DailyBrief(
            generatedAt: "2026-08-09T15:00:00Z",
            counts: BriefCounts(
                blocked: 0, overdue: 1, scheduledToday: 0,
                completedToday: 0, total: 1, done: 0
            ),
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: delivered,
            summary: "Projected summary",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        let history = try JSONSerialization.data(withJSONObject: [
            "sessionKey": DailyBriefTranscriptReconciler.durableSessionKey,
            "messages": [[
                "role": "assistant",
                "content": [["type": "text", "text": delivered]],
            ]],
        ])
        final class HistoryState {
            var shouldFail = false
            var attempts = 0
        }
        let historyState = HistoryState()
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { _ in
                historyState.attempts += 1
                if historyState.shouldFail { throw RetryError.transient }
                return history
            },
            briefLoader: { payload },
            briefRetryDelay: {}
        )

        await viewModel.loadBrief()
        #expect(viewModel.brief?.hasAgendaSurface == true)

        historyState.shouldFail = true
        await viewModel.loadBrief()
        await viewModel.waitForScheduledBriefRetryForTesting()

        #expect(historyState.attempts == 3)
        #expect(viewModel.brief?.hasAgendaSurface == true)
        #expect(viewModel.brief?.transcriptMarkdown == delivered)
        #expect(viewModel.brief?.displayedBriefSummary ==
            "The same canonical item still needs attention.")
    }

    @Test func changedArtifactOrSessionInvalidatesPreviouslyReconciledTranscript() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: NoopTaskApi(),
                modelContext: context
            )
        )
        let original = "# Morning brief\n\nThe original canonical artifact."
        let replacement = "# Afternoon brief\n\nA replacement is still landing."
        func payload(markdown: String, sessionKey: String?) -> DailyBrief {
            DailyBrief(
                generatedAt: "2026-08-09T15:00:00Z",
                counts: BriefCounts(
                    blocked: 0, overdue: 0, scheduledToday: 0,
                    completedToday: 0, total: 0, done: 0
                ),
                blocked: [], overdue: [], scheduledToday: [], completedToday: [],
                markdown: markdown,
                summary: "Projected summary",
                briefSessionKey: sessionKey
            )
        }
        let originalHistory = try JSONSerialization.data(withJSONObject: [
            "sessionKey": DailyBriefTranscriptReconciler.durableSessionKey,
            "messages": [[
                "role": "assistant",
                "content": [["type": "text", "text": original]],
            ]],
        ])
        final class RefreshState {
            var payload: DailyBrief
            var historyShouldFail = false
            var historyAttempts = 0

            init(payload: DailyBrief) {
                self.payload = payload
            }
        }
        let state = RefreshState(payload: payload(
            markdown: original,
            sessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        ))
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { _ in
                state.historyAttempts += 1
                if state.historyShouldFail { throw RetryError.transient }
                return originalHistory
            },
            briefLoader: { state.payload },
            briefRetryDelay: {}
        )

        await viewModel.loadBrief()
        #expect(viewModel.brief?.hasAgendaSurface == true)

        state.payload = payload(
            markdown: replacement,
            sessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        state.historyShouldFail = true
        await viewModel.loadBrief()
        await viewModel.waitForScheduledBriefRetryForTesting()

        // The replacement loses the old reconciled transcript, but the backend's durable-session
        // authority and replacement prose still make it a truthful Agenda doorway while history
        // catches up.
        #expect(viewModel.brief?.hasAgendaSurface == true)
        #expect(viewModel.brief?.displayedBriefMarkdown == replacement)
        #expect(viewModel.brief?.transcriptMarkdown == nil)

        state.payload = payload(
            markdown: original,
            sessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        state.historyShouldFail = false
        await viewModel.loadBrief()
        #expect(viewModel.brief?.hasAgendaSurface == true)

        let attemptsBeforeSessionChange = state.historyAttempts
        state.payload = payload(markdown: original, sessionKey: "rem-today-legacy")
        await viewModel.loadBrief()

        #expect(state.historyAttempts == attemptsBeforeSessionChange)
        #expect(viewModel.brief?.hasAgendaSurface == false)
        #expect(viewModel.brief?.transcriptMarkdown == nil)
    }

    @Test func agendaAcceptsAuthorizedCanonicalArtifactWithoutProjectedTimestamp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: NoopTaskApi(),
                modelContext: context
            )
        )
        let delivered = "# Morning brief\n\nOne canonical item needs attention."
        let cached = DailyBrief(
            generatedAt: nil,
            counts: BriefCounts(
                blocked: 0, overdue: 1, scheduledToday: 0,
                completedToday: 0, total: 1, done: 0
            ),
            blocked: [], overdue: [], scheduledToday: [], completedToday: [],
            markdown: delivered,
            summary: "Stale projected summary",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )
        let history = try JSONSerialization.data(withJSONObject: [
            "sessionKey": DailyBriefTranscriptReconciler.durableSessionKey,
            "messages": [[
                "role": "assistant",
                "content": [["type": "text", "text": delivered]],
            ]],
        ])
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { _ in history },
            briefLoader: { cached }
        )

        await viewModel.loadBrief()

        #expect(viewModel.brief?.displayedBriefMarkdown == delivered)
        #expect(viewModel.brief?.displayedBriefSummary == "One canonical item needs attention.")
        #expect(viewModel.brief?.hasAgendaSurface == true)
    }

    @Test func agendaNeverInfersProactiveBriefWhenBackendWithholdsAuthority() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(
                taskApiService: NoopTaskApi(),
                modelContext: context
            )
        )
        let cached = DailyBrief(
            generatedAt: nil,
            counts: BriefCounts(
                blocked: 0, overdue: 0, scheduledToday: 0,
                completedToday: 0, total: 0, done: 0
            ),
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "You're all clear.",
            summary: "You're all clear."
        )
        let timestamp = Date().timeIntervalSince1970 * 1_000
        let history = try JSONSerialization.data(withJSONObject: [
            "sessionKey": "rem-orchestrator",
            "messages": [
                [
                    "role": "assistant",
                    "timestamp": timestamp,
                    "provider": "minimax",
                    "model": "minimax-m2.7",
                    "content": [["type": "text", "text": "Saturday brief with overdue work"]],
                ],
                [
                    "role": "assistant",
                    "timestamp": timestamp + 1,
                    "provider": "openclaw",
                    "model": "gateway-injected",
                    "content": [["type": "text", "text": "You're all clear."]],
                ],
            ],
        ])
        var requestedHistory = false
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { _ in
                requestedHistory = true
                return history
            },
            briefLoader: { cached }
        )

        await viewModel.loadBrief()

        #expect(!requestedHistory)
        #expect(viewModel.brief?.displayedBriefMarkdown == "You're all clear.")
        #expect(viewModel.brief?.displayedBriefSummary == "You're all clear.")
        #expect(viewModel.brief?.transcriptMarkdown == nil)
        #expect(viewModel.brief?.hasAgendaSurface == false)
    }

    @Test func missingBackendRouteStillFailsClosedWhenCacheDoesNotMatchDurableTranscript() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskEvent.self, configurations: config)
        let context = ModelContext(container)
        let taskApi = NoopTaskApi()
        let taskStore = TaskStore(
            taskSyncService: RemTaskSyncService(taskApiService: taskApi, modelContext: context)
        )
        let staleCachedReply = "Ordinary assistant reply cached by an older backend."
        let cached = DailyBrief(
            generatedAt: nil,
            counts: BriefCounts(
                blocked: 0, overdue: 0, scheduledToday: 0,
                completedToday: 0, total: 0, done: 0
            ),
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "You're all clear.",
            summary: "You're all clear.",
            transcriptMarkdown: staleCachedReply,
            transcriptSummary: staleCachedReply,
            briefSessionKey: nil
        )
        let delivered = "# Friday morning\n\nFour items need your call — one blocked and three overdue."
        let history = try JSONSerialization.data(withJSONObject: [
            "sessionKey": "rem-orchestrator",
            "messages": [[
                "role": "assistant",
                "timestamp": Date().timeIntervalSince1970 * 1_000,
                "content": [["type": "text", "text": delivered]],
            ]],
        ])
        var requestedKeys: [String] = []
        var clearedKeys: [String] = []
        let viewModel = AgendaViewModel(
            modelContext: context,
            taskStore: taskStore,
            briefHistoryProvider: { key in
                requestedKeys.append(key)
                return history
            },
            briefLoader: { cached },
            briefContextClearer: { clearedKeys.append($0) }
        )

        await viewModel.loadBrief()

        #expect(requestedKeys.isEmpty)
        #expect(viewModel.brief?.displayedBriefMarkdown == "You're all clear.")
        #expect(viewModel.brief?.displayedBriefSummary == "You're all clear.")
        #expect(viewModel.brief?.transcriptMarkdown == nil)
        #expect(viewModel.brief?.transcriptSummary == nil)
        #expect(viewModel.brief?.hasAgendaSurface == false)
        #expect(clearedKeys.isEmpty)

        let completed = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            localDayKey: "1-2026-8-7",
            sessionKey: "rem-orchestrator",
            briefMarkdown: staleCachedReply
        ))
        let agendaIdentity = try #require(DailyBriefPlaybackReceipt.identity(
            accountID: "account-a",
            localDayKey: "1-2026-8-7",
            sessionKey: viewModel.brief?.briefSessionKey,
            briefMarkdown: viewModel.brief?.displayedBriefMarkdown
        ))
        #expect(agendaIdentity != completed)
    }
}
