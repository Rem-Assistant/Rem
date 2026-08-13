import Foundation
import Testing
@testable import RemClaw

// Unit coverage for the platform-agnostic pieces of the #308 Phase 1 backup
// wrapper. The shell-out itself lives in `RemClawMac/Sources/Gateway/
// BackupService.swift` and isn't reachable from the iOS test host — but the
// argv builder and JSON parser are pure value-typed code in
// `Shared/Models/BackupModels.swift` and *are* reachable.

struct BackupCommandSpecTests {

    // MARK: - arguments(for:) — argv construction

    @Test func defaultRequestEmitsBackupCreateJsonOnly() {
        let args = BackupCommandSpec.arguments(for: BackupRequest())
        #expect(args == ["backup", "create", "--json"])
    }

    @Test func outputDirectoryAddsOutputFlag() {
        let url = URL(fileURLWithPath: "/Users/test/Backups")
        let args = BackupCommandSpec.arguments(for: BackupRequest(outputDirectory: url))
        #expect(args == ["backup", "create", "--json", "--output", "/Users/test/Backups"])
    }

    @Test func defaultOutputDirectoryAddsExplicitHomeOutputFlag() {
        let dir = BackupRequest.defaultOutputDirectory
        let args = BackupCommandSpec.arguments(for: BackupRequest(outputDirectory: dir))
        #expect(args == ["backup", "create", "--json", "--output", dir.path])
    }

    @Test func dryRunFlagIsForwarded() {
        let args = BackupCommandSpec.arguments(for: BackupRequest(dryRun: true))
        #expect(args.contains("--dry-run"))
        #expect(!args.contains("--verify"))
    }

    @Test func verifyFlagIsForwarded() {
        let args = BackupCommandSpec.arguments(for: BackupRequest(verify: true))
        #expect(args.contains("--verify"))
        #expect(!args.contains("--dry-run"))
    }

    @Test func onlyConfigFlagIsForwarded() {
        let args = BackupCommandSpec.arguments(for: BackupRequest(onlyConfig: true))
        #expect(args.contains("--only-config"))
    }

    @Test func includeWorkspaceTrueOmitsNegativeFlag() {
        let args = BackupCommandSpec.arguments(for: BackupRequest(includeWorkspace: true))
        #expect(!args.contains("--no-include-workspace"))
    }

    @Test func includeWorkspaceFalseEmitsNegativeFlag() {
        let args = BackupCommandSpec.arguments(for: BackupRequest(includeWorkspace: false))
        #expect(args.contains("--no-include-workspace"))
    }

    @Test func allFlagsTogetherProduceStableOrdering() {
        let url = URL(fileURLWithPath: "/tmp/out")
        let req = BackupRequest(
            outputDirectory: url,
            dryRun: true,
            verify: true,
            onlyConfig: true,
            includeWorkspace: false
        )
        let args = BackupCommandSpec.arguments(for: req)
        // Order matters for prompt-cache-style stability and for the bash
        // fallback's quoting; pin it explicitly.
        #expect(args == [
            "backup", "create", "--json",
            "--output", "/tmp/out",
            "--dry-run",
            "--verify",
            "--only-config",
            "--no-include-workspace",
        ])
    }

    // MARK: - bashCommand(for:) — PATH-fallback shell command

    @Test func bashCommandQuotesPathsWithSpaces() {
        let url = URL(fileURLWithPath: "/Users/test/Back ups")
        let cmd = BackupCommandSpec.bashCommand(for: BackupRequest(outputDirectory: url))
        // The path with a space must be shell-quoted so `bash -lc` parses
        // it as a single argument, not two.
        #expect(cmd.contains("'/Users/test/Back ups'"))
        #expect(cmd.hasPrefix("openclaw backup create --json"))
    }

    @Test func bashCommandLeavesSafePathsUnquoted() {
        let url = URL(fileURLWithPath: "/Users/test/Backups")
        let cmd = BackupCommandSpec.bashCommand(for: BackupRequest(outputDirectory: url))
        #expect(cmd.contains("/Users/test/Backups"))
        #expect(!cmd.contains("'/Users/test/Backups'"))
    }

    @Test func bashCommandEscapesEmbeddedSingleQuotes() {
        let url = URL(fileURLWithPath: "/tmp/it's")
        let cmd = BackupCommandSpec.bashCommand(for: BackupRequest(outputDirectory: url))
        // Pattern: '...'\''...' — the canonical safe single-quote escape.
        #expect(cmd.contains("'/tmp/it'\\''s'"))
    }

    // MARK: - BackupResultParser — JSON decode

    @Test func parsesUpstreamJsonShape() throws {
        let json = """
        {
          "createdAt": "2026-04-21T12:00:00.000Z",
          "archiveRoot": "openclaw-backup-2026-04-21T12-00-00-000Z",
          "archivePath": "/Users/test/2026-04-21T12-00-00-000Z-openclaw-backup.tar.gz",
          "dryRun": false,
          "includeWorkspace": true,
          "onlyConfig": false,
          "verified": true,
          "assets": [
            {
              "kind": "state",
              "sourcePath": "/Users/test/.openclaw",
              "displayPath": "~/.openclaw",
              "archivePath": "openclaw-backup-2026-04-21T12-00-00-000Z/state"
            }
          ],
          "skipped": []
        }
        """.data(using: .utf8)!

        let result = try BackupResultParser.parse(json).get()
        #expect(result.archivePath.hasSuffix("-openclaw-backup.tar.gz"))
        #expect(result.verified == true)
        #expect(result.dryRun == false)
        #expect(result.assets.count == 1)
        #expect(result.assets.first?.kind == "state")
        #expect(result.skipped.isEmpty)
    }

    @Test func parsesDryRunResult() throws {
        let json = """
        {
          "createdAt": "2026-04-21T12:00:00.000Z",
          "archiveRoot": "openclaw-backup-2026-04-21T12-00-00-000Z",
          "archivePath": "/tmp/preview.tar.gz",
          "dryRun": true,
          "includeWorkspace": false,
          "onlyConfig": false,
          "verified": false,
          "assets": [],
          "skipped": [
            {
              "kind": "workspace",
              "sourcePath": "/Users/test/.openclaw/workspaces",
              "displayPath": "~/.openclaw/workspaces",
              "reason": "covered",
              "coveredBy": "state"
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try BackupResultParser.parse(json).get()
        #expect(result.dryRun == true)
        #expect(result.skipped.first?.reason == "covered")
        #expect(result.skipped.first?.coveredBy == "state")
    }

    @Test func malformedJsonReturnsTypedFailure() {
        let bad = Data("not-json".utf8)
        switch BackupResultParser.parse(bad) {
        case .success:
            Issue.record("expected malformedJSON failure")
        case .failure(let f):
            if case .malformedJSON(let preview) = f {
                #expect(preview.contains("not-json"))
            } else {
                Issue.record("expected .malformedJSON, got \(f)")
            }
        }
    }

    // MARK: - BackupFailure copy

    @Test func cliExitedFailureIncludesUpstreamStderr() {
        let f = BackupFailure.cliExited(code: 1, stderr: "Refusing to overwrite existing backup archive: /tmp/x")
        #expect(f.localizedDescription.contains("Refusing to overwrite"))
        #expect(f.localizedDescription.contains("exit 1"))
    }

    @Test func cliNotInstalledFailurePointsAtSetup() {
        let f = BackupFailure.cliNotInstalled
        #expect(f.localizedDescription.contains("Set Up"))
    }
}
