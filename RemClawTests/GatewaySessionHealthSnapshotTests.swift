import Testing
@testable import RemClaw

struct GatewaySessionHealthSnapshotTests {

    @Test func composeAddsApprovalRecoveryHints() {
        let snapshot = GatewaySessionHealthSnapshot.compose(
            operatorSessionState: .connected,
            nodeSessionState: .failed("pairing required"),
            gatewayProcessState: .running,
            manualRecoveryState: .approvalRequired,
            detail: "pairing required"
        )

        #expect(snapshot.recoveryHints.contains(.openApprovalsList))
        #expect(snapshot.recoveryHints.contains(.rePairThisDevice))
        #expect(!snapshot.recoveryHints.contains(.restartLocalGateway))
        #expect(snapshot.operatorUsable)
    }

    @Test func composeAddsNodeRetryHints() {
        let snapshot = GatewaySessionHealthSnapshot.compose(
            operatorSessionState: .connected,
            nodeSessionState: .failed("node offline"),
            gatewayProcessState: .running,
            manualRecoveryState: .nodeRetryRequired,
            detail: "node offline"
        )

        #expect(snapshot.recoveryHints.contains(.retryNodeConnection))
        #expect(snapshot.recoveryHints.contains(.rePairThisDevice))
        #expect(snapshot.operatorUsable)
    }

    @Test func composeAddsReconnectWhenOperatorDown() {
        let snapshot = GatewaySessionHealthSnapshot.compose(
            operatorSessionState: .disconnected,
            nodeSessionState: .failed("not connected"),
            gatewayProcessState: .unknown,
            manualRecoveryState: .none,
            detail: nil
        )

        #expect(snapshot.recoveryHints.contains(.reconnect))
        #expect(!snapshot.operatorUsable)
    }

    @Test func composeAddsRestartHintWhenProcessUnavailable() {
        let failedSnapshot = GatewaySessionHealthSnapshot.compose(
            operatorSessionState: .connected,
            nodeSessionState: .failed("node offline"),
            gatewayProcessState: .failed("connection refused"),
            manualRecoveryState: .nodeRetryRequired,
            detail: "connection refused"
        )
        #expect(failedSnapshot.recoveryHints.contains(.restartLocalGateway))

        let stoppedSnapshot = GatewaySessionHealthSnapshot.compose(
            operatorSessionState: .connected,
            nodeSessionState: .failed("node offline"),
            gatewayProcessState: .stopped,
            manualRecoveryState: .nodeRetryRequired,
            detail: nil
        )
        #expect(stoppedSnapshot.recoveryHints.contains(.restartLocalGateway))
    }
}
