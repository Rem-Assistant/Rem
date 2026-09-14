import Foundation

/// How the Agenda summary card presents a `DailyBrief` — title and prose selection.
///
/// Deliberately a **Foundation-only** file, split out of `DailyBriefCard.swift` (which imports
/// SwiftUI and UIKit). The card's title is one half of the "one headline, both surfaces" contract
/// — the other half is `BriefContext.displayTitle` — and that contract is only worth anything if
/// it is *executed* in a test. Keeping this logic free of UI imports lets the convergence test
/// compile and run on macOS, so the two surfaces can be asserted against the same decoded payload
/// without booting a simulator.
enum DailyBriefAgendaPresentation {
    /// The Agenda summary card's header. Reads the brief's authored headline — the SAME field the
    /// orchestrator chat titles itself with (see `BriefContext.displayTitle`), so tapping the card
    /// no longer changes the name of the thing you tapped.
    ///
    /// Falls back to the old clock-derived greeting ONLY when the artifact has no authored
    /// headline (pre-migration-119 rows, or no delivered artifact yet). That keeps every existing
    /// brief exactly as good as it was before the headline field existed.
    static func title(for brief: DailyBrief, now: Date = Date(), calendar: Calendar = .current) -> String {
        brief.briefHeadline ?? timeOfDayTitle(now: now, calendar: calendar)
    }

    static func timeOfDayTitle(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: now) {
        case 0..<12: return "Good morning"
        case 12..<17: return "Your afternoon"
        default: return "Evening recap"
        }
    }

    static func prose(for brief: DailyBrief) -> String? {
        guard brief.hasAgendaSurface else { return nil }
        return brief.displayedBriefSummary ?? markdownExcerpt(brief.displayedBriefMarkdown)
    }

    static func shouldShowCounts(for brief: DailyBrief) -> Bool {
        prose(for: brief) == nil
    }

    /// Extract a compact plain-text lead from canonical markdown. Body prose and list items carry
    /// more information than generic headings, so headings are used only as a final fallback.
    static func markdownExcerpt(_ markdown: String?) -> String? {
        guard let markdown else { return nil }
        var headingFallback: String?

        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let isHeading = line.hasPrefix("#")
            let stripped = line.replacingOccurrences(
                of: #"^(?:#{1,6}\s*|[-*+]\s+|\d+[.)]\s+|>\s*)"#,
                with: "",
                options: .regularExpression
            )
            let excerpt = stripped
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !excerpt.isEmpty else { continue }

            let capped = excerpt.count > 200
                ? String(excerpt.prefix(199)) + "…"
                : excerpt
            if isHeading {
                headingFallback = headingFallback ?? capped
            } else {
                return capped
            }
        }

        return headingFallback
    }
}
