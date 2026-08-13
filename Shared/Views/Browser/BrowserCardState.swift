import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol

/// What the in-chat "Rem's browser session" card should show for the current conversation.
enum BrowserCardPresentation: Equatable {
    /// No card.
    case none
    /// The pinned "Rem is using a browser · tap to watch or take over" card — Rem is browsing now.
    case live
    /// The inline "Rem's browser session · Session ended · tap to review" card, anchored below the
    /// browser message.
    case ended
}

/// A browser-tool start captured directly from the gateway event stream.
///
/// This crosses the transport/UI boundary as a small Sendable value so the live-card signal is
/// durable even when a tool start and result are both consumed before SwiftUI renders once.
struct BrowserToolActivity: Equatable, Sendable {
    let sessionKey: String
    let runID: String
    let toolCallID: String
    let toolName: String
    let action: String?

    init(
        sessionKey: String,
        runID: String = "unscoped",
        toolCallID: String,
        toolName: String,
        action: String?
    ) {
        self.sessionKey = sessionKey
        self.runID = runID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.action = action
    }
}

/// Run-scoped browser state recovered from live `agent/tool` events.
///
/// Browser starts are recorded before the transport yields them to the chat view model. Keep the
/// resulting state for the rest of that run so the card does not disappear between a `navigate`
/// result and the agent's next browser action.
struct BrowserRunEvidence: Equatable {
    enum BrowserDisposition: Equatable {
        case untouched
        /// The user attached Cloud browser, but no structured browser/canvas tool start has arrived.
        /// This may show the intent card, but must not transfer the single browser's ownership.
        case requested
        case live
        case explicitlyClosed
    }

    private(set) var sessionKey: String?
    private(set) var runID: String?
    private(set) var runIsActive = false
    private(set) var browserDisposition: BrowserDisposition = .untouched
    private(set) var observedToolCallIDs: Set<String> = []

    var supportsLiveCard: Bool {
        runIsActive && (browserDisposition == .requested || browserDisposition == .live)
    }

    var supportsOwnershipClaim: Bool {
        runIsActive && browserDisposition == .live
    }

    /// Whether this run contains real browser/canvas activity worth preserving as a review card
    /// after the browser explicitly ends. A requested-only attachment is intentionally excluded: intent without a
    /// structured tool start must never manufacture browser history.
    var containsBrowserActivity: Bool {
        browserDisposition == .live || browserDisposition == .explicitlyClosed
    }

    mutating func begin(sessionKey: String, runID: String? = nil) {
        self.sessionKey = sessionKey
        self.runID = runID
        runIsActive = true
        browserDisposition = .untouched
        observedToolCallIDs.removeAll()
    }

    mutating func record(_ activity: BrowserToolActivity) {
        if sessionKey != activity.sessionKey
            || !runIsActive
            || (runID != nil && runID != activity.runID)
        {
            begin(sessionKey: activity.sessionKey, runID: activity.runID)
        } else if runID == nil {
            runID = activity.runID
        }
        guard observedToolCallIDs.insert(activity.toolCallID).inserted else { return }
        apply(toolName: activity.toolName, action: activity.action)
    }

    mutating func markBrowserRequested(sessionKey: String, runID: String) {
        begin(sessionKey: sessionKey, runID: runID)
        browserDisposition = .requested
    }

    mutating func end(sessionKey: String, runID: String?) {
        guard self.sessionKey == sessionKey,
              runID == nil || self.runID == nil || self.runID == runID
        else { return }
        runIsActive = false
    }

    mutating func markBrowserExplicitlyClosed() {
        browserDisposition = .explicitlyClosed
    }

    private mutating func apply(toolName rawToolName: String, action rawAction: String?) {
        let toolName = rawToolName.lowercased()
        guard toolName == "browser" || toolName == "canvas" else { return }
        if toolName == "browser" {
            // Every browser-tool start means Rem is actively using the browser. In practice the
            // first action is often `tabs`, `status`, or `snapshot` rather than `open`/`navigate`.
            // Only an explicit teardown should turn the live card off within the active run.
            let action = rawAction?.lowercased()
            if action == "stop" || action == "close" {
                browserDisposition = .explicitlyClosed
            } else if browserDisposition != .explicitlyClosed
                || action == "navigate" || action == "open"
            {
                browserDisposition = .live
            }
        } else if rawAction?.lowercased() == "present" {
            browserDisposition = .live
        }
    }
}

/// Pure decision logic for the browser card, factored out of `SharedRemChatView` so the tricky
/// "is it genuinely live vs. is it stale history" rule can be unit-tested without a running view.
///
/// The load-bearing insight (the founder bug + its regression): you cannot decide "live" from the
/// transcript alone. A browser opened but never explicitly closed (agents rarely emit `browser
/// stop`) leaves the whole-transcript latch `true` forever, so reading it re-animated "Rem is using
/// a browser" on every later, unrelated turn and every time an OLD chat was re-opened. Worse, during
/// a session switch `sessionKey` and `messages` update in separate ticks, so a transcript-only rule
/// briefly evaluates the WRONG conversation.
///
/// Live agent-run evidence establishes ownership without waiting for transcript refresh. After that,
/// the session's explicit ended marker is authoritative: an agent turn finishing does not close the
/// browser, while user End and browser stop/close do. Transcript fallback remains useful only for
/// discovering browser activity; it cannot override an explicit end.
enum BrowserCardStateResolver {
    /// A requested-only attachment may render intent immediately, but the shared browser must stay
    /// non-interactive until this run has real browser/canvas evidence. Historical ownership from a
    /// prior turn is deliberately irrelevant here.
    static func canPresentLiveBrowser(
        messages: [OpenClawChatMessage],
        pendingRunCount: Int,
        activeRunEvidences: [BrowserRunEvidence]
    ) -> Bool {
        if activeRunEvidences.contains(where: \.supportsOwnershipClaim) { return true }
        let hasLifecycleAuthority = activeRunEvidences.contains {
            $0.browserDisposition != .untouched
        }
        return !hasLifecycleAuthority
            && pendingRunCount > 0
            && currentTurnTouchedBrowser(messages)
            && hasLiveBrowser(in: messages)
    }

    /// - Parameters:
    ///   - messages: the (already conversation-correct) transcript to classify.
    ///   - pendingRunCount: retained in the resolver contract for the pre-ownership intent path;
    ///     active/ended state itself no longer derives from agent-run completion.
    ///   - isOwner: whether this conversation owns the single global browser session.
    ///   - isSessionEnded: whether explicit user/agent teardown ended this owner's browser session.
    ///   - activeRunEvidence: live browser tool state observed before the transcript refreshes.
    static func resolve(
        messages: [OpenClawChatMessage],
        pendingRunCount: Int,
        isOwner: Bool,
        isSessionEnded: Bool,
        activeRunEvidence: BrowserRunEvidence = BrowserRunEvidence()
    ) -> BrowserCardPresentation {
        let evidences = activeRunEvidence.sessionKey == nil ? [] : [activeRunEvidence]
        return resolve(
            messages: messages,
            pendingRunCount: pendingRunCount,
            isOwner: isOwner,
            isSessionEnded: isSessionEnded,
            activeRunEvidences: evidences
        )
    }

    static func resolve(
        messages: [OpenClawChatMessage],
        pendingRunCount _: Int,
        isOwner: Bool,
        isSessionEnded: Bool,
        activeRunEvidences: [BrowserRunEvidence]
    ) -> BrowserCardPresentation {
        let evidenceShowsLiveBrowser = activeRunEvidences.contains(where: \.supportsLiveCard)
        let containsBrowserActivity = messages.contains(where: isBrowserMessage)
            || activeRunEvidences.contains(where: \.containsBrowserActivity)
        // Requested-only evidence may show immediate intent before ownership exists. Ownership is
        // itself proof that this conversation established the active global browser, even if a
        // later history refresh omitted its tool row and terminal run evidence was pruned.
        let live = !isSessionEnded
            && (evidenceShowsLiveBrowser || isOwner)
        if live { return .live }
        // Only the owner shows the historical review card. Prefer persisted history, but retain the
        // structured run evidence as authority when the gateway final/history handoff omits the
        // browser tool row.
        if isOwner, isSessionEnded, containsBrowserActivity {
            return .ended
        }
        return .none
    }

    /// Did the CURRENT turn — everything after the last user message — touch the browser? This is how
    /// "Rem is browsing right now" is told apart from "an old, unclosed `browser navigate` still sits
    /// in the history": an unrelated later turn appends no browser tool call after its user message.
    static func currentTurnTouchedBrowser(_ messages: [OpenClawChatMessage]) -> Bool {
        let start = messages.lastIndex(where: { $0.role == "user" }).map { $0 + 1 } ?? 0
        guard start <= messages.count else { return false }
        return messages[start...].contains(where: isBrowserMessage)
    }

    /// Is there a live browser to watch right now? A small state machine over the transcript, not
    /// just "the last browser action", because the agent often checks `browser status` AFTER a
    /// `stop` to confirm it — and a read-only status/tabs/snapshot must NOT resurrect a browser the
    /// agent already tore down. Only opening it (navigate/open, or showing it with canvas.present)
    /// starts a session; only stop/close ends one; everything else leaves the state alone.
    static func hasLiveBrowser(in messages: [OpenClawChatMessage]) -> Bool {
        var live = false
        for m in messages {
            if messageOpensBrowser(m) { live = true }
            else if messageClosesBrowser(m) { live = false }
            // status / tabs / snapshot / canvas hide: read-only or view-only — leave `live` as is.
        }
        return live
    }

    /// A tool call that (re)starts a watchable browser: `browser navigate`/`open`, or a
    /// `canvas present` that puts the live view on screen.
    static func messageOpensBrowser(_ message: OpenClawChatMessage) -> Bool {
        message.content.contains { item in
            guard let action = argAction(item.arguments)?.lowercased() else { return false }
            if item.name?.caseInsensitiveCompare("browser") == .orderedSame {
                return action == "navigate" || action == "open"
            }
            if item.name?.caseInsensitiveCompare("canvas") == .orderedSame {
                return action == "present"
            }
            return false
        }
    }

    /// A `browser` tool call that ENDS the watchable session: `stop` tears the browser down;
    /// `close` closes a tab. The live view streams a SINGLE page today, so closing that tab ends
    /// what there is to watch — and it matches how the user ends a session ("done, close it"). NOTE:
    /// upstream `close` targets one tab; if multi-tab streaming ever lands, `close` should end only
    /// when it's the last/active tab. For the shipped single-tab flow, treating both as end is
    /// correct. (`navigate`/`open`/`tabs`/`status`/`snapshot` all keep it alive.)
    static func messageClosesBrowser(_ message: OpenClawChatMessage) -> Bool {
        message.content.contains { item in
            guard item.name?.caseInsensitiveCompare("browser") == .orderedSame,
                  let action = argAction(item.arguments)?.lowercased() else { return false }
            return action == "stop" || action == "close"
        }
    }

    /// Any browser/canvas tool call — used both to know a chat TOUCHED the browser and to anchor the
    /// ended card at the browser's place in the transcript. Broader than open/close: a `status` or
    /// `snapshot` counts as "touched" too.
    static func isBrowserMessage(_ message: OpenClawChatMessage) -> Bool {
        message.content.contains { item in
            item.name?.caseInsensitiveCompare("browser") == .orderedSame
                || item.name?.caseInsensitiveCompare("canvas") == .orderedSame
        }
    }

    /// The `action` argument of a tool call (the browser tool's command — navigate / tabs / close —
    /// lives under `action`).
    static func argAction(_ args: OpenClawKit.AnyCodable?) -> String? {
        guard let args else { return nil }
        if let dict = args.value as? [String: Any], let a = dict["action"] as? String { return a }
        if let dict = args.value as? [String: OpenClawKit.AnyCodable],
           let a = dict["action"]?.value as? String { return a }
        return nil
    }
}
