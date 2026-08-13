import Foundation

/// Tracks which restored chat-history snapshot has already received its
/// initial bottom scroll.
struct RestoredHistoryScrollState: Equatable {
    private var lastScrolledSignature: String?

    mutating func reset() {
        lastScrolledSignature = nil
    }

    mutating func shouldStartScroll(
        isLoading: Bool,
        sessionKey: String,
        messageCount: Int,
        lastMessageIdentity: String?
    ) -> Bool {
        guard !isLoading, messageCount > 0, let lastMessageIdentity else {
            return false
        }

        let signature = "\(sessionKey)|\(messageCount)|\(lastMessageIdentity)"
        guard lastScrolledSignature != signature else {
            return false
        }

        lastScrolledSignature = signature
        return true
    }
}
