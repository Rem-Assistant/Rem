import Foundation
import Testing
@testable import RemClaw

/// The Inputs section used to be a Swift literal. These tests pin the two properties that literal
/// could not have: the rows come off the wire, and an answer this build does not understand is
/// never dressed up as a working one.
@Suite("Automation derived inputs")
struct AutomationInputsContractTests {

    // MARK: Decoding

    @Test func decodesAllFourDerivedStatesFromTheWireContract() throws {
        let rows = try decodeInputs("""
        {
          "inputs": [
            {
              "capability": "rem_tasks",
              "state": "included",
              "detail": "Reads scheduled, overdue, blocked, and completed task rows.",
              "connector": null,
              "lastCollectedAt": "2026-08-10T13:05:00.250Z",
              "lastItemCount": 12,
              "lastUnavailableReason": null
            },
            {
              "capability": "connector",
              "state": "unavailable",
              "detail": "Gmail is connected, but its last collection didn't complete.",
              "connector": { "source": "gmail", "displayName": "Gmail" },
              "lastCollectedAt": "2026-08-10T11:05:00Z",
              "lastItemCount": 0,
              "lastUnavailableReason": "connector_unavailable"
            },
            {
              "capability": "connector",
              "state": "not_connected",
              "detail": "Connect Slack and Daily Brief can read the last day of messages.",
              "connector": { "source": "slack", "displayName": "Slack" },
              "lastCollectedAt": null,
              "lastItemCount": null,
              "lastUnavailableReason": null
            },
            {
              "capability": "cloud_browser",
              "state": "coming_soon",
              "detail": "Cloud-browser findings aren't collected for Daily Brief yet.",
              "connector": null,
              "lastCollectedAt": null,
              "lastItemCount": null,
              "lastUnavailableReason": null
            }
          ]
        }
        """)

        #expect(rows.map(\.state) == [.included, .unavailable, .notConnected, .comingSoon])
        #expect(rows.map(\.capability) == [.remTasks, .connector, .connector, .cloudBrowser])
        #expect(rows[1].connector == AutomationInputConnector(source: "gmail", displayName: "Gmail"))
        #expect(rows[1].lastUnavailableReason == "connector_unavailable")
        #expect(rows[1].lastItemCount == 0)
        #expect(rows[2].connector?.source == "slack")
        #expect(rows[2].lastCollectedAt == nil)
        #expect(rows[2].lastItemCount == nil)
        // Two connector rows must not collide in a ForEach.
        #expect(rows[1].id != rows[2].id)
    }

    @Test func unknownStateDecodesAsUnrecognizedInsteadOfFailingOrCoercing() throws {
        let rows = try decodeInputs("""
        {
          "inputs": [
            {
              "capability": "smart_home",
              "state": "degraded",
              "detail": "Reported by a newer server than this build understands.",
              "connector": null,
              "lastCollectedAt": null,
              "lastItemCount": null,
              "lastUnavailableReason": null
            },
            {
              "capability": "rem_tasks",
              "state": "included",
              "detail": "Still decodes alongside the unknown row.",
              "connector": null,
              "lastCollectedAt": null,
              "lastItemCount": null,
              "lastUnavailableReason": null
            }
          ]
        }
        """)

        // A newer server must not break an older client: the whole payload still decodes.
        #expect(rows.count == 2)
        #expect(rows[0].state == .unrecognized("degraded"))
        #expect(rows[0].capability == .unrecognized("smart_home"))
        #expect(rows[0].state != .included)
        #expect(!rows[0].state.isRecognized)
        #expect(!rows[0].capability.isRecognized)
        // The raw code survives, so row identity is stable across refreshes.
        #expect(rows[0].state.wireValue == "degraded")
        #expect(rows[0].id == "smart_home#")
        #expect(rows[1].state == .included)
    }

    @Test func omittingNullableFieldsEntirelyStillDecodes() throws {
        // The pinned contract sends explicit nulls, but a field that is simply absent must not
        // take the whole payload down the way a required `provider` once did.
        let rows = try decodeInputs("""
        { "inputs": [ { "capability": "rem_tasks", "state": "included", "detail": "Tasks." } ] }
        """)

        #expect(rows.count == 1)
        #expect(rows[0].connector == nil)
        #expect(rows[0].lastCollectedAt == nil)
        #expect(rows[0].lastItemCount == nil)
        #expect(rows[0].lastUnavailableReason == nil)
    }

    @Test func stateAndCapabilityRoundTripThroughTheirWireValues() throws {
        let states: [AutomationInputState] = [
            .included, .notConnected, .unavailable, .comingSoon, .unrecognized("degraded"),
        ]
        for state in states {
            #expect(AutomationInputState(wireValue: state.wireValue) == state)
        }

        let capabilities: [AutomationInputCapability] = [
            .remTasks, .remCalendarItems, .connector, .cloudBrowser, .unrecognized("smart_home"),
        ]
        for capability in capabilities {
            #expect(AutomationInputCapability(wireValue: capability.wireValue) == capability)
        }
    }

    // MARK: Row presentation

    @Test func statusLabelsNeverPresentAnUnknownOrFailingSourceAsIncluded() {
        #expect(AutomationInputsPresentation.statusLabel(for: .included) == "Included")
        #expect(AutomationInputsPresentation.statusLabel(for: .notConnected) == "Not connected")
        #expect(AutomationInputsPresentation.statusLabel(for: .unavailable) == "Unavailable")
        #expect(AutomationInputsPresentation.statusLabel(for: .comingSoon) == "Coming soon")
        #expect(AutomationInputsPresentation.statusLabel(for: .unrecognized("degraded")) == "Unknown")
    }

    @Test func onlyAConnectedAndFeedingSourceReadsAsActive() {
        #expect(AutomationInputsPresentation.emphasis(for: .included) == .active)
        // The point of the whole change: a failing connector is visibly different from a working
        // one, and is not quietly muted either.
        #expect(AutomationInputsPresentation.emphasis(for: .unavailable) == .attention)
        #expect(AutomationInputsPresentation.emphasis(for: .notConnected) == .muted)
        #expect(AutomationInputsPresentation.emphasis(for: .comingSoon) == .muted)
        #expect(AutomationInputsPresentation.emphasis(for: .unrecognized("degraded")) == .muted)
    }

    @Test func onlyANotConnectedRowOffersTheConnectorsCallToAction() {
        #expect(AutomationInputsPresentation.opensConnectors(row(state: .notConnected)))
        // Already connected — Connectors would be a dead end.
        #expect(!AutomationInputsPresentation.opensConnectors(row(state: .unavailable)))
        #expect(!AutomationInputsPresentation.opensConnectors(row(state: .included)))
        #expect(!AutomationInputsPresentation.opensConnectors(row(state: .comingSoon)))
        #expect(!AutomationInputsPresentation.opensConnectors(row(state: .unrecognized("x"))))
    }

    @Test func titleAndIconPreferTheConnectorTheServerNamed() {
        let gmail = row(
            capability: .connector,
            state: .included,
            connector: AutomationInputConnector(source: "gmail", displayName: "Gmail"))

        #expect(AutomationInputsPresentation.title(for: gmail) == "Gmail")
        #expect(AutomationInputsPresentation.icon(for: gmail) == "envelope.fill")

        let tasks = row(capability: .remTasks, state: .included)
        #expect(AutomationInputsPresentation.title(for: tasks) == "Rem tasks")
        #expect(AutomationInputsPresentation.icon(for: tasks) == "checklist")

        // An unknown family is labelled from its own code, not from an invented friendly name.
        let unknown = row(capability: .unrecognized("smart_home"), state: .unrecognized("degraded"))
        #expect(AutomationInputsPresentation.title(for: unknown) == "Smart home")
        #expect(AutomationInputsPresentation.icon(for: unknown) == "questionmark.circle")
    }

    // MARK: Evidence line

    @Test func evidenceLineShowsWhatTheLastCollectProduced() throws {
        let collected = try #require(
            DailyBriefAutomationPresentation.parseISO8601("2026-08-10T11:00:00.500Z"))
        let now = collected.addingTimeInterval(2 * 3600)

        let working = row(
            capability: .connector,
            state: .included,
            connector: AutomationInputConnector(source: "gmail", displayName: "Gmail"),
            lastCollectedAt: "2026-08-10T11:00:00.500Z",
            lastItemCount: 12)

        #expect(AutomationInputsPresentation.secondaryLine(for: working, now: now)
            == "12 items · 2h ago")
    }

    @Test func aFailingConnectorNoLongerLooksIdenticalToAWorkingOne() throws {
        let collected = try #require(
            DailyBriefAutomationPresentation.parseISO8601("2026-08-10T11:00:00Z"))
        let now = collected.addingTimeInterval(2 * 3600)

        let failing = row(
            capability: .connector,
            state: .unavailable,
            connector: AutomationInputConnector(source: "gmail", displayName: "Gmail"),
            lastCollectedAt: "2026-08-10T11:00:00Z",
            lastItemCount: 0,
            lastUnavailableReason: "connector_unavailable")
        let working = row(
            capability: .connector,
            state: .included,
            connector: AutomationInputConnector(source: "gmail", displayName: "Gmail"),
            lastCollectedAt: "2026-08-10T11:00:00Z",
            lastItemCount: 12)

        let failingLine = AutomationInputsPresentation.secondaryLine(for: failing, now: now)
        #expect(failingLine == "Connector didn't respond · 2h ago")
        #expect(failingLine != AutomationInputsPresentation.secondaryLine(for: working, now: now))
        // The reason replaces the count rather than reading "0 items" next to it.
        #expect(failingLine?.contains("items") == false)
    }

    /// The claim under test is that BOTH ISO 8601 forms the backend emits are parsed — the standing
    /// CLAUDE.md gotcha. The two fixtures are therefore the SAME instant written two ways; an
    /// earlier version used `.250Z` against a `.000Z` counterpart, which made the assertion depend
    /// on how `relativeTime` rounds a 59m59.75s interval rather than on parsing at all (it
    /// truncates, so it read "59m ago" and the test failed for a reason it was not about).
    /// Truncation is pinned deliberately in its own test below.
    @Test func evidenceLineParsesBothISO8601FormsTheBackendEmits() throws {
        let withFraction = row(
            state: .included, lastCollectedAt: "2026-08-10T11:00:00.000Z", lastItemCount: 1)
        let withoutFraction = row(
            state: .included, lastCollectedAt: "2026-08-10T11:00:00Z", lastItemCount: 1)
        let now = try #require(
            DailyBriefAutomationPresentation.parseISO8601("2026-08-10T12:00:00Z"))

        #expect(AutomationInputsPresentation.secondaryLine(for: withFraction, now: now)
            == "1 item · 1h ago")
        #expect(AutomationInputsPresentation.secondaryLine(for: withoutFraction, now: now)
            == "1 item · 1h ago")
        // Both forms resolve to one instant, so the rendered lines are identical by construction.
        #expect(AutomationInputsPresentation.secondaryLine(for: withFraction, now: now)
            == AutomationInputsPresentation.secondaryLine(for: withoutFraction, now: now))
    }

    /// `relativeTime` TRUNCATES toward the elapsed unit — it does not round to the nearest one.
    /// Pinned explicitly so a fixture that lands just under a boundary fails as a rounding change,
    /// not as a mysterious parsing failure somewhere else.
    @Test func relativeTimeTruncatesRatherThanRounding() throws {
        let collected = try #require(
            DailyBriefAutomationPresentation.parseISO8601("2026-08-10T11:00:00.000Z"))
        #expect(AutomationInputsPresentation
            .relativeTime(from: collected, to: collected.addingTimeInterval(3599.75)) == "59m ago")
        #expect(AutomationInputsPresentation
            .relativeTime(from: collected, to: collected.addingTimeInterval(3600)) == "1h ago")
    }

    @Test func anUnknownStateTellsTheUserTheirAppIsBehind() throws {
        let now = try #require(
            DailyBriefAutomationPresentation.parseISO8601("2026-08-10T12:00:00Z"))
        let unknown = row(
            capability: .unrecognized("smart_home"),
            state: .unrecognized("degraded"),
            lastCollectedAt: "2026-08-10T11:00:00Z",
            lastItemCount: 4)

        #expect(AutomationInputsPresentation.secondaryLine(for: unknown, now: now)
            == "Needs a newer Rem · 4 items · 1h ago")
    }

    /// The backend deliberately emits a non-null `lastUnavailableReason` on rows whose state is
    /// fine: the field reports the LAST COLLECT, and a recorded `no_active_connection` that a live
    /// ACTIVE account has since superseded still travels on an `.included` row. `secondaryLine`
    /// used to branch on the reason being present and never consulted `state`, so a healthy Gmail
    /// row read "No connected account" directly underneath the word "Included".
    @Test func aHealthyRowIgnoresAStaleReasonAndShowsWhatItActuallyCollected() throws {
        let now = try #require(
            DailyBriefAutomationPresentation.parseISO8601("2026-08-10T13:00:00Z"))
        let supersededButFine = row(
            capability: .connector,
            state: .included,
            connector: AutomationInputConnector(source: "gmail", displayName: "Gmail"),
            lastCollectedAt: "2026-08-10T11:00:00Z",
            lastItemCount: 12,
            lastUnavailableReason: "no_active_connection")

        let line = AutomationInputsPresentation.secondaryLine(for: supersededButFine, now: now)
        #expect(line == "12 items · 2h ago")
        #expect(line?.contains("No connected account") == false)
    }

    @Test func onlyAnUnavailableRowRendersTheFailureReason() throws {
        let now = try #require(
            DailyBriefAutomationPresentation.parseISO8601("2026-08-10T13:00:00Z"))
        // Same reason string, three states. Only the one the SERVER called unavailable shows it.
        for state in [AutomationInputState.included, .notConnected, .comingSoon] {
            let line = AutomationInputsPresentation.secondaryLine(
                for: row(state: state, lastItemCount: 3, lastUnavailableReason: "timeout"),
                now: now)
            #expect(line?.contains("Timed out") == false)
        }
        let unavailable = AutomationInputsPresentation.secondaryLine(
            for: row(state: .unavailable, lastItemCount: 3, lastUnavailableReason: "timeout"),
            now: now)
        #expect(unavailable?.contains("Timed out") == true)
    }

    @Test func rowsWithNoCollectEvidenceGetNoSecondLine() {
        #expect(AutomationInputsPresentation.secondaryLine(for: row(state: .notConnected)) == nil)
        #expect(AutomationInputsPresentation.secondaryLine(for: row(state: .comingSoon)) == nil)
    }

    @Test func failureReasonsAreTreatedAsCodesNotProse() {
        #expect(AutomationInputsPresentation.failureDescription("connector_unavailable")
            == "Connector didn't respond")
        #expect(AutomationInputsPresentation.failureDescription("timeout") == "Timed out")
        #expect(AutomationInputsPresentation.failureDescription("no_accounts")
            == "No connected account")
        // An unrecognized but code-shaped reason stays readable.
        #expect(AutomationInputsPresentation.failureDescription("rate_limited") == "Rate limited")
        // A raw provider error is not pasted into the UI.
        #expect(
            AutomationInputsPresentation.failureDescription(
                "Request failed for user@example.com: 401 invalid_grant while reading mailbox")
                == "Last run didn't complete")
        #expect(AutomationInputsPresentation.failureDescription("  ") == "Last run didn't complete")
    }

    @Test func relativeTimeIsCompactAndNeverReadsNegative() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(AutomationInputsPresentation.relativeTime(
            from: now.addingTimeInterval(-10), to: now) == "just now")
        #expect(AutomationInputsPresentation.relativeTime(
            from: now.addingTimeInterval(-50), to: now) == "1m ago")
        #expect(AutomationInputsPresentation.relativeTime(
            from: now.addingTimeInterval(-45 * 60), to: now) == "45m ago")
        #expect(AutomationInputsPresentation.relativeTime(
            from: now.addingTimeInterval(-3 * 3600), to: now) == "3h ago")
        #expect(AutomationInputsPresentation.relativeTime(
            from: now.addingTimeInterval(-49 * 3600), to: now) == "2d ago")
        // Clock skew must not produce "-1h ago".
        #expect(AutomationInputsPresentation.relativeTime(
            from: now.addingTimeInterval(600), to: now) == "just now")
    }

    @Test func itemCountsReadNaturally() {
        #expect(AutomationInputsPresentation.itemCountDescription(0) == "No items")
        #expect(AutomationInputsPresentation.itemCountDescription(1) == "1 item")
        #expect(AutomationInputsPresentation.itemCountDescription(12) == "12 items")
    }

    // MARK: Store

    @MainActor
    @Test func storeReadsTheDailyBriefKindAndPublishesTheServersRows() async {
        let service = MockAutomationInputsService(
            rows: [row(state: .included)], simulatedDelay: .zero)
        let store = AutomationInputsStore(service: service)

        await store.load(showSkeleton: true)

        #expect(service.requestedKinds == ["daily-brief"])
        #expect(store.rows.count == 1)
        #expect(store.hasLoaded)
        #expect(store.loadError == nil)
        #expect(!store.isLoading)
    }

    @MainActor
    @Test func aFirstLoadFailureIsSurfacedRatherThanShowingAnInventedContract() async {
        let service = MockAutomationInputsService(
            rows: [], simulatedDelay: .zero,
            failure: AutomationInputsServiceError.requestFailed(statusCode: 404, message: nil))
        let store = AutomationInputsStore(service: service)

        await store.load(showSkeleton: true)

        #expect(store.rows.isEmpty)
        #expect(!store.hasLoaded)
        let error = store.loadError as? AutomationInputsServiceError
        #expect(error == .requestFailed(statusCode: 404, message: nil))
    }

    @MainActor
    @Test func aRefreshFailureKeepsRenderableRowsInsteadOfBlankingTheSection() async {
        let service = MockAutomationInputsService(
            rows: [row(state: .included)], simulatedDelay: .zero)
        let store = AutomationInputsStore(service: service)
        await store.load(showSkeleton: true)

        service.failure = AutomationInputsServiceError.requestFailed(
            statusCode: 500, message: nil)
        await store.load(showSkeleton: false)

        #expect(store.rows.count == 1)
        #expect(store.loadError == nil)
    }

    @MainActor
    @Test func aSupersededSkeletonLoadDoesNotStrandTheShimmer() async {
        let service = MockAutomationInputsService(
            rows: [row(state: .included)], simulatedDelay: .milliseconds(20))
        let store = AutomationInputsStore(service: service)

        // A silent refresh overtaking an in-flight skeleton load still has to end the shimmer.
        async let first: Void = store.load(showSkeleton: true)
        async let second: Void = store.load(showSkeleton: false)
        _ = await (first, second)

        #expect(!store.isLoading)
        #expect(store.hasLoaded)
        #expect(store.rows.count == 1)
    }

    // MARK: Helpers

    private func decodeInputs(_ json: String) throws -> [AutomationInputRow] {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(AutomationInputsResponse.self, from: data).inputs
    }

    private func row(
        capability: AutomationInputCapability = .connector,
        state: AutomationInputState,
        connector: AutomationInputConnector? = nil,
        lastCollectedAt: String? = nil,
        lastItemCount: Int? = nil,
        lastUnavailableReason: String? = nil
    ) -> AutomationInputRow {
        AutomationInputRow(
            capability: capability,
            state: state,
            detail: "Server-authored detail.",
            connector: connector,
            lastCollectedAt: lastCollectedAt,
            lastItemCount: lastItemCount,
            lastUnavailableReason: lastUnavailableReason)
    }
}
