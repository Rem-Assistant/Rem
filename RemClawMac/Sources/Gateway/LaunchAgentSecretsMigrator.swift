import Foundation
import os

private let log = Logger(subsystem: "app.remclaw.mac", category: "launchagent-migration")

/// One-shot migration that scrubs the legacy
/// `~/Library/LaunchAgents/app.remclaw.mac.gateway.plist` written by
/// pre-#275 RemClaw Mac builds. The plist held provider API keys and the
/// gateway auth token in plaintext under `EnvironmentVariables` (#383).
///
/// Lifecycle (single source of truth: `runIfNeeded`):
/// 1. Look for the plist at the canonical path AND the same path with a
///    `.DISABLED` suffix (some users — and our debug runbook — rename the
///    file to disable the agent without deleting it). If neither exists:
///    no-op, return.
/// 2. Parse the plist via `LaunchAgentSecretsMigration.extractSecrets`
///    (pure, in `Shared/Gateway/`).
/// 3. For each secret found, persist into the canonical home:
///    - `OPENAI_API_KEY` → `~/.openclaw/agents/main/agent/auth-profiles.json`
///      via `LocalGatewayManager.writeAuthProfile` (the upstream-canonical
///      location for BYOK keys; `setProviderApiKey` already writes here).
///    - `ANTHROPIC_API_KEY` → same shape, `provider: "anthropic"`.
///    - `OPENCLAW_AUTH_TOKEN` → `~/.openclaw/openclaw.json` under
///      `gateway.auth.token` (upstream's source-of-truth for the gateway
///      token; `currentGatewayToken()` already reads here).
///    - Mac Keychain copies for redundancy under service `app.remclaw.mac`
///      so the user can recover a key even if the openclaw config gets
///      wiped (e.g. by `openclaw reset`).
/// 4. `launchctl bootout gui/$UID/app.remclaw.mac.gateway` so the running
///    daemon dies and stops hitting `KeepAlive=true` respawn.
/// 5. `removeItem` on the plist (and the `.DISABLED` variant if present).
/// 6. Set a UserDefaults sentinel so quiet launches can skip noisy
///    migration logging after the file is gone (`launchAgentSecretsMigrated`).
///
/// Idempotent: if the plist is already gone the sentinel gets set and the
/// function returns. Safe across upgrades: the migration sentinel is
/// versioned (`v1`) so future variants of this leak — should they
/// resurface in a different file — can rerun selectively.
@MainActor
enum LaunchAgentSecretsMigrator {

    private static let migrationSentinelKey = "launchAgentSecretsMigrated.v1"

    /// Keychain service for the Mac app's redundant copies. Matches the
    /// service used elsewhere in the Mac app (e.g. `RemClawMacApp`'s
    /// OAuth store) so all Mac-app-owned secrets live under one keychain
    /// service id.
    private static let keychainService = "app.remclaw.mac"

    /// Account labels for the migrated secrets. Picked so they don't
    /// collide with any existing account names (gateway tokens,
    /// auth profiles, etc).
    private static let openAIKeychainAccount = "byok.openai.apiKey"
    private static let anthropicKeychainAccount = "byok.anthropic.apiKey"
    private static let gatewayTokenKeychainAccount = "gateway.auth.token"

    struct Dependencies {
        var legacyPlistURL: @MainActor () -> URL
        var fileExists: @MainActor (URL) -> Bool
        var readData: @MainActor (URL) -> Data?
        var removeItem: @MainActor (URL) throws -> Void
        var persistProviderKey: @MainActor (LaunchAgentSecretsMigration.ProviderKey, String) -> Bool
        var persistGatewayAuthToken: @MainActor (String) -> Bool
        var bootoutLegacyAgent: @MainActor () async -> Void
    }

    private static func liveDependencies(fileManager: FileManager) -> Dependencies {
        Dependencies(
            legacyPlistURL: { LocalGatewayManager.launchAgentPlistURL },
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            readData: { try? Data(contentsOf: $0) },
            removeItem: { try fileManager.removeItem(at: $0) },
            persistProviderKey: { provider, key in persist(provider: provider, key: key) },
            persistGatewayAuthToken: { token in persistGatewayAuthToken(token) },
            bootoutLegacyAgent: { await bootoutLegacyAgent() }
        )
    }

    /// Runs the migration at app launch. The sentinel suppresses repeated
    /// filesystem work only once the plist is gone; if a legacy plist
    /// reappears later, we scrub it again defensively.
    ///
    /// `defaults` parameter is injectable so a test can drive this with
    /// a private suite. In production callers pass `.standard`.
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) async {
        await runIfNeeded(defaults: defaults, dependencies: liveDependencies(fileManager: fileManager))
    }

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        dependencies: Dependencies
    ) async {
        let alreadyRan = defaults.bool(forKey: migrationSentinelKey)
        let plistURL = dependencies.legacyPlistURL()
        let disabledURL = plistURL.appendingPathExtension("DISABLED")

        let plistExists = dependencies.fileExists(plistURL)
        let disabledExists = dependencies.fileExists(disabledURL)

        guard plistExists || disabledExists else {
            // Nothing to migrate — set the sentinel so we don't keep
            // poking the filesystem on every launch.
            if !alreadyRan {
                defaults.set(true, forKey: migrationSentinelKey)
                log.debug("no legacy LaunchAgent plist found; sentinel set")
            } else {
                log.debug("LaunchAgent secrets migration already ran and no plist is present; skipping")
            }
            return
        }

        // Prefer the live plist if both exist (it's the one launchd is
        // actually loading). The .DISABLED variant gets cleaned up at the
        // end either way.
        let sourceURL = plistExists ? plistURL : disabledURL
        guard let data = dependencies.readData(sourceURL) else {
            log.warning("could not read legacy plist at \(sourceURL.path, privacy: .public)")
            return
        }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            log.warning("could not parse legacy plist at \(sourceURL.path, privacy: .public)")
            return
        }
        let extracted = LaunchAgentSecretsMigration.extractSecrets(fromPlist: plist)

        if alreadyRan {
            log.debug("legacy LaunchAgent plist found after sentinel was set; scrubbing defensively")
        } else {
            log.info("legacy LaunchAgent plist found at \(sourceURL.path, privacy: .public); \(LaunchAgentSecretsMigration.summarize(extracted), privacy: .public)")
        }

        // Persist the secrets into their canonical homes. We do these
        // before the bootout/removeItem so a partial failure leaves the
        // plist on disk — better than losing the secret entirely.
        var persistOK = true
        if let openAI = extracted.openAIKey {
            persistOK = dependencies.persistProviderKey(.openai, openAI) && persistOK
        }
        if let anthropic = extracted.anthropicKey {
            persistOK = dependencies.persistProviderKey(.anthropic, anthropic) && persistOK
        }
        if let token = extracted.openClawAuthToken {
            persistOK = dependencies.persistGatewayAuthToken(token) && persistOK
        }

        guard persistOK else {
            log.warning("LaunchAgent secrets migration left plist on disk because at least one secret write failed")
            return
        }

        // Bootout the running agent so KeepAlive=true stops respawning
        // the daemon. Uses /bin/launchctl directly because the upstream
        // CLI's bootout path is keyed on `ai.openclaw.gateway`, not our
        // legacy `app.remclaw.mac.gateway` label.
        await dependencies.bootoutLegacyAgent()

        // Now remove the plists. Order matters: bootout first, then
        // remove — otherwise launchd may rewrite the file as we delete it.
        for url in [plistURL, disabledURL] where dependencies.fileExists(url) {
            do {
                try dependencies.removeItem(url)
                log.info("removed legacy plist at \(url.path, privacy: .public)")
            } catch {
                log.warning("failed to remove \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        defaults.set(true, forKey: migrationSentinelKey)
        log.info("LaunchAgent secrets migration complete")
    }

    // MARK: - Persistence helpers

    private static func persist(
        provider: LaunchAgentSecretsMigration.ProviderKey,
        key: String
    ) -> Bool {
        var authProfileOK = false

        // 1) Upstream-canonical location: auth-profiles.json. Reusing
        //    `LocalGatewayManager.writeAuthProfile` keeps schema in
        //    lock-step with `setProviderApiKey`.
        do {
            let profileId = LaunchAgentSecretsMigration.providerProfileId(for: provider)
            try LocalGatewayManager.writeAuthProfile(
                provider: provider.rawValue,
                profileId: profileId,
                token: key
            )
            log.info("migrated \(provider.rawValue) key into auth-profiles.json")
            authProfileOK = true
        } catch {
            log.warning("auth-profiles.json write failed for \(provider.rawValue): \(error.localizedDescription, privacy: .public)")
        }

        // 2) Mac-side Keychain copy so the secret survives an
        //    `openclaw reset` or a corrupted config. Recovery story:
        //    if the user's gateway config gets wiped, we can repopulate
        //    the auth profile from Keychain on next launch (out of
        //    scope for this PR but the storage shape is here).
        let account: String
        switch provider {
        case .openai:    account = openAIKeychainAccount
        case .anthropic: account = anthropicKeychainAccount
        }
        let keychainOK = KeychainStore.saveString(key, service: keychainService, account: account)
        if keychainOK {
            log.info("migrated \(provider.rawValue) key into Keychain (\(keychainService, privacy: .public)/\(account, privacy: .public))")
        } else {
            log.warning("Keychain write failed for \(provider.rawValue) (\(account, privacy: .public))")
        }

        return authProfileOK && keychainOK
    }

    /// Writes the gateway auth token into `~/.openclaw/openclaw.json`
    /// under `gateway.auth.token` (upstream's location). Read-modify-
    /// write so we don't clobber other config keys (notably
    /// `gateway.mode = "local"` from `ensureLocalGatewayConfig`).
    private static func persistGatewayAuthToken(_ token: String) -> Bool {
        let configURL = LocalGatewayManager.configFileURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var gateway = (root["gateway"] as? [String: Any]) ?? [:]
        var auth = (gateway["auth"] as? [String: Any]) ?? [:]
        var configOK = false
        // Don't overwrite a non-empty token — the user may have rotated
        // since the leaky build. Plist token is the older value.
        if (auth["token"] as? String).map({ !$0.isEmpty }) == true {
            log.info("openclaw.json already has a gateway.auth.token; not overwriting from legacy plist")
            configOK = true
        } else {
            auth["token"] = token
            gateway["auth"] = auth
            root["gateway"] = gateway
            do {
                try FileManager.default.createDirectory(
                    at: configURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let data = try JSONSerialization.data(
                    withJSONObject: root,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: configURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: configURL.path
                )
                log.info("migrated gateway auth token into openclaw.json")
                configOK = true
            } catch {
                log.warning("openclaw.json write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Keychain copy — same redundancy story as the provider keys.
        let keychainOK = KeychainStore.saveString(token, service: keychainService, account: gatewayTokenKeychainAccount)
        if keychainOK {
            log.info("migrated gateway auth token into Keychain")
        } else {
            log.warning("Keychain write failed for gateway auth token")
        }

        return configOK && keychainOK
    }

    /// Boots out our legacy LaunchAgent label. Runs `/bin/launchctl
    /// bootout` synchronously off-main; non-zero exit codes are logged
    /// but not surfaced (the file removal that follows is the real
    /// stop-the-bleeding action).
    private static func bootoutLegacyAgent() async {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = [
                "bootout",
                "gui/\(getuid())/\(LocalGatewayManager.launchAgentLabel)"
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    // Exit 36 / "Unloading: 5" is the launchd code for
                    // "service was not loaded" — fine, it just means the
                    // user already booted it out manually.
                    log.info("launchctl bootout exit \(process.terminationStatus): \(out, privacy: .public)")
                }
            } catch {
                log.warning("launchctl bootout failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }
}
