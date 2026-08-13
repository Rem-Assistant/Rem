import Foundation

/// Payload for createTask RPC from the Python agent
struct CreateTaskRpcPayload: Codable {
    let type: DraftType
    let data: DraftData
}

/// Generic RPC response
struct RpcResponse: Codable {
    let status: String
    let error: String?
}

/// Payload for listEvents RPC (optional time range + query)
struct ListEventsRpcPayload: Codable {
    let timeMin: String?
    let timeMax: String?
    let query: String?

    enum CodingKeys: String, CodingKey {
        case timeMin = "time_min"
        case timeMax = "time_max"
        case query
    }
}

/// Payload for getTask/getEvent RPC
struct GetTaskRpcPayload: Codable {
    let id: String
}

/// Payload for findTask/findEvent RPC
struct FindTaskRpcPayload: Codable {
    let title: String?
    let startDate: String?
    let type: String?
    let returnAll: Bool?

    enum CodingKeys: String, CodingKey {
        case title
        case startDate = "start_date"
        case type
        case returnAll = "return_all"
    }
}

/// Response for listTasks/listEvents RPC
struct ListTasksRpcResponse: Codable {
    let status: String
    let data: [TaskEventApiResponse]?
    let error: String?
    let deviceTimezone: String?

    init(status: String, data: [TaskEventApiResponse]?, error: String?, deviceTimezone: String? = nil) {
        self.status = status
        self.data = data
        self.error = error
        self.deviceTimezone = deviceTimezone
    }

    enum CodingKeys: String, CodingKey {
        case status
        case data
        case error
        case deviceTimezone = "device_timezone"
    }
}

/// Response for getTask/getEvent RPC
struct GetTaskRpcResponse: Codable {
    let status: String
    let data: TaskEventApiResponse?
    let error: String?
}

/// Response for findEvent with return_all
struct FindEventsRpcResponse: Codable {
    let status: String
    let data: [TaskEventApiResponse]?
    let count: Int?
    let error: String?
}

/// Payload for updateTask/updateEvent RPC
struct UpdateTaskEventRpcPayload: Codable {
    let id: String
    let title: String?
    let type: String?
    let status: String?
    let priority: String?
    let startDate: String?
    let endDate: String?
    let durationMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case type
        case status
        case priority
        case startDate = "start_date"
        case endDate = "end_date"
        case durationMinutes = "duration_minutes"
    }
}

/// Response for updateTask/updateEvent RPC
struct UpdateTaskEventRpcResponse: Codable {
    let status: String
    let data: TaskEventApiResponse?
    let error: String?
}

/// Time data for getCurrentTime RPC response
struct TimeData: Codable {
    let epoch: Int64
    let iso: String
    let formatted: String
    let timezone: String
    let dayOfWeek: String

    enum CodingKeys: String, CodingKey {
        case epoch
        case iso
        case formatted
        case timezone
        case dayOfWeek = "day_of_week"
    }
}

/// Response for getCurrentTime RPC
struct GetCurrentTimeRpcResponse: Codable {
    let status: String
    let data: TimeData?
    let error: String?
}
