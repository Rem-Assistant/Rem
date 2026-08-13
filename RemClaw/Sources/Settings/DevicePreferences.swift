import Foundation

/// Lightweight UserDefaults-backed preferences for *this* device.
///
/// Lives in `Settings/` rather than `RemCredentialStore` because these are
/// non-sensitive user preferences, not credentials — keeping them in a
/// dedicated store avoids the implication that the Keychain is involved.
/// See #306 (Pairing recovery UX epic) review feedback.
enum DevicePreferences {
    private static let deviceDisplayNameKey = "rem.device.displayName"

    /// User-provided name shown in the paired-devices list on other devices.
    /// Fallback path for #304 (iOS UIDevice.current.name returns 'iPhone'):
    /// iOS 16+ returns the model ("iPhone") from `UIDevice.current.name`
    /// unless the app has the `com.apple.developer.device-information.
    /// user-assigned-device-name` entitlement (granted with justification).
    /// Rather than apply for the entitlement, we let the user set their own
    /// label in Settings. Nil / empty means "use the iOS-returned value".
    static var deviceDisplayName: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: deviceDisplayNameKey) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        set {
            let trimmed = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: deviceDisplayNameKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: deviceDisplayNameKey)
            }
        }
    }
}
