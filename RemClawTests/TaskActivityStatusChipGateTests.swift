import Foundation
import Testing
@testable import RemClaw

/// Covers the task-activity status-chip gate (#1367). The autonomous "Applied: <status>"
/// + Undo chip is gated OFF because it surfaced a false applied state ("Applied: Blocked"
/// for a status that was never applied); the human "Proposes: <status>" + Accept path is
/// unaffected.
struct TaskActivityStatusChipGateTests {

    @Test func humanProposalAlwaysShows() {
        #expect(TaskActivityStatusChipGate.showsStatusChip(
            proposedStatus: "in_progress",
            didApplyStatus: false
        ))
    }

    @Test func noStatusNeverShows() {
        #expect(!TaskActivityStatusChipGate.showsStatusChip(
            proposedStatus: nil,
            didApplyStatus: false
        ))
        // Blank / whitespace-only status is treated as no status, even when applied.
        #expect(!TaskActivityStatusChipGate.showsStatusChip(
            proposedStatus: "   ",
            didApplyStatus: true
        ))
    }

    /// The shipped behavior: an autonomously-applied status is HIDDEN rather than shown
    /// with a possibly-false "Applied: …" claim. This is the exact case from the founder's
    /// screenshot ("Applied: Blocked"). If the feature flag is ever flipped back on, this
    /// assertion flips RED — a deliberate guard on the gated state.
    @Test func appliedStatusIsGatedOffToday() {
        #expect(TaskActivityStatusChipGate.appliedStatusChipEnabled == false)
        #expect(!TaskActivityStatusChipGate.showsStatusChip(
            proposedStatus: "blocked",
            didApplyStatus: true
        ))
    }

    /// The gate's decision tracks the flag: whatever `appliedStatusChipEnabled` is, an
    /// applied status renders iff the flag is on. Proves the gate reads the flag rather
    /// than hard-coding `false`.
    @Test func appliedStatusFollowsFeatureFlag() {
        #expect(
            TaskActivityStatusChipGate.showsStatusChip(proposedStatus: "blocked", didApplyStatus: true)
                == TaskActivityStatusChipGate.appliedStatusChipEnabled
        )
    }
}
