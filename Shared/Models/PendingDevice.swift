import Foundation
import OpenClawKit

// MARK: - Pending pairing error classification

enum DevicePairingErrorClassifier {
    /// Whether a `device.pair.approve` / `device.pair.reject` failure is just a
    /// stale / already-resolved pairing request rather than a real error.
    ///
    /// The gateway returns `[INVALID_REQUEST] unknown requestId`
    /// (`openclaw/src/gateway/server-methods/devices.ts`) when the pending entry
    /// no longer exists — because the backend auto-approve
    /// (`requestAutoApprove()` → `POST /approve-device`, which approves *all*
    /// pending requests whenever the node session hits `.pairingRequired`)
    /// already consumed it, the user resolved it on another surface, or the
    /// originating connection dropped and the gateway retired the request.
    ///
    /// Classifies on the structured `GatewayResponseError.code` + `.message`
    /// (Decision Principle 5: structured signals over string parsing) rather
    /// than substring-matching a localized description.
    static func isStaleRequest(_ error: Error) -> Bool {
        guard let responseError = error as? GatewayResponseError else { return false }
        guard responseError.code == "INVALID_REQUEST" else { return false }
        return responseError.message.lowercased().contains("unknown requestid")
    }
}

// MARK: - Pending Device Model

/// A device awaiting pairing approval from the gateway's `device.pair.list` response.
/// The gateway returns pending devices separately from paired devices.
struct PendingDevice: Codable, Identifiable, Sendable {
    let requestId: String
    let deviceId: String
    let displayName: String?

    var id: String { requestId }

    /// Human-readable name for the pending device.
    var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return "Device \(String(deviceId.prefix(8)))"
    }

    /// Inferred platform based on display name heuristics.
    var inferredPlatform: DevicePlatform {
        guard let displayName else { return .unknown }
        let lower = displayName.lowercased()
        if lower.contains("mac") || lower.contains("imac") || lower.contains("macbook") { return .mac }
        if lower.contains("iphone") || lower.contains("ipad") { return .iOS }
        return .unknown
    }
}

// MARK: - Response wrapper

/// Wraps the `device.pair.list` response which includes both paired and pending arrays.
struct PendingDevicesResponse: Codable {
    let pending: [PendingDevice]?
}
