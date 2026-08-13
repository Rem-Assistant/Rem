import Foundation
import OpenClawKit

struct GatewayConfigActivationResponse: Decodable, Equatable {
    let ok: Bool
    let activated: Bool

    static func validated(data: Data, statusCode: Int) throws -> Self {
        guard (200..<300).contains(statusCode) else {
            throw GatewayConfigActivationError.backendStatus(statusCode)
        }
        let response = try JSONDecoder().decode(Self.self, from: data)
        guard response.ok, response.activated else {
            throw GatewayConfigActivationError.notActivated
        }
        return response
    }
}

enum GatewayConfigActivationError: LocalizedError, Equatable {
    case backendStatus(Int)
    case notActivated

    var errorDescription: String? {
        switch self {
        case .backendStatus(let status):
            return "Backend returned HTTP \(status)"
        case .notActivated:
            return "The gateway accepted the change but did not confirm it was active. Try again."
        }
    }
}

// MARK: - GatewaySessionProviding conformance for iOS

/// Makes `RemGatewaySessionManager` usable with shared settings views.
/// Most properties already match; this extension provides the remaining
/// protocol requirements.
extension RemGatewaySessionManager: GatewaySessionProviding {
    var sessionHealth: GatewaySessionHealthSnapshot {
        let operatorState: GatewaySessionLegState = {
            if operatorReady { return .connected }
            switch connectionState {
            case .connecting: return .connecting
            case .unauthorized: return .failed("Unauthorized")
            case .unreachable(let detail): return .failed(detail)
            default: return .disconnected
            }
        }()

        let nodeState: GatewaySessionLegState = {
            switch connectionState {
            case .connected: return .connected
            case .connecting: return .connecting
            case .pairingRequired: return .failed("Pairing approval required")
            case .unauthorized: return .failed("Unauthorized")
            case .unreachable(let detail): return .failed(detail)
            case .disconnected: return .disconnected
            }
        }()

        var manual: GatewayManualRecoveryState = .none
        if case .pairingRequired = connectionState {
            manual = .rePairRequired
        }

        return GatewaySessionHealthSnapshot.compose(
            operatorSessionState: operatorState,
            nodeSessionState: nodeState,
            gatewayProcessState: connectionState.isConnected ? .running : .unknown,
            manualRecoveryState: manual,
            detail: nodeState.detail
        )
    }

    var isAuthenticated: Bool {
        // iOS uses RemAuthService for auth state, but for the protocol
        // we check if backend credentials exist (same as Mac).
        RemCredentialStore.backendToken != nil
    }

    var activeGatewayProviderForDisplay: GatewayProvider? {
        activeGatewayProvider
    }

    var authenticatedAccountIDForRecovery: String? {
        VoiceConfigurationAccountIdentity.accountID(fromJWT: RemCredentialStore.backendToken)
    }

    func signOut() {
        clearConfiguration()
        RemCredentialStore.backendToken = nil
    }

    func configure(gatewayURL: String, gatewayToken: String) {
        configure(gatewayURL: gatewayURL, gatewayToken: gatewayToken, providerName: "Fly.io")
    }

    func configure(gatewayConfig: GatewayConfig) {
        let providerName: String
        switch gatewayConfig.provider {
        case .fly:
            providerName = "Fly.io"
        case .local:
            providerName = "Local"
        case .manual:
            providerName = gatewayConfig.provider.displayName
        }
        configure(gatewayURL: gatewayConfig.url, gatewayToken: gatewayConfig.token, providerName: providerName)
    }

    func fetchGatewayUpdateReadiness() async throws -> GatewayUpdateReadiness? {
        let response: GatewayUpdateReadinessResponse = try await AuthenticatedHttpClient.get(
            "/api/v1/gateway/update-readiness",
            timeout: 15
        )
        return response.readiness
    }

    func skillsRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        let session = await client.chatSession
        return try await session.request(
            method: method,
            paramsJSON: paramsJSON,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// POST the config merge-patch to the backend, which applies it server-side (via the gateway's
    /// setup password) AND restarts the gateway so startup-resolved config (like the browser SSRF
    /// policy) actually takes effect. Body shape: `{ "config": <patch> }` — see
    /// backend/src/routes/gateway.routes.ts `POST /patch-config`.
    func patchGatewayConfigViaBackendAndRestart(configPatchJSON: String) async throws {
        let body = Data("{\"config\":\(configPatchJSON)}".utf8)
        let (data, http) = try await AuthenticatedHttpClient.request(
            path: "/api/v1/patch-config",
            method: "POST",
            body: body,
            timeout: 120
        )
        _ = try GatewayConfigActivationResponse.validated(data: data, statusCode: http.statusCode)
    }

    func makeVoiceConfigurationRecoveryRequest() -> VoiceConfigurationRecoveryRequest? {
        guard let token = RemCredentialStore.backendToken,
              let accountID = VoiceConfigurationAccountIdentity.accountID(fromJWT: token)
        else { return nil }
        return VoiceConfigurationRecoveryRequest(accountID: accountID) {
            try await AuthenticatedHttpClient.postBoundToAccount(
                "/api/v1/gateway/voice/reconcile",
                bearerToken: token,
                accountID: accountID,
                timeout: VoiceConfigurationRecoveryRequestPolicy.timeoutSeconds
            )
        }
    }
}
