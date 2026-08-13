import Foundation

/// Explicit loading lifecycle for session-list surfaces.
/// Used by Mac Sessions (#347) and testable in isolation.
enum SessionsListViewState: Equatable {
    case disconnected
    case waitingForRequest
    case loading
    case empty
    case loaded
    case error

    /// An uncached list needs the same stable placeholder both immediately before its scheduled
    /// request starts and while that request is in flight. Treating only `.loading` as skeleton
    /// time lets the ready-but-not-yet-started frame flash a connection/null state first.
    var usesLoadingSkeleton: Bool {
        self == .waitingForRequest || self == .loading
    }
}

enum SessionsListViewStateResolver {
    static func resolve(
        operatorReady: Bool,
        isLoading: Bool,
        hasLoadedOnce: Bool,
        hasVisibleSessions: Bool,
        hasLoadError: Bool
    ) -> SessionsListViewState {
        if !operatorReady {
            return .disconnected
        }
        if isLoading && !hasVisibleSessions {
            return .loading
        }
        if !hasLoadedOnce && !hasVisibleSessions {
            return .waitingForRequest
        }
        if hasLoadError && !hasVisibleSessions {
            return .error
        }
        if !hasVisibleSessions {
            return .empty
        }
        return .loaded
    }
}

/// Resolves the one-line subtitle shown under a session row in the history list.
///
/// Priority:
/// 1. `localPreview` — last message exchanged on *this* device (freshest).
/// 2. `serverPreview` — the gateway's transcript-derived last-message text
///    (populated from `sessions.list` `lastMessagePreview`). Lets devices and
///    installs that never sent the messages locally still show real content.
/// 3. A generic placeholder — *last resort only*, for sessions whose transcript
///    preview is unavailable (older gateways, rows beyond the gateway's preview
///    window) but that clearly have history (`totalTokens > 0` / `updatedAt`).
/// 4. `nil` — a genuinely empty session with no content at all.
enum SessionRowSubtitleResolver {
    /// User-facing copy. Kept here (not inline in the view) so it is covered by
    /// tests and the fallback can be asserted to fire only when no real preview
    /// is available.
    static let savedPlaceholder = "Conversation saved on your machine"
    static let fromMachinePlaceholder = "Conversation from your machine"

    static func resolve(
        localPreview: String?,
        serverPreview: String?,
        totalTokens: Int?,
        hasUpdatedAt: Bool
    ) -> String? {
        if let localPreview = nonEmpty(localPreview) {
            return localPreview
        }
        if let serverPreview = nonEmpty(serverPreview) {
            return serverPreview
        }
        if let tokens = totalTokens, tokens > 0 {
            return savedPlaceholder
        }
        if hasUpdatedAt {
            return fromMachinePlaceholder
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
