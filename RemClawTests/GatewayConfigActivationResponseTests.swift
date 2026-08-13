import Foundation
import Testing
@testable import RemClaw

@Suite("Gateway config activation acknowledgement")
struct GatewayConfigActivationResponseTests {
    @Test("Accepts only a successful activated readback")
    func acceptsActivatedReadback() throws {
        let data = Data(#"{"ok":true,"activated":true}"#.utf8)
        let response = try GatewayConfigActivationResponse.validated(data: data, statusCode: 200)
        #expect(response == GatewayConfigActivationResponse(ok: true, activated: true))
    }

    @Test("Rejects the legacy immediate restarting acknowledgement")
    func rejectsLegacyImmediateAcknowledgement() {
        let data = Data(#"{"ok":true,"restarting":true}"#.utf8)
        #expect(throws: Error.self) {
            _ = try GatewayConfigActivationResponse.validated(data: data, statusCode: 200)
        }
    }

    @Test("Rejects a response that explicitly says activation is incomplete")
    func rejectsInactiveResponse() {
        let data = Data(#"{"ok":true,"activated":false}"#.utf8)
        #expect(throws: GatewayConfigActivationError.notActivated) {
            _ = try GatewayConfigActivationResponse.validated(data: data, statusCode: 200)
        }
    }
}
