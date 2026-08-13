import Foundation
import Testing

struct ChatDayDividerLayoutContractTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The separator is a bare label by design. Rules were the reported defect, not a missing
    /// feature: the ask was explicitly for a mini divider "without the divider lines".
    @Test func separatorClaimsLazyTranscriptWidthWithoutRules() throws {
        let separator = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Shared/Views/Chat/ChatTimeSeparator.swift"
            ),
            encoding: .utf8
        )
        let fixture = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Shared/Views/Chat/ChatDayDividerFixtureView.swift"
            ),
            encoding: .utf8
        )

        // Accepts the LazyVStack's width proposal so the label centres across the transcript.
        #expect(separator.contains(".frame(maxWidth: .infinity)"))
        #expect(separator.contains(".padding(.vertical, DesignTokens.Spacing.xs)"))
        // No rules, in any form.
        #expect(!separator.contains("Divider()"))
        #expect(!separator.contains("Rectangle()"))
        #expect(!separator.contains(".frame(height: 1)"))
        // De-emphasised: secondary label colour, caption type, never a hardcoded size or colour.
        #expect(separator.contains("DesignTokens.Color.labelSecondary"))
        #expect(separator.contains("DesignTokens.Typography.caption1"))
        #expect(!separator.contains("Font.system("))
        #expect(!separator.contains("Color("))

        #expect(fixture.contains("LazyVStack"))
        // The fixture must show the reported case: two same-day deliveries, separately labelled.
        #expect(fixture.contains("ChatTimeSeparator(label: \"Today 8:00 AM\")"))
        #expect(fixture.contains("ChatTimeSeparator(label: \"Today 2:30 PM\")"))
    }

    /// The old `OrchestratorDayDivider` is gone rather than merely unused — a ruled divider left in
    /// the tree is one autocomplete away from coming back at a new call site.
    @Test func ruledDividerIsNotReachableAnywhere() throws {
        #expect(!FileManager.default.fileExists(
            atPath: projectRoot
                .appendingPathComponent("Shared/Views/Chat/OrchestratorDayDivider.swift").path
        ))

        for relativePath in [
            "Shared/Views/Chat/SharedRemChatView.swift",
            "Shared/Views/Chat/ChatDayDividerFixtureView.swift",
        ] {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8
            )
            #expect(!source.contains("OrchestratorDayDivider"), "\(relativePath) still references it")
        }
    }

    @Test func launchArgumentSelectsFixtureAndSuppressesAppSideEffects() throws {
        let app = try String(
            contentsOf: projectRoot.appendingPathComponent("RemClaw/RemClawApp.swift"),
            encoding: .utf8
        )

        #expect(app.contains("ProcessInfo.processInfo.arguments.contains(\"--rem-chat-day-divider-fixture\")"))
        #expect(app.contains("else if isChatDayDividerFixture"))
        #expect(app.contains("ChatDayDividerFixtureView()"))
        #expect(app.contains("""
            private var isFixtureMode: Bool {
                isChatDiagnosticsFixture || isChatLifecycleFixture || isChatDayDividerFixture
        """))
    }
}
