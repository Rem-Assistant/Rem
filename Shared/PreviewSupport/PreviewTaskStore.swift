import Foundation

#if DEBUG
struct PreviewTaskStoreTask: TaskDisplayable, Hashable {
    let displayId: String
    let title: String
    let status: String
    let displayCategory: String?
    let startDate: Date?
    let endDate: Date?
    let isEvent: Bool
    let isCompleted: Bool
    let displayPriority: String?
    let notes: String?
    /// Structured agent run-state for previews (nil = no run). Satisfies the
    /// `TaskDisplayable.runStatus` requirement explicitly.
    var runStatus: String? = nil
    /// Backend `stale_at` (migration 116) for previews. nil = never nagged about.
    /// Satisfies the `TaskDisplayable.staleAt` requirement explicitly so a preview can
    /// exercise the stale and blocked-plus-stale rows.
    var staleAt: Date? = nil

    var id: String { displayId }

    var formattedDuration: String? {
        guard let startDate, let endDate else { return nil }
        let minutes = max(1, Int(endDate.timeIntervalSince(startDate) / 60))
        return "\(minutes)m"
    }
}

@MainActor
@Observable
final class PreviewTaskStore: TaskStoreProviding {
    typealias Task = PreviewTaskStoreTask

    enum Scenario {
        case empty
        case loading
        case scheduled
        case inbox
    }

    var isLoading: Bool
    var lastSyncDate: Date?
    var unscheduledTasks: [Task]

    private var scheduledTasksByDay: [Date: [Task]]

    init(scenario: Scenario) {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today

        switch scenario {
        case .empty:
            self.isLoading = false
            self.lastSyncDate = nil
            self.unscheduledTasks = []
            self.scheduledTasksByDay = [:]
        case .loading:
            self.isLoading = true
            self.lastSyncDate = nil
            self.unscheduledTasks = []
            self.scheduledTasksByDay = [:]
        case .scheduled:
            self.isLoading = false
            self.lastSyncDate = Date().addingTimeInterval(-180)
            self.unscheduledTasks = []
            self.scheduledTasksByDay = [
                today: [
                    Self.task(
                        id: "morning-plan",
                        title: "Plan tomorrow's rehearsal songs",
                        start: today.addingTimeInterval(9 * 60 * 60),
                        durationMinutes: 30,
                        priority: "high"
                    ),
                    Self.event(
                        id: "investor-chat",
                        title: "Coffee chat with an investor",
                        start: today.addingTimeInterval(19 * 60 * 60),
                        durationMinutes: 30
                    ),
                ],
                tomorrow: [
                    Self.task(
                        id: "ship-feedback",
                        title: "Review gateway recovery notes",
                        start: tomorrow.addingTimeInterval(14 * 60 * 60),
                        durationMinutes: 45,
                        priority: "medium"
                    ),
                ],
            ]
        case .inbox:
            self.isLoading = false
            self.lastSyncDate = Date().addingTimeInterval(-90)
            self.unscheduledTasks = [
                Self.task(id: "capture-1", title: "Send evidence map to portfolio engineer", priority: "high"),
                Self.task(id: "capture-2", title: "Try asking Rem to plan a day", priority: "medium"),
                Self.task(id: "capture-3", title: "Check App Store recovery screenshots", priority: "low"),
            ]
            self.scheduledTasksByDay = [:]
        }
    }

    func tasks(for date: Date) -> [Task] {
        scheduledTasksByDay[Calendar.current.startOfDay(for: date)] ?? []
    }

    func completeTask(_ task: Task) async {}
    func deleteTask(_ task: Task) async {}
    func snoozeTask(_ task: Task) async {}
    func refresh() async {}

    private static func task(
        id: String,
        title: String,
        start: Date? = nil,
        durationMinutes: Int? = nil,
        priority: String?
    ) -> Task {
        Task(
            displayId: id,
            title: title,
            status: "pending",
            displayCategory: "task",
            startDate: start,
            endDate: start.flatMap { start in durationMinutes.map { start.addingTimeInterval(TimeInterval($0 * 60)) } },
            isEvent: false,
            isCompleted: false,
            displayPriority: priority,
            notes: nil
        )
    }

    private static func event(
        id: String,
        title: String,
        start: Date,
        durationMinutes: Int
    ) -> Task {
        Task(
            displayId: id,
            title: title,
            status: "confirmed",
            displayCategory: "event",
            startDate: start,
            endDate: start.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            isEvent: true,
            isCompleted: false,
            displayPriority: nil,
            notes: nil
        )
    }
}
#endif
