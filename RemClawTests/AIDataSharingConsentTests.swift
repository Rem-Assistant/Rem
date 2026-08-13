import Foundation
import Testing

struct AIDataSharingConsentTests {
    @Test func consentCopyIsConciseAndLegallyLinked() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let consentView = try read("RemClaw/Sources/Onboarding/AIDataSharingConsentView.swift", from: projectRoot)
        #expect(consentView.contains("Privacy by design"))
        #expect(consentView.contains("Rem uses your data to answer requests and run approved actions through your personal cloud gateway."))
        #expect(consentView.contains("You can review or delete your account data in Settings."))
        #expect(consentView.contains("Terms of Service"))
        #expect(consentView.contains("How Rem accounts, subscriptions, and approved actions work."))
        #expect(consentView.contains("Privacy Policy"))
        #expect(consentView.contains("What Rem, your gateway, and AI or voice providers process."))
        #expect(consentView.contains("Accept and Continue"))
        #expect(consentView.contains("AIDataSharingLegalList"))
        #expect(consentView.contains("AIDataSharingConsentButton"))
        #expect(consentView.contains("LegalContent.termsOfServiceSections"))
        #expect(consentView.contains("LegalContent.privacyPolicySections"))
        #expect(consentView.contains("bottomBar"))
        #expect(consentView.contains(".remPrimaryActionButton()"))
        #expect(consentView.contains(".font(.system(size: 30"))
        #expect(consentView.contains(".frame(width: 64, height: 64)"))
        #expect(consentView.contains(".frame(width: 38, height: 38)"))
        #expect(!consentView.contains("Your Messages"))
        #expect(!consentView.contains("Device Data"))
        #expect(!consentView.contains("Voice (Optional)"))
        #expect(!consentView.contains("Some requests are processed by Anthropic."))
        #expect(!consentView.contains("Anthropic does not train on your data and deletes it within 30 days."))
    }

    @Test func consentFixtureIsWiredForVisualQA() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let app = try read("RemClaw/RemClawApp.swift", from: projectRoot)
        #expect(app.contains("--rem-ai-data-sharing-consent-fixture"))
        #expect(app.contains("AIDataSharingConsentFixtureView()"))
        #expect(app.contains("isAIDataSharingConsentFixture"))

        let readme = try read("RemClaw/Sources/Onboarding/README.md", from: projectRoot)
        #expect(readme.contains("AIDataSharingConsentView.swift"))
    }
}

private func read(_ path: String, from root: URL) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
