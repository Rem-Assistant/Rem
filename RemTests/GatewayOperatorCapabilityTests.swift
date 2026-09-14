import Testing
import RemKit
@testable import Rem

struct GatewayOperatorCapabilityTests {
    @Test func operatorHandshakeRequestsLiveToolEvents() {
        let options = RemGatewayClient.operatorConnectOptions(displayName: "Test iPhone")

        #expect(options.role == "operator")
        #expect(options.clientMode == "ui")
        #expect(options.caps == ["tool-events"])
        #expect(options.scopes.contains("operator.admin"))
        #expect(options.includeDeviceIdentity)
    }

    @Test func bootstrapReconnectCanOmitDeviceIdentityWithoutDroppingToolEvents() {
        let options = RemGatewayClient.operatorConnectOptions(
            displayName: "Test iPhone",
            includeDeviceIdentity: false
        )

        #expect(options.caps == ["tool-events"])
        #expect(!options.includeDeviceIdentity)
    }
}
