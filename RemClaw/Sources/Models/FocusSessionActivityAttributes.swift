import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

// MARK: - Active Focus Session

struct FocusTimerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var timeRemaining: TimeInterval
        var progress: Double // 0.0 to 1.0
        var status: FocusStatus

        init(
            timeRemaining: TimeInterval,
            progress: Double,
            status: FocusStatus
        ) {
            self.timeRemaining = timeRemaining
            self.progress = progress
            self.status = status
        }

        enum FocusStatus: String, Codable, Hashable {
            case warmingUp = "warming_up"
            case running
            case paused
            case completed
        }
    }

    let sessionId: String
    let taskTitle: String
    let duration: TimeInterval

    init(
        sessionId: String,
        taskTitle: String,
        duration: TimeInterval
    ) {
        self.sessionId = sessionId
        self.taskTitle = taskTitle
        self.duration = duration
    }
}

// MARK: - Upcoming Focus Session (Pre-Session)

struct FocusPreSessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var timeUntilStart: TimeInterval
        var canStart: Bool

        init(
            timeUntilStart: TimeInterval,
            canStart: Bool = true
        ) {
            self.timeUntilStart = timeUntilStart
            self.canStart = canStart
        }
    }

    let taskId: String
    let taskTitle: String
    let scheduledStartDate: Date
    let duration: TimeInterval?

    init(
        taskId: String,
        taskTitle: String,
        scheduledStartDate: Date,
        duration: TimeInterval? = nil
    ) {
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.scheduledStartDate = scheduledStartDate
        self.duration = duration
    }
}

#endif
