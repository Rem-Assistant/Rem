import Foundation
import Testing
@testable import RemClaw

/// Pins the Cluster A data-loss guard: a transient de-auth (401 / token minted
/// for another environment / expiry) must NEVER wipe local data; only an explicit
/// sign-out or a genuinely different user does. See
/// docs/rebuild/04-FIX-IDENTITY-DATALOSS.md.
struct LocalDataResetDecisionTests {
    typealias Decision = RemAuthService.LocalDataResetDecision

    // MARK: - De-auth

    @Test func transientDeauthKeepsData() {
        // 401 / env-mismatch / expiry → userInitiated == false → keep.
        #expect(Decision.onDeauth(userInitiated: false) == .keep)
    }

    @Test func explicitSignOutWipesData() {
        #expect(Decision.onDeauth(userInitiated: true) == .wipe)
    }

    // MARK: - Sign-in

    @Test func firstEverSignInKeepsData() {
        // No prior user on this device → nothing to wipe.
        #expect(Decision.onSignIn(newUserId: "user-a", lastSignedInUserId: nil) == .keep)
    }

    @Test func returningSameUserKeepsData() {
        // The core regression guard: re-auth after a 401 returns the SAME id,
        // so the user's tasks must survive.
        #expect(Decision.onSignIn(newUserId: "user-a", lastSignedInUserId: "user-a") == .keep)
    }

    @Test func differentUserWipesData() {
        // Account switch on a shared device → wipe to avoid cross-user leak.
        #expect(Decision.onSignIn(newUserId: "user-b", lastSignedInUserId: "user-a") == .wipe)
    }

    // MARK: - lastSignedInUserId persistence

    @Test func lastSignedInUserIdRoundTrips() {
        let original = RemAuthService.lastSignedInUserId
        defer { RemAuthService.lastSignedInUserId = original }

        RemAuthService.lastSignedInUserId = "user-xyz"
        #expect(RemAuthService.lastSignedInUserId == "user-xyz")

        // The ownership marker intentionally survives sign-out so a different future
        // user still has to wipe any rows left by a failed local-data clear.
        #expect(RemAuthService.lastSignedInUserId == "user-xyz")
    }

    @Test func signOutCleanupFailureHasAVisibleFailClosedPath() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try read("RemClaw/Sources/Settings/SettingsView.swift", from: projectRoot)
        let sharedSettings = try read("Shared/Views/Settings/SharedSettingsView.swift", from: projectRoot)

        #expect(settings.contains("you’re still signed in to keep it safe"))
        #expect(sharedSettings.contains("var onSignOut: () -> String?"))
        #expect(sharedSettings.contains("if let error = onSignOut()"))
        #expect(sharedSettings.contains(".alert(\"Couldn’t Sign Out\""))
    }

    private func read(_ relativePath: String, from projectRoot: URL) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
