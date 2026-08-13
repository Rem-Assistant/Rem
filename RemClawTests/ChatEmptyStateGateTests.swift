import Foundation
import Testing
@testable import RemClaw

/// Covers the new-vs-existing empty-state rule extracted from `SharedRemChatView.messageList`.
/// FIX 1: a fresh conversation never shows the loading skeleton (even while waking/unreachable).
/// FIX 2: a pending inbound prompt suppresses the starter prompts.
struct ChatEmptyStateGateTests {
    private func resolve(
        messagesEmpty: Bool = true,
        isLoading: Bool = false,
        isWaking: Bool = false,
        isFreshConversation: Bool = false,
        isInitialHistoryPending: Bool = false,
        hasPendingInboundPrompt: Bool = false,
        hasActiveVoiceContent: Bool = false,
        hasLiveActivity: Bool = false
    ) -> ChatEmptyStateGate.Content {
        ChatEmptyStateGate.resolve(
            messagesEmpty: messagesEmpty,
            isLoading: isLoading,
            isWaking: isWaking,
            isFreshConversation: isFreshConversation,
            isInitialHistoryPending: isInitialHistoryPending,
            hasPendingInboundPrompt: hasPendingInboundPrompt,
            hasActiveVoiceContent: hasActiveVoiceContent,
            hasLiveActivity: hasLiveActivity
        )
    }

    @Test func requestedExistingSessionWithoutRowTitleStartsPending() {
        #expect(ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: false,
            initialExistingSessionTitle: nil,
            requestedSessionKey: "daily-2026-08-06",
            currentSessionKey: "main",
            messagesEmpty: false,
            isLoading: false,
            completedInitialHistoryLoad: false
        ))
    }

    @Test func completedOrFreshRouteDoesNotRemainInitiallyPending() {
        #expect(!ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: false,
            initialExistingSessionTitle: "Munch",
            requestedSessionKey: "munch",
            currentSessionKey: "munch",
            messagesEmpty: false,
            isLoading: false,
            completedInitialHistoryLoad: true
        ))
        #expect(!ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: true,
            initialExistingSessionTitle: nil,
            requestedSessionKey: "chat-new",
            currentSessionKey: "chat-new",
            messagesEmpty: true,
            isLoading: true,
            completedInitialHistoryLoad: false
        ))
    }

    @Test func alreadyLoadedMatchingTranscriptDoesNotForceShimmer() {
        #expect(!ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: false,
            initialExistingSessionTitle: "Munch",
            requestedSessionKey: "munch",
            currentSessionKey: "munch",
            messagesEmpty: false,
            isLoading: false,
            completedInitialHistoryLoad: false
        ))
    }

    @Test func matchingButEmptyExistingTranscriptWaitsForScheduledLoad() {
        #expect(ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: false,
            initialExistingSessionTitle: nil,
            requestedSessionKey: "daily-2026-08-06",
            currentSessionKey: "daily-2026-08-06",
            messagesEmpty: true,
            isLoading: false,
            completedInitialHistoryLoad: false
        ))
    }

    @Test func matchingTranscriptOnlyShimmersWhenItIsActuallyLoading() {
        #expect(ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: false,
            initialExistingSessionTitle: "Munch",
            requestedSessionKey: "munch",
            currentSessionKey: "munch",
            messagesEmpty: false,
            isLoading: true,
            completedInitialHistoryLoad: false
        ))
    }

    // MARK: - FIX 1: fresh conversation never shimmers

    @Test func freshConversationWhileLoadingShowsStartersNotSkeleton() {
        // Founder case (a): a brand-new conversation is bootstrapping. No history to fetch → starter.
        #expect(resolve(isLoading: true, isFreshConversation: true) == .starters)
    }

    @Test func freshConversationWhileWakingOrUnreachableShowsStartersNotSkeleton() {
        // Founder case (b): a new convo whose send is stuck on an unreachable gateway (isWaking) must
        // show the starter/empty state, not a stuck shimmer.
        #expect(resolve(isWaking: true, isFreshConversation: true) == .starters)
        #expect(resolve(isLoading: true, isWaking: true, isFreshConversation: true) == .starters)
    }

    // MARK: - Existing conversation keeps the skeleton (preserves #1105)

    @Test func existingConversationLoadingHistoryShowsSkeleton() {
        #expect(resolve(isLoading: true) == .skeleton)
    }

    @Test func existingConversationBeforeAsyncLoadStartsShowsSkeleton() {
        #expect(resolve(isInitialHistoryPending: true) == .skeleton)
    }

    @Test func existingConversationDoesNotTreatStaleNonEmptyMessagesAsLoaded() {
        #expect(resolve(messagesEmpty: false, isInitialHistoryPending: true) == .skeleton)
    }

    @Test func existingConversationPrefillDoesNotExposePriorTranscriptWhileHistoryIsPending() {
        #expect(resolve(
            messagesEmpty: false,
            isInitialHistoryPending: true,
            hasPendingInboundPrompt: true
        ) == .skeleton)
    }

    @Test func freshConversationIgnoresInitialHistoryIntent() {
        #expect(resolve(isFreshConversation: true, isInitialHistoryPending: true) == .starters)
    }

    @Test func existingConversationWakingShowsSkeleton() {
        #expect(resolve(isWaking: true) == .skeleton)
    }

    @Test func existingConversationIdleAndEmptyShowsStarters() {
        // Reachable, done loading, genuinely empty: fall through to the starter, not a stuck skeleton.
        #expect(resolve() == .starters)
    }

    // MARK: - FIX 2: pending prompt suppresses starters

    @Test func pendingPromptSuppressesStartersOnFreshConversation() {
        // Arrived from Capabilities with a prefilled composer: no skeleton (fresh) AND no starters
        // (intent stated) → transcript body above the prefilled composer.
        #expect(resolve(isFreshConversation: true, hasPendingInboundPrompt: true) == .transcript)
    }

    @Test func pendingPromptSuppressesSkeletonAndStartersWhileLoading() {
        #expect(resolve(isLoading: true, hasPendingInboundPrompt: true) == .transcript)
    }

    @Test func pendingPromptOnIdleEmptyConversationShowsTranscript() {
        #expect(resolve(hasPendingInboundPrompt: true) == .transcript)
    }

    // MARK: - Voice + non-empty

    @Test func activeVoiceContentSuppressesStarters() {
        #expect(resolve(hasActiveVoiceContent: true) == .transcript)
        // Fresh + voice while waking: still no skeleton, and voice content routes to the transcript.
        #expect(resolve(isWaking: true, isFreshConversation: true, hasActiveVoiceContent: true) == .transcript)
    }

    @Test func liveActivityAlwaysSelectsTranscriptForAnEmptyConversation() {
        #expect(resolve(hasLiveActivity: true) == .transcript)
        #expect(resolve(
            isLoading: true,
            isWaking: true,
            isInitialHistoryPending: true,
            hasLiveActivity: true
        ) == .transcript)
        #expect(resolve(isFreshConversation: true, hasLiveActivity: true) == .transcript)
    }

    @Test func retainedPriorConversationActivityCannotOverrideRequestedHistory() {
        #expect(!ChatEmptyStateGate.hasRenderableLiveActivity(
            isShowingRequestedSession: false,
            activitySessionKey: "old-chat",
            currentSessionKey: "new-chat",
            hasActivityDisplays: true
        ))
        #expect(ChatEmptyStateGate.hasRenderableLiveActivity(
            isShowingRequestedSession: true,
            activitySessionKey: "new-chat",
            currentSessionKey: "new-chat",
            hasActivityDisplays: true
        ))
        #expect(resolve(
            isInitialHistoryPending: true,
            hasLiveActivity: ChatEmptyStateGate.hasRenderableLiveActivity(
                isShowingRequestedSession: false,
                activitySessionKey: "old-chat",
                currentSessionKey: "new-chat",
                hasActivityDisplays: true
            )
        ) == .skeleton)
    }

    @Test func priorAccumulatorOwnerCannotBypassSkeletonAfterViewModelKeyAdvances() {
        let renderable = ChatEmptyStateGate.hasRenderableLiveActivity(
            isShowingRequestedSession: true,
            activitySessionKey: "old-chat",
            currentSessionKey: "new-chat",
            hasActivityDisplays: true
        )

        #expect(!renderable)
        #expect(resolve(isInitialHistoryPending: true, hasLiveActivity: renderable) == .skeleton)
    }

    @Test func nonEmptyMessagesAlwaysShowTranscript() {
        #expect(resolve(messagesEmpty: false, isLoading: true) == .transcript)
        #expect(resolve(messagesEmpty: false, isWaking: true, isFreshConversation: true) == .transcript)
    }

    // MARK: - iOS Back -> reopen lifecycle

    @MainActor
    @Test func reopeningSameBoundSessionRetainsWarmTranscriptInsteadOfInstallingEmptyModel() {
        // Popping to Chat Sessions clears the route sentinel (`mainSessionKey`) but intentionally
        // retains the painted view model. Selecting the same row again must reuse that model.
        var loadCalls = 0
        var replacementCalls = 0
        let outcome = ChatSessionViewModelActivationCoordinator.activate(
            .init(
                previousRoutingSessionKey: nil,
                requestedSessionKey: "rem",
                retainedSessionKey: "rem",
                retainedBindingKey: "wss://gateway.example|rem|device-a",
                requestedBindingKey: "wss://gateway.example|rem|device-a"
            ),
            reuse: { loadCalls += 1 },
            replace: { replacementCalls += 1 }
        )

        #expect(outcome == .reusedWarmModel)
        #expect(loadCalls == 1)
        #expect(replacementCalls == 0)
        #expect(!ChatEmptyStateGate.isInitialHistoryPending(
            isFreshConversation: false,
            initialExistingSessionTitle: "Rem",
            requestedSessionKey: "rem",
            currentSessionKey: "rem",
            messagesEmpty: false,
            isLoading: false,
            completedInitialHistoryLoad: false
        ))
        #expect(resolve(messagesEmpty: false) == .transcript)
    }

    @MainActor
    @Test func differentSessionGatewayOrDeviceRequestsReplacement() {
        let requests = [
            ChatSessionViewModelActivationCoordinator.Request(
                previousRoutingSessionKey: nil,
                requestedSessionKey: "chat-b",
                retainedSessionKey: "chat-a",
                retainedBindingKey: "wss://gateway.example|chat-a|device-a",
                requestedBindingKey: "wss://gateway.example|chat-b|device-a"
            ),
            .init(
                previousRoutingSessionKey: nil,
                requestedSessionKey: "chat-a",
                retainedSessionKey: "chat-a",
                retainedBindingKey: "wss://old-gateway.example|chat-a|device-a",
                requestedBindingKey: "wss://new-gateway.example|chat-a|device-a"
            ),
            .init(
                previousRoutingSessionKey: nil,
                requestedSessionKey: "chat-a",
                retainedSessionKey: "chat-a",
                retainedBindingKey: "wss://gateway.example|chat-a|device-a",
                requestedBindingKey: "wss://gateway.example|chat-a|device-b"
            ),
        ]
        var loadCalls = 0
        var replacementCalls = 0

        for request in requests {
            let outcome = ChatSessionViewModelActivationCoordinator.activate(
                request,
                reuse: { loadCalls += 1 },
                replace: { replacementCalls += 1 }
            )
            #expect(outcome == .requestedReplacement)
        }

        #expect(loadCalls == 0)
        #expect(replacementCalls == requests.count)
    }
}
