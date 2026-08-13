import SwiftUI

// MARK: - "What Rem remembers about you" (shared across iOS and macOS)

/// Settings detail for the small, explicit set of OpenClaw defaults users can inspect:
/// SOUL.md, TOOLS.md, and AGENTS.md.
///
/// Fully shared (DRY rule): the only platform branching is the List-vs-Form container,
/// matching `SharedTaskRuntimeSettingsView`. Other workspace files remain on disk but
/// are intentionally outside this surface until the product memory model is decided.
struct SharedMemorySettingsView: View {
    /// Read-only access to the real workspace files on the gateway. Injected for previews.
    let workspaceService: any WorkspaceFilesProviding

    // Workspace (identity/memory) files fetched from the gateway.
    @State private var workspaceFiles: [WorkspaceFile] = []
    @State private var workspaceAvailable = true
    @State private var workspaceUnavailableReason: String?
    @State private var workspaceLoading = true
    @State private var workspaceError: String?

    init(workspaceService: (any WorkspaceFilesProviding)? = nil) {
        self.workspaceService = workspaceService ?? WorkspaceMemoryService()
    }

    var body: some View {
        platformContainer
            .navigationTitle("Memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                await loadWorkspace()
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        workspaceSections
    }

    // MARK: Workspace (identity/memory) files

    /// The gateway returns every file under `/data/workspace`; the page deliberately
    /// narrows that inventory to the three agreed defaults. Dreaming output, daily logs,
    /// generated wiki pages, identity/user files, and unknown markdown remain untouched
    /// on disk and hidden here.
    @ViewBuilder
    private var workspaceSections: some View {
        if workspaceLoading {
            Section {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignTokens.Color.fillTertiary)
                            .frame(width: 22, height: 26)
                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DesignTokens.Color.fillTertiary)
                                .frame(width: index == 1 ? 92 : 78, height: 15)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DesignTokens.Color.fillTertiary)
                                .frame(width: index == 2 ? 170 : 205, height: 11)
                        }
                    }
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .padding(.vertical, 3)
                }
            } header: { Text("Defaults").font(DesignTokens.Typography.caption1) }
        } else if let workspaceError {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(workspaceError)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Button("Try Again") { Task { await loadWorkspace() } }
                }
            } header: { Text("Defaults").font(DesignTokens.Typography.caption1) }
        } else if !workspaceAvailable {
            Section {
                Text(workspaceUnavailableMessage)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            } header: { Text("Memory files").font(DesignTokens.Typography.caption1) }
        } else {
            filesSection(
                title: "Defaults",
                footer: "The core files that define how Rem thinks, behaves, and uses tools. Read-only.",
                files: visibleDefaults,
                emptyMessage: "No default files are available yet."
            )
        }
    }

    /// One grouped section listing readable workspace files. Hidden entirely when
    /// there are no files and no `emptyMessage` (keeps the page tidy when a
    /// category — e.g. Dreaming — hasn't produced anything yet).
    @ViewBuilder
    private func filesSection(
        title: String,
        footer: String,
        files: [WorkspaceFile],
        emptyMessage: String?
    ) -> some View {
        if !files.isEmpty || emptyMessage != nil {
            Section {
                if files.isEmpty, let emptyMessage {
                    Text(emptyMessage)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                } else {
                    ForEach(files) { file in
                        NavigationLink {
                            SharedWorkspaceFileDetailView(file: file, service: workspaceService)
                        } label: {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                Image(systemName: "doc.text")
                                    .foregroundColor(DesignTokens.Color.labelSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.displayName(for: file))
                                        .foregroundColor(DesignTokens.Color.labelPrimary)
                                    if let subtitle = Self.subtitle(for: file) {
                                        Text(subtitle)
                                            .font(DesignTokens.Typography.caption1)
                                            .foregroundColor(DesignTokens.Color.labelSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(title).font(DesignTokens.Typography.caption1)
            } footer: {
                Text(footer).font(DesignTokens.Typography.caption1)
            }
        }
    }

    /// Stable product order, independent of filesystem listing order.
    private var visibleDefaults: [WorkspaceFile] {
        let priority = ["soul.md", "tools.md", "agents.md"]
        return workspaceFiles
            .filter(\.isVisibleMemoryDefault)
            .sorted { a, b in
                let aRank = priority.firstIndex(of: a.name.lowercased()) ?? priority.count
                let bRank = priority.firstIndex(of: b.name.lowercased()) ?? priority.count
                return aRank < bRank
            }
    }

    /// Copy for the `available == false` state, tailored by the backend's `reason`.
    /// `gateway-update-required` → the gateway runs an older image without the
    /// workspace endpoints; the files exist but can't be read until it's updated.
    private var workspaceUnavailableMessage: String {
        if workspaceUnavailableReason == "gateway-update-required" {
            return "Your gateway needs an update before Rem's memory files can appear here. They'll show up automatically after the next gateway update."
        }
        return "Rem's memory files aren't available yet. They'll appear here once your gateway is set up."
    }

    /// A friendlier display label for the well-known files (the raw `.md` filename
    /// is machine-ish). Falls back to the filename for daily logs / unknowns.
    private static func displayName(for file: WorkspaceFile) -> String {
        switch file.name.lowercased() {
        case "soul.md": return "Soul"
        case "tools.md": return "Tools"
        case "agents.md": return "Agents"
        default: return file.name
        }
    }

    /// A short, friendly one-liner under the display name.
    private static func subtitle(for file: WorkspaceFile) -> String? {
        switch file.name.lowercased() {
        case "soul.md": return "Persona and boundaries"
        case "tools.md": return "Tool-use guidance"
        case "agents.md": return "Operating instructions"
        default: return nil
        }
    }

    /// iOS uses `List` + insetGrouped; macOS uses `Form` + grouped in the centered
    /// settings column — matching `SharedTaskRuntimeSettingsView` / `SharedSettingsView`.
    @ViewBuilder
    private var platformContainer: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { content }
            .listStyle(.insetGrouped)
        #endif
    }

    private func loadWorkspace() async {
        workspaceLoading = true
        workspaceError = nil
        do {
            let result = try await workspaceService.files()
            workspaceAvailable = result.available
            workspaceUnavailableReason = result.reason
            workspaceFiles = result.files
        } catch {
            workspaceError = error.localizedDescription
        }
        workspaceLoading = false
    }

}

#Preview {
    NavigationStack {
        SharedMemorySettingsView(
            workspaceService: MockWorkspaceMemoryService()
        )
    }
}
