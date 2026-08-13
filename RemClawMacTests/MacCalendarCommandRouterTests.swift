#if os(macOS)
import Foundation
import OpenClawKit
import XCTest
@testable import RemClawMac

@MainActor
final class MacCalendarCommandRouterTests: XCTestCase {
    override func tearDown() {
        MacNodeInvocationRouter.resetCalendarServiceForTesting()
        MacNodeInvocationRouter.resetBrowserOpenForTesting()
        super.tearDown()
    }

    func testEventsCommandReturnsPayload() async throws {
        let service = StubCalendarService()
        service.events = [
            CalendarEventPayload(
                eventId: "evt-1",
                title: "Planning",
                startDate: "2026-05-10T17:00:00.000Z",
                endDate: "2026-05-10T17:30:00.000Z",
                durationMinutes: 30,
                isAllDay: false,
                calendarName: "Work"
            )
        ]
        MacNodeInvocationRouter.configureCalendarServiceForTesting(service)

        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "events", command: "calendar.events", paramsJSON: "{}")
        )

        XCTAssertTrue(response.ok)
        let payload: CalendarEventsResponse = try decodePayload(response)
        XCTAssertEqual(payload.events.map(\.title), ["Planning"])
    }

    func testAddCommandRequiresTitleAndStartDate() async {
        MacNodeInvocationRouter.configureCalendarServiceForTesting(StubCalendarService())

        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "add", command: "calendar.add", paramsJSON: "{}")
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .invalidRequest)
        XCTAssertEqual(response.error?.message.contains("calendar.add requires title and startDate"), true)
    }

    func testPermissionDeniedSurfacesClearCalendarError() async {
        let service = StubCalendarService()
        service.fetchError = MacCalendarGatewayError.permissionDenied
        MacNodeInvocationRouter.configureCalendarServiceForTesting(service)

        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "events", command: "calendar.events", paramsJSON: "{}")
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertEqual(response.error?.message.contains("Calendar access denied"), true)
        XCTAssertEqual(response.error?.message.contains("System Settings"), true)
    }

    func testReadOnlyCalendarSurfacesActionableWriteError() async throws {
        let service = StubCalendarService()
        service.updateError = MacCalendarGatewayError.readOnly("This event belongs to a read-only Calendar.")
        MacNodeInvocationRouter.configureCalendarServiceForTesting(service)

        let params = MacCalendarUpdateParams(
            eventId: "evt-readonly",
            title: "New title",
            startDate: nil,
            endDate: nil,
            durationMinutes: nil,
            notes: nil,
            calendarName: nil,
            isAllDay: nil
        )
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "update", command: "calendar.update", paramsJSON: try encode(params))
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertEqual(response.error?.message.contains("read-only Calendar"), true)
    }

    func testDeleteCommandSurfacesFullAccessRequirement() async throws {
        let service = StubCalendarService()
        service.deleteError = MacCalendarGatewayError.readOnly("Full Calendar access is required to update or delete existing events.")
        MacNodeInvocationRouter.configureCalendarServiceForTesting(service)

        let params = MacCalendarDeleteParams(eventId: "evt-writeonly")
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "delete", command: "calendar.delete", paramsJSON: try encode(params))
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertEqual(response.error?.message.contains("Full Calendar access"), true)
    }

    func testAddCommandReturnsCreatedEventPayload() async throws {
        let service = StubCalendarService()
        service.addResponse = MacCalendarAddResponse(eventId: "evt-new", title: "Demo")
        MacNodeInvocationRouter.configureCalendarServiceForTesting(service)

        let params = MacCalendarAddParams(
            title: "Demo",
            startDate: "2026-05-10T17:00:00Z",
            endDate: nil,
            durationMinutes: 30,
            notes: nil,
            calendarName: nil,
            isAllDay: false
        )
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "add", command: "calendar.add", paramsJSON: try encode(params))
        )

        XCTAssertTrue(response.ok)
        let payload: MacCalendarAddResponse = try decodePayload(response)
        XCTAssertEqual(payload.eventId, "evt-new")
        XCTAssertEqual(payload.title, "Demo")
    }

    func testBrowserProxyOpensHttpURL() async throws {
        var openedURL: URL?
        var approvalURL: URL?
        MacNodeInvocationRouter.configureBrowserOpenApprovalForTesting { url in
            approvalURL = url
            return true
        }
        MacNodeInvocationRouter.configureBrowserOpenForTesting { url in
            openedURL = url
            return true
        }

        let params = BrowserProxyParams(
            method: "POST",
            path: "/tabs/open",
            body: BrowserProxyBody(url: "https://example.com/rem", label: "Example")
        )
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "browser", command: "browser.proxy", paramsJSON: try encode(params))
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(approvalURL?.absoluteString, "https://example.com/rem")
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/rem")
        let payload: BrowserProxyResponse = try decodePayload(response)
        XCTAssertEqual(payload.result.url, "https://example.com/rem")
        XCTAssertEqual(payload.result.label, "Example")
        XCTAssertEqual(payload.result.type, "page")
    }

    func testBrowserProxyDoesNotOpenWhenApprovalDenied() async throws {
        var didAttemptOpen = false
        MacNodeInvocationRouter.configureBrowserOpenApprovalForTesting { _ in false }
        MacNodeInvocationRouter.configureBrowserOpenForTesting { _ in
            didAttemptOpen = true
            return true
        }

        let params = BrowserProxyParams(
            method: "POST",
            path: "/tabs/open",
            body: BrowserProxyBody(url: "https://example.com/rem", label: nil)
        )
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "browser", command: "browser.proxy", paramsJSON: try encode(params))
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertEqual(response.error?.message.contains("cancelled"), true)
        XCTAssertFalse(didAttemptOpen)
    }

    func testBrowserProxyRejectsNonWebURL() async throws {
        let params = BrowserProxyParams(
            method: "POST",
            path: "/tabs/open",
            body: BrowserProxyBody(url: "file:///Users/example/.ssh/id_rsa", label: nil)
        )
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "browser", command: "browser.proxy", paramsJSON: try encode(params))
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .invalidRequest)
        XCTAssertEqual(response.error?.message.contains("public http or https"), true)
    }

    func testBrowserProxyRejectsLocalNetworkURLBeforeApproval() async throws {
        var didAskApproval = false
        var didAttemptOpen = false
        MacNodeInvocationRouter.configureBrowserOpenApprovalForTesting { _ in
            didAskApproval = true
            return true
        }
        MacNodeInvocationRouter.configureBrowserOpenForTesting { _ in
            didAttemptOpen = true
            return true
        }

        let params = BrowserProxyParams(
            method: "POST",
            path: "/tabs/open",
            body: BrowserProxyBody(url: "http://192.168.0.1/admin", label: nil)
        )
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "browser", command: "browser.proxy", paramsJSON: try encode(params))
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .invalidRequest)
        XCTAssertEqual(response.error?.message.contains("public http or https"), true)
        XCTAssertFalse(didAskApproval)
        XCTAssertFalse(didAttemptOpen)
    }

    func testBrowserProxyRejectsObfuscatedLoopbackURLsBeforeApproval() async throws {
        let unsafeURLs = [
            "http://localhost./",
            "http://2130706433/",
            "http://0177.0.0.1/",
            "http://0x7f.0.0.1/",
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:7f00:1]/",
            "http://[0:0:0:0:0:ffff:7f00:1]/",
        ]

        for unsafeURL in unsafeURLs {
            var didAskApproval = false
            var didAttemptOpen = false
            MacNodeInvocationRouter.configureBrowserOpenApprovalForTesting { _ in
                didAskApproval = true
                return true
            }
            MacNodeInvocationRouter.configureBrowserOpenForTesting { _ in
                didAttemptOpen = true
                return true
            }

            let params = BrowserProxyParams(
                method: "POST",
                path: "/tabs/open",
                body: BrowserProxyBody(url: unsafeURL, label: nil)
            )
            let response = await MacNodeInvocationRouter.handle(
                BridgeInvokeRequest(id: "browser", command: "browser.proxy", paramsJSON: try encode(params))
            )

            XCTAssertFalse(response.ok, unsafeURL)
            XCTAssertEqual(response.error?.code, .invalidRequest, unsafeURL)
            XCTAssertFalse(didAskApproval, unsafeURL)
            XCTAssertFalse(didAttemptOpen, unsafeURL)
        }
    }

    func testBrowserProxyUnsupportedActionsAreClear() async throws {
        let params = BrowserProxyParams(method: "POST", path: "/snapshot", body: nil)
        let response = await MacNodeInvocationRouter.handle(
            BridgeInvokeRequest(id: "browser", command: "browser.proxy", paramsJSON: try encode(params))
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertEqual(response.error?.message.contains("Only opening browser tabs"), true)
    }

    private final class StubCalendarService: MacCalendarGatewayServicing {
        var events: [CalendarEventPayload] = []
        var addResponse = MacCalendarAddResponse(eventId: "evt-added", title: nil)
        var updateResponse = MacCalendarUpdateResponse(eventId: "evt-updated", title: nil)
        var deleteResponse = MacCalendarDeleteResponse(deleted: true, eventId: "evt-deleted", title: nil)

        var fetchError: Error?
        var addError: Error?
        var updateError: Error?
        var deleteError: Error?

        func fetchEvents(params: MacCalendarEventsParams) async throws -> [CalendarEventPayload] {
            if let fetchError { throw fetchError }
            return events
        }

        func addEvent(params: MacCalendarAddParams) async throws -> MacCalendarAddResponse {
            if let addError { throw addError }
            return addResponse
        }

        func updateEvent(params: MacCalendarUpdateParams) async throws -> MacCalendarUpdateResponse {
            if let updateError { throw updateError }
            return updateResponse
        }

        func deleteEvent(params: MacCalendarDeleteParams) async throws -> MacCalendarDeleteResponse {
            if let deleteError { throw deleteError }
            return deleteResponse
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodePayload<T: Decodable>(_ response: BridgeInvokeResponse) throws -> T {
        let json = try XCTUnwrap(response.payloadJSON)
        let data = Data(json.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
#endif
