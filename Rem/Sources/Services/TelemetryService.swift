import Foundation
import PostHog

// MARK: - Event Constants

enum TelemetryEvent {
    // Auth
    static let userSignedUp = "user_signed_up"
    static let userLoggedIn = "user_logged_in"

    // Gateway
    static let gatewayConnected = "device_gateway_node_connected"
    static let gatewayDisconnected = "device_gateway_node_disconnected"
    static let devicePaired = "device_gateway_pairing_completed"

    // Pairing recovery (#306 Pairing recovery UX epic)
    //
    // Four events measure the failure-and-recovery funnel the epic introduces:
    //   1. `..._required_seen`      — gateway signaled re-pair is needed
    //   2. `..._signature_invalid_seen` — trust-revocation failure mode, distinct
    //      from the deterministic `scope-upgrade` / `signature_expired` path
    //   3. `..._re_pair_initiated`  — a reset was actually kicked off, with
    //      `trigger: "auto" | "user"` so we can tell auto-recovery apart from
    //      user-tap recovery
    //   4. `..._re_pair_completed`  — we reconnected successfully after reset;
    //      the ratio of (completed / initiated) is the recovery success rate
    //
    // `devicePaired` carries `is_repair: Bool` so the first-pair vs re-pair
    // split is visible in the existing funnel without a new event name.
    static let gatewayPairingRequiredSeen = "gateway_pairing_required_seen"
    static let gatewaySignatureInvalidSeen = "gateway_signature_invalid_seen"
    static let gatewayRePairInitiated = "gateway_re_pair_initiated"
    static let gatewayRePairCompleted = "gateway_re_pair_completed"

    // AI Tool Invocations
    static let aiToolInvoked = "ai_agent_tool_invoked"
    static let aiToolError = "ai_agent_tool_error"

    // Tasks & Events
    static let taskCreated = "user_task_created"
    static let taskCompleted = "user_task_completed"
    static let taskDeleted = "user_task_deleted"
    static let eventCreated = "user_calendar_event_created"
    static let eventUpdated = "user_calendar_event_updated"
    static let eventDeleted = "user_calendar_event_deleted"
    static let reminderCreated = "user_reminder_created"

    // Chat
    static let chatMessageSent = "user_chat_message_sent"

    // Voice
    static let voiceSessionStarted = "user_voice_session_started"
    static let voiceSessionEnded = "user_voice_session_ended"
    static let voiceCaptureStarted = "user_voice_capture_started"
    static let voiceFirstResponseReceived = "ai_voice_first_response_received"
}

/// Singleton service for PostHog telemetry tracking.
///
/// Thread-safe via `@MainActor` isolation. All PostHog calls are funneled
/// through this service so the rest of the app never imports PostHog directly.
@MainActor
final class TelemetryService {

    static let shared = TelemetryService()

    private(set) var isInitialized: Bool = false

    private init() {}

    // MARK: - Initialization

    /// Initializes PostHog with the provided configuration.
    /// Call once from AppDelegate on launch.
    @discardableResult
    func initialize(apiKey: String, host: String? = nil) -> Bool {
        guard !isInitialized else { return false }
        guard !apiKey.isEmpty else { return false }

        let config = PostHogConfig(apiKey: apiKey, host: host ?? "https://us.i.posthog.com")
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = true
        config.flushAt = 5
        config.flushIntervalSeconds = 5
        config.sessionReplay = true

        PostHogSDK.shared.setup(config)
        isInitialized = true
        registerBaseProperties()

        #if DEBUG
        print("[Telemetry] PostHog initialized")
        #endif
        return true
    }

    // MARK: - User Identity

    /// Identifies a user with optional properties.
    /// Also registers `user_id` as a super property so it appears on every subsequent event.
    func identify(userId: String, properties: [String: Any]? = nil, propertiesSetOnce: [String: Any]? = nil) {
        guard isInitialized, !userId.isEmpty else { return }
        PostHogSDK.shared.identify(
            userId,
            userProperties: properties ?? [:],
            userPropertiesSetOnce: propertiesSetOnce ?? [:]
        )
        PostHogSDK.shared.register(["user_id": userId])
    }

    /// Resets user identification (call on sign-out).
    func reset() {
        guard isInitialized else { return }
        PostHogSDK.shared.reset()
    }

    // MARK: - Event Tracking

    /// Tracks an event with optional properties.
    func track(eventName: String, properties: [String: Any]? = nil, userProperties: [String: Any]? = nil) {
        guard isInitialized, !eventName.isEmpty else { return }
        PostHogSDK.shared.capture(
            eventName,
            properties: properties ?? [:],
            userProperties: userProperties
        )
        PostHogSDK.shared.flush()
        #if DEBUG
        print("[Telemetry] \(eventName)")
        #endif
    }

    /// Flushes pending events immediately.
    func flush() {
        guard isInitialized else { return }
        PostHogSDK.shared.flush()
    }

    // MARK: - Super Properties

    /// Registers base properties that are attached to every event automatically.
    /// Called once during initialization; user_id is added later via `identify()`.
    private func registerBaseProperties() {
        var sysinfo = utsname()
        uname(&sysinfo)
        let model = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        PostHogSDK.shared.register([
            "platform": "ios",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "device_model": model,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
    }
}
