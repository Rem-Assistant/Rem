import Foundation
import Testing
@testable import RemClaw

/// The grouping decision is the only real logic in the separator, so it is pinned directly.
///
/// Every case injects `now`, a fixed UTC calendar and `en_US_POSIX`, so nothing here depends on the
/// machine's wall clock, time zone or region.
struct ChatTimeSeparatorPolicyTests {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        return formatter.date(from: value)!
    }

    /// Sunday 2026-08-16, 18:00 UTC.
    private var now: Date { date("2026-08-16T18:00:00Z") }

    private func label(at value: String, previous: String?) -> String? {
        ChatTimeSeparatorPolicy.label(
            at: date(value),
            previous: previous.map(date),
            now: now,
            calendar: calendar,
            locale: locale
        )
    }

    @Test func messagesInTheSameMinuteStayInOneGroup() {
        #expect(label(at: "2026-08-16T14:30:00Z", previous: nil) == "Today 2:30 PM")
        #expect(label(at: "2026-08-16T14:30:41Z", previous: "2026-08-16T14:30:00Z") == nil)
    }

    /// The reported defect: a morning brief and an afternoon brief read as one message.
    @Test func aMultiHourGapOnTheSameDayStartsANewGroup() {
        #expect(label(at: "2026-08-16T08:00:00Z", previous: nil) == "Today 8:00 AM")
        #expect(label(at: "2026-08-16T14:30:00Z", previous: "2026-08-16T08:00:00Z") == "Today 2:30 PM")
    }

    @Test func theGroupingGapIsExclusiveAtItsBoundary() {
        #expect(label(at: "2026-08-16T10:59:00Z", previous: "2026-08-16T10:00:00Z") == nil)
        #expect(label(at: "2026-08-16T11:00:00Z", previous: "2026-08-16T10:00:00Z") == "Today 11:00 AM")
    }

    @Test func aDayBoundaryIsDatedRatherThanCalledToday() {
        #expect(label(at: "2026-08-15T18:00:00Z", previous: nil) == "Yesterday 6:00 PM")
        #expect(label(at: "2026-08-07T09:15:00Z", previous: nil) == "Fri, Aug 7 9:15 AM")
        #expect(label(at: "2025-11-02T09:15:00Z", previous: nil) == "Nov 2, 2025 9:15 AM")
    }

    /// Midnight separates even when the clock gap is well under the grouping threshold — otherwise
    /// last night's tail and this morning's opener share a heading.
    @Test func aDayBoundarySeparatesEvenInsideTheGroupingGap() {
        #expect(label(at: "2026-08-16T00:10:00Z", previous: "2026-08-15T23:50:00Z") == "Today 12:10 AM")
    }

    @Test func anEmptyTranscriptProducesNoSeparators() {
        #expect(ChatTimeSeparatorPolicy.separators(
            for: [], now: now, calendar: calendar, locale: locale
        ).isEmpty)
    }

    @Test func messagesWithoutUsableTimestampsProduceNoSeparators() {
        #expect(ChatTimeSeparatorPolicy.separators(
            for: [nil, nil], now: now, calendar: calendar, locale: locale
        ).isEmpty)
        // Zero, negative and non-finite timestamps are not treated as 1970.
        #expect(ChatTimeSeparatorPolicy.date(from: nil) == nil)
        #expect(ChatTimeSeparatorPolicy.date(from: 0) == nil)
        #expect(ChatTimeSeparatorPolicy.date(from: -1) == nil)
        #expect(ChatTimeSeparatorPolicy.date(from: .nan) == nil)
        #expect(ChatTimeSeparatorPolicy.date(from: .infinity) == nil)
    }

    /// Seconds and milliseconds both decode to the same instant.
    @Test func timestampsDecodeFromEitherSecondsOrMilliseconds() {
        let instant = date("2026-08-16T14:30:00Z")
        let seconds = instant.timeIntervalSince1970
        #expect(ChatTimeSeparatorPolicy.date(from: seconds) == instant)
        #expect(ChatTimeSeparatorPolicy.date(from: seconds * 1_000) == instant)
    }

    @Test func aWholeTranscriptFoldsToTheExpectedSeparatorSet() {
        let transcript: [Date?] = [
            date("2026-08-15T08:00:00Z"),   // 0 yesterday morning -> opens
            date("2026-08-15T08:00:30Z"),   // 1 reply 30s later   -> none
            date("2026-08-16T08:00:00Z"),   // 2 today morning     -> day boundary
            date("2026-08-16T08:02:00Z"),   // 3 reply 2m later    -> none
            nil,                            // 4 no timestamp      -> none
            date("2026-08-16T14:30:00Z"),   // 5 today afternoon   -> 6.5h gap
        ]

        let separators = ChatTimeSeparatorPolicy.separators(
            for: transcript, now: now, calendar: calendar, locale: locale
        )

        #expect(separators == [
            0: "Yesterday 8:00 AM",
            2: "Today 8:00 AM",
            5: "Today 2:30 PM",
        ])
    }

    /// An untimestamped message must not break a group: the fold carries the last date it trusts,
    /// so the row after it is still compared against the real previous message.
    @Test func anUntimestampedMessageDoesNotOpenASpuriousGroup() {
        let separators = ChatTimeSeparatorPolicy.separators(
            for: [date("2026-08-16T08:00:00Z"), nil, date("2026-08-16T08:01:00Z")],
            now: now,
            calendar: calendar,
            locale: locale
        )

        #expect(separators == [0: "Today 8:00 AM"])
    }

    /// AM/PM is joined by a plain space regardless of the ICU version's narrow no-break space.
    @Test func theLabelNeverCarriesANarrowNoBreakSpace() {
        let label = ChatTimeSeparatorPolicy.groupLabel(
            for: date("2026-08-16T14:30:00Z"), now: now, calendar: calendar, locale: locale
        )
        #expect(!label.unicodeScalars.contains("\u{202F}"))
        #expect(label == "Today 2:30 PM")
    }
}
