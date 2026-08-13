import Foundation
import Testing
@testable import RemClaw

struct ThinkingBlockGroupingTests {
    @Test func singleThoughtDoesNotConsolidate() {
        let group = ThinkingBlockGrouping.group(["Checking the reminders store…"])
        #expect(group.stepCount == 1)
        #expect(group.needsConsolidation == false)
        #expect(group.entries.count == 1)
        #expect(group.entries.first?.occurrences == 1)
    }

    @Test func emptyInputProducesEmptyGroup() {
        let group = ThinkingBlockGrouping.group([])
        #expect(group.isEmpty)
        #expect(group.stepCount == 0)
        #expect(group.needsConsolidation == false)
    }

    @Test func blankThoughtsAreDropped() {
        let group = ThinkingBlockGrouping.group(["   ", "\n", "reminders.add not found"])
        #expect(group.stepCount == 1)
        #expect(group.entries.count == 1)
        #expect(group.entries.first?.text == "reminders.add not found")
    }

    @Test func identicalDiagnosticsFoldIntoOneEntryWithCount() {
        let thoughts = Array(repeating: "reminders.add not found", count: 9)
        let group = ThinkingBlockGrouping.group(thoughts)
        #expect(group.stepCount == 9)
        #expect(group.needsConsolidation)
        #expect(group.entries.count == 1)
        #expect(group.entries.first?.occurrences == 9)
    }

    @Test func dedupeIgnoresWhitespaceAndCase() {
        let thoughts = [
            "reminders.add not found",
            "  Reminders.Add Not Found ",
            "REMINDERS.ADD NOT FOUND"
        ]
        let group = ThinkingBlockGrouping.group(thoughts)
        #expect(group.entries.count == 1)
        #expect(group.entries.first?.occurrences == 3)
        #expect(group.stepCount == 3)
    }

    @Test func mixedRunPreservesFirstAppearanceOrderAndCounts() {
        let thoughts = [
            "Calling reminders.add for book flights…",
            "reminders.add not found",
            "reminders.add not found",
            "Retrying reminders.add for pack bags…",
            "reminders.add not found"
        ]
        let group = ThinkingBlockGrouping.group(thoughts)

        #expect(group.stepCount == 5)
        #expect(group.entries.count == 3)
        #expect(group.entries.map(\.occurrences) == [1, 3, 1])
        #expect(group.entries.first?.text == "Calling reminders.add for book flights…")
        #expect(group.entries.last?.text == "Retrying reminders.add for pack bags…")
    }

    @Test func groupIsValueEquatableForCheapDiffing() {
        let a = ThinkingBlockGrouping.group(["x", "x", "y"])
        let b = ThinkingBlockGrouping.group(["x", "x", "y"])
        #expect(a == b)
    }
}
