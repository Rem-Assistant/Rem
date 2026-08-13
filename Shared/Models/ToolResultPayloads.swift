import Foundation

// MARK: - Tool Result Payload Types
//
// These structs describe the JSON shapes returned by AI node commands
// (calendar.events, reminders.list, device.status, device.info, etc.).
// They live in Shared because both iOS and Mac render them via the
// tool result card views under `Shared/Views/Chat/ToolResultCards/`.
//
// The iOS command-params counterparts (CalendarAddParams, RemindersUpdateParams,
// etc.) remain in RemClaw/Sources/Gateway/DeviceCommandTypes.swift — Mac does
// not send those commands, so they are iOS-only.

// MARK: - Calendar

struct CalendarEventPayload: Codable, Sendable {
    var eventId: String
    var title: String
    var startDate: String
    var endDate: String
    var durationMinutes: Int
    var isAllDay: Bool
    var calendarName: String?
}

struct CalendarEventsResponse: Codable, Sendable {
    var events: [CalendarEventPayload]
}

// MARK: - Reminders

struct ReminderPayload: Codable, Sendable {
    var identifier: String
    var title: String
    var notes: String?
    var dueDate: String?
    var isCompleted: Bool
    var priority: Int
    var listName: String?
}

struct RemindersListResponse: Codable, Sendable {
    var reminders: [ReminderPayload]
}

// MARK: - Device

struct DeviceStatusPayload: Codable, Sendable {
    var batteryLevel: Double
    var batteryState: String
    var thermalState: String
    var lowPowerMode: Bool
    var diskTotalBytes: Int64?
    var diskAvailableBytes: Int64?
}

struct DeviceInfoPayload: Codable, Sendable {
    var name: String
    var model: String
    var systemName: String
    var systemVersion: String
    var identifierForVendor: String?
    var localTime: String
    var timeZone: String
    var timeZoneAbbreviation: String
    var processInfo: DeviceProcessInfo
}

struct DeviceProcessInfo: Codable, Sendable {
    var processorCount: Int
    var physicalMemoryBytes: Int64
    var osVersion: String
    var thermalState: String
}
