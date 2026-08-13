import Foundation
import XCTest
@testable import RemClaw

/// Wire decoding + presentation for the server-derived Outputs section.
///
/// The test this file replaces (`testDailyBriefOutputContractKeepsSuggestionsPlannedAndConsentBound`)
/// asserted that the Swift literal said `.planned`. It was green for as long as the literal existed
/// — including the whole period when `deriveSuggestions` was already producing suggestions and the
/// brief route was serving them. So every assertion here is written to fail if the rendered state
/// stops tracking the underlying fact: states are checked in PAIRS, and the pair must disagree.
final class AutomationOutputsContractTests: XCTestCase {

    // MARK: Wire decoding

    private func decode(_ json: String) throws -> [AutomationOutputRow] {
        try JSONDecoder().decode(
            AutomationOutputsResponse.self, from: Data(json.utf8)).outputs
    }

    func testDecodesEveryPinnedStateAndOutputKind() throws {
        let rows = try decode("""
        {"outputs":[
          {"output":"daily_orientation","state":"included","detail":"a",
           "lastProducedAt":"2026-08-10T15:15:00.250Z","lastItemCount":null},
          {"output":"attention_triage","state":"idle","detail":"b",
           "lastProducedAt":null,"lastItemCount":0},
          {"output":"task_suggestions","state":"coming_soon","detail":"c",
           "lastProducedAt":null,"lastItemCount":null}
        ]}
        """)

        XCTAssertEqual(rows.map(\.output), [.dailyOrientation, .attentionTriage, .taskSuggestions])
        XCTAssertEqual(rows.map(\.state), [.included, .idle, .comingSoon])
        XCTAssertEqual(rows[0].lastProducedAt, "2026-08-10T15:15:00.250Z")
        // A real zero must survive decoding as 0, not collapse into nil. The distinction between
        // "produced nothing" and "has no count" is load-bearing for the status label.
        XCTAssertEqual(rows[1].lastItemCount, 0)
        XCTAssertNil(rows[2].lastItemCount)
    }

    /// A newer server must not break an older client, and — the part that matters — an unknown
    /// state must never be coerced into `.included`.
    func testUnknownStateAndOutputDecodeAsUnrecognizedNotIncluded() throws {
        let rows = try decode("""
        {"outputs":[{"output":"weekly_recap","state":"partially_produced","detail":"d",
          "lastProducedAt":null,"lastItemCount":null}]}
        """)

        XCTAssertEqual(rows[0].state, .unrecognized("partially_produced"))
        XCTAssertNotEqual(rows[0].state, .included)
        XCTAssertEqual(rows[0].output, .unrecognized("weekly_recap"))
        XCTAssertFalse(rows[0].state.isRecognized)
        XCTAssertFalse(rows[0].output.isRecognized)
        // Raw codes are preserved so row identity survives a refresh.
        XCTAssertEqual(rows[0].output.wireValue, "weekly_recap")
        XCTAssertEqual(rows[0].state.wireValue, "partially_produced")
    }

    func testAbsentNullableFieldsDecode() throws {
        let rows = try decode("""
        {"outputs":[{"output":"task_suggestions","state":"idle","detail":"e"}]}
        """)
        XCTAssertNil(rows[0].lastProducedAt)
        XCTAssertNil(rows[0].lastItemCount)
    }

    func testRoundTrips() throws {
        let original = AutomationOutputRow(
            output: .taskSuggestions, state: .included, detail: "f",
            lastProducedAt: "2026-08-10T15:15:00Z", lastItemCount: 3)
        let data = try JSONEncoder().encode(AutomationOutputsResponse(outputs: [original]))
        XCTAssertEqual(try JSONDecoder().decode(AutomationOutputsResponse.self, from: data).outputs,
                       [original])
    }

    // MARK: Status label discriminates

    /// The whole point: the label must MOVE with the state. If these two ever return the same
    /// string, the surface is back to telling the user something it did not observe.
    func testStatusLabelDiffersPerState() {
        let labels = [
            AutomationOutputsPresentation.statusLabel(for: .included),
            AutomationOutputsPresentation.statusLabel(for: .idle),
            AutomationOutputsPresentation.statusLabel(for: .comingSoon),
            AutomationOutputsPresentation.statusLabel(for: .unrecognized("whatever")),
        ]
        XCTAssertEqual(labels, ["Included", "Nothing yet", "Coming soon", "Unknown"])
        XCTAssertEqual(Set(labels).count, labels.count, "states must not share a label")
    }

    func testOnlyIncludedReadsAsActive() {
        XCTAssertEqual(AutomationOutputsPresentation.emphasis(for: .included), .active)
        for state: AutomationOutputState in [.idle, .comingSoon, .unrecognized("x")] {
            XCTAssertEqual(
                AutomationOutputsPresentation.emphasis(for: state), .muted,
                "\(state.wireValue) must not render as a producing output")
        }
    }

    // MARK: Evidence line

    func testEvidenceLineReportsCountAndAge() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let row = AutomationOutputRow(
            output: .taskSuggestions, state: .included, detail: "g",
            lastProducedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-7_200)),
            lastItemCount: 4)

        XCTAssertEqual(
            AutomationOutputsPresentation.secondaryLine(for: row, now: now), "4 items · 2h ago")
    }

    /// A zero count is reported as a zero, not hidden. An "Included" row with no items would be
    /// the same class of unfalsifiable claim the literal made.
    func testZeroCountIsStatedRatherThanOmitted() {
        let row = AutomationOutputRow(
            output: .attentionTriage, state: .idle, detail: "h", lastItemCount: 0)
        XCTAssertEqual(
            AutomationOutputsPresentation.secondaryLine(for: row), "Nothing right now")
    }

    func testNoEvidenceYieldsNoLine() {
        let row = AutomationOutputRow(output: .dailyOrientation, state: .idle, detail: "i")
        XCTAssertNil(AutomationOutputsPresentation.secondaryLine(for: row))
    }

    func testUnrecognizedRowTellsTheUserWhatToDo() {
        let row = AutomationOutputRow(
            output: .unrecognized("weekly_recap"), state: .unrecognized("odd"), detail: "j")
        XCTAssertEqual(AutomationOutputsPresentation.secondaryLine(for: row), "Needs a newer Rem")
    }

    func testUnknownOutputIsHumanizedNotInvented() {
        let row = AutomationOutputRow(
            output: .unrecognized("weekly_recap"), state: .idle, detail: "k")
        XCTAssertEqual(AutomationOutputsPresentation.title(for: row), "Weekly recap")
    }

    /// Both ISO 8601 forms, per the CLAUDE.md gotcha.
    func testParsesBothISO8601Forms() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        for stamp in ["2026-08-10T15:15:00Z", "2026-08-10T15:15:00.250Z"] {
            let row = AutomationOutputRow(
                output: .dailyOrientation, state: .included, detail: "l", lastProducedAt: stamp)
            XCTAssertNotNil(
                AutomationOutputsPresentation.secondaryLine(for: row, now: now),
                "failed to parse \(stamp)")
        }
    }

    // MARK: Store

    @MainActor
    func testLoadPublishesServerRows() async {
        let rows = [AutomationOutputRow(output: .taskSuggestions, state: .included, detail: "m")]
        let store = AutomationOutputsStore(
            service: MockAutomationOutputsService(rows: rows, simulatedDelay: .zero))

        XCTAssertFalse(store.hasLoaded)
        await store.load(showSkeleton: true)

        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.rows, rows)
        XCTAssertNil(store.loadError)
        XCTAssertFalse(store.isLoading)
    }

    /// "The server reported no outputs" and "we have not asked yet" must not render the same.
    @MainActor
    func testEmptyServerAnswerIsDistinguishableFromNotYetAsked() async {
        let store = AutomationOutputsStore(
            service: MockAutomationOutputsService(rows: [], simulatedDelay: .zero))
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertFalse(store.hasLoaded)

        await store.load(showSkeleton: true)

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(store.hasLoaded)
    }

    @MainActor
    func testFailureWithNothingRenderableSurfacesTheError() async {
        let store = AutomationOutputsStore(
            service: MockAutomationOutputsService(
                rows: [], simulatedDelay: .zero,
                failure: AutomationOutputsServiceError.requestFailed(
                    statusCode: 404, message: nil)))

        await store.load(showSkeleton: true)

        XCTAssertNotNil(store.loadError)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.hasLoaded)
    }

    /// A refresh failure must not replace rows the user can still read.
    @MainActor
    func testFailedRefreshKeepsRenderableRows() async {
        let rows = [AutomationOutputRow(output: .dailyOrientation, state: .included, detail: "n")]
        let service = MockAutomationOutputsService(rows: rows, simulatedDelay: .zero)
        let store = AutomationOutputsStore(service: service)
        await store.load(showSkeleton: true)

        service.failure = AutomationOutputsServiceError.requestFailed(
            statusCode: 500, message: nil)
        await store.load(showSkeleton: false)

        XCTAssertEqual(store.rows, rows)
        XCTAssertNil(store.loadError)
    }

    @MainActor
    func testRequestsTheDailyBriefKind() async {
        let service = MockAutomationOutputsService(rows: [], simulatedDelay: .zero)
        await AutomationOutputsStore(service: service).load(showSkeleton: false)
        XCTAssertEqual(service.requestedKinds, [AutomationInputsKind.dailyBrief])
    }

    // MARK: Server-unsupported rendering

    func testOlderServerIsNamedRatherThanBlamingTheNetwork() {
        let notFound = AutomationOutputsServiceError.requestFailed(statusCode: 404, message: nil)
        let serverError = AutomationOutputsServiceError.requestFailed(statusCode: 500, message: nil)

        XCTAssertTrue(AutomationOutputsPresentation.isUnsupportedByServer(notFound))
        XCTAssertFalse(AutomationOutputsPresentation.isUnsupportedByServer(serverError))
        XCTAssertNotEqual(
            AutomationOutputsPresentation.errorTitle(notFound),
            AutomationOutputsPresentation.errorTitle(serverError))
    }
}
