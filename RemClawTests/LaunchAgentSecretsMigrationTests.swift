import Foundation
import Testing
@testable import RemClaw

/// Tests for the pure parsing/decision half of the LaunchAgent secrets
/// migration introduced for #383 / #384. The Mac-side glue
/// (`LaunchAgentSecretsMigrator`) does Keychain + filesystem writes that
/// can't run from the iOS test bundle; everything *testable* lives in
/// `Shared/Gateway/LaunchAgentSecretsMigration.swift` so we can drive it
/// from in-memory `Data` here.
///
/// What we verify:
/// 1. A leaky plist (the exact shape from the bug report) yields the
///    expected secrets.
/// 2. A clean plist (no `EnvironmentVariables`) yields nothing — i.e. we
///    don't fabricate keys for an already-migrated user.
/// 3. Empty / whitespace values are dropped instead of being persisted as
///    empty strings into Keychain.
/// 4. Malformed inputs degrade safely instead of crashing.
/// 5. The redacted summary helper never echoes the values themselves.
struct LaunchAgentSecretsMigrationTests {

    // MARK: - Fixtures

    /// Mirrors the plist shape from the user's leaked file (#383).
    private static func leakyPlistData(
        openAI: String? = "sk-proj-fake-openai-test-key",
        anthropic: String? = nil,
        gatewayToken: String? = "2dd8b209fakeGatewayToken"
    ) -> Data {
        var env: [String: String] = [:]
        if let openAI { env["OPENAI_API_KEY"] = openAI }
        if let anthropic { env["ANTHROPIC_API_KEY"] = anthropic }
        if let gatewayToken { env["OPENCLAW_AUTH_TOKEN"] = gatewayToken }

        let plist: [String: Any] = [
            "Label": "app.remclaw.mac.gateway",
            "ProgramArguments": [
                "/Users/test/.openclaw/bin/openclaw",
                "gateway", "run", "--bind", "loopback", "--port", "18789",
            ],
            "EnvironmentVariables": env,
            "RunAtLoad": true,
            "KeepAlive": true,
        ]

        return try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
    }

    // MARK: - Tests

    @Test func extractsAllThreeSecretsFromLeakyPlist() {
        let data = Self.leakyPlistData()
        let extracted = LaunchAgentSecretsMigration.extractSecrets(fromPlistData: data)

        #expect(extracted.openAIKey == "sk-proj-fake-openai-test-key")
        #expect(extracted.openClawAuthToken == "2dd8b209fakeGatewayToken")
        #expect(extracted.anthropicKey == nil)
        #expect(extracted.hasAnySecret)
    }

    @Test func extractsAnthropicKeyWhenPresent() {
        let data = Self.leakyPlistData(
            openAI: nil,
            anthropic: "sk-ant-fake-anthropic-test-key",
            gatewayToken: nil
        )
        let extracted = LaunchAgentSecretsMigration.extractSecrets(fromPlistData: data)

        #expect(extracted.anthropicKey == "sk-ant-fake-anthropic-test-key")
        #expect(extracted.openAIKey == nil)
        #expect(extracted.openClawAuthToken == nil)
        #expect(extracted.hasAnySecret)
    }

    @Test func returnsEmptyForPlistWithoutEnvironmentVariables() {
        // A clean plist (or a post-migration one we rewrote without the
        // env block) should yield nothing — the migrator must NOT
        // hallucinate secrets for already-migrated users.
        let plist: [String: Any] = [
            "Label": "app.remclaw.mac.gateway",
            "ProgramArguments": ["/usr/local/bin/openclaw", "gateway", "run"],
            "RunAtLoad": true,
        ]
        let data = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )

        let extracted = LaunchAgentSecretsMigration.extractSecrets(fromPlistData: data)
        #expect(!extracted.hasAnySecret)
        #expect(extracted == LaunchAgentSecretsMigration.ExtractedSecrets())
    }

    @Test func dropsEmptyAndWhitespaceValues() {
        // Older plists sometimes carry empty strings where the user
        // blanked a field. Persisting "" to Keychain would be worse than
        // a missing entry — the user would think the migration succeeded
        // while their key is actually gone.
        let data = Self.leakyPlistData(
            openAI: "",
            anthropic: "   \n",
            gatewayToken: "real-token-here"
        )
        let extracted = LaunchAgentSecretsMigration.extractSecrets(fromPlistData: data)

        #expect(extracted.openAIKey == nil)
        #expect(extracted.anthropicKey == nil)
        #expect(extracted.openClawAuthToken == "real-token-here")
        #expect(extracted.hasAnySecret)
    }

    @Test func handlesMalformedPlistDataGracefully() {
        // Garbage in -> empty struct out, no throw. The migrator's
        // expected behavior on a corrupted file is "skip the value
        // recovery and just delete the file" — a crashing parser would
        // leave the leaky file on disk forever.
        let garbage = Data([0xff, 0xfe, 0x00, 0x01, 0x02])
        let extracted = LaunchAgentSecretsMigration.extractSecrets(fromPlistData: garbage)
        #expect(!extracted.hasAnySecret)
    }

    @Test func handlesPlistWithEnvAsWrongType() {
        // `EnvironmentVariables` should be `[String: String]`, but a
        // hand-edited plist might have it as an array or nested dict.
        // We bail safely rather than try to coerce.
        let plist: [String: Any] = [
            "Label": "app.remclaw.mac.gateway",
            "EnvironmentVariables": ["unexpectedly", "an", "array"],
        ]
        let data = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        let extracted = LaunchAgentSecretsMigration.extractSecrets(fromPlistData: data)
        #expect(!extracted.hasAnySecret)
    }

    @Test func summaryNeverIncludesSecretValues() {
        // The summary is what we log to os.log / stderr. It must list
        // *which* keys were present so debugging is possible, but never
        // their values — that would re-introduce the leak we're patching.
        let secret = "sk-proj-DO-NOT-LEAK-this-token"
        let extracted = LaunchAgentSecretsMigration.ExtractedSecrets(
            openAIKey: secret,
            anthropicKey: nil,
            openClawAuthToken: "another-secret-do-not-leak"
        )

        let summary = LaunchAgentSecretsMigration.summarize(extracted)

        #expect(summary.contains("OPENAI_API_KEY"))
        #expect(summary.contains("OPENCLAW_AUTH_TOKEN"))
        #expect(!summary.contains(secret))
        #expect(!summary.contains("another-secret"))
    }

    @Test func summaryHandlesEmptyExtraction() {
        let summary = LaunchAgentSecretsMigration.summarize(
            LaunchAgentSecretsMigration.ExtractedSecrets()
        )
        #expect(summary == "no recognized secrets")
    }

    @Test func providerProfileIdMatchesUpstreamFormat() {
        // `setProviderApiKey` writes profile ids of the form
        // `<provider>:manual` — our migration must use the same shape so
        // values land in the same `auth-profiles.json` slot a fresh
        // paste-token flow would use.
        #expect(LaunchAgentSecretsMigration.providerProfileId(for: .openai) == "openai:manual")
        #expect(LaunchAgentSecretsMigration.providerProfileId(for: .anthropic) == "anthropic:manual")
    }
}
