import Foundation
import OpenClawKit
import UserNotifications

enum SystemCommandHandler {

    static func handleNotify(_ req: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let params: OpenClawSystemNotifyParams = InvocationHelpers.decodeParams(req) else {
            return InvocationHelpers.invalidParams(req, "missing or invalid notify params")
        }

        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        let content = UNMutableNotificationContent()
        content.title = params.title
        content.body = params.body
        if params.sound != nil {
            content.sound = .default
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger)

        do {
            try await center.add(request)
            return BridgeInvokeResponse(id: req.id, ok: true)
        } catch {
            return InvocationHelpers.unavailable(req, "NOTIFY_FAILED: \(error.localizedDescription)")
        }
    }

    static func handleWhich(_ req: BridgeInvokeRequest) -> BridgeInvokeResponse {
        BridgeInvokeResponse(id: req.id, ok: true, payloadJSON: "{\"bins\":{}}")
    }
}
