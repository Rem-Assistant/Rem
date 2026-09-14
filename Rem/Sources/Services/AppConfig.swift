import Combine
import Foundation

/// Reads configuration values injected from xcconfig files via Info.plist.
enum AppConfig {
    static var apiBaseURL: String {
        Bundle.main.infoDictionary?["APIBaseURL"] as? String ?? ""
    }

    static var googleClientID: String? {
        Bundle.main.infoDictionary?["GIDClientID"] as? String
    }

    static var posthogApiKey: String? {
        guard let key = Bundle.main.infoDictionary?["PostHogApiKey"] as? String,
              !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    static var posthogHost: String? {
        guard let host = Bundle.main.infoDictionary?["PostHogHost"] as? String,
              !host.isEmpty, !host.hasPrefix("$(") else { return nil }
        return host
    }

    static var iapProProductID: String? {
        guard let id = Bundle.main.infoDictionary?["IAPProProductID"] as? String,
              !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return id
    }
}
