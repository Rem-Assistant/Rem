import SwiftUI

/// **The** suggestion surface. Every place suggestions appear — the Agenda's populated day, the
/// Agenda's empty day, and the orchestrator chat on both iOS and Mac — renders this one view.
///
/// Before this existed there were three hand-rolled `ForEach(suggestions) { SuggestedTaskRow(…) }`
/// blocks with three different headers, three different paddings, and three different vertical
/// rhythms; the chat one additionally carried a paragraph of explanatory subtext the others did
/// not. Divergence like that is why the same list read as a different feature on each screen.
///
/// Three behaviours are owned here so no call site can drift again:
///
/// 1. **Bounded inline set.** Only `inlineLimit` rows render in place. The list was *growing*, and
///    an unbounded proposal list stops reading as "here are your next steps" and starts reading as
///    a backlog the user did not ask for.
/// 2. **Overflow into a sheet.** The remainder is one tap away behind a plain "See more" text
///    label — progressive disclosure, nothing dropped. Accept/Dismiss work identically in the
///    sheet, which is presented from a stable ancestor (see `suggestionOverflowSheet`).
/// 3. **Contextual ordering.** Which suggestions make the inline cut is decided by
///    `SuggestionBriefRelevance` against the brief they sit beside, so the visible ones relate to
///    what the user is reading rather than to whatever the deriver emitted first.
///
/// Self-contained (DesignTokens only, no UIKit/AppKit) so it compiles into both targets per the
/// DRY rule in `CLAUDE.md`. It takes plain data and closures rather than being generic over
/// `GatewaySessionProviding`, because nothing here needs session state.
struct SharedSuggestionSection: View {
    let suggestions: [TaskSuggestion]
    /// The brief prose these suggestions sit beside, if any. Drives contextual ordering; nil (the
    /// Agenda's null state, a day with no authored brief) simply keeps the deriver's order.
    var briefMarkdown: String?
    /// How many rows render in place before the rest move behind "See all".
    var inlineLimit: Int = SharedSuggestionSection.defaultInlineLimit
    /// Presentation state for the overflow sheet, owned by a **stable ancestor** — see
    /// `suggestionOverflowSheet(isPresented:…)`. It is not `@State` here on purpose: this section
    /// is rendered inside containers that can vanish underneath a presented sheet (a `List` row,
    /// the chat transcript's `LazyVStack`, and — the case that actually bites — the Agenda's null
    /// state, which is swapped out for the populated `List` the instant the first accepted
    /// suggestion lands in the task store). Owning the flag here would take the presenter down
    /// with it and drop the remaining suggestions mid-triage.
    @Binding var isShowingAll: Bool
    let onAccept: (TaskSuggestion) -> Void
    let onDismiss: (TaskSuggestion) -> Void

    /// Three is the most that reads as "a few next steps" rather than "a list". It also matches the
    /// cap `SharedRemChatView.starters(from:)` already applies to the chat-starter surface fed by
    /// the same deriver, so the two never disagree about how much is "some".
    static let defaultInlineLimit = 3

    /// One header string everywhere. The chat used to say "Suggested next steps" over a paragraph
    /// of subtext; the subtext is gone (it explained an interaction the row's own Add/✕ affordances
    /// already state) and the title now matches the Agenda's.
    static let headerTitle = "Suggestions"

    /// Founder-specified copy. Deliberately no count ("See all 7") — a number turns the overflow
    /// into a report on how big the backlog got, which is the thing being complained about.
    static let seeMoreTitle = "See more"

    var body: some View {
        // Ranked once per body evaluation. As computed properties these re-tokenized the whole
        // brief on every read — six-plus times per render, inside a `List` row.
        let ordered = SuggestionBriefRelevance.ranked(suggestions, briefMarkdown: briefMarkdown)
        let inline = Array(ordered.prefix(max(0, inlineLimit)))
        let overflowCount = max(0, ordered.count - inline.count)

        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(Self.headerTitle)
                    .font(DesignTokens.Typography.footnote.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(inline) { suggestion in
                    SuggestedTaskRow(
                        suggestion: suggestion,
                        onAccept: { onAccept(suggestion) },
                        onDismiss: { onDismiss(suggestion) }
                    )
                }

                if overflowCount > 0 {
                    seeMoreLabel
                }
            }
            // The section fills whatever it is given. Call sites own their outer inset (16pt in
            // both the Agenda list and the chat transcript, matching the content beside them);
            // none of them get to make the section narrower than its container.
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("orchestrator-suggested-tasks")
        }
    }

    /// A plain text label, as specified: no chrome, no border, no chevron, no count. It carries the
    /// brand tint only so it reads as tappable — that is type colour, not chrome. `.plain` button
    /// style keeps SwiftUI from adding a background or bezel of its own.
    private var seeMoreLabel: some View {
        Button {
            isShowingAll = true
        } label: {
            Text(Self.seeMoreTitle)
                .font(DesignTokens.Typography.footnote.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.brandBlueOnFill)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("suggestions-see-more")
        .accessibilityLabel("See more suggestions")
    }
}

extension View {
    /// Attach the suggestion overflow sheet to a **stable ancestor** of `SharedSuggestionSection` —
    /// a screen root, never the section itself and never anything inside a lazy container.
    ///
    /// Two things depend on the presenter outliving the section:
    ///   • **Agenda null state.** Accepting a dated suggestion synchronously appends to the task
    ///     store, which flips `hasItemsForSelectedDate` and swaps the null state for the populated
    ///     `List`. A sheet owned by the section would be torn down on the *first* accept, dropping
    ///     the rest of the list the user was working through.
    ///   • **Self-close.** The sheet closes when the last suggestion is actioned. That is driven
    ///     from *this* side (see `SuggestionOverflowPresentation`), not from inside the sheet — the
    ///     section is already gone by then, and an `onChange` inside the sheet's own body would
    ///     depend on SwiftUI re-invoking the content closure, which is plausible but was never
    ///     actually verified. Gating the `isPresented` binding depends only on the ancestor
    ///     re-rendering, which it must: its own state is what changed.
    ///
    /// `suggestions` must be the caller's live array (not a captured copy) so the sheet re-renders
    /// as rows are accepted or dismissed.
    func suggestionOverflowSheet(
        isPresented: Binding<Bool>,
        suggestions: [TaskSuggestion],
        briefMarkdown: String?,
        onAccept: @escaping (TaskSuggestion) -> Void,
        onDismiss: @escaping (TaskSuggestion) -> Void
    ) -> some View {
        let gated = Binding(
            get: {
                SuggestionOverflowPresentation.isPresented(
                    requested: isPresented.wrappedValue,
                    suggestionCount: suggestions.count
                )
            },
            set: { isPresented.wrappedValue = $0 }
        )
        return sheet(isPresented: gated) {
            SuggestionOverflowSheet(
                suggestions: SuggestionBriefRelevance.ranked(suggestions, briefMarkdown: briefMarkdown),
                onAccept: onAccept,
                onDismiss: onDismiss
            )
        }
    }
}

/// Whether the overflow sheet should currently be on screen. Pulled out as a pure function so the
/// self-close rule is executable in a plain test rather than only observable by driving the app.
public enum SuggestionOverflowPresentation {
    /// The sheet stays up only while there is something left in it. Actioning the last suggestion
    /// empties the caller's array, this returns false, and SwiftUI takes the sheet down — no
    /// dependence on the sheet's own body re-running.
    public static func isPresented(requested: Bool, suggestionCount: Int) -> Bool {
        requested && suggestionCount > 0
    }
}

/// The overflow drill-down: every suggestion, same rows, same actions. A sheet rather than a push
/// because suggestions are a side errand — the user is meant to come straight back to the brief or
/// the agenda they were reading.
struct SuggestionOverflowSheet: View {
    let suggestions: [TaskSuggestion]
    let onAccept: (TaskSuggestion) -> Void
    let onDismiss: (TaskSuggestion) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(SharedSuggestionSection.headerTitle)
                    .font(DesignTokens.Typography.title3Bold)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)

                Spacer(minLength: DesignTokens.Spacing.md)

                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.brandBlueOnFill)
                    .accessibilityIdentifier("suggestions-sheet-done")
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    ForEach(suggestions) { suggestion in
                        SuggestedTaskRow(
                            suggestion: suggestion,
                            onAccept: { onAccept(suggestion) },
                            onDismiss: { onDismiss(suggestion) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Color.backgroundPrimary)
        .accessibilityIdentifier("suggestions-overflow-sheet")
        // No self-close here on purpose. Actioning the last suggestion empties the presenter's
        // array, and `SuggestionOverflowPresentation` takes the sheet down from that side.
        .modifier(SuggestionOverflowSheetSizing())
    }
}

/// macOS sheets have no natural content size, so give the overflow sheet a floor. Split out as a
/// modifier because `#if` inside a modifier chain is fragile across toolchains.
private struct SuggestionOverflowSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 420, minHeight: 420)
        #else
        content
        #endif
    }
}
