import Foundation
import OpenClawKit
import OpenClawChatUI
#if os(iOS)
import UIKit
#endif

/// Observable session manager bridging RemGatewayClient (networking actor)
/// to SwiftUI views. This is the single @Observable object injected into
/// the environment so views can read connection state and access the
/// chat transport.
///
/// Credential storage: tokens in Keychain via `RemCredentialStore`,
/// non-sensitive values (URLs) in UserDefaults. The `isConfigured` flag
/// drives the onboarding vs. main app flow.
@MainActor @Observable
final class RemGatewaySessionManager {
    // MARK: - Published state

    private(set) var connectionState: RemGatewayConnectionState = .disconnected
    private(set) var gatewayHostDisplay: String?
    var mainSessionKey: String? = nil

    /// Timestamp of the last **user-visible** reconnect — stamped only when the
    /// connection recovers from a disconnect the user actually saw (the visible
    /// Unreachable/backoff state), gated + debounced by `RemReconnectToastPolicy`.
    /// Views observe this via `.onChange` to surface a transient "Reconnected"
    /// toast (`RemToast`). Deliberately NOT stamped for the soft grace-period blip,
    /// the first-ever connect, or routine foreground-after-background resumes. It
    /// doubles as the debounce anchor (last-toast time). A signal, not durable
    /// state — nothing persists it.
    private(set) var lastReconnectAt: Date?

    /// Set when the connection enters the **visible** backoff state (see
    /// `scheduleReconnect()`), i.e. the user is being shown the "Unreachable"
    /// banner. Cleared on the next `.connected`. Gates the "Reconnected" toast so
    /// it confirms recovery only from a disconnect the user saw — never a masked
    /// grace-period blip. Boolean (not a `reconnectAttempt` threshold) because the
    /// attempt counter is zeroed the moment the node socket reconnects, which can
    /// race ahead of the `.connected` callback.
    private var sawVisibleDisconnect = false

    /// Bumped when the gateway sends a `skills.snapshot.changed` event
    /// (e.g. when a Mac connects and its binaries are probed).
    private(set) var skillsSnapshotVersion: Int = 0

    /// When false, the app should show onboarding / "Set Up Server".
    /// Backed by a stored property so `@Observable` can track changes.
    private(set) var isConfigured: Bool = false

    /// True while the deploy flow is waiting for the WebSocket to connect.
    /// ContentView checks this to keep OnboardingFlow visible after configure().
    var isCompletingDeploy: Bool = false

    /// True when the operator session (used for chat/sessions) is connected.
    /// The operator connects concurrently with the node session, so this may
    /// lag behind `connectionState == .connected` by a moment.
    private(set) var operatorReady: Bool = false

    /// Advances before an operator socket/auth context is replaced and again when the new socket
    /// becomes ready. Provider-auth evidence binds to this instead of mutable URL strings.
    private(set) var operatorSessionGeneration: UInt64 = 0

    /// Monotonic proof that a new node connection completed. Pairing recovery
    /// captures the current value before reconnecting so an already-connected
    /// coarse state cannot be mistaken for success from the new attempt.
    private(set) var connectionGeneration = 0

    /// Paired devices from the gateway (for Linked Devices UI).
    private(set) var linkedDevices: [LinkedDevice] = []

    /// True while a linked-devices fetch is in progress.
    private(set) var isLoadingLinkedDevices: Bool = false

    /// Devices awaiting pairing approval (for Pending Devices UI).
    private(set) var pendingDevices: [PendingDevice] = []

    /// True while a pending-devices fetch is in progress.
    private(set) var isLoadingPendingDevices: Bool = false

    /// Error message from the last approve/decline action.
    var pendingDeviceError: String?

    // MARK: - Internal

    let client = RemGatewayClient()
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    /// One reconnect owner at a time. Independent triggers (foreground flap,
    /// keepalive probe, grace-period retry, backoff ladder) all consult this
    /// before starting a reconnect, so they can't stack N concurrent
    /// node+operator socket pairs — the mechanism behind the observed
    /// connection churn. Self-expiring so a stuck flag can never wedge
    /// reconnection. See `ReconnectCoalescer` and #connection-reliability.
    private var reconnectCoalescer = ReconnectCoalescer()

    #if DEBUG
    /// Test seam: true while a reconnect owns the coalescer slot. Lets a
    /// manager-level test assert the slot is RELEASED after a reconnect settles
    /// (the value-type predicate tests can't catch a claim-without-release wiring
    /// bug). See `ReconnectSlotReleaseTests`. (#connection-reliability DEFECT 1)
    var isReconnectSlotHeldForTesting: Bool { reconnectCoalescer.inFlight }

    /// Test seam: number of times the `reconnect(trigger:)` path successfully
    /// CLAIMED the coalescer slot. A concurrent `reconnect()` issued while one is
    /// already in flight must NOT increment this (it's refused), which is how a
    /// test proves the one-owner guard holds across an in-flight reconnect.
    private(set) var reconnectClaimCountForTesting = 0
    #endif

    /// Forward the churn-log trigger label to the client (which stamps it on
    /// every WebSocket open/close line) without blocking the caller.
    private func setConnectTrigger(_ trigger: String) {
        Task { await client.setConnectTrigger(trigger) }
    }
    /// Last permissions snapshot sent to the gateway, used to detect changes.
    private var lastPermissions: [String: Bool] = [:]

    /// Tracks whether we've already requested auto-approve for this session
    /// to avoid spamming the endpoint.
    private var hasRequestedAutoApprove = false

    /// Tracks an in-flight re-pair so we can fire `gateway_re_pair_completed`
    /// on the next successful connect. See #306 (Pairing recovery UX epic).
    private(set) var inFlightRePairTrigger: String?

    /// True while an auto-triggered re-pair is running. The banner uses this
    /// to swap the default "Connecting…" copy for "Re-pairing…" so the user
    /// understands we're recovering rather than just reconnecting.
    var isAutoRePairInProgress: Bool {
        inFlightRePairTrigger == "auto"
    }

    var supportsExplicitPairingApproval: Bool { true }

    /// Tracks whether the next `.connected` transition is a re-pair (vs a
    /// first-pair or simple reconnect). Used to stamp `is_repair` on
    /// `device_gateway_pairing_completed`. See #306 (Pairing recovery UX epic).
    private var nextConnectIsRepair: Bool = false

    /// De-dupes `gateway_pairing_required_seen` / `gateway_signature_invalid_seen`
    /// events so a flapping connection doesn't inflate the funnel. Reset when
    /// we transition to `.connected` or `.disconnected`.
    private var hasReportedPairingRequiredSeen = false
    private var hasReportedSignatureInvalidSeen = false

    /// Prevents repeated pending-device fetches on every view appear.
    private var hasFetchedPendingDevices = false

    /// Timestamp when connectIfConfigured() was last called, for measuring time-to-connect.
    private var connectionStartTime: CFAbsoluteTime = 0

    /// Periodic keepalive that detects a silently-dropped node session
    /// and reconnects it without tearing down the working operator/chat session.
    private var keepaliveTask: Task<Void, Never>?
    private let keepaliveInterval: TimeInterval = 20
    private var isManagedCloudRePairInFlight = false

    init() {
        // Hydrate from persisted credentials
        isConfigured = RemCredentialStore.gatewayURL != nil && RemCredentialStore.gatewayToken != nil

        Task { [weak self] in
            guard let self else { return }
            await self.client.setOnStateChange { [weak self] newState in
                await MainActor.run {
                    guard let self else { return }
                    self.connectionState = newState

                    switch newState {
                    case .connected:
                        self.connectionGeneration += 1
                        let connectMs = Int((CFAbsoluteTimeGetCurrent() - self.connectionStartTime) * 1000)
                        let attempt = self.reconnectAttempt
                        self.reconnectAttempt = 0
                        self.reconnectTask?.cancel()
                        // Surface a "Reconnected" toast ONLY when recovering from a
                        // disconnect the user actually saw (the visible
                        // Unreachable/backoff state), debounced so a flaky stretch
                        // doesn't stack toasts. The soft grace-period blip, cold
                        // start, and routine foreground resumes never set
                        // `sawVisibleDisconnect`, so they don't toast. See
                        // `RemReconnectToastPolicy`.
                        if RemReconnectToastPolicy.shouldToast(
                            sawVisibleDisconnect: self.sawVisibleDisconnect,
                            now: Date(),
                            lastToastAt: self.lastReconnectAt
                        ) {
                            self.lastReconnectAt = Date()
                        }
                        // Cycle done — clear the flag whether or not we toasted.
                        self.sawVisibleDisconnect = false
                        // NOTE: the coalescer slot is released solely by each
                        // reconnect owner's token'd `defer` (`reconnect(trigger:)`,
                        // `reconnectDroppedSessions`, `reconnectOperatorOnly`),
                        // which fires on ANY settle incl. failure. We deliberately
                        // do NOT add a second, tokenless release here — that was
                        // the clobber hazard (a competing claim landing between two
                        // release points would be freed by the later one). See
                        // `ReconnectCoalescer` generation guard (DEFECT/P3).
                        self.startKeepalive()
                        self.hasReportedPairingRequiredSeen = false
                        self.hasReportedSignatureInvalidSeen = false
                        // #306 (Pairing recovery UX epic): a successful
                        // connect proves the auto-re-pair worked, so reset
                        // the throttle budget for the next failure cycle.
                        self.resetAutoRePairBudget()
                        TelemetryService.shared.track(eventName: TelemetryEvent.gatewayConnected, properties: [
                            "session_type": "node",
                            "reconnect_attempt": attempt,
                            "time_to_connect_ms": connectMs,
                        ])
                        // #306 (Pairing recovery UX epic): if this `.connected`
                        // followed an in-flight re-pair, fire the completion
                        // event so PostHog can measure recovery success rate.
                        if let trigger = self.inFlightRePairTrigger {
                            TelemetryService.shared.track(
                                eventName: TelemetryEvent.gatewayRePairCompleted,
                                properties: ["trigger": trigger])
                            self.inFlightRePairTrigger = nil
                        }
                    case .pairingRequired:
                        self.stopKeepalive()
                        self.reportPairingFailureSeen()
                        if !self.isManagedCloudRePairInFlight {
                            self.dispatchPairingRecovery()
                        }
                    case .unreachable:
                        self.stopKeepalive()
                        TelemetryService.shared.track(eventName: TelemetryEvent.gatewayDisconnected, properties: [
                            "session_type": "node",
                            "reconnect_attempt": self.reconnectAttempt,
                        ])
                        // #306 (Pairing recovery UX epic): trust-revocation
                        // failures (signature_invalid, device_id_mismatch,
                        // revoked) surface as `.unreachable` today — the state
                        // alone doesn't tell support this is a pairing issue.
                        // Emit the signature-invalid-seen event so we can
                        // track the failure rate separately.
                        self.reportPairingFailureSeen()

                        // Pairing-failure classification short-circuits the
                        // normal reconnect ladder: reconnecting with the same
                        // stale token will just loop. Auto-recoverable reasons
                        // (scope-upgrade, signature_expired) → reset and
                        // re-pair silently. Trust-revocation reasons (signature
                        // invalid, device-id mismatch, revoked) → stop and
                        // let the user tap the banner CTA.
                        //
                        // The reason is carried in `.unreachable(String?)` so
                        // we read it synchronously from `newState` here.
                        if case .unreachable(let reason) = newState,
                           self.handleClassifiedUnreachable(reason: reason) == true {
                            return
                        }

                        if self.reconnectAttempt == 0 {
                            // Grace period: first drop is likely transient (Fly proxy,
                            // network blip). Show "Connecting..." instead of "Unreachable"
                            // and immediately reconnect whichever sessions are down
                            // (node, operator, or both).
                            self.connectionState = .connecting
                            self.reconnectAttempt = 1
                            self.reconnectDroppedSessions(trigger: "grace")
                        } else {
                            // Persistent failure — show "Unreachable" with backoff
                            self.scheduleReconnect()
                        }
                    case .disconnected, .unauthorized, .connecting:
                        self.stopKeepalive()
                        if case .disconnected = newState {
                            self.hasReportedPairingRequiredSeen = false
                            self.hasReportedSignatureInvalidSeen = false
                        }
                    }
                }
            }
            await self.client.setOnSkillsChanged { [weak self] in
                await MainActor.run { self?.skillsSnapshotVersion += 1 }
            }
            await self.client.setOnOperatorStateChange { [weak self] connected in
                await MainActor.run {
                    guard let self else { return }
                    if self.operatorReady != connected {
                        self.operatorSessionGeneration &+= 1
                    }
                    self.operatorReady = connected
                }
            }
        }
    }

    // MARK: - Node keepalive

    /// Start a periodic probe that both sessions are actually alive.
    /// Sends real health requests on each WebSocket — if either times out
    /// or errors, that connection has silently dropped and we reconnect it
    /// independently (node-only or operator-only).
    private func startKeepalive() {
        stopKeepalive()
        // Capture interval on MainActor before entering the unstructured Task.
        let interval = keepaliveInterval
        // Require TWO consecutive missed probes before reconnecting. A single
        // slow `health` response under load (or a Fly proxy hiccup) is not proof
        // the socket dropped — reconnecting on the first miss is what turned a
        // transient blip into a self-sustaining feedback loop (reconnect → more
        // load → slower probe → reconnect). Counters live in the task so only
        // ONE keepalive loop ever holds them (stopKeepalive() cancels the prior).
        //
        // Latency note: this is only the SILENT-drop backstop (a drop that never
        // fires OpenClawKit's disconnect callback). Two strikes at a 20s interval
        // means a truly-silent drop is caught in ~40s instead of ~20s — an
        // acceptable trade for killing the churn, because any drop that DOES fire
        // the callback still hits the grace/ladder path immediately, and
        // `ensureNodeConnected()` re-probes before every chat send. The node and
        // operator counters are independent and BOTH probed every tick, so a
        // simultaneously-dead operator is never deferred behind a node miss.
        keepaliveTask = Task { [weak self] in
            var nodeMisses = 0
            var operatorMisses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.connectionState.isConnected else {
                    nodeMisses = 0
                    operatorMisses = 0
                    continue
                }

                var nodeReconnectKicked = false
                let nodeAlive = await self.client.probeNodeAlive()
                if nodeAlive {
                    nodeMisses = 0
                } else {
                    nodeMisses += 1
                    if nodeMisses >= 2 {
                        nodeMisses = 0
                        nodeReconnectKicked = true
                        #if DEBUG
                        print("[Gateway] keepalive: node probe failed twice, reconnecting dropped sessions")
                        #endif
                        self.reconnectDroppedSessions(trigger: "keepalive")
                    }
                    // First miss falls through to still probe the operator — we
                    // only defer the NODE reconnect to the second strike, not the
                    // operator's independent liveness check.
                }

                // If a full reconnect was just kicked it will reconnect the
                // operator too — skip the redundant operator-only path.
                guard !nodeReconnectKicked, self.connectionState.isConnected else {
                    operatorMisses = 0
                    continue
                }

                let operatorAlive = await self.client.probeOperatorAlive()
                if operatorAlive {
                    operatorMisses = 0
                } else {
                    operatorMisses += 1
                    if operatorMisses >= 2 {
                        operatorMisses = 0
                        #if DEBUG
                        print("[Gateway] keepalive: operator probe failed twice, reconnecting operator only")
                        #endif
                        self.reconnectOperatorOnly()
                    }
                }
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// Reconnect whichever sessions are currently disconnected.
    /// If the node is down, reconnects it and re-binds execNode.
    /// If the operator is down (after the node recovers or was already up),
    /// reconnects it too — prevents the app from getting stuck at
    /// "Connecting..." when only the operator session failed.
    private func reconnectDroppedSessions(trigger: String = "reconnect") {
        // Snapshot credentials before entering the Task. If clearConfiguration()
        // runs concurrently, the Task uses the snapshotted (still-valid) values
        // rather than racing against nil.
        guard let urlString = storedGatewayURL,
              let token = storedGatewayToken else { return }
        // Coalesce: if a reconnect is already in flight, skip. `debounce: false`
        // so the backoff ladder's scheduled retry (which may fire within a few
        // seconds) isn't swallowed — only true concurrency blocks here.
        guard let slotToken = reconnectCoalescer.begin(now: CFAbsoluteTimeGetCurrent(), debounce: false) else {
            #if DEBUG
            print("[Gateway] reconnectDroppedSessions(\(trigger)) skipped — reconnect already in flight")
            #endif
            return
        }
        setConnectTrigger(trigger)
        let providerName = storedProviderName
        let sessionKey = mainSessionKey

        Task {
            // Release the slot whenever this reconnect settles — including the
            // escalation paths below, which now AWAIT the fallback so the slot
            // stays HELD until the full reconnect settles (DEFECT/P1). Token'd so
            // a stale release can't clobber a competing claim (DEFECT/P3).
            defer { reconnectCoalescer.end(slotToken) }
            let provider: (any GatewayServerProvider)?
            if providerName == "Railway" {
                provider = RailwayProvider(gatewayURL: urlString, gatewayToken: token)
            } else {
                provider = FlyProvider(gatewayURL: urlString, gatewayToken: token)
            }
            guard let provider else { return }

            // --- Reconnect node if it's down ---
            let nodeAlreadyUp = await client.isNodeConnected
            if !nodeAlreadyUp {
                do {
                    try await client.reconnectNode(provider: provider)
                    reconnectAttempt = 0
                    await bindSessionToCurrentDeviceNode(sessionKey: sessionKey)
                } catch {
                    #if DEBUG
                    print("[Gateway] node reconnect failed: \(error.localizedDescription)")
                    #endif
                    // Escalate to a full reconnect, AWAITED so we keep the slot
                    // we already own until the fallback settles — no free-slot
                    // window where a concurrent trigger could stack a second
                    // socket pair (DEFECT/P1). `performReconnectAwaitingSettle`
                    // claims no slot of its own; the enclosing `defer` releases.
                    await performReconnectAwaitingSettle()
                    return
                }
            }

            // --- Reconnect operator if it's down ---
            let operatorUp = await client.isOperatorConnected
            if !operatorUp {
                do {
                    try await client.reconnectOperator(provider: provider)
                    #if DEBUG
                    print("[Gateway] operator reconnect succeeded (alongside node)")
                    #endif
                } catch {
                    #if DEBUG
                    print("[Gateway] operator reconnect failed: \(error.localizedDescription)")
                    #endif
                    // See node-escalation note above: awaited so the slot stays
                    // held across the fallback (DEFECT/P1).
                    await performReconnectAwaitingSettle()
                    return
                }
            }

            // Both sessions are now up — reset backoff
            if nodeAlreadyUp {
                reconnectAttempt = 0
            }
        }
    }

    /// Reconnect only the operator session (with device identity for scopes),
    /// keeping the node/device alive. Called when the operator silently
    /// drops (detected by keepalive probe). Handles per-role pairing inline.
    private func reconnectOperatorOnly() {
        guard let urlString = storedGatewayURL,
              let token = storedGatewayToken else { return }
        // Participate in the one-owner model (#connection-reliability DEFECT 3):
        // refuse if a full reconnect is already in flight (it reconnects the
        // operator too), and release via `defer` on any settle so this path
        // can't strand the slot either. `debounce: false` — this is a recovery
        // path, not a user/foreground trigger.
        guard let slotToken = reconnectCoalescer.begin(now: CFAbsoluteTimeGetCurrent(), debounce: false) else {
            #if DEBUG
            print("[Gateway] reconnectOperatorOnly skipped — reconnect already in flight")
            #endif
            return
        }

        let providerName = storedProviderName
        Task {
            // Token'd release on any settle, including the awaited escalations
            // below which keep the slot held across the fallback (DEFECT/P1, P3).
            defer { reconnectCoalescer.end(slotToken) }
            let provider: (any GatewayServerProvider)?
            if providerName == "Railway" {
                provider = RailwayProvider(gatewayURL: urlString, gatewayToken: token)
            } else {
                provider = FlyProvider(gatewayURL: urlString, gatewayToken: token)
            }
            guard let provider else { return }

            do {
                try await client.reconnectOperator(provider: provider)
                #if DEBUG
                print("[Gateway] operator-only reconnect succeeded")
                #endif
            } catch {
                let isPairing = "\(error)".lowercased().contains("pair")
                if isPairing {
                    #if DEBUG
                    print("[Gateway] operator reconnect needs pairing, calling auto-approve...")
                    #endif
                    do {
                        try await Self.callApproveDevice()
                        try await Task.sleep(for: .milliseconds(500))
                        try await client.reconnectOperator(provider: provider)
                        #if DEBUG
                        print("[Gateway] operator reconnect succeeded after auto-approve")
                        #endif
                    } catch {
                        #if DEBUG
                        print("[Gateway] operator reconnect failed after auto-approve: \(error.localizedDescription)")
                        #endif
                        // Awaited so the slot stays held across the fallback (P1).
                        await performReconnectAwaitingSettle()
                    }
                } else {
                    #if DEBUG
                    print("[Gateway] operator-only reconnect failed: \(error.localizedDescription)")
                    #endif
                    await performReconnectAwaitingSettle()
                }
            }
        }
    }

    /// Schedules an automatic reconnect with exponential backoff + jitter.
    /// This handles both transient WebSocket drops (iOS backgrounding, network blips)
    /// and the gateway seeing the device as "offline" when it should be online.
    ///
    /// The attempt counter is incremented *after* the sleep completes (not before)
    /// to prevent rapid state changes from skipping backoff levels.
    private func scheduleReconnect() {
        guard isConfigured else { return }
        // Reaching backoff means the grace period already failed and the visible
        // state is `.unreachable` — the user is being shown the "Unreachable"
        // banner. Record that so a later recovery confirms with a "Reconnected"
        // toast (grace-period blips never get here). See `RemReconnectToastPolicy`.
        sawVisibleDisconnect = true
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            // 1s, 2s, 4s, 8s, max 30s — plus jitter to avoid thundering herd
            let base = min(30.0, 1.0 * pow(2.0, Double(attempt)))
            let jitter = Double.random(in: 0..<1.0)
            let delay = base + jitter
            #if DEBUG
            print("[Gateway] auto-reconnect in \(String(format: "%.1f", delay))s (attempt \(attempt + 1))")
            #endif
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // Increment only after the sleep succeeds — if the task is
            // cancelled and replaced, the counter stays at the same level.
            self.reconnectAttempt = attempt + 1
            self.reconnectDroppedSessions(trigger: "backoff")
        }
    }

    // MARK: - Auto-approve pairing

    /// Asks the backend to auto-approve this device's pairing request,
    /// then reconnects. The backend polls the gateway for up to 30s,
    /// so this call blocks until approval succeeds or times out.
    ///
    /// Uses `reconnectInternal()` (not `reconnect()`) to preserve the
    /// `hasRequestedAutoApprove` flag. This prevents a tight loop when
    /// the operator role-upgrade pairing triggers repeated `.pairingRequired`
    /// states. The flag resets after a 10-second cooldown.
    private func requestAutoApprove(allowOneRetry: Bool = true) {
        guard !hasRequestedAutoApprove else { return }
        hasRequestedAutoApprove = true

        Task {
            do {
                #if DEBUG
                print("[Gateway] requesting auto-approve from backend...")
                #endif
                let approval = try await Self.callApproveDeviceResult()
                guard approval.isSuccess else {
                    #if DEBUG
                    print("[Gateway] auto-approve stopped after terminal backend result: \(approval.summary)")
                    #endif
                    hasRequestedAutoApprove = false
                    return
                }
                #if DEBUG
                print("[Gateway] auto-approve succeeded, reconnecting...")
                #endif
                // #306 (Pairing recovery UX epic): stamp whether this is a
                // first-pair or a re-pair so the existing pairing funnel can
                // be split in PostHog. `nextConnectIsRepair` is set by
                // `resetPairing()`; if it's false this is a first-pair.
                TelemetryService.shared.track(
                    eventName: TelemetryEvent.devicePaired,
                    properties: ["is_repair": self.nextConnectIsRepair])
                self.nextConnectIsRepair = false
                // Backend already waits for gateway approval before returning;
                // a brief propagation buffer is sufficient.
                try await Task.sleep(for: .seconds(2))
                reconnectInternal()
            } catch {
                #if DEBUG
                print("[Gateway] auto-approve failed: \(error.localizedDescription)")
                #endif
                // A hard request/setup failure did not change gateway trust.
                // Stop automatic churn and leave the visible manual recovery
                // action available after the underlying problem is repaired.
                hasRequestedAutoApprove = false
                return
            }
            // Reset after a cooldown so the next pairingRequired triggers
            // a fresh attempt. If still stuck, retry once.
            try? await Task.sleep(for: .seconds(15))
            hasRequestedAutoApprove = false
            if allowOneRetry, case .pairingRequired = connectionState {
                #if DEBUG
                print("[Gateway] still pairing-required after cooldown, retrying auto-approve...")
                #endif
                requestAutoApprove(allowOneRetry: false)
            }
        }
    }

    // MARK: - Pairing failure telemetry (#306 Pairing recovery UX epic)

    /// Reads the latest connect failure (typed error preferred, reason
    /// string as fallback), classifies it, and fires one of:
    ///   - `gateway_signature_invalid_seen` — trust-revocation failure
    ///   - `gateway_pairing_required_seen`  — deterministic / unclassified
    /// Each event is de-duped per disconnected→connected cycle so a flapping
    /// session doesn't inflate the funnel.
    private func reportPairingFailureSeen() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.fetchClassificationSnapshot()
            let props: [String: Any] = [
                "reason": snapshot.reason ?? "",
                "error": snapshot.errorDescription ?? "",
                "classification": snapshot.classification.telemetryValue,
                "source": snapshot.source,
            ]
            if snapshot.classification.isTrustRevocation {
                if !self.hasReportedSignatureInvalidSeen {
                    self.hasReportedSignatureInvalidSeen = true
                    TelemetryService.shared.track(
                        eventName: TelemetryEvent.gatewaySignatureInvalidSeen,
                        properties: props)
                }
            } else {
                if !self.hasReportedPairingRequiredSeen {
                    self.hasReportedPairingRequiredSeen = true
                    TelemetryService.shared.track(
                        eventName: TelemetryEvent.gatewayPairingRequiredSeen,
                        properties: props)
                }
            }
        }
    }

    /// Chooses between auto-re-pair and user-tap recovery based on the
    /// classified disconnect reason, per #306 (Pairing recovery UX epic):
    ///
    ///   - `.scopeUpgrade` / `.roleUpgrade` / `.metadataUpgrade` /
    ///     `.signatureExpired` — we caused the mismatch / the user already
    ///     consented once. Clear the token and re-pair silently. Banner copy
    ///     (set elsewhere) shows "Re-pairing…".
    ///   - `.signatureInvalid` / `.deviceIdMismatch` / `.deviceTokenMismatch`
    ///     / `.publicKeyInvalid` / `.nonceMismatch` — the gateway no longer
    ///     trusts this device. Leave state as-is so the banner CTA
    ///     ("Re-pair") shows and the user makes the decision.
    ///   - `.unknown` — fall back to the existing backend auto-approve
    ///     path so we don't regress on unclassified errors the gateway
    ///     surfaces today (empty reason strings, transient issues).
    ///
    /// Loop / churn guard: see `shouldThrottleAutoRePair`. Both this path
    /// and `handleClassifiedUnreachable` consult the same attempts counter
    /// so a flapping connection can't drain auto-re-pairs from either entry
    /// point.
    private func dispatchPairingRecovery() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.fetchClassificationSnapshot()
            if snapshot.classification.isAutoRecoverable {
                if self.shouldThrottleAutoRePair() {
                    // Out of auto-re-pair budget. Fall through so the user
                    // sees a pairing-required CTA instead of silent thrash.
                    self.requestAutoApprove()
                    return
                }
                self.resetPairing(trigger: "auto")
            } else if snapshot.classification.isTrustRevocation {
                // Leave .pairingRequired state visible so the banner's
                // "Re-pair" CTA is available. No auto-recovery — we
                // want the user to know trust was revoked.
                return
            } else {
                // Unknown reason — existing backend auto-approve path.
                self.requestAutoApprove()
            }
        }
    }

    /// Classifies an `.unreachable(reason)` state and short-circuits the
    /// normal reconnect ladder when the failure maps to a pairing failure.
    /// Reads the structured error first, then the reason string as fallback.
    ///
    /// Note: this method is synchronous (called from the state-change
    /// handler), but the structured `lastConnectError` lives on an actor.
    /// We can't await synchronously, so this method falls back to
    /// reason-string classification only — and kicks an async task that
    /// upgrades to typed classification once the actor read completes,
    /// which lets the auto-recoverable path catch device-side trust failures
    /// that arrive structured rather than via the disconnect string.
    ///
    /// Returns `Bool?` so the caller can pattern-match cleanly; `nil` means
    /// "I didn't handle this — do the default thing (reconnect ladder)".
    private func handleClassifiedUnreachable(reason: String?) -> Bool? {
        // Synchronous reason-string classification first (fast path).
        let stringClass = GatewayPairingFailure.from(reasonString: reason)
        if stringClass != .unknown {
            return applyClassifiedRecovery(classification: stringClass)
        }

        // Slow path: try the typed error. We fire an async task here and
        // tentatively let the reconnect ladder run; if the typed
        // classification matches a recoverable kind, the task will preempt
        // by calling resetPairing or flipping to .pairingRequired.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.fetchClassificationSnapshot()
            guard snapshot.classification != .unknown else { return }
            _ = self.applyClassifiedRecovery(classification: snapshot.classification)
        }
        return nil
    }

    /// Acts on a classification: auto-re-pair (if budget available) or flip
    /// to `.pairingRequired` for trust-revocation. Returns true if state was
    /// handled, false otherwise.
    @discardableResult
    private func applyClassifiedRecovery(
        classification: GatewayPairingFailure
    ) -> Bool {
        if classification.isAutoRecoverable {
            if shouldThrottleAutoRePair() {
                connectionState = .pairingRequired
                return true
            }
            resetPairing(trigger: "auto")
            return true
        }
        if classification.isTrustRevocation {
            connectionState = .pairingRequired
            return true
        }
        return false
    }

    // MARK: - Auto-re-pair throttle

    /// Auto-re-pair attempts in the current window. Reset on `.connected`
    /// or after `autoRePairWindow` seconds elapse since the first attempt.
    /// See #306 (Pairing recovery UX epic).
    private var autoRePairAttempts: Int = 0
    private var autoRePairWindowStart: Date?

    private static let maxAutoRePairsPerWindow = 3
    private static let autoRePairWindow: TimeInterval = 5 * 60

    /// True when we've burned our auto-re-pair budget in the current window.
    /// Both `.pairingRequired` and `.unreachable` paths consult this so a
    /// flapping connection can't drain budget from either entry point.
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

    // MARK: - Classification snapshot

    /// Snapshot used by both the telemetry and the dispatcher. Reads the
    /// actor-stored typed error first; falls back to the reason string when
    /// no structured error is available (e.g. post-connect transport drop).
    private struct ClassificationSnapshot {
        let classification: GatewayPairingFailure
        let reason: String?
        let errorDescription: String?
        /// "typed_error" | "reason_string" | "none" — recorded as the
        /// `source` property on telemetry so we can spot regressions where
        /// the typed path stops firing.
        let source: String
    }

    private func fetchClassificationSnapshot() async -> ClassificationSnapshot {
        let error = await client.lastConnectError
        let reason = await client.lastDisconnectReason
        if let error {
            let typed = GatewayPairingFailure.classify(error: error)
            if typed != .unknown {
                return ClassificationSnapshot(
                    classification: typed,
                    reason: reason,
                    errorDescription: String(describing: error),
                    source: "typed_error")
            }
        }
        let stringClass = GatewayPairingFailure.from(reasonString: reason)
        return ClassificationSnapshot(
            classification: stringClass,
            reason: reason,
            errorDescription: error.map { String(describing: $0) },
            source: stringClass == .unknown ? "none" : "reason_string")
    }

    private struct ApproveDeviceResponse: Decodable {
        let ok: Bool?
        let status: String?
        let approved: Int?
        let error: String?
        let message: String?
        let lastError: String?
    }

    private struct ApproveDeviceResult {
        let statusCode: Int
        let response: ApproveDeviceResponse?
        let rawBody: String

        var isSuccess: Bool {
            (200...299).contains(statusCode)
        }

        var approvalStatus: String? {
            response?.status
        }

        var summary: String {
            if let status = response?.status {
                switch status {
                case "approved":
                    if let approved = response?.approved {
                        return "approved \(approved) pending device\(approved == 1 ? "" : "s")"
                    }
                case "no_pending_device":
                    return "no pending device approval request was found"
                case "approval_still_pending":
                    return "approval is still pending; try again shortly"
                case "approval_retry_failed":
                    return response?.message ?? response?.error ?? "approval retry failed"
                case "no_gateway_configured":
                    return response?.message ?? "no gateway is configured for this account"
                default:
                    break
                }
            }
            if response?.ok == false {
                if let message = response?.message, !message.isEmpty {
                    return message
                }
                if let error = response?.error, !error.isEmpty {
                    return error
                }
            }
            if let approved = response?.approved {
                return "approved \(approved) pending device\(approved == 1 ? "" : "s")"
            }
            if let message = response?.message, !message.isEmpty {
                return message
            }
            if let error = response?.error, !error.isEmpty {
                return error
            }
            return rawBody.isEmpty ? "status \(statusCode)" : rawBody
        }

        var userFacingRetryMessage: String {
            switch approvalStatus {
            case "approved":
                return "Connection approved. Reconnecting to your gateway."
            case "no_pending_device":
                return "No pending approval was found on the gateway. Try reconnecting, or repair gateway setup if this keeps happening."
            case "approval_still_pending":
                if let lastError = response?.lastError, !lastError.isEmpty {
                    return "Rem still could not confirm approval: \(lastError). Check gateway setup, then try approval again."
                }
                return "Approval is still pending. Try approval again shortly."
            case "approval_retry_failed":
                if let lastError = response?.lastError, !lastError.isEmpty {
                    return sanitizedApprovalFailureMessage(for: lastError)
                }
                return "Approval retry failed: \(summarySentence)"
            case "no_gateway_configured":
                return "No gateway is configured for this account. Add or repair a gateway first."
            default:
                if isSuccess {
                    return "Backend \(summary); reconnecting."
                }
                return "Approval check failed: \(summarySentence)"
            }
        }

        private var summarySentence: String {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "." }
            if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
                return trimmed
            }
            return "\(trimmed)."
        }

        private func sanitizedApprovalFailureMessage(for lastError: String) -> String {
            let normalized = lastError.lowercased()
            if normalized.contains("control ui requires device identity") {
                return "The cloud gateway's approval settings need repair. Repair gateway setup, then try approval again."
            }
            if normalized.contains("approve-all http") || normalized.contains("{\"ok\"") {
                return "Rem could not finish gateway approval. Check gateway setup, then try again."
            }
            return "Approval retry failed: \(lastError). Check gateway setup, then try again."
        }
    }

    private static func fetchGatewayCredentials() async throws -> GatewayCredentialsResponse {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/me/credentials",
            method: "GET",
            timeout: 30
        )
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw NSError(
                domain: "GatewayCredentials",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "credentials HTTP \(http.statusCode): \(body)"]
            )
        }
        return try GatewayCredentialRefreshPolicy.decodeAndScrubLegacyVoiceKey(
            data: data,
            scrubLegacyVoiceKey: RemCredentialStore.clearElevenLabsApiKeyOrThrow
        )
    }

    /// POST /api/v1/approve-device — backend connects to gateway as operator and approves pending pairing requests.
    private static func callApproveDeviceResult() async throws -> ApproveDeviceResult {
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/approve-device",
            method: "POST",
            body: nil,
            timeout: 45 // Backend polls up to 30s
        )
        let body = String(data: data, encoding: .utf8) ?? ""
        let decoded = try? JSONDecoder().decode(ApproveDeviceResponse.self, from: data)
        return ApproveDeviceResult(statusCode: http.statusCode, response: decoded, rawBody: body)
    }

    private static func callApproveDevice() async throws {
        let result = try await callApproveDeviceResult()
        guard result.isSuccess else {
            throw NSError(
                domain: "ApproveDevice",
                code: result.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "approve-device HTTP \(result.statusCode): \(result.summary)"]
            )
        }
    }

    // MARK: - Credentials (via RemCredentialStore)

    /// Gateway URL string (e.g. "https://my-app.up.railway.app").
    /// Stored in UserDefaults — not sensitive.
    var storedGatewayURL: String? {
        get { RemCredentialStore.gatewayURL }
        set { RemCredentialStore.gatewayURL = newValue }
    }

    /// Gateway token. Stored in Keychain.
    var storedGatewayToken: String? {
        get { RemCredentialStore.gatewayToken }
        set { RemCredentialStore.gatewayToken = newValue }
    }

    /// Hosting provider display name (for Settings UI).
    var storedProviderName: String {
        get { RemCredentialStore.gatewayProviderName }
        set { RemCredentialStore.gatewayProviderName = newValue }
    }

    var activeGatewayProvider: GatewayProvider {
        let normalizedProvider = storedProviderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedProvider.contains("local") || normalizedProvider.contains("mac") {
            return .local
        }
        if normalizedProvider.contains("fly") {
            return .fly
        }
        if normalizedProvider.contains("railway") {
            return .manual
        }

        guard let urlString = storedGatewayURL,
              let host = URL(string: urlString)?.host?.lowercased() else {
            return .manual
        }
        return host.hasSuffix(".fly.dev") ? .fly : .manual
    }

    var sessionPreviewContext: SessionPreviewContext {
        let provider = activeGatewayProvider
        return SessionPreviewContext(
            gatewayProvider: provider.sessionPreviewProvider,
            gatewayName: provider.sessionPreviewGatewayName,
            gatewayId: gatewayHostDisplay,
            deviceId: DeviceIdentityStore.loadOrCreate().deviceId,
            deviceName: Self.localDeviceName
        )
    }

    private var isManagedFlyGateway: Bool {
        if storedProviderName == "Fly.io" {
            return true
        }
        guard let urlString = storedGatewayURL,
              let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host.hasSuffix(".fly.dev")
    }

    /// Best-effort pre-wake for managed Fly gateways. This shifts machine
    /// startup earlier so reconnect latency is less visible to the user.
    func wakeGatewayIfNeeded() async {
        guard isConfigured, isManagedFlyGateway else { return }

        do {
            let (_, http) = try await AuthenticatedHttpClient.request(
                path: "/api/v1/gateway/wake",
                method: "POST",
                timeout: 20
            )
            #if DEBUG
            print("[Gateway] wake status=\(http.statusCode)")
            #endif
        } catch {
            #if DEBUG
            print("[Gateway] wake failed: \(error.localizedDescription)")
            #endif
        }
    }

    func wakeAndConnectIfConfigured() {
        Task { [weak self] in
            guard let self else { return }
            Task {
                await self.wakeGatewayIfNeeded()
            }
            await MainActor.run {
                self.connectIfConfigured()
            }
        }
    }

    // MARK: - Configure (called from onboarding)

    /// Save credentials and connect. Called from QR scan, manual entry, etc.
    func configure(gatewayURL: String, gatewayToken: String, providerName: String = "Fly.io") {
        storedGatewayURL = gatewayURL
        storedGatewayToken = gatewayToken
        storedProviderName = providerName
        isConfigured = true
        connectIfConfigured()
    }

    /// Clear credentials and disconnect. Called from Settings "Change Server".
    func clearConfiguration() {
        invalidateBrowserTakeoverAuthority()
        connectTask?.cancel()
        connectTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stopKeepalive()
        reconnectAttempt = 0
        reconnectCoalescer.reset()
        RemCredentialStore.clearGateway()
        isConfigured = false
        gatewayHostDisplay = nil
        connectionState = .disconnected
        operatorSessionGeneration &+= 1
        operatorReady = false
        hasFetchedPendingDevices = false
        Task { await client.disconnect() }
    }

    // MARK: - Connection lifecycle

    /// Re-reads credential store and updates `isConfigured`. Call after
    /// credentials may have been written externally (e.g. after sign-in restore).
    /// Automatically connects if credentials are present.
    func recheckConfigured() {
        let configured = RemCredentialStore.gatewayURL != nil && RemCredentialStore.gatewayToken != nil
        isConfigured = configured
        print("[RemClaw] recheckConfigured() → isConfigured=\(configured) url=\(RemCredentialStore.gatewayURL ?? "nil")")
        if configured { connectIfConfigured() }
    }

    /// Attempt connection if credentials are available. Safe to call repeatedly.
    func connectIfConfigured() {
        guard let urlString = storedGatewayURL,
              let token = storedGatewayToken else { return }

        // Invalidate the old session synchronously before any credential/socket replacement. This
        // closes same-URL token swaps and prevents an in-flight old-session RPC from being
        // published under the new stored URL.
        invalidateBrowserTakeoverAuthority(preservingRecoverableHandBack: true)
        operatorSessionGeneration &+= 1
        operatorReady = false

        let provider: (any GatewayServerProvider)?
        if storedProviderName == "Railway" {
            provider = RailwayProvider(gatewayURL: urlString, gatewayToken: token)
        } else {
            provider = FlyProvider(gatewayURL: urlString, gatewayToken: token)
        }
        guard let provider else { return }

        gatewayHostDisplay = GatewayHostDisplay.sanitized(provider.gatewayURL.host)
        lastPermissions = RemGatewayClient.permissionsSnapshot()
        connectionStartTime = CFAbsoluteTimeGetCurrent()
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.connect(provider: provider)
            } catch {
                // If the state is still .connecting after connect() threw
                // (e.g. timeout, cancellation), force it to .unreachable so
                // the reconnect logic kicks in instead of hanging forever.
                if case .connecting = self.connectionState {
                    self.connectionState = .unreachable("Connection failed")
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// Test connection health — returns true if gateway responds.
    func testConnection() async -> Bool {
        await client.testConnection()
    }

    /// Reconnect (disconnect then connect). Used by "Reconnect" button in
    /// Settings and error recovery paths.
    func reconnect() {
        reconnect(trigger: "manual")
    }

    /// Foreground-triggered reconnect. Routed through the same coalescer as
    /// every other reconnect, so a rapid background→foreground flap collapses to
    /// a SINGLE reconnect instead of stacking a fresh socket pair on each
    /// `.active`. Tagged "foreground" in the churn log. Call this (not the bare
    /// `reconnect()`) from `scenePhase` handling.
    func reconnectOnForeground() {
        reconnect(trigger: "foreground")
    }

    /// Coalesced reconnect. Refused (no-op) if a reconnect is already in flight
    /// or one started within the debounce window — this is the guard that stops
    /// foreground flaps and error-recovery paths from stacking reconnects.
    private func reconnect(trigger: String) {
        guard let token = reconnectCoalescer.begin(now: CFAbsoluteTimeGetCurrent(), debounce: true) else {
            #if DEBUG
            print("[Gateway] reconnect(\(trigger)) skipped — reconnect already in flight / debounced")
            #endif
            return
        }
        #if DEBUG
        reconnectClaimCountForTesting += 1
        #endif
        setConnectTrigger(trigger)
        // Allow a fresh auto-approve cycle if pairing is required after reconnect.
        hasRequestedAutoApprove = false
        // GUARANTEED slot release on ANY settle — success, failure, or cancel.
        // We own the awaited disconnect+connect here (rather than delegating to
        // the fire-and-forget `reconnectInternal()`) precisely so the `defer`
        // frees the slot even when the reconnect ends in a terminal FAILURE
        // (`.unreachable`/`.pairingRequired`/`.unauthorized`). Releasing only on
        // `.connected` would strand the slot for up to `safetyExpiry`, dead-end
        // the backoff ladder (its `begin(debounce:false)` would be refused), and
        // freeze the manual Reconnect button — worse than the churn we fixed.
        // (#connection-reliability review DEFECT 1) The `end(token)` is
        // generation-guarded so a competing claim can't be clobbered (DEFECT/P3).
        Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectCoalescer.end(token) }
            await self.performReconnectAwaitingSettle()
        }
    }

    /// Awaited disconnect + full reconnect that RESOLVES when the connect
    /// settles (success, failure, or the 10s connect timeout), or immediately if
    /// `connectIfConfigured()` no-ops (no creds). The caller owns the coalescer
    /// slot for the whole call and releases it in its own `defer` AFTER this
    /// returns — so both `reconnect(trigger:)` and the sub-reconnect escalations
    /// keep the slot HELD until the full reconnect settles (no free-slot window
    /// where a concurrent trigger could stack a second socket pair — DEFECT/P1).
    /// We await the inner `connectTask` that `connectIfConfigured()` installs;
    /// this outer flow deliberately does not overwrite `connectTask` itself
    /// (that slot belongs to the connect, which `connectIfConfigured`
    /// cancels/replaces).
    private func performReconnectAwaitingSettle() async {
        await client.disconnect()
        connectIfConfigured()
        await connectTask?.value
    }

    /// Forgets stored device-auth pairing tokens and reconnects so the next
    /// handshake pairs fresh. Used by:
    /// - `GatewayDisconnectedBanner` "Reset & Pair" CTA on `.pairingRequired`
    ///   / `.unauthorized` states (#288)
    /// - Manual recovery from DEVICE_AUTH_SIGNATURE_INVALID / _MISMATCH (#229)
    ///
    /// This is the device-level reset (this device forgets its pairing);
    /// it doesn't touch other devices paired to the same gateway.
    ///
    /// The public overload protocol-satisfies `GatewaySessionProviding`
    /// (which is trigger-agnostic) and reports `trigger: "user"` since only
    /// user-driven UI calls this entry point today. Auto-recovery will call
    /// `resetPairing(trigger: "auto")` in Round 2.
    func resetPairing() {
        resetPairing(trigger: "user")
    }

    /// Re-pair with explicit trigger attribution for telemetry. See `#306
    /// (Pairing recovery UX epic)` for the auto-vs-user decision rule.
    func resetPairing(trigger: String) {
        TelemetryService.shared.track(
            eventName: TelemetryEvent.gatewayRePairInitiated,
            properties: ["trigger": trigger])
        inFlightRePairTrigger = trigger
        nextConnectIsRepair = true
        Task {
            await client.resetPairing()
            hasRequestedAutoApprove = false
            reconnectAttempt = 0
            connectIfConfigured()
        }
    }

    func resetPairing(config: GatewayConfig?, configStore: GatewayConfigStore?) async throws -> String? {
        guard shouldRunManagedCloudRepair(for: config) else {
            resetPairing(trigger: "user")
            return nil
        }

        TelemetryService.shared.track(
            eventName: TelemetryEvent.gatewayRePairInitiated,
            properties: ["trigger": "user", "provider": "fly", "repair_mode": "managed_cloud"])
        inFlightRePairTrigger = "user"
        nextConnectIsRepair = true
        isManagedCloudRePairInFlight = true
        defer { isManagedCloudRePairInFlight = false }

        let credentials = try await Self.fetchGatewayCredentials()
        let refreshedConfig = refreshedGatewayConfig(
            from: credentials,
            replacing: config,
            in: configStore
        )
        configStore?.save(refreshedConfig)

        RemCredentialStore.gatewayURL = refreshedConfig.url
        RemCredentialStore.gatewayToken = refreshedConfig.token
        RemCredentialStore.gatewayProviderName = refreshedConfig.provider == .fly ? "Fly.io" : refreshedConfig.provider.displayName
        gatewayHostDisplay = GatewayHostDisplay.sanitized(URL(string: refreshedConfig.url)?.host)
        hasRequestedAutoApprove = false
        reconnectAttempt = 0

        await client.resetPairing(rotateDeviceIdentity: true)
        connectIfConfigured()

        let repairSignal = await waitForManagedRepairSignal()
        if repairSignal.isConnected {
            return "Cloud credentials refreshed. This device connected after re-pair."
        }

        if repairSignal.shouldApprove {
            let approval = try await Self.callApproveDeviceResult()
            reconnectInternal()

            if approval.isSuccess {
                return "Cloud credentials refreshed. \(approval.userFacingRetryMessage)"
            }

            return "Cloud credentials refreshed, but \(approval.userFacingRetryMessage)"
        }

        let approval = try await Self.callApproveDeviceResult()
        reconnectInternal()
        let prefix = repairSignal.statusMessage ?? "Rem did not see a pairing request yet."

        if approval.isSuccess {
            return "\(prefix) \(approval.userFacingRetryMessage)"
        }

        return "\(prefix) \(approval.userFacingRetryMessage)"
    }

    func requestPairingApproval(config: GatewayConfig?) async throws -> String? {
        guard shouldRunManagedCloudRepair(for: config) else {
            await fetchPendingDevices()
            return "Checked this gateway for pending device approvals."
        }

        let approval = try await Self.callApproveDeviceResult()
        guard approval.isSuccess else {
            // A failed approval did not change gateway trust. Do not create
            // another socket cycle here; the explicit button remains available
            // for the user after the underlying setup problem is repaired.
            return approval.userFacingRetryMessage
        }

        let baselineGeneration = connectionGeneration
        await reconcileAfterPairingApproval(sessionKey: mainSessionKey)
        // Reset both readiness signals synchronously before the awaited socket
        // cycle. This prevents a recovery card mounted for operator approval
        // from observing an old coarse `.connected` value as new success.
        operatorReady = false
        connectionState = .connecting
        await performReconnectAwaitingSettle()

        // "Finish Connection" is an outcome, not merely an HTTP request. Keep
        // the action in-flight until the gateway proves the device is connected;
        // otherwise leave the recovery card mounted with honest retry copy.
        if await waitForConnectionAfterPairingApproval(after: baselineGeneration) {
            return "Connection complete. Rem is connected to your gateway."
        }
        return "Approval succeeded, but Rem is still waiting for the gateway connection. Try again shortly."
    }

    private func waitForConnectionAfterPairingApproval(
        after baselineGeneration: Int,
        timeoutSeconds: Double = 12
    ) async -> Bool {
        await Self.waitForPairingApprovalConnection(
            after: baselineGeneration,
            timeoutSeconds: timeoutSeconds
        ) { [weak self] in
            guard let self else { return (baselineGeneration, false, false) }
            return (self.connectionGeneration, self.connectionState.isConnected, self.operatorReady)
        }
    }

    static func waitForPairingApprovalConnection(
        after baselineGeneration: Int,
        timeoutSeconds: Double,
        pollInterval: Duration = .milliseconds(250),
        snapshot: @escaping @MainActor () -> (generation: Int, nodeConnected: Bool, operatorReady: Bool)
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let state = snapshot()
            if state.generation > baselineGeneration, state.nodeConnected, state.operatorReady { return true }
            try? await Task.sleep(for: pollInterval)
        }
        let state = snapshot()
        return state.generation > baselineGeneration && state.nodeConnected && state.operatorReady
    }

    private struct ManagedRepairSignal {
        var isConnected: Bool
        var shouldApprove: Bool
        var statusMessage: String?
    }

    private func waitForManagedRepairSignal(timeoutSeconds: Double = 8) async -> ManagedRepairSignal {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if connectionState.isConnected {
                return ManagedRepairSignal(isConnected: true, shouldApprove: false, statusMessage: nil)
            }
            if connectionState.needsDeviceRePair {
                return ManagedRepairSignal(isConnected: false, shouldApprove: true, statusMessage: nil)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        return ManagedRepairSignal(
            isConnected: false,
            shouldApprove: false,
            statusMessage: "Cloud credentials refreshed, but Rem did not see a pairing request before the approval check."
        )
    }

    private func shouldRunManagedCloudRepair(for config: GatewayConfig?) -> Bool {
        GatewayRepairPolicy.shouldRunManagedCloudRepair(
            config: config,
            storedProviderName: storedProviderName,
            storedGatewayURL: storedGatewayURL
        )
    }

    private func refreshedGatewayConfig(
        from credentials: GatewayCredentialsResponse,
        replacing config: GatewayConfig?,
        in configStore: GatewayConfigStore?
    ) -> GatewayConfig {
        let provider: GatewayProvider = {
            switch credentials.hostingProvider?.lowercased() {
            case "railway": return .manual
            case "fly", nil: return .fly
            default: return config?.provider ?? .manual
            }
        }()

        let existing = config
            ?? configStore?.activeConfig
            ?? configStore?.configs.first { $0.url == credentials.gatewayUrl && $0.provider == provider }

        return GatewayConfig(
            id: existing?.id ?? UUID().uuidString,
            url: credentials.gatewayUrl,
            token: credentials.gatewayToken,
            provider: provider,
            displayName: existing?.displayName ?? (provider == .fly ? "Cloud Gateway" : provider.displayName),
            macAddress: existing?.macAddress,
            isActive: true,
            transport: existing?.transport,
            tailscaleURL: existing?.tailscaleURL,
            sshLocalPort: existing?.sshLocalPort,
            isBootstrap: existing?.isBootstrap
        )
    }

    /// Internal reconnect that preserves the `hasRequestedAutoApprove` flag.
    /// Used by `requestAutoApprove()` so the cooldown actually prevents
    /// tight retry loops.
    private func reconnectInternal() {
        Task {
            await client.disconnect()
            connectIfConfigured()
        }
    }

    /// Re-checks iOS permissions and probes the node session when the app
    /// returns to foreground. Reconnects fully if permissions changed, or
    /// reconnects just the node if it silently dropped while backgrounded.
    func reconnectIfPermissionsChanged() {
        guard isConfigured, connectionState.isConnected else { return }
        let current = RemGatewayClient.permissionsSnapshot()
        if current != lastPermissions {
            #if DEBUG
            print("[Gateway] permissions changed, reconnecting to update gateway")
            #endif
            lastPermissions = current
            reconnect()
            return
        }

        // Permissions unchanged — probe both sessions to catch silent drops
        // from iOS background suspension.
        Task {
            let nodeAlive = await client.probeNodeAlive()
            if !nodeAlive {
                #if DEBUG
                print("[Gateway] foreground probe: node dead, reconnecting node only")
                #endif
                reconnectDroppedSessions(trigger: "foreground-probe")
            }

            let operatorAlive = await client.probeOperatorAlive()
            if !operatorAlive {
                #if DEBUG
                print("[Gateway] foreground probe: operator dead, reconnecting operator only")
                #endif
                reconnectOperatorOnly()
            }
        }
    }

    /// Probes the node session and reconnects if dead. Call before actions
    /// that depend on the node (e.g., sending a chat message that will
    /// invoke device commands). Returns quickly if the node is alive.
    ///
    /// Also probes the operator session (used for actual chat.send) and
    /// reconnects it independently if needed.
    func ensureNodeConnected() async {
        guard isConfigured, connectionState.isConnected else { return }

        // Probe node — reconnect if dead
        let nodeAlive = await client.probeNodeAlive()
        if !nodeAlive {
            #if DEBUG
            print("[Gateway] ensureNodeConnected: node dead, reconnecting")
            #endif
            reconnectDroppedSessions(trigger: "ensure-node")
            // Poll for reconnection instead of sleeping a fixed duration.
            // Check every 0.5s for up to 5s.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(0.5))
                let recovered = await client.isNodeConnected
                if recovered { break }
            }
        }

        // Probe operator — reconnect if dead (this is what chat.send uses)
        let operatorAlive = await client.probeOperatorAlive()
        if !operatorAlive {
            #if DEBUG
            print("[Gateway] ensureNodeConnected: operator dead, reconnecting")
            #endif
            reconnectOperatorOnly()
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(0.5))
                let recovered = await client.isOperatorConnected
                if recovered { break }
            }
        }
    }

    // MARK: - Chat transport factory

    /// Creates an OpenClawChatTransport for use with OpenClawChatView.
    /// Uses the operator session (role: "operator") which has chat permissions.
    /// The transport probes the node before each send to catch silent drops.
    ///
    /// `priorTranscriptProvider` (optional) lets a task-scoped continuation chat load
    /// its persisted cloud-run transcript as real prior messages — see
    /// `TaskChatTranscriptCoordinator` and `IOSGatewayChatTransport.requestHistory`.
    func makeChatTransport(
        onChatSendDispatched: (@MainActor @Sendable () throws -> Void)? = nil,
        onChatSendAccepted: (@MainActor @Sendable () -> Void)? = nil,
        priorTranscriptProvider: (@Sendable (String) async throws -> [AnyCodable])? = nil,
        onBrowserRunBegan: (@MainActor @Sendable (String, Bool) -> Void)? = nil,
        onBrowserRunEnded: (@MainActor @Sendable (String, String?) -> Void)? = nil,
        onBrowserRunCancelled: (@MainActor @Sendable (String) -> Void)? = nil,
        onBrowserToolActivity: (@MainActor @Sendable (BrowserToolActivity) -> Void)? = nil,
        onRunLifecycleEvidence: (@MainActor @Sendable (RunLifecycleEvidence) -> Void)? = nil,
        lifecycleEpochSource: RunLifecycleEpochSource? = nil,
        initialLifecycleLease: RunLifecycleTransportLease? = nil,
        onRunLifecycleEpoch: (@MainActor @Sendable (RunLifecycleEpoch) -> Void)? = nil
    ) async -> IOSGatewayChatTransport {
        let session = await client.chatSession
        return IOSGatewayChatTransport(
            gateway: session,
            onWillSend: { [weak self] in
                await self?.ensureNodeConnected()
            },
            onChatSendDispatched: onChatSendDispatched,
            onChatSendAccepted: onChatSendAccepted,
            priorTranscriptProvider: priorTranscriptProvider,
            onBrowserRunBegan: onBrowserRunBegan,
            onBrowserRunEnded: onBrowserRunEnded,
            onBrowserRunCancelled: onBrowserRunCancelled,
            onBrowserToolActivity: onBrowserToolActivity,
            onRunLifecycleEvidence: onRunLifecycleEvidence,
            lifecycleEpochSource: lifecycleEpochSource,
            initialLifecycleLease: initialLifecycleLease,
            onRunLifecycleEpoch: onRunLifecycleEpoch
        )
    }

    // MARK: - Browser takeover ↔ agent handshake

    private var browserTakeoverGeneration = 0
    /// The last takeover RPC in flight. Each new signal CHAINS behind it (see below), so signals
    /// execute strictly in call order and never overlap on the wire.
    private var browserTakeoverChain: Task<Void, Never>?
    private let browserHandBackCoordinator = BrowserHandBackCoordinator()

    private func invalidateBrowserTakeoverAuthority(
        preservingRecoverableHandBack: Bool = false
    ) {
        browserTakeoverGeneration += 1
        browserTakeoverChain?.cancel()
        browserTakeoverChain = nil
        browserHandBackCoordinator.invalidate(
            preservingRecoverableAttempt: preservingRecoverableHandBack
        )
    }

    /// Signal the agent about a browser-takeover change: pause (chat.abort) when the user takes the
    /// controls so it stops driving the page, resume (chat.send) when they hand back.
    ///
    /// Two guards, because the two failure modes are different:
    ///  - COALESCING (settle window + generation check): if the user mashes take-over/hand-back, only
    ///    the final intent fires — the intermediate ones are superseded before they reach the wire.
    ///  - SERIALIZATION (the chain): once an RPC IS on the wire it can't be recalled, and a
    ///    session-wide `chat.abort` (no runId) cancels EVERY run — including a resume turn created
    ///    after it. If a hand-back's `chat.send` raced an in-flight take-over abort and the abort
    ///    landed second, it would kill the fresh resume run and leave Rem silently stopped. So each
    ///    signal awaits the previous one's RPC before running: a completed abort can never cancel a
    ///    run that didn't exist yet when it ran.
    ///
    /// `mainSessionKey` is the live view's session in the normal flow; best-effort, no-op before a
    /// session exists. NOTE: a silent no-op if the operator can't authorize the abort (e.g. after an
    /// ownerConnId change) — the user would think the agent is paused when it isn't.
    func signalBrowserTakeover(userIsControlling: Bool) {
        browserTakeoverGeneration += 1
        let generation = browserTakeoverGeneration
        let previous = browserTakeoverChain
        browserTakeoverChain = Task { [weak self] in
            await previous?.value // serialize: don't put a resume on the wire until a prior abort settles
            // Settle window: if the user is mashing take-over/hand-back, only the last intent fires.
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self?.performBrowserTakeover(userIsControlling: userIsControlling, generation: generation)
        }
    }

    private func performBrowserTakeover(userIsControlling: Bool, generation: Int) async {
        guard generation == browserTakeoverGeneration else { return } // superseded by a newer toggle
        guard let sessionKey = mainSessionKey else { return }
        let transport = await makeChatTransport()
        do {
            if userIsControlling {
                try await transport.abortActiveRuns(sessionKey: sessionKey)
            } else {
                // Resume as a HIDDEN control block (stripped to nothing by MessageCleaner) so the
                // hand-back doesn't inject a fake user-style "I've taken control…" bubble. The agent
                // still gets the instruction; the take-over/hand-back stays visible in the live view.
                _ = try await transport.sendMessage(
                    sessionKey: sessionKey,
                    message: BrowserDirective.wrapControl(
                        "The user took control of the browser and has now finished (for example, signing in). If a task was in progress, continue it from here."
                    ),
                    thinking: "off",
                    idempotencyKey: UUID().uuidString,
                    attachments: []
                )
            }
        } catch { print("[Gateway] signalBrowserTakeover(controlling=\(userIsControlling)) failed: \(error)") }
    }

    /// Reserve and accept the hidden continuation before the browser UI claims Rem has control.
    /// The captured authority binds the whole operation to one account, gateway credential set,
    /// operator generation, and browser-owning conversation. A failed send retains its accepted
    /// opaque reservation/idempotency key so retry cannot charge the user twice.
    func resumeBrowserAfterHandBack(
        accountID: String,
        accountLifecycleTicket: UInt64,
        sessionKey: String,
        browserOwnerLifecycleTicket: UInt64,
        accountIsCurrent: @escaping @MainActor () -> Bool,
        browserOwnerIsCurrent: @escaping @MainActor () -> Bool,
        reserveSlot: @escaping @MainActor () async -> BrowserHandBackReservationDecision,
        acknowledgeReservation: @escaping @MainActor @Sendable (
            UsageService.RequestSlotReservation
        ) -> Void,
        cancelReservationBeforeDispatch: @escaping @MainActor @Sendable (
            UsageService.RequestSlotReservation
        ) -> Void
    ) async -> BrowserHandBackOutcome {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty,
              !sessionKey.isEmpty,
              operatorReady,
              let gatewayURL = storedGatewayURL,
              let gatewayToken = storedGatewayToken
        else {
            return .denied("Rem isn't ready to resume this browser session.")
        }

        let authority = BrowserHandBackAuthority(
            accountID: accountID,
            accountLifecycleTicket: accountLifecycleTicket,
            gatewayURL: gatewayURL,
            gatewayToken: gatewayToken,
            credentialLifecycleTicket: RemCredentialStore.gatewayCredentialLifecycleTicket,
            operatorGeneration: operatorSessionGeneration,
            sessionKey: sessionKey,
            browserOwnerLifecycleTicket: browserOwnerLifecycleTicket
        )
        let isStableScopeCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return accountIsCurrent()
                && browserOwnerIsCurrent()
                && self.storedGatewayURL == authority.gatewayURL
                && self.storedGatewayToken == authority.gatewayToken
                && RemCredentialStore.gatewayCredentialLifecycleTicket
                    == authority.credentialLifecycleTicket
        }
        let isAuthorityCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return isStableScopeCurrent()
                && self.operatorReady
                && self.operatorSessionGeneration == authority.operatorGeneration
        }

        // A take-control abort already on the wire must settle before any replacement run exists.
        // Capture the exact predecessor: if this caller becomes stale while awaiting it, the
        // coordinator returns locally without touching a newer caller's attempt.
        let precedingTakeover = browserTakeoverChain
        return await browserHandBackCoordinator.resumeAfterTakeoverSettles(
            waitForTakeover: { await precedingTakeover?.value },
            authority: authority,
            isAuthorityCurrent: isAuthorityCurrent,
            isStableScopeCurrent: isStableScopeCurrent,
            reserve: reserveSlot,
            cancelBeforeDispatch: cancelReservationBeforeDispatch,
            send: { [weak self] idempotencyKey, reservation, onDispatchStarted, onAccepted in
                guard let self, isAuthorityCurrent() else { throw CancellationError() }
                let transport = await self.makeChatTransport(
                    onChatSendDispatched: {
                        guard isAuthorityCurrent() else { throw CancellationError() }
                        onDispatchStarted()
                    },
                    onChatSendAccepted: {
                        acknowledgeReservation(reservation)
                        onAccepted()
                    }
                )
                guard isAuthorityCurrent() else { throw CancellationError() }
                _ = try await transport.sendMessage(
                    sessionKey: authority.sessionKey,
                    message: BrowserDirective.wrapControl(
                        "The user took control of the browser and has now finished (for example, signing in). If a task was in progress, continue it from here."
                    ),
                    thinking: "off",
                    idempotencyKey: idempotencyKey,
                    attachments: []
                )
            }
        )
    }

    /// Binds the active chat session to this device's node ID so node tools
    /// default to the phone when multiple nodes are connected.
    func bindSessionToCurrentDeviceNode(sessionKey: String? = nil) async {
        guard connectionState.isConnected else { return }
        guard let rawKey = sessionKey ?? mainSessionKey else { return }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        struct PatchParams: Codable {
            var key: String
            var verboseLevel: String
            var execNode: String
        }

        let nodeId = DeviceIdentityStore.loadOrCreate().deviceId
        guard !nodeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            let params = PatchParams(key: key, verboseLevel: "on", execNode: nodeId)
            let data = try JSONEncoder().encode(params)
            let json = String(data: data, encoding: .utf8)
            _ = try await client.chatSession.request(
                method: "sessions.patch",
                paramsJSON: json,
                timeoutSeconds: 10
            )
        } catch {
            print("[Gateway] sessions.patch execNode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Linked devices

    /// Fetches the list of paired devices from the gateway.
    /// Updates `linkedDevices` on the main actor for UI consumption.
    func fetchLinkedDevices() {
        guard connectionState.isConnected else {
            #if DEBUG
            print("[Gateway] fetchLinkedDevices: not connected")
            #endif
            return
        }
        guard !isLoadingLinkedDevices else { return }
        isLoadingLinkedDevices = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingLinkedDevices = false }

            do {
                let data = try await self.client.fetchPairedDevices()
                let raw = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                #if DEBUG
                print("[Gateway] device.pair.list raw: \(raw)")
                #endif

                // Try decoding as { "paired": [...] }
                let decoder = JSONDecoder()
                var allDevices: [LinkedDevice] = []
                if let response = try? decoder.decode(LinkedDevicesResponse.self, from: data),
                   let paired = response.paired {
                    allDevices = paired
                } else if let devices = try? decoder.decode([LinkedDevice].self, from: data) {
                    allDevices = devices
                } else {
                    #if DEBUG
                    print("[Gateway] fetchLinkedDevices: could not decode response")
                    #endif
                }

                // Filter: show current device + recently active devices + full devices (node+operator).
                // This removes stale one-time node-only pairings from simulator testing.
                let filtered = allDevices.filter { device in
                    device.isCurrentDevice || device.isRecentlyActive || device.isFullDevice
                }
                #if DEBUG
                print("[Gateway] fetchLinkedDevices: \(allDevices.count) total, \(filtered.count) after filter")
                #endif
                self.linkedDevices = filtered
            } catch {
                #if DEBUG
                print("[Gateway] fetchLinkedDevices failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Unlinks (unpairs) a device from the gateway.
    ///
    /// Mirrors the Mac parity fix for #304 (Unlink Device on Mac doesn't
    /// remove the device from the list): surfaces errors via
    /// `pendingDeviceError`, waits for the gateway to commit before refresh,
    /// and verifies the removal actually stuck.
    func unlinkDevice(_ device: LinkedDevice) {
        guard connectionState.isConnected, operatorReady else {
            pendingDeviceError = "Can't unlink — gateway not connected yet."
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
                #if DEBUG
                print("[Gateway] unpaired device: \(device.deviceId)")
                #endif

                // Give the gateway a moment to commit the removal before
                // refreshing — without this the refresh frequently races
                // the commit and the device appears to still be paired.
                try? await Task.sleep(for: .milliseconds(500))
                self.fetchLinkedDevices()

                // Verify it stuck; if not, hint at the likely root cause
                // (a token minted before #287 without `operator.pairing`).
                try? await Task.sleep(for: .milliseconds(500))
                if self.linkedDevices.contains(where: { $0.deviceId == device.deviceId }) {
                    self.pendingDeviceError = "Unlink didn't stick. Try Re-pair this device, then try again."
                }
            } catch {
                self.pendingDeviceError = "Failed to unlink: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Pending devices

    /// Fetches the list of devices awaiting pairing approval from the gateway.
    /// Skips redundant fetches after the first successful load unless the list is empty.
    func fetchPendingDevices() async {
        await fetchPendingDevices(force: false)
    }

    private func fetchPendingDevices(force: Bool) async {
        guard connectionState.isConnected else {
            #if DEBUG
            print("[Gateway] fetchPendingDevices: not connected")
            #endif
            return
        }
        guard force || !hasFetchedPendingDevices || pendingDevices.isEmpty else { return }
        guard !isLoadingPendingDevices else { return }
        isLoadingPendingDevices = true
        defer { isLoadingPendingDevices = false }

        do {
            let data = try await client.fetchPairedDevices()
            let decoder = JSONDecoder()
            if let response = try? decoder.decode(PendingDevicesResponse.self, from: data),
               let pending = response.pending {
                #if DEBUG
                print("[Gateway] fetchPendingDevices: \(pending.count) pending")
                #endif
                pendingDevices = pending
            } else {
                pendingDevices = []
            }
            hasFetchedPendingDevices = true
        } catch {
            #if DEBUG
            print("[Gateway] fetchPendingDevices failed: \(error.localizedDescription)")
            #endif
        }
    }

    /// Approves a pending device pairing request via the gateway operator session.
    func approveDevice(_ device: PendingDevice) {
        guard connectionState.isConnected, operatorReady else { return }

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
                #if DEBUG
                print("[Gateway] approved device: \(device.requestId)")
                #endif
                // Reflect the user's action immediately, then force a fresh
                // gateway read so stale pending state cannot keep chat stuck in
                // "pairing required" after the approval was accepted.
                self.pendingDevices.removeAll { $0.requestId == device.requestId }
                self.hasFetchedPendingDevices = false
                await self.reconcileAfterPairingApproval(sessionKey: self.mainSessionKey)
                self.reconnectInternal()
            } catch {
                // A stale/unknown requestId is not a real failure: the request
                // was almost always already resolved by the backend auto-approve
                // (`requestAutoApprove()` → POST /approve-device, which approves
                // *all* pending requests whenever the node session hits
                // `.pairingRequired`), or the originating connection dropped and
                // the gateway retired the pending entry. Either way the device is
                // effectively approved — don't show the user a scary error.
                // Treat it exactly like the success path: clear the stale row and
                // re-read the gateway so the UI reconciles.
                if DevicePairingErrorClassifier.isStaleRequest(error) {
                    #if DEBUG
                    print("[Gateway] approve: requestId already resolved (stale), reconciling")
                    #endif
                    self.pendingDevices.removeAll { $0.requestId == device.requestId }
                    self.hasFetchedPendingDevices = false
                    await self.reconcileAfterPairingApproval(sessionKey: self.mainSessionKey)
                    self.reconnectInternal()
                    return
                }
                self.pendingDeviceError = "Failed to approve device: \(error.localizedDescription)"
                #if DEBUG
                print("[Gateway] approve failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Keeps the visible device-approval UI and chat transport from drifting
    /// after the gateway accepts a pairing request.
    ///
    /// Approval can commit before the active chat session has fresh routing
    /// metadata. If the user immediately retries the message, the gateway may
    /// still report `pairing required before node invoke` unless we refresh
    /// pending/linked devices and re-bind the session's exec node first.
    private func reconcileAfterPairingApproval(sessionKey: String?) async {
        try? await Task.sleep(for: .milliseconds(500))
        await fetchPendingDevices(force: true)
        fetchLinkedDevices()

        if let sessionKey {
            await bindSessionToCurrentDeviceNode(sessionKey: sessionKey)
        } else {
            await bindSessionToCurrentDeviceNode()
        }
    }

    /// Declines (rejects) a pending device pairing request.
    func declineDevice(_ device: PendingDevice) {
        guard connectionState.isConnected, operatorReady else { return }

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
                #if DEBUG
                print("[Gateway] declined device: \(device.requestId)")
                #endif
                self.pendingDevices.removeAll { $0.requestId == device.requestId }
                self.hasFetchedPendingDevices = false
                try? await Task.sleep(for: .milliseconds(300))
                await self.fetchPendingDevices(force: true)
            } catch {
                // Same stale-requestId reasoning as approveDevice: if the request
                // is already gone, declining it is a no-op success, not an error.
                if DevicePairingErrorClassifier.isStaleRequest(error) {
                    #if DEBUG
                    print("[Gateway] decline: requestId already resolved (stale), refreshing")
                    #endif
                    self.pendingDevices.removeAll { $0.requestId == device.requestId }
                    self.hasFetchedPendingDevices = false
                    try? await Task.sleep(for: .milliseconds(300))
                    await self.fetchPendingDevices(force: true)
                    return
                }
                self.pendingDeviceError = "Failed to decline device: \(error.localizedDescription)"
                #if DEBUG
                print("[Gateway] decline failed: \(error.localizedDescription)")
                #endif
            }
        }
    }
}

private extension GatewayProvider {
    var sessionPreviewProvider: SessionPreviewEntry.GatewayProvider {
        switch self {
        case .fly: .cloud
        case .local: .mac
        case .manual: .manual
        }
    }

    var sessionPreviewGatewayName: String {
        switch self {
        case .fly: "Cloud Gateway"
        case .local: "Local Mac Gateway"
        case .manual: "Manual Gateway"
        }
    }
}

private extension RemGatewaySessionManager {
    static var localDeviceName: String? {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName
        #endif
    }
}

// MARK: - Linked Device Model
// LinkedDevice, DevicePlatform, DeviceToken, and LinkedDevicesResponse are now
// defined in Shared/Models/LinkedDevice.swift for cross-platform use.
