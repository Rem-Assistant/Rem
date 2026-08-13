import Foundation
import Testing
@testable import RemClaw

/// When the suggestion section renders alongside the empty chat, starters derived from those same
/// suggestions must be dropped — but *only* those.
///
/// The first cut suppressed the whole starter list, on the reasoning that starters "are derived
/// from these very suggestions". That is false for the generic fallback set, which is derived from
/// nothing: `MacChatWindow` never passes `starterPrompts`, so **every Mac chat** silently lost its
/// starters, and iOS lost them too whenever a snapshot held only reschedule suggestions (
/// `starters(from:)` filters to `createTask`, and `StarterObserver` then falls back to generic).
/// These tests run the rule rather than grepping for it.
struct SharedRemChatStarterSuppressionTests {
    private func suggestion(key: String, title: String) -> TaskSuggestion {
        TaskSuggestion(
            key: key,
            actionId: UUID().uuidString,
            source: "calendar",
            title: title,
            subtitle: "Calendar",
            action: SuggestionAction(kind: "createTask", taskTitle: title, targetTaskId: nil, startDate: nil)
        )
    }

    /// The regression, stated directly: Mac always gets the generic set, and the generic set shares
    /// no id with any suggestion, so all of it must survive.
    @Test func genericFallbackStartersSurviveAlongsideSuggestions() {
        let suggestions = [
            suggestion(key: "cal:standup", title: "Prep for Standup"),
            suggestion(key: "overdue:visa", title: "File visa paperwork"),
        ]

        let visible = SharedRemChatView.visibleStarters(
            from: SharedRemChatView.firstChatPrompts,
            suppressingIDs: Set(suggestions.map(\.key))
        )

        #expect(
            visible.map(\.id) == SharedRemChatView.firstChatPrompts.map(\.id),
            "Mac has no personalized starters; suppressing them empties its whole empty state."
        )
    }

    /// The duplication the suppression exists to prevent: a derived starter carries its
    /// suggestion's key as its id, so it is literally the same item as the row below it.
    @Test func derivedStartersAreDroppedWhenShownAsSuggestionRows() {
        let suggestions = [
            suggestion(key: "cal:standup", title: "Prep for Standup"),
            suggestion(key: "cal:ada", title: "Reply to Ada"),
        ]
        let derived = SharedRemChatView.starters(from: suggestions)
        #expect(derived.map(\.id) == ["cal:standup", "cal:ada"], "Precondition: id is the key.")

        let visible = SharedRemChatView.visibleStarters(
            from: derived,
            suppressingIDs: Set(suggestions.map(\.key))
        )

        #expect(visible.isEmpty)
    }

    /// A starter whose suggestion is no longer on screen must come back — suppression is scoped to
    /// what is actually rendered, not a permanent blocklist.
    @Test func onlyOverlappingStartersAreDropped() {
        let derived = SharedRemChatView.starters(from: [
            suggestion(key: "cal:standup", title: "Prep for Standup"),
            suggestion(key: "cal:ada", title: "Reply to Ada"),
        ])

        let visible = SharedRemChatView.visibleStarters(
            from: derived,
            suppressingIDs: ["cal:standup"]
        )

        #expect(visible.map(\.id) == ["cal:ada"])
    }

    @Test func noSuggestionsOnScreenSuppressesNothing() {
        let visible = SharedRemChatView.visibleStarters(
            from: SharedRemChatView.firstChatPrompts,
            suppressingIDs: []
        )

        #expect(visible.count == SharedRemChatView.firstChatPrompts.count)
    }

    /// The overflow sheet's self-close, as an executable rule rather than an assumption about when
    /// SwiftUI re-invokes a sheet's content closure.
    @Test func overflowSheetStaysUpOnlyWhileItHasContent() {
        #expect(SuggestionOverflowPresentation.isPresented(requested: true, suggestionCount: 3))
        #expect(SuggestionOverflowPresentation.isPresented(requested: true, suggestionCount: 1))
        #expect(
            !SuggestionOverflowPresentation.isPresented(requested: true, suggestionCount: 0),
            "Actioning the last suggestion must take the sheet down, not leave an empty modal."
        )
        #expect(!SuggestionOverflowPresentation.isPresented(requested: false, suggestionCount: 5))
    }
}
