import Foundation

/// Incremental window policy for `sessions.list`.
///
/// The UI grows an authoritative window. Transports satisfy that window through
/// bounded keyset-cursor pages on current gateways, then combine them into the same
/// replacement snapshot; older gateways retain the cumulative-limit fallback.
enum SessionListPagination {
    nonisolated static let initialLimit = 100
    nonisolated static let pageSize = 100

    nonisolated static func restoredLimit(
        currentLimit: Int,
        appliedLimit: Int?,
        cachedCount: Int
    ) -> Int {
        max(currentLimit, appliedLimit ?? cachedCount)
    }

    nonisolated static func nextLimit(
        currentLimit: Int,
        receivedCount: Int,
        hasMore: Bool?
    ) -> Int? {
        if hasMore == false { return nil }
        if hasMore == true { return currentLimit + pageSize }

        // Compatibility with gateways that predate the `hasMore` response field.
        // A full window may have another page; a short window is complete.
        guard receivedCount >= currentLimit else { return nil }
        return currentLimit + pageSize
    }

    /// Returns the next authoritative window only while filtering prevented the
    /// visible tail from advancing. A server window can be full of background
    /// sessions that the product intentionally hides; stopping at that window
    /// makes the list look capped even though real conversations exist below it.
    nonisolated static func nextLimitPastFilteredWindow(
        previousVisibleTail: String?,
        currentVisibleTail: String?,
        currentLimit: Int,
        receivedCount: Int,
        hasMore: Bool?
    ) -> Int? {
        guard previousVisibleTail == currentVisibleTail else { return nil }
        return nextLimit(
            currentLimit: currentLimit,
            receivedCount: receivedCount,
            hasMore: hasMore)
    }

    /// A live session can move ahead of a keyset cursor between page requests.
    /// When the terminal page proves the aggregate is stale, restart once with
    /// the legacy cumulative request to obtain a current authoritative window.
    nonisolated static func shouldRestartAfterCursorDrift(
        receivedCount: Int,
        totalCount: Int?,
        targetLimit: Int,
        hasMore: Bool?
    ) -> Bool {
        guard hasMore == false, let totalCount else { return false }
        return receivedCount != min(totalCount, targetLimit)
    }
}
