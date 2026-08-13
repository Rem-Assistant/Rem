import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Daily Brief card — Rem's orchestrator surface, inserted at the top of the Agenda
/// for *today*. Repurposes the PR #6 summary components (ProgressRing / ProgressBadge,
/// CapsuleInfo chips, InlineFlow wrapping, blurFromBottom staggered reveal) from the
/// weather/calories demo into TASK language: a done/total ring plus blocked / overdue
/// / today chips. Tapping opens the Brief detail. See backend brief.service.ts.
struct DailyBriefCard: View {
    let brief: DailyBrief
    let onTap: () -> Void
    let isReading: Bool
    let hasCompletedPlayback: Bool
    let onRead: (() -> Void)?

    init(
        brief: DailyBrief,
        onTap: @escaping () -> Void,
        isReading: Bool = false,
        hasCompletedPlayback: Bool = false,
        onRead: (() -> Void)? = nil
    ) {
        self.brief = brief
        self.onTap = onTap
        self.isReading = isReading
        self.hasCompletedPlayback = hasCompletedPlayback
        self.onRead = onRead
    }

    @State private var show = false

    private var counts: BriefCounts { brief.counts }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                header

                // Prefer canonical prose even when an older artifact has no stored summary.
                // Only a truly prose-less structured brief may fall back to count capsules.
                if let summary = DailyBriefAgendaPresentation.prose(for: brief) {
                    Text(summary)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .blurFromBottom(show, delay: 0.1)
                }

                // Capsules are a counts-only fallback. Canonical markdown without a stored
                // summary renders an excerpt above instead of synthesized task prose.
                if DailyBriefAgendaPresentation.shouldShowCounts(for: brief) {
                InlineFlow(horizontalSpacing: 5, verticalSpacing: 6) {
                    if counts.blocked > 0 {
                        CapsuleInfo(
                            icon: "exclamationmark.triangle.fill",
                            text: "\(counts.blocked) blocked",
                            color: DesignTokens.Color.systemRed.muted
                        )
                        .blurFromBottom(show, delay: 0.15)
                    }

                    if counts.overdue > 0 {
                        CapsuleInfo(
                            icon: "clock.badge.exclamationmark",
                            text: "\(counts.overdue) overdue",
                            color: DesignTokens.Color.systemOrange.muted
                        )
                        .blurFromBottom(show, delay: 0.25)
                    }

                    Text(leadInText)
                        .blurFromBottom(show, delay: 0.35)

                    ProgressBadgeView(
                        value: Double(counts.done),
                        maxValue: Double(max(counts.total, 1)),
                        title: "of \(counts.total) done",
                        color: DesignTokens.Color.systemGreen.muted
                    )
                    .blurFromBottom(show, delay: 0.45)

                    if counts.scheduledToday > 0 {
                        Text("·")
                            .blurFromBottom(show, delay: 0.55)
                        CapsuleInfo(
                            icon: "calendar",
                            text: "\(counts.scheduledToday) today",
                            // Brand blue (#0C50FF) — matches the app icon. The "today"
                            // calendar glyph anchors the brief to Rem's identity color,
                            // not the desaturated system blue used elsewhere.
                            color: DesignTokens.Color.brandBlue
                        )
                        .blurFromBottom(show, delay: 0.65)
                    }
                }
                .font(.system(size: 17, weight: .regular))
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint("Opens your daily brief")

            if let onRead, brief.hasAgendaSurface {
                Button(action: onRead) {
                    Label(
                        readActionTitle,
                        systemImage: isReading ? "stop.fill" : "speaker.wave.2"
                    )
                        .font(DesignTokens.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.brandBlue)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agenda-read-brief")
                .accessibilityValue(readActionAccessibilityValue)
            }
        }
        // Uncontained: no boxed card background. The brief reads as an inline
        // summary at the top of the agenda. The two actions are siblings so the
        // explicit playback control is never nested inside the navigation button.
        .padding(.vertical, DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { show = true }
    }

    // MARK: - Header

    private var readActionTitle: String {
        if isReading { return "Stop reading" }
        return hasCompletedPlayback ? "Read again" : "Read latest brief"
    }

    private var readActionAccessibilityValue: String {
        if isReading { return "Reading" }
        return hasCompletedPlayback ? "Completed" : "Not read"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(DailyBriefAgendaPresentation.title(for: brief))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DesignTokens.Color.labelPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.labelTertiary)
        }
    }

    // MARK: - Copy

    private var leadInText: String {
        if counts.total == 0 && counts.blocked == 0 && counts.overdue == 0 {
            return "Nothing on deck —"
        }
        return "You've finished"
    }

    private var accessibilitySummary: String {
        DailyBriefAgendaAccessibility.summary(for: brief)
    }
}

enum DailyBriefAgendaAccessibility {
    static func summary(for brief: DailyBrief) -> String {
        var parts: [String] = ["Daily brief."]
        if let summary = DailyBriefAgendaPresentation.prose(for: brief) {
            parts.append(summary)
            return parts.joined(separator: " ")
        }
        let counts = brief.counts
        if counts.total > 0 {
            parts.append("\(counts.done) of \(counts.total) done today.")
        }
        if counts.scheduledToday > 0 { parts.append("\(counts.scheduledToday) scheduled today.") }
        if counts.overdue > 0 { parts.append("\(counts.overdue) overdue.") }
        if counts.blocked > 0 { parts.append("\(counts.blocked) blocked.") }
        return parts.joined(separator: " ")
    }
}


// MARK: - Muted chip tint

private extension Color {
    /// A calmer, desaturated variant of a semantic color for the brief chips.
    /// Founder feedback: the Blocked / Overdue / Today / Done glyphs read too loud
    /// at full saturation. We keep each bucket's hue (so they stay distinguishable
    /// and scannable) but drop the saturation so the summary reads calm rather than
    /// shouting for attention.
    var muted: Color {
        #if canImport(UIKit)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: Double(h), saturation: Double(s * 0.5), brightness: Double(min(b * 0.95, 1)), opacity: Double(a))
        #else
        return self
        #endif
    }
}

#if DEBUG
#Preview("Daily Brief Card") {
    let brief = DailyBrief(
        generatedAt: nil,
        counts: BriefCounts(blocked: 2, overdue: 3, scheduledToday: 5, completedToday: 2, total: 7, done: 2),
        blocked: [], overdue: [], scheduledToday: [], completedToday: [],
        markdown: "2 tasks blocked and 3 tasks overdue need your attention. You've got 5 things on deck today.",
        summary: "2 tasks blocked and 3 tasks overdue need attention · 5 on deck · 2 of 7 done.",
        briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
    )
    return DailyBriefCard(brief: brief, onTap: {})
        .padding()
        .background(DesignTokens.Color.backgroundPrimary)
}
#endif
