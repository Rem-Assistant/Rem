import Foundation
import os
import AppKit
import AuthenticationServices
import CryptoKit
import OpenClawKit
import OpenClawProtocol

enum MacGatewaySuggestionScopeIdentity {
    static func resolve(
        activeLocalURL: String?,
        storedGatewayURL: String?,
        provider: GatewayProvider?
    ) -> String {
        let isLocal = activeLocalURL != nil || provider == .local
        let providerID = isLocal ? GatewayProvider.local.rawValue : (provider?.rawValue ?? "unknown")
        let url = activeLocalURL ?? storedGatewayURL ?? ""
        return "\(providerID)|\(url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }
}

struct MacUsageRequestAuthority: Equatable {
    let generation: UInt64
    let backendURL: String
    let backendToken: String
}

struct MacUsageRequestAuthorityTracker {
    private(set) var generation: UInt64 = 0

    mutating func begin(backendURL: String, backendToken: String) -> MacUsageRequestAuthority {
        generation &+= 1
        return MacUsageRequestAuthority(
            generation: generation,
            backendURL: backendURL,
            backendToken: backendToken
        )
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func canCommit(
        _ authority: MacUsageRequestAuthority,
        currentBackendURL: String?,
        currentBackendToken: String?
    ) -> Bool {
        authority.generation == generation
            && authority.backendURL == currentBackendURL
            && authority.backendToken == currentBackendToken
    }
}

/// Orders full usage-summary invocations across suspension points such as token refresh.
/// The request authority above cannot do this alone because it is intentionally captured
/// only after the request's final backend URL and token are known.
struct MacUsageSummaryInvocationTracker {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ ticket: UInt64) -> Bool {
        ticket == generation
    }
}

struct MacSignInAttemptAuthority: Equatable, Sendable {
    let generation: UInt64
    let backendURL: String
}

struct MacSignInAttemptAuthorityTracker {
    private(set) var generation: UInt64 = 0

    mutating func begin(backendURL: String) -> MacSignInAttemptAuthority {
        generation &+= 1
        return MacSignInAttemptAuthority(generation: generation, backendURL: backendURL)
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ authority: MacSignInAttemptAuthority, backendURL: String?) -> Bool {
        authority.generation == generation && authority.backendURL == backendURL
    }
}

struct MacBackendAuthAuthority: Hashable, Sendable {
    let generation: UInt64
    let accountGeneration: UInt64
    let backendURL: String
    let backendToken: String

    init(
        generation: UInt64,
        accountGeneration: UInt64? = nil,
        backendURL: String,
        backendToken: String
    ) {
        self.generation = generation
        self.accountGeneration = accountGeneration ?? generation
        self.backendURL = backendURL
        self.backendToken = backendToken
    }

    func isCurrent(
        generation currentGeneration: UInt64,
        backendURL currentURL: String?,
        backendToken currentToken: String?
    ) -> Bool {
        generation == currentGeneration
            && backendURL == currentURL
            && backendToken == currentToken
    }
}

private let log = Logger(subsystem: "app.remclaw.mac", category: "gateway")

/// Observable session manager for Rem for Mac.
/// Manages dual WebSocket sessions (node + operator) and provides
/// state for the SwiftUI environment.
@MainActor @Observable
final class MacGatewaySessionManager {
    typealias UsageRequestExecutor = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias LoginRequestExecutor = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    // MARK: - Published state

    private(set) var connectionState: MacConnectionState = .disconnected
    private(set) var gatewayHostDisplay: String?

    /// Deploy progress state for UI display.
    private(set) var deployPhase: MacDeployPhase = .idle

    /// True when the operator session (chat/skills) is connected.
    private(set) var operatorReady: Bool = false
    /// Monotonic identity for the concrete operator socket/auth context serving RPCs.
    private(set) var operatorSessionGeneration: UInt64 = 0

    /// Per-leg/process health surfaced to shared views.
    private(set) var sessionHealth = GatewaySessionHealthSnapshot(
        operatorSessionState: .disconnected,
        nodeSessionState: .disconnected,
        gatewayProcessState: .unknown,
        manualRecoveryState: .none,
        recoveryHints: [],
        detail: nil
    )

    /// Bumped when the gateway sends a skills.snapshot.changed event.
    private(set) var skillsSnapshotVersion: Int = 0

    /// Paired devices from the gateway (for Paired Devices UI).
    private(set) var linkedDevices: [MacLinkedDevice] = []

    /// True while a linked-devices fetch is in progress.
    private(set) var isLoadingLinkedDevices: Bool = false

    /// Devices awaiting pairing approval (for Pending Devices UI).
    private(set) var pendingDevices: [PendingDevice] = []

    /// True while a pending-devices fetch is in progress.
    private(set) var isLoadingPendingDevices: Bool = false

    /// Error message from the last approve/decline action.
    var pendingDeviceError: String?

    /// Last connection error detail shown in technical disclosures.
    private(set) var lastConnectionDetail: String?

    // MARK: - User Profile

    /// User profile fetched from the backend.
    private(set) var userProfile: UserProfile?

    /// Backend authentication is backed by Keychain. Keep a main-actor cache
    /// so SwiftUI body evaluation never synchronously waits on Security APIs.
    private var cachedBackendToken: String?
    private(set) var isAuthenticationStateLoaded = false
    private var backendAuthGeneration: UInt64 = 0
    private var backendAccountGeneration: UInt64 = 0
    private let loadPersistedBackendToken: @Sendable () -> String?
    private let savePersistedBackendToken: @Sendable (String) -> Bool
    private let deletePersistedBackendToken: @Sendable () -> Bool
    private let executeUsageRequest: UsageRequestExecutor
    private let executeLoginRequest: LoginRequestExecutor
    private var signInAttemptAuthorityTracker = MacSignInAttemptAuthorityTracker()
    private(set) var authenticationRecoveryError: String?

    // MARK: - Usage

    /// Usage summary fetched from the backend.
    private(set) var usageSummary: UsageSummary?

    /// True while usage data is being fetched.
    private(set) var isLoadingUsage: Bool = false

    /// User-facing recovery detail when the backend could not establish plan/usage truth.
    /// A missing summary is never interpreted as the Free plan.
    private(set) var usageLoadError: String?
    private(set) var usageSummaryIsStale = false
    private var usageRequestAuthorityTracker = MacUsageRequestAuthorityTracker()
    private var usageSummaryInvocationTracker = MacUsageSummaryInvocationTracker()

    var isConfigured: Bool {
        localGatewayURL != nil || (storedGatewayURL != nil && storedGatewayToken != nil)
    }

    /// SF Symbol name for the menu bar icon
    var menuBarIconName: String {
        switch connectionState {
        case .connected: "bolt.fill"
        case .connecting: "bolt.badge.clock"
        case .pairingRequired: "bolt.trianglebadge.exclamationmark"
        default: "bolt.slash"
        }
    }

    // MARK: - Internal

    let client = MacGatewayClient()
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    /// Tracks an in-flight re-pair so UI can show "Re-pairing…" instead of
    /// the default "Connecting…" banner. See #306 (Pairing recovery UX epic)
    /// and #320 (Widen Mac operator scope to operator.admin).
    private(set) var inFlightRePairTrigger: String?

    private var operatorSessionState: GatewaySessionLegState = .disconnected
    private var nodeSessionState: GatewaySessionLegState = .disconnected
    private var gatewayProcessState: GatewayProcessState = .unknown
    private var manualRecoveryState: GatewayManualRecoveryState = .none

    /// True while an auto-triggered re-pair is running. Views that care
    /// about distinguishing a silent recovery from a plain reconnect read
    /// this (banner copy swap).
    var isAutoRePairInProgress: Bool {
        inFlightRePairTrigger == "auto"
    }

    /// Auto-re-pair attempts in the current window. Reset on `.connected`
    /// or after `autoRePairWindow` seconds elapse since the first attempt.
    /// Prevents a tight loop when the gateway keeps rejecting a freshly-
    /// minted token (e.g. config still broken, scope not actually granted).
    /// See #306 (Pairing recovery UX epic) `shouldThrottleAutoRePair`.
    private var autoRePairAttempts: Int = 0
    private var autoRePairWindowStart: Date?

    private static let maxAutoRePairsPerWindow = 3
    private static let autoRePairWindow: TimeInterval = 5 * 60

    /// Periodic keepalive that detects silently-dropped sessions
    /// and reconnects without user intervention.
    private var keepaliveTask: Task<Void, Never>?
    private let keepaliveInterval: TimeInterval = 20

    /// Workspace notification observers for sleep/wake detection.
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    init(
        loadPersistedBackendToken: @escaping @Sendable () -> String? = {
            KeychainStore.loadString(service: "app.remclaw.mac", account: "backend.token")
        },
        savePersistedBackendToken: @escaping @Sendable (String) -> Bool = { token in
            KeychainStore.saveString(token, service: "app.remclaw.mac", account: "backend.token")
        },
        deletePersistedBackendToken: @escaping @Sendable () -> Bool = {
            KeychainStore.delete(service: "app.remclaw.mac", account: "backend.token")
        },
        executeUsageRequest: @escaping UsageRequestExecutor = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MacAuthenticatedHttpError.invalidResponse
            }
            return (data, http)
        },
        executeLoginRequest: @escaping LoginRequestExecutor = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MacAuthenticatedHttpError.invalidResponse
            }
            return (data, http)
        }
    ) {
        self.loadPersistedBackendToken = loadPersistedBackendToken
        self.savePersistedBackendToken = savePersistedBackendToken
        self.deletePersistedBackendToken = deletePersistedBackendToken
        self.executeUsageRequest = executeUsageRequest
        self.executeLoginRequest = executeLoginRequest
        #if DEBUG
        if let debugBaseURL = Bundle.main.infoDictionary?["APIBaseURL"] as? String,
           !debugBaseURL.isEmpty,
           backendURL != debugBaseURL {
            backendURL = debugBaseURL
        }
        #endif

        // Keep the HTTP client's refresh lifecycle on this manager's cached + Keychain authority.
        MacAuthenticatedHttpClient.currentAuthenticationAuthority = { [weak self] in
            self?.captureBackendAuthAuthority()
        }
        MacAuthenticatedHttpClient.currentBackendURL = { [weak self] in
            self?.effectiveBackendURL
        }
        MacAuthenticatedHttpClient.canPublishResponse = { [weak self] authority in
            self?.canPublishBackendResponse(for: authority) ?? false
        }
        MacAuthenticatedHttpClient.commitRefreshedAuthentication = { [weak self] authority, token in
            self?.commitRefreshedBackendToken(token, authority: authority)
        }
        MacAuthenticatedHttpClient.retireAuthentication = { [weak self] authority in
            self?.retireBackendAuthentication(ifCurrent: authority)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.client.setOnStateChange { [weak self] newState in
                await MainActor.run {
                    guard let self else { return }
                    self.connectionState = newState

                    switch newState {
                    case .connected:
                        self.nodeSessionState = .connected
                        if self.operatorReady {
                            self.operatorSessionState = .connected
                        }
                        self.manualRecoveryState = .none
                        self.lastConnectionDetail = nil
                        self.reconnectAttempt = 0
                        self.reconnectTask?.cancel()
                        self.startKeepalive()
                        self.gatewayProcessState = .running
                        // #306 (Pairing recovery UX epic): a successful
                        // connect proves the auto-re-pair worked, so reset
                        // the throttle budget for the next failure cycle.
                        self.resetAutoRePairBudget()
                        // Clear the in-flight re-pair trigger — the banner
                        // no longer needs to show "Re-pairing…".
                        self.inFlightRePairTrigger = nil
                    case .pairingRequired:
                        self.stopKeepalive()
                        // #320 (Widen Mac operator scope to operator.admin):
                        // route through the classifier-based dispatcher so
                        // scope-upgrade (and other auto-recoverable causes)
                        // self-heal silently. Trust-revocation and unknown
                        // reasons still fall through to the backend
                        // `requestAutoApprove()` path.
                        self.nodeSessionState = .failed("Pairing approval required")
                        self.lastConnectionDetail = "Pairing approval required"
                        self.dispatchPairingRecovery()
                    case .unreachable:
                        self.stopKeepalive()
                        if case .unreachable(let detail) = newState {
                            self.lastConnectionDetail = detail
                            self.nodeSessionState = .failed(detail)
                        } else {
                            self.nodeSessionState = .failed("Gateway unreachable")
                            self.lastConnectionDetail = "Gateway unreachable"
                        }
                        if self.operatorReady {
                            self.manualRecoveryState = .nodeRetryRequired
                        }
                        if self.reconnectAttempt == 0 {
                            // First drop — likely transient. Show "Connecting..."
                            // and immediately try to reconnect.
                            self.connectionState = .connecting
                            self.reconnectAttempt = 1
                            self.reconnectInternal(trigger: "grace")
                        } else {
                            self.scheduleReconnect()
                        }
                    case .disconnected, .unauthorized, .connecting:
                        self.stopKeepalive()
                        if case .connecting = newState {
                            if !self.operatorReady {
                                self.operatorSessionState = .connecting
                            }
                            self.nodeSessionState = .connecting
                            if self.localGatewayURL != nil {
                                self.gatewayProcessState = .starting
                            }
                        } else if case .disconnected = newState {
                            self.operatorSessionState = .disconnected
                            self.nodeSessionState = .disconnected
                            self.gatewayProcessState = self.localGatewayURL != nil ? .stopped : .unknown
                            self.manualRecoveryState = .none
                        } else if case .unauthorized = newState {
                            self.nodeSessionState = .failed("Unauthorized")
                            self.lastConnectionDetail = "Unauthorized"
                        }
                    }

                    self.refreshSessionHealth()
                }
            }
            await self.client.setOnOperatorStateChange { [weak self] connected in
                await MainActor.run {
                    guard let self else { return }
                    if self.operatorReady != connected {
                        self.operatorSessionGeneration &+= 1
                    }
                    self.operatorReady = connected
                    self.operatorSessionState = connected ? .connected : .disconnected
                    if !connected, self.connectionState != .connecting, self.connectionState != .disconnected {
                        self.operatorSessionState = .failed(self.lastConnectionDetail)
                    }
                    self.refreshSessionHealth()
                }
            }
            await self.client.setOnNodeStateChange { [weak self] connected in
                await MainActor.run {
                    guard let self else { return }
                    if connected {
                        self.nodeSessionState = .connected
                    } else if self.connectionState == .connecting {
                        self.nodeSessionState = .connecting
                    } else if self.connectionState == .pairingRequired {
                        self.nodeSessionState = .failed("Pairing approval required")
                    } else if case .unreachable = self.connectionState {
                        self.nodeSessionState = .failed(self.lastConnectionDetail)
                    } else {
                        self.nodeSessionState = .disconnected
                    }
                    self.refreshSessionHealth()
                }
            }
            await self.client.setOnSkillsChanged { [weak self] in
                await MainActor.run {
                    self?.skillsSnapshotVersion += 1
                }
            }
        }

        observeSleepWake()
        restoreCachedProfile()
        if MacRuntimeConfig.isVisualQAMode {
            isAuthenticationStateLoaded = true
            cachedBackendToken = nil
        } else {
            loadBackendTokenCache()
        }
    }

    deinit {
        if let sleepObserver { NotificationCenter.default.removeObserver(sleepObserver) }
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
    }

    // MARK: - Keepalive

    /// Periodically probes both sessions to detect silent drops.
    /// If a probe fails, reconnects automatically.
    private func startKeepalive() {
        stopKeepalive()
        let interval = keepaliveInterval
        // Require TWO consecutive missed probes before reconnecting (parity with
        // iOS #connection-reliability). A single slow `health` response under
        // load isn't proof the socket dropped — reconnecting on the first miss
        // can turn a transient blip into a reconnect feedback loop. The miss
        // counter lives in the task so only ONE keepalive loop ever holds it
        // (stopKeepalive() cancels the prior).
        keepaliveTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.connectionState.isConnected else { misses = 0; continue }

                let alive = await self.client.testConnection()
                if alive {
                    misses = 0
                } else {
                    misses += 1
                    if misses >= 2 {
                        misses = 0
                        log.warning("keepalive: probe failed twice, reconnecting...")
                        self.reconnectInternal(trigger: "keepalive")
                    } else {
                        log.info("keepalive: probe missed once, re-checking next tick")
                    }
                }
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Auto-reconnect with backoff

    /// Schedules an automatic reconnect with exponential backoff + jitter.
    /// Handles transient WebSocket drops without hammering the server.
    private func scheduleReconnect() {
        guard isConfigured else { return }
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            // 1s, 2s, 4s, 8s, max 30s — plus jitter
            let base = min(30.0, 1.0 * pow(2.0, Double(attempt)))
            let jitter = Double.random(in: 0..<1.0)
            let delay = base + jitter
            log.info("auto-reconnect in \(String(format: "%.1f", delay))s (attempt \(attempt + 1))")
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.reconnectAttempt = attempt + 1
            self.reconnectInternal(trigger: "backoff")
        }
    }

    // MARK: - Sleep / Wake detection

    /// Observes macOS sleep and wake notifications to reconnect after the Mac
    /// wakes from sleep. The WebSocket is always dead after sleep.
    private func observeSleepWake() {
        let workspace = NSWorkspace.shared.notificationCenter

        sleepObserver = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            log.info("Mac going to sleep — stopping keepalive")
            self?.stopKeepalive()
        }

        wakeObserver = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            log.info("Mac woke from sleep — reconnecting")
            // Brief delay for network interfaces to come up
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isConfigured else { return }
                self.reconnectAttempt = 0
                self.reconnectInternal(trigger: "wake")
            }
        }
    }

    // MARK: - Credentials (shared with iOS via UserDefaults suite or standalone)

    /// Gateway URL — stored in UserDefaults. Always stored with https:// so URL parsing has a valid host.
    var storedGatewayURL: String? {
        get {
            guard var url = UserDefaults.standard.string(forKey: "gateway_url") else { return nil }
            if url.contains("poduction") {
                url = url.replacingOccurrences(of: "poduction", with: "production")
                UserDefaults.standard.set(url, forKey: "gateway_url")
            }
            return url
        }
        set { UserDefaults.standard.set(newValue, forKey: "gateway_url") }
    }

    private static func normalizeGatewayURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("poduction") {
            trimmed = trimmed.replacingOccurrences(of: "poduction", with: "production")
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return trimmed }
        return "https://\(trimmed)"
    }

    /// Gateway token — stored in Keychain for security.
    var storedGatewayToken: String? {
        get { KeychainStore.loadString(service: Self.keychainService, account: Self.tokenAccount) }
        set {
            if let value = newValue {
                _ = KeychainStore.saveString(value, service: Self.keychainService, account: Self.tokenAccount)
            } else {
                _ = KeychainStore.delete(service: Self.keychainService, account: Self.tokenAccount)
            }
        }
    }

    private static let keychainService = "app.remclaw.mac"
    private static let tokenAccount = "gateway.token"
    private static let backendURLKey = "backend_url"

    // MARK: - Backend Auth (Keychain)

    var backendToken: String? {
        get {
            if isAuthenticationStateLoaded {
                return cachedBackendToken
            }
            let token = loadPersistedBackendToken()
            cachedBackendToken = token
            isAuthenticationStateLoaded = true
            return token
        }
    }

    /// Persists first, then publishes the matching cache/generation transition. A failed Keychain
    /// operation leaves the previous in-memory and persisted authority intact and surfaces recovery.
    func persistBackendToken(
        _ newValue: String?,
        preservesAccountAuthority: Bool = false
    ) throws {
        let previous = backendToken
        let persisted = if let newValue {
            savePersistedBackendToken(newValue)
        } else {
            deletePersistedBackendToken()
        }
        guard persisted else {
            let message = newValue == nil
                ? "Rem couldn't securely sign out. Unlock Keychain and try again."
                : "Rem couldn't securely save your session. Unlock Keychain and try again."
            authenticationRecoveryError = message
            throw MacBackendCredentialPersistenceError.failed(message)
        }

        if previous != newValue {
            backendAuthGeneration &+= 1
            if !preservesAccountAuthority {
                backendAccountGeneration &+= 1
                signInAttemptAuthorityTracker.invalidate()
            }
        }
        cachedBackendToken = newValue
        isAuthenticationStateLoaded = true
        authenticationRecoveryError = nil
    }

    var backendURL: String? {
        get { UserDefaults.standard.string(forKey: Self.backendURLKey) }
        set {
            if UserDefaults.standard.string(forKey: Self.backendURLKey) != newValue {
                backendAuthGeneration &+= 1
                backendAccountGeneration &+= 1
                signInAttemptAuthorityTracker.invalidate()
            }
            UserDefaults.standard.set(newValue, forKey: Self.backendURLKey)
        }
    }

    var isAuthenticated: Bool {
        isAuthenticationStateLoaded && !(cachedBackendToken?.isEmpty ?? true)
    }

    private func loadBackendTokenCache() {
        let loader = loadPersistedBackendToken
        Task.detached(priority: .userInitiated) { [weak self] in
            let token = loader()
            await MainActor.run {
                guard let self else { return }
                guard !self.isAuthenticationStateLoaded else { return }
                if self.cachedBackendToken != token {
                    self.backendAuthGeneration &+= 1
                    self.backendAccountGeneration &+= 1
                }
                self.cachedBackendToken = token
                self.isAuthenticationStateLoaded = true
            }
        }
    }

    private var effectiveBackendURL: String? {
        backendURL ?? (Bundle.main.infoDictionary?["APIBaseURL"] as? String)
    }

    func beginSignInAttempt() -> MacSignInAttemptAuthority? {
        guard let base = effectiveBackendURL, !base.isEmpty else { return nil }
        return signInAttemptAuthorityTracker.begin(backendURL: base)
    }

    func captureBackendAuthAuthority() -> MacBackendAuthAuthority? {
        guard let token = backendToken, !token.isEmpty,
              let base = effectiveBackendURL, !base.isEmpty
        else { return nil }
        return MacBackendAuthAuthority(
            generation: backendAuthGeneration,
            accountGeneration: backendAccountGeneration,
            backendURL: base,
            backendToken: token
        )
    }

    private func canPublishBackendResponse(for authority: MacBackendAuthAuthority) -> Bool {
        guard let current = captureBackendAuthAuthority() else { return false }
        return authority.accountGeneration == current.accountGeneration
            && authority.backendURL == current.backendURL
    }

    private func commitRefreshedBackendToken(
        _ refreshedToken: String,
        authority: MacBackendAuthAuthority
    ) -> MacBackendAuthAuthority? {
        guard authority.isCurrent(
            generation: backendAuthGeneration,
            backendURL: effectiveBackendURL,
            backendToken: backendToken
        ) else { return nil }

        do {
            try persistBackendToken(refreshedToken, preservesAccountAuthority: true)
        } catch {
            return nil
        }
        let interruptedUsageRefresh = isLoadingUsage
        usageRequestAuthorityTracker.invalidate()
        isLoadingUsage = false
        if interruptedUsageRefresh {
            usageSummaryIsStale = usageSummary != nil
            usageLoadError = "Rem couldn't finish refreshing your plan and usage. Try again."
        }
        return captureBackendAuthAuthority()
    }

    private func retireBackendAuthentication(ifCurrent authority: MacBackendAuthAuthority) {
        guard authority.isCurrent(
            generation: backendAuthGeneration,
            backendURL: effectiveBackendURL,
            backendToken: backendToken
        ) else { return }
        signOut()
    }

    // MARK: - Fetch Gateway Credentials from Backend

    func fetchGatewayCredentials() async throws {
        let (data, http) = try await MacAuthenticatedHttpClient.request(
            path: "/api/v1/me/credentials",
            method: "GET"
        )

        if http.statusCode == 404 {
            log.warning("no gateway deployed for this user — sign in on iPhone first")
            throw MacGatewayError.noGatewayDeployed
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            log.error("credentials fetch failed status=\(http.statusCode) body=\(body)")
            throw MacGatewayError.credentialsFetchFailed(statusCode: http.statusCode)
        }

        struct CredentialsResponse: Codable {
            let gatewayUrl: String
            let gatewayToken: String
        }

        let creds = try JSONDecoder().decode(CredentialsResponse.self, from: data)
        configure(gatewayURL: creds.gatewayUrl, gatewayToken: creds.gatewayToken, provider: .fly)
    }

    // MARK: - Auto-approve

    private var hasRequestedAutoApprove = false

    /// Prevents repeated pending-device fetches on every view appear.
    private var hasFetchedPendingDevices = false

    func requestAutoApprove() {
        guard !hasRequestedAutoApprove else { return }

        // Backend auto-approve opens a WebSocket from Railway to the gateway's
        // URL to call `device.pair.approve`. That works for cloud (Fly.io)
        // gateways because the backend can route to the public URL, but for a
        // local gateway bound to 127.0.0.1 / *.local the backend has no path
        // there — every call fails with `approve-device HTTP 500: auto-approve
        // timed out: no pending devices found` (#290). Skip the trip for
        // local; the recovery path for local is Reset Pairing (#287) or a
        // future on-device approver (#292).
        if localGatewayURL != nil {
            log.info("skipping backend auto-approve — local gateways must approve on-device (#290)")
            manualRecoveryState = .approvalRequired
            hasFetchedPendingDevices = false
            Task { await fetchPendingDevices() }
            refreshSessionHealth()
            return
        }

        hasRequestedAutoApprove = true

        Task {
            do {
                log.info("requesting auto-approve from backend...")
                try await callApproveDevice()
                log.info("auto-approve succeeded, reconnecting...")
                try await Task.sleep(for: .seconds(2))
                reconnect()
            } catch {
                log.error("auto-approve failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(2))
                reconnect()
            }
            try? await Task.sleep(for: .seconds(10))
            hasRequestedAutoApprove = false
        }
    }

    private func callApproveDevice() async throws {
        let (data, http) = try await MacAuthenticatedHttpClient.request(
            path: "/api/v1/approve-device",
            method: "POST",
            timeout: 45
        )
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw NSError(domain: "ApproveDevice", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "approve-device HTTP \(http.statusCode): \(body)"])
        }
    }

    // MARK: - Pairing recovery dispatcher (#306 Pairing recovery UX epic)

    /// Chooses between auto-re-pair and user-tap recovery based on the
    /// classified disconnect reason, mirroring the iOS dispatcher
    /// (`RemGatewaySessionManager.dispatchPairingRecovery`).
    ///
    ///   - `.scopeUpgrade` / `.roleUpgrade` / `.metadataUpgrade` /
    ///     `.signatureExpired` — we caused the mismatch / the user already
    ///     consented once. Clear the token and re-pair silently. UI swaps
    ///     to "Re-pairing…" via `isAutoRePairInProgress`.
    ///   - `.signatureInvalid` / `.deviceIdMismatch` / `.deviceTokenMismatch`
    ///     / `.publicKeyInvalid` / `.nonceMismatch` — the gateway no longer
    ///     trusts this device. Leave the state in `.pairingRequired` so the
    ///     Shared "Re-pair this device" CTA is visible; the user decides.
    ///   - `.unknown` — fall back to the existing backend auto-approve
    ///     path (covers unclassified errors the gateway surfaces today).
    ///
    /// The typed signal lives on `MacGatewayClient.lastConnectError`
    /// (actor-isolated), so this hop is async. See #320 (Widen Mac
    /// operator scope to operator.admin) for why this path exists on Mac
    /// starting now: shipping `operator.admin` in operator scopes causes
    /// existing tokens to be rejected with `details.reason = "scope-upgrade"`
    /// on first reconnect, and this dispatcher is the recovery.
    private func dispatchPairingRecovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.fetchClassificationSnapshot()
            if snapshot.classification.isAutoRecoverable {
                if self.shouldThrottleAutoRePair() {
                    // Out of auto-re-pair budget. Local gateways cannot use
                    // backend auto-approve, so surface deterministic manual
                    // recovery in-app instead of silently looping.
                    if self.localGatewayURL != nil {
                        log.warning("auto-re-pair throttled for local gateway; requiring manual approval UI")
                        self.manualRecoveryState = .approvalRequired
                        self.hasFetchedPendingDevices = false
                        Task { await self.fetchPendingDevices() }
                    } else {
                        log.warning("auto-re-pair throttled (classification=\(snapshot.classification.telemetryValue, privacy: .public)), falling back to requestAutoApprove")
                        self.requestAutoApprove()
                    }
                    self.refreshSessionHealth()
                    return
                }
                log.info("auto-recoverable pairing failure (\(snapshot.classification.telemetryValue, privacy: .public)) — re-pairing silently")
                self.manualRecoveryState = .none
                self.refreshSessionHealth()
                self.resetPairing(trigger: "auto")
            } else if snapshot.classification.isTrustRevocation {
                // Leave .pairingRequired visible so the banner's "Re-pair"
                // CTA is available. No auto-recovery — we want the user to
                // know trust was revoked.
                log.warning("trust revocation detected (\(snapshot.classification.telemetryValue, privacy: .public)) — leaving .pairingRequired for user-tap recovery")
                self.manualRecoveryState = .rePairRequired
                self.refreshSessionHealth()
                return
            } else {
                // Unknown reason — existing backend auto-approve path.
                if self.localGatewayURL != nil {
                    self.manualRecoveryState = .approvalRequired
                    self.hasFetchedPendingDevices = false
                    Task { await self.fetchPendingDevices() }
                    self.refreshSessionHealth()
                } else {
                    self.requestAutoApprove()
                }
            }
        }
    }

    /// Snapshot used by the dispatcher. Reads the actor-stored typed error
    /// first; falls back to the reason string when no structured error is
    /// available (e.g. post-connect transport drop). Mirrors
    /// `RemGatewaySessionManager.fetchClassificationSnapshot` minus the
    /// telemetry-only `source` field — Mac doesn't have TelemetryService.
    private struct ClassificationSnapshot {
        let classification: GatewayPairingFailure
        let reason: String?
    }

    private func fetchClassificationSnapshot() async -> ClassificationSnapshot {
        let error = await client.lastConnectError
        let reason = await client.lastDisconnectReason
        if let error {
            let typed = GatewayPairingFailure.classify(error: error)
            if typed != .unknown {
                return ClassificationSnapshot(classification: typed, reason: reason)
            }
        }
        let stringClass = GatewayPairingFailure.from(reasonString: reason)
        return ClassificationSnapshot(classification: stringClass, reason: reason)
    }

    /// True when we've burned our auto-re-pair budget in the current window.
    /// Prevents a flapping connection from churning through resets when the
    /// gateway keeps rejecting the freshly-minted token. Mirrors the iOS
    /// throttle in `RemGatewaySessionManager.shouldThrottleAutoRePair`.
    private func shouldThrottleAutoRePair() -> Bool {
        let now = Date()
        if let start = autoRePairWindowStart,
           now.timeIntervalSince(start) > Self.autoRePairWindow {
            autoRePairAttempts = 0
            autoRePairWindowStart = nil
        }
        if autoRePairAttempts >= Self.maxAutoRePairsPerWindow {
            return true
        }
        autoRePairAttempts += 1
        if autoRePairWindowStart == nil {
            autoRePairWindowStart = now
        }
        return false
    }

    private func resetAutoRePairBudget() {
        autoRePairAttempts = 0
        autoRePairWindowStart = nil
    }

    // MARK: - Token Refresh

    /// Silently refreshes the backend JWT by sending the current (possibly expired)
    /// token to `/api/v1/auth/refresh`. The backend verifies the signature (ignoring
    /// expiry) and issues a fresh JWT. Updates the Keychain on success.
    func refreshAuthIfNeeded() async throws {
        guard let token = backendToken, !token.isEmpty else {
            throw MacGatewayError.notConnected
        }

        // Decode JWT payload to check expiry
        if !Self.isTokenExpired(token) { return }

        guard let authority = captureBackendAuthAuthority() else {
            throw MacGatewayError.notConnected
        }

        log.info("refreshing expired backend token...")
        _ = try await MacAuthenticatedHttpClient.refreshAuthentication(for: authority)
        log.info("token refresh succeeded")
    }

    /// Checks whether a JWT is expired by decoding its payload.
    /// Returns true if expired or unparseable (fail-safe: attempt refresh).
    private static func isTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return true }

        var base64 = String(parts[1])
        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }

        // Expired if less than 60 seconds remaining
        return Date().timeIntervalSince1970 >= (exp - 60)
    }

    /// Ensures the backend token is fresh before making API calls.
    /// If refresh fails, falls through silently (the call will fail with 401).
    func ensureFreshToken() async {
        do {
            try await refreshAuthIfNeeded()
        } catch {
            log.warning("token refresh failed (will retry on next call): \(error.localizedDescription)")
        }
    }

    func signOut() {
        _ = signOutWithRecovery()
    }

    @discardableResult
    func signOutWithRecovery() -> String? {
        do {
            try persistBackendToken(nil)
        } catch {
            return authenticationRecoveryError ?? error.localizedDescription
        }

        retireUsageAuthority(clearSummary: true)
        clearConfiguration()
        // See RemAuthService.signOut: account-stamped, but still the signed-out user's prose.
        BriefContext.clearOrchestratorHeadline()
        backendURL = nil
        userProfile = nil
        Self.clearCachedProfile()
        return nil
    }

    /// Used when a sign-in sequence fails after authentication but before gateway setup completes.
    /// A failed secure deletion remains visible and leaves the cached authority coherent.
    @discardableResult
    func clearBackendAuthenticationAfterFailedSignIn(
        ifCurrent authority: MacBackendAuthAuthority
    ) -> String? {
        guard authority.isCurrent(
            generation: backendAuthGeneration,
            backendURL: effectiveBackendURL,
            backendToken: backendToken
        ) else { return nil }

        do {
            try persistBackendToken(nil)
            retireUsageAuthority(clearSummary: true)
            userProfile = nil
            Self.clearCachedProfile()
            return nil
        } catch {
            return authenticationRecoveryError ?? error.localizedDescription
        }
    }

    // MARK: - Apple Sign In

    /// Authenticate with the backend using an Apple ID token, store the JWT,
    /// then fetch gateway credentials and connect.
    func signInWithApple() async throws {
        guard let attempt = beginSignInAttempt() else { throw MacGatewayError.invalidURL }
        let result = try await requestAppleAuthorization()
        var profile: [String: String?]?
        if result.givenName != nil || result.familyName != nil {
            profile = [
                "given_name": result.givenName,
                "family_name": result.familyName,
            ]
        }
        let authority = try await authenticateWithBackend(
            provider: "apple",
            idToken: result.idToken,
            profile: profile,
            appleAuthorizationCode: result.authorizationCode,
            attempt: attempt
        )
        do {
            try await fetchGatewayCredentials()
        } catch MacGatewayError.noGatewayDeployed {
            throw MacGatewayError.noGatewayDeployed
        } catch {
            _ = clearBackendAuthenticationAfterFailedSignIn(ifCurrent: authority)
            throw error
        }
    }

    private func requestAppleAuthorization() async throws -> MacAppleSignInResult {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MacAppleSignInResult, Error>) in
            let delegate = MacAppleSignInDelegate(continuation: continuation)
            controller.delegate = delegate
            controller.performRequests()
            // Prevent delegate from being deallocated
            objc_setAssociatedObject(controller, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    // MARK: - Google Sign In (ASWebAuthenticationSession)

    /// Google OAuth Client ID (iOS type — no client secret needed for PKCE/public clients).
    private static let googleClientID = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"

    /// Reversed client ID used as the custom URL scheme for the OAuth redirect.
    private static let googleCallbackScheme = "com.googleusercontent.apps.YOUR_GOOGLE_CLIENT_ID"

    /// Authenticate with the backend using Google Sign-In via ASWebAuthenticationSession.
    /// Opens Google's OAuth consent screen in a browser sheet, exchanges the auth code
    /// for an ID token, then sends it to the backend.
    func signInWithGoogle(attempt: MacSignInAttemptAuthority? = nil) async throws {
        guard let attempt = attempt ?? beginSignInAttempt() else { throw MacGatewayError.invalidURL }
        let (authCode, codeVerifier) = try await requestGoogleAuthCode()
        let idToken = try await exchangeGoogleCodeForIDToken(authCode: authCode, codeVerifier: codeVerifier)
        let authority = try await authenticateWithBackend(
            provider: "google",
            idToken: idToken,
            attempt: attempt
        )
        do {
            try await fetchGatewayCredentials()
        } catch MacGatewayError.noGatewayDeployed {
            throw MacGatewayError.noGatewayDeployed
        } catch {
            _ = clearBackendAuthenticationAfterFailedSignIn(ifCurrent: authority)
            throw error
        }
    }

    /// Presents Google's OAuth consent screen via ASWebAuthenticationSession and
    /// returns the authorization code along with the PKCE code verifier.
    private func requestGoogleAuthCode() async throws -> (code: String, codeVerifier: String) {
        // Generate PKCE code verifier and challenge
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)

        let redirectURI = "\(Self.googleCallbackScheme):/oauth2callback"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.googleClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]

        guard let authURL = components.url else {
            throw MacGatewayError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.googleCallbackScheme
            ) { callbackURL, error in
                if let error {
                    // User cancelled — ASWebAuthenticationSession error code 1
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: MacGatewayError.authCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: MacGatewayError.authFailed(statusCode: -1))
                    return
                }

                continuation.resume(returning: (code, codeVerifier))
            }

            // Present the authentication session — requires a presentation anchor (window)
            session.presentationContextProvider = GoogleSignInPresentationProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    /// Exchanges a Google authorization code for an ID token via Google's token endpoint.
    /// Uses PKCE (no client secret required for iOS-type OAuth clients).
    private func exchangeGoogleCodeForIDToken(authCode: String, codeVerifier: String) async throws -> String {
        let redirectURI = "\(Self.googleCallbackScheme):/oauth2callback"

        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw MacGatewayError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code=\(authCode)",
            "client_id=\(Self.googleClientID)",
            "redirect_uri=\(redirectURI)",
            "grant_type=authorization_code",
            "code_verifier=\(codeVerifier)",
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MacGatewayError.authFailed(statusCode: -1)
        }
        guard http.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            log.error("Google token exchange failed status=\(http.statusCode) body=\(responseBody)")
            throw MacGatewayError.authFailed(statusCode: http.statusCode)
        }

        struct TokenResponse: Codable {
            let id_token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return tokenResponse.id_token
    }

    // MARK: - PKCE Helpers

    /// Generates a cryptographically random code verifier for PKCE (43-128 characters).
    private static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generates a SHA-256 code challenge from a code verifier for PKCE.
    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hashed = SHA256.hash(data: data)
        return Data(hashed)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func authenticateWithBackend(
        provider: String,
        idToken: String,
        profile: [String: String?]? = nil,
        appleAuthorizationCode: String? = nil,
        attempt: MacSignInAttemptAuthority
    ) async throws -> MacBackendAuthAuthority {
        let base = backendURL
            ?? (Bundle.main.infoDictionary?["APIBaseURL"] as? String)
        guard let base, !base.isEmpty, let url = URL(string: "\(base)/api/v1/auth/login") else {
            throw MacGatewayError.invalidURL
        }
        guard signInAttemptAuthorityTracker.isCurrent(attempt, backendURL: base) else {
            throw CancellationError()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClientVersion.setHeaders(on: &request)

        var body: [String: Any] = ["provider": provider, "id_token": idToken]
        if let profile {
            body["profile"] = profile.compactMapValues { $0 }
        }
        if let appleAuthorizationCode {
            body["apple_authorization_code"] = appleAuthorizationCode
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await executeLoginRequest(request)
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            log.error("auth/login failed status=\(http.statusCode) body=\(body)")
            throw MacGatewayError.authFailed(statusCode: http.statusCode)
        }

        struct MacAuthResponse: Codable {
            let access_token: String
            let user: UserProfile?
        }

        let authResponse = try JSONDecoder().decode(MacAuthResponse.self, from: data)
        try Task.checkCancellation()
        guard signInAttemptAuthorityTracker.isCurrent(attempt, backendURL: effectiveBackendURL) else {
            throw CancellationError()
        }
        try persistBackendToken(authResponse.access_token)
        retireUsageAuthority(clearSummary: true)
        backendURL = base

        // Cache user profile from auth response for immediate display
        if let user = authResponse.user {
            self.userProfile = user
            Self.cacheProfile(user)
        }

        guard let authority = captureBackendAuthAuthority() else {
            throw MacGatewayError.authFailed(statusCode: -1)
        }
        return authority
    }

    // MARK: - Gateway Deploy

    /// Triggers a gateway deploy for the current user and polls until complete.
    /// On success, fetches credentials and connects automatically.
    func deployGateway() async throws {
        // Start deploy
        deployPhase = .deploying("Creating server...")
        log.info("starting gateway deploy...")

        let body = try JSONSerialization.data(withJSONObject: ["hostingProvider": "fly"])

        let (startData, startHTTP) = try await MacAuthenticatedHttpClient.request(
            path: "/api/v1/deploy",
            method: "POST",
            body: body
        )
        guard (200...299).contains(startHTTP.statusCode) else {
            let body = String(data: startData, encoding: .utf8) ?? ""
            log.error("deploy start failed: HTTP \(startHTTP.statusCode) \(body)")
            deployPhase = .failed("Deploy failed: HTTP \(startHTTP.statusCode)")
            throw MacGatewayError.deployFailed(message: body)
        }

        struct DeployStartResponse: Codable {
            let deployId: String
        }

        let deployResponse = try JSONDecoder().decode(DeployStartResponse.self, from: startData)
        let deployId = deployResponse.deployId
        log.info("deploy started: \(deployId)")

        // Poll for completion
        try await pollDeployStatus(deployId: deployId)
    }

    private func pollDeployStatus(deployId: String) async throws {
        let encodedId = deployId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deployId
        while true {
            try await Task.sleep(for: .seconds(2))

            let (data, http) = try await MacAuthenticatedHttpClient.request(
                path: "/api/v1/deploy/status?id=\(encodedId)",
                method: "GET"
            )
            guard (200...299).contains(http.statusCode) else {
                continue
            }

            struct StatusWrapper: Codable {
                let status: StatusResponse
            }
            struct StatusResponse: Codable {
                let phase: String
                let message: String
                let gatewayUrl: String?
                let gatewayToken: String?
            }

            let statusWrapper = try JSONDecoder().decode(StatusWrapper.self, from: data)
            let status = statusWrapper.status
            log.info("deploy phase: \(status.phase) — \(status.message)")

            switch status.phase {
            case "creating_project", "setting_variables":
                deployPhase = .deploying("Creating server...")
            case "deploying":
                deployPhase = .deploying("Deploying server...")
            case "waiting_for_healthy":
                deployPhase = .deploying("Waiting for server...")
            case "running_onboarding":
                deployPhase = .deploying("Configuring server...")
            case "saving_credentials":
                deployPhase = .deploying("Saving credentials...")
            case "complete":
                log.info("deploy complete")
                if let url = status.gatewayUrl, let gToken = status.gatewayToken {
                    configure(gatewayURL: url, gatewayToken: gToken, provider: .fly)
                }
                deployPhase = .complete
                return
            case "failed":
                log.error("deploy failed: \(status.message)")
                deployPhase = .failed(status.message)
                throw MacGatewayError.deployFailed(message: status.message)
            default:
                deployPhase = .deploying(status.message)
            }
        }
    }

    // MARK: - Configure

    func configure(gatewayURL: String, gatewayToken: String) {
        configure(gatewayURL: gatewayURL, gatewayToken: gatewayToken, provider: nil)
    }

    func configure(gatewayURL: String, gatewayToken: String, provider: GatewayProvider?) {
        storedGatewayURL = Self.normalizeGatewayURL(gatewayURL)
        storedGatewayToken = gatewayToken
        activeGatewayProvider = provider
        connectIfConfigured()
    }

    func configure(gatewayConfig: GatewayConfig) {
        configure(gatewayURL: gatewayConfig.url, gatewayToken: gatewayConfig.token, provider: gatewayConfig.provider)
    }

    func clearConfiguration() {
        connectTask?.cancel()
        connectTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stopKeepalive()
        reconnectAttempt = 0
        UserDefaults.standard.removeObject(forKey: "gateway_url")
        UserDefaults.standard.removeObject(forKey: "local_gateway_url")
        UserDefaults.standard.removeObject(forKey: "rem.mac.active_gateway_provider")
        _ = KeychainStore.delete(service: Self.keychainService, account: Self.tokenAccount)
        gatewayHostDisplay = nil
        connectionState = .disconnected
        operatorSessionGeneration &+= 1
        operatorReady = false
        operatorSessionState = .disconnected
        nodeSessionState = .disconnected
        gatewayProcessState = .stopped
        manualRecoveryState = .none
        lastConnectionDetail = nil
        refreshSessionHealth()
        hasFetchedPendingDevices = false
        Task { await client.disconnect() }
    }

    /// Migrates gateway token from UserDefaults to Keychain (one-time).
    func migrateTokenIfNeeded() {
        let defaults = UserDefaults.standard
        if let legacyToken = defaults.string(forKey: "gateway_token"),
           !legacyToken.isEmpty,
           storedGatewayToken == nil {
            storedGatewayToken = legacyToken
            defaults.removeObject(forKey: "gateway_token")
        }
    }

    // MARK: - Multi-Gateway Migration

    /// Reads existing single-gateway credentials and creates a `GatewayConfig`
    /// entry in the provided `GatewayConfigStore`. Safe to call repeatedly --
    /// the store skips migration if a matching config already exists.
    func migrateToMultiGateway(store: GatewayConfigStore) {
        store.migrateFromLegacy(
            url: storedGatewayURL,
            token: storedGatewayToken,
            provider: .fly,
            displayName: "Cloud Gateway"
        )
    }

    /// Connects using the active gateway from a `GatewayConfigStore`,
    /// falling back to the legacy single-gateway credentials.
    func connectFromConfigStore(_ store: GatewayConfigStore) {
        if let active = store.activeConfig {
            configure(gatewayURL: active.url, gatewayToken: active.token, provider: active.provider)
        } else {
            connectIfConfigured()
        }
    }

    // MARK: - Connection lifecycle

    /// Local gateway URL override — when set, connects to a local gateway instead of the cloud.
    /// Stored in UserDefaults under `local_gateway_url`.
    var localGatewayURL: String? {
        get {
            let value = UserDefaults.standard.string(forKey: "local_gateway_url")
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { UserDefaults.standard.set(newValue, forKey: "local_gateway_url") }
    }

    var activeLocalGatewayURL: String? {
        localGatewayURL
    }

    /// Canonical non-secret identity for state that must never cross the active runtime boundary.
    /// A retained cloud URL is not active while the local override owns the connection.
    var effectiveGatewayScopeIdentity: String {
        MacGatewaySuggestionScopeIdentity.resolve(
            activeLocalURL: activeLocalGatewayURL,
            storedGatewayURL: storedGatewayURL,
            provider: activeGatewayProvider
        )
    }

    var activeLocalGatewayToken: String? {
        LocalGatewayManager.currentGatewayToken() ?? storedGatewayToken
    }

    var sessionPreviewContext: SessionPreviewContext {
        let provider = sessionPreviewProvider
        return SessionPreviewContext(
            gatewayProvider: provider,
            gatewayName: sessionPreviewGatewayName(provider: provider),
            gatewayId: gatewayHostDisplay,
            deviceId: DeviceIdentityStore.loadOrCreate().deviceId,
            deviceName: Host.current().localizedName ?? "Mac"
        )
    }

    private var activeGatewayProvider: GatewayProvider? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "rem.mac.active_gateway_provider") else { return nil }
            return GatewayProvider(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: "rem.mac.active_gateway_provider")
            } else {
                UserDefaults.standard.removeObject(forKey: "rem.mac.active_gateway_provider")
            }
        }
    }

    var activeGatewayProviderForDisplay: GatewayProvider? {
        activeGatewayProvider
    }

    private var isActiveGatewayLocal: Bool {
        if localGatewayURL != nil { return true }
        return activeGatewayProvider == .local
    }

    private var sessionPreviewProvider: SessionPreviewEntry.GatewayProvider {
        if isActiveGatewayLocal {
            return .mac
        }
        switch activeGatewayProvider {
        case .fly:
            return .cloud
        case .manual:
            return .manual
        case .local:
            return .mac
        case nil:
            guard let rawURL = storedGatewayURL,
                  let host = URL(string: rawURL)?.host?.lowercased()
            else {
                return .unknown
            }
            return host.hasSuffix(".fly.dev") ? .cloud : .manual
        }
    }

    private func sessionPreviewGatewayName(provider: SessionPreviewEntry.GatewayProvider) -> String {
        switch provider {
        case .mac: "Local Mac Gateway"
        case .cloud: "Cloud Gateway"
        case .manual: "Manual Gateway"
        case .unknown: "Active gateway"
        }
    }

    func connectIfConfigured() {
        // Retire the current RPC authority synchronously, including when only the token/account
        // changed at the same URL. A later connected edge advances the generation again.
        operatorSessionGeneration &+= 1
        operatorReady = false
        // If a local gateway URL is set, use it instead of the cloud gateway
        if let localURL = localGatewayURL, let url = URL(string: localURL) {
            gatewayHostDisplay = GatewayHostDisplay.sanitized(url.host) ?? "localhost"
            operatorSessionState = .connecting
            nodeSessionState = .connecting
            gatewayProcessState = .starting
            manualRecoveryState = .none
            lastConnectionDetail = nil
            refreshSessionHealth()
            connectTask?.cancel()
            connectTask = Task { [weak self] in
                guard let self else { return }
                do {
                    // Token source of truth is `~/.openclaw/openclaw.json`
                    // (gateway.auth.token), which `openclaw gateway install`
                    // writes. Keychain is a secondary cache populated by the
                    // chooser's `configure()` call; it can go stale if the
                    // CLI regenerates the token outside our flow.
                    //
                    // Read config first and reconcile Keychain if they drift
                    // — this self-heals users upgrading from the old custom
                    // token flow where we stored our own generated tokens.
                    let configToken = LocalGatewayManager.currentGatewayToken()
                    if let configToken, configToken != self.storedGatewayToken {
                        log.info("reconciling stale Keychain token with config gateway.auth.token")
                        self.storedGatewayToken = configToken
                    }
                    let token = configToken
                        ?? self.storedGatewayToken
                        ?? ""
                    try await self.client.connect(gatewayURL: url, token: token)
                } catch {
                    log.error("local gateway connect failed: \(error.localizedDescription)")
                    self.lastConnectionDetail = error.localizedDescription
                    self.nodeSessionState = .failed(error.localizedDescription)
                    if self.operatorReady {
                        self.manualRecoveryState = .nodeRetryRequired
                    }
                    if self.connectionState != .pairingRequired {
                        self.connectionState = .unreachable(error.localizedDescription)
                    }
                    await self.updateLocalGatewayProcessState(
                        localURL: localURL,
                        fallbackError: error.localizedDescription
                    )
                    self.refreshSessionHealth()
                }
            }
            return
        }

        guard let rawURL = storedGatewayURL,
              let token = storedGatewayToken else { return }
        let urlString = Self.normalizeGatewayURL(rawURL)
        guard let url = URL(string: urlString) else { return }

        gatewayHostDisplay = GatewayHostDisplay.sanitized(url.host)
        operatorSessionState = .connecting
        nodeSessionState = .connecting
        gatewayProcessState = .unknown
        manualRecoveryState = .none
        lastConnectionDetail = nil
        refreshSessionHealth()
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.connect(gatewayURL: url, token: token)
            } catch {
                if let ns = error as NSError? {
                    log.error("gateway connect failed: \(ns.localizedDescription) domain=\(ns.domain) code=\(ns.code)")
                } else {
                    log.error("gateway connect failed: \(error.localizedDescription)")
                }
                self.lastConnectionDetail = error.localizedDescription
                self.nodeSessionState = .failed(error.localizedDescription)
                if self.connectionState != .pairingRequired {
                    self.connectionState = .unreachable(error.localizedDescription)
                }
                self.refreshSessionHealth()
            }
        }
    }

    /// Public reconnect — resets auto-approve flag and backoff counter.
    /// Used by the UI "Reconnect" button.
    func reconnect() {
        hasRequestedAutoApprove = false
        reconnectAttempt = 0
        manualRecoveryState = .none
        if operatorSessionState != .connected { operatorSessionState = .connecting }
        nodeSessionState = .connecting
        refreshSessionHealth()
        reconnectInternal(trigger: "manual")
    }

    /// Forgets stored device-auth pairing tokens and reconnects, causing the
    /// next handshake to pair fresh. Used to recover from scope-upgrade
    /// rejection (#285, #320), invalid-signature errors (#229), and the
    /// auto-re-pair dispatcher (#306).
    ///
    /// Called from the Shared "Re-pair this device" button (user trigger)
    /// and from `dispatchPairingRecovery` (auto trigger).
    func resetPairing() {
        resetPairing(trigger: "user", localGateway: nil)
    }

    func resetPairing(localGateway: LocalGatewayManager?) {
        resetPairing(trigger: "user", localGateway: localGateway)
    }

    /// Re-pair with explicit trigger attribution. Stamps
    /// `inFlightRePairTrigger` so the UI can distinguish a silent auto
    /// recovery ("Re-pairing…") from a user-initiated one. Mirrors iOS
    /// `RemGatewaySessionManager.resetPairing(trigger:)` (minus PostHog).
    func resetPairing(trigger: String) {
        resetPairing(trigger: trigger, localGateway: nil)
    }

    func resetPairing(trigger: String, localGateway: LocalGatewayManager?) {
        inFlightRePairTrigger = trigger
        manualRecoveryState = .none
        lastConnectionDetail = nil
        nodeSessionState = .connecting
        if !operatorReady { operatorSessionState = .connecting }
        refreshSessionHealth()
        Task {
            if let localGateway, isActiveGatewayLocal {
                await localGateway.resetPairing(scope: .client) { [client] in
                    await client.resetPairing()
                }
            } else {
                await client.resetPairing()
            }
            hasRequestedAutoApprove = false
            reconnectAttempt = 0
            connectIfConfigured()
        }
    }

    /// Internal reconnect that preserves the auto-approve flag and backoff state.
    /// Used by keepalive, auto-reconnect, and wake-from-sleep. `trigger` only
    /// labels the connection-churn log (see MacGatewayClient socket logging).
    private func reconnectInternal(trigger: String = "reconnect") {
        Task {
            await client.setConnectTrigger(trigger)
            await client.disconnect()
            connectIfConfigured()
        }
    }

    // MARK: - Chat transport factory

    /// Creates an OpenClawChatTransport for use with OpenClawChatView.
    /// Uses the operator session (role: "operator") which has chat permissions.
    /// The transport probes the node before each send to catch silent drops.
    func makeChatTransport(
        quotaDispatchContext: MacQuotaDispatchContext? = nil,
        onChatSendAcknowledged: (@MainActor @Sendable (MacQuotaDispatchContext) -> Void)? = nil,
        onRunLifecycleEvidence: (@MainActor @Sendable (RunLifecycleEvidence) -> Void)? = nil,
        lifecycleEpochSource: RunLifecycleEpochSource? = nil,
        initialLifecycleLease: RunLifecycleTransportLease? = nil,
        onRunLifecycleEpoch: (@MainActor @Sendable (RunLifecycleEpoch) -> Void)? = nil
    ) async -> MacChatTransport {
        let session = await client.chatSession
        return MacChatTransport(
            gateway: session,
            onWillSend: { [weak self] in await self?.ensureNodeConnected() },
            quotaDispatchContext: quotaDispatchContext,
            onChatSendAcknowledged: onChatSendAcknowledged,
            onRunLifecycleEvidence: onRunLifecycleEvidence,
            lifecycleEpochSource: lifecycleEpochSource,
            initialLifecycleLease: initialLifecycleLease,
            onRunLifecycleEpoch: onRunLifecycleEpoch
        )
    }

    /// Probes the node session and reconnects if it has silently dropped.
    /// Called before each chat.send so device commands work when the AI responds.
    private func ensureNodeConnected() async {
        let alive = await client.testConnection()
        if !alive {
            log.warning("node probe failed before send, reconnecting...")
            reconnectInternal()
            // Poll until the node is back (up to 5s with 250ms intervals).
            // Reconnect involves TLS + auth + WebSocket handshake (typically 3-10s),
            // so a fixed 1s sleep would almost always proceed too early.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if await client.testConnection() {
                    log.info("node reconnected before send")
                    return
                }
            }
            log.warning("node still not connected after 5s, proceeding anyway")
        }
    }

    // MARK: - User Profile

    /// Fetches user profile from GET /api/v1/me and caches it.
    func fetchUserProfile() async {
        await ensureFreshToken()

        do {
            let (data, response) = try await MacAuthenticatedHttpClient.request(
                path: "/api/v1/me",
                method: "GET"
            )
            guard response.statusCode == 200 else { return }

            let profile = try JSONDecoder().decode(UserProfile.self, from: data)
            self.userProfile = profile
            Self.cacheProfile(profile)
        } catch {
            log.warning("fetchUserProfile failed: \(error.localizedDescription)")
        }
    }

    /// Restores cached user profile from UserDefaults (for instant display on launch).
    func restoreCachedProfile() {
        if let data = UserDefaults.standard.data(forKey: "cached_user_profile"),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            self.userProfile = profile
        }
    }

    private static func cacheProfile(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: "cached_user_profile")
        }
    }

    private static func clearCachedProfile() {
        UserDefaults.standard.removeObject(forKey: "cached_user_profile")
    }

    // MARK: - Usage

    /// Fetches usage summary from GET /api/v1/usage/summary.
    func fetchUsageSummary() async {
        let invocation = usageSummaryInvocationTracker.begin()
        // A view entry or explicit retry always starts a new truth request. Keep any prior payload
        // only as stale cache; presentation must show loading/error until this request succeeds.
        usageRequestAuthorityTracker.invalidate()
        usageSummaryIsStale = usageSummary != nil
        isLoadingUsage = true
        usageLoadError = nil

        await ensureFreshToken()

        // A newer explicit refresh supersedes this invocation even when task scheduling resumes
        // the older caller after the newer caller's token-refresh await.
        guard usageSummaryInvocationTracker.isCurrent(invocation) else { return }

        if let authenticationRecoveryError {
            usageRequestAuthorityTracker.invalidate()
            isLoadingUsage = false
            usageSummaryIsStale = usageSummary != nil
            usageLoadError = authenticationRecoveryError
            return
        }
        // A successful proactive refresh intentionally invalidates the pre-refresh request ticket.
        // Re-enter loading under the freshly committed token before issuing the summary request.
        isLoadingUsage = true
        usageLoadError = nil

        guard let base = backendURL, !base.isEmpty,
              let token = backendToken, !token.isEmpty,
              let url = URL(string: "\(base)/api/v1/usage/summary") else {
            usageRequestAuthorityTracker.invalidate()
            isLoadingUsage = false
            usageSummaryIsStale = usageSummary != nil
            usageLoadError = "Sign in again to load your plan and usage."
            return
        }

        let authority = usageRequestAuthorityTracker.begin(
            backendURL: base,
            backendToken: token
        )
        defer {
            if usageRequestAuthorityTracker.canCommit(
                authority,
                currentBackendURL: backendURL,
                currentBackendToken: backendToken
            ) {
                isLoadingUsage = false
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        ClientVersion.setHeaders(on: &request)

        do {
            let (data, response) = try await executeUsageRequest(request)
            guard usageRequestAuthorityTracker.canCommit(
                authority,
                currentBackendURL: backendURL,
                currentBackendToken: backendToken
            ) else { return }
            guard response.statusCode == 200 else {
                log.warning("fetchUsageSummary: HTTP \(response.statusCode)")
                usageSummaryIsStale = usageSummary != nil
                usageLoadError = "Rem couldn't load your plan and usage. Check your connection and try again."
                return
            }
            self.usageSummary = try JSONDecoder().decode(UsageSummary.self, from: data)
            usageSummaryIsStale = false
            usageLoadError = nil
        } catch {
            guard usageRequestAuthorityTracker.canCommit(
                authority,
                currentBackendURL: backendURL,
                currentBackendToken: backendToken
            ) else { return }
            log.warning("fetchUsageSummary failed: \(error.localizedDescription)")
            usageSummaryIsStale = usageSummary != nil
            usageLoadError = "Rem couldn't load your plan and usage. Check your connection and try again."
        }
    }

    private func retireUsageAuthority(clearSummary: Bool) {
        usageRequestAuthorityTracker.invalidate()
        usageSummaryInvocationTracker.invalidate()
        isLoadingUsage = false
        usageLoadError = nil
        usageSummaryIsStale = false
        if clearSummary {
            usageSummary = nil
        }
    }

    /// Performs account deletion by calling DELETE /api/v1/auth/me.
    /// Returns nil on success, or an error message on failure.
    func deleteAccount() async -> String? {
        await ensureFreshToken()

        guard let base = backendURL, !base.isEmpty,
              let token = backendToken, !token.isEmpty,
              let url = URL(string: "\(base)/api/v1/auth/me") else {
            return "Not authenticated"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        ClientVersion.setHeaders(on: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Invalid server response"
            }
            if (200...299).contains(http.statusCode) {
                return nil
            } else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                return "Failed to delete account: \(body)"
            }
        } catch {
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Linked devices

    /// Fetches the list of paired devices from the gateway.
    /// Updates `linkedDevices` on the main actor for UI consumption.
    func fetchLinkedDevices() {
        guard operatorReady else {
            log.debug("fetchLinkedDevices: operator not ready")
            return
        }
        guard !isLoadingLinkedDevices else { return }
        isLoadingLinkedDevices = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingLinkedDevices = false }

            do {
                let data = try await self.client.fetchPairedDevices()
                #if DEBUG
                let raw = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                log.debug("device.pair.list raw: \(raw)")
                #endif

                let decoder = JSONDecoder()
                var allDevices: [MacLinkedDevice] = []
                if let response = try? decoder.decode(MacLinkedDevicesResponse.self, from: data),
                   let paired = response.paired {
                    allDevices = paired
                } else if let devices = try? decoder.decode([MacLinkedDevice].self, from: data) {
                    allDevices = devices
                } else {
                    log.warning("fetchLinkedDevices: could not decode response")
                }

                // Filter stale one-time pairings — show current device, recently active, or full devices
                let filtered = allDevices.filter { device in
                    device.isCurrentDevice || device.isRecentlyActive || device.isFullDevice
                }
                log.debug("fetchLinkedDevices: \(allDevices.count) total, \(filtered.count) after filter")
                self.linkedDevices = filtered
            } catch {
                log.error("fetchLinkedDevices failed: \(error.localizedDescription)")
            }
        }
    }

    /// Unlinks (unpairs) a device from the gateway.
    ///
    /// Fixes #304 (Unlink Device on Mac doesn't remove the device from the list):
    ///   - Surfaces RPC errors to the UI via `pendingDeviceError` instead of
    ///     logging silently, so the user sees "please retry" instead of nothing.
    ///   - Waits briefly for the gateway to commit the removal before refresh,
    ///     avoiding the race where `fetchLinkedDevices()` runs against a stale
    ///     `paired.json` and shows the device as still present.
    ///   - After refresh, verifies the device actually dropped from the list
    ///     and surfaces a scope-hint if it didn't (likely an
    ///     `operator.pairing` scope issue on an old pairing — see #287).
    func unlinkDevice(_ device: MacLinkedDevice) {
        guard operatorReady else {
            pendingDeviceError = "Can't unlink — operator session not connected yet."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            self.pendingDeviceError = nil
            do {
                struct UnpairParams: Codable { var deviceId: String }
                let params = UnpairParams(deviceId: device.deviceId)
                let data = try JSONEncoder().encode(params)
                let json = String(data: data, encoding: .utf8)
                _ = try await self.client.chatSession.request(
                    method: "device.pair.remove",
                    paramsJSON: json,
                    timeoutSeconds: 10)
                log.info("unpaired device: \(device.deviceId)")

                // Give the gateway a moment to commit the removal to
                // `paired.json` before we refresh — without this the refresh
                // frequently races the commit and the device appears to
                // still be paired.
                try? await Task.sleep(for: .milliseconds(500))
                self.fetchLinkedDevices()

                // Verify the removal actually stuck. If the device is still
                // in the list after refresh, surface a hint: the most common
                // cause is a token minted before #287 (no `operator.pairing`
                // scope), in which case unlink silently no-ops gateway-side.
                try? await Task.sleep(for: .milliseconds(500))
                if self.linkedDevices.contains(where: { $0.deviceId == device.deviceId }) {
                    log.warning("unlink: device \(device.deviceId) still listed after refresh")
                    self.pendingDeviceError = "Unlink didn't stick. Try Re-pair this device, then try again."
                }
            } catch {
                log.error("unpair failed: \(error.localizedDescription)")
                self.pendingDeviceError = "Failed to unlink: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Pending devices

    /// Fetches the list of devices awaiting pairing approval from the gateway.
    /// Skips redundant fetches after the first successful load unless the list is empty.
    func fetchPendingDevices() async {
        guard operatorReady else {
            log.debug("fetchPendingDevices: operator not ready")
            pendingDeviceError = "Connect to the operator session first, then reopen approvals."
            return
        }
        guard !hasFetchedPendingDevices else { return }
        guard !isLoadingPendingDevices else { return }
        isLoadingPendingDevices = true
        defer { isLoadingPendingDevices = false }

        do {
            let data = try await client.fetchPairedDevices()
            let decoder = JSONDecoder()
            if let response = try? decoder.decode(PendingDevicesResponse.self, from: data),
               let pending = response.pending {
                log.debug("fetchPendingDevices: \(pending.count) pending")
                pendingDevices = pending
            } else {
                pendingDevices = []
            }
            if !pendingDevices.isEmpty {
                manualRecoveryState = .approvalRequired
            } else if operatorReady, !nodeSessionState.isConnected {
                manualRecoveryState = .nodeRetryRequired
            } else if manualRecoveryState == .approvalRequired {
                manualRecoveryState = .none
            }
            refreshSessionHealth()
            hasFetchedPendingDevices = true
        } catch {
            log.error("fetchPendingDevices failed: \(error.localizedDescription)")
            pendingDeviceError = "Failed to load approvals: \(error.localizedDescription)"
            refreshSessionHealth()
        }
    }

    /// Approves a pending device pairing request via the gateway operator session.
    func approveDevice(_ device: PendingDevice) {
        guard operatorReady else { return }

        Task { [weak self] in
            guard let self else { return }
            self.pendingDeviceError = nil
            do {
                struct ApproveParams: Codable { var requestId: String }
                let params = ApproveParams(requestId: device.requestId)
                let data = try JSONEncoder().encode(params)
                let json = String(data: data, encoding: .utf8)
                _ = try await self.client.chatSession.request(
                    method: "device.pair.approve",
                    paramsJSON: json,
                    timeoutSeconds: 10)
                log.info("approved device: \(device.requestId)")
                // Refresh both lists
                self.hasFetchedPendingDevices = false
                await self.fetchPendingDevices()
                self.fetchLinkedDevices()
                self.manualRecoveryState = .none
                self.refreshSessionHealth()
                self.reconnect()
            } catch {
                // A stale/unknown requestId means the request was already
                // resolved (most often by the backend auto-approve, which
                // approves *all* pending requests on `.pairingRequired`).
                // Treat it like success instead of surfacing a scary error.
                if DevicePairingErrorClassifier.isStaleRequest(error) {
                    log.info("approve: requestId already resolved (stale), reconciling")
                    self.hasFetchedPendingDevices = false
                    await self.fetchPendingDevices()
                    self.fetchLinkedDevices()
                    self.manualRecoveryState = .none
                    self.refreshSessionHealth()
                    self.reconnect()
                    return
                }
                self.pendingDeviceError = "Failed to approve device: \(error.localizedDescription)"
                log.error("approve failed: \(error.localizedDescription)")
                self.refreshSessionHealth()
            }
        }
    }

    /// Declines (rejects) a pending device pairing request.
    func declineDevice(_ device: PendingDevice) {
        guard operatorReady else { return }

        Task { [weak self] in
            guard let self else { return }
            self.pendingDeviceError = nil
            do {
                struct RejectParams: Codable { var requestId: String }
                let params = RejectParams(requestId: device.requestId)
                let data = try JSONEncoder().encode(params)
                let json = String(data: data, encoding: .utf8)
                _ = try await self.client.chatSession.request(
                    method: "device.pair.reject",
                    paramsJSON: json,
                    timeoutSeconds: 10)
                log.info("declined device: \(device.requestId)")
                self.hasFetchedPendingDevices = false
                await self.fetchPendingDevices()
            } catch {
                // Same stale-requestId reasoning as approveDevice: an already
                // resolved request is a no-op success, not an error.
                if DevicePairingErrorClassifier.isStaleRequest(error) {
                    log.info("decline: requestId already resolved (stale), refreshing")
                    self.hasFetchedPendingDevices = false
                    await self.fetchPendingDevices()
                    return
                }
                self.pendingDeviceError = "Failed to decline device: \(error.localizedDescription)"
                log.error("decline failed: \(error.localizedDescription)")
                self.refreshSessionHealth()
            }
        }
    }

    // MARK: - Shared health snapshot

    private func refreshSessionHealth() {
        let detail = lastConnectionDetail
            ?? nodeSessionState.detail
            ?? {
                if case .failed(let msg) = gatewayProcessState { return msg }
                return nil
            }()

        let processState: GatewayProcessState = localGatewayURL != nil
            ? gatewayProcessState
            : (connectionState.isConnected ? .running : .unknown)

        sessionHealth = GatewaySessionHealthSnapshot.compose(
            operatorSessionState: operatorSessionState,
            nodeSessionState: nodeSessionState,
            gatewayProcessState: processState,
            manualRecoveryState: manualRecoveryState,
            detail: detail
        )
    }

    private func updateLocalGatewayProcessState(localURL: String, fallbackError: String?) async {
        guard var components = URLComponents(string: localURL) else {
            gatewayProcessState = .failed(fallbackError)
            return
        }

        components.path = "/health"
        guard let healthURL = components.url else {
            gatewayProcessState = .failed(fallbackError)
            return
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                gatewayProcessState = .running
            } else {
                gatewayProcessState = .stopped
            }
        } catch {
            gatewayProcessState = .failed(fallbackError ?? error.localizedDescription)
        }
    }
}

enum MacBackendCredentialPersistenceError: Error, LocalizedError, Equatable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

// MARK: - Connection state
// MacConnectionState is now a typealias for GatewayConnectionState
// defined in Shared/Protocols/GatewaySessionProviding.swift

// MARK: - Apple Sign In Delegate (macOS)

struct MacAppleSignInResult {
    let idToken: String
    let authorizationCode: String?
    let givenName: String?
    let familyName: String?
}

private class MacAppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let continuation: CheckedContinuation<MacAppleSignInResult, Error>

    init(continuation: CheckedContinuation<MacAppleSignInResult, Error>) {
        self.continuation = continuation
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
           let identityToken = credential.identityToken,
           let idTokenString = String(data: identityToken, encoding: .utf8) {
            let authorizationCode: String?
            if let authorizationCodeData = credential.authorizationCode {
                authorizationCode = String(data: authorizationCodeData, encoding: .utf8)
            } else {
                authorizationCode = nil
            }
            continuation.resume(returning: MacAppleSignInResult(
                idToken: idTokenString,
                authorizationCode: authorizationCode,
                givenName: credential.fullName?.givenName,
                familyName: credential.fullName?.familyName
            ))
        } else {
            continuation.resume(throwing: MacGatewayError.notConnected)
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation.resume(throwing: error)
    }
}

// MARK: - Google Sign In Presentation Provider (macOS)

/// Provides the presentation anchor (NSWindow) for ASWebAuthenticationSession.
private class GoogleSignInPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleSignInPresentationProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}

// MARK: - Linked Device Model (Mac)
// MacLinkedDevice, MacDevicePlatform, MacDeviceToken are now typealiases for
// shared types defined in Shared/Models/LinkedDevice.swift.
// See Shared/Protocols/GatewaySessionConformance.swift for typealiases.
