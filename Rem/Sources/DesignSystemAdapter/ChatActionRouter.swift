import Foundation
import RemChatUI
import RemDesignSystem
import UIKit

/// Routes the design system's `ChatScreenAction`s to the app's existing calls. It holds no state of
/// its own: every effect is a view-model call or a closure the adapter supplies.
///
/// | Action | App call |
/// |---|---|
/// | `composer(.send)` | `ChatSendCoordinator.prepare` + `dispatch` (the classic chat's send path) |
/// | `composer(.cancel)` | `RemChatViewModel.abort()` |
/// | `composer(.draftChanged)` | `RemChatViewModel.input` |
/// | `composer(.add)` | the adapter's image file importer (`SharedRemChatView.importImageFiles`) |
/// | `composer(.removeAttachment)` | `RemChatViewModel.removeAttachment(_:)` |
/// | `composer(.speak)`, `call` | the existing voice hook (`RemChatView.onVoiceTap`) |
/// | `back` | dismiss |
/// | `starter` | fills the draft and focuses it, as the classic starters do |
/// | `transcript(.requestActions)` | presents `MessageActionSheet` (Reply, Copy, Select Text) |
/// | `transcript(.messageAction)` | Reply quotes into the draft, Copy uses `UIPasteboard`, Select Text opens a selectable view |
/// | `ChatModelMenu` `onSelect` (`selectModel`) | `RemChatViewModel.selectModel(_:)` with the classic picker's selection id (Automatic = `defaultModelSelectionID`) |
/// | `ChatModelMenu` `onManageModels` (`manageModels`) | presents the classic Manage Models sheet (`RemChatView`'s gateway-backed Models destination) |
///
/// The model menu reports through `ChatModelMenu`'s closures, not a `ChatScreenAction` case.
///
/// Not routed (the adapter never offers them): overflow, activity details, reply context, retry,
/// reactions, Mark as unread and Report.
struct ChatActionRouter {
    /// What a message action asks the adapter to present next.
    enum Presentation: Equatable {
        case none
        case selectText(String)
    }

    /// Actions the long-press sheet offers. The app has no reaction, unread or report support.
    static let availableMessageActions: Set<RemDesignSystem.ChatMessageAction> = [.reply, .copy, .selectText]

    let viewModel: RemChatViewModel
    let providerEvidence: RuntimeProviderAuthEvidence
    let hasQuota: () -> Bool
    let consumeSendSlot: (@MainActor () async -> Bool)?
    let onAfterSend: () -> Void
    let onVoice: (() -> Void)?
    let dismiss: () -> Void
    let setFocused: (Bool) -> Void
    let presentAttachmentImporter: () -> Void
    let presentMessageActions: (String) -> Void
    let presentModelSettings: () -> Void
    let starterText: (String) -> String?
    let messageText: (String) -> String?

    func handle(_ action: RemDesignSystem.ChatScreenAction) {
        switch action {
        case .back:
            dismiss()
        case .call:
            onVoice?()
        case .overflow, .activityDetails, .dismissReplyContext:
            // Hidden in phase 1b; nothing to route.
            break
        case .starter(let id):
            guard let text = starterText(id) else { return }
            viewModel.input = text
            setFocused(true)
        case .composer(let composerAction):
            handle(composerAction)
        case .transcript(let transcriptAction):
            if case .requestActions(let messageID) = transcriptAction,
               messageID != ChatDisplayMapper.streamingMessageID,
               messageText(messageID) != nil {
                presentMessageActions(messageID)
            }
        }
    }

    func handle(_ action: RemDesignSystem.ChatComposerAction) {
        switch action {
        case .draftChanged(let text):
            viewModel.input = text
        case .send:
            send()
        case .cancel:
            viewModel.abort()
        case .speak:
            onVoice?()
        case .add:
            presentAttachmentImporter()
        case .removeAttachment(let id):
            guard let attachment = viewModel.attachments.first(where: { $0.id.uuidString == id }) else { return }
            viewModel.removeAttachment(attachment.id)
        case .focusChanged(let focused):
            setFocused(focused)
        }
    }

    /// A model menu choice: the same call the classic picker makes. The view model ignores it while a
    /// send is being prepared or sent, exactly as for the classic picker.
    func selectModel(_ selection: RemDesignSystem.ChatModelSelection) {
        viewModel.selectModel(ChatDisplayMapper.selectionID(for: selection))
    }

    /// The menu's Manage Models row: the classic picker's footer destination.
    func manageModels() {
        presentModelSettings()
    }

    /// Performs a row of the message sheet. The caller dismisses the sheet first and presents what
    /// this returns.
    func perform(_ action: RemDesignSystem.ChatMessageAction, messageID: String) -> Presentation {
        guard Self.availableMessageActions.contains(action), let text = messageText(messageID) else {
            return .none
        }
        switch action {
        case .copy:
            UIPasteboard.general.string = text
            return .none
        case .selectText:
            return .selectText(text)
        case .reply:
            // Ordinary chat has no reply-target API, so Reply quotes the message into the draft:
            // what the person sees in the composer is exactly what will be sent.
            viewModel.input = Self.quotedReplyDraft(quoting: text, existingDraft: viewModel.input)
            setFocused(true)
            return .none
        case .markUnread, .report:
            return .none
        }
    }

    /// `> quoted lines`, a blank line, then any draft already typed.
    static func quotedReplyDraft(quoting text: String, existingDraft: String) -> String {
        let quote = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let draft = existingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty ? "\(quote)\n\n" : "\(quote)\n\n\(draft)"
    }

    /// The classic chat's send path, unchanged. The design-system composer has no Cloud browser chip
    /// yet, so nothing is wrapped in the browser directive.
    private func send() {
        guard let request = ChatSendCoordinator.prepare(
            viewModel: viewModel,
            providerEvidence: providerEvidence,
            browserCapabilityAttached: false,
            hasQuota: hasQuota
        ) else { return }
        ChatSendCoordinator.dispatch(
            request,
            viewModel: viewModel,
            consumeSendSlot: consumeSendSlot
        ) {
            onAfterSend()
        }
    }
}
