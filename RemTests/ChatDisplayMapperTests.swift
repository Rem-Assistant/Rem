import Foundation
import RemChatUI
import RemDesignSystem
import Testing
@testable import Rem

/// Covers the design-system Chat adapter's pure mapping (`Rem/Sources/DesignSystemAdapter/`):
/// receipts are never inferred, the composer phase follows the run lifecycle, attachments keep their
/// ids and kinds, and non-prose content stays in transcript order as host content.
@MainActor
struct ChatDisplayMapperTests {
    // MARK: Fixtures

    private func text(_ value: String) -> RemChatMessageContent {
        RemChatMessageContent(type: "text", text: value, mimeType: nil, fileName: nil, content: nil)
    }

    private func message(
        _ role: String,
        _ content: [RemChatMessageContent],
        timestamp: Double? = nil
    ) -> RemChatMessage {
        RemChatMessage(role: role, content: content, timestamp: timestamp)
    }

    private func transcript(
        _ messages: [RemChatMessage],
        pendingRunCount: Int = 0,
        streaming: String? = nil,
        errorText: String? = nil
    ) -> ChatTranscriptDisplay {
        ChatDisplayMapper.transcript(
            messages: messages,
            pendingRunCount: pendingRunCount,
            streamingAssistantText: streaming,
            errorText: errorText,
            formatTime: { _ in "10:24" }
        )
    }

    private func messages(in display: ChatTranscriptDisplay) -> [RemDesignSystem.ChatMessageDisplay] {
        display.entries.compactMap { entry in
            if case .message(let message) = entry { return message }
            return nil
        }
    }

    /// Entry kinds without day separators, which depend on the clock.
    private func kinds(_ display: ChatTranscriptDisplay) -> [String] {
        display.entries.compactMap { entry in
            switch entry {
            case .message(let message): return "message:\(message.role == .user ? "user" : "assistant")"
            case .hostContent(let id): return "host:\(id)"
            case .timestamp: return nil
            }
        }
    }

    // MARK: Receipts

    @Test func receiptsAreAlwaysNone() {
        let display = transcript([
            message("user", [text("Plan my day")], timestamp: 1_700_000_000_000),
            message("assistant", [text("Here is your plan.")], timestamp: 1_700_000_005_000),
            message("user", [text("Thanks")], timestamp: 1_700_000_010_000),
        ])

        let mapped = messages(in: display)
        #expect(mapped.count == 3)
        #expect(mapped.allSatisfy { $0.delivery == .none })
        #expect(mapped.allSatisfy { !$0.canRetry })
        // The design system's placement rule cannot surface a receipt the adapter never supplied.
        let latest = RemDesignSystem.ChatTranscriptRules.latestOutgoingID(in: display.entries)
        for message in mapped {
            #expect(RemDesignSystem.ChatTranscriptRules.displayedDelivery(
                for: message, latestOutgoingID: latest) == .none)
        }
    }

    @Test func messageTimeComesFromItsOwnTimestamp() {
        var formatted: [Date] = []
        let display = ChatDisplayMapper.transcript(
            messages: [
                message("user", [text("With time")], timestamp: 1_700_000_000_000),
                message("assistant", [text("No time")]),
            ],
            pendingRunCount: 0,
            streamingAssistantText: nil,
            errorText: nil,
            formatTime: { date in
                formatted.append(date)
                return "10:24"
            }
        )

        let mapped = messages(in: display)
        #expect(mapped.map(\.time) == ["10:24", nil])
        #expect(formatted == [Date(timeIntervalSince1970: 1_700_000_000)])
    }

    // MARK: Phase and availability

    @Test func phaseFollowsTheRunLifecycle() {
        #expect(ChatDisplayMapper.phase(pendingRunCount: 0, streamingAssistantText: nil) == .idle)
        #expect(ChatDisplayMapper.phase(pendingRunCount: 0, streamingAssistantText: "stale") == .idle)
        #expect(ChatDisplayMapper.phase(pendingRunCount: 1, streamingAssistantText: nil) == .sending)
        #expect(ChatDisplayMapper.phase(pendingRunCount: 1, streamingAssistantText: "  \n") == .sending)
        #expect(ChatDisplayMapper.phase(pendingRunCount: 2, streamingAssistantText: "Hello") == .streaming)
    }

    @Test func availabilityIsDisabledWithAReason() {
        #expect(ChatDisplayMapper.availability(
            hasQuota: false, quotaReason: "Daily limit reached.",
            isPreparingSend: false, awaitingProviderEvidence: false
        ) == .disabled(reason: "Daily limit reached."))
        #expect(ChatDisplayMapper.availability(
            hasQuota: false, quotaReason: "  ",
            isPreparingSend: false, awaitingProviderEvidence: false
        ) == .disabled(reason: ChatDisplayMapper.quotaFallbackReason))
        #expect(ChatDisplayMapper.availability(
            hasQuota: true, quotaReason: nil,
            isPreparingSend: true, awaitingProviderEvidence: false
        ) == .disabled(reason: ChatDisplayMapper.preparingSendReason))
        #expect(ChatDisplayMapper.availability(
            hasQuota: true, quotaReason: nil,
            isPreparingSend: false, awaitingProviderEvidence: true
        ) == .disabled(reason: ChatDisplayMapper.providerEvidenceReason))
        #expect(ChatDisplayMapper.availability(
            hasQuota: true, quotaReason: nil,
            isPreparingSend: false, awaitingProviderEvidence: false
        ) == .enabled)
    }

    @Test func disabledComposerCannotSendButAnInFlightTurnCanStillCancel() {
        let composer = ChatDisplayMapper.composer(
            draft: "Hello",
            attachments: [],
            availability: .disabled(reason: "Daily limit reached."),
            phase: .sending,
            model: hiddenModelMenu,
            voiceAvailable: true,
            isFocused: false
        )
        #expect(!composer.canSend)
        #expect(composer.canCancel)
        #expect(composer.primaryAction == .cancel)
        #expect(!composer.showsSpeak)
    }

    // MARK: Attachments

    @Test func attachmentsKeepTheirIdsAndKinds() {
        let photo = RemPendingAttachment(
            url: nil, data: Data(), fileName: "photo.jpg", mimeType: "image/jpeg", preview: nil)
        let document = RemPendingAttachment(
            url: nil, data: Data(), fileName: "notes.pdf", mimeType: "application/pdf", preview: nil)

        let mapped = ChatDisplayMapper.attachments([photo, document])

        #expect(mapped == [
            RemDesignSystem.ComposerAttachment(id: photo.id.uuidString, title: "photo.jpg", kind: .image),
            RemDesignSystem.ComposerAttachment(id: document.id.uuidString, title: "notes.pdf", kind: .file),
        ])
        let composer = ChatDisplayMapper.composer(
            draft: "", attachments: [photo], availability: .enabled, phase: .idle,
            model: hiddenModelMenu, voiceAvailable: false, isFocused: false)
        // A content attachment makes a message on its own.
        #expect(composer.hasContentAttachments)
        #expect(composer.canSend)
    }

    // MARK: Host content ordering

    @Test func nonProseContentBecomesHostContentInTranscriptOrder() {
        let toolCall = RemChatMessageContent(
            type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil, name: "calendar")
        let attachment = RemChatMessageContent(
            type: "file", text: nil, mimeType: "image/png", fileName: "a.png", content: nil)
        let user1 = message("user", [text("Plan my day")])
        let assistant1 = message("assistant", [toolCall, text("Here is your plan.")])
        let toolResult = message("toolResult", [text("plain output")])
        let user2 = message("user", [text("See attached."), attachment])
        let assistant2 = message("assistant", [text("Done.")])

        let display = transcript([user1, assistant1, toolResult, user2, assistant2])
        let entryKinds = kinds(display)

        #expect(entryKinds.count == 6)
        guard entryKinds.count == 6 else { return }
        #expect(entryKinds[0] == "message:user")
        #expect(entryKinds[1] == "host:activity.\(assistant1.id.uuidString)")
        #expect(entryKinds[2] == "message:assistant")
        // A tool result is a card or folded activity, depending on its payload; either way host content.
        #expect(entryKinds[3].hasPrefix("host:") && entryKinds[3].hasSuffix(toolResult.id.uuidString))
        // The synthesized "See attached." body is not shown; the attachment is host content.
        #expect(entryKinds[4] == "host:extras.\(user2.id.uuidString)")
        #expect(entryKinds[5] == "message:assistant")
        #expect(display.hostContent["extras.\(user2.id.uuidString)"]
            == .messageExtras(messageID: user2.id, attachmentCount: 1, toolResultCount: 0))
        #expect(display.hostContent["activity.\(assistant1.id.uuidString)"]
            == .activity(messageIDs: [assistant1.id]))
        // Every host-content entry resolves to something the adapter can render.
        for entry in display.entries {
            if case .hostContent(let id) = entry { #expect(display.hostContent[id] != nil) }
        }
    }

    @Test func consecutiveActivityCollapsesIntoOneEntry() {
        let calendarCall = RemChatMessageContent(
            type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil, name: "calendar")
        let remindersCall = RemChatMessageContent(
            type: "toolCall", text: nil, mimeType: nil, fileName: nil, content: nil, name: "reminders")
        let first = message("assistant", [calendarCall])
        let second = message("assistant", [remindersCall])

        let display = transcript([first, second])

        #expect(kinds(display) == ["host:activity.\(first.id.uuidString)"])
        #expect(display.hostContent["activity.\(first.id.uuidString)"]
            == .activity(messageIDs: [first.id, second.id]))
    }

    @Test func liveRunAndErrorFollowTheTranscript() {
        let user = message("user", [text("Plan my day")])
        let display = transcript([user], pendingRunCount: 1, streaming: "Working on it", errorText: "Something failed")

        #expect(kinds(display) == [
            "message:user",
            "host:\(ChatDisplayMapper.liveActivityID)",
            "message:assistant",
            "host:\(ChatDisplayMapper.errorID)",
        ])
        let streamed = messages(in: display).last
        #expect(streamed?.id == ChatDisplayMapper.streamingMessageID)
        #expect(streamed?.delivery == RemDesignSystem.MessageBubble.Delivery.none)
        #expect(display.hostContent[ChatDisplayMapper.errorID] == .error("Something failed"))
    }

    // MARK: Header and empty state

    @Test func headerReportsWorkAndOffersCallOnlyWithVoice() {
        let working = ChatDisplayMapper.header(
            connectionState: .connected, runtimeOwnsConversation: false, pendingRunCount: 1, voiceAvailable: false)
        #expect(working.isWorking)
        #expect(working.activity == "Working")
        #expect(!working.showsCall)
        #expect(!working.showsOverflow)
        #expect(!working.showsActivityDetails)

        let pairing = ChatDisplayMapper.header(
            connectionState: .pairingRequired, runtimeOwnsConversation: false, pendingRunCount: 0, voiceAvailable: true)
        #expect(pairing.status == .needsYou)
        #expect(pairing.showsCall)
        #expect(!pairing.isWorking)
    }

    @Test func emptyStateWaitsForHistoryAndYieldsToADraft() {
        let starters = SharedRemChatView.firstChatPrompts
        let empty = ChatDisplayMapper.emptyState(
            transcriptIsEmpty: true, isHistoryPending: false, hasPendingDraft: false, starters: starters)
        #expect(empty?.starters.map(\.id) == starters.map(\.id))
        #expect(empty?.message == SharedRemChatView.emptyStateSubtitleWithStarters)

        #expect(ChatDisplayMapper.emptyState(
            transcriptIsEmpty: true, isHistoryPending: true, hasPendingDraft: false, starters: starters) == nil)
        #expect(ChatDisplayMapper.emptyState(
            transcriptIsEmpty: true, isHistoryPending: false, hasPendingDraft: true, starters: starters) == nil)
        #expect(ChatDisplayMapper.emptyState(
            transcriptIsEmpty: false, isHistoryPending: false, hasPendingDraft: false, starters: starters) == nil)
    }

    // MARK: Model menu

    private let hiddenModelMenu = ChatModelMenuDisplay(
        isShown: false, providers: [], selection: .automatic, label: "Automatic")

    private let miniMax = RemChatModelChoice(
        modelID: "MiniMaxAI/MiniMax-M2.7", name: "MiniMax M2.7 (via GMI MaaS)", provider: "gmi", contextWindow: nil)
    private let managedSibling = RemChatModelChoice(
        modelID: "SomeOtherManagedModel", name: "Other Managed", provider: "gmi", contextWindow: nil)
    private let sonnet = RemChatModelChoice(
        modelID: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", provider: "anthropic", contextWindow: nil)
    private let haiku = RemChatModelChoice(
        modelID: "claude-haiku-4-5", name: "Claude Haiku 4.5", provider: "anthropic", contextWindow: nil)
    private let gpt = RemChatModelChoice(
        modelID: "gpt-5", name: "GPT-5", provider: "openai", contextWindow: nil)

    private func modelMenu(
        _ choices: [RemChatModelChoice],
        evidence: RuntimeProviderAuthEvidence,
        selection: String = RemChatViewModel.defaultModelSelectionID
    ) -> ChatModelMenuDisplay {
        ChatDisplayMapper.modelMenu(
            modelChoices: choices,
            defaultModelLabel: "Default",
            providerEvidence: evidence,
            effectiveSelectionID: selection,
            showsModelPicker: !choices.isEmpty
        )
    }

    @Test func modelMenuListsExactlyTheClassicPickerGroups() {
        let choices = [sonnet, gpt, managedSibling, miniMax, haiku]
        let evidence = RuntimeProviderAuthEvidence.verified(["anthropic"])
        let menu = modelMenu(choices, evidence: evidence)

        let classic = ModelPickerPolicy.composerGroups(
            choices,
            runtimeConfiguredProviderIDs: ["anthropic"],
            defaultModelLabel: "Default",
            hasAuthoritativeProviderEvidence: true)
        #expect(menu.providers.map(\.name) == classic.map(\.provider))
        #expect(menu.providers.map { $0.models.map(\.id) } == classic.map { $0.models.map(\.selectionID) })

        // BYOK: only the runtime-authenticated provider; managed: only canonical MiniMax, with
        // transport jargon stripped from its name.
        #expect(menu.providers == [
            RemDesignSystem.ChatModelProvider(id: "Claude", name: "Claude", models: [
                RemDesignSystem.ChatModelOption(id: haiku.selectionID, name: "Claude Haiku 4.5"),
                RemDesignSystem.ChatModelOption(id: sonnet.selectionID, name: "Claude Sonnet 4.5"),
            ]),
            RemDesignSystem.ChatModelProvider(id: "MiniMax", name: "MiniMax", models: [
                RemDesignSystem.ChatModelOption(id: miniMax.selectionID, name: "MiniMax M2.7"),
            ]),
        ])
        #expect(menu.isShown)
        #expect(menu.selection == .automatic)
        #expect(menu.label == ModelPickerPresentation.automaticTitle)
    }

    @Test func modelMenuHidesProviderGroupsUntilEvidenceIsAuthoritative() {
        let unknown = modelMenu(
            [sonnet, miniMax],
            evidence: .loading(lastVerifiedProviderIDs: nil),
            selection: sonnet.selectionID)
        // Automatic (and Manage Models) stay available as the escape hatch; no provider submenus.
        #expect(unknown.providers.isEmpty)
        #expect(unknown.isShown)
        #expect(unknown.selection == .model(id: sonnet.selectionID))
        #expect(unknown.label == "Claude Sonnet 4.5")

        let failedWithSnapshot = modelMenu(
            [sonnet, miniMax], evidence: .failed(lastVerifiedProviderIDs: []))
        #expect(failedWithSnapshot.providers.map(\.name) == ["MiniMax"])
    }

    @Test func modelMenuIsHiddenWithoutACatalogAsInTheClassicPicker() {
        let menu = modelMenu([], evidence: .verified(["anthropic"]))
        #expect(!menu.isShown)
        #expect(menu.providers.isEmpty)
        let composer = ChatDisplayMapper.composer(
            draft: "", attachments: [], availability: .enabled, phase: .idle,
            model: menu, voiceAvailable: false, isFocused: false)
        #expect(!composer.showsModel)
    }

    @Test func modelSelectionRoundTripsTheViewModelSelectionID() {
        #expect(ChatDisplayMapper.modelSelection(forSelectionID: RemChatViewModel.defaultModelSelectionID) == .automatic)
        #expect(ChatDisplayMapper.selectionID(for: .automatic) == RemChatViewModel.defaultModelSelectionID)
        #expect(ChatDisplayMapper.modelSelection(forSelectionID: sonnet.selectionID) == .model(id: sonnet.selectionID))
        #expect(ChatDisplayMapper.selectionID(for: .model(id: sonnet.selectionID)) == sonnet.selectionID)
        #expect(ChatDisplayMapper.automaticModelLabel == ModelPickerPresentation.automaticTitle)
    }

    @Test func composerShowsTheClassicTriggerTitle() {
        let menu = modelMenu([sonnet, miniMax], evidence: .verified(["anthropic"]), selection: sonnet.selectionID)
        let composer = ChatDisplayMapper.composer(
            draft: "", attachments: [], availability: .enabled, phase: .idle,
            model: menu, voiceAvailable: false, isFocused: false)
        #expect(composer.showsModel)
        #expect(composer.modelLabel == "Claude Sonnet 4.5")
        #expect(RemDesignSystem.ChatModelMenu.triggerLabel(
            for: menu.selection, providers: menu.providers,
            automaticLabel: ChatDisplayMapper.automaticModelLabel) == composer.modelLabel)
    }

    // MARK: Message actions

    @Test func replyQuotesTheMessageIntoTheDraft() {
        #expect(ChatActionRouter.quotedReplyDraft(quoting: "Line one\nLine two", existingDraft: "") ==
            "> Line one\n> Line two\n\n")
        #expect(ChatActionRouter.quotedReplyDraft(quoting: "Hi", existingDraft: "My note") ==
            "> Hi\n\nMy note")
        #expect(ChatActionRouter.availableMessageActions == [.reply, .copy, .selectText])
    }
}
