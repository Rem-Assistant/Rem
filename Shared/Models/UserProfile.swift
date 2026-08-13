import Foundation

// MARK: - User Profile

/// Shared user profile model used by both iOS and macOS.
/// Matches the backend `/api/v1/auth/me` and `/api/v1/auth/login` response shape.
struct UserProfile: Codable, Sendable {
    let id: String
    let email: String?
    let full_name: String?
    let first_name: String?
    let last_name: String?
    let profile_picture_url: String?
    let locale: String?

    var displayName: String {
        if let name = full_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let email, !email.isEmpty {
            return email.components(separatedBy: "@").first ?? email
        }
        return "Account"
    }
}
