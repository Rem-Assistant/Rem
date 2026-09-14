import Foundation

enum VoiceSessionSharedState {
    static let appGroupIdentifier = "group.com.remapp.rem"
    private static let isActiveKey = "voiceSessionIsActive"
    private static let pendingActionKey = "voicePendingAction"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static var isSessionActive: Bool {
        get { defaults?.bool(forKey: isActiveKey) ?? false }
        set { defaults?.set(newValue, forKey: isActiveKey) }
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
