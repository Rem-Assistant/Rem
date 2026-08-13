import Foundation
import Testing
@testable import RemClaw

/// Tests for `BriefContext` — the Daily Brief hidden-context injection (#985).
///
/// Focus (per review): the once-per-day guard must survive a FAILED first send.
/// `peekPreamble` must NOT burn the guard; only `commitInjection` (called after a
/// successful `chat.send`) does. So a failed send (peek, no commit) leaves the day
/// un-injected and the retry re-injects; a successful send (peek + commit) marks it.
///
/// `BriefContext` reads/writes `UserDefaults.standard`, so every test uses a unique
/// per-run session key and clears its own state in a `defer`, keeping runs hermetic
/// and non-colliding.
/// `.serialized` + an isolated `UserDefaults` suite: every test mutates the same
/// two `BriefContext` keys, so we (a) point `BriefContext.defaults` at a private
/// suite that never touches real user defaults, and (b) run serially so the
/// read-modify-write on those keys can't race across tests in this suite.
/// Nested under `BriefDefaultsSuites` so it cannot run concurrently with the other suite
/// that re-points the process-global `BriefContext.defaults`.
extension BriefDefaultsSuites {
@Suite(.serialized)
final class BriefContextTests {

    private static let suiteName = "BriefContextTests.isolated"
    private let store: UserDefaults

    init() {
        // Fresh, isolated defaults for the whole suite.
        UserDefaults().removePersistentDomain(forName: Self.suiteName)
        store = UserDefaults(suiteName: Self.suiteName)!
        BriefContext.defaults = store
    }

    deinit {
        store.removePersistentDomain(forName: Self.suiteName)
        BriefContext.defaults = .standard
    }

    /// A fresh `rem-today-<unique>` key that won't collide with real data or a
    /// concurrent test. Not a real date stamp — only the `rem-today-` prefix and
    /// per-run uniqueness matter for the guard logic.
    private func uniqueBriefKey() -> String {
        "rem-today-test-\(UUID().uuidString)"
    }

    /// Remove all persisted state for a key so a test leaves no residue.
    private func cleanup(_ key: String) {
        BriefContext.clearForTesting(sessionKey: key)
    }

    // MARK: - Failed send does NOT burn the guard (the review bug)

    @Test func failedFirstSendLeavesDayUninjected_retryReinjects() {
        let key = uniqueBriefKey()
        defer { cleanup(key) }
        BriefContext.setMarkdown("# Brief\n- one\n- two", for: key)

        // First attempt: peek returns the preamble (send is about to happen)...
        let firstPeek = BriefContext.peekPreamble(for: key)
        #expect(firstPeek != nil)
        #expect(firstPeek?.contains("# Brief") == true)

        // ...but the send FAILS, so we never commit. The retry must re-peek the
        // SAME preamble — the day is still un-injected.
        let retryPeek = BriefContext.peekPreamble(for: key)
        #expect(retryPeek != nil)
        #expect(retryPeek == firstPeek)
    }

    // MARK: - Successful send burns the guard exactly once

    @Test func successfulFirstSendMarksDay_subsequentSendsSkip() {
        let key = uniqueBriefKey()
        defer { cleanup(key) }
        BriefContext.setMarkdown("# Brief\n- one", for: key)

        // First send: peek then commit (send succeeded).
        #expect(BriefContext.peekPreamble(for: key) != nil)
        BriefContext.commitInjection(for: key)

        // Every later send in the same day now peeks nil — no re-injection.
        #expect(BriefContext.peekPreamble(for: key) == nil)
    }

    @Test func commitIsIdempotent() {
        let key = uniqueBriefKey()
        defer { cleanup(key) }
        BriefContext.setMarkdown("brief prose", for: key)

        BriefContext.commitInjection(for: key)
        BriefContext.commitInjection(for: key) // second commit must be harmless
        #expect(BriefContext.peekPreamble(for: key) == nil)
    }

    @Test func durableSessionNeverStoresOrInjectsHiddenBriefContext() {
        let key = BriefContext.durableSessionKey
        defer { cleanup(key) }

        BriefContext.setMarkdown("Already visible assistant artifact", for: key)

        #expect(BriefContext.isBriefSession(key) == true)
        #expect(BriefContext.usesLegacyContextFallback(key) == false)
        #expect(BriefContext.peekPreamble(for: key) == nil)
    }

    // MARK: - No-op cases

    @Test func nonBriefSessionNeverInjects() {
        let key = "chat-\(UUID().uuidString)"
        defer { cleanup(key) }
        // setMarkdown is a no-op for a non-brief key, and peek returns nil.
        BriefContext.setMarkdown("should be ignored", for: key)
        #expect(BriefContext.peekPreamble(for: key) == nil)
        #expect(BriefContext.isBriefSession(key) == false)
    }

    @Test func briefSessionWithNoStoredProseYieldsNil() {
        let key = uniqueBriefKey()
        defer { cleanup(key) }
        // No setMarkdown call → nothing to inject.
        #expect(BriefContext.isBriefSession(key) == true)
        #expect(BriefContext.peekPreamble(for: key) == nil)
    }

    @Test func nilProseClearsPreviouslyPersistedBriefContext() {
        let key = uniqueBriefKey()
        defer { cleanup(key) }
        BriefContext.setMarkdown("stale authored brief", for: key)
        #expect(BriefContext.peekPreamble(for: key)?.contains("stale authored brief") == true)

        // Once durable transcript prose is present, ContentView passes nil. That
        // transition must remove—not preserve—the older hidden first-turn context.
        BriefContext.setMarkdown(nil, for: key)
        #expect(BriefContext.peekPreamble(for: key) == nil)
    }

    // MARK: - Key normalization (canonical `agent:main:` form)

    @Test func canonicalAndBareKeysShareState() {
        let bare = uniqueBriefKey()
        let canonical = "agent:main:\(bare)"
        defer { cleanup(bare) }

        // Store under the canonical form...
        BriefContext.setMarkdown("cross-form prose", for: canonical)
        // ...and read under the bare form — same slot.
        let barePeek = BriefContext.peekPreamble(for: bare)
        #expect(barePeek != nil)
        #expect(barePeek?.contains("cross-form prose") == true)

        // Commit under the bare form marks the canonical form injected too.
        BriefContext.commitInjection(for: bare)
        #expect(BriefContext.peekPreamble(for: canonical) == nil)
    }

    @Test func canonicalFormIsRecognizedAsBriefSession() {
        #expect(BriefContext.isBriefSession("agent:main:rem-today-20260706") == true)
        #expect(BriefContext.isBriefSession("agent:main:chat-abc") == false)
    }

    // MARK: - Preamble shape (round-trips through the strip)

    @Test func preambleIsStrippedBackToEmptyByCleaner() {
        let key = uniqueBriefKey()
        defer { cleanup(key) }
        let md = "# Today\n- [link](http://x) (a|b) $x .* stuff"
        BriefContext.setMarkdown(md, for: key)

        let preamble = BriefContext.peekPreamble(for: key)
        #expect(preamble != nil)
        // The wire message = preamble + user text; the cleaner must strip the block
        // and leave ONLY the user text (mirrors the device-preamble contract).
        let wire = (preamble ?? "") + "What's first today?"
        #expect(MessageCleaner.cleanUserMessageText(wire) == "What's first today?")
        // Preamble alone strips to empty.
        #expect(MessageCleaner.cleanUserMessageText(preamble ?? "") == "")
    }
}
}

@Suite
struct DailyBriefAgendaVisibilityTests {
    private let emptyCounts = BriefCounts(
        blocked: 0,
        overdue: 0,
        scheduledToday: 0,
        completedToday: 0,
        total: 0,
        done: 0
    )

    @Test func synthesizedAllClearStaysHiddenWithoutCanonicalDelivery() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            summary: "You're all clear — enjoy the open runway."
        )

        #expect(!brief.hasAgendaSurface)
    }

    @Test func routeHintAloneStaysHiddenWithoutCanonicalDelivery() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            briefSessionKey: "rem-orchestrator"
        )

        #expect(!brief.hasAgendaSurface)
    }

    @Test func backendAuthorizedAllClearSummaryRemainsVisibleWithZeroTaskCounts() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "You're all clear — enjoy the open runway.",
            summary: "You're all clear — enjoy the open runway.",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )

        #expect(brief.hasAgendaSurface)
    }

    @Test func backendAuthorizedMarkdownRemainsVisibleWhenCanonicalSummaryIsMissing() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "# Morning\nA connector follow-up needs your review.",
            summary: nil,
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )

        #expect(brief.hasAgendaSurface)
        #expect(brief.displayedBriefSummary == nil)
        #expect(brief.displayedBriefMarkdown ==
            "# Morning\nA connector follow-up needs your review.")
    }

    @Test func agendaCardUsesCanonicalBulletExcerptInsteadOfZeroCountFallback() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "# Morning\n- Connector follow-up",
            summary: nil,
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )

        #expect(DailyBriefAgendaPresentation.prose(for: brief) == "Connector follow-up")
        #expect(!DailyBriefAgendaPresentation.shouldShowCounts(for: brief))
        #expect(DailyBriefAgendaAccessibility.summary(for: brief) ==
            "Daily brief. Connector follow-up")
    }

    @Test func agendaCardUsesCountsOnlyWhenCanonicalProseIsAbsent() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: BriefCounts(
                blocked: 1,
                overdue: 0,
                scheduledToday: 0,
                completedToday: 0,
                total: 0,
                done: 0
            ),
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: nil,
            summary: nil,
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )

        #expect(DailyBriefAgendaPresentation.prose(for: brief) == nil)
        #expect(DailyBriefAgendaPresentation.shouldShowCounts(for: brief))
    }

    @Test func canonicalSessionWithOnlyWhitespaceContentStaysHidden() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "  \n ",
            summary: "\t",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )

        #expect(!brief.hasAgendaSurface)
    }

    @Test func deliveredCanonicalArtifactRemainsVisibleWithZeroTaskCounts() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            markdown: "Synthesized fallback must not win.",
            summary: "Synthesized fallback must not win.",
            transcriptMarkdown: "You're all clear — enjoy the open runway.",
            transcriptSummary: "You're all clear — enjoy the open runway.",
            briefSessionKey: DailyBriefTranscriptReconciler.durableSessionKey
        )

        #expect(brief.hasAgendaSurface)
    }

    @Test func transcriptWithoutCanonicalAuthorityStaysHidden() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: [],
            transcriptMarkdown: "An ordinary assistant reply.",
            transcriptSummary: "An ordinary assistant reply.",
            briefSessionKey: "rem-today-legacy"
        )

        #expect(!brief.hasAgendaSurface)
    }

    @Test func completelyEmptyLegacyPayloadStaysHidden() {
        let brief = DailyBrief(
            generatedAt: nil,
            counts: emptyCounts,
            blocked: [],
            overdue: [],
            scheduledToday: [],
            completedToday: []
        )

        #expect(!brief.hasAgendaSurface)
    }

    @Test func briefRequestAdvertisesDurableOrchestratorContinuity() {
        #expect(
            RemBriefApiService.conversationContinuityHeader == [
                "X-Rem-Conversation-Continuity": "durable-orchestrator-v1"
            ]
        )
    }
}
