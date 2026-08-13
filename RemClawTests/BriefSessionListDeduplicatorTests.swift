import Foundation
import Testing
@testable import RemClaw

struct BriefSessionListDeduplicatorTests {
    private struct Row: Equatable {
        let key: String
        let totalTokens: Int?
        let preview: String?
        var hasLocalUserInteraction = false
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var august9: Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 12))!
    }

    @Test func authenticatedSessionFixtureCollapsesTheArtifactOnlyCurrentDayBridge() {
        let rows = [
            Row(key: "agent:main:rem-today-20260809", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "agent:main:rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "agent:main:chat-general", totalTokens: 420, preview: "Plan my week"),
        ]

        #expect(filtered(rows).map(\.key) == [
            "agent:main:rem-orchestrator",
            "agent:main:chat-general",
        ])
    }

    @Test func keepsLegacyBridgeWhenDurableConversationIsAbsent() {
        let rows = [Row(key: "rem-today-20260809", totalTokens: 0, preview: "Aug 9 brief")]
        #expect(filtered(rows) == rows)
    }

    @Test func keepsLegacyConversationWhenLatestMessagesDiffer() {
        let rows = [
            Row(key: "rem-today-20260809", totalTokens: 0, preview: "A reply in the legacy chat"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
        ]
        #expect(filtered(rows) == rows)
    }

    @Test func keepsLegacyConversationWithModelTurnEvidence() {
        let rows = [
            Row(key: "rem-today-20260809", totalTokens: 800, preview: "Aug 9 brief"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
        ]
        #expect(filtered(rows) == rows)
    }

    @Test func keepsLegacyConversationWhenTokenEvidenceIsUnknown() {
        let rows = [
            Row(key: "rem-today-20260809", totalTokens: nil, preview: "Aug 9 brief"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
        ]
        #expect(filtered(rows) == rows)
    }

    @Test func keepsLegacyConversationWithLocalUserInteractionEvidence() {
        let rows = [
            Row(
                key: "rem-today-20260809",
                totalTokens: 0,
                preview: "Aug 9 brief",
                hasLocalUserInteraction: true
            ),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
        ]
        #expect(filtered(rows) == rows)
    }

    @Test func malformedLegacyDateFailsOpen() {
        let rows = [
            // Foundation leniently rolls July 40 into August 9 unless components are round-tripped.
            Row(key: "rem-today-20260740", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
        ]
        #expect(filtered(rows) == rows)
    }

    @Test func iosAdapterKeepsLocallyRepliedLegacyConversation() {
        let key = "rem-today-20260809"
        SessionLastMessagePreviews.remove(key)
        SessionLastMessageTimes.remove(key)
        defer {
            SessionLastMessagePreviews.remove(key)
            SessionLastMessageTimes.remove(key)
        }
        SessionLastMessagePreviews.setPreview("My local reply", for: key)
        let rows = [
            Row(key: key, totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
        ]

        let visible = IOSBriefSessionListPresentation
            .removingCurrentArtifactOnlyBridgeDuplicates(
                from: rows,
                now: august9,
                calendar: utcCalendar,
                sessionKey: \.key,
                totalTokens: \.totalTokens,
                normalizedLastMessagePreview: \.preview
            )

        #expect(visible == rows)
    }

    @Test func keepsHistoricalLegacyConversation() {
        let rows = [
            Row(key: "rem-today-20260808", totalTokens: 0, preview: "Aug 8 brief"),
            Row(key: "rem-orchestrator", totalTokens: 0, preview: "Aug 8 brief"),
        ]
        #expect(filtered(rows) == rows)
    }

    @Test func handlesBareAndCanonicalKeysWithoutTouchingGeneralChats() {
        let rows = [
            Row(key: "rem-today-20260809", totalTokens: 0, preview: "  Aug 9 brief  "),
            Row(key: "agent:main:rem-orchestrator", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "main", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "chat-fresh", totalTokens: 0, preview: "Aug 9 brief"),
            Row(key: "rem-task-123", totalTokens: 0, preview: "Aug 9 brief"),
        ]

        #expect(filtered(rows).map(\.key) == [
            "agent:main:rem-orchestrator",
            "main",
            "chat-fresh",
            "rem-task-123",
        ])
    }

    private func filtered(_ rows: [Row]) -> [Row] {
        BriefSessionListDeduplicator.removingCurrentArtifactOnlyBridgeDuplicates(
            from: rows,
            now: august9,
            calendar: utcCalendar,
            sessionKey: \.key,
            totalTokens: \.totalTokens,
            hasLocalUserInteraction: \.hasLocalUserInteraction,
            normalizedLastMessagePreview: { $0.preview?.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }
}
