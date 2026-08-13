import Foundation
import Testing
@testable import RemClaw

struct TalkSessionBindingPayloadTests {
    @Test func encodesTheStructuredNativeNodeBindingExpectedByOpenClaw() throws {
        let payload = TalkSessionBindingPayload(
            key: "agent:main:rem-ios-test",
            verboseLevel: "on",
            execNode: "native-device-id"
        )

        let encoded = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])

        #expect(object == [
            "key": "agent:main:rem-ios-test",
            "verboseLevel": "on",
            "execNode": "native-device-id",
        ])
    }
}
