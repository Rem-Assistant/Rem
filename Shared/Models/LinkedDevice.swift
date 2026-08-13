import Foundation
import OpenClawKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Linked Device Model

/// A paired device record from the gateway's `device.pair.list` response.
/// Shared across iOS and macOS targets.
struct LinkedDevice: Codable, Identifiable, Sendable {
    let deviceId: String
    let displayName: String?
    let clientId: String?
    let scopes: [String]?
    let role: String?
    let connectedAt: String?
    let platform: String?
    let tokens: [DeviceToken]?
    let approvedAtMs: Int?
    let roles: [String]?

    var id: String { deviceId }

    /// Human-readable name. Uses the local device name for the current device.
    ///
    /// On iOS, when the system `UIDevice.current.name` returns the generic
    /// model ("iPhone"/"iPad" on iOS 16+ without the user-assigned-device-name
    /// entitlement — see #304), falls back to the gateway-supplied
    /// `displayName` (which was already suffixed with a short hash by the
    /// client when pairing — see `RemGatewayClient.operatorDisplayName`).
    var name: String {
        if isCurrentDevice {
            #if os(iOS)
            let raw = UIDevice.current.name
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Prefer the gateway's record (has the hash suffix / user override)
            // over the raw generic value when we have both.
            if trimmed == "iPhone" || trimmed == "iPad" {
                if let displayName, !displayName.isEmpty { return displayName }
                return "\(trimmed) (\(String(deviceId.prefix(4))))"
            }
            return trimmed.isEmpty ? (displayName ?? "This iPhone") : trimmed
            #elseif os(macOS)
            return Host.current().localizedName ?? "Mac"
            #endif
        }
        if let displayName, !displayName.isEmpty { return displayName }
        return "Device \(String(deviceId.prefix(8)))"
    }

    /// Most recent activity across all tokens, in milliseconds since epoch.
    var lastActiveMs: Int? {
        tokens?.compactMap { $0.lastUsedAtMs }.max()
    }

    /// Whether this device has been active in the last 7 days.
    var isRecentlyActive: Bool {
        guard let lastMs = lastActiveMs else {
            guard let approved = approvedAtMs else { return false }
            let sevenDaysAgo = Int(Date().timeIntervalSince1970 * 1000) - (7 * 24 * 60 * 60 * 1000)
            return approved > sevenDaysAgo
        }
        let sevenDaysAgo = Int(Date().timeIntervalSince1970 * 1000) - (7 * 24 * 60 * 60 * 1000)
        return lastMs > sevenDaysAgo
    }

    /// Whether this device has both node and operator roles.
    var isFullDevice: Bool {
        guard let roles else { return false }
        return roles.contains("node") && roles.contains("operator")
    }

    /// Inferred platform based on clientId or explicit platform field.
    var inferredPlatform: DevicePlatform {
        if let platform {
            let lower = platform.lowercased()
            if lower.contains("mac") { return .mac }
            if lower.contains("ios") || lower.contains("iphone") || lower.contains("ipad") { return .iOS }
        }
        if let clientId {
            let lower = clientId.lowercased()
            if lower.contains("mac") { return .mac }
            if lower.contains("ios") { return .iOS }
        }
        if let displayName {
            let lower = displayName.lowercased()
            if lower.contains("mac") || lower.contains("imac") || lower.contains("macbook") { return .mac }
            if lower.contains("iphone") || lower.contains("ipad") { return .iOS }
        }
        return .unknown
    }

    /// Whether this device appears to be the current device.
    var isCurrentDevice: Bool {
        let myId = DeviceIdentityStore.loadOrCreate().deviceId
        return deviceId == myId
    }
}

// MARK: - Device Platform

enum DevicePlatform: String, Sendable {
    case iOS
    case mac
    case unknown

    var sfSymbol: String {
        switch self {
        case .iOS: "iphone"
        case .mac: "desktopcomputer"
        case .unknown: "laptopcomputer.and.iphone"
        }
    }

    var displayName: String {
        switch self {
        case .iOS: "iOS"
        case .mac: "macOS"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - Device Token

struct DeviceToken: Codable, Sendable {
    let createdAtMs: Int?
    let lastUsedAtMs: Int?
    let role: String?
    let scopes: [String]?
}

// MARK: - Response Wrapper

struct LinkedDevicesResponse: Codable {
    let paired: [LinkedDevice]?
}
