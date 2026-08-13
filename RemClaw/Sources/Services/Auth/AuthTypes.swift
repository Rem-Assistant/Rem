import Foundation
import Security

// MARK: - Auth Provider

enum AuthProvider: Equatable {
    case apple
    case google
}

// MARK: - Auth Response (matches backend /api/v1/auth/login response)

struct AuthResponse: Codable {
    let access_token: String
    let user: AuthUserInfo
    let is_new_user: Bool?
}

// MARK: - User Info

/// AuthUserInfo is now a typealias for the shared UserProfile model.
/// Note: email is String? in the shared model. iOS auth responses always
/// provide an email, but callers should handle nil defensively.
typealias AuthUserInfo = UserProfile

// MARK: - Auth Error

enum AuthError: LocalizedError {
    case invalidResponse
    case networkError(Error)
    case authenticationFailed(String)
    case signInCancelled
    case identityProviderFailed(IdentityProviderFailure)
    case credentialStorageFailed(CredentialStorageFailure)
    case tokenNotFound

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .authenticationFailed(let message):
            "Authentication failed: \(message)"
        case .signInCancelled:
            "Sign-in was cancelled."
        case .identityProviderFailed(let failure):
            failure.userMessage
        case .credentialStorageFailed(let failure):
            failure.userMessage
        case .tokenNotFound:
            "No stored authentication token found"
        }
    }
}

struct IdentityProviderFailure: LocalizedError, Equatable {
    private static let googleSignInDomain = "com.google.GIDSignIn"
    private static let googleSignInCancelledCode = -5
    private static let appleAuthorizationDomain = "com.apple.AuthenticationServices.AuthorizationError"
    private static let appleAuthorizationCancelledCode = 1001

    let provider: String
    let operation: String
    let recovery: String
    let detail: String

    init(
        provider: String,
        operation: String,
        recovery: String,
        detail: String
    ) {
        self.provider = provider
        self.operation = operation
        self.recovery = recovery
        self.detail = detail
    }

    var errorDescription: String? { userMessage }

    static func map(provider: String, operation: String, error: Error) -> AuthError {
        let nsError = error as NSError
        if isCancellation(nsError) {
            return .signInCancelled
        }

        return .identityProviderFailed(
            IdentityProviderFailure(
                provider: provider,
                operation: operation,
                recovery: recoveryMessage(provider: provider, error: nsError),
                detail: "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
            )
        )
    }

    var userMessage: String {
        var message = "\(provider) sign-in couldn't finish. \(recovery)"
        message += "\n\nOperation: \(operation)"
        if !detail.isEmpty {
            message += "\nDetails: \(detail)"
        }
        return message
    }

    private static func isCancellation(_ error: NSError) -> Bool {
        if error.domain == googleSignInDomain && error.code == googleSignInCancelledCode {
            return true
        }

        if error.domain == appleAuthorizationDomain && error.code == appleAuthorizationCancelledCode {
            return true
        }

        return false
    }

    private static func recoveryMessage(provider: String, error: NSError) -> String {
        let description = error.localizedDescription.lowercased()

        if error.domain == googleSignInDomain,
           error.code == -2,
           description.contains("keychain") {
            return "Tap Clear local sign-in state below, then try Google again. If it still fails on this simulator/device, remove the saved Google account or erase the simulator and sign in again."
        }

        if error.domain == appleAuthorizationDomain,
           error.code == 1000 {
            return "Try Apple again after confirming this simulator/device is signed into iCloud and allows Apple Sign-In. If it still fails, use Google for this test account and capture the Apple sheet/error."
        }

        return "Tap Clear local sign-in state below if available, then try again. If this keeps happening, remove the saved \(provider) account from the simulator/device and sign in again."
    }
}

struct CredentialStorageFailure: LocalizedError, Equatable {
    let credential: String
    let operation: String
    let status: OSStatus?
    let detail: String

    init(
        credential: String,
        operation: String = "save",
        status: OSStatus? = nil,
        detail: String
    ) {
        self.credential = credential
        self.operation = operation
        self.status = status
        self.detail = detail
    }

    var errorDescription: String? { userMessage }

    var userMessage: String {
        var message = """
        Rem couldn't save your sign-in securely. Close and reopen Rem, then try signing in again.
        """
        message += "\n\nFailed item: \(credential)"
        message += "\nOperation: \(operation)"
        if let status {
            message += "\nKeychain status: \(status)"
            if let statusDescription = SecCopyErrorMessageString(status, nil) as String? {
                message += " (\(statusDescription))"
            }
        }
        if !detail.isEmpty {
            message += "\nDetails: \(detail)"
        }
        return message
    }
}
