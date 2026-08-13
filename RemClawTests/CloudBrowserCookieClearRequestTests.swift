import Foundation
import Testing
@testable import RemClaw

@Suite("Cloud browser cookie clearing")
struct CloudBrowserCookieClearRequestTests {
    @Test("Uses upstream browser.request clear-all-cookies route")
    func requestEnvelopeMatchesUpstream() throws {
        let json = try CloudBrowserCookieClearRequest.encodedParameters()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(object["body"] as? [String: Any])

        #expect(object["method"] as? String == "POST")
        #expect(object["path"] as? String == "/cookies/clear")
        #expect(body.isEmpty)
    }

    @Test("Does not narrow clearing to one tab, site, or alternate profile")
    func requestClearsManagedProfileContext() throws {
        let json = try CloudBrowserCookieClearRequest.encodedParameters()
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(object["body"] as? [String: Any])

        #expect(object["query"] == nil)
        #expect(body["targetId"] == nil)
        #expect(body["url"] == nil)
        #expect(body["domain"] == nil)
    }
}
