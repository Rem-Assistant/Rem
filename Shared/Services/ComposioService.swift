import Foundation

/// Read/connect surface for Composio connectors, including account-backed messaging tools such as
/// Slack, Discord Bot, WhatsApp Business, and Telegram.
///
/// Composio OAuth completes on the USER'S OWN device: `connect` returns a Composio-hosted Connect
/// Link the app opens in the system browser via SwiftUI `openURL` (not an in-app web view — there's
/// no cookie-shared sheet to auto-dismiss, so we poll `status` after the user returns instead of
/// catching an app-owned redirect callback). Composio captures the token on its own callback. The
/// agent then uses the connected tools via Composio's per-user hosted MCP wired into the gateway
/// (backend side).
///
/// Hits `/api/v1/composio/*`. Reuses the app's authenticated HTTP client for base-URL + JWT +
/// 401-refresh, exactly like `CheckinsService` (same `#if os(iOS)` transport split, no new auth path).
@MainActor
public protocol ComposioProviding: AnyObject {
    /// Toolkits enriched with branding (logoUrl) and this user's current per-toolkit connection
    /// status, plus whether the backend has Composio configured (COMPOSIO_API_KEY set).
    func toolkits() async throws -> ComposioToolkitsResponse
    /// Start an OAuth connect for `toolkit`. `callbackURL` is where Composio returns the user after
    /// provider consent (a Rem deep link so the app can dismiss the web session). Returns the
    /// Composio-hosted Connect Link + the connection id to poll.
    func connect(toolkit: String, callbackURL: String?) async throws -> ComposioConnectSession
    /// Poll a connection request's status after the user finishes the web flow. `toolkit` is the
    /// slug being connected — sent so the backend reports the right connector in pending/failed
    /// states instead of defaulting to Gmail.
    func status(connectionId: String, toolkit: String) async throws -> ComposioConnectionState
    /// Disconnect (revoke) a toolkit. Deletes+revokes EVERY active Composio connected account for
    /// this toolkit (scoped to the user), revoking the upstream provider grant so Rem can no longer
    /// act in it. Idempotent — succeeds even when nothing was connected.
    func disconnect(toolkit: String) async throws -> ComposioMutationResult
    /// Pause/resume a toolkit — the NON-destructive counterpart to `disconnect`. `enabled: false`
    /// disables EVERY active account (the OAuth token is KEPT; the agent just can't use it);
    /// `enabled: true` re-enables instantly with no re-auth. Idempotent. See backend
    /// `setToolkitEnabled` for why a paused account truly blocks the agent's MCP tools.
    func setEnabled(toolkit: String, enabled: Bool) async throws -> ComposioMutationResult
}

// MARK: - Wire models (match backend composio.routes.ts)

/// One toolkit row as returned by `GET /composio/toolkits` (#1069 logo, #1082 per-user status).
public struct ComposioToolkitSummary: Decodable, Sendable, Identifiable, Equatable {
    public let slug: String
    /// Branding image URL from Composio's toolkit metadata. `nil` when the backend couldn't fetch
    /// it (e.g. a transient Composio API error) — the view falls back to its own SF Symbol.
    public let logoUrl: String?
    /// "connected" | "pending" | "failed" | "unknown" | "not_connected"
    public let status: String
    /// Whether the provider grant is ACTIVE vs PAUSED (all accounts `disable()`d). Runtime
    /// readiness is reported separately on `ComposioToolkitsResponse`.
    public let enabled: Bool?

    public var id: String { slug }
    public var isConnected: Bool { status == "connected" }
    /// A connected toolkit is available unless the backend explicitly says it's paused.
    public var isEnabled: Bool { enabled ?? true }
}

public struct ComposioToolkitsResponse: Decodable, Sendable {
    public let configured: Bool
    public let toolkits: [ComposioToolkitSummary]
    /// Whether the gateway has acknowledged the current hosted-MCP account scope. Missing on an
    /// older backend is conservatively not ready; ACTIVE grant state alone is not agent readiness.
    public let runtimeReady: Bool?
    /// True when reconciliation exceeded the bounded HTTP observation window and continues in the
    /// backend's per-user lane. A later catalog read can promote this to `runtimeReady`.
    public let runtimeSyncing: Bool?

    public var isRuntimeReady: Bool { runtimeReady == true }
    public var isRuntimeSyncing: Bool { runtimeReady != true && runtimeSyncing == true }
}

public struct ComposioConnectSession: Decodable, Sendable {
    public let redirectUrl: String
    public let connectionId: String
    public let toolkit: String
}

public struct ComposioConnectionState: Decodable, Sendable, Equatable {
    /// The toolkit slug. Optional because the backend honestly returns `null` when it can't
    /// determine the toolkit (a failed/pending poll without the slug) rather than asserting Gmail.
    public let toolkit: String?
    /// "pending" | "connected" | "failed" | "unknown"
    public let status: String
    public let connectedAccountId: String?
    /// Whether the provider grant is ACTIVE. This does not assert gateway runtime readiness.
    public let enabled: Bool?
    /// Whether the gateway runtime has acknowledged this account scope. Kept distinct from
    /// `enabled`, which is only the provider grant's ACTIVE/INACTIVE state.
    public let runtimeReady: Bool?
    public let runtimeSyncing: Bool?

    public init(
        toolkit: String?,
        status: String,
        connectedAccountId: String?,
        enabled: Bool? = nil,
        runtimeReady: Bool? = nil,
        runtimeSyncing: Bool? = nil
    ) {
        self.toolkit = toolkit
        self.status = status
        self.connectedAccountId = connectedAccountId
        self.enabled = enabled
        self.runtimeReady = runtimeReady
        self.runtimeSyncing = runtimeSyncing
    }

    public var isConnected: Bool { status == "connected" }
    /// A connected connection is available unless explicitly paused.
    public var isEnabled: Bool { enabled ?? true }
    public var isRuntimeReady: Bool { runtimeReady == true }
    public var isRuntimeSyncing: Bool { runtimeReady != true && runtimeSyncing == true }
}

public enum ComposioRuntimeState: Equatable, Sendable {
    case ready
    case syncing
    case unavailable
}

public enum ComposioMutationStatus: Decodable, Sendable, Equatable {
    case completed
    case accepted
    case unknown
    case rejected
    case unrecognized(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw.lowercased() {
        case "completed": .completed
        case "accepted": .accepted
        case "unknown": .unknown
        case "rejected": .rejected
        default: .unrecognized(raw)
        }
    }
}

public struct ComposioMutationResult: Decodable, Sendable, Equatable {
    public let mutationStatus: ComposioMutationStatus?
    public let mutationAccepted: Bool?
    public let mutationCompleted: Bool?
    public let runtimeReady: Bool?
    public let runtimeSyncing: Bool?

    public init(
        mutationStatus: ComposioMutationStatus = .completed,
        mutationAccepted: Bool = true,
        mutationCompleted: Bool = true,
        runtimeReady: Bool,
        runtimeSyncing: Bool = false
    ) {
        self.mutationStatus = mutationStatus
        self.mutationAccepted = mutationAccepted
        self.mutationCompleted = mutationCompleted
        self.runtimeReady = runtimeReady
        self.runtimeSyncing = runtimeSyncing
    }

    public var isAccepted: Bool {
        switch mutationStatus {
        case .completed, .accepted: true
        case .unknown, .rejected, .unrecognized(_): false
        case nil: mutationAccepted != false
        }
    }
    public var isCompleted: Bool {
        switch mutationStatus {
        case .completed: true
        case .accepted, .unknown, .rejected, .unrecognized(_): false
        case nil: mutationCompleted != false
        }
    }
    public var isOutcomeUnknown: Bool { mutationStatus == .unknown }
    public var isRuntimeReady: Bool { runtimeReady == true }
    public var runtimeState: ComposioRuntimeState {
        if runtimeReady == true { return .ready }
        if runtimeSyncing == true { return .syncing }
        return .unavailable
    }
}

// MARK: - Concrete (backend REST)

@MainActor
public final class ComposioService: ComposioProviding {

    private let decoder = JSONDecoder()
    private let basePath = "/api/v1/composio"

    public init() {}

    public func toolkits() async throws -> ComposioToolkitsResponse {
        let (data, http) = try await Self.request(path: "\(basePath)/toolkits", method: "GET")
        try Self.check(http, data: data)
        return try decoder.decode(ComposioToolkitsResponse.self, from: data)
    }

    public func connect(toolkit: String, callbackURL: String?) async throws -> ComposioConnectSession {
        var payload: [String: String] = ["toolkit": toolkit]
        if let cb = callbackURL, !cb.isEmpty { payload["callbackUrl"] = cb }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await Self.request(path: "\(basePath)/connect", method: "POST", body: body)
        try Self.check(http, data: data)
        return try decoder.decode(ComposioConnectSession.self, from: data)
    }

    public func status(connectionId: String, toolkit: String) async throws -> ComposioConnectionState {
        let encoded = connectionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? connectionId
        let toolkitQuery = toolkit.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? toolkit
        let (data, http) = try await Self.request(path: "\(basePath)/status/\(encoded)?toolkit=\(toolkitQuery)", method: "GET")
        try Self.check(http, data: data)
        return try decoder.decode(ComposioConnectionState.self, from: data)
    }

    public func disconnect(toolkit: String) async throws -> ComposioMutationResult {
        let encoded = toolkit.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? toolkit
        let (data, http) = try await Self.request(path: "\(basePath)/toolkit/\(encoded)/connections", method: "DELETE")
        try Self.check(http, data: data)
        return try decoder.decode(ComposioMutationResult.self, from: data)
    }

    public func setEnabled(toolkit: String, enabled: Bool) async throws -> ComposioMutationResult {
        let encoded = toolkit.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? toolkit
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        let (data, http) = try await Self.request(path: "\(basePath)/toolkit/\(encoded)/enabled", method: "POST", body: body)
        try Self.check(http, data: data)
        return try decoder.decode(ComposioMutationResult.self, from: data)
    }

    // MARK: Transport (platform-split, mirrors CheckinsService)

    private static func request(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        #if os(iOS)
        return try await AuthenticatedHttpClient.request(path: path, method: method, body: body)
        #else
        return try await MacAuthenticatedHttpClient.request(path: path, method: method, body: body)
        #endif
    }

    private static func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw ComposioServiceError.requestFailed(statusCode: response.statusCode, message: message)
        }
    }
}

public enum ComposioServiceError: LocalizedError {
    case requestFailed(statusCode: Int, message: String?)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(code, message):
            return message ?? "Request failed (HTTP \(code))"
        case .notConfigured:
            return "Connections aren't available yet."
        }
    }
}

// MARK: - Mock (previews)

@MainActor
public final class MockComposioService: ComposioProviding {
    public var configured: Bool
    public var simulatedDelay: Duration
    private var connected: Set<String> = []
    /// Connected-but-paused toolkits (switch off). Distinct from `connected` so a preview can show
    /// the Connected•Paused state and dimmed logo.
    private var paused: Set<String> = []

    public init(
        configured: Bool = true,
        simulatedDelay: Duration = .milliseconds(250),
        connected: Set<String> = [],
        paused: Set<String> = []
    ) {
        self.configured = configured
        self.simulatedDelay = simulatedDelay
        self.connected = connected
        self.paused = paused
    }

    public func toolkits() async throws -> ComposioToolkitsResponse {
        try? await Task.sleep(for: simulatedDelay)
        // Mirrors backend COMPOSIO_TOOLKITS (composio.service.ts) so previews exercise the full
        // connector list, not just the original three.
        let slugs = [
            "gmail", "googlecalendar", "googledrive", "googledocs", "googlesheets",
            "github", "slack", "discord", "discordbot", "whatsapp", "telegram",
            "notion", "linear", "todoist", "asana",
        ]
        return ComposioToolkitsResponse(
            configured: configured,
            toolkits: slugs.map {
                let isConnected = connected.contains($0)
                return ComposioToolkitSummary(
                    slug: $0,
                    logoUrl: "https://logos.composio.dev/api/\($0)",
                    status: isConnected ? "connected" : "not_connected",
                    enabled: isConnected ? !paused.contains($0) : false
                )
            },
            runtimeReady: true,
            runtimeSyncing: false
        )
    }

    public func connect(toolkit: String, callbackURL: String?) async throws -> ComposioConnectSession {
        try? await Task.sleep(for: simulatedDelay)
        return ComposioConnectSession(
            redirectUrl: "https://connect.composio.dev/link/ln_preview_\(toolkit)",
            connectionId: "conn_preview_\(toolkit)",
            toolkit: toolkit)
    }

    public func status(connectionId: String, toolkit: String) async throws -> ComposioConnectionState {
        try? await Task.sleep(for: simulatedDelay)
        connected.insert(toolkit)
        paused.remove(toolkit)
        return ComposioConnectionState(
            toolkit: toolkit,
            status: "connected",
            connectedAccountId: "acct_preview_\(toolkit)",
            enabled: true,
            runtimeReady: true,
            runtimeSyncing: false
        )
    }

    public func disconnect(toolkit: String) async throws -> ComposioMutationResult {
        try? await Task.sleep(for: simulatedDelay)
        connected.remove(toolkit)
        paused.remove(toolkit)
        return ComposioMutationResult(runtimeReady: true)
    }

    public func setEnabled(toolkit: String, enabled: Bool) async throws -> ComposioMutationResult {
        try? await Task.sleep(for: simulatedDelay)
        if enabled { paused.remove(toolkit) } else { paused.insert(toolkit) }
        return ComposioMutationResult(runtimeReady: true)
    }
}
