import SwiftUI

/// Read-only viewer for a single agent workspace file (IDENTITY.md / USER.md /
/// MEMORY.md / memory/*.md). Fetches the file's text lazily from the gateway
/// (via the backend proxy) and renders it with the shared markdown renderer.
///
/// Shared across iOS and macOS (DRY rule) — no platform branching beyond the
/// scroll container. Presented from ``SharedMemorySettingsView``.
struct SharedWorkspaceFileDetailView: View {
    let file: WorkspaceFile
    let service: any WorkspaceFilesProviding

    @State private var content: WorkspaceFileContent?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if isLoading {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView()
                        Text("Loading…")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text(errorMessage)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                        Button("Try Again") { Task { await load() } }
                    }
                } else if let content {
                    // A seeded-but-unfilled onboarding scaffold (bare headings +
                    // placeholder lines, no real facts) should read as "not written
                    // yet" — never dumped as if it were a real memory. See
                    // `WorkspaceMemoryContent.isEmptyOrTemplate`.
                    if WorkspaceMemoryContent.isEmptyOrTemplate(content.content) {
                        Text("Rem hasn't written anything here yet. It fills this in automatically as it learns.")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    } else {
                        AssistantMarkdownView(markdown: content.content)
                        if content.truncated {
                            Text("This file is large — showing the first part only.")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelTertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)
        }
        .navigationTitle(file.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            content = try await service.file(path: file.path)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        SharedWorkspaceFileDetailView(
            file: WorkspaceFile(path: "USER.md", size: 120),
            service: MockWorkspaceMemoryService()
        )
    }
}
