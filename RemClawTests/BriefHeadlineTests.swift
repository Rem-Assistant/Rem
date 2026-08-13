import Foundation
import Testing
@testable import RemClaw

/// One headline, used everywhere.
///
/// The founder's report: the Agenda summary said "Good morning" while the orchestrator chat said
/// "The Day" — two titles for one brief, because the card synthesized its header from the clock
/// and the chat showed the brief's own first heading. The fix is a real field on the artifact
/// (`daily_brief_artifacts.headline`, backend migration 119) that BOTH surfaces render.
///
/// These tests assert the two surfaces on the SAME decoded payload, so a regression in either
/// derivation shows up as the two strings disagreeing — which is the actual bug, not a proxy
/// for it.
///
/// `.serialized` + an isolated `UserDefaults` suite for the same reason `BriefContextTests` uses
/// one: the chat title reads a `BriefContext` key that the Agenda hand-off writes.
/// Nested under `BriefDefaultsSuites` so it cannot run concurrently with the other suite
/// that re-points the process-global `BriefContext.defaults`.
extension BriefDefaultsSuites {
@Suite(.serialized)
final class BriefHeadlineTests {

    private static let suiteName = "BriefHeadlineTests.isolated"

    /// Two backend JWT subjects. The founder's device is shared between an Apple and a Google
    /// account, which is exactly how account A's headline reached account B's chat.
    private let accountA = "auth0|apple-subject-A"
    private let accountB = "auth0|google-subject-B"
    private let store: UserDefaults

    init() {
        UserDefaults().removePersistentDomain(forName: Self.suiteName)
        store = UserDefaults(suiteName: Self.suiteName)!
        BriefContext.defaults = store
    }

    deinit {
        store.removePersistentDomain(forName: Self.suiteName)
        BriefContext.defaults = .standard
    }

    /// Local wall-clock instants, built through `Calendar.current` so the assertions hold in any
    /// machine timezone (the production code buckets the fallback title with the local hour).
    private func localTime(day: Int = 11, hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        components.hour = hour
        components.minute = 0
        return Calendar.current.date(from: components)!
    }

    /// A `GET /api/v1/brief` body shaped exactly like the delivered response, so the test exercises
    /// decoding too — a wrong `CodingKey` would silently drop the headline in production.
    private func decodeBrief(headlineJSON: String) throws -> DailyBrief {
        let json = """
        {
          "generated_at": "2026-08-11T15:00:38.000Z",
          "counts": {"blocked": 1, "overdue": 3, "scheduled_today": 0, "completed_today": 0, "total": 0, "done": 0},
          "blocked": [], "overdue": [], "scheduled_today": [], "completed_today": [],
          "markdown": "## The Day\\n\\nNo completed tasks recorded and nothing on deck yet.",
          "summary": "No completed tasks recorded and nothing on deck yet.",
          \(headlineJSON)
          "brief_session_key": "rem-orchestrator"
        }
        """
        return try JSONDecoder().decode(DailyBrief.self, from: Data(json.utf8))
    }

    // MARK: - The acceptance: one string, both surfaces

    @Test func agendaSummaryAndOrchestratorChatRenderTheSameAuthoredHeadline() throws {
        // 09:00 local — the hour that used to force "Good morning" onto the card.
        let morning = localTime(hour: 9)
        let brief = try decodeBrief(headlineJSON: "\"headline\": \"The Day\",")

        // This is the hand-off AgendaViewModel performs on every `brief` assignment.
        BriefContext.setOrchestratorHeadline(brief.briefHeadline, accountID: accountA, now: morning)

        let agendaTitle = DailyBriefAgendaPresentation.title(for: brief, now: morning)
        let chatTitle = BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning)

        #expect(agendaTitle == "The Day")
        #expect(chatTitle == "The Day")
        #expect(agendaTitle == chatTitle)
        // And it is genuinely the artifact's field, not a coincidence of the clock.
        #expect(agendaTitle != DailyBriefAgendaPresentation.timeOfDayTitle(now: morning))
    }

    @Test func theGatewayCanonicalSessionKeyFormResolvesToTheSameTitle() throws {
        let morning = localTime(hour: 9)
        let brief = try decodeBrief(headlineJSON: "\"headline\": \"The Day\",")
        BriefContext.setOrchestratorHeadline(brief.briefHeadline, accountID: accountA, now: morning)

        #expect(BriefContext.displayTitle(for: "agent:main:rem-orchestrator", accountID: accountA, now: morning) == "The Day")
    }

    // MARK: - Fallback: never worse than before the headline existed

    @Test func aBriefWithoutAHeadlineKeepsEachSurfacesPriorTitle() throws {
        let morning = localTime(hour: 9)
        let brief = try decodeBrief(headlineJSON: "")
        BriefContext.setOrchestratorHeadline(brief.briefHeadline, accountID: accountA, now: morning)

        #expect(brief.briefHeadline == nil)
        #expect(DailyBriefAgendaPresentation.title(for: brief, now: morning) == "Good morning")
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "Rem")
    }

    @Test func aWhitespaceOnlyHeadlineIsTreatedAsAbsent() throws {
        let morning = localTime(hour: 9)
        let brief = try decodeBrief(headlineJSON: "\"headline\": \"   \",")
        BriefContext.setOrchestratorHeadline(brief.briefHeadline, accountID: accountA, now: morning)

        #expect(brief.briefHeadline == nil)
        #expect(DailyBriefAgendaPresentation.title(for: brief, now: morning) == "Good morning")
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "Rem")
    }

    @Test func theTimeOfDayFallbackStillTracksTheClock() {
        #expect(DailyBriefAgendaPresentation.timeOfDayTitle(now: localTime(hour: 9)) == "Good morning")
        #expect(DailyBriefAgendaPresentation.timeOfDayTitle(now: localTime(hour: 14)) == "Your afternoon")
        #expect(DailyBriefAgendaPresentation.timeOfDayTitle(now: localTime(hour: 20)) == "Evening recap")
    }

    // MARK: - Staleness

    @Test func yesterdaysHeadlineDoesNotTitleTodaysChat() throws {
        let yesterdayMorning = localTime(day: 10, hour: 9)
        let brief = try decodeBrief(headlineJSON: "\"headline\": \"The Day\",")
        BriefContext.setOrchestratorHeadline(brief.briefHeadline, accountID: accountA, now: yesterdayMorning)

        let today = localTime(day: 11, hour: 9)
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: today) == "Rem")
    }

    @Test func clearingTheHeadlineRestoresThePlainChatTitle() throws {
        let morning = localTime(hour: 9)
        BriefContext.setOrchestratorHeadline("The Day", accountID: accountA, now: morning)
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "The Day")

        BriefContext.setOrchestratorHeadline(nil, accountID: accountA, now: morning)
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "Rem")
    }

    // MARK: - The headline must not leak onto unrelated sessions

    @Test func aLegacyPerDayBriefSessionKeepsItsDateTitle() throws {
        let morning = localTime(hour: 9)
        BriefContext.setOrchestratorHeadline("The Day", accountID: accountA, now: morning)

        let legacy = BriefContext.displayTitle(for: "rem-today-20260811", accountID: accountA, now: morning)
        #expect(legacy != "The Day")
        #expect(legacy?.contains("with Rem") == true)
    }

    @Test func anOrdinaryChatSessionIsUnaffected() {
        let morning = localTime(hour: 9)
        BriefContext.setOrchestratorHeadline("The Day", accountID: accountA, now: morning)
        #expect(BriefContext.displayTitle(for: "chat-general", accountID: accountA, now: morning) == nil)
    }

    // MARK: - Account scoping: one person's brief must never title another's chat

    @Test func anotherAccountsHeadlineNeverTitlesThisAccountsChat() throws {
        let morning = localTime(hour: 9)
        let brief = try decodeBrief(headlineJSON: "\"headline\": \"Dinner with Priya at Acme\",")

        // Account A loads its brief and publishes the headline.
        BriefContext.setOrchestratorHeadline(brief.briefHeadline, accountID: accountA, now: morning)
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning)
                == "Dinner with Priya at Acme")

        // Account B opens the same chat on the same device BEFORE its own brief loads.
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountB, now: morning) == "Rem")
    }

    @Test func aSignedOutReaderGetsThePlainTitle() throws {
        let morning = localTime(hour: 9)
        let brief = try decodeBrief(headlineJSON: "\"headline\": \"The Day\",")
        BriefContext.setOrchestratorHeadline(brief.briefHeadline, accountID: accountA, now: morning)

        // No account to prove ownership with -> fail closed, never leak.
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: nil, now: morning) == "Rem")
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: "  ", now: morning) == "Rem")
    }

    @Test func aHeadlineCannotBePublishedWithoutAnAccount() throws {
        let morning = localTime(hour: 9)
        BriefContext.setOrchestratorHeadline("The Day", accountID: nil, now: morning)
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "Rem")
    }

    @Test func signOutDropsThePublishedHeadline() throws {
        let morning = localTime(hour: 9)
        BriefContext.setOrchestratorHeadline("The Day", accountID: accountA, now: morning)
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "The Day")

        BriefContext.clearOrchestratorHeadline()

        // Even the SAME account signing back in must not see the prior session's prose from disk.
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "Rem")
    }

    @Test func theAccountStampIsCaseAndWhitespaceInsensitive() throws {
        let morning = localTime(hour: 9)
        BriefContext.setOrchestratorHeadline("The Day", accountID: " Auth0|Apple-Subject-A ", now: morning)
        #expect(BriefContext.displayTitle(for: "rem-orchestrator", accountID: accountA, now: morning) == "The Day")
    }

    // MARK: - The transcript layer must not drop the headline

    @Test func adoptingDurableTranscriptProseKeepsTheAuthoredHeadline() throws {
        let brief = try decodeBrief(headlineJSON: "\"headline\": \"The Day\",")
        let withTranscript = brief.replacingTranscriptProse(
            markdown: "## The Day\n\nFour items need you today.",
            summary: "Four items need you today."
        )
        #expect(withTranscript.briefHeadline == "The Day")
    }
}
}
