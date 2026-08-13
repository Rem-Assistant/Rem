import Foundation
import Testing
@testable import RemClawMac

/// Serialized because the adapter intentionally reads the process-wide Mac session metadata stores;
/// the local-interaction fixture and the artifact-only fixture exercise the same legacy session key.
@Suite(.serialized)
struct MacBriefSessionListPresentationTests {
    private struct Row: Equatable {
        let key: String
        let totalTokens: Int?
        let preview: String?
    }

    @Test func sessionsFixtureUsesTheSharedSafeBridgeCollapse() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 9,
            hour: 12
        ))!
        let rows = [
            Row(key: "rem-today-20260809", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "chat-general", totalTokens: 50, preview: "General conversation"),
        ]

        let visible = MacBriefSessionListPresentation
            .removingCurrentArtifactOnlyBridgeDuplicates(
                from: rows,
                now: now,
                calendar: calendar,
                sessionKey: \.key,
                totalTokens: \.totalTokens,
                normalizedLastMessagePreview: \.preview
            )

        #expect(visible.map(\.key) == ["rem-orchestrator", "chat-general"])
    }

    @Test func locallyRepliedLegacyConversationRemainsVisibleWithStaleServerEvidence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 9,
            hour: 12
        ))!
        let legacyKey = "rem-today-20260809"
        MacSessionLastMessagePreviews.remove(legacyKey)
        MacSessionLastMessageTimes.remove(legacyKey)
        defer {
            MacSessionLastMessagePreviews.remove(legacyKey)
            MacSessionLastMessageTimes.remove(legacyKey)
        }
        MacSessionLastMessageTimes.touch(legacyKey)
        let rows = [
            Row(key: legacyKey, totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
        ]

        let visible = MacBriefSessionListPresentation
            .removingCurrentArtifactOnlyBridgeDuplicates(
                from: rows,
                now: now,
                calendar: calendar,
                sessionKey: \.key,
                totalTokens: \.totalTokens,
                normalizedLastMessagePreview: \.preview
            )

        #expect(visible == rows)
    }
}
