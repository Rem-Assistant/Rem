import Foundation
import Observation

extension Notification.Name {
    static let remClawDidOpenURL = Notification.Name("remclaw.didOpenURL")
}

enum VoiceSessionCommand: String {
    case start
    case stop
    case open
    /// Fetch the latest canonical Today artifact, anchor to it, and begin narrated Voice Chat.
    case readLatestBrief
}

enum VoiceSessionDeepLink {
    static let scheme = "remclaw"
    static let host = "voice"

    static func url(for command: VoiceSessionCommand) -> URL {
        URL(string: "\(scheme)://\(host)/\(command.rawValue)")!
    }

    static func command(from url: URL) -> VoiceSessionCommand? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return VoiceSessionCommand(rawValue: action)
    }
}

enum LatestBriefDeepLink {
    static let scheme = "remclaw"
    static let host = "brief"
    static let listenAction = "listen"

    static var listenURL: URL {
        URL(string: "\(scheme)://\(host)/\(listenAction)")!
    }

    static func listenURL(accountID: String) -> URL {
        var components = URLComponents(url: listenURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "accountId", value: accountID)]
        return components.url!
    }

    static func isListenRequest(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else {
            return false
        }
        let action = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return action == listenAction
    }

    static func accountID(from url: URL) -> String? {
        guard isListenRequest(url),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "accountId" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func validatedAccountID(
        from url: URL,
        isAuthenticated: Bool,
        currentUserID: String?
    ) -> String? {
        guard isAuthenticated,
              let targetAccountID = accountID(from: url),
              targetAccountID == currentUserID
        else { return nil }
        return targetAccountID
    }

    static func shouldDeferUntilAuthRestores(isCheckingAuth: Bool) -> Bool {
        // `currentUserID` may still be a cached profile while token/gateway reconciliation is
        // awaiting. Only the completed auth check can prove that profile owns the live session.
        return isCheckingAuth
    }
}

@MainActor
@Observable
final class VoiceSessionControlRouter {
    private(set) var latestCommand: VoiceSessionCommand?
    private(set) var commandToken: Int = 0
    private var targetAccountID: String?
    private var ownerID: UUID?

    func enqueue(_ command: VoiceSessionCommand, accountID: String? = nil) {
        // A brief notification belongs to the account that received it. If auth restoration has
        // not identified that account (or the user is signed out), do not retain an unbound intent
        // that a later, different sign-in could claim.
        if command == .readLatestBrief, accountID == nil {
            latestCommand = nil
            targetAccountID = nil
            ownerID = nil
            commandToken &+= 1
            return
        }
        latestCommand = command
        targetAccountID = accountID
        ownerID = nil
        commandToken &+= 1
    }

    /// Claims a command for one authenticated root without removing it. The first root binds the
    /// intent to its account; another account discards that stale notification rather than reading
    /// somebody else's brief. A replacement root for the same account can reclaim after release.
    func claimCommand(for token: Int, accountID: String?, ownerID requestedOwnerID: UUID) -> VoiceSessionCommand? {
        guard token == commandToken, let accountID else { return nil }
        if let targetAccountID, targetAccountID != accountID {
            latestCommand = nil
            self.targetAccountID = nil
            ownerID = nil
            return nil
        }
        guard ownerID == nil || ownerID == requestedOwnerID else { return nil }
        targetAccountID = accountID
        ownerID = requestedOwnerID
        return latestCommand
    }

    func acknowledgeCommand(for token: Int, ownerID: UUID) {
        guard token == commandToken, self.ownerID == ownerID else { return }
        latestCommand = nil
        targetAccountID = nil
        self.ownerID = nil
    }

    /// A view that never reached a state where it could accept the command gives ownership back to
    /// the app router. Bumping the token wakes any replacement root observing the same intent.
    func releaseCommand(ownerID: UUID) {
        guard self.ownerID == ownerID, latestCommand != nil else { return }
        self.ownerID = nil
        commandToken &+= 1
    }
}
