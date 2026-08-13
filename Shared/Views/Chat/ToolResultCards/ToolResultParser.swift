import Foundation
import OpenClawKit

/// Parsed tool result types for rich card rendering.
enum ParsedToolResult {
    case calendarEvents([CalendarEventPayload])
    case calendarAdd(eventId: String, title: String?)
    case calendarUpdate(eventId: String, title: String?)
    case calendarDelete(eventId: String, title: String?)
    case remindersList([ReminderPayload])
    case remindersAdd(identifier: String, title: String?)
    case remindersUpdate(identifier: String, title: String?)
    case remindersDelete(identifier: String, title: String?)
    case deviceStatus(DeviceStatusPayload)
    case deviceInfo(DeviceInfoPayload)
    case taskCreate(title: String)
    case taskUpdate(title: String?)
    case taskDelete
    case notifySuccess
    case error(tool: String?, message: String)
    case unknown(String)

    /// Returns true if this result was recognized as a known type (not unknown).
    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    var consolidationKey: String? {
        switch self {
        case .calendarAdd(_, let title):
            return "calendar.add|\(normalized(title))"
        case .calendarUpdate(_, let title):
            return "calendar.update|\(normalized(title))"
        case .calendarDelete(_, let title):
            return "calendar.delete|\(normalized(title))"
        case .remindersAdd(_, let title):
            return "reminders.add|\(normalized(title))"
        case .remindersUpdate(_, let title):
            return "reminders.update|\(normalized(title))"
        case .remindersDelete(_, let title):
            return "reminders.delete|\(normalized(title))"
        case .taskCreate(let title):
            return "task.create|\(normalized(title))"
        case .taskUpdate(let title):
            return "task.update|\(normalized(title))"
        case .taskDelete:
            return "task.delete"
        case .notifySuccess:
            return "notify.success"
        default:
            return nil
        }
    }

    private func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

/// Parses raw JSON text from tool result messages into typed results for card rendering.
enum ToolResultParser {

    static func parse(_ text: String) -> ParsedToolResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            return .unknown(text)
        }

        // Try to decode as a generic dictionary first for shape detection
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown(text)
        }

        // Unwrap gateway envelope: { ok, nodeId, command, payload: { ... } }
        // The actual result data lives inside `payload`.
        if json["nodeId"] != nil || json["command"] != nil,
           let payload = json["payload"] as? [String: Any] {
            return parsePayload(payload, envelope: json, rawText: text)
        }

        return parsePayload(json, envelope: nil, rawText: text)
    }

    private static func parsePayload(
        _ json: [String: Any],
        envelope: [String: Any]?,
        rawText: String
    ) -> ParsedToolResult {
        // Re-serialize the payload dict for Codable decoding
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            return .unknown(rawText)
        }

        // 1. Error — highest priority
        if let status = json["status"] as? String, status == "error",
           let errorMsg = json["error"] as? String {
            let tool = json["tool"] as? String ?? (envelope?["command"] as? String)
            return .error(tool: tool, message: errorMsg)
        }
        if let errorMsg = json["error"] as? String, json["status"] == nil {
            let tool = json["tool"] as? String ?? (envelope?["command"] as? String)
            return .error(tool: tool, message: errorMsg)
        }

        // 2. Calendar events list — { events: [...] }
        if json["events"] != nil,
           let response = try? JSONDecoder().decode(CalendarEventsResponse.self, from: data) {
            return .calendarEvents(response.events)
        }

        // 3. Reminders list — { reminders: [...] }
        if json["reminders"] != nil,
           let response = try? JSONDecoder().decode(RemindersListResponse.self, from: data) {
            return .remindersList(response.reminders)
        }

        // 4. Device status — has batteryLevel
        if json["batteryLevel"] != nil,
           let payload = try? JSONDecoder().decode(DeviceStatusPayload.self, from: data) {
            return .deviceStatus(payload)
        }

        // 7. Device info — has model + systemName
        if json["model"] != nil, json["systemName"] != nil,
           let payload = try? JSONDecoder().decode(DeviceInfoPayload.self, from: data) {
            return .deviceInfo(payload)
        }

        // 8. Calendar CRUD — { eventId: "...", title?: "..." } (single, no events array)
        if let eventId = json["eventId"] as? String, json["events"] == nil {
            let title = json["title"] as? String
            let command = envelope?["command"] as? String ?? ""
            if json["deleted"] as? Bool == true {
                return .calendarDelete(eventId: eventId, title: title)
            }
            if command.contains("update") {
                return .calendarUpdate(eventId: eventId, title: title)
            }
            return .calendarAdd(eventId: eventId, title: title)
        }

        // 9. Identifier-based confirmation — reminders CRUD
        if let identifier = json["identifier"] as? String {
            let title = json["title"] as? String
            let command = envelope?["command"] as? String ?? ""
            if json["deleted"] as? Bool == true {
                return .remindersDelete(identifier: identifier, title: title)
            }
            if command.contains("update") {
                return .remindersUpdate(identifier: identifier, title: title)
            }
            return .remindersAdd(identifier: identifier, title: title)
        }

        // 10. Task CRUD — { task: { id, title, ... } } or { deleted: true, id: "..." }
        if let taskDict = json["task"] as? [String: Any] {
            let title = taskDict["title"] as? String
            let command = envelope?["command"] as? String ?? ""
            if command.contains("update") {
                return .taskUpdate(title: title)
            }
            return .taskCreate(title: title ?? "Task")
        }
        if let deleted = json["deleted"] as? Bool, deleted, json["id"] != nil {
            return .taskDelete
        }

        // 11. Notification success — only for notify commands
        if let ok = json["ok"] as? Bool, ok, json.count <= 2 {
            let command = envelope?["command"] as? String ?? ""
            if command.contains("notify") {
                return .notifySuccess
            }
        }

        return .unknown(rawText)
    }
}
