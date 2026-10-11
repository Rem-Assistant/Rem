import Foundation
import RemDesignSystem

/// A task as the design-system surfaces read it: plain values copied from the app's `TaskEvent`
/// (`TaskStore.allTasks`), so the mappers stay pure and testable without SwiftData.
/// `nonisolated` (the app module defaults to `@MainActor`) so `Equatable` is usable anywhere.
nonisolated struct DesignSystemTaskRecord: Equatable {
    var id: UUID
    var title: String
    /// The human-facing task state is completed (`TaskEvent.isCompleted`).
    var isCompleted: Bool
    /// Backend `tasks.run_status`, verbatim (`TaskEvent.runStatus`).
    var runStatus: String?
    /// When the current or last agent run started (`TaskEvent.runStartedAt`).
    var runStartedAt: Date?
}

/// Pure functions from the app's tasks to the design system's Inbox, task chat header and Agent
/// activity values. No effects, no fetching: everything comes from the tasks the app already holds.
///
/// Truth rules:
/// - Run state is what the backend reported (`TaskRunStatus`); nothing is inferred. A value this
///   client does not recognize is `.unknown` ("Status unknown"), never a guess.
/// - Agent activity history is the finished agent runs on loaded tasks. The app records only when a
///   run **started**, so the row time says "Started …"; no finish time is invented.
enum TaskDisplayMapper {
    static let untitledTask = "Untitled task"

    /// Copies the fields the design-system surfaces read.
    static func record(_ task: TaskEvent) -> DesignSystemTaskRecord {
        DesignSystemTaskRecord(
            id: task.id,
            title: task.title,
            isCompleted: task.isCompleted,
            runStatus: task.runStatus,
            runStartedAt: task.runStartedAt
        )
    }

    // MARK: Run state

    /// The host-reported state for the Inbox row and the task chat header.
    ///
    /// | App | Design system |
    /// |---|---|
    /// | task completed | `.completed` (Done) |
    /// | no run status, `idle` | `.none` (no status) |
    /// | `running` | `.executing` (Working) |
    /// | `review`, `blocked` | `.blocked` (Needs you): the run left something for the person |
    /// | `done` | `.completed` (Done) |
    /// | unrecognized value | `.unknown` (Status unknown) |
    ///
    /// `review` is not `.needsApproval`: the app has no approval for it, only a comment to review.
    static func inboxState(isCompleted: Bool, runStatus: String?) -> RemDesignSystem.InboxItemState {
        if isCompleted { return .completed }
        guard let runStatus, !runStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }
        guard let resolved = TaskRunStatus(rawValue: runStatus) else { return .unknown }
        switch resolved {
        case .idle: return .none
        case .running: return .executing
        case .review, .blocked: return .blocked
        case .done: return .completed
        }
    }

    static func inboxState(_ record: DesignSystemTaskRecord) -> RemDesignSystem.InboxItemState {
        inboxState(isCompleted: record.isCompleted, runStatus: record.runStatus)
    }

    // MARK: Inbox

    /// The Inbox rows, in the app's order. The item id is the task's UUID string, which
    /// `taskID(forInboxItemID:in:)` maps back for routing.
    static func inboxItems(_ records: [DesignSystemTaskRecord]) -> [RemDesignSystem.InboxItemDisplay] {
        records.map { record in
            let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return RemDesignSystem.InboxItemDisplay(
                id: record.id.uuidString,
                title: title.isEmpty ? untitledTask : record.title,
                state: inboxState(record)
            )
        }
    }

    /// The task an Inbox row opens: only a task that is actually listed.
    static func taskID(forInboxItemID itemID: String, in records: [DesignSystemTaskRecord]) -> UUID? {
        records.first { $0.id.uuidString == itemID }?.id
    }

    // MARK: Task chat

    /// The task a task chat belongs to, if it is loaded. `taskID` is the lowercased UUID string
    /// `TaskChatSessionIdentity.taskId(from:)` returns.
    static func record(forTaskID taskID: String, in records: [DesignSystemTaskRecord]) -> DesignSystemTaskRecord? {
        let needle = taskID.lowercased()
        return records.first { $0.id.uuidString.lowercased() == needle }
    }

    /// Header for a task chat. A turn in flight is `Working`; otherwise the task's reported run state
    /// (`InboxItemState.header`, the same truth the Inbox row shows); with no state, `Connected` (the
    /// task conversation is runtime-owned, so gateway state does not apply). The capsule opens Agent
    /// activity; there is no overflow route.
    static func taskChatHeader(
        state: RemDesignSystem.InboxItemState?,
        pendingRunCount: Int,
        voiceAvailable: Bool
    ) -> RemDesignSystem.ChatHeaderDisplay {
        var header: RemDesignSystem.ChatHeaderDisplay
        if pendingRunCount > 0 {
            header = RemDesignSystem.ChatHeaderDisplay(activity: "Working", status: .connected, isWorking: true)
        } else {
            let reported: RemDesignSystem.InboxItemState = state ?? RemDesignSystem.InboxItemState.none
            header = reported.header(name: "Rem")
        }
        header.showsBack = true
        header.showsOverflow = false
        header.showsActivityDetails = true
        header.showsCall = voiceAvailable
        return header
    }

    // MARK: Agent activity

    private struct FinishedRun {
        let record: DesignSystemTaskRecord
        let status: TaskRunStatus
        let started: Date
    }

    /// Short local time, e.g. "3:42 PM".
    static func defaultTimeFormatter(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Day label for days before yesterday, e.g. "Oct 9".
    static func defaultDayFormatter(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The Agent activity screen: the current state is the chat header's (never derived from
    /// history); the timeline is the finished runs (`review`, `blocked`, `done`) on loaded tasks with a
    /// start time, newest first, grouped by the day the run started. Running and idle tasks are not
    /// history. No finished runs → no days, and the design system shows its empty state.
    static func agentActivity(
        header: RemDesignSystem.ChatHeaderDisplay,
        records: [DesignSystemTaskRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        formatTime: (Date) -> String = TaskDisplayMapper.defaultTimeFormatter,
        formatDay: (Date) -> String = TaskDisplayMapper.defaultDayFormatter
    ) -> RemDesignSystem.AgentActivityDisplay {
        var finished: [FinishedRun] = []
        for record in records {
            guard let raw = record.runStatus,
                  let status = TaskRunStatus(rawValue: raw),
                  status == .review || status == .blocked || status == .done,
                  let started = record.runStartedAt
            else { continue }
            finished.append(FinishedRun(record: record, status: status, started: started))
        }
        finished.sort { $0.started > $1.started }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)

        var days: [RemDesignSystem.AgentActivityDay] = []
        for item in finished {
            let day = calendar.startOfDay(for: item.started)
            let title: String
            if day == today {
                title = "Today"
            } else if day == yesterday {
                title = "Yesterday"
            } else {
                title = formatDay(item.started)
            }
            let trimmedTitle = item.record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let event = RemDesignSystem.AgentActivityEvent(
                id: item.record.id.uuidString,
                title: trimmedTitle.isEmpty ? untitledTask : item.record.title,
                outcome: item.status.displayName,
                time: "Started \(formatTime(item.started))"
            )
            let dayID = "day.\(Int(day.timeIntervalSince1970))"
            if let last = days.indices.last, days[last].id == dayID {
                days[last].events.append(event)
            } else {
                days.append(RemDesignSystem.AgentActivityDay(id: dayID, title: title, events: [event]))
            }
        }

        return RemDesignSystem.AgentActivityDisplay(
            current: RemDesignSystem.AgentActivityCurrent(header),
            days: days
        )
    }
}
