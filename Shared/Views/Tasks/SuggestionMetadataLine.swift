import SwiftUI

/// The shared **second metadata line** for a suggestion — the WHY/attribution line under the
/// title, rendered identically on every surface that shows suggestions (the Agenda cards, the
/// overflow sheet, and the empty-chat starters) so the three can't drift apart again (#1369).
///
/// It does three things the founder asked for, in one place:
///   1. **Cleans** the raw line with the same functions chat and the summary previews use, so a
///      connector summary that arrived wrapped in metadata reads as plain prose
///      (`SuggestionSourcePresentation.cleanedSecondaryLine`).
///   2. **Truncates** the content with an ellipsis so it stays tidy…
///   3. …and shows a trailing **"From {source icon(s)}"** that never truncates away — the icon is
///      the reliable source cue even when the text is clipped.
///
/// Layout: the content claims the width and truncates; the "From {icons}" group is `fixedSize` and
/// sits trailing. That is the founder's "trailing on the second metadata line" primary; when the
/// two cannot share a line the group keeps its size and the content clips to make room, which is
/// the "may need a new line" fallback expressed as truncation rather than a wrap.
///
/// Self-contained (DesignTokens only, no UIKit/AppKit) so it compiles into BOTH the iOS and macOS
/// targets per the DRY rule in CLAUDE.md.
struct SuggestionMetadataLine: View {
    let rawSubtitle: String?
    let badges: [SuggestionSourcePresentation.Badge]
    /// How many lines the content may occupy before it truncates. The cards allow two; the
    /// empty-chat starter passes 1 to stay tight (the founder: the long starter context "is
    /// probably not needed").
    var contentLineLimit: Int = 2

    private var cleanedContent: String? {
        SuggestionSourcePresentation.cleanedSecondaryLine(rawSubtitle)
    }

    var body: some View {
        let content = cleanedContent
        if content == nil, badges.isEmpty {
            // Nothing legible and no source to attribute — render nothing, exactly as the old
            // `if let subtitle …` guard did.
            EmptyView()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                if let content, !content.isEmpty {
                    Text(content)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(contentLineLimit)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !badges.isEmpty {
                    sourceAttribution
                        // Keep the source group at its intrinsic size so the content — not the
                        // icons — is what clips when the line is tight.
                        .fixedSize()
                }
            }
        }
    }

    private var sourceAttribution: some View {
        HStack(spacing: 3) {
            Text(SuggestionSourcePresentation.attributionPrefix)
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            ForEach(badges) { badge in
                Image(systemName: badge.iconName)
                    .font(.caption2)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sourceAccessibilityLabel)
    }

    private var sourceAccessibilityLabel: String {
        let names = badges.map(\.displayName).joined(separator: ", ")
        return "\(SuggestionSourcePresentation.attributionPrefix) \(names)"
    }
}
