import Foundation

/// Orders suggestions by how much they relate to the brief they are rendered beside.
///
/// The complaint that motivated this was not "too few suggestions" — it was *"the suggestion list
/// is growing btw and its just irrelevant items"*, with the ask that the surface be **contextual to
/// the brief**. So the bounded inline set is deliberately NOT "the first N the deriver happened to
/// emit": it is the N that share the most ground with the brief prose the user is actually reading.
/// Everything else stays reachable behind "See all" — nothing is hidden, only deprioritised.
///
/// Lexical on purpose, not model-scored. This runs on every render, so it must be:
///   • **deterministic** — the same brief + the same suggestions always produce the same order, so
///     a row never reshuffles under the user's thumb between two frames;
///   • **total** — no network, no async, no failure mode;
///   • **inert without a brief** — a nil/empty/non-overlapping brief returns the deriver's order
///     untouched, because an unrelated brief must not scramble an otherwise fine list.
public enum SuggestionBriefRelevance {
    /// A title match counts double. The brief naming *the thing being suggested* is a far stronger
    /// relevance signal than an incidental word in the attribution line.
    private static let titleWeight = 2
    private static let subtitleWeight = 1

    /// Below this length a token carries no topical signal ("the", "and", "9am", "due").
    private static let minimumTokenLength = 4

    /// Words that appear in nearly every brief and nearly every suggestion, so matching on them
    /// would rank noise to the top.
    ///
    /// Three groups, all for the same reason — they describe the *shape* of a suggestion rather
    /// than its subject, so every suggestion of that shape would tie and the ranking would decide
    /// nothing:
    ///   • ordinary English filler;
    ///   • deriver vocabulary — every overdue suggestion's attribution says "overdue", every
    ///     calendar one ends "· Calendar";
    ///   • **connected-source names** — since #1302 the deriver emits channel signals whose
    ///     attribution carries the source ("· Gmail", "· Slack"). A brief that mentions Gmail would
    ///     otherwise lift every Gmail-sourced suggestion by the same amount.
    private static let stopWords: Set<String> = [
        // Ordinary filler.
        "about", "afternoon", "after", "again", "also", "been", "before", "being", "between",
        "both", "could", "does", "doing", "done", "down", "during", "each", "evening", "from",
        "have", "here", "into", "just", "like", "make", "more", "morning", "most", "need",
        "next", "only", "other", "over", "same", "should", "since", "some", "such", "than",
        "that", "them", "then", "there", "these", "they", "this", "those", "through", "time",
        "today", "under", "until", "very", "were", "what", "when", "where", "which", "while",
        "will", "with", "would", "your",
        // Deriver vocabulary.
        "calendar", "event", "events", "meeting", "overdue", "reminder", "reminders",
        "reschedule", "scheduled", "task", "tasks",
        // Connected-source names.
        "email", "gcal", "gmail", "inbox", "mail", "message", "messages", "notion", "slack",
        "thread", "threads",
    ]

    /// Suggestions ordered most-brief-relevant first.
    ///
    /// Ties keep the deriver's original order, so the result is a stable reordering rather than an
    /// arbitrary one (`Array.sorted` is not itself guaranteed stable, hence the explicit offset
    /// tiebreak). When nothing matches, the input is returned verbatim.
    public static func ranked(
        _ suggestions: [TaskSuggestion],
        briefMarkdown: String?
    ) -> [TaskSuggestion] {
        let briefTokens = significantTokens(in: briefMarkdown ?? "")
        guard !briefTokens.isEmpty else { return suggestions }

        let scored = suggestions.enumerated().map { offset, suggestion in
            (
                offset: offset,
                suggestion: suggestion,
                score: relevanceScore(for: suggestion, briefTokens: briefTokens)
            )
        }

        // Nothing in the brief relates to anything on the list: leave it alone rather than
        // performing a no-op shuffle that only costs the user their positional memory.
        guard scored.contains(where: { $0.score > 0 }) else { return suggestions }

        return scored
            .sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.offset < rhs.offset : lhs.score > rhs.score
            }
            .map(\.suggestion)
    }

    /// Distinct significant tokens this suggestion shares with the brief, title-weighted. A token
    /// that appears in both the title and the subtitle is counted once, at the title weight.
    public static func relevanceScore(
        for suggestion: TaskSuggestion,
        briefTokens: Set<String>
    ) -> Int {
        let titleTokens = significantTokens(in: suggestion.title)
        let titleMatches = titleTokens.intersection(briefTokens).count
        let subtitleMatches = significantTokens(in: suggestion.subtitle)
            .subtracting(titleTokens)
            .intersection(briefTokens)
            .count
        return titleMatches * titleWeight + subtitleMatches * subtitleWeight
    }

    /// Lowercased alphanumeric tokens worth matching on. Markdown punctuation, the `·` separators
    /// the deriver uses in attribution lines, and quotes all fall out as delimiters.
    public static func significantTokens(in text: String) -> Set<String> {
        let pieces = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(
            pieces
                .lazy
                .map(String.init)
                .filter { $0.count >= minimumTokenLength && !stopWords.contains($0) }
        )
    }
}
