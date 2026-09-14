import AppKit
import Sparkle
import SwiftUI

@MainActor
@Observable
final class MacAppModel {
    static let shared = MacAppModel(isSparkleEnabled: MacRuntimeConfig.isSparkleEnabled)

    let sessionManager: MacGatewaySessionManager
    let router: MacRouter
    let localGateway: LocalGatewayManager
    let updaterController: SPUStandardUpdaterController

    var didAutoConnect = false

    init(isSparkleEnabled: Bool) {
        let session = MacGatewaySessionManager()

        self.sessionManager = session
        self.router = MacRouter()
        self.localGateway = LocalGatewayManager()
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: isSparkleEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func autoConnectIfNeeded() async {
        guard !didAutoConnect else { return }
        didAutoConnect = true
        sessionManager.migrateTokenIfNeeded()

        // One-shot migration: scrubs the legacy
        // `~/Library/LaunchAgents/app.remclaw.mac.gateway.plist`
        // that pre-#275 builds wrote with provider keys and
        // the gateway auth token in plaintext (#383, #384).
        // Idempotent — sets a UserDefaults sentinel after
        // running once, so this is a no-op on subsequent
        // launches even if the plist is already gone.
        await LaunchAgentSecretsMigrator.runIfNeeded()

        // Sync local gateway status on launch.
        localGateway.detectCLI()
        await localGateway.refreshState()

        // Auto-start local gateway if CLI is installed and it's not
        // currently running (#388). We don't wait for `start()` to
        // complete — `refreshState()` on the next activation cycle
        // will pick up the running state. The `start()` call is
        // safe to repeat: `LocalGatewayManager.start()` probes the
        // port first and exits early if something's already there.
        if localGateway.isCLIInstalled && !localGateway.status.isRunning {
            let url = LocalGatewayManager.gatewayURL()
            sessionManager.localGatewayURL = url
            Task { await localGateway.start() }
        }

        // Start health monitoring for local gateway.
        let session = sessionManager
        localGateway.startHealthMonitoring {
            // Gateway went down -- clear local URL so we fall back to cloud.
            session.localGatewayURL = nil
            session.connectIfConfigured()
        }

        sessionManager.connectIfConfigured()
    }
}

enum MacRuntimeConfig {
    static var isSparkleEnabled: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    static var isVisualQAMode: Bool {
        ProcessInfo.processInfo.environment["REM_MAC_VISUAL_QA"] == "1"
    }
}

struct MacMainWindowRootView: View {
    let model: MacAppModel
    @State private var isReadyForAppContent = false

    var body: some View {
        Group {
            if isReadyForAppContent {
                MainWindow()
                    .environment(model.sessionManager)
                    .environment(model.router)
                    .environment(\.localGateway, model.localGateway)
                    .task {
                        if !MacRuntimeConfig.isVisualQAMode {
                            await model.autoConnectIfNeeded()
                            // Persist the device tz so the brief cron resolves the user's
                            // LOCAL day/greeting/slot correctly (#1097). Best-effort; no-ops
                            // until a backend token exists, then the foreground hook retries.
                            TimezoneSyncService.syncCurrentTimezone()
                            TimezoneSyncService.syncCurrentTimezoneToGateway(model.sessionManager)
                        }
                    }
                    // Refresh consolidated lifecycle state when the app
                    // returns to the foreground (#293). Picks up config
                    // changes the user made via the CLI in another window
                    // (e.g. `openclaw config set gateway.bind lan`) without
                    // requiring an app relaunch.
                    .onReceive(NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification
                    )) { _ in
                        let gateway = model.localGateway
                        Task { await gateway.refreshState() }
                        // Re-capture the device tz on foreground so travel / DST changes
                        // reach the brief cron, and to catch the post-sign-in case where the
                        // launch-time post ran before a token existed (#1097). Skips when
                        // unchanged.
                        TimezoneSyncService.syncCurrentTimezone()
                        TimezoneSyncService.syncCurrentTimezoneToGateway(model.sessionManager)
                    }
                    .onChange(of: model.sessionManager.operatorReady) { _, operatorReady in
                        guard operatorReady else { return }
                        TimezoneSyncService.syncCurrentTimezoneToGateway(model.sessionManager)
                    }
            } else {
                MacMainWindowLaunchShell()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(MacMainWindowAccessor())
        .onAppear {
            guard !isReadyForAppContent else { return }
            DispatchQueue.main.async {
                isReadyForAppContent = true
            }
        }
    }
}

private struct MacMainWindowLaunchShell: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Opening Rem")
        }
    }
}
