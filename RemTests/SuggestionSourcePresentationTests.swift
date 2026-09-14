import Foundation
import Testing
@testable import Rem

/// The source-attribution rules behind the "From {Gmail icon} {Slack icon}" line the founder asked
/// for on every suggestion surface (#1369). Pure functions, so the visual contract is pinned here
/// rather than only being observable by driving the app.
struct SuggestionSourcePresentationTests {
    private func suggestion(source: String) -> TaskSuggestion {
        TaskSuggestion(
            key: "\(source):1",
            actionId: UUID().uuidString,
            source: source,
            title: "Reply to Ada",
            subtitle: "Ada asked about the launch · \(source) · 2h ago",
            action: SuggestionAction(kind: "createTask", taskTitle: "Reply to Ada", targetTaskId: nil, startDate: nil)
        )
    }

    // MARK: Source → badge

    /// A connected source gets a badge, and its icon/label come from the SAME map Connectors
    /// settings uses (`ComposioToolkitPresentation`) — never a private copy that could disagree.
    @Test func connectorSourcesRenderTheirComposioIconAndLabel() {
        let gmail = SuggestionSourcePresentation.badges(for: suggestion(source: "gmail"))
        #expect(gmail.count == 1)
        #expect(gmail.first?.iconName == "envelope.fill")
        #expect(gmail.first?.displayName == "Gmail")

        let slack = SuggestionSourcePresentation.badges(for: suggestion(source: "slack"))
        #expect(slack.first?.iconName == "number")
        #expect(slack.first?.displayName == "Slack")

        let discord = SuggestionSourcePresentation.badges(for: suggestion(source: "discord"))
        #expect(discord.first?.iconName == "bubble.left.and.bubble.right.fill")
    }

    /// The behavioural crux: a tier-1 LOCAL source is not something the suggestion was ingested
    /// *from*, so it earns no "From …" badge — its own subtitle already names it. Without this
    /// special-case every calendar and overdue card would sprout a spurious source chip.
    @Test func localSourcesGetNoBadge() {
        #expect(SuggestionSourcePresentation.badges(for: suggestion(source: "calendar")).isEmpty)
        #expect(SuggestionSourcePresentation.badges(for: suggestion(source: "overdue")).isEmpty)
    }

    /// Aggregation (a separate lane) will fold several signals under one parent; when it does, the
    /// contributing sources render as an ordered, de-duplicated row of icons.
    @Test func multipleSourcesAreOrderedAndDeduplicated() {
        let badges = SuggestionSourcePresentation.badges(forSources: ["gmail", "slack", "gmail"])
        #expect(badges.map(\.source) == ["gmail", "slack"])
    }

    @Test func casingAndWhitespaceAreNormalized() {
        let badges = SuggestionSourcePresentation.badges(forSources: ["  Gmail  "])
        #expect(badges.map(\.source) == ["gmail"])
    }

    // MARK: Second-line cleaning (mechanical item)

    /// The raw connector summary can arrive wrapped in the gateway's "untrusted metadata" envelope.
    /// The second line must run the same cleaning chat and the session-list previews use, so the
    /// envelope never leaks onto the card.
    @Test func secondaryLineStripsInboundMetadataEnvelope() {
        let raw = """
        Sender (untrusted metadata):
        ```json
        {"label":"Ada"}
        ```
        Ada asked about the launch
        """
        let cleaned = SuggestionSourcePresentation.cleanedSecondaryLine(raw)
        #expect(cleaned?.contains("Ada asked about the launch") == true)
        #expect(cleaned?.contains("untrusted metadata") == false)
        #expect(cleaned?.contains("```") == false)
    }

    /// GFM tables and inline markup flatten to plain one-line prose (the summary-preview path),
    /// so a table-shaped summary reads as text under the title rather than as pipes.
    @Test func secondaryLineFlattensMarkdown() {
        let cleaned = SuggestionSourcePresentation.cleanedSecondaryLine("**Reply** to [Ada](mailto:ada@example.test)")
        #expect(cleaned == "Reply to Ada")
    }

    // MARK: Starter carries its source

    /// A personalized starter must carry its suggestion's source so the empty-chat starter can show
    /// the same "From …" attribution as the Agenda card it mirrors.
    @Test func personalizedStarterCarriesItsSource() {
        let starters = SharedRemChatView.starters(from: [suggestion(source: "gmail")])
        #expect(starters.first?.sources == ["gmail"])
    }

    /// The generic fallback set is derived from nothing, so it attributes nothing.
    @Test func genericStartersCarryNoSource() {
        #expect(SharedRemChatView.firstChatPrompts.allSatisfy { $0.sources.isEmpty })
    }
}
