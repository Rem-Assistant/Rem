import Foundation

enum FocusSessionSharedState {
    static let appGroupIdentifier = "group.com.remapp.rem"
    private static let pendingActionKey = "focusPendingAction"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static var pendingAction: String? {
        get { defaults?.string(forKey: pendingActionKey) }
        set {
            defaults?.set(newValue, forKey: pendingActionKey)
            defaults?.synchronize()
        }
    }

    static func consumePendingAction() -> String? {
        guard let action = pendingAction else { return nil }
        pendingAction = nil
        return action
    }
}

enum FocusDeepLinkHelper {
    static func startFromPreSessionURL(taskId: String, taskTitle: String, duration: TimeInterval?) -> URL {
        var urlString = "remclaw://focus/startFromPreSession?taskId=\(taskId)&taskTitle=\(taskTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskTitle)"
        if let duration {
            urlString += "&duration=\(Int(duration))"
        }
        return URL(string: urlString)!
    }
}
