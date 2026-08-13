import Foundation

/// Decides where a "mini divider" belongs in a chat transcript, and what it says.
///
/// Two briefs delivered on the same day (a morning update and an afternoon one) previously abutted
/// with no visual break, so they read as a single long message. The separator is the punctuation
/// that keeps two deliveries legible as two deliveries.
///
/// Deliberately pure and Foundation-only: the grouping decision is about timestamps, not about
/// message structure, so it can be exercised directly without a simulator or the OpenClaw packages.
/// The `OpenClawChatMessage` adapter lives at the call site in `SharedRemChatView`.
enum ChatTimeSeparatorPolicy {
    /// Messages further apart than this begin a new group. One hour is the common messaging-app
    /// default and comfortably separates a morning brief from an afternoon one, while keeping the
    /// turns of a single conversation under one heading.
    static let groupingGap: TimeInterval = 60 * 60

    /// The separator to render *above* the message at `date`, or `nil` to keep it in the current
    /// group. `previous` is the preceding visible message's date, `nil` for the first message —
    /// which always opens a group, so an empty transcript yields nothing at all.
    static func label(
        at date: Date,
        previous: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        if let previous,
           calendar.isDate(previous, inSameDayAs: date),
           abs(date.timeIntervalSince(previous)) < groupingGap {
            return nil
        }
        return groupLabel(for: date, now: now, calendar: calendar, locale: locale)
    }

    /// Day-aware heading plus the time of day, e.g. `Today 2:30 PM`, `Yesterday 8:00 AM`,
    /// `Thu, Aug 7 9:15 AM`.
    static func groupLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let raw = timeFormatter(calendar: calendar, locale: locale).string(from: date)
        // ICU on iOS/macOS 16+ emits U+202F NARROW NO-BREAK SPACE before AM/PM, where older
        // versions emit a plain space. The glyph is indistinguishable on screen but makes the
        // string compare unequal, so normalise it: this label is short, centred and never wraps,
        // and a stable string is worth more here than the no-break guarantee.
        let time = raw.replacingOccurrences(of: "\u{202F}", with: " ")
        return "\(dayLabel(for: date, now: now, calendar: calendar, locale: locale)) \(time)"
    }

    static func isSameDay(_ date: Date, as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(date, inSameDayAs: other)
    }

    /// The whole transcript's separators, indexed by message position — `separators(for:)[i]` is the
    /// label above message `i`. The view resolves per index (it interleaves the brief-preview
    /// bridge), so this is a fold over the same `label(at:previous:)` core rather than a second
    /// rule set; it exists so the grouping decision is testable as one value.
    static func separators(
        for dates: [Date?],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [Int: String] {
        var result: [Int: String] = [:]
        var previous: Date?
        for (index, date) in dates.enumerated() {
            // A message with no usable timestamp can neither open nor close a group: it renders
            // under the heading it arrived beneath, and leaves `previous` alone so the next real
            // timestamp is still compared against the last one we trust.
            guard let date else { continue }
            if let label = label(
                at: date, previous: previous, now: now, calendar: calendar, locale: locale
            ) {
                result[index] = label
            }
            previous = date
        }
        return result
    }

    /// Gateway history timestamps are milliseconds. Tolerate second-based fixtures/legacy rows.
    static func date(from timestamp: Double?) -> Date? {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return nil }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }

    private static func dayLabel(
        for date: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        // `Calendar.isDateInYesterday` is relative to the wall clock and would ignore the injected
        // `now` used for deterministic rendering/tests. Compare day starts against the same source.
        let dayOffset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day
        if dayOffset == 1 { return "Yesterday" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "EEE, MMM d"
            : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func timeFormatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        // Locale-driven so 24-hour regions read correctly; never a hardcoded `h:mm a`.
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }
}
