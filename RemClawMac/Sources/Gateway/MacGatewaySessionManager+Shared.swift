import Foundation
import OpenClawKit

// MARK: - GatewaySessionProviding conformance for macOS

/// Makes `MacGatewaySessionManager` usable with shared settings views.
extension MacGatewaySessionManager: GatewaySessionProviding {
    var authenticatedAccountIDForRecovery: String? {
        VoiceConfigurationAccountIdentity.accountID(fromJWT: backendToken)
    }

    func fetchGatewayUpdateReadiness() async throws -> GatewayUpdateReadiness? {
        let response: GatewayUpdateReadinessResponse = try await MacAuthenticatedHttpClient.get(
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

    func makeVoiceConfigurationRecoveryRequest() -> VoiceConfigurationRecoveryRequest? {
        guard let token = backendToken,
              let accountID = VoiceConfigurationAccountIdentity.accountID(fromJWT: token)
        else { return nil }
        return VoiceConfigurationRecoveryRequest(accountID: accountID) {
            try await MacAuthenticatedHttpClient.postBoundToAccount(
                "/api/v1/gateway/voice/reconcile",
                bearerToken: token,
                accountID: accountID,
                timeout: VoiceConfigurationRecoveryRequestPolicy.timeoutSeconds
            )
        }
    }

    func loadRuntimeConfiguredProviderIDs(candidateProviderIDs: [String]) async throws -> [String] {
        // The active runtime is the only authority for usable authentication on every route,
        // including a local upstream gateway. Reading auth-profiles.json would miss env/config,
        // AWS SDK, and synthetic auth while accepting expired or unresolved credentials.
        return try await requestRuntimeConfiguredProviderIDs(
            candidateProviderIDs: candidateProviderIDs
        )
    }
}
