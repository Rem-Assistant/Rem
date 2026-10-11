import Foundation
import RemDesignSystem
import Testing
@testable import Rem

/// Covers the design-system Inbox, task chat header and Agent activity mapping
/// (`Rem/Sources/DesignSystemAdapter/TaskDisplayMapper.swift`): run state is only what the backend
/// reported, Inbox taps route only to listed tasks, and history never speaks for the current state.
@MainActor
struct TaskDisplayMapperTests {
    // MARK: Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-11 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_720_000)

    private func record(
        _ title: String,
        id: UUID = UUID(),
        isCompleted: Bool = false,
        runStatus: String? = nil,
        runStartedAt: Date? = nil
    ) -> DesignSystemTaskRecord {
        DesignSystemTaskRecord(
            id: id,
            title: title,
            isCompleted: isCompleted,
            runStatus: runStatus,
            runStartedAt: runStartedAt
        )
    }

    private func activity(
        _ records: [DesignSystemTaskRecord],
        header: RemDesignSystem.ChatHeaderDisplay = RemDesignSystem.ChatHeaderDisplay(activity: "Connected")
    ) -> RemDesignSystem.AgentActivityDisplay {
        TaskDisplayMapper.agentActivity(
            header: header,
            records: records,
            now: now,
            calendar: calendar,
            formatTime: { _ in "3:42 PM" },
            formatDay: { _ in "Oct 8" }
        )
    }

    // MARK: Run state

    @Test func runStateIsOnlyWhatTheBackendReported() {
        func state(_ runStatus: String?, completed: Bool = false) -> RemDesignSystem.InboxItemState {
            TaskDisplayMapper.inboxState(isCompleted: completed, runStatus: runStatus)
        }
        #expect(state(nil) == RemDesignSystem.InboxItemState.none)
        #expect(state("") == RemDesignSystem.InboxItemState.none)
        #expect(state("idle") == RemDesignSystem.InboxItemState.none)
        #expect(state("running") == .executing)
        #expect(state("review") == .blocked)
        #expect(state("blocked") == .blocked)
        #expect(state("done") == .completed)
        // A value this client does not know is reported as unknown, never guessed.
        #expect(state("paused") == .unknown)
        // A completed task is done whatever its last run reported.
        #expect(state("blocked", completed: true) == .completed)
        // The app has no approval evidence: review never claims one.
        for raw in TaskRunStatus.allCases.map(\.rawValue) {
            #expect(state(raw) != .needsApproval)
        }
    }

    // MARK: Inbox

    @Test func inboxItemsKeepOrderIdsAndReportedState() {
        let first = record("Follow up with Alex", runStatus: "running")
        let second = record("   ", isCompleted: true)
        let items = TaskDisplayMapper.inboxItems([first, second])

        #expect(items.map(\.id) == [first.id.uuidString, second.id.uuidString])
        #expect(items[0].title == "Follow up with Alex")
        #expect(items[0].state == .executing)
        #expect(items[1].title == TaskDisplayMapper.untitledTask)
        #expect(items[1].state == .completed)
    }

    @Test func inboxTapRoutesOnlyToAListedTask() {
        let listed = record("Book the venue")
        let records = [listed]
        #expect(TaskDisplayMapper.taskID(forInboxItemID: listed.id.uuidString, in: records) == listed.id)
        #expect(TaskDisplayMapper.taskID(forInboxItemID: UUID().uuidString, in: records) == nil)
        #expect(TaskDisplayMapper.taskID(forInboxItemID: "not-a-task", in: records) == nil)
    }

    // MARK: Task chat

    @Test func taskChatFindsItsTaskFromTheSessionTaskID() throws {
        let task = record("Draft the update", runStatus: "blocked")
        let sessionKey = TaskChatSessionIdentity.canonicalSessionKey(
            taskId: task.id.uuidString, persistedSessionKey: nil)
        let taskID = try #require(TaskChatSessionIdentity.taskId(from: sessionKey))
        #expect(TaskDisplayMapper.record(forTaskID: taskID, in: [task]) == task)
        #expect(TaskDisplayMapper.record(forTaskID: UUID().uuidString.lowercased(), in: [task]) == nil)
    }

    @Test func taskChatHeaderShowsTheTaskStateUntilATurnIsInFlight() {
        let blocked = TaskDisplayMapper.taskChatHeader(state: .blocked, pendingRunCount: 0, voiceAvailable: true)
        #expect(blocked.activity == "Needs you")
        #expect(blocked.status == .needsYou)
        #expect(!blocked.isWorking)
        #expect(blocked.showsCall)
        #expect(blocked.showsBack)
        #expect(!blocked.showsOverflow)
        #expect(blocked.showsActivityDetails)

        let running = TaskDisplayMapper.taskChatHeader(state: .executing, pendingRunCount: 0, voiceAvailable: false)
        #expect(running.activity == "Working")
        #expect(running.isWorking)
        #expect(!running.showsCall)

        let sending = TaskDisplayMapper.taskChatHeader(state: .blocked, pendingRunCount: 1, voiceAvailable: false)
        #expect(sending.activity == "Working")
        #expect(sending.status == .connected)
        #expect(sending.isWorking)

        let unloaded = TaskDisplayMapper.taskChatHeader(state: nil, pendingRunCount: 0, voiceAvailable: false)
        #expect(unloaded.activity == "Connected")
        #expect(unloaded.status == .connected)
        #expect(!unloaded.isWorking)
    }

    // MARK: Agent activity

    @Test func agentActivityCurrentStateIsTheHeaders() {
        let header = RemDesignSystem.ChatHeaderDisplay(activity: "Working", status: .connected, isWorking: true)
        let display = activity(
            [record("Old run", runStatus: "done", runStartedAt: now.addingTimeInterval(-600))],
            header: header
        )
        #expect(display.current == RemDesignSystem.AgentActivityCurrent(header))
    }

    @Test func agentActivityListsFinishedRunsNewestFirstByDay() {
        let todayLate = record("Plan the day", runStatus: "done", runStartedAt: now.addingTimeInterval(-60))
        let todayEarly = record("Review open tasks", runStatus: "review", runStartedAt: now.addingTimeInterval(-3_600))
        let yesterday = record("Book travel", runStatus: "blocked", runStartedAt: now.addingTimeInterval(-86_400))
        let older = record("Sync holds", runStatus: "done", runStartedAt: now.addingTimeInterval(-3 * 86_400))
        let display = activity([older, todayEarly, yesterday, todayLate])

        #expect(display.days.map(\.title) == ["Today", "Yesterday", "Oct 8"])
        #expect(display.days[0].events.map(\.id) == [todayLate.id.uuidString, todayEarly.id.uuidString])
        #expect(display.days[0].events[0].title == "Plan the day")
        #expect(display.days[0].events[0].outcome == "Done")
        #expect(display.days[0].events[1].outcome == "Needs review")
        #expect(display.days[1].events[0].outcome == "Needs attention")
        // Only the start of a run is recorded: the time says so.
        #expect(display.days[0].events[0].summary == "Done · Started 3:42 PM")
    }

    @Test func agentActivityLeavesOutRunsThatAreNotFinishedOrHaveNoStart() {
        let display = activity([
            record("Running", runStatus: "running", runStartedAt: now),
            record("Idle", runStatus: "idle", runStartedAt: now),
            record("Never run"),
            record("Unknown", runStatus: "paused", runStartedAt: now),
            record("No start", runStatus: "done"),
        ])
        #expect(display.days.isEmpty)
        #expect(display.visibleDays.isEmpty)
    }
}
