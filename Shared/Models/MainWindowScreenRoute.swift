import Foundation

/// Typed payloads for routing the macOS main window from auxiliary surfaces.
public enum MainWindowScreenRoute: String, CaseIterable, Sendable {
    case agenda
    case inbox
    case sessions
    case chat
    case settings
}

public extension Notification.Name {
    static let openMainWindowScreen = Notification.Name("remclaw.openMainWindowScreen")
}
