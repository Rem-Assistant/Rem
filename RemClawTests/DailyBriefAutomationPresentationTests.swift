import Foundation
import XCTest
@testable import RemClaw

final class DailyBriefAutomationPresentationTests: XCTestCase {
    // The Daily Brief INPUT contract is no longer asserted here. It used to be a Swift literal, so
    // a test could only confirm the literal matched itself — which it did while production had a
    // Gmail collect failing six times in a row. Inputs are now derived by the server and covered
    // by `AutomationInputsContractTests`, which asserts against the wire contract instead.

    // The Daily Brief OUTPUT contract is no longer asserted here either, and the test that used to
    // live here is worth remembering. `testDailyBriefOutputContractKeepsSuggestionsPlannedAndConsentBound`
    // asserted that task suggestions were `.planned`. It passed continuously while
    // `deriveSuggestions` shipped tier-1 and tier-2 suggestions and `GET /api/v1/brief` served
    // them — the test was green precisely BECAUSE it pinned the literal against itself. A literal
    // compared to a literal can only ever agree, so the assertion measured nothing about the
    // product and actively defended the wrong answer.
    //
    // Outputs are now derived by the server and covered by `AutomationOutputsContractTests`, which
    // asserts that the rendered state CHANGES when the observed production fact changes.

    func testStatusSummarizesEnabledTriggers() {
        XCTAssertEqual(
            DailyBriefAutomationPresentation.statusDescription(checkins(enabled: [])),
            "Off")
        XCTAssertEqual(
            DailyBriefAutomationPresentation.statusDescription(checkins(enabled: ["morning"])),
            "On · 1 time")
        XCTAssertEqual(
            DailyBriefAutomationPresentation.statusDescription(
                checkins(enabled: ["morning", "night"])),
            "On · 2 times")
    }

    func testRecentRunsParsesBothISOFormsAndSortsNewestFirst() {
        let values = [
            Checkin(
                slot: "morning", enabled: true, deliveryHour: 8, timezone: "UTC",
                lastRunAt: "2026-08-08T15:00:00Z"),
            Checkin(
                slot: "night", enabled: true, deliveryHour: 20, timezone: "UTC",
                lastRunAt: "2026-08-09T03:00:00.125Z"),
        ]

        let runs = DailyBriefAutomationPresentation.recentRuns(values)

        XCTAssertEqual(runs.map(\.slot), ["night", "morning"])
    }

    func testRecentRunsIgnoresMissingOrMalformedEvidence() {
        let values = [
            Checkin(
                slot: "morning", enabled: true, deliveryHour: 8, timezone: "UTC",
                lastRunAt: nil),
            Checkin(
                slot: "midday", enabled: true, deliveryHour: 12, timezone: "UTC",
                lastRunAt: "not-a-date"),
        ]

        XCTAssertTrue(DailyBriefAutomationPresentation.recentRuns(values).isEmpty)
    }

    @MainActor
    func testMockUpdatePreservesExistingRunEvidence() async throws {
        let service = MockCheckinsService(
            store: [
                Checkin(
                    slot: "morning", enabled: true, deliveryHour: 8, timezone: "UTC",
                    lastRunAt: "2026-08-08T15:00:00Z")
            ],
            simulatedDelay: .zero)

        let updated = try await service.update(
            slot: "morning", enabled: false, deliveryHour: 8,
            deliveryMinute: 30, timezone: "UTC")

        XCTAssertEqual(updated.lastRunAt, "2026-08-08T15:00:00Z")
    }

    @MainActor
    func testRefreshStartedBeforeSuccessfulMutationCannotOverwriteConfirmedState() async throws {
        let original = Checkin(
            slot: "morning", enabled: false, deliveryHour: 8, timezone: "UTC",
            lastRunAt: "2026-08-08T15:00:00Z")
        let service = ControllableCheckinsService()
        let store = DailyBriefAutomationStore(service: service, checkins: [original])

        let refreshTask = Task { await store.refreshDetail() }
        await service.waitForPendingCheckins()

        let persistTask = Task {
            await store.persist(
                slot: "morning", enabled: true, deliveryHour: 9, deliveryMinute: 15)
        }
        await service.waitForPendingUpdate()
        service.resumeUpdate(returning: Checkin(
            slot: "morning", enabled: true, deliveryHour: 9, deliveryMinute: 15,
            timezone: "UTC", lastRunAt: "2026-08-08T15:00:00Z"))
        await persistTask.value

        // This stale GET began before the PUT and arrives after its confirmed response.
        service.resumeCheckins(returning: [original])
        await refreshTask.value

        let result = try XCTUnwrap(store.checkins.first)
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.deliveryHour, 9)
        XCTAssertEqual(result.deliveryMinute, 15)
        XCTAssertNil(store.detailErrorMessage)
    }

    @MainActor
    func testRefreshStartedDuringMutationCannotOverwriteLaterConfirmedState() async throws {
        let original = Checkin(
            slot: "morning", enabled: false, deliveryHour: 8, timezone: "UTC",
            lastRunAt: "2026-08-08T15:00:00Z")
        let service = ControllableCheckinsService()
        let store = DailyBriefAutomationStore(service: service, checkins: [original])

        let persistTask = Task {
            await store.persist(
                slot: "morning", enabled: true, deliveryHour: 9, deliveryMinute: 15)
        }
        await service.waitForPendingUpdate()

        // This GET begins after the optimistic write but still snapshots the server before the
        // PUT is confirmed.
        let refreshTask = Task { await store.refreshDetail() }
        await service.waitForPendingCheckins()

        service.resumeUpdate(returning: Checkin(
            slot: "morning", enabled: true, deliveryHour: 9, deliveryMinute: 15,
            timezone: "UTC", lastRunAt: "2026-08-08T15:00:00Z"))
        await persistTask.value

        service.resumeCheckins(returning: [original])
        await refreshTask.value

        let result = try XCTUnwrap(store.checkins.first)
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.deliveryHour, 9)
        XCTAssertEqual(result.deliveryMinute, 15)
        XCTAssertNil(store.detailErrorMessage)
    }

    @MainActor
    func testRefreshDuringFailedMutationPreservesNewRunEvidenceWhenControlsRollBack() async throws {
        let original = Checkin(
            slot: "morning", enabled: false, deliveryHour: 8, timezone: "UTC",
            lastRunAt: "2026-08-08T15:00:00Z")
        let service = ControllableCheckinsService()
        let store = DailyBriefAutomationStore(service: service, checkins: [original])

        let persistTask = Task {
            await store.persist(
                slot: "morning", enabled: true, deliveryHour: 9, deliveryMinute: 15)
        }
        await service.waitForPendingUpdate()

        let refreshTask = Task { await store.refreshDetail() }
        await service.waitForPendingCheckins()
        service.resumeCheckins(returning: [Checkin(
            slot: "morning", enabled: false, deliveryHour: 8, timezone: "UTC",
            lastRunAt: "2026-08-08T16:00:00Z")])
        await refreshTask.value

        // The refresh may add newer run evidence, but cannot replace the optimistic controls.
        XCTAssertTrue(try XCTUnwrap(store.checkins.first).enabled)
        XCTAssertEqual(store.checkins.first?.lastRunAt, "2026-08-08T16:00:00Z")

        service.resumeUpdate(throwing: TestFailure.expected)
        await persistTask.value

        let result = try XCTUnwrap(store.checkins.first)
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.deliveryHour, 8)
        XCTAssertEqual(result.deliveryMinute, 0)
        XCTAssertEqual(result.lastRunAt, "2026-08-08T16:00:00Z")
        XCTAssertEqual(store.detailErrorMessage, "Couldn't save Daily Brief. Try again.")
    }

    private func checkins(enabled slots: Set<String>) -> [Checkin] {
        Checkin.slotOrder.enumerated().map { index, slot in
            Checkin(
                slot: slot,
                enabled: slots.contains(slot),
                deliveryHour: [8, 12, 20][index],
                timezone: "UTC")
        }
    }
}

@MainActor
private final class ControllableCheckinsService: CheckinsProviding {
    private var pendingCheckins: [CheckedContinuation<[Checkin], Error>] = []
    private var pendingUpdate: CheckedContinuation<Checkin, Error>?

    func checkins() async throws -> [Checkin] {
        try await withCheckedThrowingContinuation { continuation in
            pendingCheckins.append(continuation)
        }
    }

    func update(
        slot: String,
        enabled: Bool,
        deliveryHour: Int,
        deliveryMinute: Int,
        timezone: String
    ) async throws -> Checkin {
        try await withCheckedThrowingContinuation { continuation in
            pendingUpdate = continuation
        }
    }

    func waitForPendingCheckins() async {
        while pendingCheckins.isEmpty { await Task.yield() }
    }

    func waitForPendingUpdate() async {
        while pendingUpdate == nil { await Task.yield() }
    }

    func resumeCheckins(returning value: [Checkin]) {
        pendingCheckins.removeFirst().resume(returning: value)
    }

    func resumeUpdate(returning value: Checkin) {
        pendingUpdate?.resume(returning: value)
        pendingUpdate = nil
    }

    func resumeUpdate(throwing error: Error) {
        pendingUpdate?.resume(throwing: error)
        pendingUpdate = nil
    }
}

private enum TestFailure: Error {
    case expected
}
