import Foundation
import Testing

/// Suggestions used to be rendered by three hand-rolled `ForEach(…) { SuggestedTaskRow(…) }` blocks
/// with three different headers and paddings. There is no runtime assertion that can catch a fourth
/// copy appearing, so the DRY property is pinned at the source level: **only**
/// `SharedSuggestionSection` may build a `SuggestedTaskRow`.
struct SharedSuggestionSectionContractTests {
    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// The source of one member, brace-matched from its declaration.
    ///
    /// Needed because `String.contains` over a whole file cannot tell *where* a modifier is
    /// attached — and for the overflow sheet, where is the entire property being asserted. An
    /// earlier version of these tests checked only that `.suggestionOverflowSheet(` appeared
    /// somewhere in the file; moving it onto the section's own subtree restores the P1 and keeps
    /// that assertion green.
    ///
    /// Brace counting is naive (no string/comment awareness). That is safe in the direction that
    /// matters: over-capturing widens the region a negative assertion searches, so the test fails
    /// loudly rather than passing quietly. Valid Swift cannot make it under-capture.
    private func memberSource(declaredBy declaration: String, in source: String) throws -> String {
        let start = try #require(
            source.range(of: declaration)?.lowerBound,
            "Declaration not found — this test is out of date: \(declaration)"
        )
        var depth = 0
        var sawOpeningBrace = false
        for index in source.indices[start...] {
            switch source[index] {
            case "{":
                depth += 1
                sawOpeningBrace = true
            case "}":
                depth -= 1
                if sawOpeningBrace, depth == 0 {
                    return String(source[start...index])
                }
            default:
                break
            }
        }
        Issue.record("Unbalanced braces after \(declaration)")
        return String(source[start...])
    }

    /// Every surface that shows suggestions must go through the shared section. If this fails, a
    /// call site has grown its own copy again and the surfaces will drift apart.
    @Test func noSurfaceConstructsSuggestionRowsOutsideTheSharedSection() throws {
        let callSites = [
            "Shared/Views/Chat/SharedRemChatView.swift",
            "RemClaw/Sources/Screens/AgendaView.swift",
            "RemClawMac/Sources/UI/MacChatWindow.swift",
            "RemClawMac/Sources/UI/MacAgendaView.swift",
        ]

        for path in callSites {
            let text = try source(path)
            #expect(
                !text.contains("SuggestedTaskRow("),
                "\(path) builds suggestion rows directly; render SharedSuggestionSection instead."
            )
        }

        let section = try source("Shared/Views/Tasks/SharedSuggestionSection.swift")
        #expect(section.contains("SuggestedTaskRow("))
    }

    /// The list was *growing*. The cap and the overflow sheet are the fix, so both must stay.
    /// The affordance is a plain "See more" text label — no count, no chevron, no chrome.
    @Test func inlineSetIsBoundedAndOverflowGoesToASheet() throws {
        let section = try source("Shared/Views/Tasks/SharedSuggestionSection.swift")

        #expect(section.contains("static let defaultInlineLimit = 3"))
        #expect(section.contains("ordered.prefix("))
        #expect(section.contains("SuggestionOverflowSheet("))
        #expect(section.contains("static let seeMoreTitle = \"See more\""))
        #expect(section.contains("\"suggestions-see-more\""))
        #expect(!section.contains("chevron.right"), "The overflow affordance is a text label, not a chevron row.")
        #expect(!section.contains("See all \\("), "No count in the label — it reports how big the backlog got.")
    }

    /// The overflow sheet must be presented from a **stable ancestor**, never from the section or
    /// anything that renders it.
    ///
    /// Accepting a dated suggestion in the Agenda's null state synchronously appends to the task
    /// store (`AgendaViewModel.performAccept`, before its first `await`), which flips
    /// `hasItemsForSelectedDate` and swaps the null state for the populated `List` — taking the
    /// section with it. A presenter attached anywhere in that subtree closes the sheet on the
    /// *first* accept and drops whatever the user had not actioned yet.
    ///
    /// The negative assertions are the point. Asserting only that `.suggestionOverflowSheet(`
    /// appears in the file passes just as happily when it is attached to the section itself, which
    /// is exactly the regression.
    @Test func overflowSheetIsPresentedFromAStableAncestor() throws {
        let section = try source("Shared/Views/Tasks/SharedSuggestionSection.swift")
        #expect(section.contains("@Binding var isShowingAll: Bool"))
        #expect(
            !section.contains("@State private var isShowingAll"),
            "Section-owned presentation state dies with the section."
        )

        // Members that render the section — the presenter must not live in any of them.
        let sectionRenderers = [
            ("RemClaw/Sources/Screens/AgendaView.swift", [
                "private var suggestionSection: some View {",
                "private var suggestionRows: some View {",
                "private var suggestionStack: some View {",
            ]),
            ("Shared/Views/Chat/SharedRemChatView.swift", [
                "private var orchestratorSuggestionBlock: some View {",
            ]),
        ]

        for (path, declarations) in sectionRenderers {
            let text = try source(path)

            #expect(
                text.contains("@State private var isShowingAllSuggestions = false"),
                "\(path) must own the overflow sheet's presentation state."
            )
            #expect(
                text.contains(".suggestionOverflowSheet("),
                "\(path) must attach the overflow sheet."
            )

            for declaration in declarations {
                let member = try memberSource(declaredBy: declaration, in: text)
                #expect(
                    !member.contains(".suggestionOverflowSheet("),
                    """
                    \(path) attaches the overflow sheet inside `\(declaration)`. \
                    That subtree is torn down when the surface swaps, which closes the sheet \
                    mid-triage. Attach it on the screen root instead.
                    """
                )
                #expect(
                    !member.contains(".sheet("),
                    """
                    \(path) presents a sheet inside `\(declaration)`, which is not a stable \
                    ancestor of the suggestion rows.
                    """
                )
            }
        }
    }

    /// Contextual-to-the-brief is the requirement, not a nice-to-have: the bounded set is chosen by
    /// relevance to the brief it sits beside, and both call sites must actually pass the brief.
    @Test func inlineSetIsOrderedAgainstTheBrief() throws {
        let section = try source("Shared/Views/Tasks/SharedSuggestionSection.swift")
        #expect(section.contains("SuggestionBriefRelevance.ranked(suggestions, briefMarkdown: briefMarkdown)"))
        #expect(
            section.contains("let ordered = SuggestionBriefRelevance.ranked"),
            "Rank once per body evaluation, not once per computed-property read."
        )

        let chat = try source("Shared/Views/Chat/SharedRemChatView.swift")
        #expect(chat.contains("briefMarkdown: snapshot.briefMarkdown"))

        let agenda = try source("RemClaw/Sources/Screens/AgendaView.swift")
        #expect(agenda.contains("briefMarkdown: visibleSuggestionsBriefMarkdown"))
    }

    /// The header subtext above the suggestions is gone, and the header title no longer differs by
    /// screen.
    @Test func headerHasNoSubtextAndOneTitle() throws {
        let chat = try source("Shared/Views/Chat/SharedRemChatView.swift")

        #expect(!chat.contains("Rem noticed these signals"))
        #expect(!chat.contains("Suggested next steps"))

        let section = try source("Shared/Views/Tasks/SharedSuggestionSection.swift")
        #expect(section.contains("static let headerTitle = \"Suggestions\""))
    }

    /// The rows are meant to fill their container. Without this the dashed ring shrink-wraps each
    /// row to its own title length, which is the "inset in a way that looks unintentional" report.
    @Test func rowsAndSectionClaimFullWidth() throws {
        let row = try source("Shared/Views/Tasks/SuggestedTaskRow.swift")
        #expect(row.contains(".frame(maxWidth: .infinity, alignment: .leading)"))

        let section = try source("Shared/Views/Tasks/SharedSuggestionSection.swift")
        #expect(section.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }
}
