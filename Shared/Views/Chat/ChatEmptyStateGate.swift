import Foundation

/// Pure classifier for what the chat scroll body should render when it may be empty or loading.
///
/// Extracted from `SharedRemChatView.messageList` so the new-vs-existing rule is testable in
/// isolation (SwiftUI view bodies aren't). Two founder-reported empty-state fixes live here:
///
/// **FIX 1 — a new conversation must go straight to the starter, not the loading skeleton.**
/// A brand-new conversation (`isFreshConversation`) has no server history to fetch, so it must
/// never sit behind the shimmer skeleton — not during bootstrap, and not while the gateway is
/// waking or unreachable. The skeleton is reserved for an EXISTING conversation whose history is
/// still on its way in (which is why PR #1105 added it: to stop an opened chat from flashing the
/// empty state before its messages appeared). We can't reliably tell new from existing from the
/// view model alone during the load window (the session list may not be fetched yet), so the
/// platform passes the fact down explicitly via `isFreshConversation`.
///
/// **FIX 2 — suppress the starters when a prompt is already pending.** If the composer already
/// carries unsent text (a skill/capability prefill, a task seed, or the user's own draft), intent
/// is stated; the "Start a conversation" starters are noise. Render the transcript body (empty
/// scroll above the always-visible, prefilled composer) instead of the starters. An existing route
/// whose requested history is still pending remains skeleton-first so the prefill cannot expose
/// messages from the conversation being left.
/// `nonisolated` because the app module defaults to `@MainActor` isolation, but this is a pure,
/// actor-agnostic value classifier — its `Content.Equatable` conformance and `resolve` must be
/// callable from any context (including nonisolated tests) without a Swift 6 isolation error.
nonisolated enum ChatEmptyStateGate {
    enum Content: Equatable {
        /// The shimmer skeleton — an existing conversation whose history is still loading.
        case skeleton
        /// The "Start a conversation" empty state with starter prompts.
        case starters
        /// The normal message list / streaming / voice transcript body.
        case transcript
    }

    /// Activity can override an empty/loading presentation only after the requested conversation
    /// is actually bound. During an async route switch, retained displays still belong to the chat
    /// being left and must not expose that prior transcript in the destination.
    static func hasRenderableLiveActivity(
        isShowingRequestedSession: Bool,
        activitySessionKey: String?,
        currentSessionKey: String,
        hasActivityDisplays: Bool
    ) -> Bool {
        guard isShowingRequestedSession, hasActivityDisplays else { return false }
        let owner = activitySessionKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = currentSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner?.isEmpty == false && owner == current
    }

    /// Derives the first-frame loading intent from navigation state instead of relying on a row
    /// title being available. Daily/summary routes know the requested key but may not have a title;
    /// they are still existing-session routes and must not flash the starter state while rebinding.
    static func isInitialHistoryPending(
        isFreshConversation: Bool,
        initialExistingSessionTitle: String?,
        requestedSessionKey: String?,
        currentSessionKey: String,
        messagesEmpty: Bool,
        isLoading: Bool,
        completedInitialHistoryLoad: Bool
    ) -> Bool {
        guard !isFreshConversation, !completedInitialHistoryLoad else { return false }
        let hasKnownTitle = initialExistingSessionTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let requestedKey = requestedSessionKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRequestedExistingSession = requestedKey?.isEmpty == false
        guard hasKnownTitle || hasRequestedExistingSession else { return false }

        // A mismatch is unambiguously pending. When the requested session is already active and
        // has a transcript, it is already renderable: do not force even one shimmer frame merely
        // because navigation carried an existing-session title. An active empty session still
        // needs its scheduled history request to settle before showing the genuine empty state.
        if let requestedKey,
           !requestedKey.isEmpty,
           requestedKey != currentSessionKey.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        return isLoading || messagesEmpty
    }

    /// - Parameters:
    ///   - messagesEmpty: `viewModel.messages.isEmpty`.
    ///   - isLoading: `viewModel.isLoading` (bootstrap/history fetch or an in-flight send).
    ///   - isWaking: gateway not connected (connecting / offline / unreachable / pairing).
    ///   - isFreshConversation: this conversation was just created and has no server history.
    ///   - hasPendingInboundPrompt: the composer already holds unsent text.
    ///   - hasActiveVoiceContent: live voice transcription is showing.
    ///   - hasLiveActivity: structured activity for the current conversation is showing.
    static func resolve(
        messagesEmpty: Bool,
        isLoading: Bool,
        isWaking: Bool,
        isFreshConversation: Bool,
        isInitialHistoryPending: Bool,
        hasPendingInboundPrompt: Bool,
        hasActiveVoiceContent: Bool,
        hasLiveActivity: Bool
    ) -> Content {
        // Structured live activity is already current-session transcript content. It outranks an
        // empty/loading first frame so cross-device, local, and voice-started runs cannot be hidden
        // behind starters or a history skeleton while Working is active.
        if hasLiveActivity { return .transcript }

        // Explicit navigation intent outranks message presence. During an async session switch the
        // view model updates `sessionKey` before replacing `messages`, so non-empty messages can
        // still belong to the conversation the user just left. Keep the destination on its
        // skeleton until the requested history load completes instead of exposing that stale chat.
        // This outranks a prefilled composer for existing routes; only fresh conversations know
        // there is no history request to protect.
        if !isFreshConversation,
           isInitialHistoryPending {
            return .skeleton
        }

        // Once there are messages (or streaming/voice content routed through the transcript), the
        // scroll body is the transcript regardless of loading/waking state, provided navigation has
        // not explicitly marked those messages as potentially belonging to the prior session.
        guard messagesEmpty else { return .transcript }

        // Skeleton ONLY for an existing conversation whose history hasn't arrived yet. A fresh
        // conversation has nothing to fetch, and a pending prompt means the user is composing —
        // neither should shimmer. This is the crux of FIX 1: it is deliberately NOT a bare
        // `isWaking || isLoading`, which also fires during a new conversation's bootstrap and while
        // a first send is stuck on an unreachable gateway (exactly the founder's repro).
        if !isFreshConversation,
           !hasPendingInboundPrompt,
           (isLoading || isWaking) {
            return .skeleton
        }

        // Empty, not loading history: show the starters — unless the user is already composing
        // (FIX 2) or voice content is active, in which case fall through to the transcript body.
        if !hasPendingInboundPrompt, !hasActiveVoiceContent {
            return .starters
        }

        return .transcript
    }
}
