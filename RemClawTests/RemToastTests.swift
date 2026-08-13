import SwiftUI
import Testing
@testable import RemClaw

/// Pure-logic coverage for `RemToast`: style→token mapping, default duration, and
/// the convenience constructors. The presentation/timer path is view-driven and
/// verified via the `#Preview` + manual reasoning in the PR body.
@MainActor
struct RemToastTests {
    @Test func stylesMapToDistinctIcons() {
        let icons = Set(RemToastStyle.allCases.map(\.icon))
        #expect(icons.count == RemToastStyle.allCases.count)
        #expect(RemToastStyle.info.icon == "info.circle.fill")
        #expect(RemToastStyle.success.icon == "checkmark.circle.fill")
        #expect(RemToastStyle.warning.icon == "exclamationmark.triangle.fill")
        #expect(RemToastStyle.error.icon == "xmark.octagon.fill")
    }

    @Test func stylesUseSemanticDesignTokens() {
        #expect(RemToastStyle.info.tint == DesignTokens.Color.systemBlue)
        #expect(RemToastStyle.success.tint == DesignTokens.Color.systemGreen)
        #expect(RemToastStyle.warning.tint == DesignTokens.Color.systemOrange)
        #expect(RemToastStyle.error.tint == DesignTokens.Color.systemRed)
    }

    @Test func defaultDurationIsInTransientBand() {
        #expect(RemToastItem.defaultDuration >= 2.5)
        #expect(RemToastItem.defaultDuration <= 3.5)
    }

    @Test func itemDefaultsToDefaultDuration() {
        let item = RemToastItem(style: .info, message: "Hi")
        #expect(item.duration == RemToastItem.defaultDuration)
        #expect(item.message == "Hi")
        #expect(item.style == .info)
    }

    @Test func convenienceConstructorsSetStyleAndMessage() {
        #expect(RemToastItem.info("a").style == .info)
        #expect(RemToastItem.success("b").style == .success)
        #expect(RemToastItem.warning("c").style == .warning)
        #expect(RemToastItem.error("d").style == .error)
        #expect(RemToastItem.success("Reconnected").message == "Reconnected")
    }

    @Test func distinctItemsHaveDistinctIdentity() {
        // A fresh `id` per item is what restarts the auto-dismiss timer under
        // `.task(id:)`, so two "same" toasts must not collide.
        let a = RemToastItem.success("Reconnected")
        let b = RemToastItem.success("Reconnected")
        #expect(a.id != b.id)
    }

    @Test func explicitDurationOverridesDefault() {
        let item = RemToastItem.warning("Slow", duration: 5)
        #expect(item.duration == 5)
    }
}
