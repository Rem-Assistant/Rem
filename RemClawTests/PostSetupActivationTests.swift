import Foundation
import Testing

struct PostSetupActivationTests {
    @Test func postSetupActivationIsScopedToNewGatewaySetup() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let contentView = try read("RemClaw/ContentView.swift", from: projectRoot)
        #expect(!contentView.contains("} else if !hasSeenPostSetupActivation {"))
        #expect(!contentView.contains("AIDataSharingConsentView {"))
        #expect(!contentView.contains("PostSetupActivationView {"))
        #expect(contentView.contains("FirstUseHintCard("))
        #expect(contentView.contains(".popover(isPresented: Binding("))
        #expect(contentView.contains("FirstUseHintPopoverFixtureView"))
        #expect(contentView.contains("hasSeenPostSetupActivation"))
        #expect(contentView.contains("hasDismissedFirstUseHint"))

        let onboardingFlow = try read("RemClaw/Sources/Onboarding/OnboardingFlow.swift", from: projectRoot)
        #expect(onboardingFlow.contains("SignInButton("))
        #expect(!onboardingFlow.contains("OnboardingValueSummary"))
        #expect(!onboardingFlow.contains("Capture intent"))
        #expect(!onboardingFlow.contains("Use your cloud gateway"))
        #expect(!onboardingFlow.contains("Stay in control"))
        #expect(onboardingFlow.contains("case .dataSharingConsent"))
        #expect(onboardingFlow.contains("AIDataSharingConsentView"))
        #expect(onboardingFlow.contains("case .postSetupActivation"))
        #expect(onboardingFlow.contains("PostSetupActivationView"))
        #expect(onboardingFlow.contains("rem.hasSeenPostSetupActivation.v1"))
        #expect(onboardingFlow.range(of: "AIDataSharingConsentView")!.lowerBound < onboardingFlow.range(of: "PostSetupActivationView")!.lowerBound)
        #expect(onboardingFlow.contains("gateway.isCompletingDeploy = false"))
    }

    @Test func activationCopyStaysCloudSafeAndActionable() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let activationView = try read("RemClaw/Sources/Onboarding/PostSetupActivationView.swift", from: projectRoot)
        #expect(activationView.contains("PostSetupPagedEducation"))
        #expect(activationView.contains("Start in chat"))
        #expect(activationView.contains("Capture from the Lock Screen"))
        #expect(activationView.contains("Check your gateway"))
        #expect(!activationView.contains("Start with what you mean to do"))
        #expect(!activationView.contains("A quick tour of the few places that matter first"))
        #expect(!activationView.contains("OnboardingLogoView()"))
        #expect(activationView.contains(".tabViewStyle(.page(indexDisplayMode: .never))"))
        #expect(activationView.contains("page.id == selectedPage ? DesignTokens.Color.brandBlue"))
        #expect(activationView.contains("PhoneFrameEducationMedia("))
        #expect(activationView.contains("Image(\"iPhone14ProWithoutNotch\")"))
        #expect(!activationView.contains(".background(DesignTokens.Color.brandBlue"))
        #expect(activationView.contains(".remPrimaryActionButton()"))
        #expect(!activationView.contains("UIPasteboard.general.string = prompt.text"))
        #expect(!activationView.localizedCaseInsensitiveContains("gmail"))
        #expect(!activationView.localizedCaseInsensitiveContains("xcode"))
        #expect(!activationView.localizedCaseInsensitiveContains("open files"))
        #expect(!activationView.localizedCaseInsensitiveContains("message someone"))
    }

    @Test func promptExamplesLiveInFirstEmptyChat() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sharedChat = try read("Shared/Views/Chat/SharedRemChatView.swift", from: projectRoot)
        #expect(sharedChat.contains("var starterPrompts: [FirstChatPrompt]"))
        #expect(sharedChat.contains("FirstChatPrompt"))
        #expect(sharedChat.contains("FirstChatEmptyState"))
        #expect(sharedChat.contains("FirstChatPrompt-\\(prompt.id)"))
        #expect(sharedChat.contains("emptyStateSubtitle"))
        #expect(sharedChat.contains("Say what you want Rem to help organize."))
        #expect(sharedChat.contains("Help me plan the rest of my day."))
        #expect(sharedChat.contains("Turn this into tasks: follow up with Alex, schedule my dentist appointment, and prep for Friday."))
        #expect(sharedChat.contains("Remind me to send the investor update tomorrow morning."))
        #expect(sharedChat.contains("viewModel.input = prompt.text"))
        // Was `starterPrompts.isEmpty`. The starter block is still gated on having starters to
        // show, but the gate now runs on the post-suppression list so a starter already rendered
        // as a suggestion row is dropped without hiding the rest. Behaviour is executable in
        // `SharedRemChatStarterSuppressionTests`; this stays a source-drift guard.
        #expect(sharedChat.contains("visibleStarters.isEmpty"))
    }

    @Test func activationFixtureAndDocsAreWired() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let app = try read("RemClaw/RemClawApp.swift", from: projectRoot)
        #expect(app.contains("--rem-post-setup-nux-fixture"))
        #expect(app.contains("--rem-first-use-hint-fixture"))
        #expect(app.contains("PostSetupActivationFixtureView()"))
        #expect(app.contains("FirstUseHintPopoverFixtureView()"))
        #expect(app.contains("isPostSetupNuxFixture"))

        let buttonStyle = try read("Shared/Views/RemSettingsCTAButtonStyle.swift", from: projectRoot)
        #expect(buttonStyle.contains("struct RemPrimaryActionButtonStyle"))
        #expect(buttonStyle.contains("func remPrimaryActionButton()"))

        let consentView = try read("RemClaw/Sources/Onboarding/AIDataSharingConsentView.swift", from: projectRoot)
        #expect(consentView.contains(".remPrimaryActionButton()"))

        let contentView = try read("RemClaw/ContentView.swift", from: projectRoot)
        #expect(contentView.contains("FirstUseHintFixtureButton"))

        let readme = try read("RemClaw/Sources/Onboarding/README.md", from: projectRoot)
        #expect(readme.contains("new-gateway AI"))
        #expect(readme.contains("post-setup activation"))
        #expect(readme.contains("PostSetupActivationView.swift"))
        #expect(readme.contains("rem.hasSeenPostSetupActivation.v1"))
        #expect(readme.contains("--rem-post-setup-nux-fixture"))
        #expect(readme.contains("--rem-first-use-hint-fixture"))
    }
}

private func read(_ path: String, from root: URL) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
