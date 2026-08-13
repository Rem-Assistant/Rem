import Foundation
import OpenClawChatUI
import OpenClawKit
import Testing
@testable import RemClaw

struct DailyOrchestratorChatRoutingTests {
    @Test func createSuggestionDedupUsesStableBackendActionIdentityAcrossScheduleRefresh() throws {
        let suggestion = TaskSuggestion(
            key: "cal:one",
            actionId: "11111111-1111-5111-8111-111111111111",
            source: "calendar",
            title: "Prep for Standup",
            subtitle: "Standup · Calendar",
            action: SuggestionAction(
                kind: "createTask",
                taskTitle: "Prep for Standup",
                targetTaskId: nil,
                startDate: "2026-08-16T13:00:00Z"
            )
        )

        #expect(TaskSuggestionCreateDeduplication.matchesExistingTask(
            for: suggestion,
            taskID: suggestion.actionId
        ))
        #expect(!TaskSuggestionCreateDeduplication.matchesExistingTask(
            for: suggestion,
            taskID: "99999999-9999-5999-8999-999999999999"
        ))
        #expect(TaskSuggestionCreateDeduplication.matchesExistingTask(
            for: suggestion,
            taskID: suggestion.actionId
        ))
    }

    @Test func summaryAlwaysUsesDurableRouteEvenWhenBackendAdvertisesLegacy() {
        #expect(
            DailyOrchestratorChatRouting.conversationRoute(
                apiSessionKey: "rem-orchestrator"
            ) == .init(sessionKey: "rem-orchestrator", isFresh: false)
        )
        #expect(
            DailyOrchestratorChatRouting.conversationRoute(
                apiSessionKey: "rem-today-20260815"
            ) == .init(sessionKey: "rem-orchestrator", isFresh: false)
        )
    }

    @Test func missingOrInvalidSummaryRouteFallsBackToDurableTodayConversation() {
        #expect(
            DailyOrchestratorChatRouting.conversationRoute(
                apiSessionKey: nil
            ) == .init(sessionKey: "rem-orchestrator", isFresh: false)
        )
        #expect(
            DailyOrchestratorChatRouting.conversationRoute(
                apiSessionKey: "main"
            ) == .init(sessionKey: "rem-orchestrator", isFresh: false)
        )
    }

    @Test func everyExplicitNewChatMintsFreshGeneralNamespace() {
        let id = UUID(uuidString: "abcdef12-1234-4234-8234-123456789012")!
        #expect(
            DailyOrchestratorChatRouting.freshGeneralRoute(id: id)
                == .init(sessionKey: "chat-abcdef12", isFresh: true)
        )
    }

    @Test func dailyTitleIgnoresMutableGatewayLabel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_786_752_000) // 2026-08-15 UTC

        #expect(
            BriefContext.displayTitle(
                for: "agent:main:rem-orchestrator",
                accountID: nil,
                now: now,
                calendar: calendar
            ) == "Rem"
        )
        #expect(
            BriefContext.displayTitle(
                for: "agent:main:rem-today-20260815",
                accountID: nil,
                now: now,
                calendar: calendar
            ) == "Today with Rem"
        )
        #expect(
            BriefContext.displayTitle(
                for: "rem-today-20260814",
                accountID: nil,
                now: now,
                calendar: calendar
            ) == "Aug 14 with Rem"
        )
    }

    @Test func durableTranscriptUsesMessageTimestampsForCompactDayBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date {
            formatter.date(from: value)!
        }
        let now = date("2026-08-16T12:00:00Z")
        func message(_ value: String) -> OpenClawChatMessage {
            OpenClawChatMessage(
                role: "assistant",
                content: [],
                timestamp: date(value).timeIntervalSince1970 * 1_000
            )
        }

        let aug15Morning = message("2026-08-15T08:00:00Z")
        let aug15Evening = message("2026-08-15T18:00:00Z")
        let aug16 = message("2026-08-16T08:00:00Z")

        #expect(ChatMessageSeparatorPolicy.label(
            for: aug15Morning, previous: nil,
            now: now, calendar: calendar, locale: locale
        ) == "Yesterday 8:00 AM")
        // Ten hours later on the same day now reads as its own delivery. This assertion previously
        // expected `nil`: same-day messages never separated, which is the reported defect — a
        // morning and an afternoon update ran together as one message.
        #expect(ChatMessageSeparatorPolicy.label(
            for: aug15Evening, previous: aug15Morning,
            now: now, calendar: calendar, locale: locale
        ) == "Yesterday 6:00 PM")
        #expect(ChatMessageSeparatorPolicy.label(
            for: aug16, previous: aug15Evening,
            now: now, calendar: calendar, locale: locale
        ) == "Today 8:00 AM")
        // A message with no usable timestamp cannot open a group.
        #expect(ChatMessageSeparatorPolicy.label(
            for: OpenClawChatMessage(role: "assistant", content: [], timestamp: nil), previous: nil,
            now: now, calendar: calendar, locale: locale
        ) == nil)
    }

    /// Separators are no longer gated to the durable daily thread. A task chat resumed the next
    /// morning has the same "did this just arrive?" problem the brief had.
    @Test func separatorsApplyToOrdinaryChatsNotJustTheDurableBriefThread() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-16T12:00:00Z")!
        func message(_ value: String) -> OpenClawChatMessage {
            OpenClawChatMessage(
                role: "assistant",
                content: [],
                timestamp: formatter.date(from: value)!.timeIntervalSince1970 * 1_000
            )
        }

        let morning = message("2026-08-16T08:00:00Z")
        let afternoon = message("2026-08-16T11:30:00Z")
        let labels = SharedRemChatView.separatorLabels(
            in: [morning, afternoon],
            briefPreviewInsertionIndex: nil,
            now: now,
            calendar: calendar,
            locale: locale
        )

        #expect(labels[0] == "Today 8:00 AM")
        #expect(labels[1] == "Today 11:30 AM")
    }

    @Test func briefPreviewBridgeOnlyYieldsToTodaysExactBrief() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-16T12:00:00Z")!
        func message(role: String, at value: String, text: String) -> OpenClawChatMessage {
            OpenClawChatMessage(
                role: role,
                content: [OpenClawChatMessageContent(
                    type: "text", text: text, mimeType: nil, fileName: nil, content: nil
                )],
                timestamp: formatter.date(from: value)!.timeIntervalSince1970 * 1_000
            )
        }

        let yesterday = message(
            role: "assistant", at: "2026-08-15T18:00:00Z", text: "Yesterday"
        )
        let todayUser = message(role: "user", at: "2026-08-16T09:00:00Z", text: "Hello")
        let ordinaryTodayAssistant = message(
            role: "assistant", at: "2026-08-16T09:01:00Z", text: "Ordinary reply"
        )
        let exactTodayBrief = message(
            role: "assistant", at: "2026-08-16T09:02:00Z", text: "Expected brief"
        )

        #expect(!SharedRemChatView.hasExactBriefToday(
            [yesterday, todayUser], matching: "Expected brief", now: now, calendar: calendar
        ))
        #expect(SharedRemChatView.briefPreviewInsertionIndex(
            in: [yesterday, todayUser], matching: "Expected brief", now: now, calendar: calendar
        ) == 1)
        // The brief-preview bridge carries its own "Today" heading, so the separator at that index
        // is suppressed rather than stating the same boundary twice.
        #expect(SharedRemChatView.separatorLabels(
            in: [yesterday, todayUser],
            briefPreviewInsertionIndex: 1,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )[1] == nil)
        #expect(SharedRemChatView.separatorLabels(
            in: [yesterday, todayUser],
            briefPreviewInsertionIndex: nil,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )[1] == "Today 9:00 AM")
        #expect(!SharedRemChatView.hasExactBriefToday(
            [yesterday, ordinaryTodayAssistant],
            matching: "Expected brief",
            now: now,
            calendar: calendar
        ))
        #expect(SharedRemChatView.briefPreviewInsertionIndex(
            in: [yesterday, ordinaryTodayAssistant],
            matching: "Expected brief",
            now: now,
            calendar: calendar
        ) == 1)
        #expect(SharedRemChatView.hasExactBriefToday(
            [yesterday, ordinaryTodayAssistant, exactTodayBrief],
            matching: "Expected brief",
            now: now,
            calendar: calendar
        ))
        #expect(SharedRemChatView.briefPreviewInsertionIndex(
            in: [yesterday, ordinaryTodayAssistant, exactTodayBrief],
            matching: "Expected brief",
            now: now,
            calendar: calendar
        ) == nil)
    }

    @Test func readBriefAnchorSelectsLatestExactArtifactAmongRepliesAndSlots() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-16T12:00:00Z")!
        func message(role: String, at value: String, text: String) -> OpenClawChatMessage {
            OpenClawChatMessage(
                role: role,
                content: [OpenClawChatMessageContent(
                    type: "text", text: text, mimeType: nil, fileName: nil, content: nil
                )],
                timestamp: formatter.date(from: value)!.timeIntervalSince1970 * 1_000
            )
        }

        let yesterday = message(
            role: "assistant", at: "2026-08-15T18:00:00Z", text: "Yesterday"
        )
        let todayUser = message(role: "user", at: "2026-08-16T08:59:00Z", text: "Hello")
        let morning = message(
            role: "assistant", at: "2026-08-16T09:00:00Z", text: "Morning brief"
        )
        let reply = message(
            role: "assistant", at: "2026-08-16T10:00:00Z", text: "A later reply"
        )
        let night = message(
            role: "assistant", at: "2026-08-16T19:00:00Z", text: "Night brief"
        )
        let laterReply = message(
            role: "assistant", at: "2026-08-16T20:00:00Z", text: "An even later reply"
        )

        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [yesterday, todayUser, morning, reply, night, laterReply],
            matching: "Night brief",
            now: now,
            calendar: calendar
        ) == night.id)
        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [yesterday, todayUser, morning, reply, night, laterReply],
            matching: "Stale cache",
            now: now,
            calendar: calendar
        ) == nil)
    }

    @Test func resolvedCanonicalBriefScrollsToVisibleMessageWithoutProjectedTimestamp() {
        let canonical = "# Today\n\nThe same-day canonical brief is visibly present."
        let visible = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: canonical, mimeType: nil, fileName: nil, content: nil
            )],
            timestamp: nil
        )

        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [visible],
            matching: canonical
        ) == nil)
        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [visible],
            matching: canonical,
            requiresCurrentDay: false
        ) == visible.id)
    }

    @Test func resolvedCanonicalBriefUsesBackendAuthorityAcrossDeviceDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-16T12:00:00Z")!
        let canonical = "# Today\n\nThe current prose happens to equal an older artifact."
        let visibleWithoutTimestamp = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: canonical, mimeType: nil, fileName: nil, content: nil
            )],
            timestamp: nil
        )
        let knownYesterdayDuplicate = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: canonical, mimeType: nil, fileName: nil, content: nil
            )],
            timestamp: formatter.date(from: "2026-08-15T18:00:00Z")!.timeIntervalSince1970 * 1_000
        )

        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [visibleWithoutTimestamp, knownYesterdayDuplicate],
            matching: canonical,
            now: now,
            calendar: calendar,
            requiresCurrentDay: false
        ) == visibleWithoutTimestamp.id)
        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [knownYesterdayDuplicate],
            matching: canonical,
            now: now,
            calendar: calendar,
            requiresCurrentDay: false
        ) == knownYesterdayDuplicate.id)

        // Without backend resolution, the normal Summary preview remains device-day scoped.
        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [knownYesterdayDuplicate],
            matching: canonical,
            now: now,
            calendar: calendar
        ) == nil)
    }

    @Test func suggestedTasksAnchorOnlyAfterExactBriefInDurableOrchestrator() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-16T12:00:00Z")!
        func message(role: String, text: String) -> OpenClawChatMessage {
            OpenClawChatMessage(
                role: role,
                content: [OpenClawChatMessageContent(
                    type: "text", text: text, mimeType: nil, fileName: nil, content: nil
                )],
                timestamp: now.timeIntervalSince1970 * 1_000
            )
        }
        let exactBrief = message(role: "assistant", text: "Canonical brief")
        let laterReply = message(role: "assistant", text: "What should we do first?")
        let messages = [exactBrief, laterReply]

        #expect(SharedRemChatView.briefSuggestionAnchorMessageID(
            sessionKey: "rem-orchestrator",
            messages: messages,
            briefMarkdown: "Canonical brief",
            suggestionCount: 2,
            now: now,
            calendar: calendar
        ) == exactBrief.id)
        #expect(SharedRemChatView.briefSuggestionAnchorMessageID(
            sessionKey: "chat-general",
            messages: messages,
            briefMarkdown: "Canonical brief",
            suggestionCount: 2,
            now: now,
            calendar: calendar
        ) == nil)
        #expect(SharedRemChatView.briefSuggestionAnchorMessageID(
            sessionKey: "rem-orchestrator",
            messages: messages,
            briefMarkdown: "Canonical brief",
            suggestionCount: 0,
            now: now,
            calendar: calendar
        ) == nil)
        #expect(SharedRemChatView.briefSuggestionAnchorMessageID(
            sessionKey: "rem-orchestrator",
            messages: messages,
            briefMarkdown: "A different brief",
            suggestionCount: 2,
            now: now,
            calendar: calendar
        ) == nil)
    }

    @Test func laterLoadedDuplicateBecomesTheLatestCanonicalAnchor() {
        let canonical = "# Today\n\nThe same canonical brief was projected twice."
        let earlier = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: canonical, mimeType: nil, fileName: nil, content: nil
            )],
            timestamp: nil
        )
        let newer = OpenClawChatMessage(
            role: "assistant",
            content: [OpenClawChatMessageContent(
                type: "text", text: canonical, mimeType: nil, fileName: nil, content: nil
            )],
            timestamp: nil
        )

        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [earlier], matching: canonical, requiresCurrentDay: false
        ) == earlier.id)
        #expect(SharedRemChatView.latestExactBriefMessageID(
            in: [earlier, newer], matching: canonical, requiresCurrentDay: false
        ) == newer.id)
        #expect(earlier.id != newer.id)
    }

    @Test func settledEmptyHistoryBridgeStillShowsCurrentSuggestions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let identity = try #require(OrchestratorSuggestionBriefIdentity(
            generatedAt: "2026-08-16T08:00:00Z",
            authoredMarkdown: "Canonical brief",
            authoredRevision: "revision-1"
        ))
        let snapshot = try #require(OrchestratorSuggestionSnapshot(
            identity: identity,
            snapshotID: "snapshot-1",
            briefMarkdown: "Canonical brief",
            suggestions: [Self.suggestion]
        ))

        #expect(SharedRemChatView.shouldShowSuggestionsAfterPreview(
            sessionKey: "rem-orchestrator",
            snapshot: snapshot,
            showsBriefPreviewBridge: true,
            now: now,
            calendar: calendar
        ))
        #expect(SharedRemChatView.shouldShowSuggestionsAfterPreview(
            sessionKey: "agent:main:rem-orchestrator",
            snapshot: snapshot,
            showsBriefPreviewBridge: true,
            now: now,
            calendar: calendar
        ))
    }

    @Test func connectedSourceOnlySnapshotRendersStandaloneWithoutInventedBriefProse() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z"))
        let identity = try #require(OrchestratorSuggestionBriefIdentity(
            generatedAt: "2026-08-16T08:00:00Z",
            authoredMarkdown: nil,
            authoredRevision: "deterministic:connected-only"
        ))
        let snapshot = try #require(OrchestratorSuggestionSnapshot(
            identity: identity,
            snapshotID: "snapshot-connected-only",
            briefMarkdown: nil,
            suggestions: [Self.suggestion]
        ))

        #expect(snapshot.briefMarkdown == nil)
        #expect(SharedRemChatView.shouldShowStandaloneSuggestions(
            sessionKey: "rem-orchestrator",
            snapshot: snapshot,
            now: now,
            calendar: calendar
        ))
        #expect(!SharedRemChatView.shouldShowStandaloneSuggestions(
            sessionKey: "chat-general",
            snapshot: snapshot,
            now: now,
            calendar: calendar
        ))
        #expect(SharedRemChatView.briefSuggestionAnchorMessageID(
            sessionKey: "rem-orchestrator",
            messages: [],
            briefMarkdown: snapshot.briefMarkdown,
            suggestionCount: snapshot.suggestions.count,
            now: now,
            calendar: calendar
        ) == nil)
    }

    @Test func staleDayAndUnrelatedSessionsFailClosed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-17T00:01:00Z"))
        let identity = try #require(OrchestratorSuggestionBriefIdentity(
            generatedAt: "2026-08-16T23:59:00Z",
            authoredMarkdown: "Yesterday's brief",
            authoredRevision: "revision-old"
        ))
        let snapshot = try #require(OrchestratorSuggestionSnapshot(
            identity: identity,
            snapshotID: "snapshot-old",
            briefMarkdown: "Yesterday's brief",
            suggestions: [Self.suggestion]
        ))

        #expect(SharedRemChatView.validatedOrchestratorSuggestionSnapshot(
            sessionKey: "rem-orchestrator",
            snapshot: snapshot,
            now: now,
            calendar: calendar
        ) == nil)
        #expect(SharedRemChatView.validatedOrchestratorSuggestionSnapshot(
            sessionKey: "chat-general",
            snapshot: snapshot,
            now: now.addingTimeInterval(-120),
            calendar: calendar
        ) == nil)
    }

    private static let suggestion = TaskSuggestion(
        key: "cal:one",
        actionId: "11111111-1111-5111-8111-111111111111",
        source: "calendar",
        title: "Prep for Standup",
        subtitle: "Standup · Calendar",
        action: SuggestionAction(
            kind: "createTask",
            taskTitle: "Prep for Standup",
            targetTaskId: nil,
            startDate: nil
        )
    )
}
