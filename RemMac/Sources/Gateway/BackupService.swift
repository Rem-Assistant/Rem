import Foundation
import os

// Phase 1 implementation of issue #308: surface upstream's `openclaw backup
// create` as a Mac-app affordance. Mirrors the explicit-path → bash-PATH
// fallback shell-out pattern from `pairableSetupCode()` in
// `LocalGatewayManager.swift` (PR #354). Restore is intentionally NOT
// implemented — upstream ships no `openclaw backup restore`; per the design
// comment (#308 inv. comment 4321190595), `tar -xzf <archive> -C $HOME` is
// the documented manual restore path.

private let log = Logger(subsystem: "app.remclaw.mac", category: "backup")

extension LocalGatewayManager {

    // MARK: - Public API

    /// Runs `openclaw backup create` and returns the parsed result. The
    /// generated tarball lives at `result.archivePath` (also surfaced as a
    /// `URL` for callers that want to reveal it in Finder).
    ///
    /// State-machine note (issue #308 PR brief): callers should drive the UI
    /// from a single enum, e.g. `idle → preparing → creating → complete |
    /// error(BackupFailure)`. This method maps directly to the `creating →
    /// (complete | error)` transition.
    ///
    /// Lookup order, mirroring `pairableSetupCode()`:
    /// 1. Explicit `~/.openclaw/bin/openclaw` (where our installer writes).
    /// 2. PATH fallback via `bash -lc` (Homebrew, custom prefixes).
    /// 3. Returns `.cliNotInstalled` failure.
    nonisolated static func createBackup(_ request: BackupRequest) async -> BackupOutcome {
        guard let cli = resolveBackupCLIPath() else {
            log.warning("createBackup: openclaw CLI not found in ~/.openclaw/bin or PATH")
            return .failure(.cliNotInstalled)
        }

        let arguments = BackupCommandSpec.arguments(for: request)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if cli == "openclaw" {
            // PATH-fallback path needs a login shell to pick up the user's
            // PATH (Homebrew on Apple Silicon, custom installs).
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", BackupCommandSpec.bashCommand(for: request)]
        } else {
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
        }

        do {
            try process.run()
        } catch {
            log.error("createBackup: spawn failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.spawnFailed(error.localizedDescription))
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            log.error("createBackup: openclaw exited \(process.terminationStatus): \(stderr, privacy: .public)")
            return .failure(.cliExited(code: process.terminationStatus, stderr: stderr))
        }

        switch BackupResultParser.parse(stdoutData) {
        case .success(let result):
            // Real (non-dry-run) results must carry an archive path; missing
            // would indicate an upstream regression, surface it as a typed
            // failure so the UI can show something meaningful.
            if !result.dryRun && result.archivePath.isEmpty {
                return .failure(.missingArchive)
            }
            log.info("createBackup ok: dryRun=\(result.dryRun) verified=\(result.verified) assets=\(result.assets.count) archive=\(result.archivePath, privacy: .public)")
            return .success(result)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Lists previously-created backup archives in the given directory.
    /// Matches the upstream basename pattern `<ISO-timestamp>-openclaw-backup.tar.gz`
    /// from `openclaw/src/commands/backup-shared.ts:buildBackupArchiveBasename`.
    /// Returns newest first. Quiet on errors — empty array means "no backups
    /// (or directory unreadable)".
    nonisolated static func listBackups(in directory: URL) -> [BackupArchiveEntry] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.lastPathComponent.hasSuffix("-openclaw-backup.tar.gz") }
            .compactMap { url -> BackupArchiveEntry? in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return BackupArchiveEntry(
                    url: url,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Private helpers

    /// Picks the `openclaw` binary path. Mirrors the helper in
    /// `LocalGatewayManager` but kept private here so `BackupService.swift`
    /// can stay self-contained as a leaf operation (per #308 design
    /// "no semantic conflict with #350" note).
    nonisolated private static func resolveBackupCLIPath() -> String? {
        let fm = FileManager.default
        let explicit = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/bin/openclaw")
            .path
        if fm.isExecutableFile(atPath: explicit) {
            return explicit
        }
        // PATH fallback — bash -lc resolves it from the login PATH.
        return "openclaw"
    }
}

// MARK: - List entry

/// One entry in the on-disk backup directory listing. Cheap struct, holds no
/// archive contents — used by the Mac UI's "Recent backups" list.
struct BackupArchiveEntry: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let sizeBytes: Int64
    let modifiedAt: Date

    var filename: String { url.lastPathComponent }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
