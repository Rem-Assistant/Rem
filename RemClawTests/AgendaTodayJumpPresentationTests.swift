import Foundation
import Testing
@testable import RemClaw

struct AgendaTodayJumpPresentationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func jumpControlOnlyAppearsAwayFromToday() {
        let now = Date(timeIntervalSince1970: 1_786_089_600) // 2026-08-07 08:00 UTC
        let laterToday = now.addingTimeInterval(60 * 60 * 10)
        let yesterday = now.addingTimeInterval(-60 * 60 * 24)
        let tomorrow = now.addingTimeInterval(60 * 60 * 24)

        #expect(!AgendaTodayJumpPresentation.shouldShow(
            selectedDate: laterToday,
            now: now,
            calendar: calendar
        ))
        #expect(AgendaTodayJumpPresentation.shouldShow(
            selectedDate: yesterday,
            now: now,
            calendar: calendar
        ))
        #expect(AgendaTodayJumpPresentation.shouldShow(
            selectedDate: tomorrow,
            now: now,
            calendar: calendar
        ))
    }
}
