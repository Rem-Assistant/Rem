import Foundation
import Testing
@testable import RemClawMac

/// Mac-side coverage for the shared, server-derived Outputs rendering.
///
/// `SharedAutomationsSettingsView` renders on both platforms, so the rules that decide what the
/// user is told about an output have to hold on Mac too. These run on the macOS destination, which
/// is also the only way this repo can execute the assertions without a simulator.
///
/// Every check is a PAIR: a fact and its opposite must produce different user-visible text. The
/// test these replace asserted that a Swift literal said "Planned" — it agreed with itself for
/// months while the product shipped the opposite behaviour.
struct MacAutomationOutputsPresentationTests {

    @Test func statusLabelMovesWithTheDerivedState() {
        let labels = [
            AutomationOutputsPresentation.statusLabel(for: .included),
            AutomationOutputsPresentation.statusLabel(for: .idle),
            AutomationOutputsPresentation.statusLabel(for: .comingSoon),
            AutomationOutputsPresentation.statusLabel(for: .unrecognized("partially_produced")),
        ]
        #expect(labels == ["Included", "Nothing yet", "Coming soon", "Unknown"])
        // If two states ever collapse onto one label the surface stops discriminating, which is
        // the failure mode this whole lane exists to end.
        #expect(Set(labels).count == labels.count)
    }

    /// An unknown state must never be coerced into the producing one.
    @Test func onlyIncludedReadsAsProducing() {
        #expect(AutomationOutputsPresentation.emphasis(for: .included) == .active)
        for state: AutomationOutputState in [.idle, .comingSoon, .unrecognized("odd")] {
            #expect(AutomationOutputsPresentation.emphasis(for: state) == .muted)
        }
    }

    @Test func evidenceLineTracksTheProducerCount() {
        let base = { (count: Int?) in
            AutomationOutputRow(
                output: .taskSuggestions, state: .included, detail: "d", lastItemCount: count)
        }
        #expect(AutomationOutputsPresentation.secondaryLine(for: base(4)) == "4 items")
        #expect(AutomationOutputsPresentation.secondaryLine(for: base(1)) == "1 item")
        // A real zero is stated, not hidden — "Included" with nothing behind it is the unfalsifiable
        // claim the hand-typed row used to make.
        #expect(AutomationOutputsPresentation.secondaryLine(for: base(0)) == "Nothing right now")
        // No count at all is a different fact from a zero count, and must not borrow its copy.
        #expect(AutomationOutputsPresentation.secondaryLine(for: base(nil)) == nil)
    }

    @Test func evidenceLineReportsProductionAge() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let row = { (offset: TimeInterval) in
            AutomationOutputRow(
                output: .dailyOrientation, state: .included, detail: "d",
                lastProducedAt: ISO8601DateFormatter().string(
                    from: now.addingTimeInterval(-offset)))
        }
        #expect(AutomationOutputsPresentation.secondaryLine(for: row(7_200), now: now) == "2h ago")
        #expect(AutomationOutputsPresentation.secondaryLine(for: row(600), now: now) == "10m ago")
        // Clock skew must not read as a negative age.
        #expect(AutomationOutputsPresentation.secondaryLine(for: row(-30), now: now) == "just now")
    }

    /// Both ISO 8601 forms, per the CLAUDE.md gotcha — a non-fractional stamp must not vanish.
    @Test func parsesBothISO8601Forms() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for stamp in ["2026-08-10T15:15:00Z", "2026-08-10T15:15:00.250Z"] {
            let row = AutomationOutputRow(
                output: .dailyOrientation, state: .included, detail: "d", lastProducedAt: stamp)
            #expect(AutomationOutputsPresentation.secondaryLine(for: row, now: now) != nil)
        }
    }

    @Test func unknownOutputIsHumanizedRatherThanInvented() {
        let row = AutomationOutputRow(
            output: .unrecognized("weekly_recap"), state: .idle, detail: "d")
        #expect(AutomationOutputsPresentation.title(for: row) == "Weekly recap")
    }

    @Test func unrecognizedRowSaysWhatToDoAboutIt() {
        let row = AutomationOutputRow(
            output: .unrecognized("weekly_recap"), state: .unrecognized("odd"), detail: "d")
        #expect(AutomationOutputsPresentation.secondaryLine(for: row) == "Needs a newer Rem")
    }

    /// Decoding is the other half of the contract: an unknown wire state must survive as itself.
    @Test func unknownWireStateDecodesAsUnrecognizedNotIncluded() throws {
        let json = """
        {"outputs":[{"output":"weekly_recap","state":"partially_produced","detail":"d"}]}
        """
        let rows = try JSONDecoder()
            .decode(AutomationOutputsResponse.self, from: Data(json.utf8)).outputs

        #expect(rows[0].state == .unrecognized("partially_produced"))
        #expect(rows[0].state != .included)
        #expect(rows[0].output.wireValue == "weekly_recap")
    }

    @Test func olderServerIsNamedRatherThanBlamingTheNetwork() {
        let notFound = AutomationOutputsServiceError.requestFailed(statusCode: 404, message: nil)
        let serverError = AutomationOutputsServiceError.requestFailed(statusCode: 500, message: nil)

        #expect(AutomationOutputsPresentation.isUnsupportedByServer(notFound))
        #expect(!AutomationOutputsPresentation.isUnsupportedByServer(serverError))
        #expect(AutomationOutputsPresentation.errorTitle(notFound)
            != AutomationOutputsPresentation.errorTitle(serverError))
    }

    @MainActor
    @Test func storeDistinguishesEmptyAnswerFromNotYetAsked() async {
        let store = AutomationOutputsStore(
            service: MockAutomationOutputsService(rows: [], simulatedDelay: .zero))
        #expect(!store.hasLoaded)

        await store.load(showSkeleton: true)

        #expect(store.rows.isEmpty)
        #expect(store.hasLoaded)
        #expect(store.loadError == nil)
    }

    @MainActor
    @Test func failedRefreshKeepsRenderableRows() async {
        let rows = [AutomationOutputRow(output: .dailyOrientation, state: .included, detail: "d")]
        let service = MockAutomationOutputsService(rows: rows, simulatedDelay: .zero)
        let store = AutomationOutputsStore(service: service)
        await store.load(showSkeleton: true)

        service.failure = AutomationOutputsServiceError.requestFailed(
            statusCode: 500, message: nil)
        await store.load(showSkeleton: false)

        #expect(store.rows == rows)
        #expect(store.loadError == nil)
    }
}
