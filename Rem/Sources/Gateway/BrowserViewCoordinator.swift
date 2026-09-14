import Foundation
import Observation

/// Owns the live view of Rem's cloud browser on iOS (doc 37).
///
/// Thin by design: the session, the view and the input mapping all live in `Shared/`, so the Mac
/// can reuse them against a different frame source. This type only supplies the iOS-specific
/// answer to "which browser, and with what credential".
///
/// ## Why the app resolves its own connection
///
/// `canvas.present` carries an agent-supplied `url`. Using it would repeat the P1 Codex found on
/// #979 (`ToolResultParser.swift:138`): agent-controlled content rendered as trusted UI. A page
/// the agent is browsing could induce `canvas.present("https://discord-login.evil")` and Rem
/// would render a phishing page, chrome-less, inside a trusted surface.
///
/// So the agent's URL is never used. This connects to the user's OWN gateway, read from the
/// credential store. `canvas.present` is a signal ("show the browser"), not a destination.
/// Host-checking an agent URL would be the weaker design; not accepting one leaves nothing to
/// check.
@MainActor
@Observable
final class BrowserViewCoordinator {
    let session: BrowserLiveSession
    private let defaults: UserDefaults
    private let ownershipStorageKey = "rem.browserEndedOwnership.v1"
    private var activeScope: BrowserEndedOwnershipScope?

    init(session: BrowserLiveSession? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.session = session ?? BrowserLiveSession(makeTransport: {
            // The gateway the user is actually paired with, and the token the app already holds
            // to drive it. Nothing new is granted, and no secret goes near a URL.
            guard let urlString = RemCredentialStore.gatewayURL,
                  let url = URL(string: urlString),
                  let token = RemCredentialStore.gatewayToken
            else { return nil }
            return CloudBrowserTransport(gatewayURL: url, token: token)
        })
    }

    /// Bind persisted browser-card ownership to the current authenticated account and gateway.
    /// Changing either boundary first destroys all live/in-memory state, then restores only that
    /// scope's ended conversation key. No frame, URL, cookie, or run evidence is persisted.
    func activateAuthenticatedScope(accountID: String?, gatewayURL: String?) {
        let scope = BrowserEndedOwnershipScope(accountID: accountID, gatewayURL: gatewayURL)
        guard scope != activeScope else { return }

        session.onEndedOwnershipChanged = nil
        session.terminateAuthenticatedSession()
        activeScope = scope
        guard let scope else { return }

        session.onEndedOwnershipChanged = { [weak self] owner in
            guard let self, activeScope == scope else { return }
            let current = defaults.string(forKey: ownershipStorageKey) ?? ""
            let updated = BrowserEndedOwnershipLedger.recording(owner: owner, for: scope, in: current)
            defaults.set(updated, forKey: ownershipStorageKey)
        }

        let encoded = defaults.string(forKey: ownershipStorageKey) ?? ""
        if let owner = BrowserEndedOwnershipLedger.owner(for: scope, in: encoded) {
            session.restoreEndedOwnership(owner)
        }
    }

    /// Close the authenticated socket and erase all account-owned runtime state. The scoped receipt
    /// remains in UserDefaults so the same account+gateway can recover its ended card on return.
    func terminateAuthenticatedSession() {
        session.onEndedOwnershipChanged = nil
        session.terminateAuthenticatedSession()
        activeScope = nil
    }

    /// Show the live view and start streaming. Safe to call repeatedly.
    func present() {
        session.present()
    }

    func dismiss() {
        // Stop only the screencast: a hidden sheet must not burn gateway CPU, but Done/swipe-down
        // is a viewer lifecycle event and cannot end the remote browser session or its chat card.
        session.dismissViewer()
    }
}
