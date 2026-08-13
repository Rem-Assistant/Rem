import AppKit
import Foundation
import os

private let log = Logger(subsystem: "app.remclaw.mac", category: "local-gateway")

/// Manages the full lifecycle of a local OpenClaw gateway process.
///
/// Adapted from the reference OpenClaw macOS app's `GatewayProcessManager`
/// and `CLIInstaller`. Handles:
/// - CLI binary detection and installation
/// - Gateway process start/stop as a child process owned by the Mac app
/// - Health checking via HTTP
/// - Token generation
@MainActor @Observable
final class LocalGatewayManager {

    // MARK: - Status

    enum Status: Equatable {
        case stopped
        case installingCLI(String)
        case starting
        case running
        case attachedExisting
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "Stopped"
            case .installingCLI(let msg): msg
            case .starting: "Starting..."
            case .running: "Running"
            case .attachedExisting: "Using existing gateway"
            case .failed(let reason): "Failed: \(reason)"
            }
        }

        var isRunning: Bool {
            switch self {
            case .running, .attachedExisting: true
            default: false
            }
        }
    }

    // MARK: - State

    /// Legacy view of gateway state. Retained because shipped consumers
    /// (in-app Settings, `LocalGatewaySetupView`, `RemClawMacApp`,
    /// `MenuBarPopover`) read `.status.isRunning` and `.status.label`.
    /// New consumers should prefer `state` (see #293).
    ///
    /// Setter is module-internal (not `private(set)`) so the extension
    /// in `LocalGatewayLifecycle.swift` can mirror state struct → enum.
    var status: Status = .stopped

    /// Single-source-of-truth lifecycle snapshot (#293). Populated by
    /// `refreshState()`; kept in lock-step with the legacy `status` enum
    /// for back-compat. UI views should read this struct's typed fields
    /// rather than parse the legacy `status.label` text.
    var state: LocalGatewayLifecycleState = LocalGatewayLifecycleState()

    private(set) var isCLIInstalled: Bool = false
    private(set) var cliPath: String?

    // MARK: - Constants

    nonisolated static let defaultPort = 18789
    nonisolated static let defaultHost = "127.0.0.1"

    /// User-facing install command shown in `LocalGatewaySetupView` for
    /// copy-paste into Terminal. Mirrors the upstream openclaw docs
    /// (`--proto '=https' --tlsv1.2`) and avoids shell builtins like
    /// `set -o pipefail` that would look noisy when displayed.
    nonisolated static let installCommand = "curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh | bash"

    /// Gateway URL for a local instance.
    nonisolated static func gatewayURL(port: Int = defaultPort) -> String {
        "http://\(defaultHost):\(port)"
    }

    /// The LaunchAgent label and plist path.
    nonisolated static let launchAgentLabel = "app.remclaw.mac.gateway"

    nonisolated static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private static let keychainService = "com.remapp.rem.mac"

    // MARK: - Private

    private var healthPollTask: Task<Void, Never>?

    /// The child gateway process we spawn from `start()`. Owned by this
    /// manager so `stop()` can terminate it deterministically. Replaces
    /// the pre-#383 LaunchAgent path (see file header comment + #384) —
    /// gateway lifetime is now bounded by the Mac app's lifetime, which
    /// makes "what's running where" inspectable from the app rather than
    /// requiring `launchctl list` and `~/Library/LaunchAgents` archaeology.
    ///
    /// `nil` while the gateway is stopped or attached to an externally-
    /// managed instance (e.g. the upstream `openclaw` CLI a power user is
    /// running themselves).
    private var childGatewayProcess: Process?

    /// Paths to search for the `openclaw` binary.
    private static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.openclaw/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.local/bin",
        ]
    }()

    private static var installPrefix: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw")
            .path
    }

    /// Path to the openclaw config file that the CLI reads on startup.
    nonisolated static var configFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw")
            .appendingPathComponent("openclaw.json")
    }

    // MARK: - Config

    /// Merges `gateway.mode = "local"` into `~/.openclaw/openclaw.json`, creating
    /// the file if needed. The CLI requires this entry to start without
    /// `--allow-unconfigured` (which upstream marks as a dev escape hatch);
    /// writing it here is the canonical path per upstream docs.
    ///
    /// Also strips the legacy `"ai"` top-level key that earlier RemClaw builds
    /// wrote to the config. Upstream's schema has no `"ai"` entry; when present
    /// the gateway fails validation with `Unrecognized key: "ai"` and crashloops.
    nonisolated static func ensureLocalGatewayConfig() throws {
        let configPath = configFileURL
        var config: [String: Any] = [:]

        if let data = try? Data(contentsOf: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        // Heal old configs that contain the rejected "ai" block.
        if config["ai"] != nil {
            log.info("stripping legacy 'ai' key from openclaw.json (rejected by upstream schema)")
            config.removeValue(forKey: "ai")
        }

        var gatewayConfig = config["gateway"] as? [String: Any] ?? [:]
        gatewayConfig["mode"] = "local"
        config["gateway"] = gatewayConfig

        try FileManager.default.createDirectory(
            at: configPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configPath)
    }

    // MARK: - CLI Detection

    /// Checks whether the `openclaw` binary exists and is executable. Also
    /// mirrors the result into `state.cliInstalled` so consumers using the
    /// new lifecycle struct (#293) see the change without waiting for the
    /// next `refreshState()`.
    func detectCLI() {
        let fm = FileManager.default
        for basePath in Self.searchPaths {
            let candidate = (basePath as NSString).appendingPathComponent("openclaw")
            let exists = fm.fileExists(atPath: candidate)
            let executable = fm.isExecutableFile(atPath: candidate)
            if exists || executable {
                log.info("detectCLI: \(candidate) exists=\(exists) executable=\(executable)")
            }
            if executable {
                cliPath = candidate
                isCLIInstalled = true
                state.cliInstalled = true
                log.info("openclaw CLI found at \(candidate)")
                return
            }
        }

        // Also check the install prefix directly in case searchPaths missed it
        let directPath = (Self.installPrefix as NSString).appendingPathComponent("bin/openclaw")
        if fm.isExecutableFile(atPath: directPath) {
            cliPath = directPath
            isCLIInstalled = true
            state.cliInstalled = true
            log.info("openclaw CLI found at direct path \(directPath)")
            return
        }
        if fm.fileExists(atPath: directPath) {
            log.warning("openclaw exists at \(directPath) but is NOT executable")
            // Try to make it executable
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directPath)
            if fm.isExecutableFile(atPath: directPath) {
                cliPath = directPath
                isCLIInstalled = true
                state.cliInstalled = true
                log.info("openclaw CLI found after chmod at \(directPath)")
                return
            }
        }

        cliPath = nil
        isCLIInstalled = false
        state.cliInstalled = false
        log.info("openclaw CLI not found in: \(Self.searchPaths + [directPath])")
    }

    // MARK: - CLI Installation

    /// Downloads and installs the OpenClaw CLI using the official install script.
    /// Adapted from the reference OpenClaw `CLIInstaller`.
    func installCLI() async {
        status = .installingCLI("Installing OpenClaw CLI...")
        log.info("starting CLI installation...")

        let prefix = Self.installPrefix
        // Use openclaw.ai (the canonical install host); openclaw.bot returns
        // TLS reset and silently produces empty stdin to bash, masking the
        // failure as exit 0. set -o pipefail propagates any curl failure
        // through the pipe so installExitCode reflects reality. --proto/--tlsv1.2
        // match the upstream openclaw install docs.
        let script = """
            set -o pipefail
            curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh | \
            bash -s -- --json --no-onboard --prefix '\(prefix)'
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Run the install process off the MainActor to avoid blocking the main thread
        let (output, installExitCode): (String, Int32)
        do {
            (output, installExitCode) = try await Task.detached(priority: .userInitiated) {
                try process.run()
                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(data: outputData, encoding: .utf8) ?? ""
                return (out, process.terminationStatus)
            }.value
        } catch {
            log.error("CLI install process launch failed: \(error.localizedDescription)")
            status = .failed("Install failed: \(error.localizedDescription)")
            return
        }

        if installExitCode == 0 {
            // Parse JSON events to find installed version
            let version = Self.parseInstalledVersion(from: output)
            let summary = version.map { "Installed openclaw \($0)." } ?? "Installed openclaw."
            log.info("\(summary)")
            status = .installingCLI(summary)

            // Append `~/.openclaw/bin` to the user's shell rc so `openclaw` is
            // on PATH in new terminals. Upstream's install.sh does the same
            // thing for `~/.local/bin` and `~/.npm-global/bin` (see
            // `openclaw/scripts/install.sh:1735`), but since we pass
            // `--prefix ~/.openclaw` the binary lands outside the dirs
            // upstream auto-PATHs. Non-blocking: failures just log. See #292.
            Self.ensureCLIOnShellPath()

            // The installed binary may not be visible to isExecutableFile() immediately
            // after the install process exits. Retry detection with short delays.
            for attempt in 1...5 {
                try? await Task.sleep(for: .milliseconds(500))
                detectCLI()
                if isCLIInstalled {
                    log.info("CLI detected on attempt \(attempt)")
                    break
                }
                log.info("CLI not yet visible, retry \(attempt)/5")
            }
        } else {
            let errorMsg = Self.parseInstallError(from: output)
                ?? output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200).description
            log.error("CLI install failed (exit \(installExitCode)): \(errorMsg)")
            status = .failed("Install failed: \(errorMsg)")
        }
    }

    // MARK: - Token Generation

    /// Generates a cryptographically random 32-byte hex token.
    nonisolated static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - LaunchAgent Management (legacy)

    // Post-#383 / #384, the Mac app no longer installs a LaunchAgent for
    // the gateway. The lifecycle is owned by `start()` / `stop()` via a
    // child `Process()` — see those methods for the rationale. The two
    // `installLaunchAgent` / `uninstallLaunchAgent` methods below are
    // retained as escape hatches for power-user flows (e.g. opting into
    // upstream's `ai.openclaw.gateway` background lifetime by hand) and
    // for the staleAgent self-heal path. Neither runs from the in-app
    // happy path anymore. The legacy `app.remclaw.mac.gateway` plist is
    // scrubbed at launch by `LaunchAgentSecretsMigrator`.

    /// Whether a LaunchAgent plist is currently installed at our legacy
    /// label's path. Kept so `LaunchAgentSecretsMigrator` and diagnostic
    /// logs can detect leftover state. New code should not branch on
    /// this — runtime phase comes from `state.runtimePhase`.
    func isLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: Self.launchAgentPlistURL.path)
    }

    /// Installs the gateway LaunchAgent by delegating to the upstream CLI
    /// (`openclaw gateway install`). Retained as an escape hatch — not
    /// called from the in-app start path post-#383.
    ///
    /// Lets the CLI generate and persist the gateway auth token in the
    /// config file — we read it back via `currentGatewayToken()`. This
    /// is the upstream pattern: config file is the single source of truth
    /// for auth, the LaunchAgent just inherits from it.
    func installLaunchAgent(port: Int = defaultPort) async throws {
        guard let path = cliPath else {
            throw NSError(domain: "LocalGateway", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "OpenClaw CLI not installed"])
        }

        let cliPath = path
        let (exitCode, output) = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [
                "gateway", "install",
                "--force",
                "--port", "\(port)",
                "--runtime", "node",
                "--json",
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out)
        }.value

        if exitCode == 0 {
            // Log only the safe summary fields; the raw --json output may
            // include tokenResolution warnings that surface the auth token.
            log.info("gateway install: \(Self.summarizeCLIJSON(output))")
        } else {
            // Both the log and the NSError description use the summarized
            // form. The description propagates up via
            // `status = .failed(error.localizedDescription)` into the Mac UI,
            // so it also must not leak secrets.
            let summary = Self.summarizeCLIJSON(output)
            log.error("gateway install failed (exit \(exitCode)): \(summary)")
            throw NSError(domain: "LocalGateway", code: Int(exitCode),
                          userInfo: [NSLocalizedDescriptionKey: "gateway install failed (exit \(exitCode)): \(summary)"])
        }
    }

    /// Extracts only the safe summary fields from an `openclaw ... --json`
    /// response. Upstream responses can carry token/secret fields (e.g.
    /// `tokenResolution.warnings`) that must not land in logs.
    nonisolated static func summarizeCLIJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "<unparseable>"
        }
        let keys = ["action", "ok", "result", "message"]
        let pairs = keys.compactMap { k -> String? in
            guard let v = obj[k] else { return nil }
            return "\(k)=\(v)"
        }
        return pairs.joined(separator: " ")
    }

    /// Reads the gateway auth token from `~/.openclaw/openclaw.json` after
    /// `openclaw gateway install` has run. Upstream writes this to
    /// `gateway.auth.token`. Returns nil if the config file doesn't exist
    /// or the token isn't set yet.
    nonisolated static func currentGatewayToken() -> String? {
        guard let data = try? Data(contentsOf: configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Builds a `GatewaySetupCode` suitable for pairing a *different* device
    /// (iPhone, iPad, another Mac) by shelling out to `openclaw qr --json`
    /// — upstream's canonical pairing-code emitter. Upstream owns the
    /// payload shape (currently `{ url, bootstrapToken }`), the LAN-
    /// reachable URL resolution, and the bootstrap-token minting. By
    /// delegating instead of constructing a `{ url, token }` payload
    /// locally, we get upstream's pair-bootstrap handshake transparently:
    /// the iOS decoder reads `bootstrapToken`, sets `isBootstrap: true`,
    /// and OpenClawKit's `GatewayChannel` exchanges it for a persistent
    /// device-auth token at connect time. See #300b, #300a, and
    /// `openclaw/src/cli/qr-cli.ts:223-230` for the JSON shape.
    ///
    /// Lookup order: explicit `~/.openclaw/bin/openclaw` first (the path
    /// our installer writes), then PATH fallback for users who installed
    /// via Homebrew or another route. Returns nil if the CLI is missing,
    /// the gateway hasn't been started yet (no setup code to mint), the
    /// JSON payload doesn't decode, or the CLI is too old to support
    /// `--json` (in which case stderr is captured and logged so the user
    /// can tell what went wrong).
    nonisolated static func pairableSetupCode() -> GatewaySetupCode? {
        let cli = resolveCLIPath()
        guard let cli else {
            log.warning("pairableSetupCode: openclaw CLI not found in ~/.openclaw/bin or PATH")
            return nil
        }

        let process = Process()
        // PATH-fallback case (cli == "openclaw") needs a login shell to pick
        // up rc-file PATH adjustments from Homebrew/custom installs. Stderr
        // noise from those rc files is benign unless upstream exits non-zero.
        // Explicit-path case can exec the binary directly — both faster and
        // avoids any shell-escaping concerns.
        if cli == "openclaw" {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", "openclaw qr --json"]
        } else {
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["qr", "--json"]
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("pairableSetupCode: failed to launch openclaw qr: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            // Surface stderr verbatim — covers "unknown option --json" on
            // older CLIs, "gateway not running", and other actionable
            // failure modes upstream emits with a useful message.
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log.error("pairableSetupCode: openclaw qr --json exited \(process.terminationStatus): \(stderr, privacy: .public)")
            return nil
        }

        let payload: PairableSetupCodePayload
        switch PairableSetupCodePayload.decode(stdoutData) {
        case .success(let decodedPayload):
            payload = decodedPayload
        case .failure(let error):
            let preview = String(data: stdoutData, encoding: .utf8)?.prefix(200) ?? ""
            log.error("pairableSetupCode: failed to decode qr --json output: \(error.localizedDescription, privacy: .public) — output: \(preview, privacy: .public)")
            return nil
        }

        guard let decoded = GatewaySetupCode.decode(payload.setupCode) else {
            log.error("pairableSetupCode: openclaw qr returned a setupCode that did not decode")
            return nil
        }
        return decoded
    }

    /// Picks the `openclaw` binary path: explicit installed location first,
    /// PATH fallback otherwise. Returns nil if neither is available.
    /// The PATH-fallback sentinel is the literal string `"openclaw"`,
    /// which the caller runs through `bash -lc` so the user's login shell
    /// resolves it. `nonisolated` so it can be called from
    /// `pairableSetupCode`, which is itself nonisolated to support sync
    /// access from SwiftUI computed properties on existing call sites.
    nonisolated private static func resolveCLIPath() -> String? {
        let fm = FileManager.default
        // Mirror `installPrefix` (main-actor isolated, can't be touched
        // from this nonisolated context) — `~/.openclaw/bin/openclaw`.
        let explicit = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/bin/openclaw")
            .path
        if fm.isExecutableFile(atPath: explicit) {
            return explicit
        }
        // PATH fallback — defer the actual lookup to bash so we honor the
        // user's login PATH (Homebrew on Apple Silicon, custom prefixes,
        // etc). We don't `which openclaw` ourselves because that needs
        // the same login-PATH spawn anyway.
        return "openclaw"
    }

    /// Reads `gateway.bind` from the config file. Upstream defines values
    /// `loopback` (127.0.0.1-only), `lan` (all LAN interfaces), `tailnet`
    /// (Tailscale only), `custom`, and `auto`. Missing or `loopback`/`auto`
    /// typically means the gateway is NOT reachable from other LAN devices
    /// — relevant for pairing, because even a valid setup code can't help
    /// if the TCP socket isn't listening on the LAN interface.
    ///
    /// Returns nil if the config file can't be read or the key is absent.
    nonisolated static func gatewayBindMode() -> String? {
        guard let data = try? Data(contentsOf: configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let bind = gateway["bind"] as? String
        else { return nil }
        return bind
    }

    /// True when the current bind mode is likely to accept LAN connections.
    /// Returns false when the gateway is loopback-bound or missing a bind
    /// config (which defaults to loopback upstream) — in those cases a
    /// setup code's URL won't resolve from another device.
    nonisolated static func isLANReachable() -> Bool {
        switch gatewayBindMode() {
        case "lan", "tailnet", "custom": return true
        default: return false
        }
    }

    /// Path to the default agent's auth-profiles.json (upstream's canonical
    /// location for provider credentials, post 2026-04). Format:
    /// `{ version: 1, profiles: { "<profileId>": { type, provider, token|key } } }`.
    nonisolated static var authProfilesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/agents/main/agent/auth-profiles.json")
    }

    /// Writes a provider token into the default agent's `auth-profiles.json`
    /// and registers the profile in the gateway config — mirrors what
    /// `openclaw models auth paste-token --provider <p>` does when it's
    /// driven interactively.
    ///
    /// Upstream moved provider credentials out of `models.providers.<p>.apiKey`
    /// (config) into per-agent `auth-profiles.json`. Our prior impl wrote to
    /// the deprecated config path; the gateway stopped reading it, so users
    /// who typed a key in the setup wizard got "No API key found for
    /// provider" at first chat. See #291.
    ///
    /// We write the file directly rather than shelling out to `paste-token`
    /// because that command requires a TTY for secure prompting — we don't
    /// have one from `Process`. The auth-profiles.json format is
    /// upstream-owned (see `openclaw/src/agents/auth-profiles/types.ts`); if
    /// the schema changes there, we'll need to chase. Acceptable risk for
    /// BYOK.
    func setProviderApiKey(provider: String, apiKey: String) async throws {
        let profileId = "\(provider):manual"
        try Self.writeAuthProfile(provider: provider, profileId: profileId, token: apiKey)

        // Register the profile in the gateway config so agents can discover
        // it. Value is a JSON object per upstream's AuthProfileConfig shape.
        try await setConfigJSON(
            path: "auth.profiles.\(profileId)",
            json: "{\"provider\":\"\(provider)\",\"mode\":\"token\"}"
        )
    }

    /// Writes/updates a single entry in `auth-profiles.json` at the default
    /// agent's path. Preserves other profiles. Creates parent dirs with
    /// 0700/0600 permissions since the file holds secrets.
    nonisolated static func writeAuthProfile(
        provider: String,
        profileId: String,
        token: String
    ) throws {
        let url = authProfilesURL
        let fm = FileManager.default

        try fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        if (root["version"] as? Int) == nil {
            root["version"] = 1
        }
        var profiles = (root["profiles"] as? [String: Any]) ?? [:]
        profiles[profileId] = [
            "type": "token",
            "provider": provider,
            "token": token,
        ]
        root["profiles"] = profiles

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Shells out to `openclaw config set <path> <json-value> --json` for
    /// config paths whose value is an object (not a scalar). The CLI
    /// requires JSON-encoded values for non-string fields.
    private func setConfigJSON(path: String, json: String) async throws {
        guard let cliPath = cliPath else {
            throw NSError(domain: "LocalGateway", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "OpenClaw CLI not installed"])
        }

        let (exitCode, output) = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["config", "set", path, json, "--json"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, out)
        }.value

        if exitCode == 0 {
            log.info("registered auth profile at \(path)")
        } else {
            log.error("config set failed (exit \(exitCode)): \(Self.summarizeCLIJSON(output))")
            throw NSError(domain: "LocalGateway", code: Int(exitCode),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to register auth profile: exit \(exitCode)"])
        }
    }

    /// Restarts the gateway via the upstream CLI so it picks up config
    /// changes (e.g. after `setProviderApiKey`).
    func restartGateway() async {
        guard let path = cliPath else { return }

        let cliPath = path
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["gateway", "restart", "--json"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log.info("gateway restart exit \(process.terminationStatus): \(Self.summarizeCLIJSON(output))")
            } catch {
                log.error("gateway restart failed: \(error.localizedDescription)")
            }
        }.value
    }

    /// Uninstalls the gateway LaunchAgent via the upstream CLI
    /// (`openclaw gateway uninstall`). Mirror of `installLaunchAgent`.
    func uninstallLaunchAgent() async {
        guard let path = cliPath else {
            // If the CLI isn't installed anymore, fall back to removing the
            // plist file directly so we don't leave a dangling install.
            try? FileManager.default.removeItem(at: Self.launchAgentPlistURL)
            return
        }

        let cliPath = path
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["gateway", "uninstall", "--json"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    log.info("gateway uninstall: \(Self.summarizeCLIJSON(output))")
                } else {
                    log.warning("gateway uninstall exit \(process.terminationStatus): \(Self.summarizeCLIJSON(output))")
                }
            } catch {
                log.error("gateway uninstall failed: \(error.localizedDescription)")
            }
        }.value
    }

    // MARK: - Gateway Lifecycle

    /// Starts the local gateway as a *child process* of the Mac app.
    ///
    /// Replaces the pre-#383 LaunchAgent install path. Rationale (issues
    /// #383, #384):
    /// 1. Earlier builds installed `~/Library/LaunchAgents/app.remclaw.mac.gateway.plist`
    ///    with `KeepAlive=true` and the user's API keys + gateway token in
    ///    plaintext under `EnvironmentVariables`. Even after we stopped
    ///    embedding secrets (#275), the LaunchAgent itself was invisible
    ///    state the user couldn't manage from the app — see #384.
    /// 2. Spawning as a child process means gateway lifetime ≡ app lifetime.
    ///    No hidden plist, no respawn loop after `pkill`, no conflict with
    ///    upstream's own `ai.openclaw.gateway` plist for users who run the
    ///    `openclaw` CLI directly. Power users who want background lifetime
    ///    can still install upstream's LaunchAgent via `openclaw gateway
    ///    install` themselves — that path is intentionally not driven from
    ///    the app anymore.
    /// 3. Env vars (the legacy leak vector) never touch disk: anything we
    ///    pass goes through `process.environment` in memory and dies with
    ///    the process.
    ///
    /// Token handling: the gateway picks up `gateway.auth.token` from the
    /// config file (upstream's source of truth). We don't generate or
    /// pass tokens via env any more; if the config is missing one the
    /// CLI mints one on first run. The `token` parameter is kept for
    /// source-compat with shipped Settings consumers.
    /// but is intentionally ignored.
    ///
    /// Lifecycle invariants:
    /// - On entry: `childGatewayProcess` is `nil` (we tear down any
    ///   pre-existing process first).
    /// - On `.running` exit: `childGatewayProcess` holds a live `Process`
    ///   whose `terminationHandler` clears `status` and `childGatewayProcess`
    ///   when the gateway exits unexpectedly.
    /// - On `.attachedExisting` exit: the gateway is already running on
    ///   `port` (perhaps via upstream's LaunchAgent or a CLI in another
    ///   shell). We don't spawn — `childGatewayProcess` stays `nil`,
    ///   `stop()` is a no-op, the user manages it externally.
    /// - On `.failed` exit: `childGatewayProcess` is `nil`.
    func start(port: Int = defaultPort, token _: String? = nil) async {
        guard let cliPath else {
            status = .failed("OpenClaw CLI not installed")
            return
        }

        // First check if something is already running on the port — could
        // be the user's own `openclaw gateway run`, an upstream-installed
        // LaunchAgent, or a stale child from a prior crash. Don't try to
        // own a process we didn't spawn.
        if await probeHealth(port: port) {
            log.info("attached to existing gateway on port \(port)")
            status = .attachedExisting
            await refreshState()
            return
        }

        status = .starting
        log.info("starting local gateway on port \(port) as child process")

        do {
            // Ensure ~/.openclaw/openclaw.json has gateway.mode = "local" so
            // the CLI doesn't exit immediately with "Missing config".
            try Self.ensureLocalGatewayConfig()
        } catch {
            log.error("ensureLocalGatewayConfig failed: \(error.localizedDescription)")
            status = .failed("Config write failed: \(error.localizedDescription)")
            return
        }

        // Tear down any prior child we own. Nil after this on either path.
        if let prior = childGatewayProcess {
            log.info("terminating prior child gateway process before respawn")
            prior.terminate()
            childGatewayProcess = nil
        }

        // Spawn `openclaw gateway run --port <port>`. Inherit the user's
        // env minus anything starting with `OPENAI_` / `ANTHROPIC_` /
        // `OPENCLAW_AUTH_` so we don't accidentally re-leak a value that
        // was set in the user's shell rc — the gateway should pull keys
        // from the config file (auth-profiles.json + gateway.auth.token),
        // not env vars. Defense in depth.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["gateway", "run", "--port", "\(port)"]
        let env = Self.sanitizedChildEnvironment()

        // Restore essentials that the sandbox strips but openclaw CLI needs.
        // Without HOME the CLI can't find ~/.openclaw; without PATH it can't
        // resolve node. Fall back to computed values if the host env is gone.
        var safeEnv = env
        if safeEnv["HOME"] == nil {
            safeEnv["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if safeEnv["PATH"] == nil {
            safeEnv["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        if safeEnv["USER"] == nil {
            safeEnv["USER"] = NSUserName()
        }
        if safeEnv["TMPDIR"] == nil {
            safeEnv["TMPDIR"] = NSTemporaryDirectory()
        }
        // Ensure the shell script's bash can be found.
        safeEnv["PATH"] = "/bin:/usr/bin:" + safeEnv["PATH"]!
        // HOME must exist for bash to resolve ~ in the shebang.
        if safeEnv["HOME"] == nil {
            safeEnv["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        process.environment = safeEnv

        log.info("spawning gateway: \(cliPath) gateway run --port \(port)")
        log.info("env HOME=\(safeEnv["HOME"]!, privacy: .public) PATH=\(safeEnv["PATH"]!, privacy: .public)")

        // Capture stdout/stderr to the standard log location so the
        // user (and our troubleshooting doc) can `tail` it. Falls back
        // to /dev/null if the directory can't be made; we'd rather lose
        // log lines than fail to start.
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RemClaw")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("local-gateway.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            // Append rather than overwrite — keep history across restarts.
            try? logHandle.seekToEnd()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        process.terminationHandler = { [weak self] proc in
            // Hop back to MainActor — `terminationHandler` fires on a
            // background queue but our state mutations are MainActor-
            // isolated.
            Task { @MainActor [weak self] in
                guard let self, self.childGatewayProcess === proc else { return }
                log.info("child gateway process exited (status \(proc.terminationStatus, privacy: .public))")
                self.childGatewayProcess = nil
                if self.status.isRunning {
                    self.status = .stopped
                    await self.refreshState()
                }
            }
        }

        do {
            try process.run()
            childGatewayProcess = process
        } catch {
            log.error("failed to spawn gateway: \(error.localizedDescription)")
            status = .failed("Failed to start gateway: \(error.localizedDescription)")
            return
        }

        let healthy = await waitForHealthy(port: port, timeout: 15)
        if healthy {
            status = .running
            log.info("local gateway is healthy on port \(port)")
        } else {
            log.error("gateway started but health check timed out")
            // The child is still alive but unresponsive — terminate so
            // we don't leak a zombie. terminationHandler will clear state.
            process.terminate()
            status = .failed("Gateway started but not responding")
        }

        // Refresh the consolidated lifecycle snapshot so the new state
        // struct (#293) reflects the just-started gateway's bind mode,
        // port, and service label.
        await refreshState()
    }

    /// Stops the running gateway. If we own the child process we
    /// terminate it; if we attached to an externally-running gateway
    /// (`.attachedExisting`) we leave it alone — `stop` is the caller's
    /// way of saying "I'm done with it", not "kill whatever's there".
    func stop() {
        healthPollTask?.cancel()
        healthPollTask = nil
        UserDefaults.standard.removeObject(forKey: "local_gateway_token")

        if let child = childGatewayProcess {
            log.info("terminating child gateway process")
            child.terminate()
            // terminationHandler clears `childGatewayProcess` + status.
            // Synchronously set status here too so observers don't see
            // a stale `running` while the process tears down.
            childGatewayProcess = nil
        }
        status = .stopped

        // Refresh consolidated lifecycle state (#293) so consumers
        // reading `state.runtimePhase` see `.stopped` immediately.
        Task { [weak self] in
            await self?.refreshState()
        }
    }

    /// Baseline env for the child gateway process. Strips API-key prefixes
    /// but keeps everything else the system provides (PATH, HOME, etc.).
    /// TODO(#387): replace this denylist with an allowlist if BYOK/provider
    /// env plumbing keeps expanding.
    /// Caller supplements with fallbacks for sandboxed/safe environments.
    nonisolated private static func sanitizedChildEnvironment() -> [String: String] {
        let secretPrefixes = [
            "OPENAI_",
            "ANTHROPIC_",
            "OPENCLAW_AUTH_",
            "MISTRAL_",
        ]
        let secretKeys = [
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "OPENROUTER_API_KEY",
            "GROQ_API_KEY",
            "DEEPSEEK_API_KEY",
            "XAI_API_KEY",
        ]

        return ProcessInfo.processInfo.environment.filter { key, _ in
            !secretKeys.contains(key) && !secretPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    /// Reloads the gateway so it picks up a new provider API key after
    /// `setProviderApiKey` wrote it to `auth-profiles.json`.
    ///
    /// Post-#383 the gateway is a child process owned by this manager,
    /// so "restart" is `stop()` + `start()` rather than `openclaw gateway
    /// restart` (which only works against upstream's LaunchAgent install).
    /// If we're not currently running we no-op — the caller's flow
    /// (`LocalGatewaySetupView`) will start us once setup completes.
    func reloadWithApiKey() async {
        guard childGatewayProcess != nil || status.isRunning else {
            log.debug("reloadWithApiKey: gateway not running (no child); skipping")
            return
        }

        let port = state.port
        stop()
        // Brief pause so the listening socket clears before respawn.
        try? await Task.sleep(for: .milliseconds(500))
        await start(port: port)

        if status.isRunning {
            log.info("reloadWithApiKey: gateway restarted, health OK")
        } else {
            log.warning("reloadWithApiKey: gateway restart failed; status \(self.status.label, privacy: .public)")
        }
    }

    // MARK: - Health Check

    /// Single health probe -- returns true if the gateway responds on the port.
    func probeHealth(port: Int = defaultPort) async -> Bool {
        let urlString = "http://\(Self.defaultHost):\(port)/health"
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

    /// Waits for the gateway to become healthy, polling every 400ms.
    private func waitForHealthy(port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeHealth(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    // MARK: - Health Monitoring

    /// Starts periodic health monitoring. Calls `onUnhealthy` if the gateway stops responding.
    func startHealthMonitoring(port: Int = defaultPort, interval: TimeInterval = 15, onUnhealthy: (@MainActor @Sendable () -> Void)? = nil) {
        stopHealthMonitoring()
        healthPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.status.isRunning else { return }

                let healthy = await self.probeHealth(port: port)
                if !healthy {
                    log.warning("local gateway health check failed")
                    self.status = .stopped
                    onUnhealthy?()
                    return
                }
            }
        }
    }

    func stopHealthMonitoring() {
        healthPollTask?.cancel()
        healthPollTask = nil
    }

    // MARK: - Detection Polling (for setup flow)

    private var detectionTask: Task<Void, Never>?

    /// Polls until the gateway is detected on the port. Used during setup.
    func startDetectionPolling(port: Int = defaultPort, interval: TimeInterval = 2, onDetected: @escaping @MainActor @Sendable () -> Void) {
        stopDetectionPolling()
        detectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let healthy = await self.probeHealth(port: port)
                if healthy {
                    self.status = .attachedExisting
                    onDetected()
                    return
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopDetectionPolling() {
        detectionTask?.cancel()
        detectionTask = nil
    }

    // MARK: - Status Sync

    /// Syncs status from `openclaw gateway status --json` — the canonical
    /// source of truth. Falls back to HTTP health + filesystem check if the
    /// CLI call fails (e.g. CLI not installed yet, or during an upgrade).
    ///
    /// Previous impl used `probeHealth() + isLaunchAgentInstalled()`, where
    /// the LaunchAgent check looked for OUR label (`app.remclaw.mac.gateway`)
    /// at a fixed path. Since #275 delegated install to the upstream CLI
    /// (which writes `ai.openclaw.gateway.plist`), the filesystem check has
    /// been wrong-by-default. Gateway running under upstream's label showed
    /// up as `.attachedExisting` when it should have been `.running`; the
    /// "stale LaunchAgent" self-heal never fired because we were looking at
    /// the wrong file entirely. See #281 #282.
    ///
    /// Self-heal still runs: if the CLI reports service loaded but gateway
    /// not responding, we boot out the agent so the user gets a clean slate.
    ///
    /// Now a thin alias for `refreshState()` (#293) — the consolidated
    /// lifecycle snapshot is the single source of truth, and
    /// `applyRefreshedSnapshot` preserves the legacy `status` enum
    /// semantics so existing consumers stay correct.
    func syncStatus() async {
        await refreshState()
    }

    // MARK: - Cleanup

    /// Stops everything -- agent, monitoring, polling.
    func teardown() {
        stop()
        stopHealthMonitoring()
        stopDetectionPolling()
    }

    // MARK: - Install Event Parsing

    private struct InstallEvent: Decodable {
        let event: String
        let version: String?
        let message: String?
    }

    private static func parseInstalledVersion(from output: String) -> String? {
        let decoder = JSONDecoder()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(InstallEvent.self, from: data),
                  event.event == "done",
                  let version = event.version else { continue }
            return version
        }
        return nil
    }

    private static func parseInstallError(from output: String) -> String? {
        let decoder = JSONDecoder()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(InstallEvent.self, from: data),
                  event.event == "error",
                  let message = event.message else { continue }
            return message
        }
        return nil
    }

    // MARK: - Shell PATH Helpers

    /// The block we append to the detected shell rc file so that
    /// `~/.openclaw/bin` is on PATH in new terminal sessions. Header comment
    /// is used as the idempotency marker — we never write the block twice.
    nonisolated static let shellPathBlockHeader = "# added by Rem (openclaw CLI) — https://openclaw.ai"
    nonisolated static let shellPathExportLine = #"export PATH="$HOME/.openclaw/bin:$PATH""#

    /// Files we consider when deciding which rc file to append to. Ordering
    /// matches shell-detection priority: zsh (default on modern macOS)
    /// first, then bash.
    nonisolated static let shellRCCandidates: [String] = [
        ".zshrc",
        ".bash_profile",
        ".bashrc",
    ]

    /// Picks the rc file to write to based on `$SHELL` and which files exist
    /// under `home`. Returns an absolute path. The file may not exist yet;
    /// the caller is responsible for creating it.
    ///
    /// Rules (mirrors Homebrew/nvm installer behavior):
    /// - If `$SHELL` ends in `zsh`, target `~/.zshrc`.
    /// - If `$SHELL` ends in `bash`, target `~/.bash_profile` when it
    ///   exists, else `~/.bashrc`. On macOS login shells read
    ///   `.bash_profile`; Linux-style `.bashrc` is the fallback.
    /// - If `$SHELL` is unset/unknown, pick the first existing rc file from
    ///   `shellRCCandidates`. If none exist, default to `~/.zshrc` (modern
    ///   macOS default).
    nonisolated static func preferredShellRC(
        shell: String?,
        home: String,
        fileExists: (String) -> Bool
    ) -> String {
        let shellName = (shell as NSString?)?.lastPathComponent ?? ""

        func path(_ name: String) -> String {
            (home as NSString).appendingPathComponent(name)
        }

        if shellName.hasSuffix("zsh") {
            return path(".zshrc")
        }
        if shellName.hasSuffix("bash") {
            let profile = path(".bash_profile")
            if fileExists(profile) { return profile }
            return path(".bashrc")
        }

        // Unknown shell: prefer any existing rc, else zsh default.
        for candidate in shellRCCandidates {
            let full = path(candidate)
            if fileExists(full) { return full }
        }
        return path(".zshrc")
    }

    /// True when the given rc file already contains our PATH block. Checks
    /// both the header comment and the literal export line so we don't
    /// duplicate even if a user has manually added one of them.
    nonisolated static func rcFileAlreadyHasPathBlock(contents: String) -> Bool {
        if contents.contains(shellPathBlockHeader) { return true }
        if contents.contains(shellPathExportLine) { return true }
        // Also cover the case where the user (or some other installer) wrote
        // their own `~/.openclaw/bin` PATH export with slightly different
        // formatting (e.g. different quoting). Catching the path substring
        // is enough to keep us from doubling up.
        if contents.contains(".openclaw/bin") { return true }
        return false
    }

    /// Builds the block we append to an rc file. Leading newline ensures we
    /// don't land on the same line as whatever was previously at EOF.
    nonisolated static func shellPathBlock() -> String {
        "\n\(shellPathBlockHeader)\n\(shellPathExportLine)\n"
    }

    /// Detects the user's shell rc file and appends an idempotent PATH
    /// export so `~/.openclaw/bin/openclaw` resolves in new terminal
    /// sessions. Non-blocking: any failure (permission, missing parent
    /// dir, read error) is logged and swallowed. The CLI binary is still
    /// at `~/.openclaw/bin/openclaw` even if this step fails — the user
    /// just has to type the full path once, which they already were.
    nonisolated static func ensureCLIOnShellPath() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let shell = ProcessInfo.processInfo.environment["SHELL"]

        let rcPath = preferredShellRC(
            shell: shell,
            home: home,
            fileExists: { fm.fileExists(atPath: $0) }
        )

        // Read existing contents. If the file doesn't exist we'll create it;
        // treat non-existence as empty contents.
        let existing: String
        if fm.fileExists(atPath: rcPath) {
            do {
                existing = try String(contentsOfFile: rcPath, encoding: .utf8)
            } catch {
                log.warning("ensureCLIOnShellPath: could not read \(rcPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            existing = ""
        }

        if rcFileAlreadyHasPathBlock(contents: existing) {
            log.info("ensureCLIOnShellPath: \(rcPath, privacy: .public) already has openclaw PATH entry; skipping")
            return
        }

        let toWrite = existing + shellPathBlock()
        do {
            try toWrite.write(toFile: rcPath, atomically: true, encoding: .utf8)
            log.info("ensureCLIOnShellPath: appended PATH export to \(rcPath, privacy: .public)")
        } catch {
            log.warning("ensureCLIOnShellPath: could not write \(rcPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Clipboard & Terminal Helpers

    /// Copies text to the system clipboard.
    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens Terminal.app.
    static func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}
