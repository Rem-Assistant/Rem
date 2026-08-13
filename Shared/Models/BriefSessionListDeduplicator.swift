import Foundation

/// Collapses the artifact-only current-day session created by the Daily Brief rollout bridge.
///
/// During the compatibility window the backend writes the same brief into both the durable
/// `rem-orchestrator` conversation and a legacy `rem-today-<yyyymmdd>` conversation. The legacy
/// transcript must remain reachable when it contains a real model turn, so this policy is deliberately
/// presentation-only and fails open unless `sessions.list` proves the legacy row has zero tokens and
/// the same latest visible artifact as the durable row, and the platform has no local interaction
/// evidence that may be fresher than those server fields.
enum BriefSessionListDeduplicator {
    static let durableSessionKey = "rem-orchestrator"
    static let legacySessionKeyPrefix = "rem-today-"

    static func removingCurrentArtifactOnlyBridgeDuplicates<Entry>(
        from entries: [Entry],
        now: Date = Date(),
        calendar: Calendar = .current,
        sessionKey: (Entry) -> String,
        totalTokens: (Entry) -> Int?,
        hasLocalUserInteraction: (Entry) -> Bool,
        normalizedLastMessagePreview: (Entry) -> String?
    ) -> [Entry] {
        let durablePreviews = Set(entries.compactMap { entry -> String? in
            guard bareSessionKey(sessionKey(entry)) == durableSessionKey else { return nil }
            return nonEmpty(normalizedLastMessagePreview(entry))
        })
        guard !durablePreviews.isEmpty else { return entries }

        return entries.filter { entry in
            let key = bareSessionKey(sessionKey(entry))
            guard isCurrentLegacyDaySession(key, now: now, calendar: calendar),
                  totalTokens(entry) == 0,
                  !hasLocalUserInteraction(entry),
                  let preview = nonEmpty(normalizedLastMessagePreview(entry)),
                  durablePreviews.contains(preview)
            else { return true }
            return false
        }
    }

    private static func bareSessionKey(_ sessionKey: String) -> String {
        let trimmed = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "agent", !parts[1].isEmpty else { return trimmed }
        let bare = parts.dropFirst(2).joined(separator: ":")
        return bare.isEmpty ? trimmed : bare
    }

    private static func isCurrentLegacyDaySession(
        _ sessionKey: String,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard sessionKey.hasPrefix(legacySessionKeyPrefix) else { return false }
        let stamp = String(sessionKey.dropFirst(legacySessionKeyPrefix.count))
        guard stamp.count == 8, stamp.allSatisfy(\.isNumber),
              let year = Int(stamp.prefix(4)),
              let month = Int(stamp.dropFirst(4).prefix(2)),
              let day = Int(stamp.suffix(2)),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return false }
        let roundTripped = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTripped.year == year,
              roundTripped.month == month,
              roundTripped.day == day
        else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
