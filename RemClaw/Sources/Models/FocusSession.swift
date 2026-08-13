import Foundation

public enum FocusSessionStatus: String, Codable {
    case warmingUp
    case running
    case paused
    case completed
    case cancelled
}

public struct FocusSession: Identifiable, Codable, Equatable {
    public let id: UUID
    public var taskId: UUID?
    public var taskTitle: String
    public var duration: TimeInterval
    public var warmUpDuration: TimeInterval?
    public var startTime: Date
    public var endTime: Date?
    public var status: FocusSessionStatus
    public var pausedAt: Date?
    public var totalPausedDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        taskId: UUID? = nil,
        taskTitle: String,
        duration: TimeInterval,
        warmUpDuration: TimeInterval? = nil,
        startTime: Date = Date(),
        endTime: Date? = nil,
        status: FocusSessionStatus = .running,
        pausedAt: Date? = nil,
        totalPausedDuration: TimeInterval = 0
    ) {
        self.id = id
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.duration = duration
        self.warmUpDuration = warmUpDuration
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.pausedAt = pausedAt
        self.totalPausedDuration = totalPausedDuration
    }
}
