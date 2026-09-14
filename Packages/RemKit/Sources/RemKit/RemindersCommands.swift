import Foundation

public enum RemGatewayRemindersCommand: String, Codable, Sendable {
    case list = "reminders.list"
    case add = "reminders.add"
}

public enum RemReminderStatusFilter: String, Codable, Sendable {
    case incomplete
    case completed
    case all
}

public struct RemRemindersListParams: Codable, Sendable, Equatable {
    public var status: RemReminderStatusFilter?
    public var limit: Int?

    public init(status: RemReminderStatusFilter? = nil, limit: Int? = nil) {
        self.status = status
        self.limit = limit
    }
}

public struct RemRemindersAddParams: Codable, Sendable, Equatable {
    public var title: String
    public var dueISO: String?
    public var notes: String?
    public var listId: String?
    public var listName: String?

    public init(
        title: String,
        dueISO: String? = nil,
        notes: String? = nil,
        listId: String? = nil,
        listName: String? = nil)
    {
        self.title = title
        self.dueISO = dueISO
        self.notes = notes
        self.listId = listId
        self.listName = listName
    }
}

public struct RemReminderPayload: Codable, Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var dueISO: String?
    public var completed: Bool
    public var listName: String?

    public init(
        identifier: String,
        title: String,
        dueISO: String? = nil,
        completed: Bool,
        listName: String? = nil)
    {
        self.identifier = identifier
        self.title = title
        self.dueISO = dueISO
        self.completed = completed
        self.listName = listName
    }
}

public struct RemRemindersListPayload: Codable, Sendable, Equatable {
    public var reminders: [RemReminderPayload]

    public init(reminders: [RemReminderPayload]) {
        self.reminders = reminders
    }
}

public struct RemRemindersAddPayload: Codable, Sendable, Equatable {
    public var reminder: RemReminderPayload

    public init(reminder: RemReminderPayload) {
        self.reminder = reminder
    }
}
