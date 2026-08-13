import Foundation
import Testing
@testable import RemClaw

/// Covers the two chat-history display fixes:
///   • BUG 1 — a session's title is pinned once and never changes on later
///     messages, even when the gateway/agent re-titles the session each turn.
///   • BUG 2 — the row subtitle shows the real last message, with the generic
///     placeholder reserved for sessions that have no preview at all.
struct SessionTitleAndSubtitleTests {

    // MARK: - BUG 2: subtitle resolution

    @Test func localPreviewWinsOverEverything() {
        let subtitle = SessionRowSubtitleResolver.resolve(
            localPreview: "Remind me to call Alex",
            serverPreview: "something else",
            totalTokens: 1200,
            hasUpdatedAt: true
        )
        #expect(subtitle == "Remind me to call Alex")
    }

    @Test func serverPreviewUsedWhenNoLocalPreview() {
        let subtitle = SessionRowSubtitleResolver.resolve(
            localPreview: nil,
            serverPreview: "Here's your updated schedule for tomorrow",
            totalTokens: 1200,
            hasUpdatedAt: true
        )
        #expect(subtitle == "Here's your updated schedule for tomorrow")
    }

    @Test func placeholderFallbackFiresOnlyWhenNoRealPreviewAvailable() {
        // Session has history (tokens) but neither a local nor a server preview —
        // e.g. an older gateway that can't return lastMessagePreview.
        let subtitle = SessionRowSubtitleResolver.resolve(
            localPreview: nil,
            serverPreview: nil,
            totalTokens: 800,
            hasUpdatedAt: true
        )
        #expect(subtitle == SessionRowSubtitleResolver.savedPlaceholder)
    }

    @Test func realPreviewSuppressesTheGenericPlaceholder() {
        // The regression: a session with history must NOT show
        // "Conversation saved on your machine" when a real preview exists.
        let subtitle = SessionRowSubtitleResolver.resolve(
            localPreview: nil,
            serverPreview: "What's on my calendar today?",
            totalTokens: 800,
            hasUpdatedAt: true
        )
        #expect(subtitle != SessionRowSubtitleResolver.savedPlaceholder)
        #expect(subtitle == "What's on my calendar today?")
    }

    @Test func fromMachinePlaceholderWhenOnlyUpdatedAt() {
        let subtitle = SessionRowSubtitleResolver.resolve(
            localPreview: nil,
            serverPreview: nil,
            totalTokens: nil,
            hasUpdatedAt: true
        )
        #expect(subtitle == SessionRowSubtitleResolver.fromMachinePlaceholder)
    }

    @Test func genuinelyEmptySessionHasNoSubtitle() {
        let subtitle = SessionRowSubtitleResolver.resolve(
            localPreview: nil,
            serverPreview: nil,
            totalTokens: 0,
            hasUpdatedAt: false
        )
        #expect(subtitle == nil)
    }

    @Test func whitespaceOnlyPreviewsAreTreatedAsEmpty() {
        let subtitle = SessionRowSubtitleResolver.resolve(
            localPreview: "   ",
            serverPreview: "\n\t",
            totalTokens: 500,
            hasUpdatedAt: true
        )
        #expect(subtitle == SessionRowSubtitleResolver.savedPlaceholder)
    }

    // MARK: - BUG 1: title is set once and stays stable

    @Test func setNameIfAbsentPinsFirstTitleAndIgnoresLaterRetitles() {
        let key = "test-session-\(UUID().uuidString)"
        defer { SessionDisplayNames.removeName(for: key) }

        // First user message pins the title.
        SessionDisplayNames.setNameIfAbsent("Plan my launch week", for: key)
        #expect(SessionDisplayNames.name(for: key) == "Plan my launch week")

        // The agent re-titles the session on subsequent turns; the app observes a
        // new gateway label on each refresh and tries to pin it. setNameIfAbsent
        // must keep the original so the visible title never changes.
        SessionDisplayNames.setNameIfAbsent("Launch checklist", for: key)
        SessionDisplayNames.setNameIfAbsent("Marketing timeline", for: key)
        #expect(SessionDisplayNames.name(for: key) == "Plan my launch week")
    }

    @Test func explicitRenameStillOverridesThePinnedTitle() {
        let key = "test-session-\(UUID().uuidString)"
        defer { SessionDisplayNames.removeName(for: key) }

        SessionDisplayNames.setNameIfAbsent("Plan my launch week", for: key)
        // A deliberate user rename uses setName (not setNameIfAbsent) and wins.
        SessionDisplayNames.setName("Q3 Launch", for: key)
        #expect(SessionDisplayNames.name(for: key) == "Q3 Launch")
    }

    @Test func acceptedTitlesBatchSeedsMissingNamesWithoutOverwritingExistingOnes() {
        let existingKey = "test-existing-\(UUID().uuidString)"
        let missingKey = "test-missing-\(UUID().uuidString)"
        defer {
            SessionDisplayNames.removeName(for: existingKey)
            SessionDisplayNames.removeName(for: missingKey)
        }

        SessionDisplayNames.setName("My custom name", for: existingKey)
        SessionDisplayNames.setNamesIfAbsent([
            existingKey: "Server replacement",
            missingKey: "Cross-device title",
        ])

        #expect(SessionDisplayNames.name(for: existingKey) == "My custom name")
        #expect(SessionDisplayNames.name(for: missingKey) == "Cross-device title")
    }

    @Test func acceptedCrossDeviceTitleRequiresConversationEvidence() {
        #expect(MessageCleaner.acceptedSessionTitle(
            derivedTitle: "a1b2c3d4 (2026-08-07)",
            displayName: nil,
            lastMessagePreview: nil,
            totalTokens: 0
        ) == nil)

        #expect(MessageCleaner.acceptedSessionTitle(
            derivedTitle: "Plan my launch week",
            displayName: nil,
            lastMessagePreview: "Here is the plan",
            totalTokens: nil
        ) == "Plan my launch week")

        #expect(MessageCleaner.acceptedSessionTitle(
            derivedTitle: "Plan my launch week",
            displayName: nil,
            lastMessagePreview: nil,
            totalTokens: 820
        ) == "Plan my launch week")
    }

    // MARK: - Session-list envelope stripping (untrusted metadata / JSON)

    @Test func cleanSessionListStripsCollapsedTruncatedSenderEnvelope() {
        // The reported bug: a channel/inbound message's derived title/preview is
        // cached with newlines collapsed and truncated, so the raw envelope leaks.
        let raw = #"Sender (untrusted metadata): ```json { "label": "iPhone 17", "cha…"#
        // Nothing human-readable survives → nil so the row falls back to a name.
        #expect(MessageCleaner.cleanSessionListDisplayText(raw) == nil)
    }

    @Test func cleanSessionListKeepsRealMessageAfterEnvelope() {
        // A complete collapsed envelope followed by the actual user message keeps
        // only the message text.
        let raw = #"Sender (untrusted metadata): ```json { "label": "iPhone" } ``` What's on my calendar today?"#
        #expect(MessageCleaner.cleanSessionListDisplayText(raw) == "What's on my calendar today?")
    }

    @Test func cleanSessionListStripsMultilineInboundContextBlock() {
        // The non-collapsed transcript form is handled by the standard cleaner.
        let raw = """
        Sender (untrusted metadata):
        ```json
        { "label": "iPhone 17" }
        ```
        Remind me to call Alex
        """
        #expect(MessageCleaner.cleanSessionListDisplayText(raw) == "Remind me to call Alex")
    }

    @Test func legacyDevicePreambleAndRuntimeNamesNeverBecomeTitles() {
        let legacy = """
        [System: Connected to RemAgent (iPhone, iOS 19.0). Local time: 2026-08-06 12:30 PDT.]

        Plan tomorrow
        """
        #expect(MessageCleaner.usableSessionTitle(legacy) == "Plan tomorrow")
        #expect(MessageCleaner.usableSessionTitle("RemAgent") == nil)
        #expect(MessageCleaner.usableSessionTitle("Rem Agent") == nil)
        #expect(MessageCleaner.usableSessionTitle("remagent") == nil)
        #expect(MessageCleaner.usableSessionTitle("RemAgent today") == nil)
        #expect(MessageCleaner.usableSessionTitle("REM AGENT session") == nil)
        #expect(MessageCleaner.usableSessionTitle("RemAgent: Today") == nil)
    }

    @Test func cleanSessionListPassesThroughCleanTitles() {
        // Ordinary titles / previews are returned unchanged.
        #expect(MessageCleaner.cleanSessionListDisplayText("Plan my launch week") == "Plan my launch week")
    }

    @Test func cleanSessionListReturnsNilForEmptyOrNil() {
        #expect(MessageCleaner.cleanSessionListDisplayText(nil) == nil)
        #expect(MessageCleaner.cleanSessionListDisplayText("   ") == nil)
    }

    // MARK: - Session-list Markdown flattening (tables + inline markup)

    @Test func cleanSessionListFlattensCollapsedTable() {
        // Tool result: a GFM table whose newlines were collapsed to spaces in the
        // preview cache. The `|------|------|` separator and pipe cell dividers must
        // not leak into the one-line subtitle.
        let raw = "| Name | Role | |------|------| | Alice | Engineer | | Bob | Designer |"
        #expect(
            MessageCleaner.cleanSessionListDisplayText(raw)
                == "Name Role Alice Engineer Bob Designer")
    }

    @Test func cleanSessionListKeepsProseBeforeTable() {
        // Prose lead-in followed by an inline table — prose survives, pipes/`#` cell
        // dividers become clean spaces.
        let raw = "Here are your 3 most recent emails: | # | Sender | Subject | | Ana | Lunch? |"
        #expect(
            MessageCleaner.cleanSessionListDisplayText(raw)
                == "Here are your 3 most recent emails: # Sender Subject Ana Lunch?")
    }

    @Test func cleanSessionListStripsInlineMarkup() {
        let raw = "See **Q3 launch** notes and [the doc](https://example.com/x) for `details`"
        #expect(
            MessageCleaner.cleanSessionListDisplayText(raw)
                == "See Q3 launch notes and the doc for details")
    }

    @Test func cleanSessionListStripsHeadingHashes() {
        let raw = """
        ## Recent emails
        - Ana: Lunch?
        """
        #expect(MessageCleaner.cleanSessionListDisplayText(raw) == "Recent emails Ana: Lunch?")
    }

    @Test func cleanSessionListPreservesSnakeCaseIdentifiers() {
        // Underscore emphasis is intentionally not unwrapped so identifiers survive.
        #expect(
            MessageCleaner.cleanSessionListDisplayText("Updated user_profile_id field")
                == "Updated user_profile_id field")
    }

    @Test func cleanSessionListKeepsInlineCodePipe() {
        // A shell pipe inside inline code must survive — only real table rows
        // (2+ pipes) get flattened, so this single inline pipe is left intact.
        let raw = "Run `cat app.log | grep error`"
        #expect(
            MessageCleaner.cleanSessionListDisplayText(raw)
                == "Run cat app.log | grep error")
    }

    @Test func cleanSessionListKeepsSingleInlinePipe() {
        // A lone `A | B` pipe is not a table row and must not be mangled.
        #expect(
            MessageCleaner.cleanSessionListDisplayText("Compare A | B")
                == "Compare A | B")
    }

    @Test func cleanSessionListUnwrapsBalancedParenLink() {
        // The URL contains a balanced `(bar)`; the link regex must consume the
        // whole URL so only the link text remains (no stray trailing paren).
        let raw = "See [Foo](https://example.com/Foo_(bar)) now"
        #expect(MessageCleaner.cleanSessionListDisplayText(raw) == "See Foo now")
    }
}
