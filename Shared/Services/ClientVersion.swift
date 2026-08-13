import Foundation

/// Shared client-version helper for the backend API versioning headers used by
/// the API versioning rollout (#226, docs/API_VERSIONING.md).
///
/// Version header format: `<bundle-short-version>+<build-number>`.
/// Platform header format: `ios` or `mac`. Both are computed once per launch.
///
/// Usage:
/// ```swift
/// request.setValue(ClientVersion.headerValue, forHTTPHeaderField: "X-Client-Version")
/// request.setValue(ClientVersion.platformValue, forHTTPHeaderField: "X-Client-Platform")
/// ```
///
/// The centralized HTTP clients (`AuthenticatedHttpClient`,
/// `MacAuthenticatedHttpClient`) apply these headers automatically; raw
/// `URLRequest` call sites should call `setHeaders(on:)`.
enum ClientVersion {
    /// `<short-version>+<build>` — e.g. `1.4.0+42`.
    static let headerValue: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }()

    /// `ios` or `mac`, sent separately so backend logs can group clients by platform.
    static let platformValue: String = {
        #if os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }()

    /// Header field name. Use this constant instead of repeating the string.
    static let headerName: String = "X-Client-Version"

    /// Platform header field name. Use this constant instead of repeating the string.
    static let platformHeaderName: String = "X-Client-Platform"

    static func setHeaders(on request: inout URLRequest) {
        request.setValue(headerValue, forHTTPHeaderField: headerName)
        request.setValue(platformValue, forHTTPHeaderField: platformHeaderName)
    }
}
