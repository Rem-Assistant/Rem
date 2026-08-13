import Combine
import Foundation
import AuthenticationServices
import SwiftData
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
#if os(iOS)
import UIKit
#endif

/// Chooses which locally saved gateway record should absorb credentials from the
/// backend source of truth. Exact URL matches win; when the backend has migrated
/// a managed gateway to a new URL, reuse the active record for that provider so
/// the old gateway does not remain as a duplicate active-looking entry.
enum GatewayCredentialReconciliation {
    static func configToReplace(
        in configs: [GatewayConfig],
        canonicalURL: String,
        provider: GatewayProvider
    ) -> GatewayConfig? {
        configs.first { $0.url == canonicalURL && $0.provider == provider }
            ?? (provider == .fly
                ? configs.first { $0.isActive && $0.provider == .fly }
                : nil)
    }

    /// A credential refresh may synchronously clear an invalid session through
    /// `AuthenticatedHttpClient.onUnauthorized`. Do not overwrite that sign-out
    /// by completing token restoration after the request returns.
    static func shouldCompleteSessionRestore(hasBackendToken: Bool) -> Bool {
        hasBackendToken
    }
}

/// Manages user authentication via Apple / Google federated login.
/// Stores the backend JWT in Keychain via ``RemCredentialStore``.
@Observable @MainActor
final class RemAuthService {
    private(set) var isAuthenticated = false
    private(set) var currentUser: AuthUserInfo? {
        didSet {
            if oldValue?.id != currentUser?.id {
                accountLifecycleTicket &+= 1
            }
        }
    }
    /// Process-local identity epoch. Unlike the account id, this cannot compare equal after an
    /// A -> signed-out/B -> A replacement and therefore prevents old async authority from reviving.
    private(set) var accountLifecycleTicket: UInt64 = 0
    private(set) var error: AuthError?
    private var activeAppleAuthorizationController: ASAuthorizationController?
    private var activeAppleSignInDelegate: AppleSignInDelegate?

    /// True until `checkStoredToken()` finishes. UI should wait before rendering auth-dependent content.
    private(set) var isCheckingAuth = true

    /// True only when the most recent transition to signed-out was an explicit,
    /// user-initiated `signOut()` — NOT a transient de-auth (401 / token minted
    /// for another environment / expiry). The app reads this to decide whether
    /// to wipe local data: a transient de-auth must never destroy the user's
    /// tasks. See docs/rebuild/04-FIX-IDENTITY-DATALOSS.md (Cluster A).
    private(set) var lastDeauthWasUserInitiated = false

    nonisolated private static let lastSignedInUserIdKey = "rem.auth.lastSignedInUserId"

    /// The last userId that completed sign-in on this device. Used to wipe local
    /// data only when a *different* user signs in — not on a transient de-auth,
    /// and not for a returning user re-authenticating after a 401/expiry.
    /// `nonisolated` because it is plain thread-safe `UserDefaults` access.
    nonisolated static var lastSignedInUserId: String? {
        get { UserDefaults.standard.string(forKey: lastSignedInUserIdKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: lastSignedInUserIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSignedInUserIdKey)
            }
        }
    }

    /// Pure, testable decision for whether to wipe local user data (SwiftData
    /// tasks, focus sessions) on an auth transition. Extracted so the Cluster A
    /// data-loss guard cannot silently regress. See
    /// docs/rebuild/04-FIX-IDENTITY-DATALOSS.md.
    enum LocalDataResetDecision: Equatable {
        case keep
        case wipe

        /// Sign-in: wipe only when a *different* user signs in. A first-ever
        /// sign-in (nil previous) or a returning user (same id) keeps their data.
        static func onSignIn(newUserId: String, lastSignedInUserId: String?) -> LocalDataResetDecision {
            guard let last = lastSignedInUserId else { return .keep }
            return last == newUserId ? .keep : .wipe
        }

        /// De-auth: wipe only on an explicit, user-initiated sign-out. A transient
        /// de-auth (401 / token from another environment / expiry) keeps data.
        static func onDeauth(userInitiated: Bool) -> LocalDataResetDecision {
            userInitiated ? .wipe : .keep
        }
    }

    /// Reconcile local-data ownership at a sign-in transition. Call this when the
    /// app observes the user becoming authenticated. It resets the deauth flag and
    /// returns whether the app must wipe local data because a *different* user signed
    /// in. A different identity is recorded only after that wipe succeeds; recording
    /// it before persistence would expose the prior user's rows if disk I/O failed.
    /// Centralizing this here (rather than in the SwiftUI observer)
    /// keeps a single source of truth for identity (CLAUDE.md principle 3) and
    /// removes the observer's skip window. See docs/rebuild/04-FIX-IDENTITY-DATALOSS.md.
    ///
    /// If `currentUser` is not yet known (token restored before the profile loads)
    /// we cannot identify the user, so we neither record nor wipe and return
    /// `.keep`. That path occurs right after a reinstall, when the local store is
    /// already empty — so keeping is safe.
    @discardableResult
    func reconcileLocalDataOwnershipForSignedInUser() -> LocalDataResetDecision {
        lastDeauthWasUserInitiated = false
        guard let userId = currentUser?.id else { return .keep }
        let decision = LocalDataResetDecision.onSignIn(
            newUserId: userId,
            lastSignedInUserId: Self.lastSignedInUserId
        )
        if decision == .keep {
            Self.lastSignedInUserId = userId
        }
        return decision
    }

    /// Commit ownership only after a different-user SwiftData wipe succeeds.
    func confirmLocalDataOwnershipForSignedInUser() {
        if let userId = currentUser?.id {
            Self.lastSignedInUserId = userId
        }
    }

    /// Reject a newly authenticated different-user session when the old owner's local
    /// rows could not be cleared. Keep the prior ownership marker so a retry must wipe
    /// again; fail closed on the sign-in surface rather than exposing mixed data.
    func rejectSessionAfterLocalDataResetFailure() {
        lastDeauthWasUserInitiated = false
        RemCredentialStore.backendToken = nil
        isAuthenticated = false
        isReturningUser = false
        currentUser = nil
        clearCachedUser()
        error = .authenticationFailed("Rem couldn't securely switch accounts because local data could not be cleared. Free storage and try again.")
    }

    init() {
        #if DEBUG
        let debugBaseURL = AppConfig.apiBaseURL
        if !debugBaseURL.isEmpty, RemCredentialStore.backendURL != debugBaseURL {
            RemCredentialStore.backendURL = debugBaseURL
        }
        #endif

        // Wire the centralized HTTP client's 401 handler to our sign-out flow.
        AuthenticatedHttpClient.onUnauthorized = { [weak self] in
            self?.clearSessionBecauseUnauthorized()
        }
    }

    /// True when Keychain credentials survived an app reinstall but the user
    /// hasn't confirmed yet. Persisted via UserDefaults so it survives app kills
    /// but is wiped on reinstall (which is exactly when we need it to trigger).
    private(set) var isReturningUser = false

    /// UserDefaults key — set when the user completes sign-in or taps "Continue as".
    /// Absent after reinstall (UserDefaults wiped) while Keychain token survives.
    private static let hasConfirmedAuthKey = "rem.auth.confirmed"

    private var baseURL: String {
        AppConfig.apiBaseURL
    }

    #if DEBUG
    private static let debugAuthBackendURLKey = "rem.debug.auth.backend.url"
    private static let debugGatewayBackendURLKey = "rem.debug.gateway.backend.url"

    /// Debug builds can switch backend targets while Keychain survives app
    /// reinstalls. A token minted for production can be cryptographically valid
    /// in staging while pointing at a user row that does not exist there, which
    /// breaks gateway deploy when credentials are saved. Force a fresh sign-in
    /// once per debug backend target.
    private static func prepareAuthRefreshForDebugBackendIfNeeded() -> Bool {
        let currentBackendURL = AppConfig.apiBaseURL
        guard !currentBackendURL.isEmpty else { return false }

        let defaults = UserDefaults.standard
        guard defaults.string(forKey: debugAuthBackendURLKey) != currentBackendURL else {
            return false
        }

        defaults.set(currentBackendURL, forKey: debugAuthBackendURLKey)
        RemCredentialStore.clearAll()
        RemCredentialStore.backendURL = currentBackendURL
        defaults.removeObject(forKey: hasConfirmedAuthKey)
        GatewayConfigStore(keychainService: "app.remclaw").removeAll()
        print("[RemClaw] debug backend changed; cleared auth and gateway credentials for \(currentBackendURL)")
        return true
    }

    /// Debug builds can switch backend targets while Keychain and UserDefaults
    /// survive reinstalls. Clear gateway-only state once per target so staging
    /// builds do not keep connecting to gateways provisioned by production.
    private static func prepareGatewayRefreshForDebugBackendIfNeeded() -> Bool {
        let currentBackendURL = AppConfig.apiBaseURL
        guard !currentBackendURL.isEmpty else { return false }

        let defaults = UserDefaults.standard
        guard defaults.string(forKey: debugGatewayBackendURLKey) != currentBackendURL else {
            return false
        }

        defaults.set(currentBackendURL, forKey: debugGatewayBackendURLKey)
        RemCredentialStore.clearGateway()
        GatewayConfigStore(keychainService: "app.remclaw").removeAll()
        print("[RemClaw] debug backend changed; cleared stale gateway credentials for \(currentBackendURL)")
        return true
    }
    #endif

    // MARK: - Token Check

    /// Checks Keychain for a stored backend token, restores user profile and
    /// gateway credentials, then sets `isAuthenticated`.
    ///
    /// Call from a `.task` — this awaits network fetches so the UI has profile
    /// data (name, avatar) before showing "Continue as …".
    func checkStoredToken() async {
        defer { isCheckingAuth = false }

        #if DEBUG
        if Self.prepareAuthRefreshForDebugBackendIfNeeded() {
            isAuthenticated = false
            currentUser = nil
            return
        }
        #endif

        guard let token = RemCredentialStore.backendToken, !token.isEmpty else {
            isAuthenticated = false
            currentUser = nil
            return
        }

        // Restore backend URL if Keychain token survived but UserDefaults was wiped (app reinstall)
        if RemCredentialStore.backendURL == nil || RemCredentialStore.backendURL?.isEmpty == true {
            let url = AppConfig.apiBaseURL
            if !url.isEmpty {
                RemCredentialStore.backendURL = url
            }
        }

        #if DEBUG
        _ = Self.prepareGatewayRefreshForDebugBackendIfNeeded()
        #endif

        // Detect reinstall: Keychain token exists but the user never confirmed auth in this install
        if !UserDefaults.standard.bool(forKey: Self.hasConfirmedAuthKey) {
            isReturningUser = true
        }

        // User profile is now stored in Keychain (survives app reinstall)
        restoreCachedUser()

        // The backend is the source of truth for the user's active gateway. Always
        // attempt reconciliation on session restore so a gateway repair/migration
        // performed elsewhere reaches this device too. The request is additive:
        // failures leave the cached URL/token untouched for offline launch.
        do {
            try await restoreGatewayCredentialsIfNeeded()
        } catch {
            print("[RemClaw] restoreGatewayCredentialsIfNeeded failed during token restore: \(error.localizedDescription)")
        }

        guard GatewayCredentialReconciliation.shouldCompleteSessionRestore(
            hasBackendToken: RemCredentialStore.backendToken != nil
        ) else {
            return
        }

        isAuthenticated = true

        // Re-identify for telemetry on token restore
        if let user = currentUser {
            TelemetryService.shared.identify(userId: user.id)
        }
    }

    // MARK: - Apple Sign In

    func signInWithApple() async throws {
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let authorizationController = ASAuthorizationController(authorizationRequests: [request])
        guard let presentationAnchor = Self.activePresentationAnchor() else {
            throw AuthError.authenticationFailed("Could not find an active window for Apple Sign-In. Reopen Rem and try again.")
        }

        let result: AppleSignInResult
        defer {
            activeAppleAuthorizationController = nil
            activeAppleSignInDelegate = nil
        }
        do {
            result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AppleSignInResult, Error>) in
                let delegate = AppleSignInDelegate(
                    continuation: continuation,
                    presentationAnchor: presentationAnchor
                )
                authorizationController.delegate = delegate
                authorizationController.presentationContextProvider = delegate
                activeAppleAuthorizationController = authorizationController
                activeAppleSignInDelegate = delegate
                authorizationController.performRequests()
            }
        } catch let error as AuthError {
            throw error
        } catch {
            throw IdentityProviderFailure.map(provider: "Apple", operation: "complete Apple sign-in", error: error)
        }

        var profile: [String: String?]?
        if result.givenName != nil || result.familyName != nil {
            profile = [
                "given_name": result.givenName,
                "family_name": result.familyName,
            ]
        }
        try await authenticateWithBackend(provider: .apple, idToken: result.idToken, profile: profile, appleAuthorizationCode: result.authorizationCode)
    }

    // MARK: - Google Sign In

    #if canImport(GoogleSignIn)
    func signInWithGoogle() async throws {
        guard let clientID = AppConfig.googleClientID, !clientID.isEmpty, !clientID.hasPrefix("$(") else {
            throw AuthError.authenticationFailed("Google Client ID not configured. Set GIDClientID in xcconfig.")
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        // Check if user is already signed in to Google
        if let currentUser = GIDSignIn.sharedInstance.currentUser {
            do {
                try await currentUser.refreshTokensIfNeeded()
                if let idToken = currentUser.idToken?.tokenString {
                    let profile = extractGoogleProfile(from: currentUser)
                    try await authenticateWithBackend(provider: .google, idToken: idToken, profile: profile)
                    return
                }
            } catch {
                // Fall through to show sign-in UI after clearing the SDK's
                // own cached auth state. A stale Google keychain row can make
                // the next interactive sign-in fail while saving provider
                // auth, before Rem ever receives an ID token.
                GIDSignIn.sharedInstance.signOut()
            }

            if GIDSignIn.sharedInstance.currentUser != nil {
                GIDSignIn.sharedInstance.signOut()
            }
        }

        // The interactive flow is about to mint a fresh provider session. Clear
        // any remaining Google SDK keychain state first so a corrupt or stale
        // provider row cannot poison the save that happens after account
        // selection.
        GIDSignIn.sharedInstance.signOut()

        guard let presentingViewController = getRootViewController() else {
            throw AuthError.authenticationFailed("Could not get presenting view controller")
        }

        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
        } catch {
            throw IdentityProviderFailure.map(provider: "Google", operation: "open Google sign-in", error: error)
        }

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.authenticationFailed("Failed to get Google ID token")
        }

        let profile = extractGoogleProfile(from: result.user)
        try await authenticateWithBackend(provider: .google, idToken: idToken, profile: profile)
    }
    #endif

    /// Called when the returning user taps "Continue as …" to dismiss the welcome-back screen.
    func confirmReturningUser() {
        UserDefaults.standard.set(true, forKey: Self.hasConfirmedAuthKey)
        isReturningUser = false
    }

    // MARK: - Sign Out

    func signOut() {
        // Sign out of Google SDK session
        #if canImport(GoogleSignIn)
        if GIDSignIn.sharedInstance.currentUser != nil {
            GIDSignIn.sharedInstance.signOut()
        }
        #endif

        // Tell the backend to drop this device's APNs token so the signed-out
        // account stops receiving pushes here (#830 follow-up). MUST run before the
        // backend token is cleared below — it snapshots the bearer token now and
        // POSTs /push/unregister with it explicitly. iOS-only: no-op on Mac (no
        // APNs registration), guarded so the Mac target still compiles.
        #if os(iOS)
        PushRegistrationService.unregisterCurrentDevice()
        #endif

        // Clear Keychain token + backend URL
        RemCredentialStore.backendToken = nil

        // Drop the published brief headline. The stored value is account-stamped, so the next
        // account could not read it anyway — but it is model-authored prose that can name a
        // person or a company, and it should not outlive the session that produced it.
        BriefContext.clearOrchestratorHeadline()

        UserDefaults.standard.removeObject(forKey: Self.hasConfirmedAuthKey)
        // Keep the ownership marker after sign-out. Settings wipes SwiftData before
        // calling this method; retaining the marker fails closed if that wipe ever
        // fails and ensures a different future user must still clear the old rows.
        lastDeauthWasUserInitiated = true
        isAuthenticated = false
        isReturningUser = false
        currentUser = nil
        clearCachedUser()

        TelemetryService.shared.reset()
    }

    /// Clears partial app auth state and provider SDK state where the platform
    /// exposes a safe reset. This is intentionally user-triggered from the
    /// sign-in error UI because it may remove a cached provider session.
    func resetProviderSignInState(for provider: AuthProvider) async {
        clearFailedAuthenticationState()
        error = nil

        #if canImport(GoogleSignIn)
        if provider == .google {
            await resetGoogleSignInState()
        }
        #endif
    }

    // MARK: - SwiftData Cleanup

    /// Deletes all user-specific SwiftData records (tasks, focus sessions,
    /// pending operations) to prevent cross-user data leaks on sign-out.
    /// Call this from any sign-out path that has access to a ModelContext.
    @discardableResult
    static func clearAllUserData(from modelContext: ModelContext) -> Bool {
        do {
            try modelContext.delete(model: TaskEvent.self)
            try modelContext.delete(model: StoredFocusSession.self)
            try modelContext.delete(model: PendingTaskOperation.self)
            try modelContext.delete(model: TaskList.self)
            try modelContext.delete(model: TaskFolder.self)
            try modelContext.save()
            #if DEBUG
            print("[Auth] Cleared all SwiftData user data (TaskEvent, StoredFocusSession, PendingTaskOperation, TaskList, TaskFolder)")
            #endif
            return true
        } catch {
            // The new session is rejected by the caller. Restore the prior owner's
            // in-memory rows too, so a later successful save cannot accidentally
            // commit this failed bulk-delete attempt.
            modelContext.rollback()
            #if DEBUG
            print("[Auth] Failed to clear SwiftData user data: \(error.localizedDescription)")
            #endif
            TelemetryService.shared.track(
                eventName: "swiftdata_clear_failed",
                properties: ["error": error.localizedDescription]
            )
            return false
        }
    }

    /// Call when the backend returns 401 (e.g. token from another env or expired).
    /// Clears token and shows sign-in again so the user can get a fresh token from the current backend.
    /// This is a TRANSIENT de-auth: local data is intentionally preserved so a
    /// returning user (same id) keeps their tasks. The app only wipes on an
    /// explicit sign-out or when a different user signs in.
    /// See docs/rebuild/04-FIX-IDENTITY-DATALOSS.md (Cluster A).
    func clearSessionBecauseUnauthorized() {
        lastDeauthWasUserInitiated = false
        RemCredentialStore.backendToken = nil
        isAuthenticated = false
        currentUser = nil
    }

    // MARK: - Backend Auth

    private func authenticateWithBackend(provider: AuthProvider, idToken: String, profile: [String: String?]? = nil, appleAuthorizationCode: String? = nil) async throws {
        let fullURL = "\(baseURL)/api/v1/auth/login"

        guard let url = URL(string: fullURL) else {
            throw AuthError.networkError(NSError(domain: "Invalid URL", code: -1))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClientVersion.setHeaders(on: &request)

        var body: [String: Any] = [
            "provider": provider == .apple ? "apple" : "google",
            "id_token": idToken,
        ]

        if let profile {
            body["profile"] = profile
        }

        if let appleAuthorizationCode {
            body["apple_authorization_code"] = appleAuthorizationCode
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorData = try? JSONDecoder().decode([String: String].self, from: data),
               let errorMessage = errorData["error"] {
                throw AuthError.authenticationFailed(errorMessage)
            }
            throw AuthError.authenticationFailed("Authentication failed with status \(httpResponse.statusCode)")
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)

        do {
            // Store JWT and backend URL before any authenticated follow-up work.
            // If Keychain storage fails, keep the user signed out instead of
            // creating a partial auth session that will fail on the next launch.
            try saveBackendToken(authResponse.access_token)
            RemCredentialStore.backendURL = baseURL

            // Restore gateway credentials BEFORE setting isAuthenticated,
            // so the onChange handler sees credentials already in the store.
            try await restoreGatewayCredentialsIfNeeded()

            currentUser = authResponse.user
            try cacheUserOrThrow(authResponse.user)
        } catch {
            clearFailedAuthenticationState()
            currentUser = nil
            throw error
        }

        UserDefaults.standard.set(true, forKey: Self.hasConfirmedAuthKey)
        isAuthenticated = true

        // Telemetry: identify user + track signup/login
        let authProviderString = provider == .apple ? "apple" : "google"
        let isNewUser = authResponse.is_new_user ?? false
        let userProperties: [String: Any] = [
            "email": authResponse.user.email ?? "",
            "auth_provider": authProviderString,
            "full_name": authResponse.user.full_name ?? "",
        ]
        var propertiesSetOnce: [String: Any] = [:]
        if isNewUser {
            propertiesSetOnce["signup_date"] = ISO8601DateFormatter().string(from: Date())
        }
        TelemetryService.shared.identify(
            userId: authResponse.user.id,
            properties: userProperties,
            propertiesSetOnce: propertiesSetOnce.isEmpty ? nil : propertiesSetOnce
        )
        if isNewUser {
            TelemetryService.shared.track(eventName: TelemetryEvent.userSignedUp, properties: ["auth_provider": authProviderString])
        } else {
            TelemetryService.shared.track(eventName: TelemetryEvent.userLoggedIn, properties: ["auth_provider": authProviderString])
        }
    }

    // MARK: - Gateway Credential Restore

    /// After sign-in, check if the user already has a gateway deployed and restore credentials.
    /// This handles the sign-out → sign-back-in case where the gateway is still running.
    func restoreGatewayCredentialsIfNeeded() async throws {
        guard RemCredentialStore.backendToken != nil else {
            print("[RemClaw] restoreGatewayCredentialsIfNeeded skip: no backend token")
            return
        }

        do {
            let (data, http) = try await AuthenticatedHttpClient.request(
                path: "/api/v1/me/credentials",
                method: "GET"
            )
            print("[RemClaw] /me/credentials response status=\(http.statusCode)")
            guard http.statusCode == 200 else { return }

            let creds = try GatewayCredentialRefreshPolicy.decodeAndScrubLegacyVoiceKey(
                data: data,
                scrubLegacyVoiceKey: clearLegacyVoiceApiKey
            )
            RemCredentialStore.gatewayURL = creds.gatewayUrl
            try saveGatewayToken(creds.gatewayToken)
            let provider: GatewayProvider
            if let hostingProvider = creds.hostingProvider?.lowercased() {
                switch hostingProvider {
                case "railway":
                    RemCredentialStore.gatewayProviderName = "Railway"
                    provider = .manual
                case "fly":
                    RemCredentialStore.gatewayProviderName = "Fly.io"
                    provider = .fly
                default:
                    RemCredentialStore.gatewayProviderName = hostingProvider.capitalized
                    provider = .manual
                }
            } else {
                provider = .fly
            }
            upsertRestoredGatewayConfig(
                url: creds.gatewayUrl,
                token: creds.gatewayToken,
                provider: provider
            )
            print("[RemClaw] gateway credentials restored url=\(creds.gatewayUrl)")
        } catch let error as AuthError {
            print("[RemClaw] restoreGatewayCredentialsIfNeeded storage failed: \(error.localizedDescription)")
            throw error
        } catch is AuthenticatedHttpError {
            // 401 handled by AuthenticatedHttpClient (sign-out triggered automatically)
            print("[RemClaw] restoreGatewayCredentialsIfNeeded: auth error")
        } catch {
            print("[RemClaw] restoreGatewayCredentialsIfNeeded failed: \(error.localizedDescription)")
        }
    }

    private func upsertRestoredGatewayConfig(url: String, token: String, provider: GatewayProvider) {
        let store = GatewayConfigStore(keychainService: "app.remclaw")
        let existing = GatewayCredentialReconciliation.configToReplace(
            in: store.configs,
            canonicalURL: url,
            provider: provider
        )
        store.save(
            GatewayConfig(
                id: existing?.id ?? UUID().uuidString,
                url: url,
                token: token,
                provider: provider,
                displayName: provider == .fly ? "Cloud Gateway" : provider.displayName,
                macAddress: existing?.macAddress,
                isActive: true,
                transport: existing?.transport,
                tailscaleURL: existing?.tailscaleURL,
                sshLocalPort: existing?.sshLocalPort,
                isBootstrap: existing?.isBootstrap
            )
        )
    }

    private func clearFailedAuthenticationState() {
        RemCredentialStore.clearAll()
        GatewayConfigStore(keychainService: "app.remclaw").removeAll()
    }

    // MARK: - Profile Fetch

    /// Fetches user profile from GET /api/v1/me when the cached user is missing
    /// (e.g. after app reinstall where Keychain survives but UserDefaults is wiped).
    private func fetchAndCacheUserProfile() async {
        do {
            let (data, http) = try await AuthenticatedHttpClient.request(
                path: "/api/v1/me",
                method: "GET"
            )
            guard http.statusCode == 200 else { return }

            struct MeResponse: Codable {
                let id: String
                let email: String?
                let full_name: String?
                let first_name: String?
                let last_name: String?
                let profile_picture_url: String?
                let locale: String?
            }

            let me = try JSONDecoder().decode(MeResponse.self, from: data)
            let user = AuthUserInfo(
                id: me.id,
                email: me.email,
                full_name: me.full_name,
                first_name: me.first_name,
                last_name: me.last_name,
                profile_picture_url: me.profile_picture_url,
                locale: me.locale
            )
            currentUser = user
            cacheUser(user)
        } catch {
            #if DEBUG
            print("[Auth] Failed to fetch user profile: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Helpers

    #if canImport(GoogleSignIn)
    private func extractGoogleProfile(from user: GIDGoogleUser) -> [String: String?] {
        let profile = user.profile
        return [
            "email": profile?.email,
            "name": profile?.name,
            "given_name": profile?.givenName,
            "family_name": profile?.familyName,
            "picture": profile?.imageURL(withDimension: 320)?.absoluteString,
            "locale": nil,
        ]
    }
    #endif

    private func getRootViewController() -> UIViewController? {
        #if os(iOS)
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
        #else
        nil
        #endif
    }

    private static func activePresentationAnchor() -> ASPresentationAnchor? {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        #else
        nil
        #endif
    }

    #if canImport(GoogleSignIn)
    private func resetGoogleSignInState() async {
        if GIDSignIn.sharedInstance.currentUser == nil {
            await restorePreviousGoogleSignInUser()
        }

        guard GIDSignIn.sharedInstance.currentUser != nil else {
            GIDSignIn.sharedInstance.signOut()
            return
        }

        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.disconnect { _ in
                GIDSignIn.sharedInstance.signOut()
                continuation.resume()
            }
        }
    }

    private func restorePreviousGoogleSignInUser() async {
        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { _, _ in
                continuation.resume()
            }
        }
    }
    #endif

    private func cacheUser(_ user: AuthUserInfo) {
        RemCredentialStore.saveCachedUser(user)
    }

    private func cacheUserOrThrow(_ user: AuthUserInfo) throws {
        do {
            try RemCredentialStore.saveCachedUserOrThrow(user)
        } catch {
            throw credentialStorageError(credential: "cached user profile", error: error)
        }
    }

    private func saveBackendToken(_ token: String) throws {
        do {
            try RemCredentialStore.saveBackendTokenOrThrow(token)
        } catch {
            throw credentialStorageError(credential: "backend sign-in token", error: error)
        }
    }

    private func saveGatewayToken(_ token: String) throws {
        do {
            try RemCredentialStore.saveGatewayTokenOrThrow(token)
        } catch {
            throw credentialStorageError(credential: "gateway token", error: error)
        }
    }

    private func clearLegacyVoiceApiKey() throws {
        do {
            try RemCredentialStore.clearElevenLabsApiKeyOrThrow()
        } catch {
            throw credentialStorageError(credential: "legacy voice API key", error: error)
        }
    }

    private func credentialStorageError(credential: String, error: Error) -> AuthError {
        if let keychainError = error as? KeychainStore.KeychainError {
            return .credentialStorageFailed(
                CredentialStorageFailure(
                    credential: credential,
                    operation: keychainError.operation,
                    status: keychainError.status,
                    detail: "\(keychainError.service)/\(keychainError.account): \(keychainError.localizedDescription)"
                )
            )
        }

        return .credentialStorageFailed(
            CredentialStorageFailure(
                credential: credential,
                detail: error.localizedDescription
            )
        )
    }

    private func restoreCachedUser() {
        guard let user = RemCredentialStore.loadCachedUser(AuthUserInfo.self) else { return }
        currentUser = user
    }

    private func clearCachedUser() {
        RemCredentialStore.clearCachedUser()
    }
}

// MARK: - Apple Sign In Delegate

/// Result from Apple Sign-In containing the ID token, optional authorization code, and optional name.
private struct AppleSignInResult {
    let idToken: String
    let authorizationCode: String?
    let givenName: String?
    let familyName: String?
}

private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let continuation: CheckedContinuation<AppleSignInResult, Error>
    private let presentationAnchor: ASPresentationAnchor

    init(
        continuation: CheckedContinuation<AppleSignInResult, Error>,
        presentationAnchor: ASPresentationAnchor
    ) {
        self.continuation = continuation
        self.presentationAnchor = presentationAnchor
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
           let identityToken = credential.identityToken,
           let idTokenString = String(data: identityToken, encoding: .utf8) {
            let authCode: String?
            if let codeData = credential.authorizationCode {
                authCode = String(data: codeData, encoding: .utf8)
            } else {
                authCode = nil
            }
            continuation.resume(returning: AppleSignInResult(
                idToken: idTokenString,
                authorizationCode: authCode,
                givenName: credential.fullName?.givenName,
                familyName: credential.fullName?.familyName
            ))
        } else {
            continuation.resume(throwing: AuthError.authenticationFailed("Failed to get Apple ID token"))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation.resume(throwing: error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presentationAnchor
    }
}
