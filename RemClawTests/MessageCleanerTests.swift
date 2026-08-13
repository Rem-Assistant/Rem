import Foundation
import Testing
@testable import RemClaw

struct MessageCleanerTests {

    @Test func stripsStableDailyBriefArtifactLabelFromAssistantDisplay() {
        let raw = "[Rem daily update · 2026-08-06 · morning]\n\nYour day is clear."
        #expect(MessageCleaner.cleanAssistantMessageText(raw) == "Your day is clear.")
    }

    // MARK: - Legacy user-context compatibility

    @Test func stripsLegacyDeviceContextFromPersistedUserTurns() {
        let input = """
        [System: Connected to Sam's iPhone (iPhone, iOS 19.0). Local time: 2026-08-06 12:30 PDT (America/Los_Angeles). Node ID: abc123.]

        Plan the rest of my day
        """

        #expect(MessageCleaner.cleanUserMessageText(input) == "Plan the rest of my day")
    }

    @Test func preservesRawUserTextWithoutSyntheticContext() {
        let input = "Plan the rest of my day"
        #expect(MessageCleaner.cleanUserMessageText(input) == input)
    }

    // MARK: - Shell & tool error stripping

    @Test func stripsToolNotFoundError() {
        let input = "Tool reminders.list not found"
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsMultipleToolErrors() {
        let input = """
        Tool reminders.list not found
        Tool tasks.list not found
        Tool reminders.list not found
        """
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsUnknownCommandError() {
        let input = "error: unknown command 'device' (Did you mean devices?)"
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsCommandExitedLine() {
        let input = "(Command exited with code 1)"
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsCommandExitedNegativeCode() {
        let input = "(Command exited with code -15)"
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func collapsesCLIHelpBlockIntoFence() {
        // Phase 2 (#260): help dumps collapse into ```sh fence rather than
        // stripping to empty — non-destructive, visually contained.
        let input = """
        Usage: openclaw [options] [command]

        Options:
          --container <name>   Run in container
          --dev                Dev profile
          -h, --help           Display help
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.hasPrefix("```sh\n"))
        #expect(result.hasSuffix("\n```"))
        #expect(result.contains("Usage: openclaw [options] [command]"))
        #expect(result.contains("--container <name>"))
    }

    @Test func collapsesHelpBlockWithCommandsSectionIntoFence() {
        let input = """
        Usage: openclaw <command>

        Commands:
          gateway    Run gateway
          serve      Start server
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.hasPrefix("```sh\n"))
        #expect(result.hasSuffix("\n```"))
        #expect(result.contains("Commands:"))
        #expect(result.contains("gateway    Run gateway"))
    }

    @Test func keepsProseWithEmbeddedToolError() {
        // If the error appears inside prose, keep it — it's likely the AI
        // narrating what happened.
        let input = "I tried to fetch reminders but got: Tool reminders.list not found in the response"
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.contains("Tool reminders.list not found"))
    }

    @Test func keepsUsageWordInProse() {
        // The word "Usage:" without an Options/Commands follow-up is normal prose.
        let input = """
        Usage: this app helps you manage your tasks.
        It's designed to be intuitive.
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.contains("Usage: this app helps"))
    }

    @Test func keepsRealAssistantTextSurroundingErrors() {
        let input = """
        I'll check your reminders.
        Tool reminders.list not found
        Looks like that capability isn't available right now.
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.contains("I'll check your reminders."))
        #expect(result.contains("Looks like that capability"))
        #expect(!result.contains("Tool reminders.list not found"))
    }

    @Test func stripsRealLeakObservedInChat() {
        // From actual chat history that surfaced in #260.
        let input = """
        Tool reminders.list not found
        Tool reminders.list not found
        Tool tasks.list not found
        Tool reminders.list not found
        Tool reminders.list not found
        error: unknown command 'device' (Did you mean devices?)
        (Command exited with code 1)
        """
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func leavesNormalAssistantTextUnchanged() {
        let input = "Hey! Good morning. 👋"
        #expect(MessageCleaner.cleanAssistantMessageText(input) == input)
    }

    // MARK: - Tool-argument validation dumps

    @Test func stripsMultiLineToolValidationDump() {
        // Seen when the agent passes a node command as the `nodes` action
        // instead of `action: "invoke"`.
        let input = """
        Validation failed for tool "nodes":
        - action: must be equal to one of the allowed values
        """
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsInlineSingleLineToolValidationDump() {
        let input = #"Validation failed for tool "nodes": - action: must be equal to one of the allowed values"#
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsToolValidationDumpWithMultipleBullets() {
        let input = """
        Validation failed for tool "nodes":
        - action: must be equal to one of the allowed values
        - node: must be a string
        """
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func keepsProseAroundToolValidationDump() {
        let input = """
        Let me check your calendar.
        Validation failed for tool "nodes":
        - action: must be equal to one of the allowed values
        Got it — here's your day.
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.contains("Let me check your calendar."))
        #expect(result.contains("Got it — here's your day."))
        #expect(!result.contains("Validation failed for tool"))
        #expect(!result.contains("must be equal to one of the allowed values"))
    }

    @Test func keepsEmbeddedValidationMentionInProse() {
        // Mid-sentence mention (not a standalone leak) is preserved.
        let input = "I hit a Validation failed for tool error, retrying now."
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.contains("Validation failed for tool"))
    }

    @Test func keepsRegularMarkdownBulletsAfterProse() {
        // A normal markdown list must NOT be eaten by the validation stripper.
        let input = """
        Here's your plan:
        - Standup at 9
        - Lunch at noon
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.contains("- Standup at 9"))
        #expect(result.contains("- Lunch at noon"))
    }

    // MARK: - Follow-up review issues

    @Test func stripsHyphenatedToolName() {
        let input = "Tool tasks-v2.list not found"
        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsShellNativeCommandNotFound() {
        #expect(MessageCleaner.cleanAssistantMessageText("openclaw: command not found") == "")
        #expect(MessageCleaner.cleanAssistantMessageText("bash: foo-bar: command not found") == "")
        #expect(MessageCleaner.cleanAssistantMessageText("sh: 1: gh: not found") == "")
        #expect(MessageCleaner.cleanAssistantMessageText("zsh: rem.cli: command not found") == "")
    }

    @Test func stripsBrowserNodeRuntimeDiagnostics() {
        let input = """
        node command not allowed: the node (platform: macOS 26.1.0) does not support "system.run.prepare"
        agent=main node=0d0cd631d7750bc2e69e3c8aa3884cb39f6651a54033690ff092fa68db1b0653 gateway=default action=invoke: invokeCommand "system.run" is reserved for shell execution; use exec with host=node instead
        No connected browser-capable nodes.

        I tried, but this Mac node can't open a browser yet.
        """

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "I tried, but this Mac node can't open a browser yet.")
    }

    @Test func preservesBrowserRuntimeDiagnosticsWhenBrowserOpenFails() {
        let input = """
        node command not allowed: the node (platform: macOS 26.1.0) does not support "system.run.prepare"
        agent=main node=0d0cd631d7750bc2e69e3c8aa3884cb39f6651a54033690ff092fa68db1b0653 gateway=default action=invoke: invokeCommand "system.run" is reserved for shell execution; use exec with host=node instead
        No connected browser-capable nodes.

        I tried, but this Mac node can't open a browser yet.
        """

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "I tried, but this Mac node can't open a browser yet.")
        #expect(result.diagnosticsText?.contains("node command not allowed") == true)
        #expect(result.diagnosticsText?.contains("No connected browser-capable nodes.") == true)
    }

    @Test func suppressesTransientBrowserDiagnosticsWhenBrowserOpenSucceeds() {
        let input = """
        node command not allowed: the node (platform: macOS 26.1.0) does not support "system.run.prepare"
        agent=main node=0d0cd631d7750bc2e69e3c8aa3884cb39f6651a54033690ff092fa68db1b0653 gateway=default action=invoke: invokeCommand "system.run" is reserved for shell execution; use exec with host=node instead
        No connected browser-capable nodes.

        Opened Chrome with https://www.youtube.com/watch?v=dQw4w9WgXcQ.
        """

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "Opened Chrome with https://www.youtube.com/watch?v=dQw4w9WgXcQ.")
        #expect(result.diagnosticsText == nil)
    }

    @Test func keepsBrowserDiagnosticsForOpeningFailureProse() {
        let input = """
        node command not allowed: the node (platform: macOS 26.1.0) does not support "system.run.prepare"
        No connected browser-capable nodes.

        I tried opening Chrome, but this Mac node can't open a browser yet.
        """

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "I tried opening Chrome, but this Mac node can't open a browser yet.")
        #expect(result.diagnosticsText?.contains("No connected browser-capable nodes.") == true)
    }

    @Test func detectsRuntimePairingDiagnosticForRecoveryCTA() {
        let input = """
        agent=main node=9d93f2a33738998ae6b18722e63fa7d879e-b6e99d1e938b1fdec3531595e4932 gateway=default action=invoke: pairing required before node invoke. Approve the pending pairing request and retry.
        """

        #expect(SharedChatDiagnosticDisplay.isRuntimeDiagnostic(input))
        #expect(SharedChatDiagnosticDisplay.needsRuntimePairingApproval(input))
        #expect(SharedChatDiagnosticDisplay.collapsedTitle(for: input) == "Machine permission needed")
    }

    @Test func routesRuntimePairingDiagnosticOutOfAssistantDisplayText() {
        let input = """
        agent=main node=9d93f2a33738998ae6b18722e63fa7d879e-b6e99d1e938b1fdec3531595e4932 gateway=default action=invoke: pairing required before node invoke. Approve the pending pairing request and retry.
        """

        let result = MessageCleaner.cleanAssistantMessage(input)

        #expect(result.displayText.isEmpty)
        #expect(result.diagnosticsText?.contains("pairing required before node invoke") == true)
        #expect(SharedChatDiagnosticDisplay.collapsedTitle(for: result.diagnosticsText ?? "") == "Machine permission needed")
    }

    @Test func keepsProseWithUsageThenCommandsInProse() {
        // 'Usage:' followed by 'Commands:' in normal prose (not a CLI help
        // block — no blank line separator) should NOT trigger help stripping.
        let input = """
        Usage: this app helps you manage tasks.
        Commands: include add, list, and delete operations.
        Each command takes some arguments.
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.contains("Usage: this app"))
        #expect(result.contains("Commands: include add"))
    }

    @Test func collapsesRealHelpBlockWithBlankLineSeparator() {
        // Real CLI help: Usage:, blank line, then Options:/Commands: at column 0.
        // Phase 2 (#260) collapses rather than strips.
        let input = """
        Usage: openclaw [options]

        Options:
          --help    Show help
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.hasPrefix("```sh\n"))
        #expect(result.hasSuffix("\n```"))
        #expect(result.contains("Usage: openclaw [options]"))
    }

    // MARK: - File operation and git noise stripping

    @Test func stripsStandaloneFileOperationAndGitNoise() {
        let input = """
        Successfully replaced 1 block(s) in /Users/example/.openclaw/workspace/USER.md.
        Successfully replaced text in /Users/example/.openclaw/workspace/IDENTITY.md.
        M IDENTITY.md
        ?? .openclaw/
        [main 86339e0] Update user profile notes
        1 file changed, 19 insertions(+)
        create mode 100644 USER.md
        """

        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsFileOperationNoiseBeforeAssistantReply() {
        let input = """
        Successfully replaced 1 block(s) in /Users/example/.openclaw/workspace/IDENTITY.md.
        Successfully replaced 1 block(s) in /Users/example/.openclaw/workspace/USER.md.
        [main 4532bd0] Capture adaptive personality preference
        2 files changed, 4 insertions(+), 3 deletions(-)

        Yeah, that works for me.

        I'll keep it flexible and match your energy.
        """

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(!result.contains("Successfully replaced"))
        #expect(!result.contains("[main 4532bd0]"))
        #expect(!result.contains("files changed"))
        #expect(result == "Yeah, that works for me.\n\nI'll keep it flexible and match your energy.")
    }

    @Test func stripsScreenshotShapedWorkspaceNoise() {
        let input = """
        Successfully replaced 1 block(s) in /Users/example/.openclaw/workspace/USER.md.

        M IDENTITY.md
        ?? .openclaw/
        ?? AGENTS.md
        ?? BOOTSTRAP.md
        ?? HEARTBEAT.md
        ?? SOUL.md
        ?? TOOLS.md
        ?? USER.md
        [main 86339e0] Update user profile notes
        1 file changed, 19 insertions(+)
        create mode 100644 USER.md

        That's a pretty good place to start, honestly.
        """

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "That's a pretty good place to start, honestly.")
    }

    @Test func keepsProseThatMentionsGitOutputWords() {
        let input = """
        When you see git status output like M IDENTITY.md or create mode 100644 USER.md, that usually means files changed.
        """

        #expect(MessageCleaner.cleanAssistantMessageText(input) == input)
    }

    @Test func keepsStandaloneProseThatStartsLikeGitStatusToken() {
        #expect(MessageCleaner.cleanAssistantMessageText("A pretty good place to start.") == "A pretty good place to start.")
        #expect(MessageCleaner.cleanAssistantMessageText("Might be worth checking settings next.") == "Might be worth checking settings next.")
    }

    // MARK: - Skill installation and manifest noise stripping

    @Test func stripsStandaloneSkillMetadataDump() {
        let input = #"""
        name: github
        description: "GitHub operations via gh CLI: issues, PRs, CI runs."
        metadata:
          {
            "openclaw":
              {
                "emoji": "octopus",
                "requires": { "bins": ["gh"] },
                "install":
                  [
                    {
                      "id": "brew",
                      "kind": "brew",
                      "formula": "gh",
                      "bins": ["gh"],
                      "label": "Install GitHub CLI (brew)"
                    }
                  ]
              }
          }
        """#

        #expect(MessageCleaner.cleanAssistantMessageText(input) == "")
    }

    @Test func stripsSkillMetadataDumpButKeepsAssistantSummary() {
        let input = #"""
        The GitHub skill is available, but it needs the GitHub CLI.

        name: github
        description: "GitHub operations via gh CLI: issues, PRs, CI runs."
        metadata:
          {
            "openclaw": {
              "requires": { "bins": ["gh"] },
              "install": [{ "id": "brew", "formula": "gh" }]
            }
          }

        I can help you connect it next.
        """#

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "The GitHub skill is available, but it needs the GitHub CLI.\n\nI can help you connect it next.")
    }

    @Test func stripsCompactSkillMetadataDumpButKeepsTrailingProse() {
        let input = #"""
        The GitHub skill is available.

        name: github
        description: "GitHub operations via gh CLI."
        metadata: { "openclaw": { "requires": { "bins": ["gh"] }, "install": [] } }

        I can help you connect it next.
        """#

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "The GitHub skill is available.\n\nI can help you connect it next.")
    }

    @Test func stripsPackageManagerInstallTranscript() {
        let input = """
        The gh CLI isn't installed yet. Let me install it:

        sh: 1: gh: not found
        /usr/bin/apt-get
        Reading package lists...
        Building dependency tree...
        Reading state information...
        Get:1 http://deb.debian.org/debian bookworm InRelease [151 kB]
        Get:2 https://cli.github.com/packages stable InRelease [3917 B]
        Fetched 151 kB in 1s (35.3 kB/s)
        Selecting previously unselected package gh.
        Preparing to unpack .../gh.deb ...
        Unpacking gh (2.0.0) ...
        Setting up gh (2.0.0) ...
        8+1 records in
        8+1 records out
        4528 bytes (4.5 kB, 4.4 KiB) copied, 0.128398 s, 35.3 kB/s

        I'll finish the setup once authentication is ready.
        """

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "The gh CLI isn't installed yet. Let me install it:\n\nI'll finish the setup once authentication is ready.")
    }

    @Test func stripsInteractiveAuthTerminalTranscript() {
        let input = """
        y[0K[1A[0G[1C
        [1B[0G[1A[0G[0K[2K[0;1;92m? [0m[0;1;99mAuthenticate Git with your GitHub credentials? [0m[0;36mYes[0m
        [0;36mHow would you like to authenticate GitHub CLI?[0m
        [0;36mUse arrows to move, type to filter[0m
        [0;36mLogin with a web browser[0m
        [0;39m Paste an authentication token[0m
        Process still running.
        Sent 1 bytes to session warm-ocean.
        [0;33m![0m First copy your one-time code: ABE1-6F8E
        [0;1;39mPress Enter[0m to open https://github.com/login/device in your browser...

        I can continue once GitHub authentication completes.
        """

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "I can continue once GitHub authentication completes.")
    }

    @Test func stripsDirectoryListingTranscript() {
        let input = """
        total 220
        drwxr-xr-x 54 root root 4096 May 10 03:59 .
        drwxr-xr-x  1 root root 4096 May 10 04:01 ..
        drwxr-xr-x  3 root root 4096 May 10 03:59 password
        drwxr-xr-x  2 root root 4096 May 10 03:59 apple-notes

        I found several local skill folders.
        """

        #expect(MessageCleaner.cleanAssistantMessageText(input) == "I found several local skill folders.")
    }

    @Test func stripsScreenshotShapedSkillManifestWithEmoji() {
        let input = #"""
        name: github
        description: "GitHub operations via gh CLI: issues, PRs, CI runs, code review, API queries. Use when checking PR status."
        metadata:
          {
            "openclaw":
              {
                "emoji": "🐙",
                "requires": { "bins": ["gh"] },
                "install":
                [
                  {
                    "id": "brew",
                    "kind": "brew",
                    "formula": "gh",
                    "bins": ["gh"],
                    "label": "Install GitHub CLI (brew)"
                  },
                  {
                    "id": "apt",
                    "kind": "apt",
                    "package": "gh",
                    "bins": ["gh"],
                    "label": "Install GitHub CLI (apt)"
                  }
                ]
              }
          }

        The GitHub skill needs the gh CLI before it can run.
        """#

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "The GitHub skill needs the gh CLI before it can run.")
    }

    @Test func stripsPlainYAMLSkillMetadataDump() {
        let input = #"""
        name: github
        description: "GitHub operations via gh CLI: issues, PRs, CI runs."
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

        The GitHub skill needs the gh CLI before it can run.
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "The GitHub skill needs the gh CLI before it can run.")
        #expect(result.diagnosticsText?.contains("```yaml") == true)
        #expect(result.diagnosticsText?.contains("name: github") == true)
        #expect(result.diagnosticsText?.contains("openclaw:") == true)
    }

    @Test func stripsPlainYAMLSkillMetadataDumpWithoutBlankBeforeProse() {
        let input = #"""
        name: github
        description: "GitHub operations via gh CLI."
        metadata:
          openclaw:
            requires:
              bins: ["gh"]
            install:
              - id: brew
                formula: gh
        The GitHub skill needs the gh CLI before it can run.
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "The GitHub skill needs the gh CLI before it can run.")
        #expect(result.diagnosticsText?.contains("metadata:") == true)
        #expect(result.diagnosticsText?.contains("The GitHub skill needs") == false)
    }

    @Test func stripsStandaloneOpenClawSkillJSONManifest() {
        let input = #"""
        {
          "openclaw": {
            "emoji": "🐙",
            "requires": { "bins": ["gh"] },
            "install": [
              { "id": "brew", "kind": "brew", "formula": "gh" }
            ]
          }
        }

        I can install the GitHub CLI next.
        """#

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == "I can install the GitHub CLI next.")
    }

    @Test func keepsFencedOpenClawSkillJSONExample() {
        let input = #"""
        Here is the manifest format:

        ```json
        {
          "openclaw": {
            "requires": { "bins": ["gh"] },
            "install": [
              { "id": "brew", "kind": "brew", "formula": "gh" }
            ]
          }
        }
        ```
        """#

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == input)
    }

    @Test func keepsFencedOpenClawSkillYAMLExample() {
        let input = #"""
        ```yaml
        name: github
        description: "GitHub operations via gh CLI."
        metadata:
          {
            "openclaw": {
              "requires": { "bins": ["gh"] },
              "install": [{ "id": "brew", "formula": "gh" }]
            }
          }
        ```
        """#

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == input)
    }

    @Test func stripsThinkingInstallTranscriptForDisplay() {
        let input = """
        sh: 1: gh: not found
        /usr/bin/apt-get
        Get:1 http://deb.debian.org/debian bookworm InRelease [151 kB]
        8+1 records in
        8+1 records out
        Process still running.

        I need GitHub auth before continuing.
        """

        let result = SharedRemChatView.cleanThinkingTextForDisplay(input)
        #expect(result == "I need GitHub auth before continuing.")
    }

    @Test func preservesStrippedInstallTranscriptAsDiagnostics() {
        let input = """
        The gh CLI isn't installed yet. Let me install it:

        sh: 1: gh: not found
        /usr/bin/apt-get
        Reading package lists...
        Get:1 http://deb.debian.org/debian bookworm InRelease [151 kB]
        8+1 records in
        8+1 records out

        I'll finish the setup once authentication is ready.
        """

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "The gh CLI isn't installed yet. Let me install it:\n\nI'll finish the setup once authentication is ready.")
        #expect(result.diagnosticsText?.contains("```text") == true)
        #expect(result.diagnosticsText?.contains("sh: 1: gh: not found") == true)
        #expect(result.diagnosticsText?.contains("Get:1 http://deb.debian.org/debian") == true)
    }

    @Test func redactsOneTimeCodesInPreservedDiagnostics() {
        let input = """
        Process still running.
        First copy your one-time code: ABE1-6F8E
        Press Enter to open https://github.com/login/device in your browser...

        I can continue once GitHub authentication completes.
        """

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "I can continue once GitHub authentication completes.")
        #expect(result.diagnosticsText?.contains("one-time code: [redacted]") == true)
        #expect(result.diagnosticsText?.contains("ABE1-6F8E") == false)
    }

    @Test func preservesStrippedSkillMetadataAsDiagnostics() {
        let input = #"""
        The GitHub skill is available.

        name: github
        description: "GitHub operations via gh CLI."
        metadata: { "openclaw": { "requires": { "bins": ["gh"] }, "install": [] } }

        I can help you connect it next.
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "The GitHub skill is available.\n\nI can help you connect it next.")
        #expect(result.diagnosticsText?.contains("```yaml") == true)
        #expect(result.diagnosticsText?.contains("name: github") == true)
        #expect(result.diagnosticsText?.contains(#""openclaw""#) == true)
    }

    @Test func stripsRawReminderLifecyclePayloadDump() {
        let input = #"""
        [{"identifier":"D10E22E1-DF20-441B-9A6A-7FDD7E5A6A7E","listName":"Grocery","title":"Water","isCompleted":false,"priority":0},{"identifier":"97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C","listName":"Sorted","title":"Book club","isCompleted":false,"priority":0},{"identifier":"9E4402FE-E092-4144-81B9-F339AAE5EFA9","listName":"Grocery","title":"Honey","isCompleted":false,"priority":0,"notes":"1 tbsp"}]
        ...(truncated)...
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "")
        #expect(result.diagnosticsText == nil)
    }

    @Test func stripsPartialReminderLifecyclePayloadDump() {
        let input = #"""
        {"identifier":"D10E22E1-DF20-441B-9A6A-7FDD7E5A6A7E","listName":"Grocery","title":"Water","isCompleted":false,"priority":0},{"identifier":"97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C","listName":"Sorted","title":"Book club","isCompleted":false,"priority":0},{"identifier":"9E4402FE-E092-4144-81B9-F339AAE5EFA9","listName":"Grocery","title":"Honey","isCompleted":false,"priority":0,"notes":"1 tbsp"}
        ...(truncated)...
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "")
        #expect(result.diagnosticsText == nil)
    }

    @Test func stripsEscapedReminderLifecyclePayloadDump() {
        let input = #"""
        {\"identifier\":\"D10E22E1-DF20-441B-9A6A-7FDD7E5A6A7E\",\"listName\":\"Grocery\",\"title\":\"Water\",\"isCompleted\":false,\"priority\":0},{\"identifier\":\"97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C\",\"listName\":\"Sorted\",\"title\":\"Book club\",\"isCompleted\":false,\"priority\":0}
        ...(truncated)...
        """#

        let result = MessageCleaner.cleanStreamingAssistantMessageText(input)
        #expect(result == "")
    }

    @Test func suppressesStreamingReminderLifecyclePayloadDump() {
        let input = #"""
        {"identifier":"902FDCCF-9BB1-40FC-9300-8483EB1343F7","listName":"Life Plan","title":"Renew work permit","isCompleted":false,"priority":0}
        ...(truncated)...
        """#

        let result = MessageCleaner.cleanStreamingAssistantMessageText(input)
        #expect(result == "")
    }

    @Test func stripsMixedReminderLifecyclePayloadDumpAndKeepsProse() {
        let input = #"""
        [{"identifier":"D10E22E1-DF20-441B-9A6A-7FDD7E5A6A7E","listName":"Grocery","title":"Water","isCompleted":false,"priority":0},{"identifier":"97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C","listName":"Sorted","title":"Book club","isCompleted":false,"priority":0}]
        ...(truncated)...

        I found the reminder! There are actually two matching reminders. Let me update the first one.
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "I found the reminder! There are actually two matching reminders. Let me update the first one.")
        #expect(result.diagnosticsText == nil)
    }

    @Test func stripsMidstreamReminderLifecyclePayloadDumpAndKeepsProse() {
        let input = #"""
        "title":"Water","isCompleted":false,"priority":0},{"identifier":"97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C","listName":"Sorted","title":"Book club","isCompleted":false}
        ...(truncated)...

        Reminder updated.
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "Reminder updated.")
        #expect(result.diagnosticsText == nil)
    }

    @Test func stripsScreenshotReminderDumpAndKeepsFollowupProse() {
        let input = #"""
        "title":"Batteries for Philips Hue Dimmer","isCompleted":false,"priority":0},{"identifier":"D10E206B-D14B-441B-9A6A-7B73CCEA2169","listName":"Grocery","title":"Water","isCompleted":false,"priority":0},{"identifier":"97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C","listName":"Sorted","title":"Book club","isCompleted":false,"priority":0},{"identifier":"9E4402FE-E092-4144-81B9-F339AAE5EFA9","listName":"Grocery","title":"Honey","isCompleted":false,"priority":0,"notes":"1 tbsp"},{"identifier":"902FDCCF-9BB1-40FC-9300-8483EB1343F7","listName":"Life Plan","title":"Renew work permit","isCompleted":false,"priority":0},{
        ...(truncated)...

        I found the reminder! There are actually two identical ones about checking with Redwood Legal. I can see they're currently set for 2026-06-11T01:00:00Z, which is actually 6pm PDT today. Let me update the first one to confirm the 6pm time:
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText.hasPrefix("I found the reminder!"))
        #expect(result.displayText.contains("Let me update the first one"))
        #expect(!result.displayText.contains(#""identifier""#))
        #expect(!result.displayText.contains(#""listName""#))
        #expect(!result.displayText.contains("...(truncated)..."))
        #expect(result.diagnosticsText == nil)
    }

    @Test func stripsGatewayReminderEnvelopeDumpAndKeepsFollowupProse() {
        let input = #"""
        {
          "ok": true,
          "nodeId": "9d93f2a33738998ae6b18722e63fa7d879eb6e99d1e938b1fdec3531595e4932",
          "command": "reminders.update",
          "payload": {
            "identifier": "97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C",
            "title": "Check if Redwood Legal has responded",
            "isCompleted": true
          }
        }

        Done! Your reminder is marked as completed.
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == "Done! Your reminder is marked as completed.")
        #expect(!result.displayText.contains(#""nodeId""#))
        #expect(!result.displayText.contains(#""command""#))
        #expect(!result.displayText.contains(#""payload""#))
        #expect(result.diagnosticsText == nil)
    }

    @Test func keepsStandaloneGatewayReminderEnvelopeForResultCards() {
        let input = #"""
        {"ok":true,"nodeId":"9d93f2a33738998ae6b18722e63fa7d879eb6e99d1e938b1fdec3531595e4932","command":"reminders.update","payload":{"identifier":"97ABB7FA-FDB8-4445-B6A4-E1C93E2A5F5C","title":"Check if Redwood Legal has responded","isCompleted":true}}
        """#

        let result = MessageCleaner.cleanAssistantMessage(input)
        #expect(result.displayText == input.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(result.diagnosticsText == nil)
    }

    @Test func keepsReminderLifecycleProse() {
        let input = "I found the reminder and updated it for 6 PM."

        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result == input)
    }
}
