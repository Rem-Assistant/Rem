import SwiftUI

#if DEBUG
/// Auth-free proof of the suggestion source-attribution work (#1369): the trailing
/// "From {source icon(s)}" on the second metadata line, the metadata cleaning applied to that
/// line, and the tightened empty-chat starter. Reachable via `--rem-suggestions-fixture` — no
/// gateway, no sign-in, no live view model.
///
/// The Gmail sample deliberately carries a raw "untrusted metadata" envelope so the screenshot
/// shows the cleaner stripping it; the calendar and overdue samples carry no badge (they are not
/// ingested connector sources).
struct SuggestionSourceFixtureView: View {
    @State private var isShowingAll = false

    private static func suggestion(
        key: String,
        source: String,
        title: String,
        subtitle: String,
        kind: String = "createTask"
    ) -> TaskSuggestion {
        TaskSuggestion(
            key: key,
            actionId: UUID().uuidString,
            source: source,
            title: title,
            subtitle: subtitle,
            action: SuggestionAction(kind: kind, taskTitle: title, targetTaskId: nil, startDate: nil)
        )
    }

    private let suggestions: [TaskSuggestion] = [
        suggestion(
            key: "gmail:1",
            source: "gmail",
            title: "Reply to Ada about the launch date",
            // Raw connector summary wrapped in the gateway's untrusted-metadata envelope — the
            // second line must render this as clean prose, not the envelope.
            subtitle: """
            3:00 PM · Sender (untrusted metadata):
            ```json
            {"from":"ada@example.test"}
            ```
            Can we lock the launch date this week? I need to brief the team and the copy is blocked on it. · Gmail · 2h ago
            """
        ),
        suggestion(
            key: "slack:1",
            source: "slack",
            title: "Answer Priya in #design-review",
            subtitle: "She's waiting on the spacing token decision before she ships the header · Slack · 25m ago"
        ),
        suggestion(
            key: "cal:standup",
            source: "calendar",
            title: "Prep for Standup",
            subtitle: "Standup · 9:00 AM · Calendar"
        ),
        suggestion(
            key: "overdue:visa",
            source: "overdue",
            title: "File visa paperwork",
            subtitle: "'File visa paperwork' · overdue 3d",
            kind: "rescheduleTask"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                Text("Suggestions surface")
                    .font(DesignTokens.Typography.title3Bold)

                SharedSuggestionSection(
                    suggestions: suggestions,
                    briefMarkdown: nil,
                    isShowingAll: $isShowingAll,
                    onAccept: { _ in },
                    onDismiss: { _ in }
                )

                Divider()

                Text("Empty-chat starter (tight)")
                    .font(DesignTokens.Typography.title3Bold)

                VStack(spacing: DesignTokens.Spacing.sm) {
                    ForEach(suggestions.filter { $0.action.kind == "createTask" }) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Color.labelPrimary)
                            SuggestionMetadataLine(
                                rawSubtitle: s.subtitle,
                                badges: SuggestionSourcePresentation.badges(for: s),
                                contentLineLimit: 1
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Spacing.sm)
                        .background(
                            DesignTokens.Color.backgroundSecondary,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                }
                .frame(maxWidth: 360)
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
