import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import Observation
import Speech
import UserNotifications

/// Permissions relevant to RemClawMac capabilities.
/// Subset of what openclaw tracks -- we only need the ones that map
/// to our advertised app capabilities (screen context, automation, voice, notifications).
enum MacPermission: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case screenRecording
    case microphone
    case speechRecognition
    case calendar
    case notifications

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .calendar: "Calendars"
        case .notifications: "Notifications"
        }
    }

    var subtitle: String {
        switch self {
        case .accessibility:
            "Control UI elements and automate actions on behalf of the agent"
        case .screenRecording:
            "Capture the screen for context and screenshots"
        case .microphone:
            "Capture your voice when you use Rem Voice"
        case .speechRecognition:
            "Transcribe speech for Rem Voice conversations"
        case .calendar:
            "Read and update events when you ask Rem to plan your day"
        case .notifications:
            "Show desktop alerts for agent activity"
        }
    }

    var icon: String {
        switch self {
        case .accessibility: "hand.raised"
        case .screenRecording: "display"
        case .microphone: "mic"
        case .speechRecognition: "waveform"
        case .calendar: "calendar"
        case .notifications: "bell"
        }
    }

}

// MARK: - Permission checking and granting

enum MacPermissionStatus: Equatable, Sendable {
    case checking
    case notDetermined
    case granted
    case denied
    case limited

    var isGranted: Bool {
        switch self {
        case .granted: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .checking: "Checking..."
        case .notDetermined: "Not Set"
        case .granted: "Enabled"
        case .denied: "Denied"
        case .limited: "Limited"
        }
    }
}

enum MacPermissionChecker {

    static func checkStatus(_ permission: MacPermission) async -> MacPermissionStatus {
        switch permission {
        case .accessibility:
            return await MainActor.run { AXIsProcessTrusted() ? .granted : .notDetermined }

        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined

        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied, .restricted:
                return .denied
            @unknown default:
                return .denied
            }

        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied, .restricted:
                return .denied
            @unknown default:
                return .denied
            }

        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized:
                return .granted
            case .writeOnly:
                return .limited
            case .notDetermined:
                return .notDetermined
            case .denied, .restricted:
                return .denied
            @unknown default:
                return .denied
            }

        case .notifications:
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied:
                return .denied
            default:
                return .denied
            }
        }
    }

    static func checkAll() async -> [MacPermission: MacPermissionStatus] {
        var results: [MacPermission: MacPermissionStatus] = [:]
        for perm in MacPermission.allCases {
            results[perm] = await checkStatus(perm)
        }
        return results
    }

    /// Request a permission interactively. Returns true if granted.
    @MainActor
    static func request(_ permission: MacPermission) async -> Bool {
        switch permission {
        case .accessibility:
            let trusted = AXIsProcessTrusted()
            if !trusted {
                let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            return AXIsProcessTrusted()

        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            return CGPreflightScreenCaptureAccess()

        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return true
            case .notDetermined:
                return await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            case .denied, .restricted:
                openMicrophoneSettings()
                return false
            @unknown default:
                return false
            }

        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                return true
            case .notDetermined:
                return await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status == .authorized)
                    }
                }
            case .denied, .restricted:
                openSpeechRecognitionSettings()
                return false
            @unknown default:
                return false
            }

        case .calendar:
            let store = EKEventStore()
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized:
                return true
            case .notDetermined, .writeOnly:
                if #available(macOS 14.0, *) {
                    return (try? await store.requestFullAccessToEvents()) ?? false
                } else {
                    return (try? await store.requestAccess(to: .event)) ?? false
                }
            case .denied, .restricted:
                openCalendarSettings()
                return false
            @unknown default:
                return false
            }

        case .notifications:
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                return granted
            case .denied:
                openNotificationSettings()
                return false
            @unknown default:
                return false
            }
        }
    }

    // MARK: - System Settings deep links

    static func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openMicrophoneSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openSpeechRecognitionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    static func openCalendarSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - Permission monitor (polls for status changes)

@MainActor @Observable
final class MacPermissionMonitor {
    private(set) var status: [MacPermission: MacPermissionStatus] = [:]
    private var timer: Timer?

    func startMonitoring() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        let latest = await MacPermissionChecker.checkAll()
        if latest != status {
            status = latest
        }
    }
}
