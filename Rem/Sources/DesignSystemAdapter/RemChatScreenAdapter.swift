import SwiftUI
import UIKit
import UniformTypeIdentifiers
import RemChatUI
import RemDesignSystem

/// Phase 1b of the design-system adapter: an ordinary chat rendered through the canonical
/// `RemDesignSystem.ChatScreen`, driven by the same `RemChatViewModel` and the same send path as the
/// classic `SharedRemChatView` (`ChatSendCoordinator`). Reached only from `RemChatView` in DEBUG builds
/// launched with `--rem-ds-chat`.
///
/// What the design system does not yet draw stays truthful: tool-result cards render with the app's
/// own `ToolResultCardView`; activity timelines, attachments in sent messages and unknown message
/// kinds show a labelled row that hands the conversation back to the classic chat
/// (`onUseClassicChat`). Receipts are never shown: the app has no delivery or read evidence.
///
/// Design-system types are module-qualified: the app module defines same-named types that shadow
/// imported ones.
struct RemChatScreenAdapter: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: RemChatViewModel
    let providerEvidence: RuntimeProviderAuthEvidence
    let connectionState: GatewayConnectionState
    let runtimeOwnsConversation: Bool
    let isFreshConversation: Bool
    let initialExistingSessionTitle: String?
    let requestedSessionKey: String?
    let starters: [SharedRemChatView.FirstChatPrompt]
    let hasQuota: () -> Bool
    let quotaReason: String?
    let consumeSendSlot: (@MainActor () async -> Bool)?
    let onAfterSend: () -> Void
    /// The existing voice entry (`RemChatView.onVoiceTap`); nil when voice cannot start here.
    let onVoice: (() -> Void)?
    /// Switches this conversation back to the classic chat surface.
    let onUseClassicChat: () -> Void

    @State private var isComposerFocused = false
    @State private var showsFileImporter = false
    @State private var actionsTarget: MessageActionsTarget?
    @State private var pendingPresentation: ChatActionRouter.Presentation = .none
    @State private var selectedText: SelectedTextItem?
    /// Mirrors the classic chat's first-load gate: set once the requested session's history settled.
    @State private var completedInitialHistoryLoad = false

    private struct MessageActionsTarget: Identifiable {
        let id: String
    }

    private struct SelectedTextItem: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        let transcript: ChatTranscriptDisplay = ChatDisplayMapper.transcript(
            messages: viewModel.messages,
            pendingRunCount: viewModel.pendingRunCount,
            streamingAssistantText: viewModel.streamingAssistantText,
            errorText: viewModel.errorText
        )
        let historyPending: Bool = isHistoryPending
        // Never paint the conversation being left while a fresh one binds.
        let hidesTranscript: Bool = historyPending || isFreshInitialLoadInFlight
        let shownEntries: [RemDesignSystem.ChatTranscriptEntry] = hidesTranscript ? [] : transcript.entries
        let voiceAvailable: Bool = onVoice != nil && hasQuota()
        let router: ChatActionRouter = makeRouter(transcript: transcript)
        let header: RemDesignSystem.ChatHeaderDisplay = ChatDisplayMapper.header(
            connectionState: connectionState,
            runtimeOwnsConversation: runtimeOwnsConversation,
            pendingRunCount: viewModel.pendingRunCount,
            voiceAvailable: voiceAvailable
        )
        let composer: RemDesignSystem.ChatComposerState = ChatDisplayMapper.composer(
            draft: viewModel.input,
            attachments: viewModel.attachments,
            availability: ChatDisplayMapper.availability(
                hasQuota: hasQuota(),
                quotaReason: quotaReason,
                isPreparingSend: viewModel.isPreparingSend,
                awaitingProviderEvidence: isAwaitingProviderEvidence
            ),
            phase: ChatDisplayMapper.phase(
                pendingRunCount: viewModel.pendingRunCount,
                streamingAssistantText: viewModel.streamingAssistantText
            ),
            voiceAvailable: voiceAvailable,
            isFocused: isComposerFocused
        )
        let emptyState: RemDesignSystem.ChatEmptyState? = ChatDisplayMapper.emptyState(
            transcriptIsEmpty: shownEntries.isEmpty,
            isHistoryPending: historyPending,
            hasPendingDraft: !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            starters: starters
        )

        RemDesignSystem.ChatScreen(
            header: header,
            composer: composer,
            emptyState: emptyState,
            onAction: { (action: RemDesignSystem.ChatScreenAction) in router.handle(action) }
        ) {
            if historyPending {
                historyLoadingView
            } else {
                RemDesignSystem.ChatTranscriptList(
                    shownEntries,
                    onAction: { router.handle(RemDesignSystem.ChatScreenAction.transcript($0)) },
                    hostContent: { id in AnyView(hostView(transcript.hostContent[id])) }
                )
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            SharedRemChatView.importImageFiles(urls, into: viewModel)
        }
        .sheet(item: $actionsTarget, onDismiss: presentPendingAfterActions) { target in
            messageActionsSheet(target: target, transcript: transcript, router: router)
        }
        .sheet(item: $selectedText) { item in
            SelectableMessageText(text: item.text)
                .padding(RemDesignSystem.DesignTokens.Spacing.lg)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: viewModel.isLoading) { wasLoading, isLoading in
            if wasLoading, !isLoading, isShowingRequestedSession {
                completedInitialHistoryLoad = true
            }
        }
        .task(id: viewModel.sessionKey) {
            // Bounded fallback, as in the classic chat: an empty load with no observable loading
            // transition must not leave the loading view up indefinitely.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, isShowingRequestedSession, !viewModel.isLoading else { return }
            completedInitialHistoryLoad = true
        }
    }

    // MARK: Routing

    private func makeRouter(transcript: ChatTranscriptDisplay) -> ChatActionRouter {
        ChatActionRouter(
            viewModel: viewModel,
            providerEvidence: providerEvidence,
            hasQuota: hasQuota,
            consumeSendSlot: consumeSendSlot,
            onAfterSend: onAfterSend,
            onVoice: onVoice,
            dismiss: { dismiss() },
            setFocused: { isComposerFocused = $0 },
            presentAttachmentImporter: { showsFileImporter = true },
            presentMessageActions: { actionsTarget = MessageActionsTarget(id: $0) },
            starterText: { id in starters.first(where: { $0.id == id })?.text },
            messageText: { id in transcript.message(id: id)?.text }
        )
    }

    @ViewBuilder
    private func messageActionsSheet(
        target: MessageActionsTarget,
        transcript: ChatTranscriptDisplay,
        router: ChatActionRouter
    ) -> some View {
        if let message = transcript.message(id: target.id) {
            RemDesignSystem.MessageActionSheet(
                RemDesignSystem.ChatMessageActionsDisplay(
                    message: message,
                    available: ChatActionRouter.availableMessageActions,
                    // The app has no reactions: no grid, no `+` cell.
                    reactions: [],
                    showsMoreReactions: false
                )
            ) { action in
                if case .messageAction(let messageID, let messageAction) = action {
                    pendingPresentation = router.perform(messageAction, messageID: messageID)
                }
                actionsTarget = nil
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func presentPendingAfterActions() {
        if case .selectText(let text) = pendingPresentation {
            selectedText = SelectedTextItem(text: text)
        }
        pendingPresentation = .none
    }

    // MARK: State

    private var isAwaitingProviderEvidence: Bool {
        let selectionID = ChatSendCoordinator.effectiveModelSelectionID(
            viewModel: viewModel,
            providerEvidence: providerEvidence
        )
        return selectionID != RemChatViewModel.defaultModelSelectionID
            && !providerEvidence.canReconcileExplicitSelection(selectionID)
    }

    private var isShowingRequestedSession: Bool {
        guard let requested = requestedSessionKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty
        else { return true }
        return requested == viewModel.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isHistoryPending: Bool {
        ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: isFreshConversation,
            initialExistingSessionTitle: initialExistingSessionTitle,
            requestedSessionKey: requestedSessionKey,
            currentSessionKey: viewModel.sessionKey,
            messagesEmpty: viewModel.messages.isEmpty,
            isLoading: viewModel.isLoading,
            completedInitialHistoryLoad: completedInitialHistoryLoad
        )
    }

    private var isFreshInitialLoadInFlight: Bool {
        isFreshConversation && !completedInitialHistoryLoad
            && (!isShowingRequestedSession || viewModel.isLoading)
    }

    // MARK: Host content

    private var historyLoadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, RemDesignSystem.DesignTokens.Spacing.lg)
            .accessibilityLabel("Loading conversation")
            .accessibilityIdentifier("designSystem.chat.loading")
    }

    @ViewBuilder
    private func hostView(_ content: ChatHostContent?) -> some View {
        switch content {
        case .toolResult(let messageID, let contentIndexes)?:
            if let message = viewModel.messages.first(where: { $0.id == messageID }) {
                ToolResultCardView(
                    message: message,
                    messages: viewModel.messages,
                    contentIndexes: contentIndexes
                )
            }
        case .activity?:
            classicFallback("Activity for this turn")
        case .messageExtras(_, let attachmentCount, let toolResultCount)?:
            classicFallback(Self.extrasTitle(attachmentCount: attachmentCount, toolResultCount: toolResultCount))
        case .unsupportedMessage?:
            classicFallback("This message")
        case .liveActivity?:
            HStack(spacing: RemDesignSystem.DesignTokens.Spacing.sm) {
                ProgressView()
                Text("Working")
                    .font(RemDesignSystem.DesignTokens.Typography.footnote)
                    .foregroundStyle(RemDesignSystem.DesignTokens.Color.labelSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("designSystem.chat.working")
        case .error(let text)?:
            Text(text)
                .font(RemDesignSystem.DesignTokens.Typography.footnote)
                .foregroundStyle(RemDesignSystem.DesignTokens.Color.systemRed)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("designSystem.chat.error")
        case nil:
            EmptyView()
        }
    }

    private static func extrasTitle(attachmentCount: Int, toolResultCount: Int) -> String {
        switch (attachmentCount > 0, toolResultCount > 0) {
        case (true, true): return "Attachments and results"
        case (true, false): return attachmentCount == 1 ? "An attachment" : "Attachments"
        default: return toolResultCount == 1 ? "A result" : "Results"
        }
    }

    /// A clearly labelled gap: the classic chat renders this part; nothing is invented here.
    private func classicFallback(_ subject: String) -> some View {
        HStack(spacing: RemDesignSystem.DesignTokens.Spacing.sm) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(RemDesignSystem.DesignTokens.Color.labelSecondary)
                .accessibilityHidden(true)
            Text("\(subject) is shown in the classic chat.")
                .font(RemDesignSystem.DesignTokens.Typography.footnote)
                .foregroundStyle(RemDesignSystem.DesignTokens.Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: RemDesignSystem.DesignTokens.Spacing.sm)
            Button("Open classic chat", action: onUseClassicChat)
                .font(RemDesignSystem.DesignTokens.Typography.footnote.weight(.semibold))
                .foregroundStyle(RemDesignSystem.DesignTokens.Color.brandBlue)
                .buttonStyle(.plain)
                .accessibilityIdentifier("designSystem.chat.openClassic")
        }
        .padding(RemDesignSystem.DesignTokens.Spacing.md)
        .background(
            RemDesignSystem.DesignTokens.Color.backgroundSecondary,
            in: RoundedRectangle(cornerRadius: RemDesignSystem.DesignTokens.CornerRadius.medium, style: .continuous)
        )
    }
}

/// Read-only, selectable message text for the sheet's Select Text row. SwiftUI's `textSelection`
/// only copies whole views on iOS; a non-editable `UITextView` gives range selection.
private struct SelectableMessageText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.accessibilityIdentifier = "designSystem.chat.selectText"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
