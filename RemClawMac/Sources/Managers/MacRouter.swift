import SwiftUI

struct MacChatRoute: Equatable {
    let sessionKey: String
    let isFresh: Bool
}

/// Navigation router for RemClawMac main window.
///
/// Sidebar surfaces (see `Screen.sidebarCases`): Agenda, Inbox, Sessions,
/// Settings. Chat is intentionally NOT a sidebar row — it is reached via
/// the sidebar-footer "Chat" primary action or by selecting a past
/// conversation in the Sessions tab (#305 (Mac chat parity epic)).
@Observable
final class MacRouter {
    enum Screen: String, CaseIterable, Identifiable {
        case agenda = "Agenda"
        case inbox = "Inbox"
        case sessions = "Sessions"
        case chat = "Chat"
        case settings = "Settings"

        var id: String { rawValue }

        /// Cases shown in the sidebar nav list. Chat is reached via the
        /// sidebar-footer "Chat" button, not a sidebar row.
        static var sidebarCases: [Screen] {
            [.agenda, .inbox, .sessions, .settings]
        }

        var icon: String {
            switch self {
            case .agenda: "calendar"
            case .inbox: "tray"
            case .sessions: "clock.arrow.circlepath"
            case .chat: "bubble.left.and.bubble.right"
            case .settings: "gear"
            }
        }
    }

    var selectedScreen: Screen = .agenda

    /// When set, the Chat screen opens this specific session key
    /// instead of creating a new one. Cleared after consumption.
    var pendingSessionKey: String?
    var pendingSessionIsFresh = false

    /// Navigate to the Chat screen with a specific session key.
    func openSession(_ sessionKey: String) {
        pendingSessionKey = sessionKey
        pendingSessionIsFresh = false
        selectedScreen = .chat
    }

    /// Start a brand-new chat session. Triggered from the sidebar-footer
    /// "Chat" primary action in `MainWindow`.
    func startNewChat() {
        let shortId = UUID().uuidString.prefix(8).lowercased()
        pendingSessionKey = "chat-\(shortId)"
        pendingSessionIsFresh = true
        selectedScreen = .chat
    }
}
