import SwiftUI
import SwiftData
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct RemClawApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var launchState: LaunchScreenView.State = .splash
    @State private var showServerSettings = false
    /// Drives the bounded auto-retry connection watch on the launch screen so a
    /// single cold-start timeout no longer lands the user on a dead-end. Held so
    /// a manual Retry can cancel and restart the watch instead of stacking loops.
    @State private var connectionWatchTask: Task<Void, Never>?
    @State private var gateway: RemGatewaySessionManager
    @State private var authService = RemAuthService()
    @State private var usageService: UsageService
    @State private var voiceControlRouter = VoiceSessionControlRouter()
    @State private var focusControlRouter = FocusSessionControlRouter()

    let modelContainer: ModelContainer
    private let isChatDiagnosticsFixture =
        ProcessInfo.processInfo.arguments.contains("--rem-chat-diagnostics-fixture")
    private let isChatLifecycleFixture =
        ProcessInfo.processInfo.arguments.contains("--rem-chat-lifecycle-fixture")
    private let isChatDayDividerFixture =
        ProcessInfo.processInfo.arguments.contains("--rem-chat-day-divider-fixture")
    private let isSettingsFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-settings-fixture")
        #else
        false
        #endif
    }()
    private let isConnectorsFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-connectors-fixture")
        #else
        false
        #endif
    }()
    private let isAutomationsFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-automations-fixture")
        #else
        false
        #endif
    }()
    private let isGatewayDetailFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-gateway-detail-fixture")
        #else
        false
        #endif
    }()
    private let isVoiceSettingsFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-voice-settings-fixture")
        #else
        false
        #endif
    }()
    private let isGatewayUpdateTargetsFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-gateway-update-targets-fixture")
        #else
        false
        #endif
    }()
    private let isGatewayConnectionRecoveryFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-gateway-connection-recovery-fixture")
        #else
        false
        #endif
    }()
    private let isGatewayDevicePairingFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-gateway-device-pairing-fixture")
        #else
        false
        #endif
    }()
    private let isCloudGatewayDeployFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-cloud-deploy-fixture")
        #else
        false
        #endif
    }()
    private let isLaunchRecoveryCopyFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-launch-recovery-copy-fixture")
        #else
        false
        #endif
    }()
    private let isLaunchConnectionRecoveryRouteFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-launch-connection-recovery-route-fixture")
        #else
        false
        #endif
    }()
    private let isRestoredSessionScrollFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-restored-session-scroll-fixture")
        #else
        false
        #endif
    }()
    private let isChatDiagnosticsRowFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-chat-diagnostics-row-fixture")
        #else
        false
        #endif
    }()
    private let isBrowserLiveCardFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-browser-live-card-fixture")
        #else
        false
        #endif
    }()
    private let isModelPickerFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-model-picker-fixture")
        #else
        false
        #endif
    }()
    private let isMcpAddServerFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-mcp-add-server-fixture")
        #else
        false
        #endif
    }()
    private let isClawHubReviewFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-clawhub-review-fixture")
        #else
        false
        #endif
    }()

    private let isClawHubUnavailableFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-clawhub-unavailable-fixture")
        #else
        false
        #endif
    }()
    private let isSkillProviderRequirementsFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-skill-provider-requirements-fixture")
        #else
        false
        #endif
    }()

    private let isOnboardingKeychainErrorFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-onboarding-keychain-error-fixture")
        #else
        false
        #endif
    }()
    private let isOnboardingFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-onboarding-fixture")
        #else
        false
        #endif
    }()
    private let isPostSetupNuxFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-post-setup-nux-fixture")
        #else
        false
        #endif
    }()
    private let isAIDataSharingConsentFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-ai-data-sharing-consent-fixture")
        #else
        false
        #endif
    }()
    private let isFirstUseHintFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-first-use-hint-fixture")
        #else
        false
        #endif
    }()
    // Renders the reusable spotlight coach-mark engine (`Shared/Views/GuidedFlow.swift`,
    // epic #1373) in isolation so the scrim + cutout + Skip/Next bubble can be
    // driven on a sim. DEBUG-only capture aid; not wired into real onboarding yet.
    private let isGuidedFlowFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-guided-flow-fixture")
        #else
        false
        #endif
    }()
    private let isSessionPreviewFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-session-preview-fixture")
        #else
        false
        #endif
    }()
    private let isCollaborationFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-collaboration-fixture")
            || ProcessInfo.processInfo.arguments.contains("--rem-collaboration-empty")
        #else
        false
        #endif
    }()
    private let isTaskDetailFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-task-detail-fixture")
        #else
        false
        #endif
    }()
    private let isActivityHistoryFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-activity-history-fixture")
        #else
        false
        #endif
    }()
    private let isAgendaFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-agenda-fixture")
        #else
        false
        #endif
    }()
    private let isDailyBriefFixture: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rem-daily-brief-fixture")
        #else
        false
        #endif
    }()

    /// Creates the local SwiftData container. In DEBUG, the store is namespaced
    /// by backend target so switching staging↔prod swaps data instead of wiping
    /// it (Fix 3); on any failure it falls back to the default store. Release
    /// builds always use the default store (behavior unchanged).
    @MainActor
    private static func makeModelContainer() -> ModelContainer {
        #if DEBUG
        if let config = BackendScopedStore.debugConfiguration(),
           let scoped = try? ModelContainer(
               for: TaskEvent.self, StoredFocusSession.self, PendingTaskOperation.self,
               TaskFolder.self, TaskList.self,
               configurations: config
           ) {
            return scoped
        }
        #endif
        do {
            return try ModelContainer(for:
                TaskEvent.self,
                StoredFocusSession.self,
                PendingTaskOperation.self,
                TaskFolder.self,
                TaskList.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error.localizedDescription)")
        }
    }

    @MainActor
    init() {
        let container = Self.makeModelContainer()
        self.modelContainer = container
        AppDelegate.sharedModelContainer = container

        let usageService = UsageService()
        self._usageService = State(initialValue: usageService)

        let gatewayMgr = RemGatewaySessionManager()
        self._gateway = State(initialValue: gatewayMgr)
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                // Effective backend the HTTP client actually uses (override wins),
                // matching AuthenticatedHttpClient — so the banner can't show prod
                // while traffic goes to an overridden non-prod backend.
                .environmentBanner(backendURL: RemCredentialStore.backendURL ?? AppConfig.apiBaseURL)
                .environment(gateway)
                .environment(authService)
                .environment(usageService)
                .environment(voiceControlRouter)
                .environment(focusControlRouter)
                .task {
                    guard !isFixtureMode else { return }
                    let start = CFAbsoluteTimeGetCurrent()
                    RemCredentialStore.migrateFromUserDefaultsIfNeeded()
                    await authService.checkStoredToken()
                    Task { await reconcileUsageStateForAuthChange() }
                    Task { await gateway.wakeGatewayIfNeeded() }
                    gateway.connectIfConfigured()
                    // Persist the device timezone so the brief cron resolves the user's
                    // LOCAL day/greeting/slot correctly (#1097). Best-effort; no-ops if the
                    // token isn't ready yet — the auth observer below re-fires post sign-in.
                    TimezoneSyncService.syncCurrentTimezone()
                    TimezoneSyncService.syncCurrentTimezoneToGateway(gateway)
                    if let pendingURL = AppDelegate.pendingOpenedURL {
                        AppDelegate.pendingOpenedURL = nil
                        handleDeepLink(pendingURL)
                    }
                    let launchMinDuration: TimeInterval = 0.3
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    let remaining = launchMinDuration - elapsed
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }

                    // If not authenticated or not configured → go straight to onboarding
                    guard authService.isAuthenticated, gateway.isConfigured else {
                        launchState = .ready
                        return
                    }

                    // Already connected (fast reconnect) → go to main app
                    if gateway.connectionState.isConnected {
                        launchState = .ready
                        return
                    }

                    // Configured but not connected → show connecting state, wait for connection
                    launchState = .connecting
                    waitForConnection()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard !isFixtureMode else { return }
                    if newPhase == .active {
                        Task { await reconcileUsageStateForAuthChange() }
                        // Re-capture the device tz on foreground so travel / DST changes
                        // reach the brief cron (#1097). Skips the POST when unchanged.
                        TimezoneSyncService.syncCurrentTimezone()
                        TimezoneSyncService.syncCurrentTimezoneToGateway(gateway)
                        if gateway.isConfigured {
                            if !gateway.connectionState.isConnected {
                                // Warm-on-open: a managed Fly gateway scales to zero when
                                // idle, so returning to the app after even a short gap
                                // usually lands on a sleeping machine and the bare
                                // reconnect() below would race a cold boot and time out.
                                // Fire the backend wake ping (starts the Fly machine +
                                // waits for health) IN PARALLEL with the reconnect so the
                                // boot is already underway while the user reads the screen.
                                // No-ops for non-Fly gateways. This is the foreground twin
                                // of the launch-time wake in `.task` above (#1087 gap:
                                // launch woke the machine, foreground did not).
                                Task { await gateway.wakeGatewayIfNeeded() }
                                // Coalesced: a rapid background→foreground flap
                                // collapses to a single reconnect instead of
                                // stacking a fresh node+operator socket pair on
                                // each `.active`. wake stays (cheap); reconnect
                                // no-ops if one is already in flight/debounced.
                                gateway.reconnectOnForeground()
                            } else {
                                gateway.reconnectIfPermissionsChanged()
                            }
                        }
                        Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            if let action = VoiceSessionSharedState.consumePendingAction() {
                                switch action {
                                case "start": voiceControlRouter.enqueue(.start)
                                case "stop": voiceControlRouter.enqueue(.stop)
                                default: break
                                }
                            }
                            if let focusAction = FocusSessionSharedState.consumePendingAction(),
                               let command = FocusSessionDeepLink.command(fromPendingAction: focusAction) {
                                focusControlRouter.enqueue(command)
                            }
                        }
                    }
                }
                .onChange(of: gateway.connectionState) { _, newState in
                    guard !isFixtureMode else { return }
                    // If user reconnects from Settings sheet or auto-reconnect succeeds
                    // while on the connecting/failed screen, transition to ready
                    if newState.isConnected && (launchState == .connecting || launchState == .failed) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            launchState = .ready
                        }
                    }
                }
                .onChange(of: gateway.operatorReady) { _, operatorReady in
                    guard !isFixtureMode, operatorReady else { return }
                    TimezoneSyncService.syncCurrentTimezoneToGateway(gateway)
                }
                .onChange(of: authService.isAuthenticated) { oldValue, newValue in
                    guard !isFixtureMode else { return }
                    if !oldValue && newValue {
                        gateway.recheckConfigured()
                        Task { await reconcileUsageStateForAuthChange() }

                        // Data-loss guard (Cluster A): only wipe local data when a
                        // *different* user signs in. A returning user (same id)
                        // re-authenticating after a 401/expiry keeps their tasks.
                        // Identity bookkeeping is centralized in RemAuthService.
                        // See docs/rebuild/04-FIX-IDENTITY-DATALOSS.md.
                        if authService.reconcileLocalDataOwnershipForSignedInUser() == .wipe {
                            guard RemAuthService.clearAllUserData(from: modelContainer.mainContext) else {
                                authService.rejectSessionAfterLocalDataResetFailure()
                                return
                            }
                            authService.confirmLocalDataOwnershipForSignedInUser()
                            usageService.reset()
                        }

                        // Flush any APNs token that arrived before this backend session
                        // existed — the common returning-user case (AppDelegate gets the
                        // token at launch, before checkStoredToken finishes, so it was
                        // deferred). The reconcile above sets lastSignedInUserId, so the
                        // user-scoped skip-cache key is correct here. (#830 follow-up.)
                        PushRegistrationService.flushPendingRegistration()

                        // Stamp the device tz for the just-signed-in account so the brief
                        // cron has it immediately (#1097). Forced past the skip-cache because
                        // a launch-time post may have no-op'd before the token existed.
                        TimezoneSyncService.syncCurrentTimezoneForcingRefresh()
                        TimezoneSyncService.syncCurrentTimezoneToGateway(gateway)

                        // If gateway is configured but not connected (returning user sign-in),
                        // show the connecting launch screen while auto-reconnect runs
                        if gateway.isConfigured && !gateway.connectionState.isConnected {
                            launchState = .connecting
                            gateway.wakeAndConnectIfConfigured()
                            waitForConnection()
                        }
                    } else if oldValue && !newValue {
                        // Data-loss guard (Cluster A): only wipe on an EXPLICIT,
                        // user-initiated sign-out. A transient de-auth (401 / token
                        // minted for another environment / expiry) must NOT destroy
                        // local data — the session recovers and it's the same user's
                        // data. See docs/rebuild/04-FIX-IDENTITY-DATALOSS.md.
                        if RemAuthService.LocalDataResetDecision.onDeauth(
                            userInitiated: authService.lastDeauthWasUserInitiated
                        ) == .wipe {
                            _ = RemAuthService.clearAllUserData(from: modelContainer.mainContext)
                            usageService.reset()
                        }
                    }
                }
                .onOpenURL { url in
                    #if canImport(GoogleSignIn)
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    #endif
                    handleOrDeferDeepLinkUntilAuthRestores(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .remClawDidOpenURL)) { notification in
                    guard let url = notification.object as? URL else { return }
                    handleOrDeferDeepLinkUntilAuthRestores(url)
                }
        }
        .modelContainer(modelContainer)
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if isAgendaFixture {
            ReadmeAgendaFixtureView()
        } else if isDailyBriefFixture {
            ReadmeDailyBriefFixtureView()
        } else if isSessionPreviewFixture {
            SharedSessionPreviewFixtureView()
        } else if isCollaborationFixture {
            TaskCollaborationFixtureView()
        } else if isTaskDetailFixture {
            TaskDetailCreateFixtureView()
        } else if isActivityHistoryFixture {
            TaskActivityHistoryFixtureView()
        } else if isChatDiagnosticsFixture {
            NavigationStack {
                AssistantDiagnosticsFixtureView()
            }
        } else if isChatLifecycleFixture {
            NavigationStack {
                ChatLifecycleStateFixtureView()
                    .navigationTitle("Chat activity")
            }
        } else if isChatDayDividerFixture {
            NavigationStack {
                ChatDayDividerFixtureView()
            }
        } else if isSettingsFixture {
            SharedSettingsFixtureView()
        } else if isConnectorsFixture {
            SharedConnectorsFixtureView()
        } else if isAutomationsFixture {
            SharedAutomationsFixtureView()
        } else if isGatewayDetailFixture {
            SharedGatewayDetailFixtureView()
        } else if isVoiceSettingsFixture {
            SharedVoiceSettingsFixtureView()
        } else if isGatewayUpdateTargetsFixture {
            SharedGatewayUpdateTargetsFixtureView()
        } else if isGatewayConnectionRecoveryFixture {
            SharedGatewayConnectionRecoveryFixtureView()
        } else if isGatewayDevicePairingFixture {
            SharedGatewayDevicePairingFixtureView()
        } else if isCloudGatewayDeployFixture {
            CloudGatewayDeployFixtureView()
        } else if isLaunchRecoveryCopyFixture {
            LaunchRecoveryCopyFixtureView()
        } else if isLaunchConnectionRecoveryRouteFixture {
            LaunchConnectionRecoveryRouteFixtureView()
        } else if isRestoredSessionScrollFixture {
            RestoredSessionScrollFixtureView()
        } else if isChatDiagnosticsRowFixture {
            ChatDiagnosticsRowFixtureView()
        } else if isBrowserLiveCardFixture {
            BrowserLiveCardFixtureView()
        } else if isModelPickerFixture {
            ModelPickerFixtureView()
        } else if isMcpAddServerFixture {
            SharedMcpAddServerFixtureView()
        } else if isClawHubReviewFixture {
            SharedClawHubReviewFixtureView()
        } else if isClawHubUnavailableFixture {
            SharedClawHubUnavailableFixtureView()
        } else if isSkillProviderRequirementsFixture {
            SharedSkillProviderRequirementsFixtureView()
        } else if isOnboardingFixture {
            OnboardingFixtureView()
        } else if isPostSetupNuxFixture {
            PostSetupActivationFixtureView()
        } else if isAIDataSharingConsentFixture {
            AIDataSharingConsentFixtureView()
        } else if isFirstUseHintFixture {
            FirstUseHintPopoverFixtureView()
        } else if isGuidedFlowFixture {
            GuidedFlowFixtureView()
        } else if isOnboardingKeychainErrorFixture {
            OnboardingKeychainErrorFixtureView()
        } else {
            launchContent
        }
        #else
        launchContent
        #endif
    }

    private var isFixtureMode: Bool {
        isChatDiagnosticsFixture || isChatLifecycleFixture || isChatDayDividerFixture || isSettingsFixture || isConnectorsFixture || isAutomationsFixture || isGatewayDetailFixture || isGatewayConnectionRecoveryFixture || isLaunchRecoveryCopyFixture || isRestoredSessionScrollFixture
            || isGatewayUpdateTargetsFixture
            || isVoiceSettingsFixture
            || isGatewayDevicePairingFixture
            || isCloudGatewayDeployFixture
            || isLaunchConnectionRecoveryRouteFixture
            || isChatDiagnosticsRowFixture
            || isBrowserLiveCardFixture
            || isModelPickerFixture
            || isMcpAddServerFixture || isClawHubReviewFixture || isClawHubUnavailableFixture
            || isSkillProviderRequirementsFixture
            || isOnboardingFixture
            || isPostSetupNuxFixture
            || isAIDataSharingConsentFixture
            || isFirstUseHintFixture
            || isGuidedFlowFixture
            || isOnboardingKeychainErrorFixture
            || isCollaborationFixture
            || isTaskDetailFixture
            || isActivityHistoryFixture
            || isAgendaFixture
            || isDailyBriefFixture
    }

    @ViewBuilder
    private var launchContent: some View {
        switch launchState {
        case .splash:
            LaunchScreenView(state: .splash)
        case .connecting, .failed:
            LaunchScreenView(
                state: launchState,
                connectionState: gateway.connectionState,
                gatewayProvider: gateway.activeGatewayProvider,
                onRetry: {
                    launchState = .connecting
                    // Manual retry must also wake the machine, not just reconnect —
                    // the failure that got us here is almost always a slept Fly
                    // gateway, and reconnect() alone doesn't start it.
                    Task { await gateway.wakeGatewayIfNeeded() }
                    gateway.reconnect()
                    waitForConnection()
                },
                onOpenSettings: {
                    showServerSettings = true
                },
                onContinue: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        launchState = .ready
                    }
                }
            )
            .sheet(isPresented: $showServerSettings) {
                NavigationStack {
                    SharedGatewayRecoveryDestinationView(gateway: gateway)
                }
                .environment(gateway)
            }
        case .ready:
            ContentView()
        }
    }

    /// Watches for the gateway to connect, auto-retrying with a re-wake between
    /// attempts instead of dropping to a dead-end `.failed` screen after one
    /// timeout. A managed Fly gateway cold-boot can outlast a single connect
    /// window, so each attempt re-fires the wake ping (which shifts the machine
    /// start earlier) and nudges a fresh reconnect, resolving to `.ready` the
    /// moment the WebSocket handshake actually succeeds. Only after every
    /// attempt is exhausted do we surface the honest `.failed` state (manual
    /// Retry / Continue Anyway remain). The `connectionState` observer above is
    /// the backstop: if the gateway wakes even later, it still flips to ready.
    private func waitForConnection() {
        connectionWatchTask?.cancel()
        connectionWatchTask = Task {
            let perAttemptTimeout: TimeInterval = 10
            let maxAttempts = 4
            var attempt = 0
            while attempt < maxAttempts {
                let start = Date()
                while Date().timeIntervalSince(start) < perAttemptTimeout {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    if gateway.connectionState.isConnected {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            launchState = .ready
                        }
                        return
                    }
                    // A terminal pairing/auth state is NOT a cold start — re-firing
                    // reconnect() would reset the auto-approve budget and stack
                    // overlapping pairing-recovery cycles (#306). Hand off to the
                    // normal Review-Connection / pairing-recovery path immediately.
                    if Self.isTerminalPairingState(gateway.connectionState) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            launchState = .failed
                        }
                        return
                    }
                }
                attempt += 1
                if attempt >= maxAttempts { break }
                // Still not up after this window — re-warm the machine and nudge a
                // fresh reconnect, then keep waiting. Bounded so we never spin
                // forever; the honest `.failed` state follows if the boot never
                // completes within the budget.
                await gateway.wakeGatewayIfNeeded()
                // The wake POST can block up to ~20s, during which the inner 0.5s
                // poll above is NOT running — so the manager's own backoff ladder
                // may have brought the connection UP (or hit a terminal state, or
                // this watch may have been superseded and cancelled) meanwhile.
                // Re-check before reconnect() so we never disconnect() a now-healthy
                // node+operator pair (needless churn/flicker) or fire from a stale
                // watch (wakeGatewayIfNeeded swallows CancellationError).
                if Task.isCancelled { return }
                if gateway.connectionState.isConnected {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        launchState = .ready
                    }
                    return
                }
                if Self.isTerminalPairingState(gateway.connectionState) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        launchState = .failed
                    }
                    return
                }
                gateway.reconnect()
            }
            // Auto-retries exhausted — surface the honest failed state.
            if !gateway.connectionState.isConnected {
                withAnimation(.easeInOut(duration: 0.3)) {
                    launchState = .failed
                }
            }
        }
    }

    /// Terminal connection states that a cold-start auto-retry must NOT loop on:
    /// re-firing `reconnect()` here re-pairs with the same rejected credentials
    /// and stacks pairing-recovery cycles (#306). The launch screen surfaces the
    /// Review-Connection CTA for these instead.
    private static func isTerminalPairingState(_ state: RemGatewayConnectionState) -> Bool {
        switch state {
        case .pairingRequired, .unauthorized:
            return true
        case .disconnected, .connecting, .connected, .unreachable:
            return false
        }
    }

    @MainActor
    private func reconcileUsageStateForAuthChange() async {
        // Billing (StoreKit/IAP entitlements) was stripped from the open-core app.
        // Usage tracking stays; the only auth-driven action left is clearing cached
        // usage when signed out so the next account starts clean.
        guard authService.isAuthenticated else {
            usageService.reset()
            return
        }
    }

    private func handleDeepLink(_ url: URL) {
        if LatestBriefDeepLink.isListenRequest(url) {
            guard let targetAccountID = LatestBriefDeepLink.validatedAccountID(
                from: url,
                isAuthenticated: authService.isAuthenticated,
                currentUserID: authService.currentUser?.id
            )
            else { return }
            voiceControlRouter.enqueue(
                .readLatestBrief,
                accountID: targetAccountID
            )
            return
        }

        if let command = VoiceSessionDeepLink.command(from: url) {
            voiceControlRouter.enqueue(command)
            return
        }

        if let command = FocusSessionDeepLink.command(from: url) {
            focusControlRouter.enqueue(command)
            return
        }

        // Composio Connect completes via the system browser + backend status
        // poll (SharedComposioConnectionsView), not an app-owned redirect
        // callback, so there is no OAuth callback to intercept here.

        guard url.scheme == "remclaw", url.host == "connect" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let items = components?.queryItems,
              let gatewayURL = items.first(where: { $0.name == "url" })?.value,
              let gatewayToken = items.first(where: { $0.name == "token" })?.value
        else { return }
        gateway.configure(gatewayURL: gatewayURL, gatewayToken: gatewayToken)
    }

    /// UIKit can publish a cold-launch notification URL before the async stored-token check has
    /// identified the receiving account. Keep that URL in the launch-owned slot until auth
    /// restoration completes; `body.task` then binds the brief command to the restored account.
    /// A genuinely signed-out launch still consumes and discards the URL after the auth check, so
    /// it can never replay into a later, different sign-in.
    private func handleOrDeferDeepLinkUntilAuthRestores(_ url: URL) {
        if LatestBriefDeepLink.isListenRequest(url),
           LatestBriefDeepLink.shouldDeferUntilAuthRestores(
               isCheckingAuth: authService.isCheckingAuth
           ) {
            AppDelegate.pendingOpenedURL = url
            return
        }
        AppDelegate.pendingOpenedURL = nil
        handleDeepLink(url)
    }
}
