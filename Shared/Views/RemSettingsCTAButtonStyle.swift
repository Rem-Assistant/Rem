import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Full-width (or inline) CTA: **tinted text only** — no second fill, so the grouped list
/// doesn’t look like a box-on-box. Press feedback is **opacity** only.
struct RemSettingsCTAButtonStyle: ButtonStyle {
    enum Role: Sendable { case primary, destructive }
    enum Size: Sendable { case regular, compact }

    var role: Role
    var size: Size = .regular

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let vPad: CGFloat = size == .regular ? 6 : 4

        return configuration.label
            .font(size == .regular ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundColor(resolvedLabelColor)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .padding(.vertical, vPad)
            .padding(.horizontal, 2)
            .frame(minWidth: 0, maxWidth: size == .regular ? .infinity : nil, alignment: .center)
            .contentShape(Rectangle())
    }

    private var resolvedLabelColor: Color {
        guard isEnabled else { return .secondary }
        return role == .primary ? .accentColor : .red
    }
}

/// App-wide filled primary CTA for onboarding, consent, and other single-step
/// flows. Mirrors the sign-in button style so launch-facing screens do not
/// drift between filled button systems.
struct RemPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.Typography.bodyBold)
            .foregroundStyle(DesignTokens.Color.backgroundPrimary)
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                    .fill(isEnabled ? DesignTokens.Color.buttonBackground : DesignTokens.Color.labelTertiary.opacity(0.35))
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
    }
}

/// Row-trailing "Connect" / "Install" pill — a capsule used at the trailing edge of a browsable
/// settings row (Skills install row, Channels connect row) so the surfaces read as one system
/// instead of parallel one-offs (#958). Behavior (open chat / open detail) is owned by the caller
/// via `action`.
///
/// Style (founder inversion): **brand-blue text on the subtle grouped-list gray** rather than white
/// text on a filled brand capsule. The fill is `DesignTokens.Color.fillTertiary` — a *translucent*
/// system fill, so it reads as a visible-but-subtle gray pill layered on the row in BOTH light/dark
/// and on BOTH platforms (an opaque gray equal to the row would vanish in dark grouped lists).
///
/// Text uses `DesignTokens.Color.brandBlueOnFill` (adaptive), not raw `brandBlue`: fixed #0C50FF
/// drops to ~2.2:1 on the dark composited `fillTertiary` pill (below WCAG AA). The adaptive token
/// stays #0C50FF in light and brightens in dark to clear AA — this pill is shared app-wide
/// (Connectors/Channels/Skills/Automations), so the dark-mode contrast fix applies everywhere.
struct RemRowConnectCTA: View {
    let title: String
    let action: () -> Void
    var accessibilityLabel: String? = nil
    /// Empty string omits the hint (SwiftUI's `accessibilityHint(_:)` takes a non-optional
    /// `StringProtocol`; empty reads as "no hint" to VoiceOver).
    var accessibilityHint: String = ""

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DesignTokens.Color.brandBlueOnFill)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(DesignTokens.Color.fillTertiary)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityHint(accessibilityHint)
    }
}

extension View {
    /// Settings-style CTA: **accent / red** label only (no chip fill).
    func remSettingsCTA(
        _ role: RemSettingsCTAButtonStyle.Role,
        size: RemSettingsCTAButtonStyle.Size = .regular
    ) -> some View {
        buttonStyle(RemSettingsCTAButtonStyle(role: role, size: size))
    }

    /// macOS grouped `Form`: soften the default row well behind our text-only CTAs. On **iOS** this is
    /// a no-op so we don’t fight `List` insets (esp. the last section on gateway detail).
    func remSettingsCtaListRow() -> some View {
        #if os(macOS)
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        #else
        self
        #endif
    }

    func remPrimaryActionButton() -> some View {
        buttonStyle(RemPrimaryActionButtonStyle())
    }
}

#if DEBUG
#Preview("Rem CTA Styles") {
    RemCTAStylePreview()
        .padding()
}

#Preview("Rem CTA Styles - Dark") {
    RemCTAStylePreview()
        .padding()
        .preferredColorScheme(.dark)
}

private struct RemCTAStylePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            previewGroup("Primary full-width CTA") {
                Button("Continue") {}
                    .remPrimaryActionButton()

                Button("Disabled") {}
                    .remPrimaryActionButton()
                    .disabled(true)
            }

            previewGroup("Settings/list CTA") {
                Button("Approve This Device") {}
                    .remSettingsCTA(.primary)

                Button("Remove Gateway") {}
                    .remSettingsCTA(.destructive)

                HStack {
                    Button("Compact") {}
                        .remSettingsCTA(.primary, size: .compact)
                    Button("Delete") {}
                        .remSettingsCTA(.destructive, size: .compact)
                }
            }

            previewGroup("Inline recovery CTA") {
                Button("Retry") {}
                    .remInlineRecoveryCTA()

                Button("Reset Pairing") {}
                    .remInlineRecoveryCTA(.destructive)
            }
        }
    }

    private func previewGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
#endif
