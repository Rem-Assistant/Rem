import SwiftUI

#if DEBUG
struct AssistantMarkdownFixtureView: View {
    private let markdown = """
    ### Markdown renderer proof
    Assistant responses keep inline **emphasis** while fenced code blocks render as code instead of chat prose.

    ```swift
    struct Reminder {
        let title: String
        let dueDate: Date
    }
    ```

    The text below the block should return to normal assistant bubble styling.
    """

    // A 4x4 solid-red PNG encoded as a `data:` URL, mirroring the shape the
    // WhatsApp `whatsapp_login` pairing QR arrives in. Proves the base64 →
    // Image decode path works fully offline.
    private let imageMarkdown = """
    Scan this pairing code to connect WhatsApp:

    ![whatsapp-qr](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGP4z8AARwzEcQCukw/x0F8jngAAAABJRU5ErkJggg==)

    Text after the image should stay in normal assistant prose styling.
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Assistant Markdown")
                    .font(DesignTokens.Typography.title3)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)

                AssistantMarkdownView(markdown: markdown)
                    .padding(16)
                    .background(DesignTokens.Color.fillTertiary.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text("Inline data-URL image (offline QR path)")
                    .font(DesignTokens.Typography.caption1.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelSecondary)

                AssistantMarkdownView(markdown: imageMarkdown)
                    .padding(16)
                    .background(DesignTokens.Color.fillTertiary.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .navigationTitle("Markdown Fixture")
    }
}

struct AssistantDiagnosticsFixtureView: View {
    private let rawMessage = """
    name: github
    description: "GitHub operations via gh CLI: issues, PRs, CI runs, code review, API queries."
    metadata:
      openclaw:
        emoji: "github"
        requires:
          bins: ["gh"]
        install:
          - id: brew
            kind: brew
            formula: gh
            label: "Install GitHub CLI (brew)"

    Tool system.run not found
    node command not allowed: the node (platform: macOS 26.1.0) does not support "system.run.prepare"

    The GitHub skill needs the `gh` CLI before it can manage repositories.
    """
    private let successfulBrowserMessage = """
    node command not allowed: the node (platform: macOS 26.1.0) does not support "system.run.prepare"
    agent=main node=0d0cd631d7750bc2e69e3c8aa3884cb39f6651a54033690ff092fa68db1b0653 gateway=default action=invoke: invokeCommand "system.run" is reserved for shell execution; use exec with host=node instead
    No connected browser-capable nodes.

    Opened Chrome with https://www.youtube.com/watch?v=dQw4w9WgXcQ.
    """

    @State private var expandedSections: Set<String> = ["diagnostics"]

    var body: some View {
        let cleaned = MessageCleaner.cleanAssistantMessage(rawMessage)
        let browserCleaned = MessageCleaner.cleanAssistantMessage(successfulBrowserMessage)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chat Diagnostics Fixture")
                        .font(DesignTokens.Typography.title3)
                        .foregroundStyle(DesignTokens.Color.labelPrimary)

                    Text("Sanitized runtime output is preserved in the Thinking block while the visible reply stays conversational.")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                }

                if let diagnostics = cleaned.diagnosticsText {
                    SharedChatThinkingBlock(
                        text: diagnostics,
                        sectionId: "diagnostics",
                        expandedSections: $expandedSections
                    )
                    .background(DesignTokens.Color.fillTertiary.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Visible Assistant Reply")
                        .font(DesignTokens.Typography.caption1.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.labelSecondary)

                    AssistantMarkdownView(markdown: cleaned.displayText)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Color.fillTertiary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Successful Browser Action")
                        .font(DesignTokens.Typography.caption1.weight(.semibold))
                        .foregroundStyle(DesignTokens.Color.labelSecondary)

                    AssistantMarkdownView(markdown: browserCleaned.displayText)

                    Text(browserCleaned.diagnosticsText == nil
                         ? "Transient browser diagnostics suppressed"
                         : "Unexpected diagnostics still visible")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(browserCleaned.diagnosticsText == nil
                                         ? Color.green
                                         : Color.red)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Color.fillTertiary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .navigationTitle("Diagnostics Fixture")
    }
}

/// Proves the whatsapp_login QR (a *text tool result* of prose + an inline `data:image/png`
/// markdown image) renders as a scannable image via the tool-result fallback — not buried as
/// collapsed monospaced text. Uses a real 1×1 PNG data URL so the decode path actually runs.
struct ToolResultImageFixtureView: View {
    private let qrToolResult = """
    QR generated. Open WhatsApp → Linked Devices and scan:

    ![whatsapp-qr](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==)
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tool Result · Inline Image (QR)")
                    .font(DesignTokens.Typography.title3)
                    .foregroundStyle(DesignTokens.Color.labelPrimary)

                InlineToolResultCard(text: qrToolResult, sectionId: "qr-fixture")
                    .padding(16)
                    .background(DesignTokens.Color.fillTertiary.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .background(DesignTokens.Color.backgroundPrimary)
        .navigationTitle("Tool Result Image")
    }
}
#endif
