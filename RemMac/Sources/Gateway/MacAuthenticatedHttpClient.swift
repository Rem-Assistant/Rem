import Foundation
import os

private let log = Logger(subsystem: "app.remclaw.mac", category: "http")

/// Centralized HTTP client that adds JWT authentication to all backend API requests.
///
/// On 401 responses, the client:
/// 1. Attempts a silent token refresh via `/api/v1/auth/refresh`
/// 2. Retries the original request with the new token
/// 3. Commits refresh/sign-out only while the captured account generation is current
///
/// All backend API calls should use this client instead of raw URLSession.
/// Mirrors the iOS `AuthenticatedHttpClient` pattern but uses Mac's `KeychainStore`.
@MainActor
enum MacAuthenticatedHttpClient {

    struct RequestAuthority: @unchecked Sendable, Equatable {
        fileprivate let token: String
        fileprivate let baseURL: String

        init(token: String, baseURL: String) {
            self.token = token
            self.baseURL = baseURL
        }
    }

    static func captureRequestAuthority(expectedBackendURL: String) -> RequestAuthority? {
        guard let authority = currentAuthenticationAuthority?(),
              normalized(authority.backendURL) == normalized(expectedBackendURL)
        else { return nil }
        return RequestAuthority(token: authority.backendToken, baseURL: authority.backendURL)
    }

    // MARK: - Configuration

    /// Hooks installed by MacGatewaySessionManager so refreshes update its main-actor cache and
    /// Keychain as one authority transition. The client never mutates persisted credentials itself.
    nonisolated(unsafe) static var currentAuthenticationAuthority: (@MainActor () -> MacBackendAuthAuthority?)?
    nonisolated(unsafe) static var currentBackendURL: (@MainActor () -> String?)?
    nonisolated(unsafe) static var canPublishResponse: (@MainActor (MacBackendAuthAuthority) -> Bool)?
    nonisolated(unsafe) static var commitRefreshedAuthentication: (@MainActor (MacBackendAuthAuthority, String) -> MacBackendAuthAuthority?)?
    nonisolated(unsafe) static var retireAuthentication: (@MainActor (MacBackendAuthAuthority) -> Void)?

    /// Injectable transport used by deterministic authority tests. Production falls back to
    /// URLSession.shared, while tests can suspend a retry at the exact account-change boundary.
    typealias RequestExecutor = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    nonisolated(unsafe) static var requestExecutor: RequestExecutor?

    /// Concurrent requests only share a refresh when they captured the same URL, generation, and token.
    private static var refreshTasks: [MacBackendAuthAuthority: Task<RefreshedAuthentication, Error>] = [:]

    /// Long-lived account-bound operations deduplicate only with the exact captured token.
    private static var boundRefreshTasks: [String: Task<String, Error>] = [:]

    // X-Client-Version header lives in shared ClientVersion (#226).

    // MARK: - Public API

    /// Performs an authenticated GET request and decodes the response.
    static func get<T: Decodable>(
        _ path: String,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let (data, http) = try await performWithAuth(path: path, method: "GET", body: nil, timeout: timeout)
        guard (200...299).contains(http.statusCode) else {
            throw MacAuthenticatedHttpError.httpError(statusCode: http.statusCode)
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
            throw MacAuthenticatedHttpError.httpError(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func postBoundToAccount<T: Decodable>(
        _ path: String,
        bearerToken: String,
        accountID: String,
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let (data, http) = try await performBoundToAccount(
            path: path,
            method: "POST",
            body: body,
            timeout: timeout,
            bearerToken: bearerToken,
            accountID: accountID
        )
        guard (200...299).contains(http.statusCode) else {
            throw MacAuthenticatedHttpError.httpError(statusCode: http.statusCode)
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

    /// Performs an authenticated request with the exact account authority captured at user intent.
    /// Refresh and response publication remain fenced by the session manager's account generation.
    static func request(
        path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval = 30,
        authority: MacBackendAuthAuthority
    ) async throws -> (Data, HTTPURLResponse) {
        try await performWithAuth(
            path: path,
            method: method,
            body: body,
            timeout: timeout,
            authority: authority
        )
    }

    static func request(
        path: String,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval = 30,
        authority: RequestAuthority
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "\(authority.baseURL)\(path)") else {
            throw MacAuthenticatedHttpError.invalidURL(path)
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

    private static func currentResponseAuthority(
        for captured: MacBackendAuthAuthority
    ) -> MacBackendAuthAuthority? {
        guard let current = currentAuthenticationAuthority?() else { return nil }
        if current == captured { return current }
        guard canPublishResponse?(captured) == true else { return nil }
        return current
    }

    // MARK: - Core

    private static func performWithAuth(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        customHeaders: [String: String]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let authority = currentAuthenticationAuthority?() else {
            throw MacAuthenticatedHttpError.notAuthenticated
        }

        return try await performWithAuth(
            path: path,
            method: method,
            body: body,
            timeout: timeout,
            customHeaders: customHeaders,
            authority: authority
        )
    }

    private static func performWithAuth(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        customHeaders: [String: String]? = nil,
        authority: MacBackendAuthAuthority
    ) async throws -> (Data, HTTPURLResponse) {

        guard let url = URL(string: "\(authority.backendURL)\(path)") else {
            throw MacAuthenticatedHttpError.invalidURL(path)
        }

        // First attempt
        let (data, httpResponse) = try await execute(
            url: url, method: method, token: authority.backendToken,
            body: body, timeout: timeout, customHeaders: customHeaders
        )

        guard let responseAuthority = currentResponseAuthority(for: authority) else {
            throw CancellationError()
        }

        guard httpResponse.statusCode == 401 else {
            return (data, httpResponse)
        }

        // 401 received -- attempt token refresh
        log.info("401 on \(method) \(path) -- attempting token refresh")

        do {
            // A proactive or concurrent reactive refresh may have already replaced this exact
            // credential while the old request was in flight. Reuse that same-account successor
            // instead of refreshing the obsolete token and failing its exact-authority commit.
            let refreshed = if responseAuthority == authority {
                try await refreshCurrentAuthenticationDeduped(authority: authority)
            } else {
                RefreshedAuthentication(
                    token: responseAuthority.backendToken,
                    authority: responseAuthority
                )
            }

            try Task.checkCancellation()
            guard currentAuthenticationAuthority?() == refreshed.authority else {
                throw CancellationError()
            }

            // Retry with new token
            let (retryData, retryResponse) = try await execute(
                url: url, method: method, token: refreshed.token,
                body: body, timeout: timeout, customHeaders: customHeaders
            )

            guard canPublishResponse?(refreshed.authority)
                    ?? (currentAuthenticationAuthority?() == refreshed.authority) else {
                throw CancellationError()
            }

            if retryResponse.statusCode == 401 {
                log.error("retry still 401 after refresh -- signing out")
                retireAuthentication?(refreshed.authority)
                throw MacAuthenticatedHttpError.unauthorized
            }

            return (retryData, retryResponse)
        } catch is CancellationError {
            // A newer sign-in/sign-out retired this request, or persistence of the refreshed
            // credential failed. Neither case authorizes retiring whichever account is current.
            throw CancellationError()
        } catch let error as MacAuthenticatedHttpError where error == .unauthorized {
            retireAuthentication?(authority)
            throw error
        } catch {
            // Refresh itself failed -- sign out
            log.error("token refresh failed: \(error.localizedDescription) -- signing out")
            retireAuthentication?(authority)
            throw MacAuthenticatedHttpError.unauthorized
        }
    }

    private static func performBoundToAccount(
        path: String,
        method: String,
        body: Data?,
        timeout: TimeInterval,
        bearerToken: String,
        accountID: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
            requestAccountID: accountID,
            authorityTokens: [bearerToken],
            currentToken: bearerToken
        ) else {
            throw MacAuthenticatedHttpError.notAuthenticated
        }
        guard let baseURL = currentAuthenticationAuthority?()?.backendURL ?? currentBackendURL?(),
              let url = URL(string: "\(baseURL)\(path)") else {
            throw MacAuthenticatedHttpError.invalidURL(path)
        }

        let (data, response) = try await execute(
            url: url,
            method: method,
            token: bearerToken,
            body: body,
            timeout: timeout
        )
        guard response.statusCode == 401 else { return (data, response) }

        var refreshedToken: String?
        do {
            let latestAuthority = currentAuthenticationAuthority?()
            let mayMutateCurrentAuthentication = VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
                requestAccountID: accountID,
                authorityTokens: [bearerToken],
                currentToken: latestAuthority?.backendToken
            )
            let newToken: String
            let committedAuthority: MacBackendAuthAuthority?
            if mayMutateCurrentAuthentication, let latestAuthority {
                let refreshed = try await refreshCurrentAuthenticationDeduped(authority: latestAuthority)
                newToken = refreshed.token
                committedAuthority = refreshed.authority
            } else {
                newToken = try await refreshBoundTokenDeduped(
                    currentToken: bearerToken,
                    baseURL: baseURL
                )
                committedAuthority = nil
            }
            refreshedToken = newToken

            let (retryData, retryResponse) = try await execute(
                url: url,
                method: method,
                token: newToken,
                body: body,
                timeout: timeout
            )
            if retryResponse.statusCode == 401 {
                if let committedAuthority {
                    retireAuthentication?(committedAuthority)
                } else {
                    retireIfCurrentAccountAuthority(
                        accountID: accountID,
                        authorityTokens: [bearerToken, newToken]
                    )
                }
                throw MacAuthenticatedHttpError.unauthorized
            }
            return (retryData, retryResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MacAuthenticatedHttpError where error == .unauthorized {
            retireIfCurrentAccountAuthority(
                accountID: accountID,
                authorityTokens: Set([bearerToken] + [refreshedToken].compactMap { $0 })
            )
            throw error
        } catch {
            retireIfCurrentAccountAuthority(
                accountID: accountID,
                authorityTokens: Set([bearerToken] + [refreshedToken].compactMap { $0 })
            )
            throw MacAuthenticatedHttpError.unauthorized
        }
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

    private struct RefreshedAuthentication: Sendable {
        let token: String
        let authority: MacBackendAuthAuthority
    }

    /// Deduplicates both the network refresh and authority commit for the exact captured account.
    private static func refreshCurrentAuthenticationDeduped(
        authority: MacBackendAuthAuthority
    ) async throws -> RefreshedAuthentication {
        if let existing = refreshTasks[authority] {
            return try await existing.value
        }
        let task = Task<RefreshedAuthentication, Error> { @MainActor in
            defer { refreshTasks[authority] = nil }
            let token = try await refreshToken(
                currentToken: authority.backendToken,
                baseURL: authority.backendURL
            )
            guard let committedAuthority = commitRefreshedToken(token, for: authority) else {
                throw CancellationError()
            }
            return RefreshedAuthentication(token: token, authority: committedAuthority)
        }
        refreshTasks[authority] = task
        return try await task.value
    }

    /// Shared proactive/reactive refresh entry point. The exact captured authority is the dedupe
    /// key, so concurrent expiry checks and reactive 401 handling join one network + commit flight.
    static func refreshAuthentication(
        for authority: MacBackendAuthAuthority
    ) async throws -> MacBackendAuthAuthority {
        try await refreshCurrentAuthenticationDeduped(authority: authority).authority
    }

    /// Production seam shared by the in-flight refresh path and deterministic authority tests.
    static func commitRefreshedToken(
        _ token: String,
        for authority: MacBackendAuthAuthority
    ) -> MacBackendAuthAuthority? {
        commitRefreshedAuthentication?(authority, token)
    }

    private static func refreshBoundTokenDeduped(
        currentToken: String,
        baseURL: String
    ) async throws -> String {
        let taskKey = "\(baseURL)|\(currentToken)"
        if let existing = boundRefreshTasks[taskKey] {
            return try await existing.value
        }
        let task = Task<String, Error> { @MainActor in
            defer { boundRefreshTasks[taskKey] = nil }
            return try await refreshToken(currentToken: currentToken, baseURL: baseURL)
        }
        boundRefreshTasks[taskKey] = task
        return try await task.value
    }

    private static func refreshToken(currentToken: String, baseURL: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/v1/auth/refresh") else {
            throw MacAuthenticatedHttpError.invalidURL("/api/v1/auth/refresh")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        ClientVersion.setHeaders(on: &request)

        let (data, http) = try await perform(request)

        guard http.statusCode == 200 else {
            throw MacAuthenticatedHttpError.unauthorized
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
            throw MacAuthenticatedHttpError.invalidResponse
        }
        return (data, http)
    }

    // MARK: - Sign Out

    private static func retireIfCurrentAccountAuthority(
        accountID: String,
        authorityTokens: Set<String>
    ) {
        guard let currentAuthority = currentAuthenticationAuthority?() else { return }
        guard VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
            requestAccountID: accountID,
            authorityTokens: authorityTokens,
            currentToken: currentAuthority.backendToken
        ) else { return }
        retireAuthentication?(currentAuthority)
    }
}

// MARK: - Error

enum MacAuthenticatedHttpError: Error, Equatable, LocalizedError {
    case notAuthenticated
    case unauthorized
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not authenticated -- no backend token"
        case .unauthorized:
            "Session expired -- please sign in again"
        case .invalidURL(let path):
            "Invalid URL for path: \(path)"
        case .invalidResponse:
            "Invalid server response"
        case .httpError(let statusCode):
            "HTTP error: \(statusCode)"
        }
    }
}
