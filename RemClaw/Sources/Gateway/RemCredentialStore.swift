import Foundation

private final class GatewayCredentialLifecycleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

/// Centralizes credential storage for RemClaw.
/// Tokens are stored in the Keychain; non-sensitive values use UserDefaults.
enum RemCredentialStore {
    private static let service = "app.remclaw"
    private static let gatewayCredentialLifecycle = GatewayCredentialLifecycleCounter()

    /// Process-local credential epoch. Every URL/token replacement attempt advances it before the
    /// write, so concurrent readers can never observe replacement values under the prior epoch and an
    /// A -> B -> A value cycle cannot revive async work captured under the first credential set.
    static var gatewayCredentialLifecycleTicket: UInt64 {
        gatewayCredentialLifecycle.current
    }

    // MARK: - Keychain accounts
    private static let gatewayTokenAccount = "gateway.token"
    private static let backendTokenAccount = "backend.token"
    private static let cachedUserAccount = "cached.user"
    private static let elevenLabsApiKeyAccount = "elevenlabs.apikey"
    /// GMI AgentBox / MaaS API key (BYOK). Account name matches the
    /// frozen contract storage table (docs/agentbox/CONTRACT.md §2:
    /// "iOS/Mac Keychain `byok.gmi.apiKey`") and the existing
    /// `byok.*.apiKey` convention on the Mac side.
    private static let gmiApiKeyAccount = "byok.gmi.apiKey"

    // MARK: - UserDefaults keys (non-sensitive)
    private static let gatewayURLKey = "rem.gateway.url"
    private static let gatewayProviderKey = "rem.gateway.provider"
    private static let backendURLKey = "rem.backend.url"

    // Legacy UserDefaults keys (migrated to Keychain)
    private static let legacyGatewayTokenKey = "rem.gateway.token"
    private static let legacyBackendTokenKey = "rem.backend.token"
    private static let legacyCachedUserKey = "rem.auth.cached_user"

    // MARK: - Gateway Token (Keychain)

    static var gatewayToken: String? {
        get { KeychainStore.loadString(service: service, account: gatewayTokenAccount) }
        set {
            let previousValue = gatewayToken
            if previousValue != newValue {
                gatewayCredentialLifecycle.advance()
            }
            if let value = newValue {
                _ = KeychainStore.saveString(value, service: service, account: gatewayTokenAccount)
            } else {
                _ = KeychainStore.delete(service: service, account: gatewayTokenAccount)
            }
        }
    }

    static func saveGatewayTokenOrThrow(_ value: String) throws {
        let previousValue = gatewayToken
        if previousValue != value {
            gatewayCredentialLifecycle.advance()
        }
        try KeychainStore.saveStringOrThrow(value, service: service, account: gatewayTokenAccount)
    }

    // MARK: - Backend Token (Keychain)

    static var backendToken: String? {
        get { KeychainStore.loadString(service: service, account: backendTokenAccount) }
        set {
            if let value = newValue {
                _ = KeychainStore.saveString(value, service: service, account: backendTokenAccount)
            } else {
                _ = KeychainStore.delete(service: service, account: backendTokenAccount)
            }
        }
    }

    static func saveBackendTokenOrThrow(_ value: String) throws {
        try KeychainStore.saveStringOrThrow(value, service: service, account: backendTokenAccount)
    }

    // MARK: - Wake-on-LAN (UserDefaults — not sensitive)

    private static let macMACAddressKey = "rem.mac.wol.macaddress"

    /// MAC address of the user's Mac for Wake-on-LAN (e.g. "AA:BB:CC:DD:EE:FF").
    static var macWoLAddress: String? {
        get { UserDefaults.standard.string(forKey: macMACAddressKey) }
        set { UserDefaults.standard.set(newValue, forKey: macMACAddressKey) }
    }

    // MARK: - Gateway URL (UserDefaults — not sensitive)

    static var gatewayURL: String? {
        get { UserDefaults.standard.string(forKey: gatewayURLKey) }
        set {
            let previousValue = gatewayURL
            if previousValue != newValue {
                gatewayCredentialLifecycle.advance()
            }
            UserDefaults.standard.set(newValue, forKey: gatewayURLKey)
        }
    }

    // MARK: - Gateway Provider Name (UserDefaults)

    static var gatewayProviderName: String {
        get { UserDefaults.standard.string(forKey: gatewayProviderKey) ?? "Fly.io" }
        set { UserDefaults.standard.set(newValue, forKey: gatewayProviderKey) }
    }

    // MARK: - ElevenLabs API Key (Keychain)

    /// Read-only legacy slot retained solely so migrations can detect/scrub old installs.
    /// Provider credentials are now backend/gateway owned and must never be written by the app.
    static var elevenLabsApiKey: String? {
        KeychainStore.loadString(service: service, account: elevenLabsApiKeyAccount)
    }

    static func clearElevenLabsApiKeyOrThrow() throws {
        try KeychainStore.deleteOrThrow(service: service, account: elevenLabsApiKeyAccount)
    }

    // MARK: - GMI API Key (Keychain) — BYOK, frozen contract §2

    /// GMI API key, BYOK. Lives ONLY in the Keychain (CLAUDE.md: secrets never
    /// touch a plist or config file the app writes). Unlike the retired Voice provider cache,
    /// this user-owned BYOK slot remains intentionally writable.
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

    static func saveGmiApiKeyOrThrow(_ value: String) throws {
        try KeychainStore.saveStringOrThrow(value, service: service, account: gmiApiKeyAccount)
    }

    // MARK: - BYOK Provider Keys (Keychain) — multi-provider

    /// Per-provider BYOK key, stored at account `byok.{provider}.apiKey` (one
    /// row per provider). Mirrors upstream `ApiKeyCredential.provider` keying
    /// (`openclaw/src/agents/auth-profiles/types.ts`). The legacy single GMI key
    /// (`byok.gmi.apiKey`) is just `provider == "gmi"`, so an existing key
    /// surfaces in the multi-provider list with no migration.
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

    // MARK: - Backend URL (UserDefaults — not sensitive)

    static var backendURL: String? {
        get { UserDefaults.standard.string(forKey: backendURLKey) }
        set { UserDefaults.standard.set(newValue, forKey: backendURLKey) }
    }

    // MARK: - Cached User Profile (Keychain — survives app reinstall)

    static func loadCachedUser<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = KeychainStore.loadData(service: service, account: cachedUserAccount) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func saveCachedUser<T: Encodable>(_ user: T) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        _ = KeychainStore.saveData(data, service: service, account: cachedUserAccount)
    }

    static func saveCachedUserOrThrow<T: Encodable>(_ user: T) throws {
        let data = try JSONEncoder().encode(user)
        try KeychainStore.saveDataOrThrow(data, service: service, account: cachedUserAccount)
    }

    static func clearCachedUser() {
        _ = KeychainStore.delete(service: service, account: cachedUserAccount)
    }

    // MARK: - Migration

    /// Migrates tokens from UserDefaults to Keychain on first launch.
    /// Safe to call repeatedly — no-ops if already migrated.
    static func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard

        // Migrate gateway token
        if let legacyToken = defaults.string(forKey: legacyGatewayTokenKey),
           !legacyToken.isEmpty,
           gatewayToken == nil {
            gatewayToken = legacyToken
            defaults.removeObject(forKey: legacyGatewayTokenKey)
        }

        // Migrate backend token
        if let legacyToken = defaults.string(forKey: legacyBackendTokenKey),
           !legacyToken.isEmpty,
           backendToken == nil {
            backendToken = legacyToken
            defaults.removeObject(forKey: legacyBackendTokenKey)
        }

        // Migrate cached user profile from UserDefaults to Keychain
        if let userData = defaults.data(forKey: legacyCachedUserKey),
           KeychainStore.loadData(service: service, account: cachedUserAccount) == nil {
            _ = KeychainStore.saveData(userData, service: service, account: cachedUserAccount)
            defaults.removeObject(forKey: legacyCachedUserKey)
        }
    }

    /// Clears all gateway-related credentials. Used when disconnecting.
    static func clearGateway() {
        gatewayToken = nil
        gatewayURL = nil
        UserDefaults.standard.removeObject(forKey: gatewayProviderKey)
    }

    /// Clears all credentials (gateway + backend + cached user).
    static func clearAll() {
        clearGateway()
        backendToken = nil
        backendURL = nil
        _ = KeychainStore.delete(service: service, account: elevenLabsApiKeyAccount)
        gmiApiKey = nil
        clearCachedUser()
    }

    // MARK: - Multi-Gateway Migration

    /// Reads existing single-gateway credentials and creates a `GatewayConfig`
    /// entry in the provided `GatewayConfigStore`. Safe to call repeatedly --
    /// the store skips migration if a matching config already exists.
    @MainActor
    static func migrateToMultiGateway(store: GatewayConfigStore) {
        store.migrateFromLegacy(
            url: gatewayURL,
            token: gatewayToken,
            provider: gatewayProviderName == "Local" ? .local : .fly,
            displayName: gatewayProviderName == "Local" ? "Local Gateway" : "Cloud Gateway"
        )
    }
}
