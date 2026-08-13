import Foundation
import OpenClawChatUI
import Testing
@testable import RemClaw

struct ChatLifecycleDisplayTests {
    @Test func liveLifecycleLabelsStayInProgressTense() {
        #expect(ActionLifecycleDisplay(sfSymbol: "brain", text: "Thinking").text == "Thinking")
        #expect(ActionLifecycleDisplay(sfSymbol: "checklist.checked", text: "Updating reminder").text == "Updating reminder")
        #expect(ActionLifecycleDisplay(sfSymbol: "square.and.pencil", text: "Updating agent instructions").text == "Updating agent instructions")
    }

    @Test func historicalLifecycleLabelsUsePastTense() {
        #expect(ActionLifecycleDisplay(sfSymbol: "brain", text: "Thinking", phase: .historical).text == "Thought")
        #expect(ActionLifecycleDisplay(sfSymbol: "checklist.checked", text: "Updating reminder", phase: .historical).text == "Updated reminder")
        #expect(ActionLifecycleDisplay(sfSymbol: "calendar.badge.plus", text: "Creating event", phase: .historical).text == "Created event")
        #expect(ActionLifecycleDisplay(sfSymbol: "person.badge.clock", text: "Checking pending devices", phase: .historical).text == "Checked pending devices")
    }

    @Test func updatingAgentInstructionsHasDeterministicHistoricalLabel() {
        let live = ActionLifecycleDisplay(
            sfSymbol: "square.and.pencil",
            text: "Updating agent instructions",
            historicalText: "Updated agent instructions"
        )

        #expect(live.text == "Updating agent instructions")
        #expect(live.withPhase(.historical).text == "Updated agent instructions")
    }

    @Test func updatingAgentInstructionsDisclosureTitlesFollowLifecyclePhase() {
        let live = ActionLifecycleDisplay(
            sfSymbol: "square.and.pencil",
            text: "Updating agent instructions",
            historicalText: "Updated agent instructions",
            phase: .live,
            presentation: .editingInstruction
        )
        let historical = live.withPhase(.historical)

        #expect(ActionLifecycleDisclosure.title(for: [live]) == "Updating agent instructions")
        #expect(ActionLifecycleDisclosure.title(for: [historical]) == "Updated agent instructions")
        #expect(ActionLifecycleDisclosure.title(for: [historical, live]) == "Updating agent instructions")
    }

    @Test func toolActivityDisclosureConsolidatesTheRunIntoOneCount() {
        let displays = [
            ActionLifecycleDisplay(sfSymbol: "calendar", text: "Checking calendar"),
            ActionLifecycleDisplay(sfSymbol: "checklist", text: "Updating reminder"),
            ActionLifecycleDisplay(sfSymbol: "globe", text: "Searching the web"),
        ]

        #expect(ActionLifecycleDisclosure.title(for: displays, kind: .toolActivity) == "Working")
        #expect(ActionLifecycleDisclosure.title(for: [displays[0]], kind: .toolActivity) == "Working")
    }

    @Test func runActivityExpansionAndHeaderChromeFollowLifecycle() {
        // Expansion follows the user, never the run phase — see
        // `workingDisclosureStaysCollapsedUntilTappedAndKeepsManualExpansion` for the #1278 detail.
        #expect(!ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: false,
            kind: .runActivity,
            isRunActive: true
        ))
        #expect(!ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: false,
            kind: .runActivity,
            isRunActive: false
        ))
        #expect(ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: true,
            kind: .runActivity,
            isRunActive: false
        ))
        #expect(!ActionLifecycleDisclosure.showsLeadingHeaderIcon(for: .toolActivity))
        #expect(!ActionLifecycleDisclosure.showsLeadingHeaderIcon(for: .runActivity))
        #expect(ActionLifecycleDisclosure.showsLeadingHeaderIcon(for: .agentInstructions))
        #expect(ActionLifecycleDisclosure.accessibilityStateLabel(isExpanded: true) == "Expanded")
        #expect(ActionLifecycleDisclosure.accessibilityStateLabel(isExpanded: false) == "Collapsed")
        #expect(ActionLifecycleDisclosure.occurrenceLabel(for: 1) == nil)
        #expect(ActionLifecycleDisclosure.occurrenceLabel(for: 3) == "×3")
        #expect(SharedRemChatView.activityDisclosureKind(isActive: true) == .toolActivity)
        #expect(SharedRemChatView.activityDisclosureKind(isActive: false) == .runActivity)
        #expect(ActionLifecycleDisclosure.expandedTimelineMaxHeight == 240)
    }

    /// #1278: the in-progress "Working" disclosure auto-expanded its chevron while a turn was
    /// running, so a running turn showed an expanded section the user never opened and every new
    /// step shifted the reply the user was trying to read.
    @Test func workingDisclosureStaysCollapsedUntilTappedAndKeepsManualExpansion() {
        let liveSection = SharedRemChatView.liveRunActivitySectionID

        // 1. Collapsed by default while the turn runs — for the live kind and for the consolidated
        //    kind, so neither phase of a turn opens itself.
        for kind in [ActionLifecycleDisclosure.Kind.toolActivity, .runActivity] {
            #expect(!ActionLifecycleDisclosure.resolvesExpanded(
                userExpanded: false,
                kind: kind,
                isRunActive: true
            ))
        }
        // Same default the completed Activity disclosure already had.
        #expect(!ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: false,
            kind: .runActivity,
            isRunActive: false
        ))
        #expect(ActionLifecycleDisclosure.accessibilityStateLabel(isExpanded: false) == "Collapsed")

        // 2. The user can still open it by hand mid-run.
        #expect(ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: true,
            kind: .toolActivity,
            isRunActive: true
        ))

        // 3. That manual expansion survives subsequent streaming updates. Each tick reconciles the
        //    same still-active run, and none of them may rewrite the section.
        var sections: Set<String> = [liveSection]
        for _ in 0..<5 {
            sections = SharedRemChatView.reconcileLiveRunActivityExpansion(
                expandedSections: sections,
                previousEffectiveRunCount: 1,
                currentEffectiveRunCount: 1
            )
        }
        #expect(sections.contains(liveSection))
        #expect(ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: sections.contains(liveSection),
            kind: .toolActivity,
            isRunActive: true
        ))

        // 4. The run ending does not collapse it out from under the reader either.
        sections = SharedRemChatView.reconcileLiveRunActivityExpansion(
            expandedSections: sections,
            previousEffectiveRunCount: 1,
            currentEffectiveRunCount: 0
        )
        #expect(sections.contains(liveSection))

        // 5. The next turn starts collapsed again: the live section id is reused across runs, so a
        //    0 -> 1 boundary clears it instead of inheriting the previous turn's expansion.
        let nextRun = SharedRemChatView.reconcileLiveRunActivityExpansion(
            expandedSections: sections,
            previousEffectiveRunCount: 0,
            currentEffectiveRunCount: 1
        )
        #expect(!nextRun.contains(liveSection))
        #expect(!ActionLifecycleDisclosure.resolvesExpanded(
            userExpanded: nextRun.contains(liveSection),
            kind: .toolActivity,
            isRunActive: true
        ))

        // 6. Completed turns keep their own expansion — the live reset touches only the live id.
        let completedSection = "message-42-run-activity"
        #expect(SharedRemChatView.reconcileLiveRunActivityExpansion(
            expandedSections: [liveSection, completedSection],
            previousEffectiveRunCount: 0,
            currentEffectiveRunCount: 1
        ) == [completedSection])

        // 7. Wording contract is untouched: "Thought" for reasoning, "Worked" for tool activity,
        //    "Working" only while the run is live.
        let thought = ActionLifecycleDisplay(sfSymbol: "brain", text: "Thinking", phase: .historical)
        let tool = ActionLifecycleDisplay(sfSymbol: "calendar", text: "Checking calendar", phase: .historical)
        #expect(ActionLifecycleDisclosure.title(
            for: [thought], kind: .runActivity, elapsedSeconds: 3) == "Thought for 3s")
        #expect(ActionLifecycleDisclosure.title(
            for: [thought, tool], kind: .runActivity, elapsedSeconds: 3) == "Worked for 3s")
        #expect(ActionLifecycleDisclosure.title(for: [tool], kind: .toolActivity) == "Working")
    }

    @Test func combinedReasoningAndFinalTextBothRemainVisible() {
        let content = OpenClawChatMessageContent(
            type: "text",
            text: "Here is the final answer.",
            thinking: "I should verify the result first.",
            mimeType: nil,
            fileName: nil,
            content: nil
        )

        let projection = SharedRemChatView.splitContent([content], isUser: false)

        #expect(projection.thinking == ["I should verify the result first."])
        #expect(projection.textBlocks == ["Here is the final answer."])
    }

    @Test func mirroredThinkingTextKeepsAuthoritativeFinalProseAndDedupesActivity() {
        let content = OpenClawChatMessageContent(
            type: "text",
            text: "Checking the result",
            thinking: "Checking the result",
            mimeType: nil,
            fileName: nil,
            content: nil
        )

        let projection = SharedRemChatView.splitContent([content], isUser: false)

        #expect(projection.thinking.isEmpty)
        #expect(projection.textBlocks == ["Checking the result"])
    }

    @Test func exactTerminalRetainsCollapsedRowsUntilMatchingHistoryOwnsThem() {
        var accumulator = RunActivityAccumulator()
        let calendar = RunActivityAccumulator.Observation(
            id: "calendar-1",
            display: ActionLifecycleDisplay(sfSymbol: "calendar", text: "Checking calendar")
        )
        let gmail = RunActivityAccumulator.Observation(
            id: "gmail-1",
            display: ActionLifecycleDisplay(sfSymbol: "envelope", text: "Checking Gmail")
        )

        accumulator.begin(sessionKey: "session-a")
        accumulator.observePending([calendar, gmail])
        #expect(accumulator.displays.map(\.text) == ["Checking calendar", "Checking Gmail"])

        // The tool `result` event removes calendar from pendingToolCalls. Its step
        // must remain in the current run instead of disappearing before history.
        accumulator.observePending([gmail])
        #expect(accumulator.displays.map(\.text) == ["Checked calendar", "Checking Gmail"])

        accumulator.observePending([])
        #expect(accumulator.displays.map(\.text) == ["Checked calendar", "Checked Gmail"])
        accumulator.finish()
        #expect(!accumulator.isActive)
        #expect(accumulator.isAwaitingAuthoritativeHistory)
        #expect(accumulator.displays.map(\.text) == ["Checked calendar", "Checked Gmail"])

        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "session-a",
            observations: [],
            historyOwnershipCounts: ["calendar|Checked calendar": 1]
        ))
        #expect(accumulator.isAwaitingAuthoritativeHistory)

        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "session-a",
            observations: [],
            historyOwnershipCounts: [
                "calendar|Checked calendar": 1,
                "envelope|Checked Gmail": 1,
            ]
        ))
        #expect(!accumulator.isAwaitingAuthoritativeHistory)
        #expect(accumulator.displays.isEmpty)
    }

    @Test func priorIdenticalHistoryCannotPrematurelyOwnTerminalRows() {
        var accumulator = RunActivityAccumulator()
        let calendar = RunActivityAccumulator.Observation(
            id: "calendar-current",
            display: ActionLifecycleDisplay(sfSymbol: "calendar", text: "Checking calendar")
        )

        accumulator.reconcile(.init(
            runCount: 1,
            sessionKey: "session-a",
            observations: [calendar],
            historyOwnershipCounts: ["calendar|Checked calendar": 1]
        ))
        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "session-a",
            observations: [],
            historyOwnershipCounts: ["calendar|Checked calendar": 1]
        ))

        #expect(accumulator.isAwaitingAuthoritativeHistory)
        #expect(accumulator.displays.map(\.text) == ["Checked calendar"])

        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "session-a",
            observations: [],
            historyOwnershipCounts: ["calendar|Checked calendar": 2]
        ))
        #expect(accumulator.displays.isEmpty)
    }

    @Test func browserCardTransitionReconcilesIdentityAndEvictsRetainedBrowserStep() {
        let browserActivity = BrowserToolActivity(
            sessionKey: "session-a",
            runID: "run-a",
            toolCallID: "browser-call-from-evidence",
            toolName: "browser",
            action: "navigate"
        )
        var browserEvidence = BrowserRunEvidence()
        browserEvidence.record(browserActivity)
        let before = SharedRemChatView.runActivityReconciliationIdentity(
            effectiveRunCount: 1,
            pendingToolCallIDs: [browserActivity.toolCallID, "gmail-1"],
            browserCardPresentation: .none,
            streamingThinkingSummaries: ["Checking connected accounts"]
        )
        let after = SharedRemChatView.runActivityReconciliationIdentity(
            effectiveRunCount: 1,
            pendingToolCallIDs: [browserActivity.toolCallID, "gmail-1"],
            browserCardPresentation: .live,
            streamingThinkingSummaries: ["Checking connected accounts"]
        )
        #expect(before != after)

        let summary = RunActivityAccumulator.Observation(
            id: "streaming-thinking-0",
            display: .init(sfSymbol: "lightbulb", text: "Checking connected accounts")
        )
        let browser = RunActivityAccumulator.Observation(
            id: browserActivity.toolCallID,
            display: .init(sfSymbol: "globe", text: "Using browser")
        )
        let gmail = RunActivityAccumulator.Observation(
            id: "gmail-1",
            display: .init(sfSymbol: "envelope", text: "Checking Gmail")
        )
        var accumulator = RunActivityAccumulator()
        accumulator.reconcile(.init(
            runCount: 1,
            sessionKey: "session-a",
            observations: [summary, browser, gmail]
        ))
        #expect(accumulator.displays.map(\.liveText) == [
            "Checking connected accounts", "Using browser", "Checking Gmail",
        ])

        accumulator.reconcile(.init(
            runCount: 1,
            sessionKey: "session-a",
            observations: [summary, browser, gmail],
            // The result already removed the browser from pendingToolCalls; the
            // durable gateway evidence is the only remaining source for its ID.
            suppressedObservationIDs: SharedRemChatView.suppressedRunActivityIDs(
                pendingBrowserToolCallIDs: [],
                activeBrowserRunEvidences: [browserEvidence],
                cardPresentation: .live
            )
        ))
        #expect(accumulator.displays.map(\.liveText) == [
            "Checking connected accounts", "Checking Gmail",
        ])
    }

    @MainActor
    @Test func exactTerminalClosesOnlyItsOwnConcurrentRun() {
        let store = RunLifecycleEvidenceStore()
        let runA = RunLifecycleEvidence.Run(sessionKey: "voice-session", runID: "run-a")
        let runB = RunLifecycleEvidence.Run(sessionKey: "voice-session", runID: "run-b")
        store.record(.init(run: runA, phase: .active))
        store.record(.init(run: runB, phase: .active))

        #expect(store.activeRunIDs(for: "voice-session") == ["run-a", "run-b"])

        store.record(.init(run: runA, phase: .terminal(.final)))
        #expect(store.activeRunIDs(for: "voice-session") == ["run-b"])

        // A duplicate or out-of-order terminal for A cannot collapse B.
        store.record(.init(run: runA, phase: .terminal(.error)))
        #expect(store.activeRunIDs(for: "voice-session") == ["run-b"])

        store.record(.init(run: runB, phase: .terminal(.aborted)))
        #expect(store.activeRunIDs(for: "voice-session").isEmpty)
    }

    @MainActor
    @Test func terminalRemovesExactLocalRegistration() {
        let store = RunLifecycleEvidenceStore()
        let run = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "local-run")
        store.record(.init(run: run, phase: .localRegistered))
        #expect(store.localRunIDs(for: "chat-a") == ["local-run"])

        store.record(.init(run: run, phase: .terminal(.final)))
        #expect(store.localRunIDs(for: "chat-a").isEmpty)
        store.record(.init(run: run, phase: .localRegistered))
        #expect(store.localRunIDs(for: "chat-a").isEmpty)
    }

    @MainActor
    @Test func terminalFromAnotherSessionCannotCollapseActiveRun() {
        let store = RunLifecycleEvidenceStore()
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "shared-id"),
            phase: .active
        ))
        store.record(.init(
            run: .init(sessionKey: "chat-b", runID: "shared-id"),
            phase: .terminal(.final)
        ))

        #expect(store.activeRunIDs(for: "chat-a") == ["shared-id"])
        #expect(store.activeRunIDs(for: "chat-b").isEmpty)
    }

    @MainActor
    @Test func outOfOrderActivityCannotResurrectTerminalRun() {
        let store = RunLifecycleEvidenceStore()
        let run = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "run-a")
        store.record(.init(run: run, phase: .terminal(.final)))
        store.record(.init(run: run, phase: .active))

        #expect(store.activeRunIDs(for: "chat-a").isEmpty)
    }

    @MainActor
    @Test func sessionSwitchCannotDiscardTerminalProtectionForDelayedActivity() {
        let store = RunLifecycleEvidenceStore()
        let runA = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "run-a")
        store.record(.init(run: runA, phase: .terminal(.final)))

        store.retainOnly(sessionKey: "chat-b")
        store.record(.init(run: runA, phase: .active))
        store.retainOnly(sessionKey: "chat-a")

        #expect(store.activeRunIDs(for: "chat-a").isEmpty)
    }

    @MainActor
    @Test func moreThan256RecentTerminalsCannotAdmitStaleActivity() {
        let store = RunLifecycleEvidenceStore(terminalCapacity: 512)
        let oldest = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "run-0")
        for index in 0..<300 {
            store.record(.init(
                run: .init(sessionKey: "chat-a", runID: "run-\(index)"),
                phase: .terminal(.final)
            ))
        }

        store.record(.init(run: oldest, phase: .active))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)

        let unrelated = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "new-run")
        store.record(.init(run: unrelated, phase: .active))
        #expect(store.activeRunIDs(for: "chat-a") == ["new-run"])
    }

    @MainActor
    @Test func connectionEpochChangeClearsExactTerminalTombstones() {
        let source = RunLifecycleEpochSource()
        let store = RunLifecycleEvidenceStore(epochSource: source)
        let firstEpoch = store.beginConnectionEpoch()
        let run = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "reused-run-id")

        store.record(.init(run: run, phase: .terminal(.final), connectionEpoch: firstEpoch))
        store.record(.init(run: run, phase: .active, connectionEpoch: firstEpoch))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)

        let nextEpoch = store.beginConnectionEpoch()
        store.record(.init(run: run, phase: .active, connectionEpoch: nextEpoch))
        #expect(store.activeRunIDs(for: "chat-a") == ["reused-run-id"])

        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "stale-old-epoch"),
            phase: .active,
            connectionEpoch: firstEpoch
        ))
        #expect(store.activeRunIDs(for: "chat-a") == ["reused-run-id"])
    }

    @MainActor
    @Test func persistentEpochSourceRejectsRecreatedTransportCollisionsAndDelayedOldEvidence() {
        let persistentSource = RunLifecycleEpochSource()
        let store = RunLifecycleEvidenceStore(epochSource: persistentSource)
        let oldTransport = store.beginTransportEpoch()
        guard let oldTransportReconnect = persistentSource.issueSubscription(
            for: oldTransport.transportID
        ) else {
            Issue.record("Current transport must be able to rotate its subscription epoch")
            return
        }
        store.setCurrentConnectionEpoch(oldTransportReconnect)

        let replacement = store.beginTransportEpoch()
        let recreatedLocalSourceCollision = RunLifecycleEpochSource()
            .beginTransport().epoch
        store.setCurrentConnectionEpoch(recreatedLocalSourceCollision)
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "collision"),
            phase: .active,
            connectionEpoch: recreatedLocalSourceCollision
        ))
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "delayed-old"),
            phase: .active,
            connectionEpoch: oldTransportReconnect
        ))
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "current"),
            phase: .active,
            connectionEpoch: replacement.epoch
        ))

        #expect(oldTransport.epoch.generation == 1)
        #expect(recreatedLocalSourceCollision.generation == 1)
        #expect(persistentSource.issueSubscription(for: oldTransport.transportID) == nil)
        #expect(store.activeRunIDs(for: "chat-a") == ["current"])
    }

    @MainActor
    @Test func transportSetupGateRejectsInvertedCompletionAndTeardownWhileAwaiting() {
        let gate = ChatTransportSetupGate()
        var installed: [String] = []
        let a = gate.begin(bindingKey: "gateway-a|chat-a")
        let b = gate.begin(bindingKey: "gateway-b|chat-b")

        #expect(!gate.commit(
            a,
            currentBindingKey: "gateway-b|chat-b",
            isReady: true
        ) { installed.append("A") })
        #expect(gate.commit(
            b,
            currentBindingKey: "gateway-b|chat-b",
            isReady: true
        ) { installed.append("B") })
        #expect(installed == ["B"])

        let teardown = gate.begin(bindingKey: "gateway-c|chat-c")
        gate.invalidate()
        #expect(!gate.commit(
            teardown,
            currentBindingKey: "gateway-c|chat-c",
            isReady: true
        ) { installed.append("C") })
        #expect(installed == ["B"])
    }

    @MainActor
    @Test func terminalTombstoneExpiresExactlyAtDelayedEventTTLBoundary() {
        var currentTime: TimeInterval = 1_000
        let store = RunLifecycleEvidenceStore(
            terminalTTL: 120,
            now: { currentTime }
        )
        let epoch = store.beginConnectionEpoch()
        let run = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "delayed-run")
        store.record(.init(run: run, phase: .terminal(.final), connectionEpoch: epoch))

        currentTime = 1_119
        store.record(.init(run: run, phase: .active, connectionEpoch: epoch))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)

        currentTime = 1_120
        store.record(.init(run: run, phase: .active, connectionEpoch: epoch))
        #expect(store.activeRunIDs(for: "chat-a") == ["delayed-run"])
    }

    @MainActor
    @Test func capacityOverflowFailsClosedUntilTTLOrNewEpoch() {
        var currentTime: TimeInterval = 2_000
        let store = RunLifecycleEvidenceStore(
            terminalCapacity: 512,
            terminalTTL: 120,
            now: { currentTime }
        )
        let epoch = store.beginConnectionEpoch()
        let oldest = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "run-0")
        for index in 0..<513 {
            store.record(.init(
                run: .init(sessionKey: "chat-a", runID: "run-\(index)"),
                phase: .terminal(.final),
                connectionEpoch: epoch
            ))
        }

        store.record(.init(run: oldest, phase: .active, connectionEpoch: epoch))
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "new-during-overflow"),
            phase: .active,
            connectionEpoch: epoch
        ))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)

        currentTime = 2_060
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "terminal-during-overflow-1"),
            phase: .terminal(.final),
            connectionEpoch: epoch
        ))
        currentTime = 2_119
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "terminal-during-overflow-2"),
            phase: .terminal(.final),
            connectionEpoch: epoch
        ))

        currentTime = 2_120
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "new-after-ttl"),
            phase: .active,
            connectionEpoch: epoch
        ))
        #expect(store.activeRunIDs(for: "chat-a") == ["new-after-ttl"])

        let nextEpoch = store.beginConnectionEpoch()
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "new-next-epoch"),
            phase: .active,
            connectionEpoch: nextEpoch
        ))
        #expect(store.activeRunIDs(for: "chat-a") == ["new-next-epoch"])
    }

    @MainActor
    @Test func duplicateTerminalRefreshesOneBoundedOrderEntry() {
        var currentTime: TimeInterval = 4_000
        let store = RunLifecycleEvidenceStore(terminalTTL: 120, now: { currentTime })
        let epoch = store.beginConnectionEpoch()
        let run = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "same-run")
        store.record(.init(run: run, phase: .terminal(.final), connectionEpoch: epoch))

        currentTime = 4_100
        for _ in 0..<1_000 {
            store.record(.init(run: run, phase: .terminal(.final), connectionEpoch: epoch))
        }
        #expect(store.terminalTombstoneCount == 1)

        currentTime = 4_219
        store.record(.init(run: run, phase: .active, connectionEpoch: epoch))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)

        currentTime = 4_220
        store.record(.init(run: run, phase: .active, connectionEpoch: epoch))
        #expect(store.activeRunIDs(for: "chat-a") == ["same-run"])
    }

    @MainActor
    @Test func sessionSwitchIsOnlyFallbackCleanupForMissingTerminalIdentity() {
        let store = RunLifecycleEvidenceStore()
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "run-without-terminal"),
            phase: .active
        ))

        // No timer, transcript, or render pass infers completion.
        #expect(store.activeRunIDs(for: "chat-a") == ["run-without-terminal"])
        store.retainOnly(sessionKey: "chat-b")
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)
    }

    @Test func accumulatorUsesExactTransportRunSetInsteadOfTranscriptShape() {
        var accumulator = RunActivityAccumulator()
        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "voice-session",
            observations: [.init(
                id: "voice-tool-1",
                display: .init(sfSymbol: "calendar", text: "Checking calendar")
            )],
            activeTransportRunIDs: ["voice-run"]
        ))
        #expect(accumulator.isActive)
        #expect(accumulator.displays.map(\.text) == ["Checking calendar"])

        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "voice-session",
            observations: [],
            activeTransportRunIDs: [],
            historyOwnershipCounts: ["calendar|Checked calendar": 1]
        ))
        #expect(!accumulator.isActive)
        #expect(accumulator.displays.isEmpty)
    }

    @Test func exactLocalRegistrationCorrelatesWithoutDoubleCounting() {
        let input = RunActivityAccumulator.Input(
            runCount: 1,
            sessionKey: "chat-a",
            observations: [],
            activeTransportRunIDs: ["local-run"],
            localRegisteredRunIDs: ["local-run"]
        )
        #expect(!input.hasAmbiguousMixedOwnership)
        #expect(input.effectiveRunCount == 1)
    }

    @Test func unmatchedMixedLocalAndExternalRunsFailClosed() {
        let input = RunActivityAccumulator.Input(
            runCount: 1,
            sessionKey: "chat-a",
            observations: [],
            activeTransportRunIDs: ["external-run"],
            localRegisteredRunIDs: ["local-run"]
        )
        #expect(input.hasAmbiguousMixedOwnership)
        #expect(input.effectiveRunCount > 1)

        var accumulator = RunActivityAccumulator()
        accumulator.reconcile(input)
        #expect(accumulator.isSuppressedForOverlap)
        #expect(accumulator.displays.isEmpty)
    }

    @Test func emittedThinkingSummaryUsesOneSanitizedDisplayIdentity() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let raw = #"Checking node 550e8400-e29b-41d4-a716-446655440000 · {"nodeId":"private-node","status":"ok"}"#
        let display = SharedRemChatView.streamingThinkingActivityDisplay(from: raw)
        let observations = SharedRemChatView.streamingThinkingActivityObservations(
            from: "<think>\(raw)</think>"
        )

        #expect(display != nil)
        #expect(observations.count == 1)
        #expect(observations.first?.display.liveText == display?.liveText)
        #expect(display?.liveText.contains(uuid) == false)
        #expect(display?.liveText.contains("nodeId") == false)
        #expect(display?.liveText.contains("[redacted]") == true)
        #expect(display?.liveText.contains("details hidden") == true)
    }

    @Test func newRunAccumulatorDoesNotLeakPriorSessionSteps() {
        var accumulator = RunActivityAccumulator()
        accumulator.begin(sessionKey: "session-a")
        accumulator.observePending([.init(
            id: "old",
            display: ActionLifecycleDisplay(sfSymbol: "calendar", text: "Checking calendar")
        )])
        accumulator.finish()

        accumulator.begin(sessionKey: "session-b")
        #expect(accumulator.sessionKey == "session-b")
        #expect(accumulator.displays.isEmpty)
        #expect(accumulator.isActive)
        #expect(!accumulator.isAwaitingAuthoritativeHistory)
    }

    @Test func overlappingRunsFailClosedInsteadOfMergingToolSteps() {
        var accumulator = RunActivityAccumulator()
        let first = RunActivityAccumulator.Observation(
            id: "first-tool",
            display: ActionLifecycleDisplay(sfSymbol: "calendar", text: "Checking calendar")
        )
        let second = RunActivityAccumulator.Observation(
            id: "second-tool",
            display: ActionLifecycleDisplay(sfSymbol: "envelope", text: "Checking Gmail")
        )

        accumulator.observeRunCount(1, sessionKey: "session-a")
        accumulator.observePending([first])
        #expect(accumulator.displays.map(\.text) == ["Checking calendar"])

        accumulator.observeRunCount(2, sessionKey: "session-a")
        accumulator.observePending([first, second])
        #expect(accumulator.isSuppressedForOverlap)
        #expect(accumulator.displays.isEmpty)

        // With no public run identity, 2 -> 1 is still ambiguous. Do not
        // repopulate from whichever session-wide tool calls happen to remain.
        accumulator.observeRunCount(1, sessionKey: "session-a")
        accumulator.observePending([second])
        #expect(accumulator.isSuppressedForOverlap)
        #expect(accumulator.displays.isEmpty)

        accumulator.observeRunCount(0, sessionKey: "session-a")
        #expect(!accumulator.isActive)
        #expect(!accumulator.isSuppressedForOverlap)

        accumulator.observeRunCount(1, sessionKey: "session-a")
        accumulator.observePending([second])
        #expect(accumulator.displays.map(\.text) == ["Checking Gmail"])
    }

    @Test func completedRunUsesOneActivityTitle() {
        let displays = [
            ActionLifecycleDisplay(sfSymbol: "lightbulb", text: "Checked the page", phase: .historical),
            ActionLifecycleDisplay(sfSymbol: "globe", text: "Opened browser", phase: .historical),
            ActionLifecycleDisplay(sfSymbol: "checkmark.circle", text: "Tool result", phase: .historical),
        ]

        #expect(
            ActionLifecycleDisclosure.title(
                for: displays,
                kind: .runActivity,
                elapsedSeconds: 3
            ) == "Worked for 3s"
        )
    }

    @Test func completedThinkingOnlyRunUsesThoughtTitleAndUntimedWorkUsesActivity() {
        let thought = ActionLifecycleDisplay(
            sfSymbol: "lightbulb",
            text: "Checked the plan",
            phase: .historical
        )
        let tool = ActionLifecycleDisplay(
            sfSymbol: "calendar",
            text: "Checked calendar",
            phase: .historical
        )

        #expect(ActionLifecycleDisclosure.title(
            for: [thought], kind: .runActivity, elapsedSeconds: 4) == "Thought for 4s")
        #expect(ActionLifecycleDisclosure.title(
            for: [thought], kind: .runActivity, elapsedSeconds: nil) == "Thought")
        #expect(ActionLifecycleDisclosure.title(
            for: [tool], kind: .runActivity, elapsedSeconds: nil) == "Activity")
    }

    @Test func completedRunFormatsLongDurationsAsHumanTime() {
        let thought = ActionLifecycleDisplay(
            sfSymbol: "lightbulb",
            text: "Checked the plan",
            phase: .historical
        )

        #expect(ActionLifecycleDisclosure.title(
            for: [thought], kind: .runActivity, elapsedSeconds: 75) == "Thought for 1m 15s")
        #expect(ActionLifecycleDisclosure.title(
            for: [thought], kind: .runActivity, elapsedSeconds: 37_507) == "Thought for 10h 25m")
    }

    @Test func knownToolResultsFoldIntoTimelineInsteadOfStandaloneCards() throws {
        let raw = #"{"eventId":"event-1","title":"Dinner"}"#
        let parsed = ToolResultParser.parse(raw)
        let display = try #require(SharedRemChatView.foldedKnownToolResultDisplay(parsed, text: raw))
        let message = OpenClawChatMessage(
            role: "toolResult",
            content: [OpenClawChatMessageContent(
                type: "toolResult",
                text: raw,
                mimeType: nil,
                fileName: nil,
                content: nil
            )],
            timestamp: nil
        )

        #expect(display.text == "Created event")
        #expect(display.detailText == raw)
        #expect(!SharedRemChatView.toolResultNeedsStandalonePresentation(message))
    }

    @Test func mixedToolResultPresentsOnlyUnmatchedContentOutsideTimeline() {
        let known = #"{"eventId":"event-1","title":"Dinner"}"#
        let opaque = #"{"payload":{"secret":"private"}}"#
        let message = OpenClawChatMessage(
            role: "toolResult",
            content: [known, opaque].map {
                OpenClawChatMessageContent(
                    type: "toolResult", text: $0, mimeType: nil,
                    fileName: nil, content: nil)
            },
            timestamp: nil
        )

        #expect(SharedRemChatView.standaloneToolResultContentIndexes(message) == Set([1]))
    }

    @Test func foldedKnownErrorUsesPrivacyProjectedDetail() throws {
        let raw = #"{"status":"error","error":"command=exec token=secret-token nodeId=private-node"}"#
        let parsed = ToolResultParser.parse(raw)
        let display = try #require(SharedRemChatView.foldedKnownToolResultDisplay(parsed, text: raw))

        #expect(display.text == "Tool failed")
        #expect(display.detailText == "The action couldn't be completed.")
        #expect(!display.detailText!.contains("secret-token"))
    }

    @Test func completedRunDurationUsesPersistedMillisecondTimestamps() {
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(from: 1_000, through: 4_200) == 3)
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(from: 1_000, through: 1_100) == 1)
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(
            from: 1_700_000_000,
            through: 1_700_000_003) == 3)
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(
            from: 1_700_000_000,
            through: 1_700_000_003_000) == 3)
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(
            from: 1_700_000_000_000_000,
            through: 1_700_000_003_000_000) == 3)
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(
            from: 1_700_000_000_000_000_000,
            through: 1_700_000_003_000_000_000) == 3)
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(from: nil, through: 4_200) == nil)
        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(from: 4_200, through: 1_000) == nil)
    }

    @Test func historicalRunStartsAtFirstActivityInsteadOfDelayedUserMessage() {
        let firstActivity = SharedRemChatView.historicalActivityStartTimestamp(
            current: nil,
            messageTimestamp: 37_500_000,
            carriesActivity: true)
        #expect(firstActivity == 37_500_000)
        #expect(SharedRemChatView.historicalActivityStartTimestamp(
            current: firstActivity,
            messageTimestamp: 37_505_000,
            carriesActivity: true) == firstActivity)
        #expect(SharedRemChatView.historicalActivityStartTimestamp(
            current: nil,
            messageTimestamp: 1_000,
            carriesActivity: false) == nil)

        #expect(ActionLifecycleDisclosure.resolvedElapsedSeconds(
            from: firstActivity,
            through: 37_503_000) == 3)
    }

    @Test func completedRunDurationRequiresTerminalAssistantContentAndTimestamp() {
        let toolCall = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil,
                name: "calendar", arguments: nil
            )],
            timestamp: 2_000,
            stopReason: "tool_use"
        )
        let missingTimestamp = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "Done", mimeType: nil, fileName: nil, content: nil
            )],
            timestamp: nil
        )
        let terminal = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: "Done", mimeType: nil, fileName: nil, content: nil
            )],
            timestamp: 4_200
        )
        let preToolSentence = OpenClawChatMessage(
            role: "assistant",
            content: [
                OpenClawChatMessageContent(
                    type: "text", text: "I'll check that now.", mimeType: nil,
                    fileName: nil, content: nil
                ),
                OpenClawChatMessageContent(
                    type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil,
                    name: "calendar", arguments: nil
                ),
            ],
            timestamp: 2_500,
            stopReason: "tool_use"
        )

        #expect(SharedRemChatView.terminalAssistantTimestamp(toolCall) == nil)
        #expect(SharedRemChatView.terminalAssistantTimestamp(missingTimestamp) == nil)
        #expect(SharedRemChatView.terminalAssistantTimestamp(terminal) == 4_200)
        #expect(SharedRemChatView.terminalAssistantTimestamp(preToolSentence) == nil)
        #expect(SharedRemChatView.assistantTurnCompleted(terminal))

        let intermediateDuration = SharedRemChatView.updatedCompletedRunElapsedSeconds(
            current: nil,
            turnStartedAt: 1_000,
            message: terminal,
            carriesActivity: false
        )
        #expect(intermediateDuration == 3)
        #expect(SharedRemChatView.updatedCompletedRunElapsedSeconds(
            current: intermediateDuration,
            turnStartedAt: 1_000,
            message: toolCall,
            carriesActivity: true
        ) == nil)
        #expect(SharedRemChatView.updatedCompletedRunElapsedSeconds(
            current: nil,
            turnStartedAt: 1_000,
            message: preToolSentence,
            carriesActivity: true
        ) == nil)
        #expect(SharedRemChatView.updatedCompletedRunElapsedSeconds(
            current: nil,
            turnStartedAt: 1_000,
            message: missingTimestamp,
            carriesActivity: false
        ) == nil)
    }

    @Test func completedRunDeduplicatesActivityAcrossPersistedMessages() {
        let repeatedThought = ActionLifecycleDisplay(
            sfSymbol: "lightbulb",
            text: "Checking the page",
            phase: .historical
        )
        let displays = SharedRemChatView.consolidatedHistoricalActivityDisplays([
            repeatedThought,
            repeatedThought,
            ActionLifecycleDisplay(sfSymbol: "globe", text: "Opened browser", phase: .historical),
        ])

        #expect(displays.count == 2)
        #expect(displays[0].occurrenceCount == 2)
        #expect(
            ActionLifecycleDisclosure.title(
                for: displays,
                kind: .runActivity,
                elapsedSeconds: 3
            ) == "Worked for 3s"
        )
    }

    @Test func liveActivityScrollFollowsOnlyTheInactiveToActiveTransition() {
        #expect(SharedRemChatView.shouldScrollToLiveActivity(
            previousEffectiveRunCount: 0,
            currentEffectiveRunCount: 1
        ))
        #expect(!SharedRemChatView.shouldScrollToLiveActivity(
            previousEffectiveRunCount: 1,
            currentEffectiveRunCount: 1
        ))
        #expect(!SharedRemChatView.shouldScrollToLiveActivity(
            previousEffectiveRunCount: 1,
            currentEffectiveRunCount: 2
        ))
        #expect(!SharedRemChatView.shouldScrollToLiveActivity(
            previousEffectiveRunCount: 1,
            currentEffectiveRunCount: 0
        ))
    }

    @Test func unknownRichResultsStayVisibleWhileBrowserDiagnosticsFold() {
        let qr = "![whatsapp-qr](data:image/png;base64,AAAA)"
        let browserScreenshot = "![browser-screenshot](https://example.com/screenshot.png)"
        let fileRead = "# Skill instructions\nUseful content"

        #expect(!SharedRemChatView.shouldFoldUnknownToolResult(toolName: "whatsapp_login", text: qr))
        #expect(!SharedRemChatView.shouldFoldUnknownToolResult(toolName: "browser", text: browserScreenshot))
        #expect(!SharedRemChatView.shouldFoldUnknownToolResult(toolName: "canvas", text: browserScreenshot))
        #expect(SharedRemChatView.shouldFoldUnknownToolResult(toolName: "read", text: fileRead))
        #expect(!SharedRemChatView.shouldFoldUnknownToolResult(toolName: "browser", text: #"{"ok":true}"#))
        #expect(!SharedRemChatView.shouldFoldUnknownToolResult(
            toolName: "nodes",
            text: "No connected browser-capable nodes."
        ))

        let mixedMessage = OpenClawChatMessage(
            role: "toolResult",
            content: [
                OpenClawChatMessageContent(
                    type: "toolResult",
                    text: "No connected browser-capable nodes.",
                    mimeType: nil,
                    fileName: nil,
                    content: nil,
                    name: "nodes"
                ),
                OpenClawChatMessageContent(
                    type: "toolResult",
                    text: qr,
                    mimeType: nil,
                    fileName: nil,
                    content: nil,
                    name: "whatsapp_login"
                ),
                OpenClawChatMessageContent(
                    type: "toolResult",
                    text: browserScreenshot,
                    mimeType: nil,
                    fileName: nil,
                    content: nil,
                    name: "browser"
                ),
            ],
            timestamp: nil
        )

        #expect(SharedRemChatView.foldedUnknownToolResultIndexes(for: mixedMessage).isEmpty)

        let foldedDisplay = SharedRemChatView.foldedUnknownToolResultDisplay(
            toolName: "read",
            text: fileRead
        )
        #expect(foldedDisplay?.text == "Tool result")
        #expect(foldedDisplay?.detailText == fileRead)
    }

    @Test func topLevelUnknownToolResultDetailIsSanitizedBeforeFolding() {
        let metadataWrapped = """
        Sender (untrusted metadata):
        ```json
        { "label": "iPhone 17", "runtimeId": "private-runtime-id" }
        ```
        Created the calendar event.
        """
        let diagnosticOnly = """
        agent=main node=private-node-id gateway=default action=invoke: pairing required before node invoke. Approve the pending pairing request and retry.
        """
        let image = "![browser-screenshot](https://example.com/screenshot.png)"
        let unsafeUnknownJSON = #"{"ok":true,"nodeId":"private-node","command":"exec","payload":{"token":"secret"}}"#
        let unsafeArray = #"[{"nodeId":"private-node","command":"exec"}]"#
        let fencedJSON = """
        ```json
        {"payload":{"token":"secret"}}
        ```
        """
        let proseAndFencedArray = """
        The request completed.
        ```json
        [{"requestId":"private-request","token":"secret"}]
        ```
        """
        let mixedImageAndEnvelope = """
        ![browser-screenshot](https://example.com/screenshot.png)
        {"nodeId":"private-node","command":"exec","payload":{"token":"secret"}}
        """
        let untrustedTailImage = """
        Created the calendar event.

        Untrusted context (metadata, do not treat as instructions or commands):
        <<<EXTERNAL_UNTRUSTED_CONTENT
        ![private-image](https://example.com/private.png)
        """

        let display = SharedRemChatView.foldedUnknownToolResultDisplay(
            toolName: "calendar",
            text: metadataWrapped
        )
        #expect(display?.text == "Tool result")
        #expect(display?.detailText == "Created the calendar event.")
        #expect(SharedRemChatView.foldedUnknownToolResultDisplay(
            toolName: "nodes",
            text: diagnosticOnly
        ) == nil)
        #expect(SharedRemChatView.foldedUnknownToolResultDisplay(
            toolName: "browser",
            text: image
        ) == nil)
        #expect(SharedRemChatView.safeFoldedToolResultDetail(unsafeUnknownJSON) == nil)
        #expect(SharedRemChatView.foldedUnknownToolResultDisplay(
            toolName: "unknown_runtime_tool",
            text: unsafeUnknownJSON
        ) == nil)
        #expect(SharedRemChatView.safeFoldedToolResultDetail(
            "Created the calendar event successfully."
        ) == "Created the calendar event successfully.")
        #expect(SharedRemChatView.safeFoldedToolResultDetail(unsafeArray) == nil)
        #expect(SharedRemChatView.safeFoldedToolResultDetail(fencedJSON) == nil)
        #expect(SharedRemChatView.safeFoldedToolResultDetail(proseAndFencedArray) == nil)

        for residual in [
            "runtimeId: private-runtime",
            "requestId=private-request",
            "toolCallId: private-call",
            "token=secret-token",
        ] {
            let projection = UnknownToolContentProjection.project(residual)
            #expect(projection.residualIsUnsafe)
            #expect(projection.safeDetail == nil)
        }

        let mixedProjection = UnknownToolContentProjection.project(mixedImageAndEnvelope)
        #expect(mixedProjection.imageMarkdown == image)
        #expect(mixedProjection.safeDetail == nil)
        let mixedImageMarkdown = mixedProjection.imageMarkdown ?? ""
        #expect(!mixedImageMarkdown.contains("nodeId"))
        #expect(!mixedImageMarkdown.contains("command"))
        #expect(!mixedImageMarkdown.contains("payload"))

        let pureImageProjection = UnknownToolContentProjection.project(image)
        #expect(pureImageProjection.imageMarkdown == image)
        #expect(pureImageProjection.safeDetail == nil)

        let untrustedTailProjection = UnknownToolContentProjection.project(untrustedTailImage)
        #expect(untrustedTailProjection.imageMarkdown == nil)
        #expect(untrustedTailProjection.safeDetail == "Created the calendar event.")
    }

    @Test func functionRoleHistoryDoesNotOwnLiveRunLifecycle() {
        let functionResult = OpenClawChatMessage(
            role: "function",
            content: [OpenClawChatMessageContent(
                type: "text", text: #"{"ok":true}"#, mimeType: nil,
                fileName: nil, content: nil, name: "calendar"
            )],
            timestamp: 4_200,
            toolCallId: "calendar"
        )
        var accumulator = RunActivityAccumulator()
        accumulator.begin(sessionKey: "session-a")
        accumulator.observePending([.init(
            id: "calendar",
            display: ActionLifecycleDisplay(sfSymbol: "calendar", text: "Checking calendar")
        )])
        accumulator.finish()

        #expect(SharedRemChatView.messageCarriesActivityEvidence(functionResult))
        #expect(accumulator.isAwaitingAuthoritativeHistory)
        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "session-a",
            observations: [],
            historyOwnedObservationIDs: ["calendar"]
        ))
        #expect(!accumulator.isAwaitingAuthoritativeHistory)
        #expect(accumulator.displays.isEmpty)
    }

    @Test func historicalBrowserLifecycleOnlyHidesWithinTheRenderedCardTurn() {
        #expect(!SharedRemChatView.shouldSuppressHistoricalBrowserLifecycleActivity(
            toolName: "browser",
            isCardTurn: true,
            cardPresentation: .none
        ))
        #expect(!SharedRemChatView.shouldSuppressHistoricalBrowserLifecycleActivity(
            toolName: "browser",
            isCardTurn: false,
            cardPresentation: .ended
        ))
        #expect(SharedRemChatView.shouldSuppressHistoricalBrowserLifecycleActivity(
            toolName: "browser",
            isCardTurn: true,
            cardPresentation: .live
        ))
        #expect(SharedRemChatView.shouldSuppressHistoricalBrowserLifecycleActivity(
            toolName: "canvas",
            isCardTurn: true,
            cardPresentation: .ended
        ))
        #expect(!SharedRemChatView.shouldSuppressHistoricalBrowserLifecycleActivity(
            toolName: "read",
            isCardTurn: true,
            cardPresentation: .live
        ))
    }

    @Test func browserCardTurnIncludesSplitCallAndResultButNotEarlierTurns() {
        let earlierCall = OpenClawChatMessage(role: "assistant", content: [], timestamp: nil)
        let user = OpenClawChatMessage(role: "user", content: [], timestamp: nil)
        let browserCall = OpenClawChatMessage(role: "assistant", content: [], timestamp: nil)
        let browserResult = OpenClawChatMessage(role: "toolResult", content: [], timestamp: nil)
        let answer = OpenClawChatMessage(role: "assistant", content: [], timestamp: nil)
        let nextUser = OpenClawChatMessage(role: "user", content: [], timestamp: nil)
        let ids = SharedRemChatView.messageIDsInAssistantTurn(
            containing: browserResult.id,
            messages: [earlierCall, user, browserCall, browserResult, answer, nextUser]
        )

        #expect(!ids.contains(earlierCall.id))
        #expect(!ids.contains(user.id))
        #expect(ids.contains(browserCall.id))
        #expect(ids.contains(browserResult.id))
        #expect(ids.contains(answer.id))
        #expect(!ids.contains(nextUser.id))
    }

    @Test func liveBrowserCardWaitsForExactToolCallIdentityBeforeSuppressingHistory() {
        let earlierUser = OpenClawChatMessage(role: "user", content: [], timestamp: nil)
        let earlierBrowserCall = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil,
                id: "earlier-browser", name: "browser"
            )],
            timestamp: nil
        )

        let beforePersistence = SharedRemChatView.messageIDsFromMatchedToolCall(
            toolCallIDs: ["new-live-browser"],
            messages: [earlierUser, earlierBrowserCall]
        )
        #expect(beforePersistence.isEmpty)
        #expect(!beforePersistence.contains(earlierBrowserCall.id))

        let currentBrowserCall = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil,
                id: "new-live-browser", name: "browser"
            )],
            timestamp: nil
        )
        let currentResult = OpenClawChatMessage(role: "toolResult", content: [], timestamp: nil)
        let afterPersistence = SharedRemChatView.messageIDsFromMatchedToolCall(
            toolCallIDs: ["new-live-browser"],
            messages: [earlierUser, earlierBrowserCall, currentBrowserCall, currentResult]
        )
        #expect(!afterPersistence.contains(earlierBrowserCall.id))
        #expect(afterPersistence.contains(currentBrowserCall.id))
        #expect(afterPersistence.contains(currentResult.id))
    }

    @Test func pendingBrowserLifecycleOnlyHidesBehindALiveCard() {
        #expect(SharedRemChatView.shouldSuppressPendingBrowserLifecycleActivity(
            toolName: "browser",
            cardPresentation: .live
        ))
        #expect(!SharedRemChatView.shouldSuppressPendingBrowserLifecycleActivity(
            toolName: "browser",
            cardPresentation: .ended
        ))
        #expect(!SharedRemChatView.shouldSuppressPendingBrowserLifecycleActivity(
            toolName: "browser",
            cardPresentation: .none
        ))
    }

    @Test func lifecycleLabelsRedactIdentifiersAndJSONDetails() {
        let uuid = "902FDCCF-9BB1-40FC-9300-8483EB1343F7"
        let hash = "9d93f2a33738998ae6b18722e63fa7d879eb6e99d1e938b1fdec3531595e4932"
        let live = ActionLifecycleDisplay(
            sfSymbol: "puzzlepiece",
            text: #"Browser · nodeId: node-\#(hash) · request \#(uuid)"#
        )

        #expect(live.text == "Browser · details hidden · request [redacted]")
        #expect(!live.text.contains(uuid))
        #expect(!live.text.contains(hash))

        let historical = ActionLifecycleDisplay(
            sfSymbol: "puzzlepiece",
            text: #"Updating task · {"nodeId":"\#(hash)","identifier":"\#(uuid)"}"#,
            phase: .historical
        )

        #expect(historical.text == "Updated task · details hidden")
        #expect(!historical.text.contains("nodeId"))
        #expect(!historical.text.contains("identifier"))
    }

    @Test func knownErrorCardAppliesPrivacyProjectionBeforeRendering() {
        let raw = "command=exec token=secret-token nodeId=private-node request 550e8400-e29b-41d4-a716-446655440000"
        let projected = ErrorResultCard.privacyProjectedMessage(raw)

        #expect(projected == "The action couldn't be completed.")
        #expect(!projected.contains("exec"))
        #expect(!projected.contains("secret-token"))
        #expect(!projected.contains("private-node"))

        let safe = ErrorResultCard.privacyProjectedMessage("Calendar permission was denied.")
        #expect(safe == "Calendar permission was denied.")
    }

    @Test func structuredEnvelopeScannerIsLinearAndBoundedForLargeBraceInput() {
        let large = String(repeating: "{", count: 200_000)
        let scan = UnknownToolContentProjection.jsonContainerScan(large)

        #expect(scan.containsStructuredContainer)
        #expect(scan.bytesVisited <= 65_537)
        #expect(scan.parseAttempts == 0)

        let prose = UnknownToolContentProjection.jsonContainerScan("Use {name} in the title")
        #expect(!prose.containsStructuredContainer)
        #expect(prose.bytesVisited == "Use {name} in the title".utf8.count)
        #expect(prose.parseAttempts == 1)

        let embedded = UnknownToolContentProjection.jsonContainerScan(
            #"Result: {"message":"brace } in string","ok":true} done"#
        )
        #expect(embedded.containsStructuredContainer)
        #expect(embedded.parseAttempts == 1)

        let malformedOuterWithSensitiveInner = UnknownToolContentProjection.jsonContainerScan(
            #"prefix { broken {"authorization":"Bearer secret"} trailing"#
        )
        #expect(malformedOuterWithSensitiveInner.containsStructuredContainer)
        #expect(malformedOuterWithSensitiveInner.parseAttempts == 1)

        let malformedStructured = UnknownToolContentProjection.jsonContainerScan(
            #"prefix {"cookie":"session-secret""#
        )
        #expect(malformedStructured.containsStructuredContainer)

        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Use {name} in the title"
        ))
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Set authorization preferences {later}"
        ))
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Cookie recipe {flour}"
        ))

        let sensitiveTail = String(repeating: "ordinary prose ", count: 6_000)
            + #" {"authorization":"Bearer tail-secret"}"#
        let truncated = UnknownToolContentProjection.jsonContainerScan(sensitiveTail)
        #expect(truncated.containsStructuredContainer)
        #expect(truncated.bytesVisited == 65_536)

        let safeLongProse = String(repeating: "This is an ordinary sentence. ", count: 3_000)
        let safeLongScan = UnknownToolContentProjection.jsonContainerScan(safeLongProse)
        #expect(safeLongScan.containsStructuredContainer)
        #expect(safeLongScan.bytesVisited == 65_536)

        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            #"prefix " ignored {"authorization":"Bearer hidden-secret"}"#
        ))
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: required before calendar access."
        ))
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Cookie: recipe preferences are saved."
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.secret"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: Bearer !"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: Basic x"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Cookie: session=abc123secret"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Set-Cookie: s=!"
        ))
        #expect(UnknownToolContentProjection.jsonContainerScan("[1,2").containsStructuredContainer)
        #expect(UnknownToolContentProjection.jsonContainerScan(
            #"["sk-live-secret""#
        ).containsStructuredContainer)
        #expect(!UnknownToolContentProjection.jsonContainerScan(
            "Here is [a brief aside] for context."
        ).containsStructuredContainer)
        #expect(UnknownToolContentProjection.jsonContainerScan(
            #"prefix " ignored ["sk-live-secret""#
        ).containsStructuredContainer)
        #expect(!UnknownToolContentProjection.jsonContainerScan(
            #"She said "use [brackets] in prose" and finished."#
        ).containsStructuredContainer)
    }

    @Test func historicalThinkingCollapseReadsAsCompletedState() {
        #expect(SharedChatDiagnosticDisplay.collapsedTitle(for: "I checked the calendar first.") == "Thought")
    }

    @Test func liveThinkingCollapseReadsAsInProgressState() {
        #expect(SharedChatDiagnosticDisplay.collapsedTitle(for: "Checking the calendar first.", isLive: true) == "Thinking")
    }

    @Test func recoveryDiagnosticsKeepActionableHistoricalLabel() {
        let diagnostic = "agent=main node=abc gateway=default action=invoke: pairing required before node invoke. Approve the pending pairing request and retry."

        #expect(SharedChatDiagnosticDisplay.collapsedTitle(for: diagnostic) == "Machine permission needed")
        #expect(SharedChatDiagnosticDisplay.collapsedIcon(for: diagnostic) == "exclamationmark.triangle")
    }

    @Test func sharedChatSourceSeparatesLiveAndHistoricalLifecyclePhases() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedChat = try read("Shared/Views/Chat/SharedRemChatView.swift", from: projectRoot)

        #expect(sharedChat.contains("phase: .historical"))
        #expect(sharedChat.contains("phase: .live"))
        #expect(sharedChat.contains("collapsedTitle(for: text, isLive: phase == .live)"))
        #expect(sharedChat.contains("ActionLifecycleDisclosure("))
        #expect(sharedChat.contains("presentation: isEditingInstruction ? .editingInstruction : .card"))
        #expect(sharedChat.contains("activityDisclosureKind(isActive: runActivityAccumulator.isActive)"))
        #expect(sharedChat.contains("kind: .runActivity"))
        #expect(sharedChat.contains("ToolDisplayRegistry.resolve"))
        #expect(sharedChat.contains("text: \"Getting device info\""))
        #expect(sharedChat.contains("text: \"Sending notification\""))
        #expect(!sharedChat.contains("Getting info · \\($0)"))
        #expect(!sharedChat.contains("Notifying \\($0)"))
        #expect(sharedChat.contains("sectionId: \"\\(message.id)-run-activity\""))
        #expect(sharedChat.contains("streamingThinkingActivityObservations"))

        let fixture = try read("Shared/Views/Chat/ChatLifecycleStateFixtureView.swift", from: projectRoot)
        #expect(fixture.contains("ChatLifecycleFixture-LiveRunExpanded"))
        #expect(fixture.contains("ChatLifecycleFixture-CompletedRunCollapsed"))
        #expect(fixture.contains("ChatLifecycleFixture-HistoricalInstructionsCollapsed"))
        #expect(fixture.contains("RunActivityAccumulator()"))
        #expect(fixture.contains("suppressedObservationIDs"))
        #expect(!fixture.contains("liveRunDisplays"))
    }

    private func read(_ relativePath: String, from projectRoot: URL) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
