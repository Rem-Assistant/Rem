import SwiftUI

// MARK: - Centered iOS-style settings column (macOS)

extension View {
    /// Puts the view in a **centered** column bounded by `DesignTokens.Layout` (Native
    /// frame hints). **No-op on iOS** — the phone already reads as a single column.
    /// Use with `Form` + `.grouped` for Mac settings-like density.
    @ViewBuilder
    func macSettingsCenteredColumn() -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 0)
            self
                .frame(
                    minWidth: 0,
                    idealWidth: DesignTokens.Layout.settingsDetailIdealWidth,
                    maxWidth: DesignTokens.Layout.settingsTabbedIdealWidth
                )
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
        #else
        self
        #endif
    }
}
