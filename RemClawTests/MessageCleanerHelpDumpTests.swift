import Foundation
import Testing
@testable import RemClaw

/// Phase 2 tests for #260 (Chat sanitization gaps: shell command output and
/// tool errors leak into AI bubbles): multi-line CLI-help-dump detector and
/// ```sh fenced-block collapse. Preserves content non-destructively rather
/// than stripping to empty.
///
/// Mirrors the shape of `openclaw/apps/shared/OpenClawKit/Tests/OpenClawKitTests/ChatMarkdownPreprocessorTests.swift`.
struct MessageCleanerHelpDumpTests {

    // MARK: - Full openclaw --help dump (synthesized from real CLI output)
    //
    // Captured from `~/.openclaw/bin/openclaw --help` (OpenClaw 2026.4.15).
    // Trimmed to representative sections (Usage + Options + Commands).

    @Test func collapsesFullOpenclawHelpDump() {
        let input = """
        Usage: openclaw [options] [command]

        Options:
          --container <name>   Run the CLI inside a running Podman/Docker container
                               named <name> (default: env OPENCLAW_CONTAINER)
          --dev                Dev profile: isolate state under ~/.openclaw-dev, default
                               gateway port 19001, and shift derived ports
                               (browser/canvas)
          -h, --help           Display help for command
          --log-level <level>  Global log level override for file + console
                               (silent|fatal|error|warn|info|debug|trace)
          --no-color           Disable ANSI colors
          --profile <name>     Use a named profile
          -V, --version        output the version number

        Commands:
          agent                Run one agent turn via the Gateway
          agents *             Manage isolated agents (workspaces, auth, routing)
          channels *           Manage connected chat channels (Telegram, Discord, etc.)
          devices *            Device pairing + token management
          gateway *            Run, inspect, and query the WebSocket Gateway
          help                 Display help for command
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)

        // Entire dump collapses into a single ```sh fence.
        #expect(result.hasPrefix("```sh\n"))
        #expect(result.hasSuffix("\n```"))

        // Content preserved non-destructively.
        #expect(result.contains("Usage: openclaw [options] [command]"))
        #expect(result.contains("--container <name>"))
        #expect(result.contains("Options:"))
        #expect(result.contains("Commands:"))
        #expect(result.contains("agent                Run one agent turn via the Gateway"))
        #expect(result.contains("devices *"))

        // Contiguous sections group into ONE fence, not multiple.
        let fenceOpens = result.components(separatedBy: "```sh").count - 1
        let fenceCloses = result.components(separatedBy: "```").count - 1 - fenceOpens
        #expect(fenceOpens == 1)
        #expect(fenceCloses == 1)
    }

    @Test func suppressesOpenClawHelpDumpDuringStreaming() {
        let input = """
        🦞 OpenClaw 2026.4.9 (0512059) — Your .env is showing; don't worry, I'll pretend I didn't see it.

        Usage: openclaw devices [options] [command]

        Device pairing and auth tokens

        Options:
          -h, --help  Display help for command

        Commands:
          approve  Approve a pending device pairing request
          list     List pending and paired devices
        """

        #expect(MessageCleaner.cleanStreamingAssistantMessageText(input) == "")
        let final = MessageCleaner.cleanAssistantMessageText(input)
        #expect(final.contains("```sh"))
    }

    @Test func suppressesPartialOpenClawHelpDumpDuringStreaming() {
        let input = """
        🦞 OpenClaw 2026.4.9 (0512059) — I'm the reason your shell history looks like a
        """

        #expect(MessageCleaner.cleanStreamingAssistantMessageText(input) == "")
    }

    @Test func keepsNormalAssistantTextDuringStreaming() {
        let input = "Sure, I can help you create that task."
        #expect(MessageCleaner.cleanStreamingAssistantMessageText(input) == input)
    }

    // MARK: - Partial dump (Options block only, no Commands)

    @Test func collapsesPartialHelpDumpWithOnlyOptions() {
        let input = """
        Usage: openclaw gateway [options]

        Options:
          --port <n>    Listen port
          --host <h>    Bind host
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)

        #expect(result.hasPrefix("```sh\n"))
        #expect(result.hasSuffix("\n```"))
        #expect(result.contains("Usage: openclaw gateway"))
        #expect(result.contains("--port <n>"))
        #expect(result.contains("--host <h>"))
    }

    // MARK: - Interleaved prose + dump

    @Test func preservesSurroundingProseAroundCollapsedDump() {
        let input = """
        Here's the help:

        Usage: foo bar [options]

        Options:
          --flag    A flag

        Let me know if that works.
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)

        // Prose before and after survives.
        #expect(result.contains("Here's the help:"))
        #expect(result.contains("Let me know if that works."))

        // Fence is inline between the prose.
        #expect(result.contains("```sh"))
        #expect(result.contains("Usage: foo bar [options]"))
        #expect(result.contains("--flag    A flag"))

        // Prose NOT inside fence — check that "Let me know" comes after the
        // closing fence, not captured inside the code block.
        if let fenceClose = result.range(of: "```", options: .backwards),
           let letMeKnow = result.range(of: "Let me know if that works.") {
            #expect(fenceClose.upperBound <= letMeKnow.lowerBound)
        } else {
            Issue.record("expected both closing fence and trailing prose")
        }
    }

    // MARK: - Extended section headers

    @Test func collapsesDumpWithFlagsHeader() {
        let input = """
        Usage: tool cmd [flags]

        Flags:
          -v    Verbose
          -q    Quiet
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.hasPrefix("```sh\n"))
        #expect(result.contains("Flags:"))
        #expect(result.contains("-v    Verbose"))
    }

    @Test func collapsesDumpWithEnvironmentHeader() {
        let input = """
        Usage: tool [options]

        Environment:
          FOO_BAR    Controls foo behavior
          BAZ        Set the baz
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.hasPrefix("```sh\n"))
        #expect(result.contains("Environment:"))
        #expect(result.contains("FOO_BAR"))
    }

    @Test func collapsesDumpWithExamplesHeader() {
        let input = """
        Usage: tool cmd <arg>

        Examples:
          tool cmd foo
          tool cmd bar --verbose
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(result.hasPrefix("```sh\n"))
        #expect(result.contains("Examples:"))
        #expect(result.contains("tool cmd foo"))
    }

    // MARK: - Contiguous multi-section dump groups into one fence

    @Test func groupsContiguousSectionsIntoSingleFence() {
        let input = """
        Usage: foo [options] <cmd>

        Options:
          --x    X option
          --y    Y option

        Commands:
          a    Do A
          b    Do B

        Examples:
          foo a
          foo b --x
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)

        // One fence open, one fence close — not three.
        let openCount = result.components(separatedBy: "```sh").count - 1
        #expect(openCount == 1)

        // All three sections captured inside.
        #expect(result.contains("Options:"))
        #expect(result.contains("Commands:"))
        #expect(result.contains("Examples:"))
        #expect(result.contains("--x    X option"))
        #expect(result.contains("a    Do A"))
    }

    // MARK: - Negative cases (do NOT trigger fence)

    @Test func doesNotCollapseUsageInProse() {
        // "Usage:" without a recognized section-header follow-up is normal
        // prose and must NOT be wrapped.
        let input = """
        Usage: this app helps manage tasks.
        It's intuitive.
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(!result.contains("```sh"))
        #expect(result.contains("Usage: this app helps"))
    }

    @Test func doesNotCollapseWhenHeaderIsMidProse() {
        // A recognized header must be preceded by a blank line (canonical CLI
        // format). Mid-prose `Commands:` should NOT trigger collapse.
        let input = """
        Usage: some tool works like this.
        Commands: include add, list, and delete.
        All take arguments.
        """
        let result = MessageCleaner.cleanAssistantMessageText(input)
        #expect(!result.contains("```sh"))
        #expect(result.contains("Usage: some tool"))
        #expect(result.contains("Commands: include add"))
    }
}
