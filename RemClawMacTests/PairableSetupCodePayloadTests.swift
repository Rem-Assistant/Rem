#if os(macOS)
import Foundation
import XCTest
@testable import RemClawMac

final class PairableSetupCodePayloadTests: XCTestCase {
    func testDecodePreservesUpstreamQrFields() throws {
        let data = Data("""
        {
          "setupCode": "rem://setup/example",
          "gatewayUrl": "http://rem.local:18789",
          "auth": "bootstrap",
          "urlSource": "lan"
        }
        """.utf8)

        let payload = try PairableSetupCodePayload.decode(data).get()

        XCTAssertEqual(payload.setupCode, "rem://setup/example")
        XCTAssertEqual(payload.gatewayUrl, "http://rem.local:18789")
        XCTAssertEqual(payload.auth, "bootstrap")
        XCTAssertEqual(payload.urlSource, "lan")
    }

    func testDecodeRequiresSetupCode() {
        let data = Data("""
        {
          "gatewayUrl": "http://rem.local:18789",
          "auth": "bootstrap",
          "urlSource": "lan"
        }
        """.utf8)

        switch PairableSetupCodePayload.decode(data) {
        case .success:
            XCTFail("Expected missing setupCode to fail decoding")
        case .failure:
            break
        }
    }
}
#endif
