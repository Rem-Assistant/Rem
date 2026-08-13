import Foundation
import Testing
@testable import RemClaw

@Suite("Cloud gateway deploy client decoding")
struct CloudGatewayDeployClientDecodingTests {
    @Test func inProgressStatusDecodesRedactedGatewayToken() throws {
        let status = try decodeStatusWrapper("""
        {
          "status": {
            "phase": "waiting_for_healthy",
            "message": "Waiting for server to start...",
            "gatewayUrl": "https://remclaw-00000000.fly.dev",
            "gatewayToken": null
          }
        }
        """)

        #expect(status.phase == "waiting_for_healthy")
        #expect(status.message == "Waiting for server to start...")
        #expect(status.gatewayUrl == "https://remclaw-00000000.fly.dev")
        #expect(status.gatewayToken == nil)
    }

    @Test func completeStatusDecodesGatewayCredentials() throws {
        let status = try decodeStatusWrapper("""
        {
          "status": {
            "phase": "complete",
            "message": "Gateway ready",
            "gatewayUrl": "https://remclaw-00000000.fly.dev",
            "gatewayToken": "gateway-token"
          }
        }
        """)

        #expect(status.phase == "complete")
        #expect(status.gatewayUrl == "https://remclaw-00000000.fly.dev")
        #expect(status.gatewayToken == "gateway-token")
    }

    @Test func startDeployResponseDecodesInitialStatus() throws {
        let data = try #require("""
        {
          "deployId": "deploy-1",
          "status": {
            "phase": "creating_project",
            "message": "Creating Fly app...",
            "gatewayUrl": null,
            "gatewayToken": null
          }
        }
        """.data(using: .utf8))

        let response = try JSONDecoder().decode(
            CloudGatewayDeployClient.DeployResponse.self,
            from: data
        )

        #expect(response.deployId == "deploy-1")
        #expect(response.status.phase == "creating_project")
        #expect(response.status.gatewayUrl == nil)
        #expect(response.status.gatewayToken == nil)
    }

    private func decodeStatusWrapper(_ json: String) throws -> CloudGatewayDeployClient.StatusResponse {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(
            CloudGatewayDeployClient.StatusWrapper.self,
            from: data
        ).status
    }
}
