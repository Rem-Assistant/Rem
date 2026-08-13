import Foundation
import Testing

@testable import RemClaw

/// Staleness (migration 116) is a SEPARATE COLUMN from `status`, and the whole point of this suite
/// is that it stays one: rendered *alongside* the status, never instead of it, and never at the cost
/// of the row disappearing.
///
/// The three failure modes these pin, all of which a `status = 'stale'` design would have shipped:
///   1. the task VANISHES, because `status` is a filter in five consumers;
///   2. the user's real status is DESTROYED, because `status` holds one value;
///   3. the phone silently DISAGREES, because `statusFromBackend` falls back to `.todo`.
struct TaskStalenessVisibilityTests {

    // MARK: - Both facts survive together

    @Test func blockedAndStaleReportsBoth() throws {
        let reasons = TaskDeemphasisReason.reasons(status: "blocked", staleAt: Date())

        // Neither hides the other. This is the requirement the founder called out by name.
        #expect(reasons == [.blocked, .stale])
        #expect(reasons.contains(.blocked))
        #expect(reasons.contains(.stale))
    }

    @Test func staleAloneNeverClaimsTheTaskIsBlocked() throws {
        // A pending task that went stale is still pending. Staleness must not invent a status.
        #expect(TaskDeemphasisReason.reasons(status: "pending", staleAt: Date()) == [.stale])
        #expect(TaskDeemphasisReason.reasons(status: "in_progress", staleAt: Date()) == [.stale])
    }

    @Test func blockedAloneIsNotStale() throws {
        #expect(TaskDeemphasisReason.reasons(status: "blocked", staleAt: nil) == [.blocked])
    }

    @Test func theOrdinaryTaskGetsNoTreatmentAtAll() throws {
        // The overwhelmingly common case. If this ever returns a reason, every row in the app dims.
        #expect(TaskDeemphasisReason.reasons(status: "pending", staleAt: nil).isEmpty)
        #expect(TaskDeemphasisReason.reasons(status: nil, staleAt: nil).isEmpty)
    }

    @Test func blockedIsMatchedExactlyNotBySubstring() throws {
        // `status.contains("block")` — the shape used elsewhere in the app — also matches
        // "unblocked", which means the opposite. A machine decision made by substring is the wrong
        // layer (principle 5), so the resolver compares whole values.
        #expect(TaskDeemphasisReason.reasons(status: "unblocked", staleAt: nil).isEmpty)
        #expect(TaskDeemphasisReason.reasons(status: "blocking", staleAt: nil).isEmpty)
        // …but the real value still matches whatever case the backend sends it in.
        #expect(TaskDeemphasisReason.reasons(status: "BLOCKED", staleAt: nil) == [.blocked])
    }

    // MARK: - Same treatment, different word

    @Test func theTwoReasonsShareTreatmentButNotTheirLabel() throws {
        // The founder considered reusing `blocked` for both and rejected it: same visual
        // de-emphasis, distinct word. A refactor that collapsed the labels would erase the
        // decision, so it is asserted rather than left to a comment.
        #expect(TaskDeemphasisReason.blocked.label != TaskDeemphasisReason.stale.label)
        #expect(TaskDeemphasisReason.stale.label == "Stale")
        #expect(TaskDeemphasisReason.blocked.label == "Blocked")

        // Every reason must actually say something in each slot — an empty pill is invisible,
        // which is the bug being fixed.
        for reason in TaskDeemphasisReason.allCases {
            #expect(!reason.label.isEmpty)
            #expect(!reason.detail.isEmpty)
            #expect(!reason.systemImage.isEmpty)
            // The screen-reader string must carry more than the bare word: "Stale" on its own does
            // not tell anyone that Rem stopped raising the task.
            #expect(reason.accessibilityLabel.count > reason.label.count)
        }
    }

    // MARK: - The field actually arrives from the backend

    @Test func staleAtIsDecodedFromTheWire() throws {
        // The exact payload `formatTask` emits for a stale task (backend tasks.routes.ts).
        let json = """
        {
          "id": "33333333-3333-4333-8333-333333333331",
          "title": "Renew the domain",
          "status": "pending",
          "stale_at": "2026-07-02T15:00:00.000Z",
          "created_at": "2026-06-01T09:00:00.000Z"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TaskEventApiResponse.self, from: json)

        #expect(decoded.staleAt == "2026-07-02T15:00:00.000Z")
        // …and the status came through untouched next to it.
        #expect(decoded.status == "pending")
    }

    @Test func absentOrNullStaleAtMeansNotStale() throws {
        // `null` is what the backend sends for every task the user has touched, and an ABSENT key
        // is what an older backend sends. Both must decode, and both mean "not stale" — a decode
        // failure here would take down the whole task list over a field about de-emphasis.
        let explicitNull = """
        { "id": "a", "title": "t", "status": "pending", "stale_at": null }
        """.data(using: .utf8)!
        let absent = """
        { "id": "a", "title": "t", "status": "pending" }
        """.data(using: .utf8)!

        #expect(try JSONDecoder().decode(TaskEventApiResponse.self, from: explicitNull).staleAt == nil)
        #expect(try JSONDecoder().decode(TaskEventApiResponse.self, from: absent).staleAt == nil)
    }

    @Test func staleAtSurvivesTheRoundTripBackToTheApiShape() throws {
        let task = TaskEvent(title: "Renew the domain")
        task.staleAt = Date(timeIntervalSince1970: 1_782_054_000)

        #expect(task.toApiResponse().staleAt != nil)
    }

    // MARK: - Stale never overwrites, and never hides, the real task

    @Test func staleDoesNotOverwriteTheStatusTheUserSet() throws {
        let task = TaskEvent(title: "Send the signed contract back", status: .blocked)
        task.staleAt = Date()

        // The status column is untouched: the phone still reports exactly what the user (or the
        // agent run) set. This is failure mode 2 — a `'stale'` status would have destroyed it.
        #expect(task.statusEnum == .blocked)
        #expect(task.status == "blocked")
        // …and staleness is reported in its own right, from its own field.
        #expect(task.isStale)
        #expect(task.deemphasisReasons == [.blocked, .stale])
    }

    @Test func aStalePendingTaskStillReadsAsPendingNotAsSomethingUnknown() throws {
        // Failure mode 3: an unrecognised status decodes to `.todo` via `statusFromBackend`'s
        // fallback, so a stale task would have rendered as an ordinary to-do while the backend
        // believed the phone had been told. Here the status is genuinely `pending` AND the phone
        // separately knows it is stale.
        let task = TaskEvent(title: "Renew the domain", status: .todo)
        task.staleAt = Date()

        #expect(task.statusEnum == .todo)
        #expect(task.isStale)
        #expect(task.deemphasisReasons == [.stale])
    }

    @Test func aStaleTaskIsStillRoutedIntoTheUserSLists() throws {
        // Failure mode 1, client side: "stop nagging" must never mean "vanish from the app".
        // These are the predicates that decide which surface a task appears on; neither consults
        // staleness, and this pins that they never start to.
        let unscheduled = TaskEvent(title: "Renew the domain")
        unscheduled.staleAt = Date()
        #expect(unscheduled.shouldAppearInInbox)
        #expect(!unscheduled.shouldAppearInAgenda)

        let today = Date()
        let scheduled = TaskEvent(title: "Book the dentist", startDate: today)
        scheduled.staleAt = Date()
        #expect(scheduled.shouldAppearInAgenda)
        #expect(scheduled.shouldAppear(on: today))

        // And a stale task is never treated as finished — staleness is a pause on asking, not a
        // silent completion.
        #expect(!unscheduled.isCompleted)
        #expect(!scheduled.isCompleted)
    }

    // MARK: - The dimming is applied once

    @Test func twoReasonsStillProduceASingleDimming() throws {
        let task = TaskEvent(title: "Send the signed contract back", status: .blocked)
        task.staleAt = Date()

        // Two badges, ONE de-emphasis. Views branch on `isDeemphasized`, not on the reason count:
        // two stacked `.opacity(0.55)` modifiers multiply to 0.30, so a blocked-and-stale row would
        // fade twice as far as either alone and read as an error rather than as quiet.
        #expect(task.deemphasisReasons.count == 2)
        #expect(task.isDeemphasized)

        let onlyStale = TaskEvent(title: "Renew the domain")
        onlyStale.staleAt = Date()
        #expect(onlyStale.isDeemphasized == task.isDeemphasized)
    }

    @Test func aTaskWithNoStalenessFieldIsNotDeemphasized() throws {
        // The protocol default (`staleAt: nil`) covers previews and fixtures. It must read as
        // "never nagged about", not as stale.
        let ordinary = TaskEvent(title: "Renew the domain")
        #expect(!ordinary.isStale)
        #expect(!ordinary.isDeemphasized)
        #expect(ordinary.deemphasisReasons.isEmpty)
    }

    // MARK: - The brief surface resolves staleness the same way

    @Test func theBriefResolvesStalenessThroughTheSameRule() throws {
        // `gatherBrief` keeps a stale item in its bucket flagged `is_stale` rather than hiding it,
        // and sends a boolean where the task routes send a timestamp. Both must land on the same
        // treatment, or the brief and the agenda disagree about what stale looks like.
        let json = """
        {
          "id": "33333333-3333-4333-8333-333333333331",
          "title": "Renew the domain",
          "status": "blocked",
          "type": "task",
          "bucket": "overdue",
          "is_stale": true
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(BriefItem.self, from: json)

        #expect(item.isStale == true)
        #expect(item.deemphasisReasons == [.blocked, .stale])
    }

    @Test func aBriefItemWithoutTheFlagDecodesAsNotStale() throws {
        let json = """
        { "id": "a", "title": "t", "status": "pending", "type": "task", "bucket": "overdue" }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(BriefItem.self, from: json)

        #expect(item.isStale == nil)
        #expect(item.deemphasisReasons.isEmpty)
    }
}
