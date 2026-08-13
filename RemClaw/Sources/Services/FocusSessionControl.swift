import Foundation
import Observation

enum FocusSessionCommand {
    case pause(sessionId: String)
    case resume(sessionId: String)
    case stop(sessionId: String)
    case startFromPreSession(taskId: String, taskTitle: String, duration: TimeInterval?)
}

enum FocusSessionDeepLink {
    static let scheme = "remclaw"
    static let host = "focus"

    static func command(from url: URL) -> FocusSessionCommand? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        switch action {
        case "pause":
            guard let sessionId = queryValue("sessionId") else { return nil }
            return .pause(sessionId: sessionId)
        case "resume":
            guard let sessionId = queryValue("sessionId") else { return nil }
            return .resume(sessionId: sessionId)
        case "stop":
            guard let sessionId = queryValue("sessionId") else { return nil }
            return .stop(sessionId: sessionId)
        case "startFromPreSession":
            guard let taskId = queryValue("taskId"),
                  let taskTitle = queryValue("taskTitle") else { return nil }
            let duration = queryValue("duration").flatMap { Double($0) }
            return .startFromPreSession(taskId: taskId, taskTitle: taskTitle, duration: duration)
        default:
            return nil
        }
    }

    /// Parse a pending action string from FocusSessionSharedState.
    static func command(fromPendingAction action: String) -> FocusSessionCommand? {
        let parts = action.split(separator: ":", maxSplits: 1)
        guard parts.count >= 2 else { return nil }
        let verb = String(parts[0])
        let rest = String(parts[1])

        switch verb {
        case "pause":
            return .pause(sessionId: rest)
        case "resume":
            return .resume(sessionId: rest)
        case "stop":
            return .stop(sessionId: rest)
        case "startFromPreSession":
            let subParts = rest.split(separator: ":", maxSplits: 2)
            guard subParts.count >= 2 else { return nil }
            let taskId = String(subParts[0])
            let taskTitle = String(subParts[1])
            let duration: TimeInterval? = subParts.count > 2 ? Double(subParts[2]) : nil
            return .startFromPreSession(taskId: taskId, taskTitle: taskTitle, duration: duration)
        default:
            return nil
        }
    }
}

@MainActor
@Observable
final class FocusSessionControlRouter {
    private(set) var latestCommand: FocusSessionCommand?
    private(set) var commandToken: Int = 0

    func enqueue(_ command: FocusSessionCommand) {
        latestCommand = command
        commandToken &+= 1
    }
}
