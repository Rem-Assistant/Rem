import Foundation

enum PushRegistrationStatePolicy {
    /// Returns every token this install may still own, with the last successfully registered
    /// destination first. APNs can rotate from `persisted` to `latest` while the new registration
    /// is still in flight; unregistering only one value would leave the other account-owned row
    /// enabled after sign-out.
    static func tokensForUnregister(latest: String?, persisted: String?) -> [String] {
        [persisted, latest]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, token in
                if !result.contains(token) { result.append(token) }
            }
    }

    /// A registration cache is authoritative only when it describes the complete installation
    /// ownership claim accepted by the backend. Older app versions persisted only token,
    /// environment, and user; treating that partial cache as current would skip the one request
    /// that upgrades a legacy database row into the generation-fenced contract.
    static func registrationMatchesAuthority(
        token: String,
        environment: String,
        userId: String,
        installationId: String,
        ownershipGeneration: Int,
        persistedToken: String?,
        persistedEnvironment: String?,
        persistedUserId: String?,
        persistedInstallationId: String?,
        persistedOwnershipGeneration: Int?
    ) -> Bool {
        persistedToken == token
            && persistedEnvironment == environment
            && persistedUserId == userId
            && persistedInstallationId == installationId
            && persistedOwnershipGeneration == ownershipGeneration
    }

    /// A shipped-version cache proves only that this account once registered the token; it does
    /// not prove the migration's `legacy:<user-id>` row was upgraded to this install UUID. A cold
    /// logout must ask the backend to retire that exact legacy token in the same transaction as the
    /// new installation tombstone whenever either authority field is missing.
    static func requiresLegacyAuthorityRetirement(
        persistedToken: String?,
        persistedUserId: String?,
        persistedInstallationId: String?,
        persistedOwnershipGeneration: Int?,
        currentUserId: String?
    ) -> Bool {
        guard let token = persistedToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let persistedUserId,
              !persistedUserId.isEmpty,
              persistedUserId == currentUserId
        else { return false }
        let installationId = persistedInstallationId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return installationId.isEmpty || persistedOwnershipGeneration == nil
    }
}

/// Registers this device's APNs token with the backend so backend-scheduled
/// routines can deliver remote pushes (the proactive half of the thesis).
///
/// Flow:
/// 1. `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
///    receives the raw APNs token, hex-encodes it, and hands it here.
/// 2. We POST `{ token, platform: "ios", environment }` to `/api/v1/push/register`
///    (backend PR #830 — `push.service.ts`, `device_tokens` table) using the same
///    `AuthenticatedHttpClient` every other backend service uses.
///
/// `environment` follows the build config: `"sandbox"` for DEBUG (development APNs),
/// `"production"` for Release. With **automatic** code signing, Xcode rewrites the
/// `aps-environment` entitlement to `production` when the build is signed for
/// distribution (TestFlight / App Store) and leaves it `development` for
/// development-signed builds — so the source `RemClaw.entitlements` value
/// (`development`) is correct for both: used as-is for DEBUG (sandbox token) and
/// promoted to `production` for distribution Release builds (production token).
/// `currentEnvironment` mirrors that promotion (DEBUG → `"sandbox"`, Release →
/// `"production"`), keeping the value we send aligned with the token APNs minted.
/// (A Release build that is *not* distribution-signed — e.g. a local Release run on
/// a dev profile — is the lone mismatch, but that path doesn't ship.)
///
/// The most-recent token is retained so registration can also be flushed after the
/// user authenticates (a token can arrive before sign-in). The last successfully
/// posted token+environment+userId is cached in `UserDefaults` to avoid redundant
/// POSTs across launches. A stable installation ID plus monotonic ownership generation
/// prevents an in-flight request from an older account from reclaiming the destination.
@MainActor
enum PushRegistrationService {

    /// Push registration body — matches `push.routes.ts` POST /push/register.
    private struct RegisterBody: Encodable {
        let token: String
        let platform: String
        let environment: String
        let installationId: String
        let ownershipGeneration: Int
    }

    /// Push unregister body — matches `push.routes.ts` POST /push/unregister.
    private struct UnregisterBody: Encodable {
        let token: String
        let installationId: String
        let ownershipGeneration: Int
        let retireLegacyAuthority: Bool
    }

    private static let lastSentTokenKey = "rem.push.lastSentToken"
    private static let lastSentEnvironmentKey = "rem.push.lastSentEnvironment"
    private static let lastSentUserIdKey = "rem.push.lastSentUserId"
    private static let lastSentInstallationIdKey = "rem.push.lastSentInstallationId"
    private static let lastSentOwnershipGenerationKey = "rem.push.lastSentOwnershipGeneration"
    private static let installationIdKey = "rem.push.installationId"
    private static let ownershipUserIdKey = "rem.push.ownershipUserId"
    private static let ownershipGenerationKey = "rem.push.ownershipGeneration"

    /// Hex APNs token, retained in memory so we can retry after auth lands.
    private static var latestDeviceToken: String?
    private static var registrationTask: Task<Void, Never>?

    /// Sandbox APNs in DEBUG, production APNs in Release — mirrors the entitlement.
    static var currentEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // MARK: - Entry points

    /// Called from `didRegisterForRemoteNotificationsWithDeviceToken` with the
    /// hex-encoded APNs token. Stores it and posts if the user is authenticated.
    static func handleDeviceToken(_ hexToken: String) {
        latestDeviceToken = hexToken
        registerLatestTokenIfPossible()
    }

    /// Re-attempts registration of the most recent token — e.g. after the user
    /// signs in (or a stored token is restored on launch), when a token may have
    /// arrived before a backend session existed. This is the post-authentication
    /// entry point: called from `RemClawApp`'s auth-state observer so the common
    /// "returning user, token already in hand" case actually registers instead of
    /// deferring forever.
    static func flushPendingRegistration() {
        registerLatestTokenIfPossible()
    }

    /// On sign-out, tell the backend to drop this device's token so the account
    /// that just signed out stops receiving pushes on this install. MUST be called
    /// BEFORE the backend token is cleared from `RemCredentialStore` — we snapshot
    /// the bearer token and base URL now and POST with them explicitly, because the
    /// credential store is wiped by the time the async request runs.
    static func unregisterCurrentDevice() {
        let defaults = UserDefaults.standard
        let deviceTokens = PushRegistrationStatePolicy.tokensForUnregister(
            latest: latestDeviceToken,
            persisted: defaults.string(forKey: lastSentTokenKey)
        )
        guard !deviceTokens.isEmpty else { return }
        guard let backendToken = RemCredentialStore.backendToken, !backendToken.isEmpty else { return }
        let baseURL = RemCredentialStore.backendURL ?? AppConfig.apiBaseURL
        guard !baseURL.isEmpty else { return }

        registrationTask?.cancel()
        registrationTask = nil
        let installationId = currentInstallationId
        let generation = advanceOwnershipGeneration(for: currentUserId ?? "", force: true)
        let persistedGeneration = defaults.object(forKey: lastSentOwnershipGenerationKey) == nil
            ? nil
            : defaults.integer(forKey: lastSentOwnershipGenerationKey)
        let retireLegacyAuthority = PushRegistrationStatePolicy.requiresLegacyAuthorityRetirement(
            persistedToken: defaults.string(forKey: lastSentTokenKey),
            persistedUserId: defaults.string(forKey: lastSentUserIdKey),
            persistedInstallationId: defaults.string(forKey: lastSentInstallationIdKey),
            persistedOwnershipGeneration: persistedGeneration,
            currentUserId: currentUserId
        )

        // Drop the skip-cache so the next account to sign in re-registers this token
        // (its user_id no longer matches the cached one anyway, but be explicit).
        defaults.removeObject(forKey: lastSentTokenKey)
        defaults.removeObject(forKey: lastSentEnvironmentKey)
        defaults.removeObject(forKey: lastSentUserIdKey)
        defaults.removeObject(forKey: lastSentInstallationIdKey)
        defaults.removeObject(forKey: lastSentOwnershipGenerationKey)

        Task {
            for deviceToken in deviceTokens {
                await postUnregister(
                    deviceToken: deviceToken,
                    backendToken: backendToken,
                    baseURL: baseURL,
                    installationId: installationId,
                    ownershipGeneration: generation,
                    retireLegacyAuthority: retireLegacyAuthority
                )
            }
        }
    }

    // MARK: - Core

    /// The user the backend will scope this token to. Read from the canonical
    /// signed-in identity persisted by `RemAuthService`, so the skip-cache key is
    /// user-aware and a different account on the same install re-registers.
    private static var currentUserId: String? {
        RemAuthService.lastSignedInUserId
    }

    private static var currentInstallationId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: installationIdKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: installationIdKey)
        return created
    }

    /// Monotonic per-install generation. Account transitions advance it so an older in-flight
    /// request can never reclaim this APNs destination after the next account has registered.
    private static func advanceOwnershipGeneration(for userId: String, force: Bool = false) -> Int {
        let defaults = UserDefaults.standard
        let previousUserId = defaults.string(forKey: ownershipUserIdKey)
        var generation = defaults.integer(forKey: ownershipGenerationKey)
        if force || previousUserId != userId {
            let wallClockGeneration = Int(Date().timeIntervalSince1970 * 1_000)
            generation = max(generation + 1, wallClockGeneration)
            defaults.set(userId, forKey: ownershipUserIdKey)
            defaults.set(generation, forKey: ownershipGenerationKey)
        } else if generation == 0 {
            generation = 1
            defaults.set(generation, forKey: ownershipGenerationKey)
        }
        return generation
    }

    private static func registerLatestTokenIfPossible() {
        guard let token = latestDeviceToken else { return }

        // Only post when authenticated — the endpoint requires a JWT, and the
        // token is keyed to the user server-side.
        guard let backendToken = RemCredentialStore.backendToken, !backendToken.isEmpty else {
            #if DEBUG
            print("[Push] device token received but not authenticated — deferring registration")
            #endif
            return
        }

        let environment = currentEnvironment
        let userId = currentUserId ?? ""
        let installationId = currentInstallationId
        let ownershipGeneration = advanceOwnershipGeneration(for: userId)
        let baseURL = RemCredentialStore.backendURL ?? AppConfig.apiBaseURL
        guard !baseURL.isEmpty else { return }

        // Skip only when the complete ownership authority was accepted. A token/environment/user
        // cache written by an older app intentionally misses the installation fields and therefore
        // forces one upgrade registration that repairs its legacy destination row.
        let defaults = UserDefaults.standard
        let persistedGeneration = defaults.object(forKey: lastSentOwnershipGenerationKey) == nil
            ? nil
            : defaults.integer(forKey: lastSentOwnershipGenerationKey)
        if PushRegistrationStatePolicy.registrationMatchesAuthority(
            token: token,
            environment: environment,
            userId: userId,
            installationId: installationId,
            ownershipGeneration: ownershipGeneration,
            persistedToken: defaults.string(forKey: lastSentTokenKey),
            persistedEnvironment: defaults.string(forKey: lastSentEnvironmentKey),
            persistedUserId: defaults.string(forKey: lastSentUserIdKey),
            persistedInstallationId: defaults.string(forKey: lastSentInstallationIdKey),
            persistedOwnershipGeneration: persistedGeneration
        ) {
            return
        }

        registrationTask?.cancel()
        registrationTask = Task {
            await postRegistration(
                token: token,
                environment: environment,
                userId: userId,
                backendToken: backendToken,
                baseURL: baseURL,
                installationId: installationId,
                ownershipGeneration: ownershipGeneration
            )
        }
    }

    private static func postRegistration(
        token: String,
        environment: String,
        userId: String,
        backendToken: String,
        baseURL: String,
        installationId: String,
        ownershipGeneration: Int
    ) async {
        do {
            let body = try JSONEncoder().encode(
                RegisterBody(
                    token: token,
                    platform: "ios",
                    environment: environment,
                    installationId: installationId,
                    ownershipGeneration: ownershipGeneration
                )
            )
            guard let url = URL(string: "\(baseURL)/api/v1/push/register") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(backendToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ClientVersion.setHeaders(on: &request)
            request.httpBody = body
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            guard (200...299).contains(http.statusCode) else {
                #if DEBUG
                print("[Push] register failed — HTTP \(http.statusCode)")
                #endif
                return
            }

            // Do not let a superseded account's delayed completion poison the success cache.
            let defaults = UserDefaults.standard
            guard defaults.string(forKey: ownershipUserIdKey) == userId,
                  defaults.integer(forKey: ownershipGenerationKey) == ownershipGeneration else {
                return
            }
            defaults.set(token, forKey: lastSentTokenKey)
            defaults.set(environment, forKey: lastSentEnvironmentKey)
            defaults.set(userId, forKey: lastSentUserIdKey)
            defaults.set(installationId, forKey: lastSentInstallationIdKey)
            defaults.set(ownershipGeneration, forKey: lastSentOwnershipGenerationKey)
            #if DEBUG
            print("[Push] registered APNs token (\(environment))")
            #endif
        } catch {
            #if DEBUG
            print("[Push] register error: \(error.localizedDescription)")
            #endif
        }
    }

    private static func postUnregister(
        deviceToken: String,
        backendToken: String,
        baseURL: String,
        installationId: String,
        ownershipGeneration: Int,
        retireLegacyAuthority: Bool
    ) async {
        guard let url = URL(string: "\(baseURL)/api/v1/push/unregister") else { return }
        do {
            // Posted with an explicit bearer token (not via AuthenticatedHttpClient)
            // because the credential store is cleared synchronously during sign-out,
            // before this Task runs — the client would throw `notAuthenticated`.
            let body = try JSONEncoder().encode(
                UnregisterBody(
                    token: deviceToken,
                    installationId: installationId,
                    ownershipGeneration: ownershipGeneration,
                    retireLegacyAuthority: retireLegacyAuthority
                )
            )
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(backendToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ClientVersion.setHeaders(on: &request)
            request.httpBody = body
            let (_, response) = try await URLSession.shared.data(for: request)
            #if DEBUG
            if let http = response as? HTTPURLResponse {
                print("[Push] unregister HTTP \(http.statusCode)")
            }
            #endif
        } catch {
            #if DEBUG
            print("[Push] unregister error: \(error.localizedDescription)")
            #endif
        }
    }
}
