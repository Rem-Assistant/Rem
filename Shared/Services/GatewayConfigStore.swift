import Foundation
import os

private let log = Logger(subsystem: "app.remclaw", category: "GatewayConfigStore")

// MARK: - Protocol

/// Abstraction for multi-gateway configuration storage.
/// Tokens are stored in the Keychain; metadata (URLs, display names,
/// provider type) is stored as JSON in UserDefaults.
@MainActor
protocol GatewayConfigStoring: AnyObject {
    /// All saved gateway configurations.
    var configs: [GatewayConfig] { get }

    /// The currently active gateway, if any.
    var activeConfig: GatewayConfig? { get }

    /// Save or update a gateway configuration.
    func save(_ config: GatewayConfig)

    /// Remove a gateway configuration by ID.
    func remove(id: String)

    /// Remove all saved gateway configurations.
    func removeAll()

    /// Set the active gateway. Deactivates all others.
    func setActive(id: String)
}

// MARK: - Implementation

/// Concrete store backed by UserDefaults (metadata) + Keychain (tokens).
///
/// **Storage layout:**
/// - `UserDefaults["rem.gateway.configs"]` — JSON array of `StoredGatewayMeta`
///   (everything except the token).
/// - Keychain service `<keychainService>`, account `gateway.token.<config.id>`
///   — per-gateway token.
///
/// The Keychain service name is platform-specific:
/// - iOS: `"app.remclaw"`
/// - macOS: `"app.remclaw.mac"`
@MainActor
final class GatewayConfigStore: GatewayConfigStoring {

    // MARK: - Storage keys

    private static let configsDefaultsKey = "rem.gateway.configs"

    /// Metadata-only struct for UserDefaults persistence (no token).
    ///
    /// The `transport` / `tailscaleURL` / `sshLocalPort` fields (added in
    /// #317) and `isBootstrap` (added in #300a) are optional so that JSON
    /// written before they were introduced — which lacks these keys —
    /// still decodes cleanly on upgrade.
    private struct StoredGatewayMeta: Codable {
        let id: String
        var url: String
        var provider: GatewayProvider
        var displayName: String
        var macAddress: String?
        var isActive: Bool
        var transport: GatewayTransport?
        var tailscaleURL: String?
        var sshLocalPort: Int?
        var isBootstrap: Bool?
    }

    // MARK: - Properties

    private let keychainService: String
    private let defaults: UserDefaults

    /// In-memory cache, kept in sync with disk.
    private(set) var configs: [GatewayConfig] = []

    var activeConfig: GatewayConfig? {
        configs.first(where: \.isActive)
    }

    // MARK: - Init

    /// - Parameters:
    ///   - keychainService: `"app.remclaw"` on iOS, `"app.remclaw.mac"` on macOS.
    ///   - defaults: UserDefaults instance (normally `.standard`).
    init(keychainService: String, defaults: UserDefaults = .standard) {
        self.keychainService = keychainService
        self.defaults = defaults
        self.configs = loadFromDisk()
    }

    #if DEBUG
    /// In-memory seed for deterministic UI fixtures. This intentionally avoids
    /// reading persisted configs or Keychain tokens during visual QA.
    init(fixtureConfigs: [GatewayConfig]) {
        self.keychainService = "app.remclaw.fixture"
        self.defaults = UserDefaults(suiteName: "app.remclaw.fixture.\(UUID().uuidString)") ?? .standard
        self.configs = fixtureConfigs
    }
    #endif

    // MARK: - GatewayConfigStoring

    func save(_ config: GatewayConfig) {
        // Save token to Keychain
        _ = KeychainStore.saveString(
            config.token,
            service: keychainService,
            account: tokenAccount(for: config.id)
        )

        // Update in-memory list
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }

        // If this config is active, deactivate others
        if config.isActive {
            for i in configs.indices where configs[i].id != config.id {
                configs[i].isActive = false
            }
        }

        persistMeta()
        log.info("saved gateway config '\(config.displayName)' (id=\(config.id), active=\(config.isActive))")
    }

    func remove(id: String) {
        configs.removeAll(where: { $0.id == id })
        _ = KeychainStore.delete(
            service: keychainService,
            account: tokenAccount(for: id)
        )
        persistMeta()
        log.info("removed gateway config id=\(id)")
    }

    func removeAll() {
        for config in configs {
            _ = KeychainStore.delete(
                service: keychainService,
                account: tokenAccount(for: config.id)
            )
        }
        configs.removeAll()
        persistMeta()
        log.info("removed all gateway configs")
    }

    func setActive(id: String) {
        for i in configs.indices {
            configs[i].isActive = (configs[i].id == id)
        }
        persistMeta()
        log.info("set active gateway id=\(id)")
    }

    // MARK: - Migration

    /// Migrates a single legacy gateway (URL + token stored separately) into
    /// a `GatewayConfig` entry. Safe to call repeatedly -- no-ops if already
    /// migrated or if there is nothing to migrate.
    ///
    /// - Parameters:
    ///   - url: The legacy gateway URL (e.g. from UserDefaults).
    ///   - token: The legacy gateway token (e.g. from Keychain).
    ///   - provider: Provider type to assign (default `.fly`).
    ///   - displayName: Human-readable name (default `"Cloud Gateway"`).
    ///   - macAddress: Optional WoL MAC address.
    func migrateFromLegacy(
        url: String?,
        token: String?,
        provider: GatewayProvider = .fly,
        displayName: String = "Cloud Gateway",
        macAddress: String? = nil
    ) {
        guard let url, !url.isEmpty,
              let token, !token.isEmpty else { return }

        // Skip if we already have a config with this URL
        if configs.contains(where: { $0.url == url }) {
            log.debug("migration skipped — config already exists for \(url)")
            return
        }

        let config = GatewayConfig(
            url: url,
            token: token,
            provider: provider,
            displayName: displayName,
            macAddress: macAddress,
            isActive: configs.isEmpty  // active if it's the only one
        )
        save(config)
        log.info("migrated legacy gateway to multi-config: \(url)")
    }

    // MARK: - Disk I/O

    private func loadFromDisk() -> [GatewayConfig] {
        guard let data = defaults.data(forKey: Self.configsDefaultsKey) else { return [] }
        do {
            let metas = try JSONDecoder().decode([StoredGatewayMeta].self, from: data)
            let loaded: [GatewayConfig] = metas.compactMap { meta in
                guard
                    let token = KeychainStore.loadString(
                        service: keychainService,
                        account: tokenAccount(for: meta.id)
                    ),
                    !token.isEmpty
                else {
                    // Drop entries with missing or empty tokens. Empty tokens
                    // came from the pre-#276 Bonjour tap-to-connect bug; leaving
                    // them around causes silent auth failure on next launch.
                    // Also purge the stale Keychain entry so it can't haunt us.
                    _ = KeychainStore.delete(
                        service: keychainService,
                        account: tokenAccount(for: meta.id)
                    )
                    log.warning("empty/missing token for config id=\(meta.id) — dropped, user must re-pair")
                    return nil
                }
                return GatewayConfig(
                    id: meta.id,
                    url: meta.url,
                    token: token,
                    provider: meta.provider,
                    displayName: meta.displayName,
                    macAddress: meta.macAddress,
                    isActive: meta.isActive,
                    transport: meta.transport,
                    tailscaleURL: meta.tailscaleURL,
                    sshLocalPort: meta.sshLocalPort,
                    isBootstrap: meta.isBootstrap
                )
            }
            return dedupeConfigs(loaded)
        } catch {
            log.error("failed to decode gateway configs: \(error.localizedDescription)")
            return []
        }
    }

    /// Deduplicates stored connections by canonical host+provider while preserving
    /// active entries first. This prevents stale duplicate Fly records from
    /// accumulating in the list for the same account.
    private func dedupeConfigs(_ configs: [GatewayConfig]) -> [GatewayConfig] {
        var seen = Set<String>()
        var result: [GatewayConfig] = []

        for config in configs.sorted(by: { $0.isActive && !$1.isActive }) {
            let key = canonicalKey(for: config)
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(config)
        }

        // Ensure exactly one active connection if we have any items.
        if result.count > 1, result.contains(where: { $0.isActive }) {
            var foundActive = false
            for i in result.indices {
                if result[i].isActive, !foundActive {
                    foundActive = true
                } else {
                    result[i].isActive = false
                }
            }
        }

        return result
    }

    private func canonicalKey(for config: GatewayConfig) -> String {
        let normalizedURL = config.url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(config.provider.rawValue)|\(normalizedURL)"
    }

    private func persistMeta() {
        let metas = configs.map { config in
            StoredGatewayMeta(
                id: config.id,
                url: config.url,
                provider: config.provider,
                displayName: config.displayName,
                macAddress: config.macAddress,
                isActive: config.isActive,
                transport: config.transport,
                tailscaleURL: config.tailscaleURL,
                sshLocalPort: config.sshLocalPort,
                isBootstrap: config.isBootstrap
            )
        }
        do {
            let data = try JSONEncoder().encode(metas)
            defaults.set(data, forKey: Self.configsDefaultsKey)
        } catch {
            log.error("failed to persist gateway configs: \(error.localizedDescription)")
        }
    }

    private func tokenAccount(for configId: String) -> String {
        "gateway.token.\(configId)"
    }
}
