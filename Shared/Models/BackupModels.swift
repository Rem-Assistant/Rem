import Foundation

// Phase 1 wrapper around upstream `openclaw backup create`. The Mac app shells
// out to the CLI; the request → argv mapping and the JSON response decode live
// here so they can be unit-tested without spawning a real subprocess. See
// issue #308 (design comment 4321190595) and `openclaw/src/commands/backup.ts`.

// MARK: - Request

/// Inputs to `openclaw backup create`. Mirrors the CLI flags declared in
/// `openclaw/src/cli/program/register.backup.ts`. `outputDirectory` is a
/// directory; the CLI writes a timestamped `.tar.gz` inside it.
struct BackupRequest: Equatable, Sendable {
    /// The Mac UI always passes an explicit output directory so the CLI and
    /// recent-backups list agree even when Finder/Dock launches with `/` as cwd.
    nonisolated static var defaultOutputDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    var outputDirectory: URL?
    var dryRun: Bool
    var verify: Bool
    var onlyConfig: Bool
    /// When false, passes `--no-include-workspace` to skip workspace dirs.
    var includeWorkspace: Bool

    init(
        outputDirectory: URL? = nil,
        dryRun: Bool = false,
        verify: Bool = false,
        onlyConfig: Bool = false,
        includeWorkspace: Bool = true
    ) {
        self.outputDirectory = outputDirectory
        self.dryRun = dryRun
        self.verify = verify
        self.onlyConfig = onlyConfig
        self.includeWorkspace = includeWorkspace
    }
}

// MARK: - Command spec (argv builder)

/// Turns a `BackupRequest` into the argv list passed to the `openclaw` binary.
/// Pure, deterministic, no I/O — drives both the shell-out path and unit tests.
enum BackupCommandSpec {

    /// Builds the argv tail (everything after the executable path).
    /// Always ends with `--json` so the Mac app can parse the result; upstream
    /// otherwise prints a human-readable summary that's harder to consume.
    nonisolated static func arguments(for request: BackupRequest) -> [String] {
        var args: [String] = ["backup", "create", "--json"]
        if let dir = request.outputDirectory {
            args.append("--output")
            args.append(dir.path)
        }
        if request.dryRun {
            args.append("--dry-run")
        }
        if request.verify {
            args.append("--verify")
        }
        if request.onlyConfig {
            args.append("--only-config")
        }
        // Upstream defaults to including workspace dirs; the negative flag is
        // the only way to opt out (`commander`'s `--no-include-workspace`).
        if !request.includeWorkspace {
            args.append("--no-include-workspace")
        }
        return args
    }

    /// Same as `arguments(for:)` but rendered as a single shell command for
    /// the bash-PATH-fallback case. Safely quotes the output path so
    /// directories with spaces work.
    nonisolated static func bashCommand(for request: BackupRequest, executable: String = "openclaw") -> String {
        let parts = [executable] + arguments(for: request)
        return parts.map(shellQuote).joined(separator: " ")
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        // Single-quote and escape any embedded single quotes — handles spaces,
        // `$`, `&`, etc. Mirrors shell `printf %q` for typical filesystem paths.
        if s.range(of: "[^A-Za-z0-9_./:=-]", options: .regularExpression) == nil {
            return s
        }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - Result (Codable mirror of upstream JSON)

/// Decoded form of `openclaw backup create --json` output. Mirrors the
/// `BackupCreateResult` type in `openclaw/src/infra/backup-create.ts`. Fields
/// the Mac UI doesn't surface today are still decoded (and forwarded) so the
/// PR body's "manifest summary" claim stays accurate without future schema
/// chasing.
struct BackupCreateResult: Decodable, Equatable, Sendable {
    let createdAt: String
    let archiveRoot: String
    let archivePath: String
    let dryRun: Bool
    let includeWorkspace: Bool
    let onlyConfig: Bool
    let verified: Bool
    let assets: [Asset]
    let skipped: [SkippedEntry]

    struct Asset: Decodable, Equatable, Sendable {
        let kind: String
        let sourcePath: String
        // Kept optional for older CLI compatibility even though upstream
        // currently emits these fields for every asset.
        let displayPath: String?
        let archivePath: String?
    }

    struct SkippedEntry: Decodable, Equatable, Sendable {
        let kind: String
        let sourcePath: String
        // Kept optional for older CLI compatibility even though upstream
        // currently emits this field for every skipped entry.
        let displayPath: String?
        let reason: String
        let coveredBy: String?
    }
}

// MARK: - Parsing

/// Result of running the wrapper: typed success + decoded result, or a
/// structured error the UI can map to copy. Kept as an enum so the SwiftUI
/// layer can switch on cases without inspecting localized strings.
enum BackupOutcome: Equatable, Sendable {
    case success(BackupCreateResult)
    case failure(BackupFailure)
}

enum BackupFailure: Error, Equatable, Sendable {
    /// CLI not on disk and not on PATH.
    case cliNotInstalled
    /// Process failed to launch (permission, sandbox, missing interpreter).
    case spawnFailed(String)
    /// `openclaw backup create` returned non-zero. `stderr` carries upstream's
    /// own message which is usually actionable ("gateway not running",
    /// "permission denied", "refusing to overwrite existing backup archive").
    case cliExited(code: Int32, stderr: String)
    /// CLI exited 0 but the JSON didn't decode — treat as a versioning bug
    /// (older CLI without `--json`, malformed output).
    case malformedJSON(preview: String)
    /// Ran successfully but no archive was created (dry-run is reported via
    /// `BackupCreateResult.dryRun`, not this case — this is for a real run
    /// that finished with `archivePath` empty, which would be a CLI bug).
    case missingArchive

    var localizedDescription: String {
        switch self {
        case .cliNotInstalled:
            return "OpenClaw CLI not installed. Install it from Settings → General → Set Up to enable backups."
        case .spawnFailed(let underlying):
            return "Could not launch openclaw: \(underlying)"
        case .cliExited(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "openclaw backup create failed (exit \(code))."
            }
            return "openclaw backup create failed (exit \(code)): \(trimmed)"
        case .malformedJSON(let preview):
            return "openclaw backup create returned unexpected output: \(preview)"
        case .missingArchive:
            return "Backup completed but no archive path was reported."
        }
    }
}

/// Parses a raw `--json` stdout payload from `openclaw backup create`. Pure;
/// drives both the shell-out path and unit tests.
enum BackupResultParser {
    nonisolated static func parse(_ stdout: Data) -> Result<BackupCreateResult, BackupFailure> {
        let decoder = JSONDecoder()
        do {
            let result = try decoder.decode(BackupCreateResult.self, from: stdout)
            return .success(result)
        } catch {
            let preview = String(data: stdout.prefix(200), encoding: .utf8) ?? "<non-utf8>"
            return .failure(.malformedJSON(preview: preview))
        }
    }
}
