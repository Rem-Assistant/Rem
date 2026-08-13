import Foundation
import OpenClawKit

// MARK: - Shared Connection State

/// Unified connection state used by both iOS and macOS targets.
/// Replaces `RemGatewayConnectionState` (iOS) and `MacConnectionState` (Mac).
enum GatewayConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case unauthorized
    case pairingRequired
    case unreachable(String? = nil)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .unauthorized: "Unauthorized"
        case .pairingRequired: "Approval Pending"
        case .unreachable(let detail): "Unreachable\(detail.map { ": \($0)" } ?? "")"
        }
    }

    /// A SHORT status for compact chrome (settings-row badges, chips). Unlike `statusText`, the
    /// `.unreachable` case never appends the raw wire detail — that detail is a low-level error
    /// string ("connect failed … Swift.CancellationError") that cram-wraps sideways in a one-line
    /// badge and leaks jargon. The full detail belongs in the gateway detail screen, not the badge.
    var shortStatusText: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Waking up…"
        case .connected: "Connected"
        case .unauthorized: "Sign-in needed"
        case .pairingRequired: "Approval pending"
        case .unreachable: "Can't reach Rem"
        }
    }

    var needsDeviceRePair: Bool {
        switch self {
        case .pairingRequired, .unauthorized:
            return true
        case .unreachable(let detail):
            return GatewayPairingFailure.from(reasonString: detail).isTrustRevocation
        case .disconnected, .connecting, .connected:
            return false
        }
    }
}

// MARK: - Per-session Health

/// Health for one gateway leg (operator or node).
enum GatewaySessionLegState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String? = nil)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Failed"
        }
    }

    var detail: String? {
        if case .failed(let detail) = self { return detail }
        return nil
    }
}

/// Health for the local gateway process (best-effort for cloud gateways).
enum GatewayProcessState: Equatable, Sendable {
    case unknown
    case starting
    case running
    case stopped
    case failed(String? = nil)

    var label: String {
        switch self {
        case .unknown: "Unknown"
        case .starting: "Starting"
        case .running: "Running"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }
}

/// Deterministic recovery hints for unavailable states.
enum GatewayRecoveryHint: String, Equatable, Sendable {
    case reconnect
    case rePairThisDevice
    case openApprovalsList
    case retryNodeConnection
    case restartLocalGateway
}

/// High-level manual recovery mode shown in UI.
enum GatewayManualRecoveryState: Equatable, Sendable {
    case none
    case approvalRequired
    case rePairRequired
    case nodeRetryRequired
}

/// Shared health snapshot surfaced by both iOS and macOS managers.
struct GatewaySessionHealthSnapshot: Equatable, Sendable {
    var operatorSessionState: GatewaySessionLegState
    var nodeSessionState: GatewaySessionLegState
    var gatewayProcessState: GatewayProcessState
    var manualRecoveryState: GatewayManualRecoveryState
    var recoveryHints: [GatewayRecoveryHint]
    var detail: String?

    var operatorUsable: Bool {
        operatorSessionState.isConnected
    }
}

extension GatewaySessionHealthSnapshot {
    /// Shared hint synthesis so iOS and macOS can construct consistent
    /// recovery actions from structured per-leg states.
    static func compose(
        operatorSessionState: GatewaySessionLegState,
        nodeSessionState: GatewaySessionLegState,
        gatewayProcessState: GatewayProcessState,
        manualRecoveryState: GatewayManualRecoveryState,
        detail: String?
    ) -> GatewaySessionHealthSnapshot {
        var hints: [GatewayRecoveryHint] = []

        func add(_ hint: GatewayRecoveryHint) {
            if !hints.contains(hint) {
                hints.append(hint)
            }
        }

        if !operatorSessionState.isConnected {
            add(.reconnect)
        }

        switch manualRecoveryState {
        case .none:
            break
        case .approvalRequired:
            add(.openApprovalsList)
            add(.rePairThisDevice)
        case .rePairRequired:
            add(.rePairThisDevice)
        case .nodeRetryRequired:
            add(.retryNodeConnection)
            add(.rePairThisDevice)
        }

        switch gatewayProcessState {
        case .stopped, .failed(_):
            add(.restartLocalGateway)
        default:
            break
        }

        return GatewaySessionHealthSnapshot(
            operatorSessionState: operatorSessionState,
            nodeSessionState: nodeSessionState,
            gatewayProcessState: gatewayProcessState,
            manualRecoveryState: manualRecoveryState,
            recoveryHints: hints,
            detail: detail
        )
    }
}

// MARK: - Gateway Session Protocol

/// Protocol that both `RemGatewaySessionManager` (iOS) and
/// `MacGatewaySessionManager` (macOS) conform to, enabling shared
/// settings views across platforms.
@MainActor
protocol GatewaySessionProviding: AnyObject, Observable {
    var connectionState: GatewayConnectionState { get }
    var sessionHealth: GatewaySessionHealthSnapshot { get }
    var gatewayHostDisplay: String? { get }
    var operatorReady: Bool { get }
    /// Monotonic identity of the exact operator-session/auth context serving RPCs. This must
    /// advance before replacing credentials or a socket, including same-URL token/account swaps.
    var operatorSessionGeneration: UInt64 { get }
    var skillsSnapshotVersion: Int { get }
    var isAutoRePairInProgress: Bool { get }
    var supportsExplicitPairingApproval: Bool { get }
    var isConfigured: Bool { get }
    var isAuthenticated: Bool { get }

    // Linked devices
    var linkedDevices: [LinkedDevice] { get }
    var isLoadingLinkedDevices: Bool { get }
    func fetchLinkedDevices()
    func unlinkDevice(_ device: LinkedDevice)

    // Pending devices (awaiting approval)
    var pendingDevices: [PendingDevice] { get }
    var isLoadingPendingDevices: Bool { get }
    var pendingDeviceError: String? { get set }
    func fetchPendingDevices() async
    func approveDevice(_ device: PendingDevice)
    func declineDevice(_ device: PendingDevice)

    // Connection lifecycle
    func reconnect()
    func connectIfConfigured()
    func clearConfiguration()
    func configure(gatewayURL: String, gatewayToken: String)
    func configure(gatewayConfig: GatewayConfig)
    func signOut()

    /// Forgets stored device-auth pairing tokens and reconnects so the next
    /// handshake pairs fresh. Recovers from scope-upgrade rejection (#285)
    /// and invalid-signature errors (#229). Platforms that don't manage
    /// device-auth tokens can no-op.
    func resetPairing()

    /// Context-aware re-pair entry point for shared detail views. Platforms
    /// that can repair provider-managed credentials should use `config` and
    /// `configStore`; the default implementation falls back to device-local
    /// pairing reset.
    func resetPairing(config: GatewayConfig?, configStore: GatewayConfigStore?) async throws -> String?

    /// Requests approval for an already-pending pairing without clearing this
    /// device's token. Managed cloud gateways can use this to expose an
    /// explicit "finish connection" action instead of relying on polling only.
    func requestPairingApproval(config: GatewayConfig?) async throws -> String?

    /// Reads backend-owned update readiness metadata for the authenticated
    /// account. Implementations may return nil when unavailable; shared UI
    /// falls back to local provider-based copy and never enables mutation.
    func fetchGatewayUpdateReadiness() async throws -> GatewayUpdateReadiness?

    // Stored credentials (for gateway list/migration)
    var storedGatewayURL: String? { get }
    var storedGatewayToken: String? { get }
    var activeLocalGatewayURL: String? { get }
    var activeLocalGatewayToken: String? { get }
    var activeGatewayProviderForDisplay: GatewayProvider? { get }
    /// Stable backend JWT subject used to discard a recovery response after account change.
    var authenticatedAccountIDForRecovery: String? { get }
    /// Captures an opaque immutable account/token authority before launching long-lived recovery.
    /// The bearer token remains inside the platform-provided operation closure.
    func makeVoiceConfigurationRecoveryRequest() -> VoiceConfigurationRecoveryRequest?

    // Skills RPC (chat session access)
    //
    // Default timeout (via extension below) is suitable for quick queries
    // (skills.status, skills.search, skills.detail, skills.update). Long-running
    // operations like skills.install should pass a larger timeout explicitly —
    // ClawHub downloads can take tens of seconds, and the upstream web UI uses
    // 120s for generic installs (see openclaw/ui/src/ui/controllers/skills.ts
    // installSkill/installFromClawHub).
    func skillsRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data

    /// Returns provider ids backed by usable authentication in the active runtime. Managed Rem
    /// gateways use the structured `models.authAvailability` RPC; a platform running an upstream
    /// local gateway may override this requirement with that runtime's own auth-profile source.
    func loadRuntimeConfiguredProviderIDs(candidateProviderIDs: [String]) async throws -> [String]

    /// Patch the gateway config VIA THE BACKEND and RESTART the gateway so the change takes effect.
    /// Needed for config the running gateway only resolves at STARTUP (the browser SSRF policy is
    /// resolved once at boot; an operator `config.patch` writes the file but doesn't hot-reload it —
    /// verified: the browser stayed restricted until the gateway restarted). `configPatchJSON` is a
    /// JSON merge-patch object, e.g. `{"browser":{"ssrfPolicy":{"hostnameAllowlist":[…]}}}`. Default
    /// throws `unsupported`; iOS posts to the backend `/api/v1/patch-config` (patch + restart).
    func patchGatewayConfigViaBackendAndRestart(configPatchJSON: String) async throws

}

/// Thrown by the default `patchGatewayConfigViaBackendAndRestart` where no backend orchestration is
/// wired (e.g. self-managed Mac gateways).
struct GatewayBackendPatchUnsupported: LocalizedError {
    var errorDescription: String? { "Changing this setting isn't available on this platform yet." }
}

extension GatewaySessionProviding {
    var operatorSessionGeneration: UInt64 { 0 }
    var isAutoRePairInProgress: Bool { false }
    var supportsExplicitPairingApproval: Bool { false }
    var activeLocalGatewayURL: String? { nil }
    var activeLocalGatewayToken: String? { nil }
    var activeGatewayProviderForDisplay: GatewayProvider? {
        if activeLocalGatewayURL != nil {
            return .local
        }
        guard let storedGatewayURL,
              let host = URL(string: storedGatewayURL)?.host?.lowercased() else {
            return nil
        }
        if host.hasSuffix(".fly.dev") {
            return .fly
        }
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasSuffix(".local") {
            return .local
        }
        return nil
    }
    var authenticatedAccountIDForRecovery: String? { nil }

    func makeVoiceConfigurationRecoveryRequest() -> VoiceConfigurationRecoveryRequest? { nil }

    func configure(gatewayConfig: GatewayConfig) {
        configure(gatewayURL: gatewayConfig.url, gatewayToken: gatewayConfig.token)
    }

    func resetPairing(config: GatewayConfig?, configStore: GatewayConfigStore?) async throws -> String? {
        resetPairing()
        return nil
    }

    func requestPairingApproval(config: GatewayConfig?) async throws -> String? {
        nil
    }

    func fetchGatewayUpdateReadiness() async throws -> GatewayUpdateReadiness? {
        nil
    }

    /// Backward-compatible overload: default 10s timeout for quick RPCs.
    func skillsRequest(method: String, paramsJSON: String?) async throws -> Data {
        try await skillsRequest(method: method, paramsJSON: paramsJSON, timeoutSeconds: 10)
    }

    func patchGatewayConfigViaBackendAndRestart(configPatchJSON: String) async throws {
        throw GatewayBackendPatchUnsupported()
    }

}
