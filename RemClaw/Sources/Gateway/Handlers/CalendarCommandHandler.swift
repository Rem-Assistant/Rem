import Foundation
import OpenClawKit

@MainActor
enum CalendarCommandHandler {

    private static let calendarService = CalendarGatewayService()

    static func handleEvents(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let params: CalendarEventsParams
        if let decoded: CalendarEventsParams = InvocationHelpers.decodeParams(req) {
            params = decoded
        } else {
            params = CalendarEventsParams()
        }

        do {
            let events = try await calendarService.fetchEvents(params: params)
            return InvocationHelpers.encodeSuccess(req, CalendarEventsResponse(events: events))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }

    static func handleAdd(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: CalendarAddParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "calendar.add requires title and startDate")
        }

        do {
            let eventId = try await calendarService.addEvent(params: params)
            return InvocationHelpers.encodeSuccess(req, CalendarAddResponse(eventId: eventId, title: params.title))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }

    static func handleUpdate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: CalendarUpdateParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "calendar.update requires eventId")
        }

        do {
            let result = try await calendarService.updateEvent(params: params)
            return InvocationHelpers.encodeSuccess(req, CalendarUpdateResponse(eventId: result.eventId, title: result.title))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }

    static func handleDelete(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: CalendarDeleteParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "calendar.delete requires eventId")
        }

        do {
            let result = try await calendarService.deleteEvent(eventId: params.eventId)
            return InvocationHelpers.encodeSuccess(req, CalendarDeleteResponse(deleted: true, eventId: result.eventId, title: result.title))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }
}
