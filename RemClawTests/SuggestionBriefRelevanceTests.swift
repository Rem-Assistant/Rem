import Foundation
import Testing
@testable import RemClaw

/// The inline suggestion set is bounded, so *which* suggestions survive the cut is the whole
/// feature — "the suggestion list is growing btw and its just irrelevant items". These tests pin
/// the ordering contract that decides it.
struct SuggestionBriefRelevanceTests {
    private func suggestion(
        key: String,
        title: String,
        subtitle: String,
        kind: String = "createTask"
    ) -> TaskSuggestion {
        TaskSuggestion(
            key: key,
            actionId: UUID().uuidString,
            source: "calendar",
            title: title,
            subtitle: subtitle,
            action: SuggestionAction(
                kind: kind,
                taskTitle: title,
                targetTaskId: nil,
                startDate: nil
            )
        )
    }

    @Test func briefRelatedSuggestionsRankAboveUnrelatedOnes() {
        let brief = """
        Your morning is dominated by the Hartwell contract review. Legal wants redlines back before
        the board call.
        """
        let unrelated = suggestion(
            key: "cal:gym",
            title: "Book squash court",
            subtitle: "Recurring · Calendar"
        )
        let related = suggestion(
            key: "cal:hartwell",
            title: "Draft Hartwell redlines",
            subtitle: "Contract review · Calendar"
        )
        let alsoUnrelated = suggestion(
            key: "cal:dentist",
            title: "Confirm dentist appointment",
            subtitle: "Voicemail · Phone"
        )

        let ranked = SuggestionBriefRelevance.ranked(
            [unrelated, related, alsoUnrelated],
            briefMarkdown: brief
        )

        #expect(ranked.first?.key == "cal:hartwell")
        #expect(ranked.count == 3, "Ranking reorders — it must never drop a suggestion.")
        #expect(Set(ranked.map(\.key)) == Set(["cal:gym", "cal:hartwell", "cal:dentist"]))
    }

    @Test func titleMatchOutranksSubtitleMatch() {
        let brief = "Standup is at 9. Then the Peregrine migration."
        let subtitleOnly = suggestion(
            key: "cal:notes",
            title: "Write up notes",
            subtitle: "Peregrine · Calendar"
        )
        let titleMatch = suggestion(
            key: "cal:peregrine",
            title: "Peregrine cutover checklist",
            subtitle: "Flagged · Mail"
        )

        let ranked = SuggestionBriefRelevance.ranked([subtitleOnly, titleMatch], briefMarkdown: brief)

        #expect(ranked.map(\.key) == ["cal:peregrine", "cal:notes"])
    }

    @Test func tiesKeepDeriverOrderSoRowsDoNotReshuffle() {
        let brief = "Two things share the word Falkirk today: Falkirk sync and Falkirk recap."
        let first = suggestion(key: "cal:a", title: "Falkirk sync prep", subtitle: "Calendar")
        let second = suggestion(key: "cal:b", title: "Falkirk recap notes", subtitle: "Calendar")

        let ranked = SuggestionBriefRelevance.ranked([first, second], briefMarkdown: brief)
        let rerankedReversedInput = SuggestionBriefRelevance.ranked([second, first], briefMarkdown: brief)

        #expect(ranked.map(\.key) == ["cal:a", "cal:b"])
        #expect(rerankedReversedInput.map(\.key) == ["cal:b", "cal:a"])
    }

    @Test func absentOrUnrelatedBriefLeavesOrderUntouched() {
        let items = [
            suggestion(key: "cal:a", title: "Book squash court", subtitle: "Calendar"),
            suggestion(key: "cal:b", title: "Confirm dentist", subtitle: "Phone"),
        ]

        #expect(SuggestionBriefRelevance.ranked(items, briefMarkdown: nil).map(\.key) == ["cal:a", "cal:b"])
        #expect(SuggestionBriefRelevance.ranked(items, briefMarkdown: "").map(\.key) == ["cal:a", "cal:b"])
        #expect(
            SuggestionBriefRelevance
                .ranked(items, briefMarkdown: "Nothing here overlaps whatsoever.")
                .map(\.key) == ["cal:a", "cal:b"],
            "A brief about something else must not shuffle a perfectly good list."
        )
    }

    /// Guards the reason the stop list exists: every overdue suggestion says "overdue" and every
    /// calendar one says "Calendar", so matching those would tie the whole list at the top and the
    /// ranking would decide nothing.
    @Test func sharedDomainVocabularyDoesNotCountAsRelevance() {
        let brief = "You have overdue tasks on the calendar today."
        let items = [
            suggestion(key: "overdue:a", title: "Reschedule to today", subtitle: "'File visa paperwork' · overdue 3d", kind: "rescheduleTask"),
            suggestion(key: "cal:b", title: "Prep for Standup", subtitle: "Standup · 9:00 AM · Calendar"),
        ]

        let ranked = SuggestionBriefRelevance.ranked(items, briefMarkdown: brief)

        #expect(ranked.map(\.key) == ["overdue:a", "cal:b"], "No match should mean no reorder.")
    }

    @Test func shortWordsAreNotRelevanceSignals() {
        let tokens = SuggestionBriefRelevance.significantTokens(in: "The 9am due sync for Hartwell")

        #expect(tokens.contains("hartwell"))
        #expect(tokens.contains("sync"))
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("due"))
        #expect(!tokens.contains("9am"))
    }

    /// The attribution line the deriver emits is `'File visa paperwork' · overdue 3d` — the `·` separators
    /// and quotes must fall out as delimiters, or the whole line becomes one unmatchable token.
    @Test func attributionPunctuationSplitsIntoTokens() {
        let tokens = SuggestionBriefRelevance.significantTokens(in: "'File visa paperwork' · overdue 3d · Gmail")

        #expect(tokens.contains("file"))
        #expect(!tokens.contains("overdue"), "Deriver vocabulary is filtered out.")
        #expect(!tokens.contains("gmail"), "Connected-source names are filtered out.")
    }

    /// Since #1302 the deriver emits connected-source signals whose attribution carries the source.
    /// A brief that names the source must not lift every suggestion from that source equally — that
    /// ties the whole class and the ranking stops discriminating.
    @Test func connectedSourceNameDoesNotLiftEverySuggestionFromThatSource() {
        let brief = "Gmail has three threads waiting. One is from Okonkwo about the lease."
        let items = [
            suggestion(key: "gm:a", title: "Reply to newsletter", subtitle: "Gmail · 2h ago"),
            suggestion(key: "gm:b", title: "Reply to Okonkwo", subtitle: "Gmail · 20m ago"),
            suggestion(key: "gm:c", title: "Archive receipts", subtitle: "Gmail · 1d ago"),
        ]

        let ranked = SuggestionBriefRelevance.ranked(items, briefMarkdown: brief)

        #expect(
            ranked.first?.key == "gm:b",
            "The one the brief is actually about should win, not all three tied on 'Gmail'."
        )
    }
}
