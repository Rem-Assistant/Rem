import SwiftUI

/// Renders one `tasks.update` proposal inside a conversation. Pure and presentational — it takes a
/// display item plus approve / dismiss callbacks and owns no networking, so it renders identically
/// from live data, previews, and the `--rem-conversation-proposal-fixture` launch arg, and compiles
/// into both the iOS and macOS targets (Shared/ DRY rule, CLAUDE.md).
///
/// Pending shows the proposed change with Approve / Dismiss; every resolved state
/// (`succeeded` / `failed` / `dismissed` / `stale`) shows a terminal, non-actionable summary.
struct RemProposalCardView: View {
    let item: RemProposalDisplayItem
    var onApprove: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var proposal: ConversationToolProposal { item.proposal }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header
            Text(actionSentence)
                .font(DesignTokens.Typography.subheadline)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let explanation = proposal.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Color.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if item.displayState == .pending {
                actions
            } else {
                terminalSummary
            }

            if let inlineError = item.inlineError, !inlineError.isEmpty {
                Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Color.systemOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DesignTokens.Color.backgroundSecondary,
            in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                .strokeBorder(DesignTokens.Color.separator, lineWidth: 0.5)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "checklist")
                .font(DesignTokens.Typography.subheadline)
                .foregroundStyle(DesignTokens.Color.brandBlue)
            Text(proposal.taskTitle)
                .font(DesignTokens.Typography.bodyBold)
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// "Rem can mark '<title>' as <status>", matching the pending phrasing in the task brief.
    private var actionSentence: String {
        "Rem can mark ‘\(proposal.taskTitle)’ as \(proposal.patch.readableStatus)"
    }

    // MARK: Pending actions

    private var actions: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: onApprove) {
                if item.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Approve")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(item.isBusy)

            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bordered)
                .disabled(item.isBusy)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Terminal summary

    private var terminalSummary: some View {
        Label {
            Text(terminalText)
                .font(DesignTokens.Typography.subheadline)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
        } icon: {
            Image(systemName: terminalIcon)
                .foregroundStyle(terminalTint)
        }
        .accessibilityLabel(terminalText)
    }

    private var terminalText: String {
        switch item.displayState {
        case .succeeded: return "Marked as \(proposal.patch.readableStatus)"
        case .failed: return "Couldn’t apply this change"
        case .dismissed: return "Dismissed"
        case .stale: return "This task changed — ask Rem for a fresh proposal"
        case .pending: return ""
        }
    }

    private var terminalIcon: String {
        switch item.displayState {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .dismissed: return "minus.circle.fill"
        case .stale: return "clock.badge.exclamationmark.fill"
        case .pending: return "circle"
        }
    }

    private var terminalTint: Color {
        switch item.displayState {
        case .succeeded: return DesignTokens.Color.systemGreen
        case .failed: return DesignTokens.Color.systemRed
        case .dismissed: return DesignTokens.Color.labelTertiary
        case .stale: return DesignTokens.Color.systemOrange
        case .pending: return DesignTokens.Color.labelTertiary
        }
    }
}
