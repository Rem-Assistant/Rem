import Foundation

// MARK: - TaskDisplayable conformance for Mac MacTask

extension MacTask: TaskDisplayable {
    var displayId: String { id }
    var displayCategory: String? { category }
    var displayPriority: String? { priority }
    // `runStatus` is provided directly by MacTask's stored property.

    var formattedDuration: String? {
        guard let start = startDate, let end = endDate else { return nil }
        let interval = end.timeIntervalSince(start)
        guard interval > 0 else { return nil }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
