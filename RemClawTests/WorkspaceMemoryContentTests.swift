import Testing
@testable import RemClaw

/// Guards the seeded-scaffold heuristic behind Settings → Memory: a genuine short
/// memory must NOT be hidden as a template just because a line contains a hint
/// word, while a bare onboarding scaffold IS still hidden.
struct WorkspaceMemoryContentTests {

    // MARK: Real short memories must render (not be hidden as "template")

    @Test func realMemoryContainingHintWordIsNotHidden() {
        // Each merely *contains* a hint word inside a real sentence — must be kept.
        let realMemories = [
            "# USER.md\n\n- Fixed the placeholder image bug in checkout\n",
            "# USER.md\n\n- User said there's nothing yet to report on the merger\n",
            "# USER.md\n\n- todos: buy milk, call mom\n",
            "# MEMORY.md\n\n- Wants the coming soon banner removed from the homepage\n",
            "# USER.md\n\n- Prefers morning workouts before 8am\n",
        ]
        for content in realMemories {
            #expect(
                WorkspaceMemoryContent.isEmptyOrTemplate(content) == false,
                "genuine memory wrongly hidden as template: \(content)"
            )
        }
    }

    // MARK: Seeded scaffolds must still be treated as empty

    @Test func seededScaffoldIsTreatedAsTemplate() {
        let scaffolds = [
            "# MEMORY.md\n",                                   // heading only
            "# USER.md\n\n- (nothing yet)\n",                  // parenthesized hint bullet
            "# USER.md\n\nTODO\n",                             // bare hint line
            "# MEMORY.md\n\n<!-- Long-term notes. -->\n- (nothing yet)\n",
            "# IDENTITY.md\n\n---\n",                          // heading + thematic break
            "# USER.md\n\n- \n- \n",                           // empty bullets
            "# USER.md\n\nTBD.\n",                             // hint + trailing punctuation
            "# USER.md\n\n- Placeholder\n",                    // whole-body hint bullet
            "",                                                // fully empty
        ]
        for content in scaffolds {
            #expect(
                WorkspaceMemoryContent.isEmptyOrTemplate(content) == true,
                "seeded scaffold not detected as template: \(content)"
            )
        }
    }

    // MARK: Machine files are hidden; markdown is grouped correctly

    @Test func machineFilesAreHiddenFromMemoryPage() {
        let machine = [
            WorkspaceFile(path: "phase-signals.json", size: 40),
            WorkspaceFile(path: "workspace-state.json", size: 12),
            WorkspaceFile(path: "memory/.dreams/state.json", size: 20),
            WorkspaceFile(path: ".openclaw-wiki/cache/digest.json", size: 20),
        ]
        for file in machine {
            #expect(file.memoryCategory == .hidden, "machine file not hidden: \(file.path)")
        }
    }

    @Test func markdownFilesAreGroupedByCategory() {
        // Rem's instructions — OpenClaw's standard instruction files
        // (docs/rebuild/32-REMCLAW-MD-SCOPE.md): identity/agents/soul/tools.
        #expect(WorkspaceFile(path: "IDENTITY.md", size: 10).memoryCategory == .remInstructions)
        #expect(WorkspaceFile(path: "AGENTS.md", size: 10).memoryCategory == .remInstructions)
        #expect(WorkspaceFile(path: "REMCLAW.md", size: 10).memoryCategory == .remInstructions)
        #expect(WorkspaceFile(path: "SOUL.md", size: 10).memoryCategory == .remInstructions)
        #expect(WorkspaceFile(path: "TOOLS.md", size: 10).memoryCategory == .remInstructions)
        // Case-insensitive matching (same style as the classifier).
        #expect(WorkspaceFile(path: "soul.md", size: 10).memoryCategory == .remInstructions)

        // Your info — durable facts about the user stay out of instructions.
        #expect(WorkspaceFile(path: "USER.md", size: 10).memoryCategory == .yourInfo)
        #expect(WorkspaceFile(path: "MEMORY.md", size: 10).memoryCategory == .yourInfo)
        #expect(WorkspaceFile(path: "memory/2026-07-06.md", size: 10).memoryCategory == .yourInfo)

        // Dreaming diary.
        #expect(WorkspaceFile(path: "DREAMS.md", size: 10).memoryCategory == .dreaming)
    }

    @Test func memorySurfaceShowsOnlyRootAgentDefaults() {
        let visible = ["SOUL.md", "TOOLS.md", "AGENTS.md", "soul.md"]
        for path in visible {
            #expect(WorkspaceFile(path: path, size: 10).isVisibleMemoryDefault)
        }

        let hidden = [
            "IDENTITY.md", "USER.md", "MEMORY.md", "DREAMS.md",
            "memory/2026-07-06.md", "memory/AGENTS.md",
            "index.md", "open-questions.md", "stale-pages.md",
            ".openclaw-wiki/AGENTS.md", "workspace-state.json",
        ]
        for path in hidden {
            #expect(
                WorkspaceFile(path: path, size: 10).isVisibleMemoryDefault == false,
                "unexpected Memory default: \(path)"
            )
        }
    }
}
