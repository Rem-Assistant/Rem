import Foundation
import SwiftData

@Model
public final class PendingTaskOperation {
    @Attribute(.unique) public var id: UUID
    public var operationType: String
    public var taskId: UUID?
    public var taskData: Data?
    public var createdAt: Date
    public var retryCount: Int
    public var lastError: String?

    public init(
        operationType: String,
        taskId: UUID?,
        taskData: Data?
    ) {
        self.id = UUID()
        self.operationType = operationType
        self.taskId = taskId
        self.taskData = taskData
        self.createdAt = Date()
        self.retryCount = 0
        self.lastError = nil
    }
}
