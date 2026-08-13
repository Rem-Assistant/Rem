import Foundation
#if os(iOS)
import UIKit
#endif
import Combine
import os
import OpenClawKit
import OpenClawProtocol
#if canImport(EventKit)
import EventKit
#endif

/// Always-on (release-safe) logger for gateway WebSocket lifecycle events.
/// Captured in device logs / sysdiagnose so the *next* connection churn is
/// recorded with evidence (trigger + role + running socket tally) without any
/// PostHog cost. See `RemGatewayClient.logSocketOpen/Close`.
private let gatewayConnLog = Logger(subsystem: "com.remclaw", category: "gateway-conn")

/// Manages two gateway connections for RemClaw:
///
/// 1. **Node session** (`role: "node"`) — advertises device capabilities
///    (calendar, reminders, etc.) so the AI agent can invoke them.
///    Requires device pairing.
///
/// 2. **Operator session** (`role: "operator"`) — used for chat transport
///    (chat.send, chat.history, sessions.list) and config reads.
///    Connects with device identity to obtain scopes (operator.read,
///    operator.write, operator.admin). If the operator role hasn't been
///    paired yet (gateway v2026.2.25+ per-role pairing), auto-approve
///    handles the role-upgrade.
///
/// This mirrors the reference OpenClaw iOS app's dual-connection pattern.
/// UI state is projected via `RemGatewaySessionManager`.
actor RemGatewayClient {
    /// Capabilities consumed by the operator/UI socket itself.
    ///
    /// `tool-events` is deliberately advertised on the operator connection rather than relying on
    /// the phone's node capabilities. OpenClaw registers the `chat.send` WebSocket as a live tool
    /// event recipient only when that exact connection declares this capability. Without it, the
    /// final history still contains tool calls, but Rem cannot show in-flight Activity or transfer
    /// Cloud browser card ownership when the browser starts.
    nonisolated static func operatorConnectOptions(
        displayName: String,
        includeDeviceIdentity: Bool = true
    ) -> GatewayConnectOptions {
        GatewayConnectOptions(
            role: "operator",
            scopes: ["operator.read", "operator.write", "operator.admin"],
            caps: ["tool-events"],
            commands: [],
            permissions: [:],
            clientId: "openclaw-ios",
            clientMode: "ui",
            clientDisplayName: displayName,
            includeDeviceIdentity: includeDeviceIdentity
        )
    }

    /// Human-readable label advertised to the gateway on operator connect.
    /// Shows up as the device name in paired-devices lists on the Mac app
    /// (see #289). Main-actor isolated because `UIDevice.current.name` is;
    /// read via `await Self.operatorDisplayName()` from within `connect()`.
    ///
    /// Resolution order (fixes #304 (iOS UIDevice.current.name returns
    /// 'iPhone') without requiring the user-assigned-device-name entitlement):
    ///   1. User-set override from Settings → "This Device's Name"
    ///   2. `UIDevice.current.name`, if it's not the generic model ("iPhone"
    ///      or "iPad" on iOS 16+ without the entitlement) — suffixed with a
    ///      short device-id hash so multiple "iPhone"s are distinguishable
    ///   3. `"Rem iOS"` as a last resort
    @MainActor
    static func operatorDisplayName() -> String {
        #if os(iOS)
        if let override = DevicePreferences.deviceDisplayName {
            return override
        }
        let raw = UIDevice.current.name
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Rem iOS" }
        // iOS 16+ without the entitlement returns the generic model. Append
        // a short hash so the Mac's paired-devices list can still tell two
        // "iPhone"s apart.
        if trimmed == "iPhone" || trimmed == "iPad" {
            let deviceId = DeviceIdentityStore.loadOrCreate().deviceId
            let suffix = String(deviceId.prefix(4))
            return "\(trimmed) (\(suffix))"
        }
        return trimmed
        #else
        return "Rem"
        #endif
    }

    // Primary node connection — device capabilities + pairing
    private let nodeSession = GatewayNodeSession()
    // Secondary operator connection — chat + config
    private let operatorSession = GatewayNodeSession()
    private var nodeConnected = false
    private var operatorConnected = false

    // MARK: - Connection-churn instrumentation (#connection-reliability)

    /// Running tally of node/operator WebSockets we have explicitly opened but
    /// not yet closed. Steady state is 2 (one node + one operator). If this
    /// climbs and stays above 2 we are leaking sockets on a reconnect path —
    /// exactly the "~4 concurrent connections" signature of the churn bug.
    /// Adjusted only at the open/close call sites we control.
    private var liveSocketTally = 0

    /// Human-readable label for what triggered the current (re)connect, set by
    /// the session manager via `setConnectTrigger` before it initiates one.
    /// Purely for the churn log ("foreground" / "keepalive" / "backoff" /
    /// "grace" / "manual" / "launch" / …).
    private var connectTrigger = "launch"

    /// Set the trigger label attached to subsequent socket open/close log lines.
    func setConnectTrigger(_ trigger: String) { connectTrigger = trigger }

    private func logSocketOpen(role: String) {
        liveSocketTally += 1
        gatewayConnLog.log(
            "ws OPEN role=\(role, privacy: .public) trigger=\(self.connectTrigger, privacy: .public) live=\(self.liveSocketTally, privacy: .public)")
    }

    private func logSocketClose(role: String) {
        liveSocketTally = max(0, liveSocketTally - 1)
        gatewayConnLog.log(
            "ws CLOSE role=\(role, privacy: .public) trigger=\(self.connectTrigger, privacy: .public) live=\(self.liveSocketTally, privacy: .public)")
    }

    /// An unexpected socket drop reported by OpenClawKit's disconnect callback
    /// (vs. a close we initiated). Logged for churn correlation but does NOT
    /// adjust the tally — the reconnect path that follows issues its own
    /// close-before-open, which keeps the tally honest.
    private func logSocketDrop(role: String, reason: String) {
        gatewayConnLog.log(
            "ws DROP role=\(role, privacy: .public) trigger=\(self.connectTrigger, privacy: .public) live=\(self.liveSocketTally, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private(set) var connectionState: RemGatewayConnectionState = .disconnected

    /// Last disconnect reason string reported by either node or operator session.
    /// Used by the session manager as a fallback signal — but never as the
    /// primary classifier for control flow. The structured `lastConnectError`
    /// below is preferred. Cleared on successful connect so stale reasons
    /// don't leak across sessions. See #306 (Pairing recovery UX epic).
    private(set) var lastDisconnectReason: String?

    /// Structured error captured from the most recent connect-throw.
    /// Carries `GatewayConnectAuthError.detail` (typed `DEVICE_AUTH_*` code)
    /// and `detailsReason` ("scope-upgrade" / "role-upgrade" /
    /// "metadata-upgrade") so the session manager can classify pairing
    /// failures via the upstream typed `GatewayConnectionProblemMapper`
    /// instead of substring-matching `error.localizedDescription`.
    /// Cleared on successful connect. See #306 (Pairing recovery UX epic).
    private(set) var lastConnectError: Error?

    /// Callback fired on state changes so the UI layer can react.
    private(set) var onStateChange: (@Sendable (RemGatewayConnectionState) async -> Void)?

    /// Callback fired when the gateway sends a skills.snapshot.changed event.
    private(set) var onSkillsChanged: (@Sendable () async -> Void)?

    /// Callback fired when the operator session connects or disconnects.
    private(set) var onOperatorStateChange: (@Sendable (Bool) async -> Void)?

    /// Set the state-change callback. Call this from any context; mutation runs on the actor.
    func setOnStateChange(_ handler: (@Sendable (RemGatewayConnectionState) async -> Void)?) {
        onStateChange = handler
    }

    func setOnSkillsChanged(_ handler: (@Sendable () async -> Void)?) {
        onSkillsChanged = handler
    }

    func setOnOperatorStateChange(_ handler: (@Sendable (Bool) async -> Void)?) {
        onOperatorStateChange = handler
    }

    // MARK: - Connect / Disconnect

    /// Overall timeout for the initial connect handshake (both operator + node).
    /// Prevents indefinite hangs from DNS issues or firewalls.
    private static let connectTimeoutSeconds: TimeInterval = 10

    /// Connect to a gateway using the provided server provider.
    /// Node connects with device identity (may require pairing).
    /// Operator connects WITHOUT device identity (Phase 1 — fast, no pairing).
    /// The session manager handles Phase 2 (operator upgrade with identity).
    /// Times out after `connectTimeoutSeconds` to avoid indefinite hangs.
    ///
    /// - Parameters:
    ///   - provider: hosting + credential abstraction (URL + token).
    ///   - isBootstrap: when `true`, `provider.gatewayToken` is treated as
    ///     a short-lived bootstrap credential and routed to OpenClawKit's
    ///     `bootstrapToken:` parameter (which serializes as
    ///     `auth.bootstrapToken` on the wire and triggers the upstream
    ///     pair-bootstrap → device-token handshake; see
    ///     `GatewayChannel.swift:430-440, 545-607`). When `false` (the
    ///     default), the token is routed to `token:` as today.
    ///
    ///     Plumbed in #300a; the only caller (`RemGatewaySessionManager`)
    ///     does NOT pass it yet, so every existing path still hits the
    ///     `false` branch and behavior is unchanged. #300b flips the Mac
    ///     emitter + decoder to set `GatewayConfig.isBootstrap == true`
    ///     for upstream-format setup codes, at which point the session
    ///     manager will start forwarding it.
    func connect(
        provider: any GatewayServerProvider,
        isBootstrap: Bool = false
    ) async throws {
        await setState(.connecting)

        // Close-before-open: never stack a second pair of sockets on top of a
        // live connection. If either session is still up (e.g. connectIfConfigured
        // was called without an intervening disconnect), tear both down first so
        // we can't leak the old node+operator sockets. The dedicated reconnect
        // paths (reconnectNode/reconnectOperator/disconnect) already close first;
        // this covers the direct connect-on-top path. (#connection-reliability)
        if nodeConnected || operatorConnected {
            if nodeConnected { logSocketClose(role: "node") }
            if operatorConnected { logSocketClose(role: "operator") }
            await nodeSession.disconnect()
            await operatorSession.disconnect()
            nodeConnected = false
            operatorConnected = false
        }

        // Build WebSocket URL; use ws:// for http:// (e.g. local), wss:// for https:// (prod).
        let wsURL = Self.webSocketURL(from: provider.gatewayURL)
        guard let url = wsURL else {
            await setState(.unreachable("Invalid gateway URL"))
            throw GatewayClientError.invalidURL
        }

        let token = provider.gatewayToken
        // #300a: `isBootstrap` selects which auth slot the token rides in.
        // Today this is always false; #300b is where it starts flipping true
        // for upstream-format setup codes from the Mac emitter.
        let useBootstrap = isBootstrap
        let connectToken: String? = useBootstrap ? nil : token
        let connectBootstrapToken: String? = useBootstrap ? token : nil

        // --- Node connection options ---
        // Capabilities/commands are generated from the device's real handler
        // registry (`NodeInvocationRouter`), so the agent is only ever offered
        // commands this device actually implements — no hand-maintained drift
        // and no hallucinated "unknown command" path (R1 / #810).
        let caps = await NodeInvocationRouter.advertisedCaps
        let commands = await NodeInvocationRouter.advertisedCommands

        let permissions = await Self.currentPermissions()

        let nodeOptions = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: caps,
            commands: commands,
            permissions: permissions,
            clientId: "openclaw-ios",
            clientMode: "node",
            clientDisplayName: nil)

        // --- Operator connection options ---
        // Connects WITH device identity to obtain scopes. If the operator
        // role isn't paired yet, the disconnect handler sets .pairingRequired
        // and auto-approve handles the role-upgrade.
        let displayName = await Self.operatorDisplayName()
        // `operator.admin` is required because chat patches session labels, verbose level, and the
        // exec-node binding. Keep the initial and reconnect handshakes on one factory so neither
        // those scopes nor the operator-owned live `tool-events` capability can drift.
        let operatorOptions = Self.operatorConnectOptions(displayName: displayName)

        nodeConnected = false
        operatorConnected = false

        // Connect both sessions in parallel.
        // Uses a non-throwing task group so one session's pairing failure
        // doesn't cancel the other via structured concurrency. We catch the
        // thrown errors here (instead of the previous `try?`) so the
        // structured `GatewayConnectAuthError` reaches `lastConnectError`
        // for the typed-error classifier — without this, the error would be
        // discarded and only the localized message would survive (via
        // `disconnectHandler`), defeating the whole point of using the
        // upstream `GatewayConnectionProblemMapper`. See #306.
        try await withThrowingTimeout(seconds: Self.connectTimeoutSeconds) {
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
                                return await NodeInvocationRouter.handle(req)
                            })
                        await self.logSocketOpen(role: "node")
                    } catch {
                        await self.recordConnectError(error)
                    }
                }
                for await _ in group {}
            }
        }

        // After both tasks complete, check node status.
        // The node's disconnect handler has already set the appropriate
        // state (.pairingRequired, .unreachable, etc.) and awaited the
        // MainActor callback, so the session manager will react correctly.
        guard nodeConnected else {
            throw GatewayClientError.notConnected
        }

        // Node connected. If operator pairing is in progress (state is
        // .pairingRequired), don't override — auto-approve will reconnect.
        if connectionState != .pairingRequired {
            await setState(.connected)
        }
    }

    /// Runs a throwing async closure with a timeout. Throws `GatewayClientError.connectionTimeout`
    /// if the operation doesn't complete within the given duration.
    private func withThrowingTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw GatewayClientError.connectionTimeout
            }
            // The first task to complete wins; cancel the other.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Connect the operator session (required for chat/task/event flows).
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
                // Operator session should not handle node.invoke requests.
                BridgeInvokeResponse(
                    id: req.id,
                    ok: false,
                    // Terminal: the operator session structurally cannot invoke
                    // node commands — retrying never helps (R2-A / #811).
                    error: OpenClawNodeError(
                        code: .invalidRequest,
                        message: "INVALID_REQUEST: operator session cannot invoke node commands. Do not retry.",
                        retryable: false))
            })
        logSocketOpen(role: "operator")
    }

    private func handleNodeConnected() async {
        nodeConnected = true
        lastDisconnectReason = nil
        lastConnectError = nil
        if operatorConnected {
            await setState(.connected)
        } else if connectionState != .pairingRequired {
            // Don't override .pairingRequired — the operator's disconnect
            // handler already set it and auto-approve is in progress.
            await setState(.connecting)
        }
    }

    /// Captures a thrown connect error for the typed-error classifier.
    /// Only retains the *first* error from a connect attempt so a follow-up
    /// transport drop doesn't overwrite a more informative auth error.
    /// See #306 (Pairing recovery UX epic).
    fileprivate func recordConnectError(_ error: Error) {
        if lastConnectError == nil {
            lastConnectError = error
        }
        #if DEBUG
        print("[Gateway] captured connect error: \(error)")
        #endif
    }

    private func handleNodeDisconnected(_ reason: String) async {
        nodeConnected = false
        lastDisconnectReason = reason
        logSocketDrop(role: "node", reason: reason)
        let lower = reason.lowercased()
        if lower.contains("pairing") {
            await setState(.pairingRequired)
        } else if GatewayPairingFailure.from(reasonString: reason).isTrustRevocation {
            await setState(.pairingRequired)
        } else if lower.contains("unauthorized") || lower.contains("1008") {
            await setState(.unauthorized)
        } else {
            await setState(.unreachable(reason))
        }
    }

    private func handleOperatorConnected() async {
        operatorConnected = true
        #if DEBUG
        print("[Gateway] operator session connected")
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
        print("[Gateway] operator session disconnected: \(reason)")
        #endif
        await onOperatorStateChange?(false)

        // Detect operator-role pairing requirement (gateway v2026.2.25+
        // per-role pairing). The auto-approve flow handles the role-upgrade.
        let lower = reason.lowercased()
        if lower.contains("pairing") {
            await setState(.pairingRequired)
        }
        // Otherwise don't tear down a healthy node just because the
        // operator dropped. The keepalive will reconnect the operator.
    }

    func disconnect() async {
        // Only log a close for roles we actually believe are open, so the
        // `live=` tally can't drift negative on a disconnect of an already-idle
        // client (Low item — was clamped by max(0,...) but cosmetically off).
        if nodeConnected { logSocketClose(role: "node") }
        if operatorConnected { logSocketClose(role: "operator") }
        await nodeSession.disconnect()
        await operatorSession.disconnect()
        nodeConnected = false
        operatorConnected = false
        await setState(.disconnected)
    }

    /// Forgets the device-auth pairing tokens stored by OpenClawKit, then
    /// disconnects so the next connect performs a fresh pairing handshake.
    /// Matches the Mac helper. Used by #288 banner CTA + manual recovery.
    ///
    /// Safe to call when connected or disconnected. The caller should
    /// trigger a reconnect after this returns.
    func resetPairing(rotateDeviceIdentity: Bool = false) async {
        let identity = DeviceIdentityStore.loadOrCreate()
        for role in ["operator", "node"] {
            DeviceAuthStore.clearToken(deviceId: identity.deviceId, role: role)
        }
        if rotateDeviceIdentity {
            DeviceAuthStore.clearAll()
            DeviceIdentityStore.reset()
        }
        await disconnect()
    }

    /// Whether the node session believes it is connected (cached flag).
    /// NOTE: In silent-drop scenarios, this flag may be stale. Use
    /// `probeNodeAlive()` for a real liveness check.
    var isNodeConnected: Bool { nodeConnected }

    /// Whether the operator session believes it is connected (cached flag).
    var isOperatorConnected: Bool { operatorConnected }

    /// Sends a lightweight health request on the node session to verify
    /// the WebSocket is actually alive. Returns false if the request
    /// times out or errors — meaning the connection silently dropped.
    func probeNodeAlive() async -> Bool {
        guard nodeConnected else { return false }
        do {
            _ = try await nodeSession.request(
                method: "health",
                paramsJSON: nil,
                timeoutSeconds: 5)
            return true
        } catch {
            #if DEBUG
            print("[Gateway] node probe failed: \(error.localizedDescription)")
            #endif
            // The connection is dead — update the cached flag so other
            // code paths also see it as disconnected.
            nodeConnected = false
            return false
        }
    }

    /// Probes the operator session with a lightweight health request.
    /// Returns false if the request times out or errors.
    func probeOperatorAlive() async -> Bool {
        guard operatorConnected else { return false }
        do {
            _ = try await operatorSession.request(
                method: "health",
                paramsJSON: nil,
                timeoutSeconds: 5)
            return true
        } catch {
            #if DEBUG
            print("[Gateway] operator probe failed: \(error.localizedDescription)")
            #endif
            operatorConnected = false
            return false
        }
    }

    /// Reconnect only the node session (preserves the operator/chat connection).
    /// Used by the keepalive timer when the node silently drops.
    ///
    /// `isBootstrap` mirrors `connect(provider:isBootstrap:)`. Defaulted to
    /// `false` so existing callers (the session manager's keepalive path)
    /// pick the same auth slot they always have. See #300a.
    func reconnectNode(
        provider: any GatewayServerProvider,
        isBootstrap: Bool = false
    ) async throws {
        let wsURL = Self.webSocketURL(from: provider.gatewayURL)
        guard let url = wsURL else { throw GatewayClientError.invalidURL }

        let token = provider.gatewayToken
        let useBootstrap = isBootstrap
        let connectToken: String? = useBootstrap ? nil : token
        let connectBootstrapToken: String? = useBootstrap ? token : nil
        // Advertise from the real handler registry (R1 / #810) — same source
        // of truth as `connect()`, so reconnect can't drift from first connect.
        let caps = await NodeInvocationRouter.advertisedCaps
        let commands = await NodeInvocationRouter.advertisedCommands
        let permissions = await Self.currentPermissions()
        let nodeOptions = GatewayConnectOptions(
            role: "node",
            scopes: [],
            caps: caps,
            commands: commands,
            permissions: permissions,
            clientId: "openclaw-ios",
            clientMode: "node",
            clientDisplayName: nil)

        logSocketClose(role: "node")
        await nodeSession.disconnect()
        nodeConnected = false

        do {
            try await nodeSession.connect(
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
                    return await NodeInvocationRouter.handle(req)
                })
            logSocketOpen(role: "node")
        } catch {
            recordConnectError(error)
            throw error
        }
    }

    /// Reconnect only the operator session (preserves the node/device connection).
    /// - Parameter includeDeviceIdentity: When `true`, the operator connects
    ///   with device identity to obtain scopes. When `false`, connects without
    ///   identity (fast, no pairing — but no scopes).
    /// - Parameter isBootstrap: mirrors `connect(provider:isBootstrap:)`.
    ///   Defaulted `false` so existing callers route the token via the same
    ///   `auth.token` slot they always have. See #300a.
    func reconnectOperator(
        provider: any GatewayServerProvider,
        includeDeviceIdentity: Bool = true,
        isBootstrap: Bool = false
    ) async throws {
        let wsURL = Self.webSocketURL(from: provider.gatewayURL)
        guard let url = wsURL else { throw GatewayClientError.invalidURL }

        let token = provider.gatewayToken
        let useBootstrap = isBootstrap
        let connectToken: String? = useBootstrap ? nil : token
        let connectBootstrapToken: String? = useBootstrap ? token : nil
        let displayName = await Self.operatorDisplayName()
        let operatorOptions = Self.operatorConnectOptions(
            displayName: displayName,
            includeDeviceIdentity: includeDeviceIdentity
        )

        logSocketClose(role: "operator")
        await operatorSession.disconnect()
        operatorConnected = false

        do {
            try await connectOperator(
                url: url,
                token: connectToken,
                bootstrapToken: connectBootstrapToken,
                options: operatorOptions)
        } catch {
            recordConnectError(error)
            throw error
        }
    }

    // MARK: - Gateway session access

    /// The node session — used for device capability invocations.
    var gatewaySession: GatewayNodeSession { nodeSession }

    /// The operator session — used for chat transport (chat.send, chat.history, etc.).
    var chatSession: GatewayNodeSession { operatorSession }

    // MARK: - Linked devices

    /// Queries the gateway for paired devices via `device.pair.list`.
    /// Returns the raw JSON response as `Data` for the caller to decode.
    func fetchPairedDevices() async throws -> Data {
        guard operatorConnected else { throw GatewayClientError.notConnected }
        return try await operatorSession.request(
            method: "device.pair.list",
            paramsJSON: "{}",
            timeoutSeconds: 10)
    }

    // MARK: - Health check

    /// Quick connectivity test — returns true if gateway responds.
    func testConnection() async -> Bool {
        do {
            _ = try await operatorSession.request(
                method: "health",
                paramsJSON: nil,
                timeoutSeconds: 5)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Permissions snapshot

    /// Build a permission map reporting the current iOS authorization status
    /// for each device service. The gateway uses this to inform the AI agent
    /// which capabilities are actually usable.
    @MainActor
    private static func currentPermissions() -> [String: Bool] {
        var perms: [String: Bool] = [:]

        #if canImport(EventKit)
        let calStatus = EKEventStore.authorizationStatus(for: .event)
        perms["calendar"] = calStatus == .fullAccess || calStatus == .authorized

        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        perms["reminders"] = remStatus == .fullAccess || remStatus == .authorized
        #endif


        // Notifications: async check not feasible here; report optimistically
        perms["notifications"] = true
        // Device info is always available
        perms["device"] = true

        return perms
    }

    /// Returns the current permissions snapshot (for comparison).
    @MainActor
    static func permissionsSnapshot() -> [String: Bool] {
        currentPermissions()
    }

    // MARK: - Private

    private func setState(_ state: RemGatewayConnectionState) async {
        connectionState = state
        await onStateChange?(state)
    }

    /// Converts gateway URL to WebSocket URL. Scheme from URL: http → ws, https → wss (local dev vs prod).
    static func webSocketURL(from gatewayURL: URL) -> URL? {
        var components = URLComponents()
        let useTLS = gatewayURL.scheme?.lowercased() == "https"
        components.scheme = useTLS ? "wss" : "ws"
        components.host = gatewayURL.host
        components.port = gatewayURL.port
        components.path = gatewayURL.path.isEmpty ? "/" : gatewayURL.path
        return components.url
    }
}

// MARK: - Pairing failure classification (#306 Pairing recovery UX epic)
//
// The `GatewayPairingFailure` enum + classifier now live in
// `Shared/Gateway/GatewayPairingFailure.swift` so the Mac session manager
// can use the same code path (see #320 (Widen Mac operator scope to
// operator.admin)). iOS behaviour is unchanged.

enum GatewayClientError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case connectionTimeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid gateway URL"
        case .notConnected: "Not connected to gateway"
        case .connectionTimeout: "Gateway connection timed out"
        }
    }
}
