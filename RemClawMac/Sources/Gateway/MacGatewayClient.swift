import Foundation
import os
import OpenClawKit
import OpenClawProtocol

/// Always-on logger for Mac gateway WebSocket lifecycle events. Parity with
/// iOS `gateway-conn` so the same churn evidence (trigger + role + running
/// socket tally) is captured in Mac device logs. See #connection-reliability.
private let macGatewayConnLog = Logger(subsystem: "app.remclaw.mac", category: "gateway-conn")

/// Gateway connection for Rem for Mac.
///
/// Manages two simultaneous WebSocket connections:
/// 1. **Node session** (`role: "node"`, `clientMode: "node"`) -- advertises
///    device capabilities (shell, clipboard, files) so the AI can invoke them.
/// 2. **Operator session** (`role: "operator"`, `clientMode: "ui"`) -- used for
///    chat transport (chat.send, chat.history, sessions.list) and skills config.
///
/// Uses the same GatewayNodeSession from OpenClawKit for both roles.
actor MacGatewayClient {
    // Primary node connection -- device capabilities
    private let nodeSession = GatewayNodeSession()
    // Secondary operator connection -- chat + config
    private let operatorSession = GatewayNodeSession()
    private var nodeConnected = false
    private var operatorConnected = false

    // MARK: - Connection-churn instrumentation (#connection-reliability)

    /// Running tally of node/operator WebSockets we have explicitly opened but
    /// not yet closed. Steady state is 2; a persistent climb above 2 means a
    /// reconnect path is leaking sockets. Adjusted only at explicit open/close
    /// call sites.
    private var liveSocketTally = 0
    private var connectTrigger = "launch"

    func setConnectTrigger(_ trigger: String) { connectTrigger = trigger }

    private func logSocketOpen(role: String) {
        liveSocketTally += 1
        macGatewayConnLog.log(
            "ws OPEN role=\(role, privacy: .public) trigger=\(self.connectTrigger, privacy: .public) live=\(self.liveSocketTally, privacy: .public)")
    }

    private func logSocketClose(role: String) {
        liveSocketTally = max(0, liveSocketTally - 1)
        macGatewayConnLog.log(
            "ws CLOSE role=\(role, privacy: .public) trigger=\(self.connectTrigger, privacy: .public) live=\(self.liveSocketTally, privacy: .public)")
    }

    private func logSocketDrop(role: String, reason: String) {
        macGatewayConnLog.log(
            "ws DROP role=\(role, privacy: .public) trigger=\(self.connectTrigger, privacy: .public) live=\(self.liveSocketTally, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private(set) var connectionState: MacConnectionState = .disconnected

    /// Last disconnect reason string reported by either node or operator
    /// session. Fallback signal for the session manager's pairing classifier
    /// when no structured error is available. Cleared on successful connect
    /// so stale reasons don't leak across sessions. See #306 (Pairing
    /// recovery UX epic) and #320 (Widen Mac operator scope to operator.admin).
    private(set) var lastDisconnectReason: String?

    /// Structured error captured from the most recent connect-throw.
    /// Carries `GatewayConnectAuthError.detail` (typed `DEVICE_AUTH_*` code)
    /// and `detailsReason` ("scope-upgrade" / "role-upgrade" /
    /// "metadata-upgrade") so the Mac session manager can classify pairing
    /// failures via the upstream typed `GatewayConnectionProblemMapper`
    /// instead of substring-matching `error.localizedDescription`.
    /// Cleared on successful connect. Mirrors `RemGatewayClient.lastConnectError`.
    private(set) var lastConnectError: Error?

    private(set) var onStateChange: (@Sendable (MacConnectionState) async -> Void)?

    /// Callback fired when the operator session connects or disconnects.
    private(set) var onOperatorStateChange: (@Sendable (Bool) async -> Void)?

    /// Callback fired when the node session connects or disconnects.
    private(set) var onNodeStateChange: (@Sendable (Bool) async -> Void)?

    /// Callback fired when a skills.snapshot.changed event is received.
    private(set) var onSkillsChanged: (@Sendable () async -> Void)?

    func setOnStateChange(_ handler: (@Sendable (MacConnectionState) async -> Void)?) {
        onStateChange = handler
    }

    func setOnOperatorStateChange(_ handler: (@Sendable (Bool) async -> Void)?) {
        onOperatorStateChange = handler
    }

    func setOnNodeStateChange(_ handler: (@Sendable (Bool) async -> Void)?) {
        onNodeStateChange = handler
    }

    func setOnSkillsChanged(_ handler: (@Sendable () async -> Void)?) {
        onSkillsChanged = handler
    }

    // MARK: - Connect / Disconnect

    /// Connect to a gateway.
    ///
    /// - Parameters:
    ///   - gatewayURL: HTTP/WS URL of the gateway.
    ///   - token: gateway credential (long-lived shared token by default; a
    ///     short-lived bootstrap credential when `isBootstrap == true`).
    ///   - isBootstrap: when `true`, `token` is routed to OpenClawKit's
    ///     `bootstrapToken:` slot (`auth.bootstrapToken` on the wire,
    ///     triggering the upstream pair-bootstrap → device-token handshake;
    ///     see `GatewayChannel.swift:430-440, 545-607`). When `false` (the
    ///     default), the token is routed to `token:` as today.
    ///
    ///     Plumbed in #300a; the only caller (`MacGatewaySessionManager`)
    ///     does NOT pass it yet, so every existing path still hits the
    ///     `false` branch and behavior is unchanged. #300b is where the
    ///     Mac emitter starts producing upstream-format setup codes that
    ///     decode with `GatewayConfig.isBootstrap == true`.
    func connect(
        gatewayURL: URL,
        token: String,
        isBootstrap: Bool = false
    ) async throws {
        await setState(.connecting)

        // Close-before-open: never stack a second socket pair on a live
        // connection. Reconnects go through disconnect() first, but this covers
        // a direct connect-on-top path. (#connection-reliability)
        if nodeConnected || operatorConnected {
            if nodeConnected { logSocketClose(role: "node") }
            if operatorConnected { logSocketClose(role: "operator") }
            await nodeSession.disconnect()
            await operatorSession.disconnect()
            nodeConnected = false
            operatorConnected = false
        }

        let wsURL = Self.webSocketURL(from: gatewayURL)
        guard let url = wsURL else {
            await setState(.unreachable("Invalid gateway URL"))
            throw MacGatewayError.invalidURL
        }

        // #300a: `isBootstrap` selects which auth slot the token rides in.
        // Today this is always false; #300b is where it starts flipping true
        // for upstream-format setup codes from the Mac emitter.
        let useBootstrap = isBootstrap
        let connectToken: String? = useBootstrap ? nil : token
        let connectBootstrapToken: String? = useBootstrap ? token : nil

        // Advertise from the router's own capability list (R1 / #810) so the
        // agent is only ever offered commands `MacNodeInvocationRouter`
        // actually handles — notably NOT reminders.
        let caps = MacNodeInvocationRouter.advertisedCaps
        let commands = MacNodeInvocationRouter.advertisedCommands

        // --- Node connection options ---
        let nodeOptions = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: caps,
            commands: commands,
            permissions: [
                "screen": false,
                "calendar": MacCalendarGatewayService.currentAuthorizationSupportsCommands,
                "clipboard": true,
                "shell": true,
                "files": true,
                "browser": true,
            ],
            // Upstream's own id for this app: GATEWAY_CLIENT_IDS.MACOS_APP
            // (openclaw/src/gateway/protocol/client-info.ts:10). The Mac previously reported
            // "openclaw-ios", which made the gateway's stored client record
            // (openclaw/src/gateway/node-registry.ts:89 persists `connect.client.id`) say this
            // Mac was an iPhone.
            //
            // Safe to change — verified, not assumed:
            //  * The PAIRING node id is `connect.device?.id ?? connect.client.id`
            //    (node-registry.ts:72), and `includeDeviceIdentity` defaults to TRUE
            //    (GatewayChannel.swift:125), so the node id is the DEVICE id, not this string.
            //    Empirically: the live gateway lists 9+ paired devices that all send
            //    "openclaw-ios" yet each holds its own row — if client.id were the key they
            //    would collapse into one. So changing it does not re-pair or strand a record.
            //  * Upstream treats MACOS_APP and IOS_APP identically at both special-case sites
            //    (ws-connection/message-handler.ts:554-555, agents/tools/sessions-resolution.ts:27-28).
            clientId: "openclaw-macos",
            clientMode: "node",
            clientDisplayName: Host.current().localizedName ?? "Mac")

        // --- Operator connection options ---
        // Mac is the manager device; it requests the full upstream scope set
        // matched to the iOS reference app's Mac client
        // (`GatewayChannel.swift:127-133`: admin/read/write/pairing).
        //
        // `operator.admin` unlocks every upstream `[ADMIN_SCOPE]` method:
        // cross-device `device.pair.remove`, `sessions.patch` (exec-node
        // pinning, verboseLevel, session label — critical for multi-device
        // routing), `skills.install/update`, `agents.*`, `cron.*`,
        // `secrets.reload/resolve`, `channels.logout`. See #320 (Widen Mac
        // operator scope to operator.admin).
        //
        // `operator.pairing` lets the Mac list/approve/remove paired
        // devices — without it, the Paired Devices list stays empty and
        // pending pairings hang forever (see #287).
        //
        // **Rollout safety.** Existing Mac installs have pairing tokens
        // minted with the narrower scope. On first connect after this ships,
        // the gateway emits `PAIRING_REQUIRED` with
        // `details.reason = "scope-upgrade"`. The session manager's
        // `dispatchPairingRecovery` (this PR) classifies via
        // `GatewayPairingFailure.scopeUpgrade` and calls `resetPairing()`
        // silently — the user sees a brief "Re-pairing…" banner, then normal
        // operation. No manual tap required. See #306 (Pairing recovery UX
        // epic) for the iOS dispatcher this mirrors.
        //
        // iOS stays narrow (`operator.read`/`operator.write`) per the #285
        // policy — iOS is a node device, not a manager.
        let operatorOptions = GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.read", "operator.write", "operator.pairing", "operator.admin"],
            caps: [],
            commands: [],
            permissions: [:],
            // Same correction as the node session above. See that comment for the evidence
            // that this is safe; the operator session is not the paired-node identity at all.
            clientId: "openclaw-macos",
            clientMode: "ui",
            clientDisplayName: Host.current().localizedName ?? "Rem Mac",
            includeDeviceIdentity: true)

        nodeConnected = false
        operatorConnected = false

        // Connect both sessions in parallel. We catch thrown errors here
        // (instead of `try?`) so the structured `GatewayConnectAuthError`
        // reaches `lastConnectError` for the typed-error classifier —
        // without this the error would be discarded and only the localized
        // message would survive (via `disconnectHandler`), defeating the
        // point of using the upstream `GatewayConnectionProblemMapper`.
        // Mirrors `RemGatewayClient.connect` (#306 Pairing recovery UX epic).
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await self.connectOperator(
                        url: url,
                        token: connectToken,
                        bootstrapToken: connectBootstrapToken,
                        options: operatorOptions)
                } catch {
                    await self.recordConnectError(error)
                }
            }
            group.addTask {
                do {
                    try await self.nodeSession.connect(
                        url: url,
                        token: connectToken,
                        bootstrapToken: connectBootstrapToken,
                        password: nil,
                        connectOptions: nodeOptions,
                        sessionBox: nil,
                        onConnected: { [weak self] in
                            await self?.handleNodeConnected()
                        },
                        onDisconnected: { [weak self] reason in
                            await self?.handleNodeDisconnected(reason)
                        },
                        onInvoke: { [weak self] req in
                            if req.command == "skills.snapshot.changed" {
                                await self?.onSkillsChanged?()
                            }
                            return await MacNodeInvocationRouter.handle(req)
                        })
                    await self.logSocketOpen(role: "node")
                } catch {
                    await self.recordConnectError(error)
                }
            }
            for await _ in group {}
        }

        guard nodeConnected else {
            throw MacGatewayError.notConnected
        }

        if connectionState != .pairingRequired {
            await setState(.connected)
        }
    }

    /// Connect the operator session.
    ///
    /// `token` and `bootstrapToken` are mutually exclusive — exactly one is
    /// non-nil per the #300a auth-routing rule (`isBootstrap` flag at the
    /// caller). OpenClawKit's `selectConnectAuth` (`GatewayChannel.swift:498`)
    /// frames `auth.token` vs `auth.bootstrapToken` accordingly.
    private func connectOperator(
        url: URL,
        token: String?,
        bootstrapToken: String?,
        options: GatewayConnectOptions
    ) async throws {
        try await operatorSession.connect(
            url: url,
            token: token,
            bootstrapToken: bootstrapToken,
            password: nil,
            connectOptions: options,
            sessionBox: nil,
            onConnected: { [weak self] in
                await self?.handleOperatorConnected()
            },
            onDisconnected: { [weak self] reason in
                await self?.handleOperatorDisconnected(reason)
            },
            onInvoke: { req in
                BridgeInvokeResponse(
                    id: req.id,
                    ok: false,
                    error: OpenClawNodeError(
                        code: .invalidRequest,
                        message: "INVALID_REQUEST: operator session cannot invoke node commands"))
            })
        logSocketOpen(role: "operator")
    }

    private func handleNodeConnected() async {
        nodeConnected = true
        // A successful connect invalidates any captured failure signals from
        // a previous attempt — otherwise they'd leak into the next classify.
        lastDisconnectReason = nil
        lastConnectError = nil
        if operatorConnected {
            await setState(.connected)
        } else if connectionState != .pairingRequired {
            await setState(.connecting)
        }
        await onNodeStateChange?(true)
    }

    /// Captures a thrown connect error for the typed-error classifier.
    /// Only retains the *first* error from a connect attempt so a follow-up
    /// transport drop doesn't overwrite a more informative auth error.
    /// Mirrors `RemGatewayClient.recordConnectError`. See #306 (Pairing
    /// recovery UX epic).
    fileprivate func recordConnectError(_ error: Error) {
        if lastConnectError == nil {
            lastConnectError = error
        }
        #if DEBUG
        print("[MacGateway] captured connect error: \(error)")
        #endif
    }

    private func handleNodeDisconnected(_ reason: String) async {
        nodeConnected = false
        lastDisconnectReason = reason
        logSocketDrop(role: "node", reason: reason)
        await onNodeStateChange?(false)
        // Substring matching here is intentionally conservative — it only
        // distinguishes broad buckets (pairing vs unauthorized vs
        // unreachable). The session manager does the structured
        // classification via `GatewayPairingFailure.classify(error:)` using
        // `lastConnectError` as the source of truth (#306 Pairing recovery
        // UX epic rule: structured signals over string parsing, CLAUDE.md
        // principle #5).
        let lower = reason.lowercased()
        if lower.contains("pairing") {
            await setState(.pairingRequired)
        } else if lower.contains("unauthorized") || lower.contains("1008") {
            await setState(.unauthorized)
        } else {
            await setState(.unreachable(reason))
        }
    }

    private func handleOperatorConnected() async {
        operatorConnected = true
        // Symmetric with handleNodeConnected — a successful operator connect
        // also invalidates captured failure signals from a previous attempt
        // so they don't leak into the next classify. Without this, a node-
        // success + operator-fail scenario could leave stale operator errors
        // pinned; and even in the symmetric success case it prevents a
        // lingering lastDisconnectReason from a prior session.
        lastDisconnectReason = nil
        lastConnectError = nil
        #if DEBUG
        print("[MacGateway] operator session connected")
        #endif
        await onOperatorStateChange?(true)
        if nodeConnected {
            await setState(.connected)
        }
    }

    private func handleOperatorDisconnected(_ reason: String) async {
        operatorConnected = false
        lastDisconnectReason = reason
        logSocketDrop(role: "operator", reason: reason)
        #if DEBUG
        print("[MacGateway] operator session disconnected: \(reason)")
        #endif
        await onOperatorStateChange?(false)

        let lower = reason.lowercased()
        if lower.contains("pairing") {
            await setState(.pairingRequired)
        }
    }

    func disconnect() async {
        // Only log a close for roles we believe are open, so the `live=` tally
        // can't drift negative on an already-idle disconnect (Low item).
        if nodeConnected { logSocketClose(role: "node") }
        if operatorConnected { logSocketClose(role: "operator") }
        await nodeSession.disconnect()
        await operatorSession.disconnect()
        nodeConnected = false
        operatorConnected = false
        await onNodeStateChange?(false)
        await onOperatorStateChange?(false)
        await setState(.disconnected)
    }

    /// Forgets the device-auth pairing tokens stored on disk by OpenClawKit,
    /// then disconnects so the next connect performs a fresh pairing
    /// handshake. Used to recover from:
    ///   - scope-upgrade rejection (#285) after we widen operator scopes
    ///   - DEVICE_AUTH_SIGNATURE_INVALID / _MISMATCH errors (#229)
    ///   - any stale token that the gateway no longer accepts
    ///
    /// Safe to call when connected or disconnected. The caller should
    /// trigger a reconnect after this returns.
    func resetPairing() async {
        let identity = DeviceIdentityStore.loadOrCreate()
        for role in ["operator", "node"] {
            DeviceAuthStore.clearToken(deviceId: identity.deviceId, role: role)
        }
        await disconnect()
    }

    // MARK: - Gateway session access

    /// The node session -- used for device capability invocations.
    var gatewaySession: GatewayNodeSession { nodeSession }

    /// The operator session -- used for chat transport and skills config.
    var chatSession: GatewayNodeSession { operatorSession }

    /// Whether the operator session is connected.
    var isOperatorConnected: Bool { operatorConnected }

    /// Whether the node session is connected.
    var isNodeConnected: Bool { nodeConnected }

    func testConnection() async -> Bool {
        do {
            _ = try await nodeSession.request(method: "health", paramsJSON: nil, timeoutSeconds: 5)
            return true
        } catch {
            return false
        }
    }

    /// Queries the gateway for paired devices via `device.pair.list`.
    /// Returns the raw JSON response as `Data` for the caller to decode.
    func fetchPairedDevices() async throws -> Data {
        guard operatorConnected else { throw MacGatewayError.notConnected }
        return try await operatorSession.request(
            method: "device.pair.list",
            paramsJSON: "{}",
            timeoutSeconds: 10)
    }

    // MARK: - Private

    private func setState(_ state: MacConnectionState) async {
        connectionState = state
        await onStateChange?(state)
    }

    static func webSocketURL(from httpURL: URL) -> URL? {
        var components = URLComponents()
        let useTLS = httpURL.scheme == "https"
        components.scheme = useTLS ? "wss" : "ws"
        components.host = httpURL.host
        components.port = httpURL.port
        components.path = httpURL.path
        return components.url
    }
}

enum MacGatewayError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case authFailed(statusCode: Int)
    case authCancelled
    case noGatewayDeployed
    case credentialsFetchFailed(statusCode: Int)
    case deployFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid gateway URL"
        case .notConnected: "Not connected to gateway"
        case .authFailed(let code): "Sign-in failed (status \(code)). Check your account."
        case .authCancelled: "Sign-in was cancelled."
        case .noGatewayDeployed: "No gateway found — deploying one now."
        case .credentialsFetchFailed(let code): "Failed to fetch gateway credentials (status \(code))"
        case .deployFailed(let msg): "Gateway deploy failed: \(msg)"
        }
    }
}

/// Deploy progress state for the Mac session manager.
enum MacDeployPhase: Equatable {
    case idle
    case deploying(String)
    case complete
    case failed(String)

    var isDeploying: Bool {
        if case .deploying = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .idle: return ""
        case .deploying(let msg): return msg
        case .complete: return "Gateway ready"
        case .failed(let msg): return msg
        }
    }
}
