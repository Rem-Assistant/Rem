import Foundation

/// BYOK (bring-your-own-key) provider keys for the Mac app, stored in the
/// Mac Keychain under service `app.remclaw.mac`.
///
/// Mirrors the iOS `RemCredentialStore` accessor shape (computed property +
/// `*OrThrow`) and the existing Mac convention of calling `KeychainStore`
/// directly with `service: "app.remclaw.mac"` (see
/// `MacGatewaySessionManager.storedGatewayToken`,
/// `LaunchAgentSecretsMigrator.openAIKeychainAccount`).
///
/// Secrets live in the Keychain ONLY — never in a LaunchAgent plist or a
/// config file the Mac app writes (CLAUDE.md "Mac app must NOT write secrets
/// to disk except via Keychain", #383).
enum MacBYOKKeychain {
    /// Matches the service used by every other Mac-app-owned secret so they
    /// all live under one keychain service id.
    private static let service = "app.remclaw.mac"

    /// Account name from the frozen contract storage table
    /// (docs/agentbox/CONTRACT.md §2: "iOS/Mac Keychain `byok.gmi.apiKey`")
    /// and the existing `byok.*.apiKey` accounts documented in
    /// `RemClawMac/Sources/Gateway/README.md`.
    private static let gmiApiKeyAccount = "byok.gmi.apiKey"

    // MARK: - GMI API Key (Keychain) — BYOK, frozen contract §2

    /// GMI AgentBox / MaaS API key. Setting `nil` deletes the row.
    static var gmiApiKey: String? {
        get { KeychainStore.loadString(service: service, account: gmiApiKeyAccount) }
        set {
            if let value = newValue {
                _ = KeychainStore.saveString(value, service: service, account: gmiApiKeyAccount)
            } else {
                _ = KeychainStore.delete(service: service, account: gmiApiKeyAccount)
            }
        }
    }

    // MARK: - BYOK Provider Keys (Keychain) — multi-provider

    /// Per-provider BYOK key, stored at account `byok.{provider}.apiKey` (one
    /// row per provider). Mirrors upstream `ApiKeyCredential.provider` keying
    /// (`openclaw/src/agents/auth-profiles/types.ts`) and the existing
    /// `byok.openai.apiKey` / `byok.anthropic.apiKey` accounts already used by
    /// `LaunchAgentSecretsMigrator`. The legacy GMI key (`byok.gmi.apiKey`) is
    /// just `provider == "gmi"`, so it surfaces with no migration.
    static func byokKey(forProvider providerID: String) -> String? {
        KeychainStore.loadString(service: service, account: "byok.\(providerID).apiKey")
    }

    /// Stores (or, when `value` is `nil`, deletes) the BYOK key for a provider.
    static func setBYOKKey(_ value: String?, forProvider providerID: String) {
        let account = "byok.\(providerID).apiKey"
        if let value {
            _ = KeychainStore.saveString(value, service: service, account: account)
        } else {
            _ = KeychainStore.delete(service: service, account: account)
        }
    }
}
