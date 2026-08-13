import Foundation
import OpenClawKit

// MARK: - Pairing failure classification (#306 Pairing recovery UX epic)

/// Classifies a gateway connect/disconnect failure into a pairing-failure
/// bucket so callers can pick auto-recovery vs user-tap recovery per the
/// epic rule:
///
/// - **Auto-recover** (deterministic, we caused the mismatch): `scopeUpgrade`,
///   `roleUpgrade`, `metadataUpgrade`, `signatureExpired` → call
///   `resetPairing()` immediately, show "Re-pairing…"
/// - **User-tap recover** (gateway no longer trusts this device):
///   `signatureInvalid`, `deviceIdMismatch`, `deviceTokenMismatch`,
///   `publicKeyInvalid`, `nonceMismatch` → show a CTA so the user
///   knows something security-meaningful happened.
/// - **Unknown** → fall back to existing behavior (auto-approve / reconnect)
///
/// **Source of truth.** Classification delegates to the upstream
/// `GatewayConnectionProblemMapper` (in OpenClawKit), which reads
/// `GatewayConnectAuthError.detail` (typed `DEVICE_AUTH_*` code) and
/// `detailsReason` ("scope-upgrade" / "role-upgrade" / "metadata-upgrade").
/// We never substring-match `error.localizedDescription` for control flow —
/// the gateway only puts the human message there; structured fields go via
/// the typed error.
///
/// **String fallback.** A `from(reasonString:)` path exists only for
/// post-connect transport drops where `disconnectHandler(_ reason: String)`
/// is the only signal. It returns `.unknown` aggressively rather than
/// guessing, so trust-revocation reasons that arrive only as strings stay
/// in the safe fallback path instead of triggering an auto-reset.
///
/// Originally defined in `RemClaw/Sources/Gateway/GatewayClient.swift` for
/// iOS use only (#306). Moved to Shared for #320 (Widen Mac operator scope
/// to operator.admin) so the Mac session manager can consume the same
/// classifier — the Mac needs the auto-re-pair path to handle scope-upgrade
/// when existing installs first reconnect with the wider scope set.
enum GatewayPairingFailure: Equatable {
    case scopeUpgrade
    case roleUpgrade
    case metadataUpgrade
    case signatureExpired
    case signatureInvalid
    case deviceIdMismatch
    case deviceTokenMismatch
    case publicKeyInvalid
    case nonceMismatch
    case unknown

    /// Classify a thrown connect error using the upstream typed mapper.
    /// Returns `.unknown` if the error isn't a recognized auth / response
    /// problem (e.g. transport / timeout).
    static func classify(error: Error?) -> GatewayPairingFailure {
        guard let error else { return .unknown }
        guard let problem = GatewayConnectionProblemMapper.map(error: error) else {
            return .unknown
        }
        return Self.from(problemKind: problem.kind)
    }

    /// Map an upstream `GatewayConnectionProblem.Kind` to our local bucket.
    /// Public for the unit tests under `RemClawTests/`.
    static func from(problemKind kind: GatewayConnectionProblem.Kind) -> GatewayPairingFailure {
        switch kind {
        case .pairingScopeUpgradeRequired: .scopeUpgrade
        case .pairingRoleUpgradeRequired: .roleUpgrade
        case .pairingMetadataUpgradeRequired: .metadataUpgrade
        case .deviceSignatureExpired: .signatureExpired
        case .deviceSignatureInvalid: .signatureInvalid
        case .deviceIdMismatch: .deviceIdMismatch
        case .deviceTokenMismatch: .deviceTokenMismatch
        case .devicePublicKeyInvalid: .publicKeyInvalid
        case .deviceNonceMismatch: .nonceMismatch
        default: .unknown
        }
    }

    /// Conservative string-only fallback for cases where we ONLY have the
    /// disconnect reason (post-connect transport drops). Matches a small set
    /// of unambiguous DEVICE_AUTH_* code substrings plus exact human messages
    /// observed from OpenClaw disconnect reasons — anything ambiguous returns
    /// `.unknown` so we don't trigger auto-recovery on guesses.
    ///
    /// Notably this does NOT classify `.scopeUpgrade` / `.roleUpgrade` /
    /// `.metadataUpgrade` / `.deviceIdMismatch` / `.deviceTokenMismatch` —
    /// those only arrive via `details.reason` on the structured error and
    /// should never reach this fallback. If they do, falling through to
    /// `.unknown` is the right behavior (we'll let the existing auto-approve
    /// loop handle it instead of clearing tokens on a guess).
    static func from(reasonString reason: String?) -> GatewayPairingFailure {
        guard let reason, !reason.isEmpty else { return .unknown }
        let lower = reason.lowercased()
        // The gateway includes the DEVICE_AUTH_* code in some formatted
        // strings; match the unambiguous ones only.
        if lower.contains("device_auth_signature_expired") {
            return .signatureExpired
        }
        if lower.contains("device_auth_signature_invalid") {
            return .signatureInvalid
        }
        if lower == "device signature invalid" ||
            lower.hasSuffix(": device signature invalid") {
            return .signatureInvalid
        }
        return .unknown
    }

    /// True when this failure mode is deterministic and consent-preserving —
    /// we widened scopes / role / metadata, or a token TTL expired. Auto-re-pair is safe.
    var isAutoRecoverable: Bool {
        switch self {
        case .scopeUpgrade, .roleUpgrade, .metadataUpgrade, .signatureExpired: true
        default: false
        }
    }

    /// True when the gateway no longer trusts this device (revoked, mismatched
    /// device-id, mismatched token, invalid signature/key/nonce). Show a
    /// user-tap CTA so the user knows something security-meaningful happened.
    var isTrustRevocation: Bool {
        switch self {
        case .signatureInvalid, .deviceIdMismatch, .deviceTokenMismatch,
             .publicKeyInvalid, .nonceMismatch: true
        default: false
        }
    }

    /// Short label for telemetry properties.
    var telemetryValue: String {
        switch self {
        case .scopeUpgrade: "scope_upgrade"
        case .roleUpgrade: "role_upgrade"
        case .metadataUpgrade: "metadata_upgrade"
        case .signatureExpired: "signature_expired"
        case .signatureInvalid: "signature_invalid"
        case .deviceIdMismatch: "device_id_mismatch"
        case .deviceTokenMismatch: "device_token_mismatch"
        case .publicKeyInvalid: "public_key_invalid"
        case .nonceMismatch: "nonce_mismatch"
        case .unknown: "unknown"
        }
    }
}
