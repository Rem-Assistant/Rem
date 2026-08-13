import Foundation
import SwiftData

@Model
public class StoredFocusSession {
    @Attribute(.unique) public var id: UUID
    public var taskId: UUID?
    public var taskTitle: String
    public var duration: TimeInterval
    public var startTime: Date
    public var endTime: Date
    public var completedDuration: TimeInterval
    public var wasCompleted: Bool

    public init(
        id: UUID,
        taskId: UUID?,
        taskTitle: String,
        duration: TimeInterval,
        startTime: Date,
        endTime: Date,
        completedDuration: TimeInterval,
        wasCompleted: Bool
    ) {
        self.id = id
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.duration = duration
        self.startTime = startTime
        self.endTime = endTime
        self.completedDuration = completedDuration
        self.wasCompleted = wasCompleted
    }
}
