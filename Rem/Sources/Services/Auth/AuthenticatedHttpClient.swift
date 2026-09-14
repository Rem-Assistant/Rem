import Foundation

/// Centralized HTTP client that adds JWT authentication to all backend API requests.
///
/// On 401 responses, the client:
/// 1. Attempts a silent token refresh via `/api/v1/auth/refresh`
/// 2. Retries the original request with the new token
/// 3. If the refresh also fails (401), triggers sign-out via ``RemAuthService``
///
/// All backend API calls should use this client instead of raw URLSession.
@MainActor
enum AuthenticatedHttpClient {

    /// Immutable credentials captured synchronously with a user-authorized mutation. Suggestion
    /// actions use this instead of re-reading global credentials after an actor hop, which could
    /// otherwise send an old account's payload with a newly signed-in account's token.
    struct RequestAuthority: @unchecked Sendable, Equatable {
        fileprivate let token: String
        fileprivate let baseURL: String

        init(token: String, baseURL: String) {
            self.token = token
            self.baseURL = baseURL
        }
    }

    /// Immutable account ownership and credentials for a long-lived operation. Unlike
    /// ``RequestAuthority``, this authority may refresh a 401, but any Keychain or sign-out side
    /// effects remain conditional on the captured account still owning the current credentials.
    struct AccountRequestAuthority: @unchecked Sendable, Equatable {
        let token: String
        let baseURL: String
        let accountID: String

        init(token: String, baseURL: String, accountID: String) {
            self.token = token
            self.baseURL = baseURL
            self.accountID = accountID
        }
    }

    static func captureRequestAuthority(expectedBackendURL: String) -> RequestAuthority? {
        guard let token = RemCredentialStore.backendToken, !token.isEmpty else { return nil }
        let baseURL = RemCredentialStore.backendURL ?? AppConfig.apiBaseURL
        guard normalized(baseURL) == normalized(expectedBackendURL) else { return nil }
        return RequestAuthority(token: token, baseURL: baseURL)
    }

    static func captureAccountRequestAuthority() -> AccountRequestAuthority? {
        if let accountAuthorityProvider {
            return accountAuthorityProvider()
        }
        guard let token = RemCredentialStore.backendToken, !token.isEmpty,
              let accountID = VoiceConfigurationAccountIdentity.accountID(fromJWT: token) else {
            return nil
        }
        let baseURL = RemCredentialStore.backendURL ?? AppConfig.apiBaseURL
        guard !baseURL.isEmpty else { return nil }
        return AccountRequestAuthority(token: token, baseURL: baseURL, accountID: accountID)
    }

    /// Callback set by RemAuthService on init to handle forced sign-out on unrecoverable 401.
    /// Avoids a circular dependency between this client and RemAuthService.
    nonisolated(unsafe) static var onUnauthorized: (@MainActor () -> Void)?

    /// Deduplicates concurrent 401 token refresh attempts.
    /// Multiple in-flight requests that each receive a 401 will share a single refresh task.
    nonisolated(unsafe) private static var refreshTask: Task<String, Error>?

    /// Account-bound recoveries survive view cancellation, so their refreshes cannot share the
    /// unscoped global task or publish into whichever account happens to be signed in later.
    private struct BoundRefreshAuthority: Hashable {
        let accountID: String
        let token: String
        let normalizedBaseURL: String
    }

    private static var boundRefreshTasks: [BoundRefreshAuthority: Task<String, Error>] = [:]

    /// Injectable transport for deterministic production-lifecycle tests.
    typealias RequestExecutor = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    nonisolated(unsafe) static var requestExecutor: RequestExecutor?

    /// Injectable current-authority seam for deterministic auth-boundary tests. Production reads
    /// the exact account, token, and backend currently stored on this device.
    typealias AccountAuthorityProvider = @MainActor () -> AccountRequestAuthority?
    nonisolated(unsafe) static var accountAuthorityProvider: AccountAuthorityProvider?

    /// Deterministic test seam for proving that multiple callers joined the same bound refresh.
    typealias BoundRefreshWaiterObserver = @MainActor () -> Void
    nonisolated(unsafe) static var boundRefreshWaiterObserver: BoundRefreshWaiterObserver?

    // X-Client-Version header lives in shared ClientVersion (#226).

    // MARK: - Public API

    /// Performs an authenticated GET request and decodes the response.
    static func get<T: Decodable>(
        _ path: String,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let (data, http) = try await performWithAuth(path: path, method: "GET", body: nil, timeout: timeout)
        guard (200...299).contains(http.statusCode) else {
            throw AuthenticatedHttpError.httpError(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Performs an authenticated POST request and decodes the response.
    static func post<T: Decodable>(
        _ path: String,
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let (data, http) = try await performWithAuth(path: path, method: "POST", body: body, timeout: timeout)
        guard (200...299).contains(http.statusCode) else {
            throw AuthenticatedHttpError.httpError(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Performs a long-lived request with immutable authorization captured at user intent time.
    /// A response may still complete after account change, but refresh/sign-out side effects are
    /// allowed only while Keychain continues to hold the captured account.
    static func postBoundToAccount<T: Decodable>(
        _ path: String,
        bearerToken: String,
        accountID: String,
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let baseURL = RemCredentialStore.backendURL ?? AppConfig.apiBaseURL
        let (data, http) = try await performBoundToAccount(
            path: path,
            method: "POST",
            body: body,
            timeout: timeout,
            bearerToken: bearerToken,
            accountID: accountID,
            baseURL: baseURL
        )
        guard (200...299).contains(http.statusCode) else {
            throw AuthenticatedHttpError.httpError(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Performs an authenticated request and returns raw (data, HTTPURLResponse).
    /// Use this when you need custom response handling (e.g., checking specific status codes).
    static func request(
        path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval = 30,
        customHeaders: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await performWithAuth(
            path: path,
            method: method,
            body: body,
            timeout: timeout,
            customHeaders: customHeaders
        )
    }

    /// Performs a raw request with account identity, credentials, and backend URL captured before
    /// the operation's first suspension. A 401 refresh never adopts credentials from another
    /// account and cannot mutate or sign out a replacement account.
    static func request(
        path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval = 30,
        authority: AccountRequestAuthority
    ) async throws -> (Data, HTTPURLResponse) {
        try await performBoundToAccount(
            path: path,
            method: method,
            body: body,
            timeout: timeout,
            bearerToken: authority.token,
            accountID: authority.accountID,
            baseURL: authority.baseURL
        )
    }

    /// Executes with the exact backend and bearer token captured at tap time. A scoped mutation
    /// deliberately does not refresh through current global credentials on 401: retrying under a
    /// replacement account would violate the mutation's ownership boundary.
    static func request(
        path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval = 30,
        authority: RequestAuthority
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "\(authority.baseURL)\(path)") else {
            throw AuthenticatedHttpError.invalidURL(path)
        }
        return try await execute(
            url: url,
            method: method,
            token: authority.token,
            body: body,
            timeout: timeout
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    // MARK: - Core

    private static func performWithAuth(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        customHeaders: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let token = RemCredentialStore.backendToken, !token.isEmpty else {
            throw AuthenticatedHttpError.notAuthenticated
        }

        let baseURL = RemCredentialStore.backendURL ?? AppConfig.apiBaseURL
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)\(path)") else {
            throw AuthenticatedHttpError.invalidURL(path)
        }

        // First attempt
        let (data, httpResponse) = try await execute(
            url: url, method: method, token: token,
            body: body, timeout: timeout, customHeaders: customHeaders
        )

        guard httpResponse.statusCode == 401 else {
            return (data, httpResponse)
        }

        // 401 received — attempt token refresh
        #if DEBUG
        print("[AuthHttpClient] 401 on \(method) \(path) — attempting token refresh")
        #endif

        do {
            let newToken = try await refreshTokenDeduped(currentToken: token, baseURL: baseURL)
            RemCredentialStore.backendToken = newToken

            // Retry with new token
            let (retryData, retryResponse) = try await execute(
                url: url, method: method, token: newToken,
                body: body, timeout: timeout, customHeaders: customHeaders
            )

            if retryResponse.statusCode == 401 {
                // Refresh succeeded but retry still 401 — token is truly invalid
                #if DEBUG
                print("[AuthHttpClient] retry still 401 after refresh — signing out")
                #endif
                triggerSignOut()
                throw AuthenticatedHttpError.unauthorized
            }

            return (retryData, retryResponse)
        } catch let error as AuthenticatedHttpError where error == .unauthorized {
            triggerSignOut()
            throw error
        } catch {
            // Refresh itself failed — sign out
            #if DEBUG
            print("[AuthHttpClient] token refresh failed: \(error.localizedDescription) — signing out")
            #endif
            triggerSignOut()
            throw AuthenticatedHttpError.unauthorized
        }
    }

    private static func performBoundToAccount(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        bearerToken: String,
        accountID: String,
        baseURL: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
            requestAccountID: accountID,
            authorityTokens: [bearerToken],
            currentToken: bearerToken
        ) else {
            throw AuthenticatedHttpError.notAuthenticated
        }
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)\(path)") else {
            throw AuthenticatedHttpError.invalidURL(path)
        }

        let (data, response) = try await execute(
            url: url,
            method: method,
            token: bearerToken,
            body: body,
            timeout: timeout
        )
        guard response.statusCode == 401 else { return (data, response) }

        let newToken: String
        do {
            newToken = try await refreshBoundTokenDeduped(
                currentToken: bearerToken,
                baseURL: baseURL,
                accountID: accountID
            )
        } catch let error as AuthenticatedHttpError where error == .unauthorized {
            triggerSignOutIfCurrentAuthority(
                accountID: accountID,
                authorityTokens: [bearerToken]
            )
            throw error
        } catch {
            triggerSignOutIfCurrentAuthority(
                accountID: accountID,
                authorityTokens: [bearerToken]
            )
            throw AuthenticatedHttpError.unauthorized
        }

        // The refresh task deliberately outlives a cancelled caller so concurrent requests can
        // share it. That must not authorize this caller's retry: immediately before the second
        // network mutation, require both live task intent and the exact captured credentials.
        let originalAuthority = AccountRequestAuthority(
            token: bearerToken,
            baseURL: baseURL,
            accountID: accountID
        )
        let refreshedAuthority = AccountRequestAuthority(
            token: newToken,
            baseURL: baseURL,
            accountID: accountID
        )
        let currentAuthority = captureAccountRequestAuthority()
        guard !Task.isCancelled,
              currentAuthority == originalAuthority || currentAuthority == refreshedAuthority else {
            throw AuthenticatedHttpError.notAuthenticated
        }
        if accountAuthorityProvider == nil {
            // A joined waiter may observe the exact token that the first waiter already installed.
            // Never replace any third, newer credential that arrived while refresh was suspended.
            if currentAuthority == originalAuthority {
                RemCredentialStore.backendToken = newToken
            }
        }

        // Once this retry is issued, a transport/invalid-response failure is ambiguous: the
        // mutation may have committed before its response was lost. Preserve that error for the
        // caller instead of collapsing it into `.unauthorized` (which is definitely uncommitted).
        let (retryData, retryResponse) = try await execute(
            url: url,
            method: method,
            token: newToken,
            body: body,
            timeout: timeout
        )
        if retryResponse.statusCode == 401 {
            triggerSignOutIfCurrentAuthority(
                accountID: accountID,
                authorityTokens: [bearerToken, newToken]
            )
            throw AuthenticatedHttpError.unauthorized
        }
        return (retryData, retryResponse)
    }

    private static func execute(
        url: URL,
        method: String,
        token: String,
        body: Data?,
        timeout: TimeInterval,
        customHeaders: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClientVersion.setHeaders(on: &request)
        request.httpBody = body
        request.timeoutInterval = timeout

        if let customHeaders {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return try await perform(request)
    }

    // MARK: - Token Refresh

    /// Deduplicates concurrent refresh calls — if a refresh is already in flight, awaits it instead of starting a new one.
    private static func refreshTokenDeduped(currentToken: String, baseURL: String) async throws -> String {
        if let existing = AuthenticatedHttpClient.refreshTask {
            return try await existing.value
        }
        let task = Task<String, Error> {
            defer { AuthenticatedHttpClient.refreshTask = nil }
            return try await refreshToken(currentToken: currentToken, baseURL: baseURL)
        }
        AuthenticatedHttpClient.refreshTask = task
        return try await task.value
    }

    private static func refreshBoundTokenDeduped(
        currentToken: String,
        baseURL: String,
        accountID: String
    ) async throws -> String {
        boundRefreshWaiterObserver?()
        let authority = BoundRefreshAuthority(
            accountID: accountID,
            token: currentToken,
            normalizedBaseURL: normalized(baseURL)
        )
        if let existing = boundRefreshTasks[authority] {
            return try await existing.value
        }
        let task = Task<String, Error> { @MainActor in
            defer { boundRefreshTasks[authority] = nil }
            return try await refreshToken(currentToken: currentToken, baseURL: baseURL)
        }
        boundRefreshTasks[authority] = task
        return try await task.value
    }

    private static func refreshToken(currentToken: String, baseURL: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/v1/auth/refresh") else {
            throw AuthenticatedHttpError.invalidURL("/api/v1/auth/refresh")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        ClientVersion.setHeaders(on: &request)

        let (data, http) = try await perform(request)

        guard http.statusCode == 200 else {
            throw AuthenticatedHttpError.unauthorized
        }

        struct RefreshResponse: Codable {
            let access_token: String
        }

        let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return refreshResponse.access_token
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let requestExecutor {
            return try await requestExecutor(request)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticatedHttpError.invalidResponse
        }
        return (data, http)
    }

    // MARK: - Sign Out

    private static func triggerSignOut() {
        RemCredentialStore.backendToken = nil
        onUnauthorized?()
    }

    private static func triggerSignOutIfCurrentAuthority(
        accountID: String,
        authorityTokens: Set<String>
    ) {
        guard VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
            requestAccountID: accountID,
            authorityTokens: authorityTokens,
            currentToken: RemCredentialStore.backendToken
        ) else { return }
        triggerSignOut()
    }
}

// MARK: - Error

enum AuthenticatedHttpError: Error, Equatable, LocalizedError {
    case notAuthenticated
    case unauthorized
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not authenticated — no backend token"
        case .unauthorized:
            "Session expired — please sign in again"
        case .invalidURL(let path):
            "Invalid URL for path: \(path)"
        case .invalidResponse:
            "Invalid server response"
        case .httpError(let statusCode):
            "HTTP error: \(statusCode)"
        }
    }
}
