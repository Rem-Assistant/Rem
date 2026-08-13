import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum DesignTokens {
    public enum Color {
        #if os(iOS)
        public static let backgroundPrimary = SwiftUI.Color(.systemBackground)
        public static let backgroundSecondary = SwiftUI.Color(.secondarySystemBackground)
        public static let backgroundTertiary = SwiftUI.Color(.tertiarySystemBackground)
        #else
        public static let backgroundPrimary = SwiftUI.Color(nsColor: .windowBackgroundColor)
        public static let backgroundSecondary = SwiftUI.Color(nsColor: .controlBackgroundColor)
        public static let backgroundTertiary = SwiftUI.Color(nsColor: .textBackgroundColor)
        #endif

        #if os(iOS)
        public static let labelPrimary = SwiftUI.Color(.label)
        public static let labelSecondary = SwiftUI.Color(.secondaryLabel)
        public static let labelTertiary = SwiftUI.Color(.tertiaryLabel)
        public static let separator = SwiftUI.Color(.separator)
        public static let fillTertiary = SwiftUI.Color(.tertiarySystemFill)
        public static let buttonBackground = SwiftUI.Color(.label)
        #else
        public static let labelPrimary = SwiftUI.Color(nsColor: .labelColor)
        public static let labelSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        public static let labelTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        public static let separator = SwiftUI.Color(nsColor: .separatorColor)
        public static let fillTertiary = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        public static let buttonBackground = SwiftUI.Color(nsColor: .labelColor)
        #endif

        public static let systemBlue = SwiftUI.Color.blue
        public static let systemGreen = SwiftUI.Color.green
        public static let systemRed = SwiftUI.Color.red
        public static let systemYellow = SwiftUI.Color.yellow
        public static let systemOrange = SwiftUI.Color.orange
        public static let systemIndigo = SwiftUI.Color.indigo
        public static let systemPurple = SwiftUI.Color.purple

        public static let brandBlue = SwiftUI.Color(red: 12/255, green: 80/255, blue: 255/255)

        /// Brand blue for **tinted text sitting on a subtle gray fill** (e.g. `RemRowConnectCTA` on
        /// `fillTertiary`). `brandBlue` (#0C50FF) is a fixed, non-adaptive color; in dark mode it
        /// composites to ~2.2:1 on the dark `fillTertiary` pill (~#323234) — below WCAG AA (4.5:1)
        /// and the 3:1 UI floor. This variant keeps #0C50FF in light mode (unchanged look) and
        /// brightens to #6E9BFF in dark mode (~4.7:1 on that pill) so Connect/Install CTAs clear AA
        /// in both appearances. Same blue hue family, just raised luminance for the dark surface.
        #if os(iOS)
        public static let brandBlueOnFill = SwiftUI.Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 110/255, green: 155/255, blue: 255/255, alpha: 1)
                : UIColor(red: 12/255, green: 80/255, blue: 255/255, alpha: 1)
        })
        #else
        public static let brandBlueOnFill = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(red: 110/255, green: 155/255, blue: 255/255, alpha: 1)
                : NSColor(red: 12/255, green: 80/255, blue: 255/255, alpha: 1)
        })
        #endif

        /// Cross-platform secondary background for pills and badges.
        #if os(iOS)
        public static let pillBackground = SwiftUI.Color(.secondarySystemBackground)
        #else
        public static let pillBackground = SwiftUI.Color(nsColor: .quaternaryLabelColor).opacity(0.3)
        #endif
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 48
        public static let xxxl: CGFloat = 120
    }

    public enum Typography {
        public static let largeTitle = Font.system(size: 34, weight: .regular)
        public static let title1 = Font.system(size: 28, weight: .regular)
        public static let title3 = Font.system(size: 20, weight: .regular)
        public static let title3Tracking: CGFloat = -0.45
        public static let body = Font.system(size: 17, weight: .regular)
        public static let subheadline = Font.system(size: 15, weight: .regular)
        public static let footnote = Font.system(size: 13, weight: .regular)
        public static let caption1 = Font.system(size: 12, weight: .regular)

        public static let bodyBold = Font.system(size: 17, weight: .bold)
        public static let title1Bold = Font.system(size: 28, weight: .bold)
        public static let title3Bold = Font.system(size: 20, weight: .bold)
        public static let caption1Bold = Font.system(size: 12, weight: .bold)

        /// Chat text roles. Keep composer, user bubbles, assistant prose, and
        /// expanded diagnostics on the same readable scale across iOS and Mac.
        public static let chatMessage = body
        public static let chatCode = Font.system(size: 17, weight: .regular, design: .monospaced)
        public static let chatMeta = footnote
        public static let chatChrome = caption1
    }

    public enum Opacity {
        /// A row that is still real, readable and tappable, but is **not asking for attention right
        /// now** — a `blocked` task, or a stale one (migration 116). One value, deliberately, so
        /// "receded" reads identically for both: the founder's decision was *same visual
        /// de-emphasis, different label*.
        ///
        /// 0.55 is not a new number — it is the dimming `TaskEventView` already uses for a
        /// read-only control ("so it reads as a disabled control", `TaskEventView.swift`). Reusing
        /// it keeps one meaning for one opacity across the app.
        ///
        /// Apply it ONCE per row. Two stacked applications multiply to 0.30, which reads as broken
        /// rather than quiet — see `TaskDisplayable.isDeemphasized`.
        public static let deemphasized: Double = 0.55
    }

    public enum CornerRadius {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 24
        public static let xlarge: CGFloat = 16
    }

    /// Frame hints aligned with the local **Native** reference app
    /// (`/Volumes/.../DesignSystem/Native`): `SettingsOneView` / `SettingsThreeView` /
    /// `SettingsFiveView` use sidebar **200–240** and detail **360–448**; tab-only
    /// variants (`SettingsTwoView`, `SettingsFourView`) use **360×480** or **600** min width.
    /// Rem does not have to use `NavigationSplitView` for settings; use these when tuning
    /// macOS **Form** / list columns, sheets, or auxiliary windows so density matches the reference.
    #if os(macOS)
    public enum Layout {
        public static let settingsSidebarMinWidth: CGFloat = 200
        public static let settingsSidebarIdealWidth: CGFloat = 240
        public static let settingsDetailMinWidth: CGFloat = 360
        public static let settingsDetailIdealWidth: CGFloat = 448
        public static let settingsTabbedMinWidth: CGFloat = 360
        public static let settingsTabbedIdealWidth: CGFloat = 480
        public static let settingsTabbedWideMinWidth: CGFloat = 600
    }
    #endif
}

public extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Shimmer Effect

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        .clear,
                        .white.opacity(0.3),
                        .clear,
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 200
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}
