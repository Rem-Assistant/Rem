import CryptoKit
import Foundation
import OpenClawKit

/// Shared helpers for node invocation handlers.
enum InvocationHelpers {

    // MARK: - Date Parsing

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return iso8601WithFractional.date(from: raw) ?? iso8601NoFractional.date(from: raw)
    }

    static func formatISODate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return iso8601WithFractional.string(from: date)
    }

    // MARK: - Param Decoding

    static func decodeParams<T: Decodable>(_ req: BridgeInvokeRequest) -> T? {
        guard let json = req.paramsJSON,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Derives a deterministic UUID from the gateway invocation identity. Mutating node
    /// calls may be redelivered after an acknowledgement is lost; using the same resource
    /// id lets the backend reconcile that retry by id rather than guessing by name.
    static func stableResourceID(for req: BridgeInvokeRequest, namespace: String) -> UUID {
        let material = Data("\(namespace)\u{0}\(req.id)".utf8)
        var bytes = Array(SHA256.hash(data: material).prefix(16))
        // RFC 9562 UUIDv8: application-defined payload plus the standard variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Response Builders

    static func encodeSuccess<T: Encodable>(_ req: BridgeInvokeRequest, _ payload: T) -> BridgeInvokeResponse {
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return error(req, "failed to encode response")
        }
        return BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: json)
    }

    // MARK: - Terminal vs retryable errors (R2-A / #811)
    //
    // Unknown-command, permission-denied, and not-implemented are TERMINAL:
    // re-issuing the exact same call can never succeed, so we set the
    // structured `retryable: false` signal the agent loop should read
    // (principle 5: structured signals over string parsing) AND spell it out
    // in the message ("Do not retry"). Bad params / generic failures stay
    // unmarked (`retryable` defaults to nil) so the agent may legitimately fix
    // inputs and retry.

    /// The command is not in the connected device's handler registry — the
    /// tool does not exist here. Terminal.
    static func unknownCommand(_ req: BridgeInvokeRequest, _ command: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(
            id: req.id,
            ok: false,
            error: OpenClawNodeError(
                code: .invalidRequest,
                message: "UNKNOWN_COMMAND: '\(command)' does not exist on the connected device. Do not retry.",
                retryable: false))
    }

    /// The capability exists but the user has not granted the required
    /// permission. Terminal until the user grants access in Settings.
    static func permissionDenied(_ req: BridgeInvokeRequest, _ message: String) -> BridgeInvokeResponse {
        // TODO(#807): also surface a `RemContextualMessage` banner nudging the
        // user to grant access. That shared component isn't on this branch yet
        // (lands with #807) — wire it here once it merges.
        BridgeInvokeResponse(
            id: req.id,
            ok: false,
            error: OpenClawNodeError(
                code: .unavailable,
                message: "PERMISSION_DENIED: \(message) Do not retry; ask the user to grant access.",
                retryable: false))
    }

    static func unavailable(_ req: BridgeInvokeRequest, _ message: String) -> BridgeInvokeResponse {
        // Terminal: an unavailable / not-implemented capability won't appear on
        // retry (R2-A / #811).
        BridgeInvokeResponse(
            id: req.id,
            ok: false,
            error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: \(message)", retryable: false))
    }

    static func invalidParams(_ req: BridgeInvokeRequest, _ message: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(
            id: req.id,
            ok: false,
            error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: \(message)"))
    }

    static func error(_ req: BridgeInvokeRequest, _ message: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(
            id: req.id,
            ok: false,
            error: OpenClawNodeError(code: .invalidRequest, message: "ERROR: \(message)"))
    }

    static func permissionOrError(_ req: BridgeInvokeRequest, _ error: any Error) -> BridgeInvokeResponse {
        let message = error.localizedDescription
        let isPermission = message.lowercased().contains("denied") || message.lowercased().contains("permission")
        // Permission denial is terminal (retryable: false); other errors stay
        // retryable so the agent may legitimately fix inputs and retry.
        return isPermission ? permissionDenied(req, message) : Self.error(req, message)
    }
}
