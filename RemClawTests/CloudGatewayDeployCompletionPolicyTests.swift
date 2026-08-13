import Testing
@testable import RemClaw

@Suite("Cloud gateway deploy completion policy")
struct CloudGatewayDeployCompletionPolicyTests {
    @Test func completeStatusWithCredentialsConfiguresCloudGateway() {
        let decision = CloudGatewayDeployStatusDecision.resolve(.init(
            phase: "complete",
            message: "Gateway ready",
            gatewayUrl: "https://remclaw-00000000.fly.dev",
            gatewayToken: "gateway-token"
        ))

        guard case .configure(let config) = decision else {
            Issue.record("Expected configure decision, got \(decision)")
            return
        }

        #expect(config.url == "https://remclaw-00000000.fly.dev")
        #expect(config.token == "gateway-token")
        #expect(config.provider == .fly)
        #expect(config.displayName == "Cloud Gateway")
        #expect(config.isActive)
    }

    @Test func completeStatusWithoutCredentialsDoesNotConfigureGateway() {
        let missingToken = CloudGatewayDeployStatusDecision.resolve(.init(
            phase: "complete",
            message: "Gateway ready",
            gatewayUrl: "https://remclaw-00000000.fly.dev",
            gatewayToken: nil
        ))
        let missingURL = CloudGatewayDeployStatusDecision.resolve(.init(
            phase: "complete",
            message: "Gateway ready",
            gatewayUrl: nil,
            gatewayToken: "gateway-token"
        ))

        #expect(missingToken == .missingCredentials)
        #expect(missingURL == .missingCredentials)
    }

    @Test func failedAndInProgressStatusesResolveWithoutCredentials() {
        let failed = CloudGatewayDeployStatusDecision.resolve(.init(
            phase: "failed",
            message: "Fly deploy failed",
            gatewayUrl: nil,
            gatewayToken: nil
        ))
        let inProgress = CloudGatewayDeployStatusDecision.resolve(.init(
            phase: "waiting_for_healthy",
            message: "Waiting for server to start...",
            gatewayUrl: "https://remclaw-00000000.fly.dev",
            gatewayToken: nil
        ))

        #expect(failed == .failed("Fly deploy failed"))
        #expect(inProgress == .continuePolling)
    }

    @Test func connectionDecisionPreservesDeployedButNotConnectedRecoveryCopy() throws {
        #expect(CloudGatewayDeployConnectionDecision.resolve(.connected) == .complete)

        let approvalDecision = CloudGatewayDeployConnectionDecision.resolve(.pairingRequired)
        guard case .notReady(let approvalMessage) = approvalDecision else {
            Issue.record("Expected not-ready approval decision, got \(approvalDecision)")
            return
        }
        #expect(approvalMessage.contains("waiting for approval"))
        #expect(approvalMessage.contains("Do not deploy another cloud gateway yet"))

        let unreachableDecision = CloudGatewayDeployConnectionDecision.resolve(.unreachable("connect failed"))
        guard case .notReady(let unreachableMessage) = unreachableDecision else {
            Issue.record("Expected not-ready unreachable decision, got \(unreachableDecision)")
            return
        }
        #expect(unreachableMessage.contains("could not connect"))
        #expect(unreachableMessage.contains("Do not deploy another cloud gateway yet"))
    }
}
