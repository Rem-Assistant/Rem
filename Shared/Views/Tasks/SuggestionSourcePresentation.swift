import Foundation

/// Pure presentation for a suggestion's SOURCE attribution — the trailing
/// "From {Gmail icon} {Slack icon}" the founder asked for on the second metadata line of every
/// suggestion surface (#1369).
///
/// No SwiftUI here on purpose: the source → icon map and the second-line cleaning are plain
/// functions a test can call, so the visual rules ("gmail shows an envelope", "a connector-less
/// calendar row shows no badge", "the raw summary is cleaned before it renders") are verifiable
/// without a simulator.
///
/// The icon/label map is NOT reinvented — it reuses `ComposioToolkitPresentation`, the one place
/// the app already decides how a connector renders (`SharedComposioConnectionsView.swift`), so a
/// Gmail badge here can never disagree with the Gmail row in Connectors settings (CLAUDE.md
/// Decision Principle 1: mirror an existing pattern before inventing one).
enum SuggestionSourcePresentation {
    /// One rendered source chip: the SF Symbol and human label for a single ingested source.
    struct Badge: Equatable, Identifiable {
        let source: String
        let iconName: String
        let displayName: String
        var id: String { source }
    }

    /// The trailing "From" prefix shown before the icons. Held here so the string is asserted in a
    /// test rather than buried in a view body.
    static let attributionPrefix = "From"

    /// Source badges for a suggestion, ordered and de-duplicated.
    ///
    /// **The multi-source seam.** A `TaskSuggestion` carries a single `source` today. When the
    /// aggregation lane (#1369, a SEPARATE thread) folds several signals under one parent, the
    /// contributing sources arrive as a list — point this one call at that field and every surface
    /// renders every contributing icon with no further view work, because everything downstream
    /// already handles N badges.
    static func badges(for suggestion: TaskSuggestion) -> [Badge] {
        badges(forSources: [suggestion.source])
    }

    /// Ordered, de-duplicated badges for a list of raw source identifiers (`"gmail"`, `"slack"`).
    /// Unknown or local sources drop out (see `badge(forSource:)`); the first occurrence of each
    /// distinct source wins its position.
    static func badges(forSources sources: [String]) -> [Badge] {
        var seen = Set<String>()
        var out: [Badge] = []
        for raw in sources {
            guard let badge = badge(forSource: raw), seen.insert(badge.source).inserted else {
                continue
            }
            out.append(badge)
        }
        return out
    }

    /// Clean the raw second-line text with the SAME functions chat and the session-list previews
    /// use (`MessageCleaner.cleanSessionListDisplayText`), so a connector summary that arrived
    /// wrapped in an "untrusted metadata" envelope — or as a GFM table, or carrying a
    /// `[Rem daily update · …]` label — reads as plain one-line prose here too (#1369, mechanical
    /// item). Returns `nil` when nothing legible survives, in which case the caller shows only the
    /// source badges.
    static func cleanedSecondaryLine(_ raw: String?) -> String? {
        MessageCleaner.cleanSessionListDisplayText(raw)
    }

    // MARK: Source → badge

    /// A tier-1 LOCAL source (`calendar`, `overdue`) is not something the suggestion was *ingested
    /// from* — its own subtitle already attributes it ("… · Calendar"), and a "From 🗓" badge would
    /// just be noise. Only CONNECTED sources (Gmail, Slack, Discord, …) get a badge, matching the
    /// founder's exact framing: "an icon of the source(s) the suggestion was ingested from."
    private static func badge(forSource raw: String) -> Badge? {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !source.isEmpty else { return nil }
        switch source {
        case "calendar", "overdue":
            return nil
        default:
            return Badge(
                source: source,
                iconName: ComposioToolkitPresentation.iconName(for: source),
                displayName: ComposioToolkitPresentation.displayName(for: source)
            )
        }
    }
}
