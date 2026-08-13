import UIKit
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
import UserNotifications
import SwiftData

class AppDelegate: NSObject, UIApplicationDelegate {
    /// Retained so UNUserNotificationCenter keeps a strong delegate reference.
    private var notificationDelegate: TaskNotificationDelegate?

    /// Shared model container — set by RemClawApp after creation so the
    /// notification delegate can build a ModelContext for action handlers.
    static var sharedModelContainer: ModelContainer?

    /// Shared task sync service — set by ContentView once created, so
    /// notification action buttons (Mark Complete) can sync to the backend.
    static var sharedTaskSyncService: TaskSyncServiceProtocol?
    static var pendingOpenedURL: URL?

    @MainActor
    static func routeOpenedURL(_ url: URL) {
        pendingOpenedURL = url
        NotificationCenter.default.post(name: .remClawDidOpenURL, object: url)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        initializeTelemetry()

        // Wire the notification delegate so foreground banners and action
        // buttons (Mark Complete, Snooze) work. The model container is set
        // later by RemClawApp; until then, action handlers are no-ops.
        let delegate = TaskNotificationDelegate(
            modelContextProvider: {
                guard let container = AppDelegate.sharedModelContainer else { return nil }
                return ModelContext(container)
            },
            taskSyncServiceProvider: {
                return AppDelegate.sharedTaskSyncService
            }
        )
        self.notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate

        // If the user already granted notification permission (returning user),
        // kick off APNs registration so the backend has a fresh device token for
        // proactive routine pushes (#830). First-time grants register from the
        // permission flow via `registerForRemoteNotificationsIfAuthorized()`.
        AppDelegate.registerForRemoteNotificationsIfAuthorized()
        return true
    }

    // MARK: - Remote Notifications (APNs)

    /// Requests an APNs device token from the system, but only if the user has
    /// already authorized notifications. Calling `registerForRemoteNotifications()`
    /// without authorization would silently return a token the user never agreed to.
    /// Safe to call repeatedly — iOS dedupes and returns the cached token quickly.
    @MainActor
    static func registerForRemoteNotificationsIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// APNs delivered a device token. Hex-encode it (the wire/DB format APNs and
    /// `push.service.ts` expect) and hand it to `PushRegistrationService`, which
    /// posts it to `/api/v1/push/register` once the user is authenticated.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            PushRegistrationService.handleDeviceToken(hexToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[Push] APNs registration failed: \(error.localizedDescription)")
        #endif
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        #if canImport(GoogleSignIn)
        if GIDSignIn.sharedInstance.handle(url) { return true }
        #endif
        AppDelegate.routeOpenedURL(url)
        return true
    }

    // MARK: - Telemetry

    private func initializeTelemetry() {
        Task { @MainActor in
            guard let apiKey = AppConfig.posthogApiKey, !apiKey.isEmpty else {
                #if DEBUG
                print("[Telemetry] POSTHOG_API_KEY not configured, telemetry disabled")
                #endif
                return
            }
            TelemetryService.shared.initialize(apiKey: apiKey, host: AppConfig.posthogHost)
        }
    }
}
