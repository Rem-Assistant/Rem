import SwiftUI
import SwiftData
import Combine
import OpenClawChatUI
import OpenClawKit
import WidgetKit

enum DailyOrchestratorChatRouting {
    static let durableSessionKey = DailyBriefTranscriptReconciler.durableSessionKey

    struct Route: Equatable {
        let sessionKey: String
        let isFresh: Bool
    }

    /// Summary is a doorway into one durable Today conversation. The server field remains an
    /// input for wire compatibility, but even an older backend advertising `rem-today-*` must not
    /// fork modern clients back into a per-day thread.
    static func compatibleConversationKey(_ apiSessionKey: String?) -> String {
        _ = apiSessionKey
        return durableSessionKey
    }

    static func conversationRoute(
        apiSessionKey: String?
    ) -> Route {
        Route(sessionKey: compatibleConversationKey(apiSessionKey), isFresh: false)
    }

    static func freshGeneralRoute(id: UUID = UUID()) -> Route {
        Route(
            sessionKey: "chat-\(id.uuidString.prefix(8).lowercased())",
            isFresh: true
        )
    }
}

/// Root view — gates on authentication, then on gateway configuration,
/// then on permissions onboarding (fresh install only).
struct ContentView: View {
    @Environment(RemGatewaySessionManager.self) private var gateway
    @Environment(RemAuthService.self) private var authService

    var body: some View {
        if !authService.isAuthenticated || !gateway.isConfigured || authService.isReturningUser || gateway.isCompletingDeploy {
            OnboardingFlow()
                .transition(.opacity)
        } else {
            RemMainTabView()
                .transition(.opacity)
        }
    }
}

private struct FirstUseHintCard: View {
    let onStartChat: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.brandBlue)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text("Start by asking Rem")
                    .font(DesignTokens.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignTokens.Color.labelPrimary)
                Text("Use the chat button or mic to capture a plan, task list, or reminder.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: onStartChat) {
                Image(systemName: "message.badge.waveform.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.brandBlue)
            .accessibilityLabel("Start chat")
            .accessibilityIdentifier("FirstUseHintStartChatButton")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Color.labelSecondary)
            .accessibilityLabel("Dismiss first-use hint")
            .accessibilityIdentifier("FirstUseHintDismissButton")
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DesignTokens.Color.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignTokens.Color.separator.opacity(0.5), lineWidth: 1)
        )
        .accessibilityIdentifier("FirstUseHintCard")
    }
}

#if DEBUG
struct FirstUseHintPopoverFixtureView: View {
    @State private var showHint = false

    var body: some View {
        VStack {
            Spacer()

            Button {
                showHint = true
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(DesignTokens.Typography.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.Color.brandBlue)
            .popover(isPresented: $showHint, arrowEdge: .bottom) {
                FirstUseHintCard(
                    onStartChat: { showHint = false },
                    onDismiss: { showHint = false }
                )
                .frame(maxWidth: 360)
                .padding(DesignTokens.Spacing.sm)
            }
            .accessibilityIdentifier("FirstUseHintFixtureButton")

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Color.backgroundPrimary)
        .task {
            showHint = true
        }
    }
}
#endif

// MARK: - Main Bottom Toolbar

/// The Rem main tab bar — hamburger (tab switch) · new-chat · plus (create) —
/// factored out of `RemMainTabView` so both the live app and the README Agenda
/// fixture drive the *same* controls inside a real `.bottomBar` toolbar group,
/// rather than the fixture hand-drawing an approximation. Kept as a
/// `@ViewBuilder` free function (not a `View` struct) so the controls flatten
/// into individual toolbar items exactly as the inline property did.
@ViewBuilder
func remMainBottomToolbar(
    selectedTab: AppTab,
    hasActiveSession: Bool,
    firstUseHintPresented: Binding<Bool>,
    onSelectTab: @escaping (AppTab) -> Void,
    onNewChat: @escaping () -> Void,
    onDismissFirstUseHint: @escaping () -> Void,
    onCreateTask: @escaping () -> Void,
    onNewFolder: @escaping () -> Void,
    onNewList: @escaping () -> Void
) -> some View {
    // Hamburger menu — switches between tabs
    Menu {
        ForEach([AppTab.settings, .history, .inbox, .agenda], id: \.self) { tab in
            Button {
                onSelectTab(tab)
            } label: {
                Label(tab.title, systemImage: tab.icon)
            }
        }
    } label: {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 20, weight: .medium))
    }
    .accessibilityIdentifier("menu-button")
    .accessibilityLabel("Menu")

    Spacer()

    // New chat (center) — hidden on Settings and when a session is active
    if selectedTab != .settings && !hasActiveSession {
        Button { onNewChat() } label: {
            Image(systemName: "message.badge.waveform.fill")
                .font(.system(size: 20, weight: .medium))
        }
        .buttonStyle(.borderedProminent)
        .tint(DesignTokens.Color.brandBlue)
        .popover(isPresented: firstUseHintPresented, arrowEdge: .bottom) {
            FirstUseHintCard(
                onStartChat: {
                    onDismissFirstUseHint()
                    onNewChat()
                },
                onDismiss: { onDismissFirstUseHint() }
            )
            .frame(maxWidth: 360)
            .padding(DesignTokens.Spacing.sm)
        }
        .accessibilityIdentifier("new-chat-button")
        .accessibilityLabel("New Chat")
        Spacer()
    }

    // Plus (create) — visible on Agenda/Inbox only. Sorted-style: the "+"
    // creates a Task/Event (the primary action), or a List/Folder to organize.
    // "View by List" moved to the agenda's in-list Sort control.
    if selectedTab == .agenda || selectedTab == .inbox {
        Menu {
            Button {
                onCreateTask()
            } label: {
                Label("New Task or Event", systemImage: "checklist")
            }
            Divider()
            Button {
                onNewFolder()
            } label: {
                Label("New Folder", systemImage: "folder")
            }
            Button {
                onNewList()
            } label: {
                Label("New List", systemImage: "list.bullet")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
        }
        .accessibilityIdentifier("create-task-button")
        .accessibilityLabel("Create")
    }
}

// MARK: - App Tab

enum AppTab: Int, CaseIterable {
    case agenda = 0
    case inbox = 1
    case history = 2
    case settings = 3

    var title: String {
        switch self {
        case .agenda: "Agenda"
        case .inbox: "Inbox"
        case .history: "Chat Sessions"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .agenda: "calendar"
        case .inbox: "tray"
        case .history: "clock.arrow.circlepath"
        case .settings: "gear"
        }
    }
}

/// Selects exactly one owner for connection recovery. Chat Sessions and pushed chat destinations
/// own the canonical chat recovery card; other root tabs use the app-wide banner.
enum MainConnectionRecoveryBannerPolicy {
    static func shouldShow(
        isConfigured: Bool,
        isConnected: Bool,
        isCompletingDeploy: Bool,
        selectedTab: AppTab,
        hasNavigationDestination: Bool
    ) -> Bool {
        isConfigured
            && !isConnected
            && !isCompletingDeploy
            && selectedTab != .settings
            && selectedTab != .history
            && !hasNavigationDestination
    }
}

@MainActor
enum GatewayConnectionRecovery {
    /// Mirrors launch recovery: reconnect immediately while the managed-gateway wake request runs.
    /// Returning the task keeps the side effects directly testable without changing call-site UX.
    @discardableResult
    static func retry(
        wake: @escaping @MainActor () async -> Void,
        reconnect: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        let wakeTask = Task { await wake() }
        reconnect()
        return wakeTask
    }
}

// MARK: - Navigation Destination

struct ChatDestination: Hashable {
    let sessionKey: String
    var autoStartVoice: Bool = false
    var prefill: String?
    /// Agenda prose shown inside the durable Today chat until today's real assistant artifact or
    /// reply is present. This prevents a pending delivery from opening an apparently unrelated or
    /// empty transcript while keeping the gateway history authoritative once it lands.
    var briefPreviewMarkdown: String? = nil
    /// The Summary "Read latest brief" doorway opens at today's first delivered assistant message,
    /// rather than applying the normal restored-chat bottom scroll.
    var scrollToLatestBrief: Bool = false
    /// True when this destination minted a BRAND-NEW session key (New conversation, a tapped
    /// starter, a skill/capability hand-off) that has no server-side history to load. Drives
    /// `SharedRemChatView`'s skeleton gate so a new chat shows the starter immediately instead of
    /// shimmering. Defaults to `false` so opens of existing sessions keep the loading skeleton.
    var isFresh: Bool = false
    /// The title already shown in the Chat Sessions row that opened this destination. Non-nil means
    /// this is a known existing conversation whose history must be represented as loading from the
    /// destination's very first frame; it also prevents a transient "New conversation" title.
    var existingSessionTitle: String?
}

/// Identity key for the chat view's session/prefill `.task`. Keyed on **both**
/// the session key and the live `OpenClawChatViewModel` *instance* so the task
/// re-runs when a different route needs a fresh model (which zeroes `input`). A
/// same-session re-entry intentionally retains the existing model; see
/// `ChatSessionViewModelReusePolicy` below.
private struct ChatSessionTaskID: Hashable {
    let sessionKey: String
    let viewModelID: ObjectIdentifier
}

/// Pure route policy for retaining an already-painted chat model across a Back -> reopen cycle.
/// The navigation root clears `gateway.mainSessionKey` so its New Chat affordance can return, but
/// that routing sentinel is not permission to discard the transcript. Reuse is safe only when both
/// the requested session and the complete gateway/device binding are unchanged; another session or
/// gateway still receives a newly bound transport and view model.
nonisolated enum ChatSessionViewModelReusePolicy {
    static func canReuse(
        requestedSessionKey: String,
        currentSessionKey: String,
        currentBindingKey: String?,
        requestedBindingKey: String
    ) -> Bool {
        let requested = requestedSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = currentSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, requested == current else { return false }
        return currentBindingKey == requestedBindingKey
    }
}

/// Owns the synchronous decision at the `mainSessionKey` navigation boundary so tests exercise
/// both side effects—not only the predicate. The previous route may be nil after Back; retained
/// model identity remains authoritative until this coordinator either loads it or requests a
/// replacement.
@MainActor
enum ChatSessionViewModelActivationCoordinator {
    enum Outcome: Equatable {
        case reusedWarmModel
        case requestedReplacement
    }

    struct Request {
        let previousRoutingSessionKey: String?
        let requestedSessionKey: String
        let retainedSessionKey: String?
        let retainedBindingKey: String?
        let requestedBindingKey: String
    }

    @discardableResult
    static func activate(
        _ request: Request,
        reuse: () -> Void,
        replace: () -> Void
    ) -> Outcome {
        // `previousRoutingSessionKey` intentionally does not authorize cache reuse. Back clears it
        // to nil, while session + complete binding identity decide whether retained state is safe.
        if ChatSessionViewModelReusePolicy.canReuse(
            requestedSessionKey: request.requestedSessionKey,
            currentSessionKey: request.retainedSessionKey ?? "",
            currentBindingKey: request.retainedBindingKey,
            requestedBindingKey: request.requestedBindingKey
        ) {
            reuse()
            return .reusedWarmModel
        }
        replace()
        return .requestedReplacement
    }
}

/// Pushed destination for **"View history"** — the full activity/comment thread for
/// a task, keyed by its backend id. A dedicated view (not a chat) so View history
/// reliably opens for every item, then offers its own doorway into the task-scoped
/// chat. See `TaskActivityHistoryView`.
struct TaskActivityHistoryDestination: Hashable {
    let taskId: String
}

// MARK: - Main app view (hamburger menu + NavigationStack)

struct RemMainTabView: View {
    @Environment(RemGatewaySessionManager.self) private var gateway
    @Environment(RemAuthService.self) private var authService
    @Environment(UsageService.self) private var usageService
    @Environment(VoiceSessionControlRouter.self) private var voiceControlRouter
    @Environment(FocusSessionControlRouter.self) private var focusControlRouter
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab: AppTab = .agenda
    @State private var navigationPath = NavigationPath()
    @State private var voiceCommandOwnerID = UUID()
    @State private var showInboxToast = false
    @State private var showConnectionRecovery = false
    /// Transient app-wide toast (e.g. "Reconnected"). See `RemToast`.
    @State private var toast: RemToastItem?
    // Organization (Sorted-style) — create sheets presented from the "+" menu.
    @State private var showCreateList = false
    @State private var showCreateFolder = false
    /// Live view of Rem's cloud browser — owned here so the agent can summon it from any tab.
    @State private var browserView = BrowserViewCoordinator()
    // First-run conversational capture — orient the human, persist answers to memory.
    @State private var showConversationalCapture = false
    @AppStorage("rem.hasSeenPostSetupActivation.v1") private var hasSeenPostSetupActivation = false
    @AppStorage("rem.hasDismissedFirstUseHint.v1") private var hasDismissedFirstUseHint = false
    /// One-time gate: conversational capture has been shown (completed or skipped). See
    /// `ConversationalCaptureView`.
    @AppStorage("rem.hasCompletedConversationalCapture.v1") private var hasCompletedConversationalCapture = false
    /// Account-scoped completion receipts for explicit Today brief narration. A receipt changes
    /// only after the matching authored message finishes; interruption never marks it read.
    @AppStorage("rem.completedDailyBriefPlaybackReceipts.v2")
    private var completedDailyBriefPlaybackReceipts = ""

    // Shared chat ViewModel — used by both History and Chat views
    @State private var chatViewModel: OpenClawChatViewModel?
    @State private var chatViewModelBindingKey: String?
    @State private var chatRequestSlotHandoff = TextRequestSlotHandoff()
    @State private var runLifecycleEvidenceStore = RunLifecycleEvidenceStore()
    @State private var chatTransportSetupGate = ChatTransportSetupGate()
    @State private var latestBriefPlayback = LatestBriefPlaybackController()
    @State private var briefPlaybackAccountID: String?
    /// The durable Today message resolved after navigation began. The destination first carries
    /// Agenda's fast preview; publishing this value retargets the active chat to the actual message
    /// once `chat.history` identifies it.
    @State private var resolvedBriefNavigationMarkdown: String?

    // Shared task store — single source of truth for all tasks
    @State private var taskStore: TaskStore?

    // ViewModels
    @State private var agendaViewModel: AgendaViewModel?
    @State private var inboxViewModel: InboxViewModel?

    // Voice session state (TalkMode: Apple STT + chat.send + ElevenLabs TTS)
    @State private var talkMode = RemTalkModeManager()
    @State private var talkStartDate: Date?
    @State private var failedBriefRetryCompletion: (() -> Void)?
    @State private var failedBriefRetryContext: ExplicitSpeechRetryContext?
#if canImport(ActivityKit) && os(iOS)
    @State private var voiceLiveActivity = VoiceSessionLiveActivityManager()
#endif

    // Focus session
    @StateObject private var focusSessionManager = FocusSessionManager()
    @State private var activeFocusSession: FocusSession?
    @State private var focusTimerMinimized = false

    // Central @Query — feeds the shared TaskStore
    @Query(sort: [SortDescriptor(\TaskEvent.createdAt, order: .reverse)], animation: .default)
    private var allTasks: [TaskEvent]

    // Services
    @StateObject private var calendarService = RemCalendarService()
    private let taskApiService = RemTaskApiService()
    private let organizationApiService = OrganizationApiService()
    @State private var taskSyncService: RemTaskSyncService?

    // Bridges a task's persisted cloud-run transcript into the chat's history load so
    // a task-scoped continuation chat opens the REAL prior conversation (#869 / #874).
    private let taskChatTranscriptCoordinator =
        TaskChatTranscriptCoordinator(service: TaskCommentService())

    var body: some View {
        accountAwareMainContent
    }

    private var accountAwareMainContent: some View {
        mainContent.task(id: authService.currentUser?.id) {
            let currentAccountID = authService.currentUser?.id
            defer { briefPlaybackAccountID = currentAccountID }
            handleBriefPlaybackAccountTransition(
                previousAccountID: briefPlaybackAccountID,
                currentAccountID: currentAccountID
            )
        }
        .task(id: browserAuthenticatedScope) {
            browserView.activateAuthenticatedScope(
                accountID: browserAuthenticatedScope?.accountID,
                gatewayURL: browserAuthenticatedScope?.gatewayIdentity
            )
        }
        .onDisappear {
            browserView.terminateAuthenticatedSession()
            tearDownBriefPlaybackOnAuthenticatedRootDisappearance()
        }
    }

    private var browserAuthenticatedScope: BrowserEndedOwnershipScope? {
        BrowserEndedOwnershipScope(
            accountID: authService.currentUser?.id,
            gatewayURL: gateway.storedGatewayURL
        )
    }

    private var agendaSuggestionMutationScope: AgendaSuggestionMutationScope? {
        AgendaSuggestionMutationScope(
            accountID: authService.currentUser?.id,
            backendURL: RemCredentialStore.backendURL ?? AppConfig.apiBaseURL,
            gatewayURL: gateway.storedGatewayURL
        )
    }

    /// Backend JWT subject used to scope the published brief headline. Hoisted into its own
    /// property rather than written inline at the `AgendaViewModel(...)` call: `mainContent` is
    /// already at the compiler's practical type-checking limit (see its note below), and one more
    /// inline closure in that expression tips it over into "unable to type-check in reasonable
    /// time". Keep new closures for that initializer out here.
    private var briefHeadlineAccountID: AgendaViewModel.BriefAccountIDProvider {
        { gateway.authenticatedAccountIDForRecovery }
    }

    private var mainContent: some View {
        // Keep the long-lived presentation and lifecycle modifier groups behind explicit
        // type-erasure boundaries. Adding brief playback observation pushed this root's generic
        // SwiftUI type past the compiler's practical type-checking limit; the boundaries preserve
        // the same modifier order and behavior while keeping incremental builds deterministic.
        AnyView(
            AnyView(
                mainContentLayout
        .sheet(isPresented: $showConnectionRecovery) {
            NavigationStack {
                SharedGatewayRecoveryDestinationView(gateway: gateway)
            }
            .environment(gateway)
        }
        // Live view of Rem's cloud browser (doc 37). Opened either by the user tapping the card
        // in chat, or by the agent calling `canvas.present` at a wall it can't get past alone.
        .sheet(isPresented: Binding(
            get: { browserView.session.isPresented },
            set: { if !$0 { browserView.dismiss() } }
        )) {
            SharedBrowserLiveSheet(session: browserView.session) { browserView.dismiss() }
        }
        // Backs both the card in chat and the sheet above.
        .environment(browserView.session)
        // Transient, non-blocking toast overlay (top safe-area). Non-actionable
        // confirmations/notifications; auto-dismisses. See `RemToast`.
        .remToast(item: $toast)
        // Surface a "Reconnected" toast when the node session recovers from a
        // disconnect the user actually saw. `lastReconnectAt` is stamped only for a
        // visible-backoff recovery, debounced — never a grace blip, cold start, or
        // routine foreground resume (see RemReconnectToastPolicy).
        .onChange(of: gateway.lastReconnectAt) { _, newValue in
            guard newValue != nil else { return }
            toast = .success("Reconnected")
        }
        .sheet(isPresented: $showCreateList) {
            CreateListSheet(apiService: organizationApiService)
        }
        .sheet(isPresented: $showCreateFolder) {
            CreateFolderSheet(apiService: organizationApiService)
        }
        .sheet(isPresented: $showConversationalCapture) {
            ConversationalCaptureView(greetingName: captureGreetingName) {
                hasCompletedConversationalCapture = true
                showConversationalCapture = false
            }
            .interactiveDismissDisabled()
        }
        .fullScreenCover(item: $activeFocusSession, onDismiss: {
            if focusSessionManager.currentSession != nil {
                focusTimerMinimized = true
            }
        }) { session in
            FocusTimerView(
                manager: focusSessionManager,
                session: session,
                onStartNewSession: nil
            )
        }
        .onChange(of: focusSessionManager.currentSession) { _, newSession in
            if let session = newSession, session.status != .completed && session.status != .cancelled {
                if activeFocusSession == nil && !focusTimerMinimized {
                    activeFocusSession = session
                }
            } else if newSession == nil {
                activeFocusSession = nil
                focusTimerMinimized = false
            }
        }
        .environment(\.taskApiService, taskApiService)
        .environment(\.taskSyncService, taskSyncService)
        // Inject on the VStack (an ANCESTOR of the NavigationStack), not on the
        // NavigationStack itself. A NavigationStack seeds its pushed destinations'
        // environment from its *enclosing* scope, so custom EnvironmentKey values
        // applied directly to the stack (or to its root content) do NOT reach views
        // pushed via NavigationLink — they read nil. Values applied to an ancestor
        // (how `gateway`/`taskApiService`/Mac's `localGateway` are injected) DO
        // propagate to those destinations. This is why `openSkillSetupChat` was nil
        // deep in the Settings subtree (Capabilities Install silently no-oped). See
        // SharedSkillsSettingsView, which reads \.openSkillSetupChat two pushes deep.
        .environment(\.openSkillSetupChat) { request in
            openSkillSetupChat(request)
        }
                .environmentObject(calendarService)
            )
        .task {
            let syncService = RemTaskSyncService(
                taskApiService: taskApiService,
                modelContext: modelContext,
                calendarService: calendarService
            )
            taskSyncService = syncService
            AppDelegate.sharedTaskSyncService = syncService

            let store = TaskStore(taskSyncService: syncService)
            store.update(allTasks)
            taskStore = store

            focusSessionManager.modelContext = modelContext
            focusSessionManager.taskSyncService = syncService

            if agendaViewModel == nil {
                agendaViewModel = AgendaViewModel(
                    modelContext: modelContext,
                    taskStore: store,
                    calendarService: calendarService,
                    taskApiService: taskApiService,
                    taskSyncService: syncService,
                    briefHistoryProvider: { sessionKey in
                        let params = DailyBriefTranscriptReconciler.requestParameters(
                            sessionKey: sessionKey
                        )
                        return try await gateway.skillsRequest(
                            method: "chat.history",
                            paramsJSON: params,
                            timeoutSeconds: 15
                        )
                    },
                    suggestionMutationScope: {
                        AgendaSuggestionMutationScope(
                            accountID: authService.currentUser?.id,
                            backendURL: RemCredentialStore.backendURL ?? AppConfig.apiBaseURL,
                            gatewayURL: gateway.storedGatewayURL
                        )
                    }
                )
                // Assigned here rather than passed to `init`: one more argument in that call tips
                // `mainContent` over the compiler's type-checking limit. The value is the backend
                // JWT subject — NOT `authService.currentUser?.id`, which is a different
                // identifier. The chat views read the headline back with
                // `gateway.authenticatedAccountIDForRecovery`, so the writer must stamp with that
                // same value or the headline would never match on read.
                agendaViewModel?.briefAccountID = briefHeadlineAccountID
            }
            resumePendingExternalBriefReadIfReady()
            if inboxViewModel == nil {
                inboxViewModel = InboxViewModel(
                    modelContext: modelContext,
                    taskStore: store,
                    calendarService: calendarService,
                    taskApiService: taskApiService,
                    taskSyncService: syncService
                )
            }

            NodeInvocationRouter.configureTaskAccess(
                modelContext: { modelContext },
                taskSyncService: { syncService },
                taskApiService: { taskApiService },
                organizationApiService: { organizationApiService }
            )

            // Pull Folders + Lists into local SwiftData (task-sync pattern).
            let orgSync = OrganizationSyncManager(
                apiService: organizationApiService,
                modelContext: modelContext
            )
            await orgSync.syncFromBackend()
            NodeInvocationRouter.configureVoiceStateProvider { [talkMode] in
                talkMode.isEnabled
            }
            CanvasCommandHandler.configure(coordinator: { [browserView] in browserView })
            // Takeover handshake: taking over the live browser pauses the agent (chat.abort) so it
            // stops driving the page; handing back resumes it (chat.send). Wired here rather than in
            // the shared session so the app-specific gateway does the RPCs (which it coalesces).
            browserView.session.onControlIntentChanged = { [gateway] controlling in
                guard controlling else { return }
                // Synchronous: it registers the (coalesced, serialized) work and returns immediately.
                Task { @MainActor in gateway.signalBrowserTakeover(userIsControlling: true) }
            }
            browserView.session.onRequestHandBack = {
                await requestBrowserHandBack()
            }

            await store.sync()
            await setupChatViewModel()
            if let activeKey = gateway.mainSessionKey {
                await gateway.bindSessionToCurrentDeviceNode(sessionKey: activeKey)
            }

            // Wire TalkMode to gateway (use chat/operator session for chat.send, chat.history, server events)
            let session = await gateway.client.chatSession
            talkMode.attachGateway(session)
            talkMode.attachUsageService(usageService)
            talkMode.updateGatewayConnected(gateway.connectionState.isConnected)
            talkMode.updateSessionKey(gateway.mainSessionKey)
        }
        .onChange(of: gateway.connectionState) { _, newState in
            talkMode.updateGatewayConnected(newState.isConnected)
            if newState.isConnected {
                Task { await setupChatViewModel() }
            } else {
                chatTransportSetupGate.invalidate()
                chatViewModelBindingKey = nil
            }
            if newState.isConnected, let activeKey = gateway.mainSessionKey {
                Task { await gateway.bindSessionToCurrentDeviceNode(sessionKey: activeKey) }
            }
        }
        .onChange(of: gateway.operatorReady) { _, ready in
            if ready && gateway.connectionState.isConnected {
                Task { await agendaViewModel?.recoverBriefAfterOperatorReady() }
                if chatViewModel == nil {
                    // Operator is ready but chatViewModel was never created
                    Task { await setupChatViewModel() }
                } else {
                    // Operator reconnected after a drop — refresh sessions
                    // so the Chats tab picks up the restored connection.
                    chatViewModel?.refreshSessions(limit: 100)
                }
                if let activeKey = gateway.mainSessionKey {
                    Task { await gateway.bindSessionToCurrentDeviceNode(sessionKey: activeKey) }
                }
            } else {
                chatTransportSetupGate.invalidate()
            }
        }
        .onChange(of: gateway.mainSessionKey) { oldKey, newKey in
            talkMode.updateSessionKey(newKey)
            if failedBriefRetryContext?.sessionKey != newKey {
                invalidateBriefRetryRecovery()
            }
            chatTransportSetupGate.invalidate()
            if let newKey {
                let requestedBindingKey = chatBindingKey(sessionKey: newKey)
                ChatSessionViewModelActivationCoordinator.activate(
                    .init(
                        previousRoutingSessionKey: oldKey,
                        requestedSessionKey: newKey,
                        retainedSessionKey: chatViewModel?.sessionKey,
                        retainedBindingKey: chatViewModelBindingKey,
                        requestedBindingKey: requestedBindingKey
                    ),
                    reuse: {
                        // Appearance is idempotent for a usable warm generation and remains
                        // retryable after a failed bootstrap. Keep the painted transcript while
                        // rebinding the device instead of installing an empty model during nav.
                        chatViewModel?.load()
                        Task {
                            guard gateway.mainSessionKey == newKey else { return }
                            await gateway.bindSessionToCurrentDeviceNode(sessionKey: newKey)
                        }
                    },
                    replace: {
                        Task {
                            guard await setupChatViewModel(force: true),
                                  gateway.mainSessionKey == newKey
                            else { return }
                            chatViewModel?.switchSession(to: newKey)
                            await gateway.bindSessionToCurrentDeviceNode(sessionKey: newKey)
                        }
                    }
                )
            }
        }
        .onChange(of: gateway.storedGatewayURL) { _, _ in
            invalidateBriefRetryRecovery()
            chatTransportSetupGate.invalidate()
            chatViewModel = nil
            chatViewModelBindingKey = nil
            Task { await setupChatViewModel(force: true) }
        }
        .task(id: agendaSuggestionMutationScope) {
            agendaViewModel?.invalidateSuggestionAuthority()
            guard BriefContext.isDurableOrchestratorSession(gateway.mainSessionKey ?? "") else { return }
            await agendaViewModel?.refreshBriefAndSuggestions()
        }
        )
        .onReceive(agendaBriefChanges) { _ in
            let currentContext = currentExplicitBriefRetryContext()
            if ExplicitSpeechPlaybackContextPolicy.shouldCancel(
                expected: failedBriefRetryContext,
                current: currentContext,
                playbackIsActive: talkMode.isReadingAloud || talkMode.canRetryReadingAloud
            ) {
                invalidateBriefRetryRecovery()
            }
        }
        .onChange(of: navigationPath) { oldPath, newPath in
            if newPath.isEmpty && !talkMode.isEnabled {
                // User popped back with no active voice session. Do not delete
                // the current gateway session here: server-backed chats may not
                // have local preview metadata on this device yet, and deleting
                // them on navigation makes real chat history disappear.
                gateway.mainSessionKey = nil
            }
        }
        .task(id: voiceControlRouter.commandToken) {
            let token = voiceControlRouter.commandToken
            guard let command = voiceControlRouter.claimCommand(
                for: token,
                accountID: authService.currentUser?.id,
                ownerID: voiceCommandOwnerID
            ) else { return }
            if await handleExternalVoiceCommand(command) {
                voiceControlRouter.acknowledgeCommand(for: token, ownerID: voiceCommandOwnerID)
            }
        }
        .task(id: focusControlRouter.commandToken) {
            await handleExternalFocusCommand(focusControlRouter.latestCommand)
        }
        .onChange(of: allTasks) { _, newTasks in
            taskStore?.update(newTasks)
        }
        .onChange(of: talkMode.isEnabled) { _, isEnabled in
            if !isEnabled {
                latestBriefPlayback.endVoiceSession()
            }
            syncVoiceLiveActivity()
        }
        .onChange(of: talkMode.statusText) { _, _ in
            syncVoiceLiveActivity()
        }
        .onChange(of: talkMode.isListening) { _, _ in
            syncVoiceLiveActivity()
        }
        .onChange(of: talkMode.isSpeaking) { _, _ in
            syncVoiceLiveActivity()
        }
        .onChange(of: talkMode.messages.count) { _, _ in
            syncVoiceLiveActivity()
        }
        .onAppear { maybePresentConversationalCapture() }
        .onDisappear {
            voiceControlRouter.releaseCommand(ownerID: voiceCommandOwnerID)
        }
        // On cold launch no voice session is active, so any live Voice Live Activity is an orphan
        // stranded on the lock screen by a previous run that was killed mid-session. Sweep it. (#1068)
        .task { await voiceLiveActivity.reconcileStaleActivitiesAtLaunch() }
        .onChange(of: hasSeenPostSetupActivation) { _, _ in
            maybePresentConversationalCapture()
        }
    }

    private var mainContentLayout: some View {
        VStack(spacing: 0) {
            if shouldShowConnectionRecoveryBanner {
                GatewayDisconnectedBanner(gatewayProvider: gateway.activeGatewayProvider) {
                    showConnectionRecovery = true
                }
            }

            NavigationStack(path: $navigationPath) {
                selectedTabContent
                    .navigationDestination(for: ChatDestination.self) { dest in
                        chatView(
                            sessionKey: dest.sessionKey,
                            autoStartVoice: dest.autoStartVoice,
                            prefill: dest.prefill,
                            briefPreviewMarkdown: dest.briefPreviewMarkdown,
                            resolvedBriefMarkdown: dest.scrollToLatestBrief
                                ? $resolvedBriefNavigationMarkdown
                                : .constant(nil),
                            scrollToLatestBrief: dest.scrollToLatestBrief,
                            isFresh: dest.isFresh,
                            existingSessionTitle: dest.existingSessionTitle
                        )
                    }
                    .navigationDestination(for: String.self) { destination in
                        taskNavigationDestination(for: destination)
                    }
                    .navigationDestination(for: UUID.self) { taskID in
                        editDestination(for: taskID)
                    }
                    .navigationDestination(for: TaskActivityHistoryDestination.self) { dest in
                        taskActivityHistoryDestination(for: dest.taskId)
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .bottomBar) {
                            bottomToolbar
                        }
                    }
            }

            // Minimized focus session bar
            if focusSessionManager.currentSession != nil && activeFocusSession == nil && navigationPath.isEmpty {
                focusMiniPlayerBar
            }

            // Voice bar below toolbar on tab screens (chat view renders its own)
            if talkMode.isEnabled && navigationPath.isEmpty {
                voiceMiniPlayerBar
            }
        }
    }

    /// Presents the first-run conversational capture once, after the user has finished
    /// gateway setup (post-setup activation seen) and not yet completed/skipped capture.
    /// The sentinel flips inside the sheet's `onFinish`, so this never re-presents.
    private func maybePresentConversationalCapture() {
        guard hasSeenPostSetupActivation,
              !hasCompletedConversationalCapture,
              !showConversationalCapture else { return }
        showConversationalCapture = true
    }

    /// First name (or email handle) for the capture greeting; nil falls back to a generic hello.
    private var captureGreetingName: String? {
        if let first = authService.currentUser?.first_name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return first
        }
        if let full = authService.currentUser?.full_name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !full.isEmpty {
            return full.components(separatedBy: " ").first
        }
        if let email = authService.currentUser?.email {
            return email.components(separatedBy: "@").first
        }
        return nil
    }

    private var shouldShowConnectionRecoveryBanner: Bool {
        MainConnectionRecoveryBannerPolicy.shouldShow(
            isConfigured: gateway.isConfigured,
            isConnected: gateway.connectionState.isConnected,
            isCompletingDeploy: gateway.isCompletingDeploy,
            selectedTab: selectedTab,
            hasNavigationDestination: !navigationPath.isEmpty
        )
    }

    private func retryGatewayConnection() {
        GatewayConnectionRecovery.retry(
            wake: { await gateway.wakeGatewayIfNeeded() },
            reconnect: { gateway.reconnect() }
        )
    }

    private var shouldShowFirstUseHint: Bool {
        hasSeenPostSetupActivation
            && !hasDismissedFirstUseHint
            && navigationPath.isEmpty
            && selectedTab != .settings
            && gateway.connectionState.isConnected
    }

    // MARK: - Chat ViewModel Setup

    private func chatBindingKey(sessionKey: String) -> String {
        let deviceId = DeviceIdentityStore.loadOrCreate().deviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [gateway.storedGatewayURL ?? "", sessionKey, deviceId]
            .joined(separator: "|")
    }

    @discardableResult
    private func setupChatViewModel(force: Bool = false) async -> Bool {
        guard gateway.connectionState.isConnected else { return false }
        guard gateway.operatorReady else { return false }

        let key = gateway.mainSessionKey ?? "main"
        let bindingKey = chatBindingKey(sessionKey: key)

        if !force, chatViewModel != nil, chatViewModelBindingKey == bindingKey {
            return true
        }

        let setupTicket = chatTransportSetupGate.begin(bindingKey: bindingKey)
        let coordinator = taskChatTranscriptCoordinator
        let liveBrowserSession = browserView.session
        let initialLifecycleLease = runLifecycleEvidenceStore.beginTransportEpoch()
        let requestSlotHandoff = TextRequestSlotHandoff()
        let transport = await gateway.makeChatTransport(
            onChatSendAccepted: { [usageService, requestSlotHandoff] in
                requestSlotHandoff.accept(using: usageService)
            },
            priorTranscriptProvider: { sessionKey in
                try await coordinator.priorHistoryMessages(sessionKey: sessionKey)
            },
            onBrowserRunBegan: { [weak liveBrowserSession] sessionKey, browserRequested in
                liveBrowserSession?.beginBrowserRun(
                    for: sessionKey,
                    browserRequested: browserRequested
                )
            },
            onBrowserRunEnded: { [weak liveBrowserSession] sessionKey, runID in
                liveBrowserSession?.endBrowserRunEnsuringPresentation(
                    for: sessionKey,
                    runID: runID
                )
            },
            onBrowserRunCancelled: { [weak liveBrowserSession] sessionKey in
                liveBrowserSession?.cancelPendingBrowserRun(for: sessionKey)
            },
            onBrowserToolActivity: { [weak liveBrowserSession] activity in
                liveBrowserSession?.recordBrowserToolActivity(activity)
            },
            onRunLifecycleEvidence: { [runLifecycleEvidenceStore] evidence in
                runLifecycleEvidenceStore.record(evidence)
            },
            lifecycleEpochSource: runLifecycleEvidenceStore.epochSource,
            initialLifecycleLease: initialLifecycleLease,
            onRunLifecycleEpoch: { [runLifecycleEvidenceStore] epoch in
                runLifecycleEvidenceStore.setCurrentConnectionEpoch(epoch)
            }
        )
        return chatTransportSetupGate.commit(
            setupTicket,
            currentBindingKey: chatBindingKey(sessionKey: gateway.mainSessionKey ?? "main"),
            isReady: gateway.connectionState.isConnected && gateway.operatorReady
        ) {
            let viewModel = OpenClawChatViewModel(
                sessionKey: key,
                transport: transport
            )
            chatViewModel = viewModel
            chatViewModelBindingKey = bindingKey
            chatRequestSlotHandoff = requestSlotHandoff
            viewModel.load()
            #if DEBUG
            print("[ContentView] chatViewModel created with sessionKey=\(key) binding=\(bindingKey.prefix(80))")
            #endif
        }
    }

    // MARK: - Selected Tab Content

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .agenda:
            agendaContent
        case .inbox:
            inboxContent
        case .history:
            historyContent
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Bottom Toolbar (hamburger | new-chat | plus)

    @ViewBuilder
    private var bottomToolbar: some View {
        remMainBottomToolbar(
            selectedTab: selectedTab,
            hasActiveSession: gateway.mainSessionKey != nil,
            firstUseHintPresented: Binding(
                get: { shouldShowFirstUseHint },
                set: { if !$0 { hasDismissedFirstUseHint = true } }
            ),
            onSelectTab: { tab in
                selectedTab = tab
                navigationPath = NavigationPath()
            },
            onNewChat: { openNewChat(autoStartVoice: true) },
            onDismissFirstUseHint: { hasDismissedFirstUseHint = true },
            onCreateTask: { navigationPath.append("create_task") },
            onNewFolder: { showCreateFolder = true },
            onNewList: { showCreateList = true }
        )
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var agendaContent: some View {
        Group {
            if let vm = agendaViewModel {
                AgendaView(viewModel: vm, onCreateTask: {
                    navigationPath.append("create_task")
                }, onOpenCalendarSettings: {
                    selectedTab = .settings
                    navigationPath = NavigationPath()
                }, onOpenBriefChat: { apiSessionKey in
                    // Daily Brief → open the AI-authored brief *chat* (the conversational
                    // landing). Navigation, Agenda reconciliation, and playback all use the same
                    // durable `rem-orchestrator` transcript even if a stale backend omits the
                    // route hint or advertises a legacy `rem-today-*` key.
                    let route = DailyOrchestratorChatRouting.conversationRoute(
                        apiSessionKey: apiSessionKey
                    )
                    openDailyOrchestratorChat(
                        route: route,
                        briefMarkdown: vm.brief?.displayedBriefMarkdown
                    )
                }, isReadingBrief: talkMode.isReadingAloud,
                   hasCompletedBriefPlayback: DailyBriefPlaybackReceipt.contains(
                       dailyBriefPlaybackIdentity(for: vm.brief),
                       in: completedDailyBriefPlaybackReceipts
                    ), onReadBrief: {
                    if talkMode.isReadingAloud {
                        latestBriefPlayback.cancelPendingRequest()
                        stopBriefReadingAndContinue()
                    } else {
                        openAndReadLatestBrief(
                            apiSessionKey: vm.brief?.briefSessionKey
                        )
                    }
                })
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var inboxContent: some View {
        Group {
            if let vm = inboxViewModel {
                InboxView(viewModel: vm)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if let vm = chatViewModel {
            ChatHistoryView(
                viewModel: vm,
                onSelectSession: { key, title in
                    let destinationKey = chatHistoryDestinationSessionKey(for: key)
                    gateway.mainSessionKey = destinationKey
                    chatViewModel?.switchSession(to: destinationKey)
                    navigationPath.append(
                        ChatDestination(sessionKey: destinationKey, existingSessionTitle: title)
                    )
                },
                onNewChat: { openNewChat() },
                onRetryConnection: retryGatewayConnection,
                onReviewConnection: {
                    navigationPath.append("device_connections")
                }
            )
        } else {
            ChatConnectionLoadingView(
                connectionState: gateway.connectionState,
                onRetry: retryGatewayConnection,
                onReviewConnection: {
                    navigationPath.append("device_connections")
                }
            )
            .navigationTitle("Chat Sessions")
        }
    }

    // MARK: - Chat View (pushed destination)

    /// Personalized empty-chat starters come from the same suggestion signals as the Agenda
    /// (WS2 "3 surfaces" — doc 38). `AgendaViewModel` is an `ObservableObject` held here as plain
    /// `@State`, so reading `.suggestions` directly would NOT invalidate the pushed chat
    /// destination when the fetch lands (Codex P2) — the personalized set would never replace the
    /// fallback. These wrappers observe the VM so the starters refresh live; nil VM → generic set.
    private struct PersonalizedStarterChat<Content: View>: View {
        let agenda: AgendaViewModel?
        let sessionKey: String
        let historyRefreshToken: Int
        @ViewBuilder let content: (
            [SharedRemChatView.FirstChatPrompt],
            OrchestratorSuggestionSnapshot?
        ) -> Content
        var body: some View {
            if let agenda {
                StarterObserver(
                    agenda: agenda,
                    sessionKey: sessionKey,
                    historyRefreshToken: historyRefreshToken,
                    content: content
                )
            } else {
                content(SharedRemChatView.firstChatPrompts, nil)
            }
        }
    }

    private struct StarterObserver<Content: View>: View {
        @ObservedObject var agenda: AgendaViewModel
        let sessionKey: String
        let historyRefreshToken: Int
        @ViewBuilder let content: (
            [SharedRemChatView.FirstChatPrompt],
            OrchestratorSuggestionSnapshot?
        ) -> Content
        var body: some View {
            Group {
                let personalized = SharedRemChatView.starters(from: agenda.suggestions)
                content(
                    personalized.isEmpty ? SharedRemChatView.firstChatPrompts : personalized,
                    BriefContext.isDurableOrchestratorSession(sessionKey)
                        ? agenda.orchestratorSuggestionSnapshot()
                        : nil
                )
            }
            .task(id: "\(sessionKey)|\(historyRefreshToken)") {
                guard BriefContext.isDurableOrchestratorSession(sessionKey) else { return }
                await agenda.refreshBriefAndSuggestions()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                guard BriefContext.isDurableOrchestratorSession(sessionKey) else { return }
                Task { await agenda.refreshBriefAndSuggestions() }
            }
        }
    }

    @ViewBuilder
    private func chatView(
        sessionKey: String,
        autoStartVoice: Bool = false,
        prefill: String? = nil,
        briefPreviewMarkdown: String? = nil,
        resolvedBriefMarkdown: Binding<String?> = .constant(nil),
        scrollToLatestBrief: Bool = false,
        isFresh: Bool = false,
        existingSessionTitle: String? = nil
    ) -> some View {
        if let vm = chatViewModel {
            PersonalizedStarterChat(
                agenda: agendaViewModel,
                sessionKey: sessionKey,
                historyRefreshToken: vm.messages.count
            ) { starters, suggestionSnapshot in
                RemChatView(
                    viewModel: vm,
                    requestSlotHandoff: chatRequestSlotHandoff,
                    // Scope the voice mini-bar to the conversation the voice session is attached to.
                    // `talkMode` is app-global, so a bare `talkMode.isEnabled` renders the bar in EVERY
                    // open chat (incl. a New Chat) while voice is only attached to one conversation.
                    // Mirror the transcription-state scoping in RemChatView.mappedTranscriptionState
                    // (guards on `tm.attachedSessionKey == viewModel.sessionKey`).
                    isTalkModeActive: talkMode.isEnabled && talkMode.attachedSessionKey == vm.sessionKey,
                    gatewayConnectionState: gateway.connectionState,
                    isFreshConversation: isFresh,
                    initialExistingSessionTitle: existingSessionTitle,
                    requestedSessionKey: sessionKey,
                    autoStartVoice: autoStartVoice,
                    onVoiceTap: { startVoiceSession() },
                    talkMode: talkMode,
                    onEndVoice: { stopVoiceSession() },
                    onStopReadingAloud: { stopBriefReadingAndContinue() },
                    onRetryReadingAloud: { retryFailedBriefReading() },
                    talkStartDate: talkStartDate,
                    starterPrompts: starters,
                    orchestratorSuggestionSnapshot: suggestionSnapshot,
                    onAcceptSuggestion: { suggestion in
                        Task {
                            guard let snapshotID = suggestionSnapshot?.snapshotID else { return }
                            await agendaViewModel?.acceptSuggestion(suggestion, snapshotID: snapshotID)
                        }
                    },
                    onDismissSuggestion: { suggestion in
                        Task {
                            guard let snapshotID = suggestionSnapshot?.snapshotID else { return }
                            await agendaViewModel?.dismissSuggestion(suggestion, snapshotID: snapshotID)
                        }
                    },
                    briefPreviewMarkdown: briefPreviewMarkdown,
                    resolvedBriefMarkdown: resolvedBriefMarkdown,
                    scrollToLatestBrief: scrollToLatestBrief,
                    sessionPreviewContext: gateway.sessionPreviewContext,
                    onOpenDeviceConnections: {
                        navigationPath.append("device_connections")
                    },
                    onRetryConnection: retryGatewayConnection,
                    runLifecycleEvidenceStore: runLifecycleEvidenceStore
                )
                // Re-run when the *instance* changes, not only the session key:
                // opening a fresh chat sets `gateway.mainSessionKey`, whose onChange
                // rebuilds the view model (input="") AFTER this destination first
                // renders. Keying on the instance identity makes the seed re-apply
                // to the replacement so the prefill lands on the *visible* composer.
                .task(id: ChatSessionTaskID(sessionKey: sessionKey, viewModelID: ObjectIdentifier(vm))) {
                    if vm.sessionKey != sessionKey {
                        vm.switchSession(to: sessionKey)
                    } else {
                        vm.load()
                    }
                    if let prefill,
                       !prefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vm.input = prefill
                    }
                }
            }
        } else {
            ChatConnectionLoadingView(
                connectionState: gateway.connectionState,
                onRetry: retryGatewayConnection,
                onReviewConnection: {
                    navigationPath.append("device_connections")
                }
            )
                .navigationTitle("Chat")
        }
    }

    // MARK: - New Chat

    private func openNewChat(autoStartVoice: Bool = false) {
        // Every explicit New Chat—including the global/footer button—mints an independent general
        // conversation. Only the Summary/brief doorway calls `openDailyOrchestratorChat`.
        openConversationRoute(
            DailyOrchestratorChatRouting.freshGeneralRoute(),
            autoStartVoice: autoStartVoice
        )
    }

    private func openConversationRoute(
        _ route: DailyOrchestratorChatRouting.Route,
        prefill: String? = nil,
        briefPreviewMarkdown: String? = nil,
        scrollToLatestBrief: Bool = false,
        autoStartVoice: Bool = false
    ) {
        gateway.mainSessionKey = route.sessionKey
        chatViewModel?.switchSession(to: route.sessionKey)
        navigationPath.append(
            ChatDestination(
                sessionKey: route.sessionKey,
                autoStartVoice: autoStartVoice,
                prefill: prefill,
                briefPreviewMarkdown: briefPreviewMarkdown,
                scrollToLatestBrief: scrollToLatestBrief,
                isFresh: route.isFresh
            )
        )
    }

    private func openDailyOrchestratorChat(
        route: DailyOrchestratorChatRouting.Route,
        briefMarkdown: String?,
        autoStartVoice: Bool = false,
        scrollToLatestBrief: Bool = false
    ) {
        openConversationRoute(
            route,
            briefPreviewMarkdown: briefMarkdown,
            scrollToLatestBrief: scrollToLatestBrief,
            autoStartVoice: autoStartVoice
        )
    }

    /// Opens the durable Today conversation, then reads the latest assistant-authored brief from
    /// that same transcript and leaves Voice Chat listening for the user's reply. Agenda's compact
    /// summary is only a fallback while the backend's exact durable artifact is still landing; the
    /// client never substitutes a different assistant turn by position.
    @discardableResult
    private func openAndReadLatestBrief(
        apiSessionKey: String?,
        supersedingActiveRequest: Bool = false
    ) -> Bool {
        guard let requestID = latestBriefPlayback.beginRequest(
            supersedingActiveRequest: supersedingActiveRequest,
            onSupersedeActivePlayback: {
                // A buffered player does not observe cancellation of the surrounding Task. Stop
                // stale audible prose now; if the replacement fetch fails, the old brief must not
                // continue speaking or leave Talk Mode in a phantom reading state.
                invalidateBriefRetryRecovery()
            }
        ) else { return false }
        resolvedBriefNavigationMarkdown = nil
        guard let startingAccountID = authService.currentUser?.id,
              !startingAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            latestBriefPlayback.finishRequest(requestID)
            toast = .warning("Sign in again before reading your latest brief.")
            return false
        }
        let route = DailyOrchestratorChatRouting.conversationRoute(
            apiSessionKey: apiSessionKey
        )
        openDailyOrchestratorChat(
            route: route,
            // Do not bridge the pre-tap Agenda prose into Today. It may be stale; the explicit
            // playback request below will replace this with the freshly fetched exact artifact.
            briefMarkdown: nil,
            scrollToLatestBrief: true
        )
        let destinationDepth = navigationPath.count

        let playbackTask = Task { @MainActor in
            defer {
                latestBriefPlayback.finishRequest(requestID)
            }
            guard let agendaViewModel else { return }
            let refresh: AgendaViewModel.ExplicitBriefRefresh
            do {
                refresh = try await agendaViewModel.fetchBriefForExplicitPlayback()
            } catch is CancellationError {
                // SUPERSEDED, NOT FAILED. `fetchBriefForExplicitPlayback` throws
                // CancellationError in two cases: this Task was cancelled, OR a NEWER brief
                // request bumped `briefRequestGeneration` while this one was in flight. The
                // second is invisible to `Task.isCancelled`, so the old guard fell through and
                // showed a failure toast for a request that was simply overtaken.
                //
                // Observed 2026-08-11: tapping through to the brief fires several GET /brief
                // calls within a second or two (backend logged four in three seconds, every one
                // 200 OK) and the founder saw "Your latest brief couldn't be refreshed" while
                // nothing had failed. A newer request is already on its way; staying silent is
                // correct — it will render.
                return
            } catch {
                guard !Task.isCancelled else { return }
                toast = .warning("Your latest brief couldn't be refreshed. Try again shortly.")
                return
            }
            guard latestBriefPlayback.canContinue(requestID),
                  authService.currentUser?.id == startingAccountID,
                  let refreshedBrief = agendaViewModel.commitBriefForExplicitPlayback(refresh)
            else { return }
            guard let refreshedAuthoredMarkdown = DailyBriefTranscriptReconciler
                .backendAuthorizedCanonicalMarkdown(
                from: refreshedBrief
            ),
                  let refreshedPlaybackIdentity = dailyBriefPlaybackIdentity(for: refreshedBrief),
                  refreshedPlaybackIdentity.accountID == startingAccountID
            else {
                toast = .warning("The latest brief isn't available in Today yet. Try again shortly.")
                return
            }
            // The freshly fetched authored artifact may still be landing in history. It is safe as
            // a temporary pending bridge after account/request revalidation, but narration and read
            // receipts remain gated on the exact durable-history match below.
            resolvedBriefNavigationMarkdown = refreshedAuthoredMarkdown
            // A delivered transcript cached by Agenda is not a freshness guarantee: a newer
            // morning/evening artifact can land after Agenda's last reconciliation. Resolve the
            // exact backend-authored artifact on every explicit Read action so we never narrate an
            // older summary or infer identity from a neighboring conversation turn.
            let params = DailyBriefTranscriptReconciler.requestParameters(
                sessionKey: route.sessionKey
            )
            let history = try? await gateway.skillsRequest(
                method: "chat.history",
                paramsJSON: params,
                timeoutSeconds: 15
            )
            let latestAssistant: String? = history.flatMap {
                return DailyBriefTranscriptReconciler.currentBackendAuthorizedArtifact(
                    from: $0,
                    for: refreshedBrief
                )?.markdown
            }
            // The durable Today transcript is the authority. The Agenda cache can be stale (for
            // example, "all clear" while a replacement is still delivering), so it must never be
            // spoken as fallback here. Exact `/brief` prose is the durable delivery identity.
            // The transcript request can outlive a quick Back gesture or a jump into another
            // conversation. Never start speaking into whichever screen happens to be current then.
            guard LatestBriefPlaybackGate.shouldStart(
                requestID: requestID,
                activeRequestID: latestBriefPlayback.activeRequestID,
                destinationDepth: destinationDepth,
                currentDepth: navigationPath.count,
                expectedSessionKey: route.sessionKey,
                currentSessionKey: gateway.mainSessionKey,
                expectedAccountID: refreshedPlaybackIdentity.accountID,
                currentAccountID: authService.currentUser?.id
            ) else { return }
            guard dailyBriefPlaybackIdentity(for: agendaViewModel.brief) == refreshedPlaybackIdentity else {
                toast = .warning("The latest brief changed before reading could start. Try again.")
                return
            }
            guard let latestAssistant,
                  !latestAssistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                toast = .warning("The latest brief isn't available in Today yet. Try again shortly.")
                return
            }
            // Navigation began with Agenda's low-latency preview. Replace that anchor with the
            // exact durable Today message before narration so the visible scroll target, Agenda
            // summary, and spoken text converge on one artifact.
            resolvedBriefNavigationMarkdown = latestAssistant
            // Playback just resolved the same durable artifact Agenda is meant to summarize.
            // Publish it before narration starts so the return trip uses the identical content
            // fingerprint and can immediately show the completed `Read again` state.
            guard agendaViewModel.applyDurableBriefTranscript(
                latestAssistant,
                sessionKey: route.sessionKey,
                expectedAuthoredMarkdown: refreshedAuthoredMarkdown
            ) == true
            else {
                toast = .warning("The latest brief changed before reading could start. Try again.")
                return
            }
            guard let completionIdentity = DailyBriefPlaybackReceipt.identity(
                accountID: refreshedPlaybackIdentity.accountID,
                localDayKey: refreshedPlaybackIdentity.localDayKey,
                sessionKey: route.sessionKey,
                briefMarkdown: latestAssistant
            ) else { return }
            guard let retryContext = explicitBriefRetryContext(
                identity: completionIdentity,
                sessionKey: route.sessionKey
            ) else {
                toast = .warning("The latest brief changed before reading could start. Try again.")
                return
            }
            await beginVoiceSession(
                initialSpokenText: latestAssistant,
                initialPlaybackRetryContext: retryContext,
                shouldBeginInitialPlayback: {
                    guard latestBriefPlayback.canContinue(requestID) else { return false }
                    guard LatestBriefPlaybackGate.shouldStart(
                        requestID: requestID,
                        activeRequestID: latestBriefPlayback.activeRequestID,
                        destinationDepth: destinationDepth,
                        currentDepth: navigationPath.count,
                        expectedSessionKey: route.sessionKey,
                        currentSessionKey: gateway.mainSessionKey,
                        expectedAccountID: refreshedPlaybackIdentity.accountID,
                        currentAccountID: authService.currentUser?.id
                    ) else { return false }
                    guard retryContext == currentExplicitBriefRetryContext() else { return false }
                    return latestBriefPlayback.markBriefVoiceSessionStarted(for: requestID)
                },
                onInitialPlaybackCompleted: {
                    guard DailyBriefPlaybackAccountBoundary.canRecordCompletion(
                        expectedAccountID: refreshedPlaybackIdentity.accountID,
                        currentAccountID: authService.currentUser?.id
                    ),
                    ExplicitSpeechPlaybackContextPolicy.canRecordReceipt(
                        expected: retryContext,
                        current: currentExplicitBriefRetryContext(),
                        outcome: .completed
                    )
                    else { return }
                    completedDailyBriefPlaybackReceipts = DailyBriefPlaybackReceipt.recording(
                        completionIdentity,
                        in: completedDailyBriefPlaybackReceipts
                    )
                }
            )
        }
        latestBriefPlayback.retain(playbackTask, for: requestID)
        return true
    }

    private func dailyBriefPlaybackIdentity(
        for brief: DailyBrief?
    ) -> DailyBriefPlaybackIdentity? {
        DailyBriefPlaybackReceipt.identity(
            accountID: authService.currentUser?.id,
            generatedAt: brief?.generatedAt,
            sessionKey: brief?.briefSessionKey,
            briefMarkdown: brief?.displayedBriefMarkdown
                ?? brief?.briefMarkdown
                ?? brief?.displayedBriefSummary
        )
    }

    private func explicitBriefRetryContext(
        identity: DailyBriefPlaybackIdentity,
        sessionKey: String
    ) -> ExplicitSpeechRetryContext? {
        let accountID = (authService.currentUser?.id ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayID = (gateway.storedGatewayURL ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, !gatewayID.isEmpty, !sessionKey.isEmpty else { return nil }
        return ExplicitSpeechRetryContext(
            accountID: accountID,
            gatewayID: gatewayID,
            sessionKey: sessionKey,
            localDayKey: identity.localDayKey,
            briefKey: identity.briefKey
        )
    }

    private func currentExplicitBriefRetryContext() -> ExplicitSpeechRetryContext? {
        guard let identity = dailyBriefPlaybackIdentity(for: agendaViewModel?.brief),
              let sessionKey = gateway.mainSessionKey
        else { return nil }
        return explicitBriefRetryContext(identity: identity, sessionKey: sessionKey)
    }

    /// `AgendaViewModel` is installed lazily and retained as plain `@State`, so nested
    /// `@Published brief` changes do not invalidate this parent view. Subscribe directly: a
    /// same-day artifact replacement must cancel old narration immediately, not only when some
    /// unrelated parent state later happens to redraw.
    private var agendaBriefChanges: AnyPublisher<DailyBrief?, Never> {
        guard let agendaViewModel else {
            return Empty<DailyBrief?, Never>().eraseToAnyPublisher()
        }
        return agendaViewModel.$brief.eraseToAnyPublisher()
    }

    private func invalidateBriefRetryRecovery() {
        failedBriefRetryCompletion = nil
        failedBriefRetryContext = nil
        talkMode.invalidateExplicitBriefPlayback()
    }

    private func handleBriefPlaybackAccountTransition(
        previousAccountID: String?,
        currentAccountID: String?
    ) {
        guard previousAccountID != currentAccountID else { return }
        // Invalidate both the pre-playback history request and any narration that has already
        // started. Audio and completion state must never cross an authenticated-account edge.
        let wasBriefVoiceSession = latestBriefPlayback.invalidateAll()
        invalidateBriefRetryRecovery()
        guard DailyBriefPlaybackAccountBoundary.shouldCancelActivePlayback(
            previousAccountID: previousAccountID,
            currentAccountID: currentAccountID,
            isBriefVoiceSession: wasBriefVoiceSession,
            isTalkModeEnabled: talkMode.isEnabled
        ) else { return }
        talkMode.stop()
        talkStartDate = nil
        syncVoiceLiveActivity()
    }

    private func tearDownBriefPlaybackOnAuthenticatedRootDisappearance() {
        let decision = DailyBriefPlaybackLifecycle.teardownDecision(
            hasPendingRequest: latestBriefPlayback.hasPendingRequest,
            isTalkModeEnabled: talkMode.isEnabled
        )
        if decision.invalidatePendingRequest || latestBriefPlayback.isBriefVoiceSession {
            latestBriefPlayback.invalidateAll()
        }
        invalidateBriefRetryRecovery()
        guard decision.stopTalkMode else { return }
        talkMode.stop()
        talkStartDate = nil
        syncVoiceLiveActivity()
    }

    private func openSkillSetupChat(_ request: SkillSetupChatRequest) {
        let shortId = UUID().uuidString.prefix(8).lowercased()
        let key = "chat-\(shortId)"
        gateway.mainSessionKey = key
        selectedTab = .history
        chatViewModel?.switchSession(to: key)
        // NOTE: do NOT seed `chatViewModel?.input` here. Setting
        // `gateway.mainSessionKey` above triggers `setupChatViewModel(force: true)`,
        // which replaces `chatViewModel` with a fresh instance (input=""), so any
        // seed on the current instance is discarded. The prefill is carried on the
        // ChatDestination and applied in `chatView`'s `.task`, which re-fires on the
        // instance swap (see ChatSessionTaskID).
        navigationPath = NavigationPath()
        // Brand-new session seeded with the skill's example prompt: no server history, and the
        // pending prompt already states intent — so skip both the loading skeleton (FIX 1) and the
        // "Start a conversation" starters (FIX 2). Both are handled in SharedRemChatView's gate.
        navigationPath.append(ChatDestination(sessionKey: key, prefill: request.prompt, isFresh: true))
    }

    // MARK: - Navigation Destinations

    @ViewBuilder
    private func taskNavigationDestination(for destination: String) -> some View {
        switch destination {
        case "create_task":
            TaskEventView(
                viewModel: TaskEventViewModel(
                    modelContext: modelContext,
                    calendarService: calendarService,
                    taskApiService: taskApiService,
                    taskSyncService: taskSyncService
                ),
                onTaskAddedToInbox: { showInboxToast = true }
            )
        case "device_connections":
            deviceConnectionsDestination()
        case "tasks_by_list":
            TasksByListView(
                apiService: organizationApiService,
                onOpenTask: { taskID in navigationPath.append(taskID) }
            )
        default:
            Text("Unknown destination: \(destination)")
        }
    }

    @ViewBuilder
    private func deviceConnectionsDestination() -> some View {
        let configStore = SharedGatewaySettingsStore.makeMigratedStore(gateway: gateway)
        if let config = SharedGatewaySettingsResolver.preferredLandingConfig(from: configStore.configs) {
            SharedGatewayDevicePairingScreen(
                config: config,
                configStore: configStore,
                gateway: gateway
            )
        } else {
            SharedGatewayRecoveryDestinationView(gateway: gateway, configStore: configStore)
        }
    }

    @ViewBuilder
    private func editDestination(for taskID: UUID) -> some View {
        EditTaskDestination(
            taskID: taskID,
            calendarService: calendarService,
            taskApiService: taskApiService,
            taskSyncService: taskSyncService,
            onStartFocusSession: { session in
                handleStartFocusSession(session)
            },
            onOpenSession: { comment in
                openSession(for: comment)
            },
            onOpenHistory: { taskId in
                navigationPath.append(TaskActivityHistoryDestination(taskId: taskId))
            },
            onOpenTaskChat: { taskId, latest, draft in
                openTaskChat(taskId: taskId, latest: latest, draft: draft)
            }
        )
    }

    /// "View history" destination — the full activity thread for a task, with its own
    /// "Continue in chat" doorway into the task-scoped (unblock) chat.
    @ViewBuilder
    private func taskActivityHistoryDestination(for taskId: String) -> some View {
        TaskActivityHistoryView(
            taskId: taskId,
            onContinueInChat: { latest in
                openTaskChat(taskId: taskId, latest: latest, draft: "")
            }
        )
    }

    /// Resolve a tapped Activity comment to a chat and push it onto the
    /// NavigationStack.
    ///
    /// Namespace caveat (root cause of the "empty linked chat" bug): for an
    /// **AgentBox** (cloud) comment, `comment.sessionId` is a backend-generated run
    /// UUID (`randomUUID()` in `POST /tasks/:id/agent-run`, migration 022). That id
    /// lives in the AgentBox cloud agent's namespace — it is NOT a key in the user's
    /// per-user gateway, which is what `chat.history` reads. The cloud run's
    /// transcript is never persisted as a gateway session (only the final reply is
    /// saved, as this comment's body), so routing a `ChatDestination` at that id
    /// loads no messages and the chat opens empty. See docs/agentbox/CONTRACT.md.
    ///
    /// Best partial until cloud transcripts are retrievable from the device: open a
    /// **stable per-task continuation chat** on the gateway, seeded with the task
    /// title so the user lands in a usable thread (and re-tapping the same task
    /// returns to the same chat) instead of a dead, empty session keyed by an
    /// id the gateway can't resolve.
    ///
    /// Local-runtime comments (iOS/Mac) execute on the gateway itself, so their
    /// `sessionId` IS a real gateway session key with a retrievable transcript —
    /// those route directly. Human comments (no runtime, no session) fall back to
    /// the live main session rather than crashing or dead-ending.
    private func openSession(for comment: TaskComment) {
        // Cloud runs have no gateway-retrievable transcript → continuation chat,
        // seeded with the task's context (title + this latest update).
        if comment.runtime?.isCloud == true {
            openTaskContinuationChat(taskId: comment.taskId, latest: comment)
            return
        }
        // Local-runtime sessions live on the gateway → route to the transcript.
        if let sessionKey = comment.sessionId, !sessionKey.isEmpty {
            navigationPath.append(ChatDestination(sessionKey: sessionKey))
        } else if let mainKey = gateway.mainSessionKey {
            navigationPath.append(ChatDestination(sessionKey: mainKey))
        }
        // No session handle and no main session yet → no-op (don't crash the tap).
    }

    /// Unified entry into a task's chat — used by the bottom composer and the
    /// "Continue in chat" CTA in the history view. Routes a local-runtime comment to
    /// its real gateway transcript when one exists; otherwise opens the task-scoped
    /// continuation chat seeded with the task's context (the cloud-run case, and the
    /// no-activity-yet case). `draft` carries whatever the user typed in the composer.
    private func openTaskChat(taskId: String, latest: TaskComment?, draft: String) {
        if let latest, latest.runtime?.isCloud == false,
           let sessionKey = latest.sessionId, !sessionKey.isEmpty {
            navigationPath.append(ChatDestination(sessionKey: sessionKey))
            return
        }
        openTaskContinuationChat(taskId: taskId, latest: latest, draft: draft)
    }

    /// Open (or reopen) a per-task continuation chat. The session key is derived from
    /// the task id so the thread is **stable across taps** (re-entering the same task
    /// returns to the same chat). The cloud run's REAL prior turns (the ask + Rem's
    /// reply) load as actual messages in the thread via the transcript
    /// (`TaskChatTranscriptCoordinator` → `GET /tasks/:id/chat`), making this a true
    /// continuation — not an empty composer. The prefill is just a light unblock nudge
    /// (carrying the task title) plus the user's draft. See `openSession(for:)`.
    private func openTaskContinuationChat(taskId: String, latest: TaskComment?, draft: String = "") {
        // Continue on the canonical UUID session and let the transport read-through
        // merge the deterministic legacy `task-<12>` history. Do not choose identity
        // from the asynchronously loaded/top-50 session list: absence there is not
        // proof that an older gateway transcript does not exist.
        let historyPlan = TaskChatSessionIdentity.gatewayHistoryPlan(
            taskId: taskId,
            persistedSessionKey: taskSessionKey(forTaskId: taskId)
        )
        let key = historyPlan.activeSessionKey
        // Register the session→task mapping BEFORE switching, so the transport's
        // history load (TaskChatTranscriptCoordinator → GET /tasks/:id/chat) can fetch
        // and render the cloud run's REAL prior turns as messages in this thread.
        taskChatTranscriptCoordinator.register(sessionKey: key, taskId: taskId)
        let prefill = taskChatSeed(
            title: taskTitle(forTaskId: taskId),
            draft: draft
        )
        gateway.mainSessionKey = key
        chatViewModel?.switchSession(to: key)
        navigationPath.append(ChatDestination(sessionKey: key, prefill: prefill))
    }

    /// Build the composer nudge for a task-scoped chat. The cloud run's actual turns
    /// (the ask + Rem's reply) now load as REAL prior messages via the transcript
    /// (`TaskChatTranscriptCoordinator`), so this no longer re-echoes Rem's latest
    /// update — it's just the unblock framing (carrying the task title) plus the user's
    /// typed draft when present, prefilled into the input (never auto-sent).
    private func taskChatSeed(title: String?, draft: String) -> String {
        let name = title.map { "“\($0)”" } ?? "this task"
        var lines: [String] = ["Let's keep working on \(name) — I want to unblock it."]

        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("")
        lines.append(typed.isEmpty ? "What do you need from me to move it forward?" : typed)
        return lines.joined(separator: "\n")
    }

    /// Look up a task's title from the shared store by its backend id (a UUID
    /// string). Returns `nil` when the task isn't loaded yet, so callers degrade to
    /// a generic prompt rather than showing a raw id.
    private func taskTitle(forTaskId taskId: String) -> String? {
        let needle = taskId.lowercased()
        let match = taskStore?.allTasks.first { $0.id.uuidString.lowercased() == needle }
        guard let title = match?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    /// The backend-stamped stable session key for a task, decoded from the task DTO
    /// (`tasks.session_key`, migration 019 — populated at manual agent-run start and by
    /// the orchestrator sweep, both via `rem-task-<taskId>`). When present, this is the
    /// canonical handle for the task's continuation chat, so "Open conversation" lands on
    /// the SAME session the backend ran/persisted against rather than a locally-derived
    /// key. `nil` until a run has touched the task — the caller derives the backend's
    /// same canonical `rem-task-<full UUID>` key. See `openTaskContinuationChat`.
    private func taskSessionKey(forTaskId taskId: String) -> String? {
        let needle = taskId.lowercased()
        let match = taskStore?.allTasks.first { $0.id.uuidString.lowercased() == needle }
        guard let key = match?.sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// A legacy task row can still be visible in Chat History after upgrade. When its
    /// task is loaded, route selection to the canonical thread so history loading
    /// merges the legacy gateway turns, canonical continuation, and backend transcript.
    /// If the task was deleted or the truncated legacy key is ambiguous, preserve the
    /// original row so its gateway-only conversation remains recoverable.
    private func chatHistoryDestinationSessionKey(for sessionKey: String) -> String {
        let taskIds = taskStore?.allTasks.map(\.id.uuidString) ?? []
        guard let redirect = TaskChatSessionIdentity.legacyHistoryRedirect(
            sessionKey: sessionKey,
            candidateTaskIds: taskIds
        ) else { return sessionKey }
        taskChatTranscriptCoordinator.register(
            sessionKey: redirect.canonicalSessionKey,
            taskId: redirect.taskId
        )
        return redirect.canonicalSessionKey
    }

    private func handleStartFocusSession(_ session: FocusSession) {
        focusTimerMinimized = false
        Task {
            await focusSessionManager.startSession(session)
        }
    }

    // MARK: - Voice Session

    /// Handing browser control back starts a hidden agent continuation, so it consumes the same
    /// request slot as an explicit composer or voice turn. Keep the browser under user control when
    /// the reservation is denied or cannot be verified; `BrowserLiveSession` renders the returned
    /// message inline and only emits the resume intent after `.authorized`.
    private func requestBrowserHandBack() async -> BrowserLiveSession.HandBackAuthorization {
        guard let accountID = authService.currentUser?.id,
              let sessionKey = browserView.session.lastConversationKey
        else {
            return .denied("This browser session changed. Open it again from chat.")
        }
        let accountLifecycleTicket = authService.accountLifecycleTicket
        let browserOwnerLifecycleTicket = browserView.session.browserOwnerLifecycleTicket

        let outcome = await gateway.resumeBrowserAfterHandBack(
            accountID: accountID,
            accountLifecycleTicket: accountLifecycleTicket,
            sessionKey: sessionKey,
            browserOwnerLifecycleTicket: browserOwnerLifecycleTicket,
            accountIsCurrent: {
                authService.currentUser?.id == accountID
                    && authService.accountLifecycleTicket == accountLifecycleTicket
            },
            browserOwnerIsCurrent: {
                browserView.session.lastConversationKey == sessionKey
                    && browserView.session.browserOwnerLifecycleTicket == browserOwnerLifecycleTicket
            },
            reserveSlot: {
                do {
                    let reservation = try await usageService.consumeRequestSlot()
                    usageService.dismissQuotaError()
                    return .reserved(reservation)
                } catch {
                    switch UsageSlotFailurePolicy.classify(error) {
                    case .quotaExceeded(let quota):
                        usageService.handleQuotaExceeded(quota)
                        return .denied(quota.message)
                    case .verificationUnavailable:
                        return .denied("Couldn't verify your plan. Check your connection and try again.")
                    case .reservationRetryBlocked:
                        return .denied(
                            "That browser handoff wasn't sent, but its quota check may have counted. "
                                + "To avoid counting it twice, don't retry it. Check Usage or contact support."
                        )
                    }
                }
            },
            acknowledgeReservation: { reservation in
                usageService.markReservedRequestAccepted(reservation)
            },
            cancelReservationBeforeDispatch: { reservation in
                usageService.markReservedRequestCancelledBeforeDispatch(reservation)
            }
        )
        switch outcome {
        case .resumed:
            return .authorized
        case .denied(let message):
            return .denied(message)
        }
    }

    private func startVoiceSession(initialSpokenText: String? = nil) {
        // Manual Talk Mode supersedes any in-flight Read Latest Brief launch. Cancelling and
        // invalidating the request prevents a late history/chatSession completion from starting
        // narration over the user's explicitly started conversation.
        latestBriefPlayback.invalidateAll()
        invalidateBriefRetryRecovery()
        Task {
            await beginVoiceSession(initialSpokenText: initialSpokenText)
        }
    }

    private func beginVoiceSession(
        initialSpokenText: String? = nil,
        initialPlaybackRetryContext: ExplicitSpeechRetryContext? = nil,
        shouldBeginInitialPlayback: (() -> Bool)? = nil,
        onInitialPlaybackCompleted: (() -> Void)? = nil
    ) async {
        // Check quota if already cached, but don't block on network fetch
        if let remaining = usageService.effectiveRemaining,
           QuotaPresentation.currentDenial(
               plan: usageService.summary?.plan,
               remaining: remaining
           ) != nil {
            usageService.presentCurrentQuotaDenial()
            return
        }
        let session = await gateway.client.chatSession
        // `chatSession` may suspend while auth/root teardown cancels the originating brief task.
        // Revalidate immediately before any Talk Mode state or audio can be enabled.
        guard shouldBeginInitialPlayback?() ?? true else { return }
        talkMode.attachGateway(session)
        talkMode.attachUsageService(usageService)
        talkMode.updateGatewayConnected(gateway.connectionState.isConnected)
        if let activeKey = gateway.mainSessionKey {
            talkMode.updateSessionKey(activeKey)
        }
        talkStartDate = Date()
        if let initialSpokenText,
           !initialSpokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let initialPlaybackRetryContext else {
                invalidateBriefRetryRecovery()
                return
            }
            failedBriefRetryCompletion = onInitialPlaybackCompleted
            failedBriefRetryContext = initialPlaybackRetryContext
            let completed = await talkMode.startByReadingAloud(
                initialSpokenText,
                retryContext: initialPlaybackRetryContext
            )
            if completed {
                onInitialPlaybackCompleted?()
                invalidateBriefRetryRecovery()
            } else if !talkMode.canRetryReadingAloud {
                invalidateBriefRetryRecovery()
            }
        } else {
            invalidateBriefRetryRecovery()
            talkMode.setEnabled(true)
        }
        syncVoiceLiveActivity()

        // Fetch quota in background — talkMode checks quota before each chat.send
        if usageService.summary == nil {
            try? await usageService.fetchSummary()
        }
    }

    private func stopVoiceSession() {
        invalidateBriefRetryRecovery()
        latestBriefPlayback.endVoiceSession()
        talkMode.stop()
        talkStartDate = nil
        gateway.mainSessionKey = nil
        syncVoiceLiveActivity()
    }

    private func stopBriefReadingAndContinue() {
        invalidateBriefRetryRecovery()
        talkMode.stopReadingAloud(continueListening: true)
    }

    private func retryFailedBriefReading() {
        guard talkMode.canRetryReadingAloud,
              let expectedContext = failedBriefRetryContext,
              expectedContext == currentExplicitBriefRetryContext()
        else {
            invalidateBriefRetryRecovery()
            return
        }
        Task { @MainActor in
            let completed = await talkMode.retryFailedReadingAloud(
                expectedContext: expectedContext
            )
            if completed,
               expectedContext == failedBriefRetryContext,
               expectedContext == currentExplicitBriefRetryContext() {
                failedBriefRetryCompletion?()
                invalidateBriefRetryRecovery()
            } else if !talkMode.canRetryReadingAloud {
                invalidateBriefRetryRecovery()
            }
            syncVoiceLiveActivity()
        }
    }

    private func handleExternalVoiceCommand(_ command: VoiceSessionCommand?) async -> Bool {
        guard let command else { return false }
        switch command {
        case .start:
            let route = gateway.mainSessionKey.map {
                DailyOrchestratorChatRouting.Route(sessionKey: $0, isFresh: false)
            } ?? DailyOrchestratorChatRouting.freshGeneralRoute()
            gateway.mainSessionKey = route.sessionKey
            selectedTab = .history
            navigationPath = NavigationPath()
            navigationPath.append(
                ChatDestination(sessionKey: route.sessionKey, isFresh: route.isFresh)
            )
            startVoiceSession()
            return true
        case .stop:
            stopVoiceSession()
            return true
        case .open:
            let route = gateway.mainSessionKey.map {
                DailyOrchestratorChatRouting.Route(sessionKey: $0, isFresh: false)
            } ?? DailyOrchestratorChatRouting.freshGeneralRoute()
            gateway.mainSessionKey = route.sessionKey
            selectedTab = .history
            navigationPath = NavigationPath()
            navigationPath.append(
                ChatDestination(sessionKey: route.sessionKey, isFresh: route.isFresh)
            )
            return true
        case .readLatestBrief:
            guard agendaViewModel != nil else { return false }
            return openAndReadLatestBrief(
                apiSessionKey: agendaViewModel?.brief?.briefSessionKey,
                supersedingActiveRequest: true
            )
        }
    }

    private func resumePendingExternalBriefReadIfReady() {
        let token = voiceControlRouter.commandToken
        guard agendaViewModel != nil,
              voiceControlRouter.claimCommand(
                for: token,
                accountID: authService.currentUser?.id,
                ownerID: voiceCommandOwnerID
              ) == .readLatestBrief
        else { return }
        if openAndReadLatestBrief(
            apiSessionKey: agendaViewModel?.brief?.briefSessionKey,
            supersedingActiveRequest: true
        ) {
            voiceControlRouter.acknowledgeCommand(for: token, ownerID: voiceCommandOwnerID)
        }
    }

    private func handleExternalFocusCommand(_ command: FocusSessionCommand?) async {
        guard let command else { return }
        switch command {
        case .pause:
            await focusSessionManager.pauseSession()
        case .resume:
            await focusSessionManager.resumeSession()
        case .stop:
            await focusSessionManager.stopSession()
        case .startFromPreSession(let taskId, let taskTitle, let duration):
            guard let uuid = UUID(uuidString: taskId) else { return }
            let session = FocusSession(
                taskId: uuid,
                taskTitle: taskTitle,
                duration: duration ?? 25 * 60,
                warmUpDuration: nil,
                startTime: Date(),
                status: .running
            )
            await focusSessionManager.startSession(session)
        }
    }

    private func syncVoiceLiveActivity() {
        // Keep the lock screen ControlWidget state in sync
        VoiceSessionSharedState.isSessionActive = talkMode.isEnabled
        ControlCenter.shared.reloadControls(
            ofKind: "com.remapp.rem.VoiceSessionControl"
        )

#if canImport(ActivityKit) && os(iOS)
        Task {
            if talkMode.isEnabled {
                let latestUser = talkMode.latestUserPreview
                    ?? talkMode.messages.reversed().first(where: { $0.sender == .user })?.text
                let latestAI = talkMode.latestAssistantPreview
                    ?? talkMode.messages.reversed().first(where: { $0.sender == .ai })?.text
                await voiceLiveActivity.startOrUpdate(
                    sessionKey: gateway.mainSessionKey ?? "main",
                    status: talkMode.statusText,
                    isListening: talkMode.isListening,
                    isSpeaking: talkMode.isSpeaking,
                    latestUserMessage: latestUser,
                    latestAssistantMessage: latestAI
                )
            } else {
                await voiceLiveActivity.end()
            }
        }
#endif
    }

    // MARK: - Minimized Focus Session Bar

    @ViewBuilder
    private var focusMiniPlayerBar: some View {
        let session = focusSessionManager.currentSession
        let isPaused = session?.status == .paused

        return MiniPlayerBar(
            modeText: {
                switch session?.status {
                case .warmingUp: return "Warming Up"
                case .paused: return "Paused"
                default: return "Focusing"
                }
            }(),
            titleText: session?.taskTitle ?? "Focus",
            subtitleText: {
                let t = focusSessionManager.timeRemaining
                let h = Int(t) / 3600
                let m = (Int(t) % 3600) / 60
                let s = Int(t) % 60
                if h > 0 { return String(format: "%dh %02dm left", h, m) }
                if m > 0 { return String(format: "%02d:%02d left", m, s) }
                return String(format: "0:%02d left", s)
            }(),
            progress: focusSessionManager.progress,
            progressColor: isPaused ? DesignTokens.Color.systemYellow : DesignTokens.Color.systemGreen,
            primaryButton: .init(
                icon: isPaused ? "play.fill" : "pause.fill",
                color: DesignTokens.Color.systemGreen,
                accessibilityLabel: isPaused ? "Resume focus" : "Pause focus",
                action: {
                    Task {
                        if isPaused {
                            await focusSessionManager.resumeSession()
                        } else {
                            await focusSessionManager.pauseSession()
                        }
                    }
                }
            ),
            stopButton: .init(
                icon: "xmark",
                color: .red,
                accessibilityLabel: "End focus",
                action: { Task { await focusSessionManager.stopSession() } }
            ),
            onTap: {
                if let s = session {
                    focusTimerMinimized = false
                    activeFocusSession = s
                }
            }
        )
    }

    private var voiceMiniPlayerBar: some View {
        MiniPlayerBar(
            modeText: (talkMode.isReadingAloud || talkMode.canRetryReadingAloud)
                ? "Latest Brief" : "Voice Chat",
            titleText: talkMode.isReadingAloud
                ? briefReadingProgressTitle : talkMode.statusText,
            subtitleText: talkMode.canRetryReadingAloud
                ? "Microphone stays muted until reading succeeds"
                : (talkMode.isReadingAloud ? "Continue listening, then reply" : "Active session"),
            timerStartDate: talkStartDate,
            progress: nil,
            progressColor: .clear,
            primaryButton: .init(
                icon: talkMode.isMuted ? "mic.slash.fill" : "mic.fill",
                color: talkMode.isMuted ? .red : DesignTokens.Color.labelPrimary,
                accessibilityLabel: talkMode.isMuted ? "Unmute microphone" : "Mute microphone",
                action: {
                    if talkMode.isMuted {
                        talkMode.unmute()
                    } else {
                        talkMode.mute()
                    }
                }
            ),
            stopButton: .init(
                icon: talkMode.isReadingAloud ? "stop.fill" : "phone.down.fill",
                color: .red,
                accessibilityLabel: talkMode.isReadingAloud
                    ? "Stop reading and continue voice chat"
                    : "End voice chat",
                action: {
                    if talkMode.isReadingAloud {
                        stopBriefReadingAndContinue()
                    } else {
                        stopVoiceSession()
                    }
                }
            ),
            retryReadingAction: talkMode.canRetryReadingAloud
                ? { retryFailedBriefReading() }
                : nil,
            onTap: {
                navigationPath = NavigationPath()
                navigationPath.append(ChatDestination(sessionKey: gateway.mainSessionKey ?? "main"))
            },
            // The inactivity monitor is view-independent, so the countdown + "Keep open" must show
            // on this tab-level bar too — otherwise an idle session vanishes with no warning when
            // the user is on Home/Tasks/etc. (review finding).
            closingDeadline: talkMode.autoCloseAt,
            closingDuration: talkMode.voiceAutoCloseCountdownDuration,
            onKeepOpen: { talkMode.keepVoiceOpen() }
        )
    }

    private var briefReadingProgressTitle: String {
        guard talkMode.explicitPlaybackTotalChunks > 0 else {
            return "Reading latest brief"
        }
        let current = min(
            talkMode.explicitPlaybackCompletedChunks + 1,
            talkMode.explicitPlaybackTotalChunks
        )
        return "Reading \(current) of \(talkMode.explicitPlaybackTotalChunks)"
    }
}

// MARK: - Edit Task Destination (fetches task by ID from SwiftData)

private struct EditTaskDestination: View {
    let taskID: UUID
    let calendarService: RemCalendarService
    let taskApiService: RemTaskApiService
    let taskSyncService: RemTaskSyncService?
    var onStartFocusSession: ((FocusSession) -> Void)?
    var onOpenSession: ((TaskComment) -> Void)?
    var onOpenHistory: ((String) -> Void)?
    var onOpenTaskChat: ((_ taskId: String, _ latest: TaskComment?, _ draft: String) -> Void)?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let descriptor = FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == taskID })
        let task = try? modelContext.fetch(descriptor).first

        if let task {
            TaskEventView(
                viewModel: TaskEventViewModel(
                    modelContext: modelContext,
                    task: task,
                    calendarService: calendarService,
                    taskApiService: taskApiService,
                    taskSyncService: taskSyncService
                ),
                onStartFocusSession: onStartFocusSession,
                onOpenSession: onOpenSession,
                onOpenHistory: onOpenHistory,
                onOpenTaskChat: onOpenTaskChat
            )
        } else {
            Text("Task not found")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Connection status badge

struct ConnectionStatusBadge: View {
    let state: RemGatewayConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .gray
        case .unauthorized: .red
        case .pairingRequired: .yellow
        case .unreachable: .red
        }
    }
}

#Preview {
    ContentView()
        .environment(RemGatewaySessionManager())
        .environment(RemAuthService())
        .environment(VoiceSessionControlRouter())
}
