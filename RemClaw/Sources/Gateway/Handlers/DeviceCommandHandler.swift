import Foundation
import OpenClawKit

enum DeviceCommandHandler {

    static func handleStatus(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let payload = await MainActor.run { DeviceStatusService.getStatus() }
        return InvocationHelpers.encodeSuccess(req, payload)
    }

    static func handleInfo(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        let payload = await MainActor.run { DeviceStatusService.getInfo() }
        return InvocationHelpers.encodeSuccess(req, payload)
    }
}
