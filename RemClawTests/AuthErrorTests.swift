import Foundation
import Testing
@testable import RemClaw

struct AuthErrorTests {
    @Test func credentialStorageFailureExplainsSecureSignInStorage() {
        let failure = CredentialStorageFailure(
            credential: "backend sign-in token",
            operation: "update",
            status: -25308,
            detail: "app.remclaw/backend.token"
        )
        let error = AuthError.credentialStorageFailed(failure)
        let message = error.localizedDescription

        #expect(message.contains("couldn't save your sign-in securely"))
        #expect(message.contains("Close and reopen Rem"))
        #expect(message.contains("backend sign-in token"))
        #expect(message.contains("update"))
        #expect(message.contains("-25308"))
        #expect(message.contains("interaction"))
        #expect(message.contains("app.remclaw/backend.token"))
    }

    @Test func credentialStorageFailureCanOmitStatusForUnknownErrors() {
        let failure = CredentialStorageFailure(
            credential: "cached user profile",
            detail: "JSON encoding failed"
        )
        let message = failure.localizedDescription

        #expect(message.contains("cached user profile"))
        #expect(message.contains("Operation: save"))
        #expect(!message.contains("Keychain status:"))
        #expect(message.contains("JSON encoding failed"))
    }

    @Test func identityProviderFailureKeepsProviderDetailsAndRecovery() {
        let failure = IdentityProviderFailure(
            provider: "Google",
            operation: "open Google sign-in",
            recovery: "Close and reopen Rem, then try again.",
            detail: "com.google.GIDSignIn code -2: keychain error"
        )
        let error = AuthError.identityProviderFailed(failure)
        let message = error.localizedDescription

        #expect(message.contains("Google sign-in couldn't finish"))
        #expect(message.contains("Close and reopen Rem"))
        #expect(message.contains("open Google sign-in"))
        #expect(message.contains("com.google.GIDSignIn"))
        #expect(message.contains("keychain error"))
    }

    @Test func identityProviderFailureSupportsAppleAuthorizationErrors() {
        let failure = IdentityProviderFailure(
            provider: "Apple",
            operation: "complete Apple sign-in",
            recovery: "Close and reopen Rem, then try again.",
            detail: "com.apple.AuthenticationServices.AuthorizationError code 1000"
        )
        let error = AuthError.identityProviderFailed(failure)
        let message = error.localizedDescription

        #expect(message.contains("Apple sign-in couldn't finish"))
        #expect(message.contains("complete Apple sign-in"))
        #expect(message.contains("AuthorizationError"))
        #expect(message.contains("code 1000"))
    }

    @Test func identityProviderMapperPreservesProviderErrorWithoutUserInfoLeakage() {
        let error = NSError(
            domain: "com.google.GIDSignIn",
            code: -2,
            userInfo: [
                NSLocalizedDescriptionKey: "keychain error",
                "account": "private@example.com",
            ]
        )
        let mapped = IdentityProviderFailure.map(
            provider: "Google",
            operation: "open Google sign-in",
            error: error
        )
        let message = mapped.localizedDescription

        #expect(message.contains("com.google.GIDSignIn code -2: keychain error"))
        #expect(!message.contains("private@example.com"))
    }

    @Test func googleProviderKeychainFailureGivesResetFirstRecovery() {
        let error = NSError(
            domain: "com.google.GIDSignIn",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "keychain error"]
        )

        let mapped = IdentityProviderFailure.map(
            provider: "Google",
            operation: "open Google sign-in",
            error: error
        )
        let message = mapped.localizedDescription

        #expect(message.contains("Tap Clear local sign-in state below"))
        #expect(message.contains("try Google again"))
        #expect(message.contains("erase the simulator"))
    }

    @Test func appleProviderAuthorizationFailureExplainsDevicePrerequisite() {
        let error = NSError(
            domain: "com.apple.AuthenticationServices.AuthorizationError",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed."]
        )

        let mapped = IdentityProviderFailure.map(
            provider: "Apple",
            operation: "complete Apple sign-in",
            error: error
        )
        let message = mapped.localizedDescription

        #expect(message.contains("signed into iCloud"))
        #expect(message.contains("allows Apple Sign-In"))
        #expect(message.contains("use Google for this test account"))
    }

    @Test func identityProviderMapperTreatsProviderCancellationsAsCancelled() {
        let googleCancel = NSError(domain: "com.google.GIDSignIn", code: -5)
        let appleCancel = NSError(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001)

        #expect(IdentityProviderFailure.map(provider: "Google", operation: "open Google sign-in", error: googleCancel).localizedDescription == "Sign-in was cancelled.")
        #expect(IdentityProviderFailure.map(provider: "Apple", operation: "complete Apple sign-in", error: appleCancel).localizedDescription == "Sign-in was cancelled.")
    }
}
