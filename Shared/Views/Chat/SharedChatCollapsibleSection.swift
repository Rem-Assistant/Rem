import SwiftUI

/// One collapsible disclosure shared by every chat artifact that folds long
/// content behind a header — assistant "Thought" blocks, consolidated thought
/// runs, tool-result cards, and error cards.
///
/// Extracted so "Thought" and "Tool result" render as the *same* control:
/// identical width (full content width), horizontal insets, vertical padding,
/// header row (icon + label + disclosure chevron), fonts, and collapse
/// behavior. Before this, the Thought block (`SharedChatThinkingBlock`) and the
/// #947 tool-result disclosure (`FallbackResultCard`) each hand-rolled their own
/// header with different fonts and icon/chevron sizes, so they looked like two
/// unrelated components stacked in the same transcript.
///
/// The header styling is the canonical one previously used by the Thought
/// block: `chatMeta` (13pt) icon + medium label, `labelTertiary` foreground, and
/// the Mac-tuned higher-contrast chevron (#323). Callers supply their own
/// expanded `content` because payloads differ (markdown prose vs. monospaced
/// JSON), but the chrome around it is now identical everywhere.
struct SharedChatCollapsibleSection<Content: View>: View {
    let icon: String
    let title: String
    /// When `false` the header renders without a chevron and taps are inert —
    /// used by short error results that have nothing to expand.
    var isCollapsible: Bool = true
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard isCollapsible else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(DesignTokens.Typography.chatMeta)
                    Text(title)
                        .font(DesignTokens.Typography.chatMeta.weight(.medium))
                        .lineLimit(1)
                    if isCollapsible {
                        // #323: at 10pt `.labelTertiary` the chevron was invisible
                        // on Mac against the speech-bubble background. Mac gets a
                        // larger, higher-contrast chevron so the affordance is
                        // discoverable at Mac DPI.
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        #if os(macOS)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                        #else
                            .font(DesignTokens.Typography.chatChrome.weight(.medium))
                        #endif
                    }
                }
                .foregroundStyle(DesignTokens.Color.labelTertiary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SharedChatCollapsibleSection {
    /// Convenience for callers that track expansion in a shared `Set<String>`
    /// keyed by `sectionId` (the pattern used by the transcript's thought and
    /// tool-result rows so expansion state survives re-renders).
    init(
        icon: String,
        title: String,
        sectionId: String,
        expandedSections: Binding<Set<String>>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.isCollapsible = true
        self._isExpanded = Binding(
            get: { expandedSections.wrappedValue.contains(sectionId) },
            set: { newValue in
                if newValue {
                    expandedSections.wrappedValue.insert(sectionId)
                } else {
                    expandedSections.wrappedValue.remove(sectionId)
                }
            }
        )
        self.content = content
    }
}
