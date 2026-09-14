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
