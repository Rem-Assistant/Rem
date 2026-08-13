import Foundation

/// Best-effort cache for chat session defaults patched through `sessions.patch`.
///
/// Chat sends need `verboseLevel=on` and `execNode=<device>` so tool events are
/// visible and the gateway routes device actions to the current node. Patching
/// before every send adds a network round trip to the user's perceived thinking
/// time. This cache lets transports skip redundant patches briefly while still
/// retrying after reconnects, failures, or TTL expiry.
actor ChatSessionDefaultsPatchCache {
    enum Decision: Equatable {
        case patch
        case skip(ageSeconds: Int)
    }

    private struct Entry {
        var nodeId: String
        var patchedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttlSeconds: TimeInterval

    init(ttlSeconds: TimeInterval = 300) {
        self.ttlSeconds = ttlSeconds
    }

    func decision(sessionKey: String, nodeId: String, now: Date = Date()) -> Decision {
        guard let entry = entries[sessionKey],
              entry.nodeId == nodeId else {
            return .patch
        }

        let age = now.timeIntervalSince(entry.patchedAt)
        guard age < ttlSeconds else {
            return .patch
        }

        return .skip(ageSeconds: max(0, Int(age.rounded())))
    }

    func recordPatched(sessionKey: String, nodeId: String, now: Date = Date()) {
        entries[sessionKey] = Entry(nodeId: nodeId, patchedAt: now)
    }

    func invalidate(sessionKey: String) {
        entries.removeValue(forKey: sessionKey)
    }
}
