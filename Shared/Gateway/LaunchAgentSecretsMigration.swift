import Foundation

/// Pure (no I/O) helpers for the LaunchAgent-secrets migration introduced
/// to fix the leak documented in #383 / #384.
///
/// **Background.** Earlier RemClaw Mac builds (pre-#275) wrote a
/// LaunchAgent at `~/Library/LaunchAgents/app.remclaw.mac.gateway.plist`
/// whose `EnvironmentVariables` dict contained the user's `OPENAI_API_KEY`
/// and `OPENCLAW_AUTH_TOKEN` in plain XML. The plist sits at default Unix
/// perms in `~/Library/LaunchAgents/`, so any process with disk read can
/// pull the key. We've since stopped writing those env vars (#275 delegates
/// install to the upstream `openclaw gateway install` CLI; the new in-app
/// flow doesn't go near that file at all), but the on-disk plist persists
/// across upgrades. This file owns the *parsing* half of the migration so
/// we can unit-test it without touching launchd or Keychain.
///
/// The Mac-side glue (`LaunchAgentSecretsMigrator` in
/// `RemClawMac/Sources/Gateway/`) reads the plist, runs it through
/// `extractSecrets` here, persists what came out into the canonical homes
/// (Keychain + `~/.openclaw/openclaw.json`), and removes the plist. Keeping
/// the parser pure means tests can pass an in-memory `Data` and assert on
/// the extracted struct.
public enum LaunchAgentSecretsMigration {

    /// Secrets pulled out of a legacy plist's `EnvironmentVariables`. Only
    /// the keys we know how to migrate; anything else gets ignored on
    /// purpose so we don't accidentally re-persist random env vars from
    /// older user configurations.
    public struct ExtractedSecrets: Equatable, Sendable {
        public var openAIKey: String?
        public var anthropicKey: String?
        public var openClawAuthToken: String?

        public init(
            openAIKey: String? = nil,
            anthropicKey: String? = nil,
            openClawAuthToken: String? = nil
        ) {
            self.openAIKey = openAIKey
            self.anthropicKey = anthropicKey
            self.openClawAuthToken = openClawAuthToken
        }

        /// True when at least one secret needs migrating. Used to decide
        /// whether the on-disk plist warrants the full migrate-then-delete
        /// path or just a quiet `removeItem`.
        public var hasAnySecret: Bool {
            openAIKey != nil || anthropicKey != nil || openClawAuthToken != nil
        }
    }

    /// Parses a plist `Data` blob (XML or binary) and pulls the env-var
    /// secrets the legacy installer used to embed. Returns an empty struct
    /// if the plist is malformed, missing the `EnvironmentVariables` dict,
    /// or carries no recognized keys.
    ///
    /// We accept missing values silently: a half-broken plist (e.g. one
    /// that has `OPENCLAW_AUTH_TOKEN` but no `OPENAI_API_KEY`) is still
    /// migratable for whichever fields are present.
    public static func extractSecrets(fromPlistData data: Data) -> ExtractedSecrets {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            return ExtractedSecrets()
        }
        return extractSecrets(fromPlist: plist)
    }

    /// Same as `extractSecrets(fromPlistData:)` but takes a pre-decoded
    /// dictionary. Convenient when callers have already parsed the plist
    /// for other reasons (e.g. logging).
    public static func extractSecrets(fromPlist plist: [String: Any]) -> ExtractedSecrets {
        guard let env = plist["EnvironmentVariables"] as? [String: String] else {
            return ExtractedSecrets()
        }

        // Only treat non-empty strings as "real" values. Empty strings
        // sometimes appear in older plists where the user blanked the
        // setting; persisting an empty string into Keychain would be
        // worse than dropping it on the floor.
        func nonEmpty(_ key: String) -> String? {
            guard let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { return nil }
            return v
        }

        return ExtractedSecrets(
            openAIKey: nonEmpty("OPENAI_API_KEY"),
            anthropicKey: nonEmpty("ANTHROPIC_API_KEY"),
            openClawAuthToken: nonEmpty("OPENCLAW_AUTH_TOKEN")
        )
    }

    /// Returns a redacted summary of the migration outcome safe for
    /// `os.log` / stdout. Never include the secret values themselves —
    /// the whole point of the migration is to stop leaking them, so we
    /// don't reintroduce a leak via the diagnostic path.
    public static func summarize(_ secrets: ExtractedSecrets) -> String {
        var present: [String] = []
        if secrets.openAIKey != nil { present.append("OPENAI_API_KEY") }
        if secrets.anthropicKey != nil { present.append("ANTHROPIC_API_KEY") }
        if secrets.openClawAuthToken != nil { present.append("OPENCLAW_AUTH_TOKEN") }
        if present.isEmpty { return "no recognized secrets" }
        return "secrets present: \(present.joined(separator: ", "))"
    }

    /// Maps an OpenAI/Anthropic provider key onto the upstream
    /// `auth-profiles.json` profile id (e.g. `openai:manual`).
    /// Mirrors the format `LocalGatewayManager.setProviderApiKey` uses
    /// when registering a paste-key profile.
    public static func providerProfileId(for provider: ProviderKey) -> String {
        "\(provider.rawValue):manual"
    }

    public enum ProviderKey: String, Sendable {
        case openai
        case anthropic
    }
}
