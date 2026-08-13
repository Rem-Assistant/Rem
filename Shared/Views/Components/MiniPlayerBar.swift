import SwiftUI

/// Unified mini player bar used for focus sessions and voice chat.
/// Flat bar with system background, centered status text, contained action
/// buttons, and optional timer/progress affordances.
///
/// When `closingDeadline` is set (an idle voice session auto-closing), the bar
/// TRANSFORMS in place — it does not stack a separate widget: a brand-accent line
/// drains at the top edge, the status becomes a left-aligned "Closing…" title +
/// reason, and the trailing control becomes a "Keep open" CTA (composer-Speak
/// style) that cancels the close.
struct MiniPlayerBar: View {
    let modeText: String
    let titleText: String
    let subtitleText: String
    /// When set, shows a live counting timer instead of `subtitleText`.
    var timerStartDate: Date? = nil
    let progress: Double?
    let progressColor: Color
    let primaryButton: ActionButton
    let stopButton: ActionButton
    /// Recoverable authored-reading failure. Kept separate from Stop/End so retry does not hide
    /// the user's way out of the voice session.
    var retryReadingAction: (() -> Void)? = nil
    /// Connecting state: the session is starting but not yet live (e.g. voice enabled while the
    /// gateway is still waking). Collapses the bar to just animated thinking-dots — the mic/stop
    /// buttons, the mode label, and the timer are hidden, then animate back in once connected.
    var isConnecting: Bool = false
    let onTap: () -> Void
    /// When set, the session is idle and auto-closing at this instant: the bar shows its "closing"
    /// state (draining top line + left title/reason + "Keep open" CTA). Nil = not closing.
    var closingDeadline: Date? = nil
    /// The full countdown window the top line represents (so it drains `remaining / duration`).
    var closingDuration: TimeInterval = 30
    /// Tapped "Keep open" — cancel the auto-close and keep the session alive.
    var onKeepOpen: (() -> Void)? = nil
    /// Copy for the closing state (defaults suit a voice session).
    var closingTitle: String = "Closing voice chat"
    var closingSubtitle: String = "Paused — no recent activity"

    struct ActionButton {
        let icon: String
        let color: Color
        var accessibilityLabel: String? = nil
        let action: () -> Void
    }

    private var isClosing: Bool { closingDeadline != nil }

    var body: some View {
        VStack(spacing: 0) {
            // The auto-close countdown draws as a draining accent line at the very TOP edge.
            // It slides down from the top edge as the bar enters its closing state.
            if let closingDeadline {
                closingProgressLine(deadline: closingDeadline)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // The bar's row transforms into the "closing" layout while counting down. The two rows
            // occupy the same slot and CROSS-FADE (ZStack) so the transform reads as one bar
            // changing state, not a hard swap.
            ZStack {
                if closingDeadline != nil {
                    closingRow.transition(.opacity)
                } else {
                    standardRow.transition(.opacity)
                }
            }

            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(progressColor.opacity(0.2))

                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(progressColor)
                            .frame(width: geometry.size.width * min(max(progress, 0), 1))
                            .animation(.linear(duration: 1), value: progress)
                    }
                }
                .frame(height: 5)
                .padding(.horizontal, 16)
            }
        }
        .background(.bar)
        // Drive the enter/exit of the closing state (top line in, rows cross-fade) as one motion.
        .animation(.easeInOut(duration: 0.3), value: isClosing)
    }

    // MARK: - Standard row (mic · status · hang up)

    private var standardRow: some View {
        HStack {
            // Mic (left) — hidden while connecting; scales back in once live.
            if !isConnecting {
                Button(action: primaryButton.action) {
                    Image(systemName: primaryButton.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(primaryButton.color)
                        .frame(width: 32, height: 32)
                        .background(primaryButton.color.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(primaryButton.accessibilityLabel ?? "Primary action")
                .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            if isConnecting {
                // Just thinking-dots — no mode label, no title, no timer — until the session is live.
                SharedChatTypingDots()
                    .frame(height: 32)
                    .transition(.opacity)
                    .accessibilityLabel("Connecting voice")
            } else {
                Button(action: onTap) {
                    VStack(spacing: 1) {
                        Text(modeText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .lineLimit(1)

                        Text(titleText)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)

                        if let timerStartDate {
                            Text(timerStartDate, style: .timer)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(subtitleText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            Spacer()

            if !isConnecting, let retryReadingAction {
                Button(action: retryReadingAction) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(DesignTokens.Color.brandBlue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry reading latest brief")
                .transition(.scale.combined(with: .opacity))
            }

            // Hang up (right) — hidden while connecting; scales back in once live.
            if !isConnecting {
                Button(action: stopButton.action) {
                    Image(systemName: stopButton.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(stopButton.color)
                        .frame(width: 32, height: 32)
                        .background(stopButton.color.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(stopButton.accessibilityLabel ?? "Stop")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isConnecting)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Closing row (left title/reason · Keep-open CTA)

    private var closingRow: some View {
        HStack(spacing: 12) {
            // Leftmost: the same eyebrow + a "closing" title and the reason underneath.
            VStack(alignment: .leading, spacing: 1) {
                Text(modeText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)

                Text(closingTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(closingSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Rightmost: the dismiss CTA, styled like the composer's "Speak" button
            // (brand-blue filled capsule), replacing the hang-up control while closing.
            Button(action: { onKeepOpen?() }) {
                Text("Keep open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(DesignTokens.Color.brandBlue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep voice open")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Closing progress line (top edge, brand accent, draining)

    @ViewBuilder
    private func closingProgressLine(deadline: Date) -> some View {
        TimelineView(.animation) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let fraction = closingDuration > 0 ? min(max(remaining / closingDuration, 0), 1) : 0
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(DesignTokens.Color.brandBlue.opacity(0.18))
                    Rectangle()
                        .fill(DesignTokens.Color.brandBlue)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
    }
}
