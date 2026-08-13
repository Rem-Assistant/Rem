import Foundation
import Testing
@testable import RemClawMac

@Suite("Mac root authentication presentation")
struct MacRootAuthenticationPresentationTests {
    @Test("Cold launch stays on the loading shell until Keychain state resolves")
    func coldLaunchDoesNotFlashSignIn() {
        #expect(MacRootAuthenticationPresentation.resolve(
            isLoaded: false,
            isAuthenticated: false
        ) == .loading)
        #expect(MacRootAuthenticationPresentation.resolve(
            isLoaded: true,
            isAuthenticated: false
        ) == .signedOut)
        #expect(MacRootAuthenticationPresentation.resolve(
            isLoaded: true,
            isAuthenticated: true
        ) == .authenticated)
    }
}

@Suite("Mac usage request authority")
struct MacUsageRequestAuthorityTests {
    @Test("An old refresh cannot overwrite a signed-out or newly signed-in account")
    func refreshAuthorityCannotCrossAccounts() {
        let previousAccount = MacBackendAuthAuthority(
            generation: 7,
            backendURL: "https://api.example.test",
            backendToken: "old-account-token"
        )

        #expect(!previousAccount.isCurrent(generation: 8, backendURL: nil, backendToken: nil))
        #expect(!previousAccount.isCurrent(
            generation: 8,
            backendURL: "https://api.example.test",
            backendToken: "new-account-token"
        ))
        #expect(previousAccount.isCurrent(
            generation: 7,
            backendURL: "https://api.example.test",
            backendToken: "old-account-token"
        ))
    }

    @Test("A delayed response cannot commit after sign-out")
    func signOutInvalidatesDelayedResponse() {
        var tracker = MacUsageRequestAuthorityTracker()
        let previousAccount = tracker.begin(
            backendURL: "https://api.example.test",
            backendToken: "old-account-token"
        )

        tracker.invalidate()

        #expect(!tracker.canCommit(
            previousAccount,
            currentBackendURL: nil,
            currentBackendToken: nil
        ))
    }

    @Test("A delayed response cannot overwrite a newly signed-in account")
    func accountChangeInvalidatesDelayedResponse() {
        var tracker = MacUsageRequestAuthorityTracker()
        let previousAccount = tracker.begin(
            backendURL: "https://api.example.test",
            backendToken: "old-account-token"
        )
        tracker.invalidate()
        let currentAccount = tracker.begin(
            backendURL: "https://api.example.test",
            backendToken: "new-account-token"
        )

        #expect(!tracker.canCommit(
            previousAccount,
            currentBackendURL: currentAccount.backendURL,
            currentBackendToken: currentAccount.backendToken
        ))
        #expect(tracker.canCommit(
            currentAccount,
            currentBackendURL: currentAccount.backendURL,
            currentBackendToken: currentAccount.backendToken
        ))
    }

    @Test("A newer retry supersedes an older request for the same account")
    func retrySupersedesOlderRequest() {
        var tracker = MacUsageRequestAuthorityTracker()
        let first = tracker.begin(
            backendURL: "https://api.example.test",
            backendToken: "same-account-token"
        )
        let retry = tracker.begin(
            backendURL: "https://api.example.test",
            backendToken: "same-account-token"
        )

        #expect(!tracker.canCommit(
            first,
            currentBackendURL: retry.backendURL,
            currentBackendToken: retry.backendToken
        ))
        #expect(tracker.canCommit(
            retry,
            currentBackendURL: retry.backendURL,
            currentBackendToken: retry.backendToken
        ))
    }

    @Test("A newer invocation stays authoritative when an older token refresh resumes last")
    func invocationOrderSurvivesSuspension() {
        var tracker = MacUsageSummaryInvocationTracker()
        let older = tracker.begin()
        let newer = tracker.begin()

        #expect(!tracker.isCurrent(older))
        #expect(tracker.isCurrent(newer))

        tracker.invalidate()
        #expect(!tracker.isCurrent(newer))
    }
}

@Suite("Mac authenticated HTTP refresh authority", .serialized)
@MainActor
struct MacAuthenticatedHttpRefreshAuthorityTests {
    @Test("An older login response cannot replace a newer completed sign-in")
    func olderLoginCannotOverwriteNewerAccount() async throws {
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        let originalCachedProfile = UserDefaults.standard.data(forKey: "cached_user_profile")
        defer {
            UserDefaults.standard.set(originalBackendURL, forKey: "backend_url")
            if let originalCachedProfile {
                UserDefaults.standard.set(originalCachedProfile, forKey: "cached_user_profile")
            } else {
                UserDefaults.standard.removeObject(forKey: "cached_user_profile")
            }
        }

        let probe = DelayedLoginRequestExecutor()
        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { nil },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true },
            executeLoginRequest: { request in try await probe.execute(request) }
        )
        manager.backendURL = "https://api.example.test"
        guard let attemptA = manager.beginSignInAttempt() else {
            Issue.record("Expected account A sign-in authority")
            return
        }
        let accountA = Task {
            try await manager.authenticateWithBackend(
                provider: "apple",
                idToken: "account-a",
                attempt: attemptA
            )
        }
        await probe.waitUntilStarted(idToken: "account-a")

        guard let attemptB = manager.beginSignInAttempt() else {
            Issue.record("Expected account B sign-in authority")
            return
        }
        let accountB = Task {
            try await manager.authenticateWithBackend(
                provider: "google",
                idToken: "account-b",
                attempt: attemptB
            )
        }
        await probe.waitUntilStarted(idToken: "account-b")

        probe.complete(idToken: "account-b")
        _ = try await accountB.value
        probe.complete(idToken: "account-a")

        do {
            _ = try await accountA.value
            Issue.record("Older account A login unexpectedly published")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(manager.backendToken == "token-account-b")
        #expect(manager.userProfile?.id == "account-b")
    }

    @Test("Failed gateway setup clears the authenticated profile after secure token deletion")
    func failedGatewaySetupClearsProfile() throws {
        let originalCachedProfile = UserDefaults.standard.data(forKey: "cached_user_profile")
        defer {
            if let originalCachedProfile {
                UserDefaults.standard.set(originalCachedProfile, forKey: "cached_user_profile")
            } else {
                UserDefaults.standard.removeObject(forKey: "cached_user_profile")
            }
        }

        let profile = UserProfile(
            id: "failed-setup-account",
            email: "person@example.test",
            full_name: "Example Person",
            first_name: "Example",
            last_name: "Person",
            profile_picture_url: nil,
            locale: "en"
        )
        UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: "cached_user_profile")
        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { "authenticated-token" },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true }
        )
        manager.restoreCachedProfile()
        #expect(manager.userProfile?.id == profile.id)
        guard let authority = manager.captureBackendAuthAuthority() else {
            Issue.record("Expected authenticated cleanup authority")
            return
        }

        #expect(manager.clearBackendAuthenticationAfterFailedSignIn(ifCurrent: authority) == nil)
        #expect(manager.userProfile == nil)
        #expect(UserDefaults.standard.data(forKey: "cached_user_profile") == nil)
    }

    @Test("An older failed setup cannot clear a replacement account")
    func failedSetupCleanupCannotCrossAccounts() throws {
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        defer { UserDefaults.standard.set(originalBackendURL, forKey: "backend_url") }

        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { "account-a-token" },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true }
        )
        manager.backendURL = "https://api.example.test"
        _ = manager.backendToken
        guard let accountA = manager.captureBackendAuthAuthority() else {
            Issue.record("Expected account A authority")
            return
        }

        try manager.persistBackendToken("account-b-token")
        #expect(manager.clearBackendAuthenticationAfterFailedSignIn(ifCurrent: accountA) == nil)
        #expect(manager.backendToken == "account-b-token")
    }

    @Test("The production client cannot commit account A refresh after account B signs in")
    func delayedRefreshCannotOverwriteReplacementAccount() {
        let accountA = MacBackendAuthAuthority(
            generation: 11,
            backendURL: "https://api.example.test",
            backendToken: "account-a-token"
        )
        var currentAuthority = accountA
        var cachedToken = accountA.backendToken
        var persistedToken = accountA.backendToken

        let originalCommit = MacAuthenticatedHttpClient.commitRefreshedAuthentication
        defer {
            MacAuthenticatedHttpClient.commitRefreshedAuthentication = originalCommit
        }
        MacAuthenticatedHttpClient.commitRefreshedAuthentication = { captured, refreshedToken in
            guard captured == currentAuthority else { return nil }
            currentAuthority = MacBackendAuthAuthority(
                generation: currentAuthority.generation + 1,
                backendURL: currentAuthority.backendURL,
                backendToken: refreshedToken
            )
            cachedToken = refreshedToken
            persistedToken = refreshedToken
            return currentAuthority
        }

        currentAuthority = MacBackendAuthAuthority(
            generation: 12,
            backendURL: "https://api.example.test",
            backendToken: "account-b-token"
        )
        cachedToken = currentAuthority.backendToken
        persistedToken = currentAuthority.backendToken

        let committed = MacAuthenticatedHttpClient.commitRefreshedToken(
            "refreshed-account-a-token",
            for: accountA
        )

        #expect(committed == nil)
        #expect(currentAuthority.backendToken == "account-b-token")
        #expect(cachedToken == "account-b-token")
        #expect(persistedToken == "account-b-token")
    }

    @Test("A successful retry cannot return after a replacement account signs in")
    func delayedRetryCannotReturnAcrossAccounts() async {
        let accountA = MacBackendAuthAuthority(
            generation: 21,
            backendURL: "https://api.example.test",
            backendToken: "account-a-token"
        )
        var currentAuthority: MacBackendAuthAuthority? = accountA
        let probe = DelayedRetryRequestExecutor()

        let originalCurrent = MacAuthenticatedHttpClient.currentAuthenticationAuthority
        let originalCanPublish = MacAuthenticatedHttpClient.canPublishResponse
        let originalCommit = MacAuthenticatedHttpClient.commitRefreshedAuthentication
        let originalRetire = MacAuthenticatedHttpClient.retireAuthentication
        let originalExecutor = MacAuthenticatedHttpClient.requestExecutor
        defer {
            MacAuthenticatedHttpClient.currentAuthenticationAuthority = originalCurrent
            MacAuthenticatedHttpClient.canPublishResponse = originalCanPublish
            MacAuthenticatedHttpClient.commitRefreshedAuthentication = originalCommit
            MacAuthenticatedHttpClient.retireAuthentication = originalRetire
            MacAuthenticatedHttpClient.requestExecutor = originalExecutor
        }

        MacAuthenticatedHttpClient.currentAuthenticationAuthority = { currentAuthority }
        MacAuthenticatedHttpClient.canPublishResponse = { authority in
            authority == currentAuthority
        }
        MacAuthenticatedHttpClient.commitRefreshedAuthentication = { captured, token in
            guard captured == currentAuthority else { return nil }
            let refreshed = MacBackendAuthAuthority(
                generation: captured.generation + 1,
                backendURL: captured.backendURL,
                backendToken: token
            )
            currentAuthority = refreshed
            return refreshed
        }
        MacAuthenticatedHttpClient.retireAuthentication = { authority in
            guard authority == currentAuthority else { return }
            currentAuthority = nil
        }
        MacAuthenticatedHttpClient.requestExecutor = { request in
            try await probe.execute(request)
        }

        let requestTask = Task {
            try await MacAuthenticatedHttpClient.request(path: "/resource", method: "GET")
        }
        await probe.waitUntilRetryStarted()
        currentAuthority = nil
        currentAuthority = MacBackendAuthAuthority(
            generation: 23,
            backendURL: accountA.backendURL,
            backendToken: "account-b-token"
        )
        probe.completeRetry()

        do {
            _ = try await requestTask.value
            Issue.record("Retired account response unexpectedly returned")
        } catch is CancellationError {
            // Expected: the response cannot escape its retired authority.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(currentAuthority?.backendToken == "account-b-token")
    }

    @Test("Cancellation after refresh prevents the authenticated retry from dispatching")
    func cancellationBeforeRetryPreventsDispatch() async {
        let account = MacBackendAuthAuthority(
            generation: 31,
            backendURL: "https://api.example.test",
            backendToken: "account-token"
        )
        var currentAuthority: MacBackendAuthAuthority? = account
        let probe = CancellationBeforeRetryExecutor()
        let hooks = MacHTTPHookSnapshot()
        defer { hooks.restore() }

        MacAuthenticatedHttpClient.currentAuthenticationAuthority = { currentAuthority }
        MacAuthenticatedHttpClient.canPublishResponse = { $0 == currentAuthority }
        MacAuthenticatedHttpClient.commitRefreshedAuthentication = { captured, token in
            guard captured == currentAuthority else { return nil }
            let refreshed = MacBackendAuthAuthority(
                generation: captured.generation + 1,
                accountGeneration: captured.accountGeneration,
                backendURL: captured.backendURL,
                backendToken: token
            )
            currentAuthority = refreshed
            return refreshed
        }
        MacAuthenticatedHttpClient.retireAuthentication = { _ in }
        MacAuthenticatedHttpClient.requestExecutor = { request in
            try await probe.execute(request)
        }

        let requestTask = Task {
            try await MacAuthenticatedHttpClient.request(path: "/resource", method: "POST")
        }
        await probe.waitUntilRefreshStarted()
        requestTask.cancel()
        probe.completeRefresh()

        do {
            _ = try await requestTask.value
            Issue.record("Cancelled request unexpectedly dispatched its retry")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(probe.resourceCallCount == 1)
    }

    @Test("Concurrent proactive refreshes join one exact-authority flight")
    func concurrentProactiveRefreshesDeduplicate() async throws {
        let hooks = MacHTTPHookSnapshot()
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        defer {
            hooks.restore()
            UserDefaults.standard.set(originalBackendURL, forKey: "backend_url")
        }
        let refreshedToken = makeJWT(expiration: Date().addingTimeInterval(3_600))
        let probe = DelayedRefreshRequestExecutor(refreshedToken: refreshedToken)
        MacAuthenticatedHttpClient.requestExecutor = { request in
            try await probe.execute(request)
        }

        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { "expired-token" },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true }
        )
        manager.backendURL = "https://api.example.test"
        _ = manager.backendToken

        let first = Task { try await manager.refreshAuthIfNeeded() }
        await probe.waitUntilStarted()
        let second = Task { try await manager.refreshAuthIfNeeded() }
        await Task.yield()
        await Task.yield()
        probe.complete()

        try await first.value
        try await second.value
        #expect(probe.callCount == 1)
        #expect(manager.backendToken == refreshedToken)
    }

    @Test("A same-account refresh does not discard a delayed successful mutation")
    func sameAccountRefreshPreservesSuccessfulMutationResponse() async throws {
        let hooks = MacHTTPHookSnapshot()
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        defer {
            hooks.restore()
            UserDefaults.standard.set(originalBackendURL, forKey: "backend_url")
        }
        let expiringToken = makeJWT(expiration: Date().addingTimeInterval(30))
        let refreshedToken = makeJWT(expiration: Date().addingTimeInterval(3_600))
        let probe = DelayedSuccessfulMutationExecutor(refreshedToken: refreshedToken)
        MacAuthenticatedHttpClient.requestExecutor = { request in
            try await probe.execute(request)
        }

        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { expiringToken },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true }
        )
        manager.backendURL = "https://api.example.test"
        _ = manager.backendToken

        let mutation = Task {
            try await MacAuthenticatedHttpClient.request(
                path: "/api/v1/tasks/task-1",
                method: "PATCH",
                body: Data("{}".utf8)
            )
        }
        await probe.waitUntilMutationStarted()
        try await manager.refreshAuthIfNeeded()
        probe.completeMutation()

        let (_, response) = try await mutation.value
        #expect(response.statusCode == 200)
        #expect(manager.backendToken == refreshedToken)
    }

    @Test("A delayed old-token 401 reuses the current same-account refresh")
    func delayedUnauthorizedReusesCurrentSameAccountAuthority() async throws {
        let hooks = MacHTTPHookSnapshot()
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        defer {
            hooks.restore()
            UserDefaults.standard.set(originalBackendURL, forKey: "backend_url")
        }
        let expiringToken = makeJWT(expiration: Date().addingTimeInterval(30))
        let refreshedToken = makeJWT(expiration: Date().addingTimeInterval(3_600))
        let probe = DelayedOldUnauthorizedExecutor(refreshedToken: refreshedToken)
        MacAuthenticatedHttpClient.requestExecutor = { request in
            try await probe.execute(request)
        }

        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { expiringToken },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true }
        )
        manager.backendURL = "https://api.example.test"
        _ = manager.backendToken

        let request = Task {
            try await MacAuthenticatedHttpClient.request(path: "/resource", method: "GET")
        }
        await probe.waitUntilOldRequestStarted()
        try await manager.refreshAuthIfNeeded()
        probe.completeOldRequestWithUnauthorized()

        let (_, response) = try await request.value
        #expect(response.statusCode == 200)
        #expect(probe.refreshCallCount == 1)
        #expect(probe.resourceAuthorizations == [
            "Bearer \(expiringToken)",
            "Bearer \(refreshedToken)",
        ])
    }

    @Test("A delayed profile cannot publish after sign-out and account replacement")
    func delayedProfileCannotOverwriteReplacementAccount() async throws {
        let hooks = MacHTTPHookSnapshot()
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        let originalCachedProfile = UserDefaults.standard.data(forKey: "cached_user_profile")
        defer {
            hooks.restore()
            UserDefaults.standard.set(originalBackendURL, forKey: "backend_url")
            UserDefaults.standard.set(originalCachedProfile, forKey: "cached_user_profile")
        }
        UserDefaults.standard.removeObject(forKey: "cached_user_profile")

        let accountAToken = makeJWT(expiration: Date().addingTimeInterval(3_600), subject: "account-a")
        let accountBToken = makeJWT(expiration: Date().addingTimeInterval(3_600), subject: "account-b")
        let probe = DelayedProfileRequestExecutor()
        MacAuthenticatedHttpClient.requestExecutor = { request in
            try await probe.execute(request)
        }

        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { accountAToken },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true }
        )
        manager.backendURL = "https://api.example.test"
        _ = manager.backendToken

        let profileRequest = Task { await manager.fetchUserProfile() }
        await probe.waitUntilStarted()
        #expect(manager.signOutWithRecovery() == nil)
        manager.backendURL = "https://api.example.test"
        try manager.persistBackendToken(accountBToken)
        probe.complete()
        await profileRequest.value

        #expect(manager.userProfile == nil)
        #expect(UserDefaults.standard.data(forKey: "cached_user_profile") == nil)
        #expect(manager.backendToken == accountBToken)
    }

    @Test("Failed Keychain save and delete leave the prior authority coherent")
    func keychainFailuresDoNotPublishCacheTransitions() async throws {
        let hooks = MacHTTPHookSnapshot()
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        defer {
            hooks.restore()
            UserDefaults.standard.set(originalBackendURL, forKey: "backend_url")
        }
        let saveFailure = MacGatewaySessionManager(
            loadPersistedBackendToken: { "persisted-account-token" },
            savePersistedBackendToken: { _ in false },
            deletePersistedBackendToken: { true }
        )
        saveFailure.backendURL = "https://api.example.test"
        _ = saveFailure.backendToken
        do {
            try saveFailure.persistBackendToken("replacement-token")
            Issue.record("Expected secure save failure")
        } catch is MacBackendCredentialPersistenceError {
            // Expected.
        }
        #expect(saveFailure.backendToken == "persisted-account-token")
        #expect(saveFailure.authenticationRecoveryError?.contains("securely save") == true)

        MacAuthenticatedHttpClient.requestExecutor = { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                return response(
                    statusCode: 200,
                    data: Data("{\"access_token\":\"replacement-token\"}".utf8),
                    request: request
                )
            }
            return response(statusCode: 401, data: Data(), request: request)
        }
        do {
            _ = try await MacAuthenticatedHttpClient.request(path: "/resource", method: "GET")
            Issue.record("Expected refresh persistence failure")
        } catch is CancellationError {
            // Expected: persistence failure stays recoverable and does not retire the old cache.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(saveFailure.backendToken == "persisted-account-token")
        #expect(saveFailure.isAuthenticated)

        let deleteFailure = MacGatewaySessionManager(
            loadPersistedBackendToken: { "persisted-account-token" },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { false }
        )
        _ = deleteFailure.backendToken
        let signOutError = deleteFailure.signOutWithRecovery()
        #expect(signOutError?.contains("securely sign out") == true)
        #expect(deleteFailure.backendToken == "persisted-account-token")
        #expect(deleteFailure.isAuthenticated)
    }

    @Test("A failed entry refresh exposes stale cached billing instead of current plan")
    func cachedSummaryBecomesStaleWhenRefreshFails() async throws {
        let hooks = MacHTTPHookSnapshot()
        let originalBackendURL = UserDefaults.standard.string(forKey: "backend_url")
        defer {
            hooks.restore()
            UserDefaults.standard.set(originalBackendURL, forKey: "backend_url")
        }
        let responses = UsageResponseExecutor()
        let manager = MacGatewaySessionManager(
            loadPersistedBackendToken: { makeJWT(expiration: Date().addingTimeInterval(3_600)) },
            savePersistedBackendToken: { _ in true },
            deletePersistedBackendToken: { true },
            executeUsageRequest: { request in try await responses.execute(request) }
        )
        manager.backendURL = "https://api.example.test"
        responses.enqueue(summary: makeSummary(plan: "free"))
        await manager.fetchUsageSummary()
        #expect(manager.usageSummary?.plan == "free")
        #expect(!manager.usageSummaryIsStale)

        responses.enqueueFailure(statusCode: 503)
        await manager.fetchUsageSummary()
        #expect(manager.usageSummary?.plan == "free")
        #expect(manager.usageSummaryIsStale)
        #expect(manager.usageLoadError != nil)
        #expect(!manager.isLoadingUsage)
    }
}

@MainActor
private struct MacHTTPHookSnapshot {
    let current = MacAuthenticatedHttpClient.currentAuthenticationAuthority
    let currentURL = MacAuthenticatedHttpClient.currentBackendURL
    let canPublish = MacAuthenticatedHttpClient.canPublishResponse
    let commit = MacAuthenticatedHttpClient.commitRefreshedAuthentication
    let retire = MacAuthenticatedHttpClient.retireAuthentication
    let executor = MacAuthenticatedHttpClient.requestExecutor

    func restore() {
        MacAuthenticatedHttpClient.currentAuthenticationAuthority = current
        MacAuthenticatedHttpClient.currentBackendURL = currentURL
        MacAuthenticatedHttpClient.canPublishResponse = canPublish
        MacAuthenticatedHttpClient.commitRefreshedAuthentication = commit
        MacAuthenticatedHttpClient.retireAuthentication = retire
        MacAuthenticatedHttpClient.requestExecutor = executor
    }
}

@MainActor
private final class DelayedSuccessfulMutationExecutor {
    private let refreshedToken: String
    private var mutationContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?

    init(refreshedToken: String) {
        self.refreshedToken = refreshedToken
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/api/v1/auth/refresh" {
            let data = try! JSONSerialization.data(withJSONObject: ["access_token": refreshedToken])
            return response(statusCode: 200, data: data, request: request)
        }
        return await withCheckedContinuation { mutationContinuation = $0 }
    }

    func waitUntilMutationStarted() async {
        while mutationContinuation == nil { await Task.yield() }
    }

    func completeMutation() {
        guard let mutationContinuation else { return }
        self.mutationContinuation = nil
        mutationContinuation.resume(returning: response(
            statusCode: 200,
            data: Data("{\"id\":\"task-1\"}".utf8),
            requestURL: URL(string: "https://api.example.test/api/v1/tasks/task-1")!
        ))
    }
}

@MainActor
private final class DelayedOldUnauthorizedExecutor {
    private let refreshedToken: String
    private var oldRequestContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private(set) var refreshCallCount = 0
    private(set) var resourceAuthorizations: [String] = []

    init(refreshedToken: String) {
        self.refreshedToken = refreshedToken
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/api/v1/auth/refresh" {
            refreshCallCount += 1
            let data = try! JSONSerialization.data(withJSONObject: ["access_token": refreshedToken])
            return response(statusCode: 200, data: data, request: request)
        }

        resourceAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        if resourceAuthorizations.count == 1 {
            return await withCheckedContinuation { oldRequestContinuation = $0 }
        }
        return response(statusCode: 200, data: Data("{\"ok\":true}".utf8), request: request)
    }

    func waitUntilOldRequestStarted() async {
        while oldRequestContinuation == nil { await Task.yield() }
    }

    func completeOldRequestWithUnauthorized() {
        guard let oldRequestContinuation else { return }
        self.oldRequestContinuation = nil
        oldRequestContinuation.resume(returning: response(
            statusCode: 401,
            data: Data(),
            requestURL: URL(string: "https://api.example.test/resource")!
        ))
    }
}

@MainActor
private final class DelayedProfileRequestExecutor {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func complete() {
        guard let continuation else { return }
        self.continuation = nil
        let profile = UserProfile(
            id: "account-a",
            email: "account-a@example.test",
            full_name: "Account A",
            first_name: nil,
            last_name: nil,
            profile_picture_url: nil,
            locale: nil
        )
        continuation.resume(returning: response(
            statusCode: 200,
            data: try! JSONEncoder().encode(profile),
            requestURL: URL(string: "https://api.example.test/api/v1/me")!
        ))
    }
}

@MainActor
private final class DelayedRetryRequestExecutor {
    private var resourceCalls = 0
    private var retryContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        if path == "/api/v1/auth/refresh" {
            return response(statusCode: 200, data: Data("{\"access_token\":\"account-a-refreshed\"}".utf8), request: request)
        }
        resourceCalls += 1
        if resourceCalls == 1 {
            return response(statusCode: 401, data: Data(), request: request)
        }
        return await withCheckedContinuation { retryContinuation = $0 }
    }

    func waitUntilRetryStarted() async {
        while retryContinuation == nil { await Task.yield() }
    }

    func completeRetry() {
        guard let retryContinuation else { return }
        self.retryContinuation = nil
        retryContinuation.resume(returning: response(
            statusCode: 200,
            data: Data("{\"ok\":true}".utf8),
            requestURL: URL(string: "https://api.example.test/resource")!
        ))
    }
}

@MainActor
private final class CancellationBeforeRetryExecutor {
    private var refreshContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private(set) var resourceCallCount = 0

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/api/v1/auth/refresh" {
            return await withCheckedContinuation { refreshContinuation = $0 }
        }
        resourceCallCount += 1
        return response(statusCode: 401, data: Data(), request: request)
    }

    func waitUntilRefreshStarted() async {
        while refreshContinuation == nil { await Task.yield() }
    }

    func completeRefresh() {
        guard let refreshContinuation else { return }
        self.refreshContinuation = nil
        refreshContinuation.resume(returning: response(
            statusCode: 200,
            data: Data("{\"access_token\":\"account-refreshed\"}".utf8),
            requestURL: URL(string: "https://api.example.test/api/v1/auth/refresh")!
        ))
    }
}

@MainActor
private final class DelayedLoginRequestExecutor {
    private var continuations: [String: CheckedContinuation<(Data, HTTPURLResponse), Never>] = [:]

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
        let idToken = body["id_token"] as! String
        return await withCheckedContinuation { continuations[idToken] = $0 }
    }

    func waitUntilStarted(idToken: String) async {
        while continuations[idToken] == nil { await Task.yield() }
    }

    func complete(idToken: String) {
        guard let continuation = continuations.removeValue(forKey: idToken) else { return }
        let user = UserProfile(
            id: idToken,
            email: "\(idToken)@example.test",
            full_name: idToken,
            first_name: nil,
            last_name: nil,
            profile_picture_url: nil,
            locale: "en"
        )
        let payload: [String: Any] = [
            "access_token": "token-\(idToken)",
            "user": try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(user)),
        ]
        continuation.resume(returning: response(
            statusCode: 200,
            data: try! JSONSerialization.data(withJSONObject: payload),
            requestURL: URL(string: "https://api.example.test/api/v1/auth/login")!
        ))
    }
}

@MainActor
private final class DelayedRefreshRequestExecutor {
    let refreshedToken: String
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?

    init(refreshedToken: String) {
        self.refreshedToken = refreshedToken
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func complete() {
        guard let continuation else { return }
        self.continuation = nil
        let data = try! JSONSerialization.data(withJSONObject: ["access_token": refreshedToken])
        continuation.resume(returning: response(
            statusCode: 200,
            data: data,
            requestURL: URL(string: "https://api.example.test/api/v1/auth/refresh")!
        ))
    }
}

@MainActor
private final class UsageResponseExecutor {
    private var queued: [(Data, Int)] = []

    func enqueue(summary: UsageSummary) {
        queued.append((try! JSONEncoder().encode(summary), 200))
    }

    func enqueueFailure(statusCode: Int) {
        queued.append((Data(), statusCode))
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next = queued.removeFirst()
        return response(statusCode: next.1, data: next.0, request: request)
    }
}

private func makeJWT(expiration: Date, subject: String? = nil) -> String {
    var claims: [String: Any] = ["exp": expiration.timeIntervalSince1970]
    claims["sub"] = subject
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

private func makeSummary(plan: String) -> UsageSummary {
    UsageSummary(
        plan: plan,
        status: "active",
        limits: PlanLimits(requestsPerDay: 20, requestsPerMonth: 200),
        usage: UsageStats(day: 2, month: 12),
        remaining: RemainingQuota(day: 18, month: 188)
    )
}

private func response(
    statusCode: Int,
    data: Data,
    request: URLRequest
) -> (Data, HTTPURLResponse) {
    response(statusCode: statusCode, data: data, requestURL: request.url!)
}

private func response(
    statusCode: Int,
    data: Data,
    requestURL: URL
) -> (Data, HTTPURLResponse) {
    (data, HTTPURLResponse(
        url: requestURL,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!)
}
