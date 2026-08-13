import Foundation

/// Shared façade for the Task / Cloud settings section: the GMI BYOK key
/// (Keychain, platform-routed) and the default task runtime (UserDefaults).
///
/// The SwiftUI section view (`SharedTaskRuntimeSettingsView`) is fully shared
/// across iOS and macOS; this store is the one place that bridges to the
/// platform-specific Keychain accessor so the view never needs `#if` for
/// secret storage.
///
/// - GMI key: Keychain ONLY (CLAUDE.md secrets rule) — iOS
///   `RemCredentialStore.gmiApiKey`, Mac `MacBYOKKeychain.gmiApiKey`, both at
///   account `byok.gmi.apiKey` per docs/agentbox/CONTRACT.md §2.
/// - Default runtime: UserDefaults, key `rem.task.defaultRuntime`, storing the
///   `TaskRuntimeKind.rawValue`.
enum TaskRuntimeSettingsStore {

    // MARK: - GMI API Key (Keychain, platform-routed)

    /// Reads/writes the GMI key from the platform Keychain. Setting `nil`
    /// (or an all-whitespace string) clears it.
    static var gmiApiKey: String? {
        get {
            #if os(iOS)
            return RemCredentialStore.gmiApiKey
            #else
            return MacBYOKKeychain.gmiApiKey
            #endif
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let valueToStore = (trimmed?.isEmpty == false) ? trimmed : nil
            #if os(iOS)
            RemCredentialStore.gmiApiKey = valueToStore
            #else
            MacBYOKKeychain.gmiApiKey = valueToStore
            #endif
        }
    }

    /// Whether a non-empty GMI key is present, without revealing it.
    static var hasGMIKey: Bool {
        guard let key = gmiApiKey else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Default Task Runtime (UserDefaults)

    /// UserDefaults key for the user's preferred default task runtime.
    /// Stores `TaskRuntimeKind.rawValue` (e.g. "agentbox", "local_mac",
    /// "local_ios"). Documented so other lanes can read the same key.
    static let defaultRuntimeDefaultsKey = "rem.task.defaultRuntime"

    /// Platform-appropriate fallback when nothing is persisted yet.
    /// Cloud (AgentBox) is the cross-platform default.
    static var defaultRuntimeFallback: TaskRuntimeKind { .agentbox }

    /// Runtime kinds offered in the picker on this platform. `.localMac` only
    /// makes sense on Mac; `.localiOS` only on iOS. `.agentbox` is everywhere.
    static var selectableRuntimes: [TaskRuntimeKind] {
        #if os(iOS)
        return [.agentbox, .localiOS]
        #else
        return [.agentbox, .localMac]
        #endif
    }

    /// The persisted default runtime, falling back to `defaultRuntimeFallback`
    /// if unset or if the stored value isn't selectable on this platform.
    static var defaultRuntime: TaskRuntimeKind {
        get {
            guard
                let raw = UserDefaults.standard.string(forKey: defaultRuntimeDefaultsKey),
                let kind = TaskRuntimeKind(rawValue: raw),
                selectableRuntimes.contains(kind)
            else {
                return defaultRuntimeFallback
            }
            return kind
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultRuntimeDefaultsKey)
        }
    }
}
