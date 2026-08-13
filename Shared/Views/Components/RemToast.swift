import SwiftUI

/// A compact, **transient**, non-blocking notification — the toast counterpart to
/// `RemContextualMessage`.
///
/// The two are deliberately different tools:
/// - `RemContextualMessage` is **persistent, in-context, and actionable** — a card
///   that sits in the layout until the underlying state changes (connection
///   problems, empty/loading states, inline notices with a Retry button).
/// - `RemToast` is **transient, non-blocking, and non-actionable** — a brief
///   confirmation or notification ("Reconnected", "Copied", "Task added", a short
///   non-actionable error) that slides in, auto-dismisses after a couple seconds,
///   and never steals focus or covers the composer.
///
/// Styling mirrors `RemContextualMessage`: a leading semantic glyph + message on a
/// `.ultraThinMaterial` surface without an accent stroke, all colors/spacing/typography
/// from `DesignTokens` (no hardcoded hex). The `style` picks the icon + accent tint the same way
/// `RemContextualMessage`'s `iconColor` sets the tone — see `RemToastStyle`.
///
/// Present it app-wide with the `.remToast(item:)` view modifier, which mirrors
/// SwiftUI's `.sheet(item:)` / `.alert(item:)` binding pattern used throughout the
/// app. It renders as a top safe-area overlay (non-blocking; the composer lives at
/// the bottom on both platforms), auto-dismisses, and supports tap / swipe-up to
/// dismiss early. Motion collapses to a plain fade under Reduce Motion.
///
/// First adopter: a "Reconnected" toast when the gateway node session recovers from
/// a dropped/reconnecting state (`RemMainTabView`).

// MARK: - Style

/// Semantic toast style. Mirrors how `RemContextualMessage` maps a status to a
/// single `DesignTokens` accent color + SF Symbol — no hardcoded hex.
enum RemToastStyle: CaseIterable, Equatable {
    case info
    case success
    case warning
    case error

    /// Leading SF Symbol glyph for the style.
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    /// Semantic accent tint (from `DesignTokens`) for the glyph.
    var tint: Color {
        switch self {
        case .info: return DesignTokens.Color.systemBlue
        case .success: return DesignTokens.Color.systemGreen
        case .warning: return DesignTokens.Color.systemOrange
        case .error: return DesignTokens.Color.systemRed
        }
    }
}

// MARK: - Item

/// A single toast to present. `Identifiable` so a change of `id` restarts the
/// auto-dismiss timer (mirrors `.sheet(item:)`).
struct RemToastItem: Identifiable, Equatable {
    let id: UUID
    let style: RemToastStyle
    let message: String
    /// Seconds the toast stays on screen before auto-dismiss.
    let duration: TimeInterval

    /// Default on-screen duration. Kept in the ~2.5–3.5s band that reads as a
    /// confirmation without lingering.
    static let defaultDuration: TimeInterval = 3.0

    init(
        style: RemToastStyle,
        message: String,
        duration: TimeInterval = RemToastItem.defaultDuration,
        id: UUID = UUID()
    ) {
        self.id = id
        self.style = style
        self.message = message
        self.duration = duration
    }

    // Convenience constructors keep call sites terse and legible.
    static func info(_ message: String, duration: TimeInterval = defaultDuration) -> RemToastItem {
        RemToastItem(style: .info, message: message, duration: duration)
    }

    static func success(_ message: String, duration: TimeInterval = defaultDuration) -> RemToastItem {
        RemToastItem(style: .success, message: message, duration: duration)
    }

    static func warning(_ message: String, duration: TimeInterval = defaultDuration) -> RemToastItem {
        RemToastItem(style: .warning, message: message, duration: duration)
    }

    static func error(_ message: String, duration: TimeInterval = defaultDuration) -> RemToastItem {
        RemToastItem(style: .error, message: message, duration: duration)
    }
}

// MARK: - View

/// The compact toast pill: leading glyph + message. Non-actionable by design.
struct RemToast: View {
    let item: RemToastItem

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: item.style.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.style.tint)

            Text(item.message)
                .font(DesignTokens.Typography.subheadline.weight(.medium))
                .foregroundStyle(DesignTokens.Color.labelPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.message)
        .accessibilityIdentifier("RemToast")
    }
}

// MARK: - Presenter modifier

/// Presents a `RemToast` as a top safe-area overlay driven by an optional binding,
/// mirroring `.sheet(item:)`. Auto-dismisses after `item.duration`; tap or swipe-up
/// dismisses early. Non-blocking (`allowsHitTesting` limited to the pill), so it
/// never steals focus or covers the composer at the bottom.
private struct RemToastModifier: ViewModifier {
    @Binding var item: RemToastItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live drag offset while the user swipes the toast up to dismiss.
    @State private var dragOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let item {
                    RemToast(item: item)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.top, DesignTokens.Spacing.sm)
                        .offset(y: min(dragOffset, 0))
                        .contentShape(Capsule())
                        .onTapGesture { dismiss() }
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    // Only track upward drags — a downward pull shouldn't
                                    // push the toast further into content.
                                    dragOffset = min(value.translation.height, 0)
                                }
                                .onEnded { value in
                                    if value.translation.height < -20 {
                                        dismiss()
                                    } else {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            dragOffset = 0
                                        }
                                    }
                                }
                        )
                        .transition(dismissTransition)
                        // A fresh `id` restarts the timer; disappearance cancels it.
                        .task(id: item.id) {
                            await autoDismiss(item)
                        }
                        .id(item.id)
                }
            }
            // Animate present/dismiss off the item identity so replacing one toast
            // with another cross-fades cleanly.
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85), value: item?.id)
    }

    /// Slide-from-top + fade on full motion; plain fade under Reduce Motion.
    private var dismissTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .top).combined(with: .opacity)
    }

    private func autoDismiss(_ presented: RemToastItem) async {
        let nanos = UInt64(max(presented.duration, 0) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        guard !Task.isCancelled else { return }
        // Only clear if this exact toast is still the one showing.
        if item?.id == presented.id {
            dismiss()
        }
    }

    private func dismiss() {
        dragOffset = 0
        item = nil
    }
}

extension View {
    /// Present transient toasts driven by an optional binding. See `RemToast`.
    func remToast(item: Binding<RemToastItem?>) -> some View {
        modifier(RemToastModifier(item: item))
    }
}

// MARK: - Preview

#if DEBUG
private struct RemToastPreviewHost: View {
    @State private var toast: RemToastItem?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Text("Tap a style to fire a toast")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Color.labelSecondary)

            Button("info — Reconnected") { toast = .info("Reconnected") }
            Button("success — Task added") { toast = .success("Task added") }
            Button("warning — Working offline") { toast = .warning("Working offline") }
            Button("error — Couldn't copy link") { toast = .error("Couldn't copy link") }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Color.backgroundPrimary)
        .remToast(item: $toast)
    }
}

#Preview("RemToast — all styles") {
    RemToastPreviewHost()
}

#Preview("RemToast — static styles") {
    VStack(spacing: DesignTokens.Spacing.md) {
        RemToast(item: .info("Reconnected"))
        RemToast(item: .success("Task added"))
        RemToast(item: .warning("Working offline"))
        RemToast(item: .error("Couldn't copy link"))
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignTokens.Color.backgroundPrimary)
}
#endif
