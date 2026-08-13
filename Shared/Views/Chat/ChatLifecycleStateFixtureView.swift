import SwiftUI

#if DEBUG
struct ChatLifecycleStateFixtureView: View {
    @State private var expandedSections: Set<String> = [
        "historical-thought",
        "recovery",
    ]

    var body: some View {
        let states = Self.reducerStates
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text("Active run")
                    .font(DesignTokens.Typography.caption1.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                ActionLifecycleDisclosure(
                    displays: states.active,
                    isExpanded: true,
                    kind: .runActivity,
                    isRunActive: true,
                    accessibilityIdentifier: "ChatLifecycleFixture-LiveRunExpanded",
                    onToggle: {}
                )

                Text("Long active run (bounded)")
                    .font(DesignTokens.Typography.caption1.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .padding(.top, DesignTokens.Spacing.sm)
                ActionLifecycleDisclosure(
                    displays: Self.longActiveRun,
                    isExpanded: true,
                    kind: .runActivity,
                    isRunActive: true,
                    accessibilityIdentifier: "ChatLifecycleFixture-LongRunBounded",
                    onToggle: {}
                )

                Text("Completed run")
                    .font(DesignTokens.Typography.caption1.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .padding(.top, DesignTokens.Spacing.sm)
                ActionLifecycleDisclosure(
                    displays: states.awaitingHistory,
                    isExpanded: false,
                    kind: .runActivity,
                    elapsedSeconds: 21,
                    accessibilityIdentifier: "ChatLifecycleFixture-CompletedRunCollapsed",
                    onToggle: {}
                )

                Text("Other lifecycle states")
                    .font(DesignTokens.Typography.caption1.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .padding(.top, DesignTokens.Spacing.sm)
                SharedChatThinkingBlock(
                    text: "I checked the calendar and reminders before replying.",
                    sectionId: "historical-thought",
                    expandedSections: $expandedSections
                )
                ActionLifecycleCard(
                    display: .init(
                        sfSymbol: "asset.apple-reminders-logo",
                        text: "Updating reminder",
                        phase: .historical
                    ),
                    showsProgress: false,
                    accessibilityIdentifier: "ChatLifecycleFixture-HistoricalAction"
                )
                ActionLifecycleCard(
                    display: .init(
                        sfSymbol: "square.and.pencil",
                        text: "write · /data/workspace/USER.md",
                        phase: .historical,
                        presentation: .editingInstruction
                    ),
                    showsProgress: false,
                    accessibilityIdentifier: "ChatLifecycleFixture-HistoricalInstructions"
                )
                ActionLifecycleDisclosure(
                    displays: Self.historicalInstructionDisplays,
                    isExpanded: false,
                    accessibilityIdentifier: "ChatLifecycleFixture-HistoricalInstructionsCollapsed",
                    onToggle: {}
                )
                ActionLifecycleDisclosure(
                    displays: Self.historicalInstructionDisplays,
                    isExpanded: true,
                    accessibilityIdentifier: "ChatLifecycleFixture-HistoricalInstructionsExpanded",
                    onToggle: {}
                )

                Text("Recovery")
                    .font(DesignTokens.Typography.caption1.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .padding(.top, DesignTokens.Spacing.sm)
                SharedChatThinkingBlock(
                    text: "agent=main node=abc gateway=default action=invoke: pairing required before node invoke. Approve the pending pairing request and retry.",
                    sectionId: "recovery",
                    expandedSections: $expandedSections
                )
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Color.backgroundPrimary)
    }

    private static let historicalInstructionDisplays: [ActionLifecycleDisplay] = [
        .init(
            sfSymbol: "square.and.pencil",
            text: "write · /data/workspace/USER.md",
            phase: .historical,
            presentation: .editingInstruction
        ),
        .init(
            sfSymbol: "square.and.pencil",
            text: "write · /data/workspace/IDENTITY.md",
            phase: .historical,
            presentation: .editingInstruction
        ),
        .init(
            sfSymbol: "terminal",
            text: "exec · rm /data/workspace/BOOTSTRAP.md",
            phase: .historical,
            presentation: .editingInstruction
        ),
    ]

    private static let longActiveRun: [ActionLifecycleDisplay] = (1...14).map { step in
        .init(
            sfSymbol: step.isMultiple(of: 2) ? "magnifyingglass" : "doc.text",
            text: "Inspecting activity step \(step)",
            tint: DesignTokens.Color.labelTertiary
        )
    }

    private struct ReducerStates {
        let active: [ActionLifecycleDisplay]
        let awaitingHistory: [ActionLifecycleDisplay]
    }

    /// Drives the fixture through the same accumulator inputs as production:
    /// emitted streaming summary + pending tools, browser-card suppression, then
    /// run completion while the authoritative history refresh is pending.
    private static let reducerStates: ReducerStates = {
        var accumulator = RunActivityAccumulator()
        let summary = SharedRemChatView.streamingThinkingActivityObservations(
            from: "<think>Checking which accounts are connected</think>"
        )
        let browserActivity = BrowserToolActivity(
            sessionKey: "fixture-session",
            runID: "fixture-run",
            toolCallID: "fixture-browser-call",
            toolName: "browser",
            action: "navigate"
        )
        var browserEvidence = BrowserRunEvidence()
        browserEvidence.record(browserActivity)
        let browser = RunActivityAccumulator.Observation(
            id: browserActivity.toolCallID,
            display: .init(sfSymbol: "globe", text: "Using browser")
        )
        let gmail = RunActivityAccumulator.Observation(
            id: "gmail-1",
            display: .init(sfSymbol: "envelope", text: "Checking Gmail")
        )

        // Browser card is initially absent, so the browser tool joins Activity.
        accumulator.reconcile(.init(
            runCount: 1,
            sessionKey: "fixture-session",
            observations: summary + [browser, gmail]
        ))
        // Once the card becomes live, production explicitly evicts that step.
        accumulator.reconcile(.init(
            runCount: 1,
            sessionKey: "fixture-session",
            observations: summary + [browser, gmail],
            suppressedObservationIDs: SharedRemChatView.suppressedRunActivityIDs(
                pendingBrowserToolCallIDs: [],
                activeBrowserRunEvidences: [browserEvidence],
                cardPresentation: .live
            )
        ))
        let active = accumulator.displays

        accumulator.reconcile(.init(
            runCount: 0,
            sessionKey: "fixture-session",
            observations: []
        ))
        return ReducerStates(active: active, awaitingHistory: accumulator.displays)
    }()
}

#Preview("Chat Lifecycle States") {
    ChatLifecycleStateFixtureView()
}
#endif
