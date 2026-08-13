import Testing
import Foundation
import OpenClawKit
@testable import RemClaw

@Suite("Device pairing error classifier")
struct DevicePairingErrorClassifierTests {
    @Test func unknownRequestIdIsStale() {
        // Mirrors the gateway response from
        // openclaw/src/gateway/server-methods/devices.ts when the pending
        // pairing entry has already been consumed/retired.
        let error = GatewayResponseError(
            method: "device.pair.approve",
            code: "INVALID_REQUEST",
            message: "unknown requestId",
            details: nil
        )
        #expect(DevicePairingErrorClassifier.isStaleRequest(error))
    }

    @Test func unknownRequestIdIsCaseInsensitive() {
        let error = GatewayResponseError(
            method: "device.pair.reject",
            code: "INVALID_REQUEST",
            message: "Unknown RequestID",
            details: nil
        )
        #expect(DevicePairingErrorClassifier.isStaleRequest(error))
    }

    @Test func differentInvalidRequestMessageIsNotStale() {
        // A real validation failure (e.g. ownership mismatch) must still surface.
        let error = GatewayResponseError(
            method: "device.pair.approve",
            code: "INVALID_REQUEST",
            message: "approval denied: this request belongs to a different device",
            details: nil
        )
        #expect(!DevicePairingErrorClassifier.isStaleRequest(error))
    }

    @Test func nonInvalidRequestCodeIsNotStale() {
        let error = GatewayResponseError(
            method: "device.pair.approve",
            code: "FORBIDDEN",
            message: "unknown requestId",
            details: nil
        )
        #expect(!DevicePairingErrorClassifier.isStaleRequest(error))
    }

    @Test func nonGatewayErrorIsNotStale() {
        let error = NSError(domain: "Gateway", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "not connected",
        ])
        #expect(!DevicePairingErrorClassifier.isStaleRequest(error))
    }
}
