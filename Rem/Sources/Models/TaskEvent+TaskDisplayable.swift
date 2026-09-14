import Foundation

// MARK: - TaskDisplayable conformance for iOS TaskEvent

extension TaskEvent: TaskDisplayable {
    public var displayId: String { id.uuidString }
    public var displayCategory: String? { category }
    public var displayPriority: String? { priority }
    // isCompleted, title, status, startDate, endDate, isEvent, notes, formattedDuration,
    // runStatus are already provided by TaskEvent's stored/computed properties.
}
