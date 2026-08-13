import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Speech)
import Speech
#endif

// MARK: - Permission Type

/// OS-level permissions surfaced by the iOS Permissions settings screen.
/// Mirrors the `Capability` enum in `openclaw/apps/macos/Sources/OpenClaw/Capability.swift`
/// with the iOS-relevant subset (no Accessibility / Screen Recording / AppleScript).
enum PermissionType: CaseIterable {
    case calendar
    case reminders
    case microphone
    case notifications
    case speechRecognition
    case camera
}

enum PermissionStatus: Equatable {
    case checking
    case notDetermined
    case granted
    case denied
    case restricted
    case limited
    case provisional
    case always
    case whenInUse
    case unavailable
    case unknown

    var displayText: String {
        switch self {
        case .checking: "Checking..."
        case .notDetermined: "Not Set"
        case .granted: "Granted"
        case .denied, .restricted: "Denied"
        case .limited: "Limited"
        case .provisional: "Provisional"
        case .always: "Always"
        case .whenInUse: "When In Use"
        case .unavailable: "N/A"
        case .unknown: "Unknown"
        }
    }

    var shouldRequestSystemPrompt: Bool {
        self == .notDetermined
    }
}

// MARK: - Permission Checker

enum PermissionChecker {

    /// Returns a human-readable status string for the given permission type.
    @MainActor
    static func checkStatus(for type: PermissionType) async -> String {
        await permissionStatus(for: type).displayText
    }

    @MainActor
    static func permissionStatus(for type: PermissionType) async -> PermissionStatus {
        switch type {
        case .camera:
            #if canImport(AVFoundation)
            return avStatus(for: .video)
            #else
            return .unavailable
            #endif
        case .microphone:
            #if canImport(AVFoundation)
            return avStatus(for: .audio)
            #else
            return .unavailable
            #endif
        case .notifications:
            return await notificationStatus()
        case .calendar:
            return calendarStatus()
        case .reminders:
            return remindersStatus()
        case .speechRecognition:
            return speechRecognitionStatus()
        }
    }

    /// Requests the permission if not determined, otherwise opens Settings.
    /// Denied redirect uses `UIApplication.openSettingsURLString` — the
    /// standard iOS pattern (locked decision for #314).
    @MainActor
    static func requestOrOpenSettings(for type: PermissionType, currentStatus: PermissionStatus) async {
        if currentStatus.shouldRequestSystemPrompt {
            await requestPermission(for: type)
        } else {
            openAppSettings()
        }
    }

    /// Directly requests the system permission prompt.
    @MainActor
    static func requestPermission(for type: PermissionType) async {
        switch type {
        case .camera:
            #if canImport(AVFoundation)
            _ = await AVCaptureDevice.requestAccess(for: .video)
            #endif
        case .microphone:
            #if canImport(AVFoundation)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            #endif
        case .notifications:
            #if canImport(UserNotifications)
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted {
                // Register for APNs once notifications are allowed so the backend
                // can deliver proactive routine pushes (#830).
                AppDelegate.registerForRemoteNotificationsIfAuthorized()
            }
            #endif
        case .calendar:
            #if canImport(EventKit)
            let store = EKEventStore()
            if #available(iOS 17.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await store.requestAccess(to: .event)
            }
            #endif
        case .reminders:
            #if canImport(EventKit)
            let store = EKEventStore()
            if #available(iOS 17.0, *) {
                _ = try? await store.requestFullAccessToReminders()
            } else {
                _ = try? await store.requestAccess(to: .reminder)
            }
            #endif
        case .speechRecognition:
            #if canImport(Speech)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in
                    cont.resume()
                }
            }
            #endif
        }
    }

    static func openAppSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    // MARK: - Private Status Helpers

    #if canImport(AVFoundation)
    private static func avStatus(for mediaType: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
    #endif

    private static func notificationStatus() async -> PermissionStatus {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .granted
        case .denied: return .denied
        case .provisional: return .provisional
        case .notDetermined: return .notDetermined
        case .ephemeral: return .limited
        @unknown default: return .unknown
        }
        #else
        return .unavailable
        #endif
    }

    private static func calendarStatus() -> PermissionStatus {
        #if canImport(EventKit)
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .writeOnly: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
        #else
        return .unavailable
        #endif
    }

    private static func remindersStatus() -> PermissionStatus {
        #if canImport(EventKit)
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized: return .granted
        case .writeOnly: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
        #else
        return .unavailable
        #endif
    }

    private static func speechRecognitionStatus() -> PermissionStatus {
        #if canImport(Speech)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
        #else
        return .unavailable
        #endif
    }

}

// MARK: - Permission Status Badge (dot + label)

/// Displays a colored dot and a short label reflecting permission status.
///
/// - Green dot + "Enabled" → Granted / Always / When In Use
/// - Red dot + "Denied" → Denied
/// - Orange dot + "Limited" → Limited / Provisional
/// - Gray dot + "Not Set" → Not Set (status indicator)
struct PermissionStatusBadge: View {
    let status: PermissionStatus

    init(status: PermissionStatus) {
        self.status = status
    }

    init(status: String) {
        self.status = Self.status(from: status)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(DesignTokens.Typography.body)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
    }

    private var dotColor: Color {
        switch status {
        case .granted, .always, .whenInUse: .green
        case .denied, .restricted: .red
        case .limited, .provisional: .orange
        default: .gray
        }
    }

    private var label: String {
        switch status {
        case .granted, .always, .whenInUse: "Enabled"
        case .denied, .restricted: "Denied"
        case .limited, .provisional: "Limited"
        case .notDetermined: "Not Set"
        default: status.displayText
        }
    }

    private static func status(from displayText: String) -> PermissionStatus {
        switch displayText {
        case "Granted": .granted
        case "Always": .always
        case "When In Use": .whenInUse
        case "Denied": .denied
        case "Limited": .limited
        case "Provisional": .provisional
        case "Not Set": .notDetermined
        case "N/A": .unavailable
        case "Checking...": .checking
        case "Unknown": .unknown
        default: .unknown
        }
    }
}
