import Foundation
import OpenClawKit

#if DEBUG
enum PreviewDevices {
    static var currentIPhone: LinkedDevice {
        LinkedDevice(
            deviceId: DeviceIdentityStore.loadOrCreate().deviceId,
            displayName: "This iPhone",
            clientId: "rem-ios-preview",
            scopes: ["operator.read", "operator.write"],
            role: "operator",
            connectedAt: nil,
            platform: "ios",
            tokens: [
                DeviceToken(
                    createdAtMs: Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000),
                    lastUsedAtMs: Int(Date().addingTimeInterval(-7_200).timeIntervalSince1970 * 1000),
                    role: "operator",
                    scopes: ["operator.read", "operator.write"]
                ),
            ],
            approvedAtMs: Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000),
            roles: ["operator"]
        )
    }

    static let pendingIPhone = PendingDevice(
        requestId: "preview-request-iphone",
        deviceId: "preview-device-iphone",
        displayName: "Sam's iPhone"
    )

    static let pendingIPad = PendingDevice(
        requestId: "preview-request-ipad",
        deviceId: "preview-device-ipad",
        displayName: "Studio iPad"
    )

    static let pendingAgent = PendingDevice(
        requestId: "preview-request-agent",
        deviceId: "preview-device-agent",
        displayName: "agent"
    )

    static let pairedIPhone = LinkedDevice(
        deviceId: "preview-paired-iphone",
        displayName: "Sam's iPhone",
        clientId: "rem-ios-preview",
        scopes: ["operator.read", "operator.write"],
        role: "operator",
        connectedAt: nil,
        platform: "ios",
        tokens: [
            DeviceToken(
                createdAtMs: Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000),
                lastUsedAtMs: Int(Date().timeIntervalSince1970 * 1000),
                role: "operator",
                scopes: ["operator.read", "operator.write"]
            ),
        ],
        approvedAtMs: Int(Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000),
        roles: ["operator"]
    )

    static let pairedMac = LinkedDevice(
        deviceId: "preview-paired-mac",
        displayName: "Sam's MacBook",
        clientId: "rem-mac-preview",
        scopes: ["operator.read", "operator.write", "operator.admin"],
        role: "operator",
        connectedAt: nil,
        platform: "macos",
        tokens: [
            DeviceToken(
                createdAtMs: Int(Date().addingTimeInterval(-172_800).timeIntervalSince1970 * 1000),
                lastUsedAtMs: Int(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1000),
                role: "operator",
                scopes: ["operator.read", "operator.write", "operator.admin"]
            ),
        ],
        approvedAtMs: Int(Date().addingTimeInterval(-172_800).timeIntervalSince1970 * 1000),
        roles: ["operator", "node"]
    )

    static let pairedAgent = LinkedDevice(
        deviceId: "preview-paired-agent",
        displayName: "agent",
        clientId: "openclaw-agent-preview",
        scopes: ["operator.pairing"],
        role: "operator",
        connectedAt: nil,
        platform: nil,
        tokens: [
            DeviceToken(
                createdAtMs: Int(Date().addingTimeInterval(-1_800).timeIntervalSince1970 * 1000),
                lastUsedAtMs: Int(Date().addingTimeInterval(-300).timeIntervalSince1970 * 1000),
                role: "operator",
                scopes: ["operator.pairing"]
            ),
        ],
        approvedAtMs: Int(Date().addingTimeInterval(-1_800).timeIntervalSince1970 * 1000),
        roles: ["operator"]
    )
}
#endif
