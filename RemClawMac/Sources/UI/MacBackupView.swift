import AppKit
import SwiftUI

// Phase 1 of #308: active local gateway Backup detail. Wraps upstream's
// `openclaw backup create` via `LocalGatewayManager.createBackup(...)`.
//
// Restore is intentionally not exposed — upstream ships no `openclaw backup
// restore`. The user-visible doc copy points to the manual `tar -xzf` path,
// matching the design comment on issue #308.

struct MacBackupView: View {
    let localGateway: LocalGatewayManager

    /// Source of truth for the lifecycle state machine. UI reads this; nothing
    /// else mutates it. Named transitions only — no string parsing.
    @State private var phase: Phase = .idle
    @State private var lastResult: BackupCreateResult?
    @State private var recentBackups: [BackupArchiveEntry] = []
    @State private var dryRun: Bool = false
    @State private var verify: Bool = true
    @State private var includeWorkspace: Bool = true
    @State private var outputDir: URL = BackupRequest.defaultOutputDirectory

    /// Lifecycle states for one backup attempt. Mirrors the state machine
    /// called out in the PR body for #308 Phase 1:
    /// `idle → preparing → creating → manifestParsed → complete | error(...)`.
    enum Phase: Equatable {
        case idle
        case preparing
        case creating
        case manifestParsed
        case complete
        case error(BackupFailure)

        var isBusy: Bool {
            switch self {
            case .preparing, .creating, .manifestParsed: return true
            default: return false
            }
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                        SettingsIcon(icon: "externaldrive.fill", color: .green)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preserve this Mac's gateway identity")
                                .font(DesignTokens.Typography.bodyBold)
                            Text("Create a portable OpenClaw archive before wiping, migrating, or rebuilding this Mac.")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Label {
                        Text("Without a backup, paired devices may treat this Mac as a new gateway and require re-pairing.")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(DesignTokens.Color.systemOrange)
                    }

                    Button {
                        Task { await runBackup() }
                    } label: {
                        HStack {
                            if phase.isBusy {
                                ProgressView().controlSize(.small)
                            }
                            Text(phase.isBusy ? "Backing Up..." : "Back Up Now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(phase.isBusy)

                    switch phase {
                    case .complete:
                        if let result = lastResult, !result.dryRun {
                            BackupResultRow(result: result)
                        } else if let result = lastResult, result.dryRun {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Dry run: \(result.assets.count) path\(result.assets.count == 1 ? "" : "s") would be included")
                                    .font(DesignTokens.Typography.body)
                                Text("No archive was written.")
                                    .font(DesignTokens.Typography.caption1)
                                    .foregroundColor(DesignTokens.Color.labelSecondary)
                            }
                        }
                    case .error(let failure):
                        Text(failure.localizedDescription)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.systemRed)
                    default:
                        EmptyView()
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            } header: {
                Text("Gateway Backup")
            } footer: {
                Text("Backups include OpenClaw configuration and, when enabled below, workspace files.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination")
                        .font(DesignTokens.Typography.bodyBold)
                    Text(outputDir.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("Choose Folder...") { chooseOutputFolder() }
                        .controlSize(.small)
                    if outputDir != BackupRequest.defaultOutputDirectory {
                        Button("Reset") {
                            outputDir = BackupRequest.defaultOutputDirectory
                            refreshRecentBackups()
                        }
                            .controlSize(.small)
                    }
                }
                Toggle("Include workspace files", isOn: $includeWorkspace)
                Toggle("Verify archive after writing", isOn: $verify)
                Toggle("Dry run (preview only, no archive written)", isOn: $dryRun)
            } header: {
                Text("Options")
            } footer: {
                Text("Dry run reports what would be backed up without producing a file. Verify re-reads the archive immediately after writing it.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }

            if !recentBackups.isEmpty {
                Section("Recent Backups") {
                    ForEach(recentBackups) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.filename)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(entry.formattedSize) · \(formatDate(entry.modifiedAt))")
                                    .font(DesignTokens.Typography.caption1)
                                    .foregroundColor(DesignTokens.Color.labelSecondary)
                            }
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .controlSize(.small)
                            .help("Reveal in Finder")
                        }
                    }
                }
            }

            Section {
                Text("To restore, extract the archive back to your home directory in Terminal:")
                    .font(DesignTokens.Typography.caption1)
                Text("tar -xzf <archive>.tar.gz -C $HOME")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.vertical, 2)
                Text("OpenClaw does not ship a built-in restore command yet. Extracting the archive over your home directory is the documented restore path.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            } header: {
                Text("Restore")
            }
        }
        .formStyle(.grouped)
        .macSettingsCenteredColumn()
        .navigationTitle("Backup")
        .onAppear { refreshRecentBackups() }
    }

    // MARK: - Actions

    private func runBackup() async {
        phase = .preparing
        let request = BackupRequest(
            outputDirectory: outputDir,
            dryRun: dryRun,
            verify: verify,
            onlyConfig: false,
            includeWorkspace: includeWorkspace
        )
        phase = .creating

        let outcome = await LocalGatewayManager.createBackup(request)

        switch outcome {
        case .success(let result):
            phase = .manifestParsed
            lastResult = result
            phase = .complete
            refreshRecentBackups()
        case .failure(let failure):
            phase = .error(failure)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for OpenClaw backup archives."
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url
            refreshRecentBackups()
        }
    }

    private func refreshRecentBackups() {
        recentBackups = LocalGatewayManager.listBackups(in: outputDir)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Result row

private struct BackupResultRow: View {
    let result: BackupCreateResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DesignTokens.Spacing.xs + 2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(DesignTokens.Color.systemGreen)
                Text(result.verified ? "Backup created and verified" : "Backup created")
                    .font(DesignTokens.Typography.bodyBold)
            }
            Text(result.archivePath)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text("\(result.assets.count) path\(result.assets.count == 1 ? "" : "s") included" +
                 (result.skipped.isEmpty ? "" : " · \(result.skipped.count) skipped"))
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)

            Button {
                let url = URL(fileURLWithPath: result.archivePath)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
