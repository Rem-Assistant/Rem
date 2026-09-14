import SwiftUI

enum MacRootAuthenticationPresentation: Equatable {
    case loading
    case authenticated
    case signedOut

    static func resolve(isLoaded: Bool, isAuthenticated: Bool) -> Self {
        guard isLoaded else { return .loading }
        return isAuthenticated ? .authenticated : .signedOut
    }
}

struct MainWindow: View {
    @Environment(MacGatewaySessionManager.self) private var session
    @Environment(MacRouter.self) private var router
    @State private var taskStore = MacTaskStore()
    @State private var orchestratorSuggestionStore = MacOrchestratorSuggestionStore()
    @State private var showCreateTask = false
    @State private var agendaDetailTask: MacTask?
    @State private var inboxDetailTask: MacTask?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Adapter bridging MacTaskStore → TaskStoreProviding for shared views.
    private var taskStoreAdapter: MacTaskStoreAdapter {
        MacTaskStoreAdapter(store: taskStore)
    }

    var body: some View {
        Group {
            switch MacRootAuthenticationPresentation.resolve(
                isLoaded: session.isAuthenticationStateLoaded,
                isAuthenticated: session.isAuthenticated
            ) {
            case .loading:
                MacAuthenticationLoadingView()
                    .frame(minWidth: 600, minHeight: 420)
                    .background(MacMainWindowAccessor())
            case .authenticated:
                @Bindable var router = router
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    VStack(alignment: .leading, spacing: 0) {
                        List(MacRouter.Screen.sidebarCases, selection: $router.selectedScreen) { screen in
                            Label(screen.rawValue, systemImage: screen.icon)
                                .tag(screen)
                                .accessibilityIdentifier("Sidebar_\(screen.rawValue)")
                        }
                        .listStyle(.sidebar)

                        Divider()

                        // Primary "Chat" action — distinct from nav rows
                        // above. Visual separation via the Divider and a filled
                        // brand-blue background makes this the obvious CTA for
                        // starting a chat. #305 (Mac chat parity epic).
                        //
                        // Label is "Chat" (not "New Chat") to fit on a single
                        // line when the sidebar is minimized — same verb as
                        // iOS.
                        Button {
                            router.startNewChat()
                        } label: {
                            HStack(spacing: 8) {
                                // Icon matches iOS chat CTA
                                // (`ContentView.swift` uses
                                // `message.badge.waveform.fill`) so the primary
                                // entry point reads the same on both platforms.
                                // #321 (Voice on Mac parity mini-epic).
                                Image(systemName: "message.badge.waveform.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Chat")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(
                                DesignTokens.Color.brandBlue,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .accessibilityIdentifier("Sidebar_NewChat")
                        .help("Start a new chat")
                    }
                } detail: {
                    switch router.selectedScreen {
                    case .agenda:
                        NavigationStack {
                            SharedAgendaView(
                                store: taskStoreAdapter,
                                onCreateTask: { showCreateTask = true },
                                onOpenTask: { task in
                                    agendaDetailTask = task
                                }
                            )
                            .navigationDestination(item: $agendaDetailTask) { task in
                                MacTaskDetailView(task: task, taskStore: taskStore)
                            }
                        }
                    case .inbox:
                        NavigationStack {
                            SharedInboxView(
                                store: taskStoreAdapter,
                                onCreateTask: { showCreateTask = true },
                                onOpenTask: { task in
                                    inboxDetailTask = task
                                }
                            )
                            .navigationDestination(item: $inboxDetailTask) { task in
                                MacTaskDetailView(task: task, taskStore: taskStore)
                            }
                        }
                    case .sessions:
                        NavigationStack {
                            MacSessionsView()
                                .environment(session)
                                .environment(router)
                        }
                    case .chat:
                        NavigationStack {
                            MacChatWindow()
                                .environment(session)
                                .environment(router)
                        }
                    case .settings:
                        MacFullSettingsView()
                            .environment(session)
                    }
                }
                .frame(minWidth: 700, minHeight: 500)
                .background(MacMainWindowAccessor())
                .environment(taskStore)
                .environment(orchestratorSuggestionStore)
                .task {
                    await refreshTasksIfReady()
                }
                .onChange(of: session.operatorReady) { _, ready in
                    if ready {
                        Task { await refreshTasksIfReady() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                    Task {
                        await orchestratorSuggestionStore.refreshForCalendarDayChange()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openMainWindowScreen)) { note in
                    guard let raw = note.object as? String,
                          let screen = screen(forRoutePayload: raw)
                    else { return }
                    if screen == .chat {
                        router.startNewChat()
                    } else {
                        router.selectedScreen = screen
                    }
                }
                .sheet(isPresented: $showCreateTask) {
                    MacTaskCreateSheet(taskStore: taskStore) {
                        showCreateTask = false
                    }
                    .environment(session)
                }
            case .signedOut:
                MacSignInView()
                    .frame(minWidth: 600, minHeight: 420)
                    .background(MacMainWindowAccessor())
            }
        }
        .onChange(of: orchestratorSuggestionScopeID) { _, newScopeID in
            // The window owns the store and outlives its authenticated subtree. Retire the old
            // generation synchronously here so sign-out cannot remove Chat before invalidation.
            orchestratorSuggestionStore.invalidateForScopeChange(to: newScopeID)
        }
    }

    private var orchestratorSuggestionScopeID: String {
        guard session.isAuthenticated else { return "signed-out" }
        return [
            session.userProfile?.id ?? "",
            session.backendURL ?? "",
            session.effectiveGatewayScopeIdentity
        ].joined(separator: "|")
    }

    private func refreshTasksIfReady() async {
        guard session.isAuthenticated else { return }
        await taskStore.fetchTasks()
    }

    private func screen(forRoutePayload raw: String) -> MacRouter.Screen? {
        if let route = MainWindowScreenRoute(rawValue: raw) {
            switch route {
            case .agenda: return .agenda
            case .inbox: return .inbox
            case .sessions: return .sessions
            case .chat: return .chat
            case .settings: return .settings
            }
        }
        return MacRouter.Screen(rawValue: raw)
    }
}

private struct MacAuthenticationLoadingView: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DesignTokens.Color.fillTertiary)
                    .frame(width: 56, height: 56)

                VStack(spacing: 8) {
                    skeleton(width: 72, height: 30)
                    skeleton(width: 240, height: 18)
                }
            }

            VStack(spacing: 10) {
                skeleton(width: 320, height: 54)
                skeleton(width: 320, height: 46)
                skeleton(width: 320, height: 46)
            }

            Spacer()
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Color.backgroundPrimary)
        .shimmering()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your account")
    }

    private func skeleton(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(height / 2, 10), style: .continuous)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: height)
    }
}
