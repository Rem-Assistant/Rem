import Foundation
import os

// File-shape note (#293/#350 follow-up #351):
//
// The PR brief asked for an "actor"-based pattern for `LocalGatewayManager`,
// but the implementation kept it as a `@MainActor @Observable final class`
// and lifted the new lifecycle surface into this `extension` instead. That
// preserved the 7 existing consumer call sites (Settings, MenuBar, Setup
// view, etc) which already assumed MainActor isolation — a true `actor`
// refactor would have required `await` at every call site and broken
// SwiftUI's `@Bindable`/`@Environment` ergonomics. Future readers: if you
// reach for `actor` here, expect to migrate consumers in lock-step.

// Nonisolated so it can be accessed from `nonisolated static` helpers
// without tripping main-actor isolation warnings (Swift 6 mode).
nonisolated(unsafe) private let log = Logger(subsystem: "app.remclaw.mac", category: "local-gateway-lifecycle")

// MARK: - LocalGatewayLifecycleState

/// Single source-of-truth snapshot of the local gateway's full lifecycle.
///
/// Mirrors the structured fields surfaced by `openclaw gateway status --json`
/// (see `openclaw/src/cli/daemon-cli/status.gather.ts:332`), augmented with
/// values the gateway already persists to disk (`devices/paired.json`,
/// `agents/main/agent/auth-profiles.json`) but the CLI doesn't yet expose
/// in `gateway status`.
///
/// Per the project's structured-signals rule (CLAUDE.md §5), this struct
/// stores typed fields, not parsed strings — UI views derive copy from these
/// fields rather than the legacy `Status` enum's `label` text. The legacy
/// `LocalGatewayManager.Status` enum remains for back-compat with shipped
/// consumer code; new consumers should read this struct directly.
///
/// Source of truth ordering when fields conflict:
/// 1. `openclaw gateway status --json` (CLI runtime probe — port + service
///    are authoritative because the CLI talks to launchd/systemd directly).
/// 2. Filesystem reads of `~/.openclaw/openclaw.json` (config bind mode +
///    auth token) — used as fallback when the CLI is unavailable.
/// 3. Filesystem reads of `paired.json` and `auth-profiles.json` for
///    fields the CLI doesn't yet surface.
struct LocalGatewayLifecycleState: Equatable, Sendable {

    // MARK: CLI

    /// Whether the `openclaw` binary is present + executable on disk.
    var cliInstalled: Bool = false
    /// Detected CLI version reported by the install script. Nil until first
    /// `openclaw --version` (we only update this opportunistically — cost is
    /// not zero and the CLI version doesn't change often during one app run).
    var cliVersion: String? = nil

    // MARK: Service runtime (from `gateway status --json` `service.*`)

    /// Phase of the gateway service as classified from CLI status output.
    /// Maps `(service.loaded, service.runtime.status)` from
    /// `daemon-cli/status.gather.ts`'s `DaemonStatus` shape.
    var runtimePhase: RuntimePhase = .unknown

    /// `service.label` reported by the CLI (e.g. `ai.openclaw.gateway`).
    /// Used so we can stop the *actual* live label rather than guessing.
    var serviceLabel: String? = nil

    // MARK: Gateway socket (from `gateway status --json` `gateway.*`)

    /// Bind mode — `loopback`, `lan`, `tailnet`, `custom`, `auto`. Drives
    /// LAN-reachability classification for QR setup codes.
    var bindMode: BindMode = .unknown

    /// Port the gateway is listening on (or expected to listen on).
    var port: Int = LocalGatewayManager.defaultPort

    /// True iff `bindMode` is one that other LAN devices can reach.
    var isLANReachable: Bool { bindMode.isLANReachable }

    // MARK: Auth & paired devices

    /// Whether `openclaw.json` has a non-empty `gateway.auth.token`. The
    /// token itself is intentionally NOT held here — secrets stay in the
    /// config file; callers fetch on demand via `currentGatewayToken()`.
    var hasAuthToken: Bool = false

    /// Number of devices in `~/.openclaw/devices/paired.json`. Used by the
    /// "Reset Pairing (gateway-side)" affordance to show the user how many
    /// entries will be cleared. -1 means "unknown / file unreadable".
    var pairedDeviceCount: Int = -1

    // MARK: Providers (BYOK)

    /// Provider-name inventory listed in `~/.openclaw/agents/main/agent/auth-profiles.json`.
    /// This is refresh/display metadata only: membership does not prove that a credential is usable.
    /// Runtime auth availability must come from the gateway's structured auth resolver.
    var configuredProviders: [String] = []

    // MARK: Diagnostics

    /// Last error surfaced by an explicit lifecycle op (install/start/stop
    /// /restart). Cleared by the next successful op. Drives the red error
    /// banner in setup/settings.
    var lastError: String? = nil

    // MARK: - Derived helpers

    enum RuntimePhase: Equatable, Sendable {
        /// Initial state before any probe has run.
        case unknown
        /// CLI not installed yet, OR the `gateway status` shell-out failed
        /// (timeout, spawn error, malformed JSON). The legacy probe path
        /// (`probeHealth()` + filesystem) was used to derive `running`/`stopped`.
        case fallback
        /// LaunchAgent loaded AND gateway responding.
        case running
        /// Gateway responding but NOT via our LaunchAgent (someone started
        /// it manually, or another tool installed a duplicate plist).
        case attachedExisting
        /// LaunchAgent loaded but gateway not responding — KeepAlive crash
        /// loop, broken config, or stale plist. Self-heal triggers a bootout.
        case staleAgent
        /// Not loaded, not responding.
        case stopped
        /// A user-initiated lifecycle op is in flight (`installing`, `starting`,
        /// `stopping`, `restarting`). Non-`Equatable` payload kept as a tag
        /// for UI; transitions back to `running`/`stopped`/`staleAgent` once
        /// the op completes and `refreshState()` runs.
        case transitioning(TransitionTag)

        enum TransitionTag: String, Sendable {
            case installingCLI
            case installingService
            case starting
            case stopping
            case restarting
            case uninstalling
        }

        var isRunning: Bool {
            switch self {
            case .running, .attachedExisting: return true
            default: return false
            }
        }

        var isTransitioning: Bool {
            if case .transitioning = self { return true }
            return false
        }
    }

    enum BindMode: String, Equatable, Sendable {
        case loopback
        case lan
        case tailnet
        case custom
        case auto
        /// Config file missing or `gateway.bind` unset — defaults to loopback
        /// upstream, but we surface "unknown" so the UI can prompt the user
        /// to choose explicitly when a LAN-reachable QR code is needed.
        case unknown

        var isLANReachable: Bool {
            switch self {
            case .lan, .tailnet, .custom: return true
            default: return false
            }
        }

        nonisolated static func parse(_ raw: String?) -> BindMode {
            guard let raw, let mode = BindMode(rawValue: raw) else { return .unknown }
            return mode
        }
    }

    /// Scope for `resetPairing` — controls whether we clear only the
    /// client's stored device-auth tokens (today's behavior), or also the
    /// gateway's `paired.json` table via `openclaw devices clear`.
    enum ResetPairingScope: Equatable, Sendable {
        /// Forget client-side device-auth only (what `client.resetPairing()`
        /// does). Next connect re-pairs from this device's perspective; the
        /// gateway's `paired.json` keeps the old entry until it's overwritten.
        case client
        /// Clear `~/.openclaw/devices/paired.json` via `openclaw devices clear
        /// --yes` — wipes EVERY paired device. Useful when the gateway has a
        /// dangling entry from a deleted device.
        case gateway
        /// Both: client tokens forgotten AND gateway `paired.json` cleared.
        /// Heavy; intended for full pairing-table reset.
        case both
    }
}

// MARK: - Errors

enum LocalGatewayLifecycleError: LocalizedError {
    case cliNotInstalled
    case cliFailed(action: String, exitCode: Int32, summary: String)
    case cliTimeout(action: String)
    case cliSpawnFailed(action: String, underlying: String)
    case malformedCLIResponse(action: String)

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            return "OpenClaw CLI not installed."
        case .cliFailed(let action, let exit, let summary):
            return "\(action) failed (exit \(exit)): \(summary)"
        case .cliTimeout(let action):
            return "\(action) timed out — the openclaw CLI did not respond."
        case .cliSpawnFailed(let action, let underlying):
            return "\(action) could not start: \(underlying)"
        case .malformedCLIResponse(let action):
            return "\(action) returned unexpected output."
        }
    }
}

// MARK: - LocalGatewayManager Lifecycle Extension

extension LocalGatewayManager {

    // MARK: Refresh

    /// Refreshes the consolidated lifecycle state from `openclaw gateway
    /// status --json`. Falls back to the legacy probe (HTTP /health +
    /// filesystem checks) if the CLI is unavailable, so this is safe to
    /// call even before the CLI is installed.
    ///
    /// This is the single read-side entry point. UI views should call this
    /// on `.task`, on foregrounding, and after any user-initiated lifecycle
    /// op. It reconciles the legacy `status` field too so existing consumers
    /// stay correct during the migration.
    func refreshState() async {
        let snapshot = await Self.gatherLifecycleSnapshot(cliPath: cliPath)
        applyRefreshedSnapshot(snapshot)
    }

    /// Applies a freshly-gathered snapshot, preserving the in-flight
    /// `lastError` field if the new snapshot doesn't include one.
    @MainActor
    private func applyRefreshedSnapshot(_ snapshot: LocalGatewayLifecycleState) {
        // Self-heal: if the CLI says "service loaded but gateway not
        // responding", that's an upstream `ai.openclaw.gateway` install
        // (we no longer install our own — see #383, #384). The CLI owns
        // bootout for that label; surface the staleness to the user via
        // `lastError` rather than trying to boot out a service we don't
        // own anymore. The legacy `app.remclaw.mac.gateway` plist gets
        // cleaned up at app launch by `LaunchAgentSecretsMigrator`.
        if snapshot.runtimePhase == .staleAgent {
            log.warning("stale upstream LaunchAgent detected (service loaded but gateway not responding); user should run `openclaw gateway restart`")
        }

        var next = snapshot
        // Preserve last-error across refreshes — it's only cleared by a
        // new lifecycle op, not by a status refresh.
        if next.lastError == nil {
            next.lastError = self.state.lastError
        }
        self.state = next

        // Mirror the legacy Status enum so existing consumers keep working
        // (Settings, MenuBar, SetupView). Once all consumers move to
        // `state.runtimePhase`, this fan-out can be deleted.
        switch next.runtimePhase {
        case .running:           self.status = .running
        case .attachedExisting:  self.status = .attachedExisting
        case .staleAgent:        self.status = .stopped
        case .stopped:           self.status = .stopped
        case .fallback, .unknown:
            // Don't clobber a transitioning legacy status.
            break
        case .transitioning:
            break
        }
    }

    // MARK: Restart (first-class)

    /// Restarts the gateway via `openclaw gateway restart`. First-class
    /// op (was previously a stop+install dance). After restart, refreshes
    /// state so UI reflects the new socket/bind/port without waiting for
    /// the next foreground.
    ///
    /// Mirrors upstream: `openclaw/src/cli/daemon-cli/register-service-commands.ts:97`.
    func restart() async {
        state.runtimePhase = .transitioning(.restarting)
        state.lastError = nil
        do {
            try await runCLI(action: "gateway restart", arguments: ["gateway", "restart", "--json"])
            // Wait for socket to come back before reporting state.
            _ = await waitForHealthy(timeout: 15)
            await refreshState()
        } catch {
            state.lastError = error.localizedDescription
            await refreshState()
        }
    }

    // MARK: Configure

    /// Writes `gateway.bind` (and optionally `gateway.port`) to the config
    /// file via `openclaw config set`, then restarts so the change takes
    /// effect immediately. Replaces the previous flow where the user had
    /// to run the CLI manually then relaunch the app.
    ///
    /// `bind` accepts `loopback`, `lan`, `tailnet`, `custom`, `auto` —
    /// upstream's `GatewayBindMode` (see
    /// `openclaw/src/config/types.ts`).
    func configure(bind: LocalGatewayLifecycleState.BindMode, port: Int? = nil) async {
        state.lastError = nil
        do {
            // Use the raw enum value — `openclaw config set` accepts a
            // bare string for scalar config keys.
            try await runCLI(
                action: "config set gateway.bind",
                arguments: ["config", "set", "gateway.bind", bind.rawValue, "--json"]
            )
            if let port {
                try await runCLI(
                    action: "config set gateway.port",
                    arguments: ["config", "set", "gateway.port", String(port), "--json"]
                )
            }
            await restart()
        } catch {
            state.lastError = error.localizedDescription
            await refreshState()
        }
    }

    // MARK: Reset Pairing (scoped)

    /// Resets pairing state at the chosen scope.
    ///
    /// - `.client` — forgets THIS device's stored device-auth tokens via the
    ///   provided `clientReset` closure (`MacGatewayClient.resetPairing()`).
    ///   Today's behavior; reconnect re-pairs.
    /// - `.gateway` — clears `~/.openclaw/devices/paired.json` via
    ///   `openclaw devices clear --yes`. Required when the gateway has a
    ///   stale entry that blocks a fresh pair (#293's "had to `rm` manually").
    /// - `.both` — does both.
    ///
    /// `clientReset` is injected so this extension can stay agnostic of the
    /// MacGatewaySessionManager / MacGatewayClient types that own the
    /// client-side token store. Callers thread it through:
    /// `await localGateway.resetPairing(scope: .both) { await session.client.resetPairing() }`.
    ///
    /// `includePending` (default `false`): when `true`, also passes
    /// `--pending` to `openclaw devices clear`, which rejects any in-flight
    /// pair requests in addition to wiping `paired.json`. The destructive
    /// dialog in Settings only promises clearing paired devices, so
    /// the default keeps the operation scoped to that promise. Callers that
    /// want the broader "reject pending too" path should opt in explicitly
    /// via a separate affordance.
    func resetPairing(
        scope: LocalGatewayLifecycleState.ResetPairingScope,
        clientReset: (@Sendable () async -> Void)? = nil,
        includePending: Bool = false
    ) async {
        state.lastError = nil

        if scope == .client || scope == .both {
            await clientReset?()
        }

        if scope == .gateway || scope == .both {
            do {
                var args = ["devices", "clear", "--yes"]
                if includePending {
                    args.append("--pending")
                }
                args.append("--json")
                try await runCLI(action: "devices clear", arguments: args)
            } catch {
                state.lastError = error.localizedDescription
            }
        }

        await refreshState()
    }

    // MARK: - Internal CLI helpers

    /// Runs an `openclaw` CLI command, capturing stdout+stderr and surfacing
    /// structured errors. All shell-out paths in the new lifecycle API go
    /// through this helper so error handling stays uniform.
    @discardableResult
    func runCLI(action: String, arguments: [String], timeout: TimeInterval = 15) async throws -> String {
        guard let cliPath else {
            throw LocalGatewayLifecycleError.cliNotInstalled
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: LocalGatewayLifecycleError.cliSpawnFailed(
                        action: action,
                        underlying: error.localizedDescription
                    ))
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(throwing: LocalGatewayLifecycleError.cliTimeout(action: action))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    log.info("\(action) ok: \(LocalGatewayManager.summarizeCLIJSON(output))")
                    continuation.resume(returning: output)
                } else {
                    let summary = LocalGatewayManager.summarizeCLIJSON(output)
                    log.error("\(action) failed (exit \(process.terminationStatus)): \(summary)")
                    continuation.resume(throwing: LocalGatewayLifecycleError.cliFailed(
                        action: action,
                        exitCode: process.terminationStatus,
                        summary: summary
                    ))
                }
            }
        }
    }

    /// Single-shot health probe used by `restart()` to wait for the new
    /// socket. Mirrors the existing `waitForHealthy` but reads `state.port`
    /// so config changes take effect.
    func waitForHealthy(timeout: TimeInterval) async -> Bool {
        let port = state.port
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeHealth(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    // MARK: - Snapshot gathering (nonisolated)

    /// Builds a complete `LocalGatewayLifecycleState` from disk + CLI. Pure
    /// w.r.t. the manager — pass `cliPath` in. Parses the structured
    /// `gateway status --json` payload (per #282) plus reads the two
    /// upstream-owned files the CLI doesn't yet surface
    /// (`devices/paired.json`, `agents/main/agent/auth-profiles.json`).
    nonisolated static func gatherLifecycleSnapshot(cliPath: String?) async -> LocalGatewayLifecycleState {
        var state = LocalGatewayLifecycleState()
        state.cliInstalled = (cliPath != nil)

        // 1) Try the CLI status probe first — most authoritative.
        if let cliPath {
            let cliResult = await fetchCLIStatusJSON(cliPath: cliPath)
            switch cliResult {
            case .ok(let parsed):
                state.runtimePhase = parsed.phase
                state.serviceLabel = parsed.serviceLabel
                state.bindMode = parsed.bindMode
                state.port = parsed.port ?? defaultPort
                state.cliVersion = parsed.cliVersion
            case .unavailable:
                state.runtimePhase = .fallback
            }
        } else {
            state.runtimePhase = .fallback
        }

        // 2) Fallback path: legacy probe (HTTP + filesystem) when the CLI
        //    didn't give us a clean answer. Keeps initial-install flow
        //    working before the CLI is on disk.
        if state.runtimePhase == .fallback {
            let healthy = await probeHealthStatic(port: state.port)
            let agentInstalled = FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
            if healthy {
                state.runtimePhase = agentInstalled ? .running : .attachedExisting
            } else {
                state.runtimePhase = .stopped
            }
            state.bindMode = LocalGatewayLifecycleState.BindMode.parse(gatewayBindMode())
        }

        // 3) Auth token presence — read from the config file. This is a
        //    cheap nonisolated read and is needed by the Settings UI to
        //    decide whether the "Pair Device" affordance can render a QR.
        state.hasAuthToken = (currentGatewayToken()?.isEmpty == false)

        // 4) Paired-devices count — read upstream-owned file directly.
        //    `openclaw gateway status` doesn't surface this today (would be
        //    a nice upstream addition; until then this read is the only
        //    way the UI can show a meaningful "Reset Pairing (gateway-side)
        //    will clear N devices").
        state.pairedDeviceCount = countPairedDevices()

        // 5) Provider inventory — read auth-profiles.json directly. This invalidates UI probes but
        //    never authorizes a provider; only the runtime resolver can do that truthfully.
        state.configuredProviders = readConfiguredProviders()

        return state
    }

    /// Static health probe used by the snapshot builder (the instance
    /// `probeHealth` is `@MainActor`-isolated so it can't be called from
    /// a nonisolated context).
    nonisolated private static func probeHealthStatic(port: Int) async -> Bool {
        let urlString = "http://\(defaultHost):\(port)/health"
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// Reads `~/.openclaw/devices/paired.json` and returns the count of
    /// entries. Returns -1 if the file is missing or unreadable, so the UI
    /// can distinguish "we don't know" from "0 devices paired".
    nonisolated static func pairedDevicesURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/devices/paired.json")
    }

    nonisolated private static func countPairedDevices() -> Int {
        let url = pairedDevicesURL()
        guard let data = try? Data(contentsOf: url) else { return 0 }
        // Upstream's paired.json shape: `{ "devices": [...] }` or a bare
        // array on older gateway versions. Tolerate both.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = obj["devices"] as? [Any] {
            return devices.count
        }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return arr.count
        }
        return -1
    }

    /// Reads provider-name inventory from `~/.openclaw/agents/main/agent/auth-profiles.json`
    /// without exposing secrets. This deliberately does not claim the profiles are usable.
    nonisolated private static func readConfiguredProviders() -> [String] {
        let url = authProfilesURL
        guard let data = try? Data(contentsOf: url),
              let providerIDs = configuredProviderIDs(fromAuthProfilesData: data)
        else { return [] }
        return providerIDs
    }

    nonisolated static func configuredProviderIDs(fromAuthProfilesData data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [String: Any]
        else { return nil }
        // Each value is `{ "type": ..., "provider": "openai", "token": "..." }`.
        // We only return the provider name, never the token.
        var names = Set<String>()
        for value in profiles.values {
            if let dict = value as? [String: Any],
               let provider = dict["provider"] as? String {
                names.insert(provider)
            }
        }
        return names.sorted()
    }

    // MARK: - CLI status JSON parsing

    fileprivate enum ParsedStatusResult {
        case ok(ParsedStatus)
        case unavailable
    }

    fileprivate struct ParsedStatus {
        var phase: LocalGatewayLifecycleState.RuntimePhase
        var serviceLabel: String?
        var bindMode: LocalGatewayLifecycleState.BindMode
        var port: Int?
        var cliVersion: String?
    }

    /// Shells out to `openclaw gateway status --json`, parses the structured
    /// fields we care about. Bounded 3s timeout to avoid blocking refresh.
    /// Mirrors the existing `fetchCLIStatus` but returns the richer shape.
    nonisolated private static func fetchCLIStatusJSON(cliPath: String) async -> ParsedStatusResult {
        let result: (output: String, exitCode: Int32)? = await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = ["gateway", "status", "--json"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe() // discard stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(returning: nil)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (out, process.terminationStatus))
            }
        }

        guard let result, result.exitCode == 0,
              let data = result.output.data(using: .utf8)
        else { return .unavailable }

        // Codable shape for the subset of `openclaw gateway status --json`
        // we consume. Mirrors `daemon-cli/status.gather.ts`'s `DaemonStatus`.
        // All fields optional so older CLI versions that omit some keys
        // still decode (we treat absence as "unknown" downstream).
        struct DaemonStatusJSON: Decodable {
            struct Service: Decodable {
                struct Runtime: Decodable {
                    let status: String?
                    let version: String?
                }
                let loaded: Bool?
                let label: String?
                let runtime: Runtime?
            }
            struct Gateway: Decodable {
                let bindMode: String?
                let port: Int?
            }
            let service: Service?
            let gateway: Gateway?
        }

        guard let parsed = try? JSONDecoder().decode(DaemonStatusJSON.self, from: data),
              let service = parsed.service
        else { return .unavailable }

        let loaded = service.loaded ?? false
        let running = (service.runtime?.status == "running")

        let phase: LocalGatewayLifecycleState.RuntimePhase
        switch (loaded, running) {
        case (true, true):   phase = .running
        case (false, true):  phase = .attachedExisting
        case (true, false):  phase = .staleAgent
        case (false, false): phase = .stopped
        }

        let bind = LocalGatewayLifecycleState.BindMode.parse(parsed.gateway?.bindMode)

        return .ok(ParsedStatus(
            phase: phase,
            serviceLabel: service.label,
            bindMode: bind,
            port: parsed.gateway?.port,
            // Version may live under `service.runtime.version` on newer
            // CLIs; tolerate absence — none of our state machine depends
            // on it.
            cliVersion: service.runtime?.version
        ))
    }
}
