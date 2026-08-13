import Foundation
import Testing
@testable import RemClaw

/// Guards the user-facing privacy disclosure against re-introducing a model
/// provider the product does not actually run. Managed (default) users run
/// MiniMax `MiniMaxAI/MiniMax-M2.7`, served via GMI — see the backend config of
/// record `backend/src/config/gateway-defaults.ts` (`DEFAULT_PRIMARY_MODEL =
/// gmi/MiniMaxAI/MiniMax-M2.7`, applied as `model.primary` in the deploy config
/// patch). Anthropic Claude was named in shipped copy but has not been the
/// managed brain since 2026-06-29 (issue #28).
struct ModelProviderDisclosureTests {
    /// Every LegalSection body concatenated — the exact prose a user reads in
    /// Settings → Privacy Policy. Evaluates the real `LegalContent`, not source text.
    private var privacyProse: String {
        LegalContent.privacyPolicySections
            .map { "\($0.title)\n\($0.body)" }
            .joined(separator: "\n\n")
    }

    @Test func privacyDisclosureDoesNotNameAnthropicAsTheModelProvider() {
        // Anthropic is not the model that generates responses for managed users.
        #expect(!privacyProse.contains("Anthropic"))
        #expect(!privacyProse.contains("Claude"))
    }

    @Test func privacyDisclosureNamesTheProviderActuallyInUse() {
        // The disclosure must name the real managed brain: MiniMax, served via GMI.
        #expect(privacyProse.contains("MiniMax"))
        #expect(privacyProse.contains("GMI"))
    }
}
