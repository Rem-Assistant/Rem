import Foundation
import RemChatUI
import RemDesignSystem

/// A transcript position the design system leaves to the app (`ChatTranscriptEntry.hostContent`).
/// `RemChatScreenAdapter` renders each case; the mapper only decides what goes where.
/// `nonisolated` (the app module defaults to `@MainActor`) so its `Equatable` conformance is usable
/// from any context, including test expectations.
nonisolated enum ChatHostContent: Equatable {
    /// A tool-result message with cards the classic chat shows on their own. Rendered with the app's
    /// existing `ToolResultCardView`, limited to `contentIndexes` exactly as `SharedRemChatView` does.
    case toolResult(messageID: UUID, contentIndexes: Set<Int>)
    /// Thinking, tool calls and folded tool results of consecutive messages. The classic chat groups
    /// these into one activity timeline per turn; the adapter does not reproduce it yet and shows a
    /// labelled hand-back to the classic chat instead.
    case activity(messageIDs: [UUID])
    /// Attachments or inline tool payloads carried by a user or assistant message. Classic only.
    case messageExtras(messageID: UUID, attachmentCount: Int, toolResultCount: Int)
    /// A message whose role is neither user, assistant nor tool result. Classic only.
    case unsupportedMessage(messageID: UUID)
    /// A run is in flight (`pendingRunCount > 0`).
    case liveActivity
    /// The view model's current error text.
    case error(String)
}

/// The mapped transcript: entries in transcript order plus what each host-content id stands for.
struct ChatTranscriptDisplay {
    var entries: [RemDesignSystem.ChatTranscriptEntry]
    var hostContent: [String: ChatHostContent]

    /// The mapped message for `id`, if the transcript shows one.
    func message(id: String) -> RemDesignSystem.ChatMessageDisplay? {
        for entry in entries {
            if case .message(let message) = entry, message.id == id { return message }
        }
        return nil
    }
}

/// Pure functions from the app's chat state to the design system's display values. No effects and no
/// state: `RemChatScreenAdapter` reads the view model and passes plain values in.
///
/// Truth rules (`docs/contracts/chat-adapter.md` in Rem-Design-System):
/// - `delivery` is always `.none`. The app has no durable acceptance or read evidence for a message,
///   and the contract forbids inferring one (for example from a reply appearing).
/// - `time` is the message's own timestamp, formatted here by the host. No timestamp, no time.
/// - Only user and assistant prose becomes a message bubble, cleaned with the app's existing
///   `MessageCleaner` via `SharedRemChatView.splitContent`. Everything else becomes host content in
///   transcript order.
enum ChatDisplayMapper {
    /// The id of the in-flight streamed assistant bubble. It is not a stored message, so it offers no
    /// message actions.
    static let streamingMessageID = "streaming"
    static let liveActivityID = "live-activity"
    static let errorID = "error"

    static let emptyStateTitle = "Start a conversation"
    static let preparingSendReason = "Sending your message…"
    static let providerEvidenceReason = "Checking which models you can use…"
    static let quotaFallbackReason = "You've reached your message limit."

    // MARK: Header

    /// Header for an ordinary chat. `activity` is agent-lifecycle copy: Working while a run is in
    /// flight, otherwise the gateway's short status. `needsYou` only when the device must be
    /// re-approved. Overflow and activity details are hidden: phase 1b routes neither. The call entry
    /// appears only when the app can start in-app voice.
    static func header(
        connectionState: GatewayConnectionState,
        runtimeOwnsConversation: Bool,
        pendingRunCount: Int,
        voiceAvailable: Bool
    ) -> RemDesignSystem.ChatHeaderDisplay {
        let isWorking = pendingRunCount > 0
        let activity: String
        if isWorking {
            activity = "Working"
        } else if runtimeOwnsConversation {
            activity = GatewayConnectionState.connected.shortStatusText
        } else {
            activity = connectionState.shortStatusText
        }
        return RemDesignSystem.ChatHeaderDisplay(
            name: "Rem",
            activity: activity,
            status: connectionState.needsDeviceRePair && !runtimeOwnsConversation ? .needsYou : .connected,
            isWorking: isWorking,
            showsBack: true,
            showsOverflow: false,
            showsActivityDetails: false,
            showsCall: voiceAvailable
        )
    }

    // MARK: Composer

    /// Idle, sending (a run exists, no reply text yet) or streaming (reply text is arriving). The
    /// model-repair and quota window before a run exists is not a phase: there is nothing to cancel
    /// yet, so `availability(…)` disables input instead of showing Stop.
    static func phase(
        pendingRunCount: Int,
        streamingAssistantText: String?
    ) -> RemDesignSystem.ComposerPhase {
        guard pendingRunCount > 0 else { return .idle }
        let streamed = streamingAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return streamed.isEmpty ? .sending : .streaming
    }

    /// Disabled, with the reason, when quota is denied, a send is being prepared, or an explicit model
    /// choice is waiting for provider evidence (the same gate `ChatSendCoordinator` applies).
    static func availability(
        hasQuota: Bool,
        quotaReason: String?,
        isPreparingSend: Bool,
        awaitingProviderEvidence: Bool
    ) -> RemDesignSystem.ComposerAvailability {
        if !hasQuota {
            let reason = quotaReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .disabled(reason: (reason?.isEmpty == false ? reason : nil) ?? quotaFallbackReason)
        }
        if isPreparingSend { return .disabled(reason: preparingSendReason) }
        if awaitingProviderEvidence { return .disabled(reason: providerEvidenceReason) }
        return .enabled
    }

    /// Pending attachments as composer chips. Image MIME types are images; everything else is a file.
    /// The id is the attachment's UUID string, so `.removeAttachment(id:)` maps straight back.
    static func attachments(_ attachments: [RemPendingAttachment]) -> [RemDesignSystem.ComposerAttachment] {
        attachments.map { attachment in
            RemDesignSystem.ComposerAttachment(
                id: attachment.id.uuidString,
                title: attachment.fileName,
                kind: attachment.mimeType.lowercased().hasPrefix("image/") ? .image : .file
            )
        }
    }

    static func composer(
        draft: String,
        attachments: [RemPendingAttachment],
        availability: RemDesignSystem.ComposerAvailability,
        phase: RemDesignSystem.ComposerPhase,
        voiceAvailable: Bool,
        isFocused: Bool
    ) -> RemDesignSystem.ChatComposerState {
        RemDesignSystem.ChatComposerState(
            draft: draft,
            placeholder: "Ask anything",
            // Phase 1c adds the model menu. Until then the model is not shown, rather than shown as
            // a control that does nothing; sends still use the view model's selection.
            modelLabel: "Auto",
            attachments: Self.attachments(attachments),
            availability: availability,
            phase: phase,
            showsModel: false,
            voiceAvailable: voiceAvailable,
            isFocused: isFocused
        )
    }

    // MARK: Empty state

    /// The empty conversation, or nil while there is anything to show, history is still loading, or
    /// the composer already holds a draft (intent is stated; starters would be noise, as in
    /// `ChatEmptyStateGate`).
    static func emptyState(
        transcriptIsEmpty: Bool,
        isHistoryPending: Bool,
        hasPendingDraft: Bool,
        starters: [SharedRemChatView.FirstChatPrompt]
    ) -> RemDesignSystem.ChatEmptyState? {
        guard transcriptIsEmpty, !isHistoryPending, !hasPendingDraft else { return nil }
        return RemDesignSystem.ChatEmptyState(
            title: emptyStateTitle,
            message: starters.isEmpty
                ? SharedRemChatView.emptyStateSubtitlePlain
                : SharedRemChatView.emptyStateSubtitleWithStarters,
            starters: starters.map { RemDesignSystem.ChatStarter(id: $0.id, title: $0.text) }
        )
    }

    // MARK: Transcript

    /// Short local time for a message timestamp, e.g. "10:24".
    static func defaultTimeFormatter(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Maps the view model's messages, in order. Day separators come from the classic chat's
    /// `separatorLabels`; the optimistic/echo collapse from its `visibleMessages(from:)`.
    static func transcript(
        messages: [RemChatMessage],
        pendingRunCount: Int,
        streamingAssistantText: String?,
        errorText: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        formatTime: (Date) -> String = ChatDisplayMapper.defaultTimeFormatter
    ) -> ChatTranscriptDisplay {
        var display = ChatTranscriptDisplay(entries: [], hostContent: [:])
        let visible = SharedRemChatView.visibleMessages(from: messages)
        let separators = SharedRemChatView.separatorLabels(
            in: visible,
            briefPreviewInsertionIndex: nil,
            now: now,
            calendar: calendar,
            locale: locale
        )

        func appendHost(_ id: String, _ content: ChatHostContent) {
            display.entries.append(.hostContent(id: id))
            display.hostContent[id] = content
        }

        /// Consecutive activity collapses into one entry, as the classic chat shows one per turn.
        func appendActivity(_ messageID: UUID) {
            if case .hostContent(let lastID)? = display.entries.last,
               case .activity(let ids)? = display.hostContent[lastID] {
                display.hostContent[lastID] = .activity(messageIDs: ids + [messageID])
                return
            }
            appendHost("activity.\(messageID.uuidString)", .activity(messageIDs: [messageID]))
        }

        for (index, message) in visible.enumerated() {
            if let label = separators[index] {
                display.entries.append(.timestamp(id: "separator.\(message.id.uuidString)", text: label))
            }

            if SharedRemChatView.isToolResultRole(message.role) {
                let indexes = SharedRemChatView.standaloneToolResultContentIndexes(message)
                if indexes.isEmpty {
                    appendActivity(message.id)
                } else {
                    appendHost(
                        "tool-result.\(message.id.uuidString)",
                        .toolResult(messageID: message.id, contentIndexes: indexes)
                    )
                }
                continue
            }

            let role: RemDesignSystem.MessageBubble.Role
            switch message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "user": role = .user
            case "assistant", "model": role = .assistant
            default:
                appendHost("unsupported.\(message.id.uuidString)", .unsupportedMessage(messageID: message.id))
                continue
            }
            let isUser = role == .user
            let parts = SharedRemChatView.splitContent(message.content, isUser: isUser)

            if !parts.thinking.isEmpty || !parts.toolCalls.isEmpty {
                appendActivity(message.id)
            }

            // Same rule as the classic row: an image-only user send synthesizes "See attached.".
            let textBlocks = isUser && !parts.attachments.isEmpty
                ? parts.textBlocks.filter { !SharedRemChatView.isSyntheticAttachmentPlaceholder($0) }
                : parts.textBlocks
            let text = textBlocks.joined(separator: "\n\n")
            if !text.isEmpty {
                let usedCloudBrowser = isUser
                    && message.content.contains { BrowserDirective.isChipSend($0.text ?? "") }
                display.entries.append(.message(RemDesignSystem.ChatMessageDisplay(
                    id: message.id.uuidString,
                    role: role,
                    text: text,
                    meta: usedCloudBrowser ? "Cloud browser" : nil,
                    // No acceptance or read evidence exists in the app: never a receipt.
                    delivery: .none,
                    canRetry: false,
                    time: ChatTimeSeparatorPolicy.date(from: message.timestamp).map(formatTime)
                )))
            }

            if !parts.attachments.isEmpty || !parts.jsonToolResults.isEmpty {
                appendHost(
                    "extras.\(message.id.uuidString)",
                    .messageExtras(
                        messageID: message.id,
                        attachmentCount: parts.attachments.count,
                        toolResultCount: parts.jsonToolResults.count
                    )
                )
            }
        }

        if pendingRunCount > 0 {
            appendHost(liveActivityID, .liveActivity)
            let streamed = MessageCleaner.cleanStreamingAssistantMessageText(streamingAssistantText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !streamed.isEmpty {
                display.entries.append(.message(RemDesignSystem.ChatMessageDisplay(
                    id: streamingMessageID,
                    role: .assistant,
                    text: streamed
                )))
            }
        }

        if let errorText = errorText?.trimmingCharacters(in: .whitespacesAndNewlines), !errorText.isEmpty {
            appendHost(errorID, .error(errorText))
        }

        return display
    }
}
