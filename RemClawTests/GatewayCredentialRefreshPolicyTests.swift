import Foundation
import Testing
@testable import RemClaw

struct GatewayCredentialRefreshPolicyTests {
    @Test func successfulRefreshClearsStaleVoiceKeyAndDoesNotRetainLegacyDTOField() throws {
        let data = Data(
            """
            {
              "gatewayUrl": "https://remclaw-user.fly.dev",
              "gatewayToken": "gateway-token",
              "hostingProvider": "fly",
              "elevenLabsApiKey": "legacy-org-secret"
            }
            """.utf8
        )
        var staleVoiceKey: String? = "legacy-org-secret"

        let response = try GatewayCredentialRefreshPolicy.decodeAndScrubLegacyVoiceKey(
            data: data,
            scrubLegacyVoiceKey: { staleVoiceKey = nil }
        )

        #expect(staleVoiceKey == nil)
        #expect(response == GatewayCredentialsResponse(
            gatewayUrl: "https://remclaw-user.fly.dev",
            gatewayToken: "gateway-token",
            hostingProvider: "fly"
        ))
        #expect(!Mirror(reflecting: response).children.contains { $0.label == "elevenLabsApiKey" })
    }

    @Test func scrubFailurePreventsCredentialRefreshFromSucceeding() {
        struct ScrubFailure: Error {}
        let data = Data(
            #"{"gatewayUrl":"https://remclaw-user.fly.dev","gatewayToken":"token","hostingProvider":"fly"}"#.utf8
        )

        #expect(throws: ScrubFailure.self) {
            _ = try GatewayCredentialRefreshPolicy.decodeAndScrubLegacyVoiceKey(
                data: data,
                scrubLegacyVoiceKey: { throw ScrubFailure() }
            )
        }
    }

    @Test func bothAuthenticatedCredentialRefreshPathsUseTheScrubbingDTO() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let authService = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "RemClaw/Sources/Services/Auth/RemAuthService.swift"
            ),
            encoding: .utf8
        )
        let gatewaySession = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "RemClaw/Sources/Gateway/GatewaySessionManager.swift"
            ),
            encoding: .utf8
        )

        #expect(authService.contains("GatewayCredentialRefreshPolicy.decodeAndScrubLegacyVoiceKey"))
        #expect(gatewaySession.contains("GatewayCredentialRefreshPolicy.decodeAndScrubLegacyVoiceKey"))
        #expect(!authService.contains("let elevenLabsApiKey"))
        #expect(!gatewaySession.contains("credentials.elevenLabsApiKey"))
    }
}
