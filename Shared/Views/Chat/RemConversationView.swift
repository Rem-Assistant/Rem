import SwiftUI

/// A minimal conversation surface: it lists the turns and inlines a `RemProposalCardView` beneath
/// the assistant message that produced each proposal. Binds to `RemConversationViewModel` for state
/// and actions, so it renders live, in previews, and under the fixture launch arg, and compiles
/// into both platform targets (Shared/ DRY rule, CLAUDE.md). The live gateway routing seam is out
/// of scope here — this view only talks to the view model.
struct RemConversationView: View {
    let viewModel: RemConversationViewModel
    /// Optional composer. Off by default so screenshot fixtures stay static; the app can turn it on.
    var showsComposer: Bool = true

    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if let errorText = viewModel.errorText, !errorText.isEmpty {
                errorBanner(errorText)
            }
            transcript
            if showsComposer {
                composer
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                ForEach(viewModel.messages) { message in
                    messageRow(message)
                    ForEach(viewModel.proposals(for: message.id)) { item in
                        proposalCard(item)
                    }
                }
                ForEach(orphanProposals) { item in
                    proposalCard(item)
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Proposals whose owning assistant message isn't in the current page — rendered at the end so
    /// they never silently disappear.
    private var orphanProposals: [RemProposalDisplayItem] {
        let shown = Set(viewModel.messages.map(\.id))
        return viewModel.proposals.filter { !shown.contains($0.proposal.messageID) }
    }

    private func proposalCard(_ item: RemProposalDisplayItem) -> some View {
        RemProposalCardView(
            item: item,
            onApprove: { Task { await viewModel.approve(item.id) } },
            onDismiss: { Task { await viewModel.dismiss(item.id) } }
        )
    }

    // MARK: Message row

    @ViewBuilder
    private func messageRow(_ message: ConversationMessage) -> some View {
        let isUser = !message.isAssistant
        HStack {
            if isUser { Spacer(minLength: DesignTokens.Spacing.xxl) }
            Text(message.content)
                .font(DesignTokens.Typography.chatMessage)
                .foregroundStyle(isUser ? Color.white : DesignTokens.Color.labelPrimary)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    isUser ? DesignTokens.Color.brandBlue : DesignTokens.Color.backgroundSecondary,
                    in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xlarge, style: .continuous)
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !isUser { Spacer(minLength: DesignTokens.Spacing.xxl) }
        }
    }

    // MARK: Error banner

    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(DesignTokens.Typography.footnote)
            .foregroundStyle(DesignTokens.Color.systemRed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)
            .background(DesignTokens.Color.backgroundSecondary)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Message Rem", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(viewModel.isSending)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                if viewModel.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? DesignTokens.Color.brandBlue : DesignTokens.Color.labelTertiary)
            .disabled(!canSend)
        }
        .padding(DesignTokens.Spacing.md)
    }

    private var canSend: Bool {
        !viewModel.isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await viewModel.send(text) }
    }
}
