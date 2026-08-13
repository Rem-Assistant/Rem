import Foundation
import OpenClawKit

@MainActor
enum RemindersCommandHandler {

    private static let remindersService = RemindersService()

    static func handleList(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let params: RemindersListParams? = InvocationHelpers.decodeParams(req)

        do {
            let reminders = try await remindersService.listReminders(params: params)
            return InvocationHelpers.encodeSuccess(req, RemindersListResponse(reminders: reminders))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }

    static func handleAdd(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: RemindersAddParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "reminders.add requires title")
        }

        do {
            let id = try await remindersService.addReminder(params: params)
            return InvocationHelpers.encodeSuccess(req, RemindersAddResponse(identifier: id, title: params.title))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }

    static func handleUpdate(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: RemindersUpdateParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "reminders.update requires identifier")
        }

        do {
            let result = try await remindersService.updateReminder(params: params)
            return InvocationHelpers.encodeSuccess(req, RemindersUpdateResponse(identifier: result.identifier, title: result.title))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }

    static func handleDelete(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: RemindersDeleteParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "reminders.delete requires identifier")
        }

        do {
            let result = try await remindersService.deleteReminder(identifier: params.identifier)
            return InvocationHelpers.encodeSuccess(req, RemindersDeleteResponse(deleted: true, identifier: result.identifier, title: result.title))
        } catch {
            return InvocationHelpers.permissionOrError(req, error)
        }
    }
}
