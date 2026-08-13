import Foundation
import Testing
@testable import RemClaw

@Suite("Pairing recovery source contract")
struct PairingRecoverySourceContractTests {
    @Test func usesOnePairedDevicesDestinationAndCloudApprovalAction() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recovery = try read("Shared/Views/Gateway/SharedGatewayRecoveryDestinationView.swift", from: projectRoot)
        let pairing = try read("Shared/Views/Gateway/SharedGatewayDeviceConnectionsView.swift", from: projectRoot)
        let detail = try read("Shared/Views/Gateway/SharedGatewayDetailView.swift", from: projectRoot)
        let session = try read("RemClaw/Sources/Gateway/GatewaySessionManager.swift", from: projectRoot)

        #expect(recovery.contains("State(initialValue: gateway.connectionState.needsDeviceRePair)"))
        #expect(recovery.contains("if showsPairingRecovery"))
        #expect(recovery.contains("SharedGatewayDevicePairingScreen("))
        #expect(pairing.contains("gateway.requestPairingApproval(config: config)"))
        #expect(pairing.contains("config?.provider == .fly && gateway.supportsExplicitPairingApproval"))
        #expect(pairing.contains(".remPrimaryActionButton()"))
        #expect(pairing.contains("keepsApprovalCardVisible: keepsApprovalCardVisible"))
        #expect(pairing.contains(".navigationTitle(\"Paired Devices\")"))
        #expect(pairing.components(separatedBy: "Text(\"Pending Connections\")").count - 1 == 2)
        #expect(!pairing.contains("Pending Machine Connection"))
        #expect(!pairing.contains("!gateway.isLoadingPendingDevices"))
        #expect(detail.contains("Text(\"Paired Devices\")"))
        #expect(!detail.contains("gateway.requestPairingApproval"))
        #expect(!detail.contains("Approve This Device"))
        #expect(session.contains("guard approval.isSuccess else"))
        #expect(session.contains("if await waitForConnectionAfterPairingApproval(after: baselineGeneration)"))
        #expect(session.contains("Connection complete. Rem is connected to your gateway."))
        #expect(session.contains("requestAutoApprove(allowOneRetry: false)"))
        #expect(!session.contains("Still try to reconnect — the device might have been approved already"))
    }

    @MainActor
    @Test func staleConnectedStateCannotCompleteANewApprovalAttempt() async {
        let completed = await RemGatewaySessionManager.waitForPairingApprovalConnection(
            after: 7,
            timeoutSeconds: 0.02,
            pollInterval: .milliseconds(5)
        ) { (7, true, true) }

        #expect(completed == false)
    }

    @Test func approvalCardStaysVisibleUntilNodeAndOperatorAreReady() {
        #expect(GatewayApprovalRecoveryCardPolicy.shouldRemainVisible(
            enteredForApprovalRecovery: true,
            supportsManagedApproval: true,
            nodeConnected: true,
            operatorReady: false
        ))
        #expect(!GatewayApprovalRecoveryCardPolicy.shouldRemainVisible(
            enteredForApprovalRecovery: true,
            supportsManagedApproval: true,
            nodeConnected: true,
            operatorReady: true
        ))
    }

    @Test func managedPartialRecoveryIsRestoredOnReentry() {
        #expect(GatewayApprovalRecoveryCardPolicy.shouldRemainVisible(
            enteredForApprovalRecovery: false,
            supportsManagedApproval: true,
            nodeConnected: true,
            operatorReady: false
        ))
        #expect(!GatewayApprovalRecoveryCardPolicy.shouldRemainVisible(
            enteredForApprovalRecovery: false,
            supportsManagedApproval: false,
            nodeConnected: true,
            operatorReady: false
        ))
    }

    @MainActor
    @Test func delayedNewNodeAndOperatorConnectionCompletesApproval() async {
        var snapshot = (generation: 7, nodeConnected: true, operatorReady: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            snapshot = (generation: 8, nodeConnected: true, operatorReady: false)
            try? await Task.sleep(for: .milliseconds(20))
            snapshot = (generation: 8, nodeConnected: true, operatorReady: true)
        }

        let completed = await RemGatewaySessionManager.waitForPairingApprovalConnection(
            after: 7,
            timeoutSeconds: 1.0,
            pollInterval: .milliseconds(5)
        ) { snapshot }

        #expect(completed == true)
    }

    private func read(_ relativePath: String, from projectRoot: URL) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
