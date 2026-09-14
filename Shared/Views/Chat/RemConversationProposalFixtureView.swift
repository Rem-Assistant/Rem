import SwiftUI

#if DEBUG
/// Auth-free proof of the conversation + task-proposal surface. Reachable via
/// `--rem-conversation-proposal-fixture` — no gateway, no sign-in, no live networking. It seeds a
/// `RemConversationViewModel` (backed by the no-network `PreviewConversationApiService`) with one
/// canned proposal in EACH lifecycle state so `RemConversationView` and its inlined
/// `RemProposalCardView`s can be screenshotted headlessly:
///
/// - `pending` (idle) — Approve / Dismiss
/// - `pending` (busy) — in-flight spinner
/// - `succeeded` — terminal "Marked as …"
/// - `failed` — terminal + inline error
/// - `dismissed` — terminal
/// - `stale` — client-only terminal state after a 409 `task_changed`
struct RemConversationProposalFixtureView: View {
    @State private var viewModel = RemConversationProposalFixtureView.makeViewModel()

    var body: some View {
        RemConversationView(viewModel: viewModel, showsComposer: false)
    }

    private static func makeViewModel() -> RemConversationViewModel {
        RemConversationViewModel(
            conversationId: "fixture",
            service: PreviewConversationApiService(),
            seededMessages: messages,
            seededProposals: proposals
        )
    }

    private static let messages: [ConversationMessage] = [
        ConversationMessage(id: "u1", role: "user", content: "Can you tidy up my tasks for today?", runID: nil, createdAt: "2026-09-06T09:00:00.000Z"),
        ConversationMessage(id: "a1", role: "assistant", content: "Here are the changes I can make. Review each one:", runID: "r1", createdAt: "2026-09-06T09:00:01.000Z"),
        ConversationMessage(id: "a2", role: "assistant", content: "And a few I already tried to apply:", runID: "r2", createdAt: "2026-09-06T09:00:02.000Z"),
    ]

    private static let proposals: [RemProposalDisplayItem] = [
        RemProposalDisplayItem(
            proposal: proposal(id: "p1", messageID: "a1", title: "Finish the launch checklist", status: "completed", state: .pending, explanation: "You said this is done.")
        ),
        RemProposalDisplayItem(
            proposal: proposal(id: "p2", messageID: "a1", title: "Draft the retro notes", status: "in_progress", state: .pending, explanation: nil),
            isBusy: true
        ),
        RemProposalDisplayItem(
            proposal: proposal(id: "p3", messageID: "a1", title: "Book the team offsite", status: "blocked", state: .succeeded, explanation: "Waiting on venue confirmation.")
        ),
        RemProposalDisplayItem(
            proposal: proposal(id: "p4", messageID: "a2", title: "Send the investor update", status: "completed", state: .failed, explanation: nil, failureCode: "task_status_changed"),
            inlineError: "This task can no longer be applied."
        ),
        RemProposalDisplayItem(
            proposal: proposal(id: "p5", messageID: "a2", title: "Review the pull requests", status: "completed", state: .dismissed, explanation: nil)
        ),
        RemProposalDisplayItem(
            proposal: proposal(id: "p6", messageID: "a2", title: "Reply to Ada about the date", status: "in_progress", state: .pending, explanation: nil),
            displayState: .stale
        ),
    ]

    private static func proposal(
        id: String,
        messageID: String,
        title: String,
        status: String,
        state: ProposalState,
        explanation: String?,
        failureCode: String? = nil
    ) -> ConversationToolProposal {
        ConversationToolProposal(
            id: id,
            messageID: messageID,
            taskID: "task-\(id)",
            taskTitle: title,
            patch: ProposalPatch(status: status),
            explanation: explanation,
            state: state,
            effectID: state == .succeeded ? "effect-\(id)" : nil,
            failureCode: failureCode,
            createdAt: "2026-09-06T09:00:01.000Z",
            updatedAt: "2026-09-06T09:00:03.000Z",
            resolvedAt: state.isTerminal ? "2026-09-06T09:00:03.000Z" : nil
        )
    }
}
#endif
