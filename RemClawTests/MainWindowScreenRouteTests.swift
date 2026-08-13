import Foundation
import Testing
@testable import RemClaw

// MARK: - What this file does and does not prove
//
// Most tests below read a *source file as text* and assert that certain substrings appear in it.
// This target is the iOS test target, so it cannot link or execute `RemClawMac` view code; reading
// the Mac sources off disk is the only way it can say anything about them at all.
//
// Be clear about the strength of that signal. These are **source-shape** assertions, not
// behavioural ones. They prove some bytes exist somewhere in a file. They do **not** prove that:
//
//   * the code is reachable — nothing here reads `MacRouter`, so a change that stops `.chat` from
//     ever being selected leaves every assertion in `macChatUsesNativeNavigationHostAndFallbackTitle`
//     green while Mac chat is unreachable;
//   * the code is live — a matching string inside a comment or a disabled `#if` branch passes;
//   * the code is the one that wins — a later declaration that shadows the matched one passes;
//   * anything renders — SwiftUI view structure is never instantiated here.
//
// That is not hypothetical. Deleting the Mac chat route outright and leaving the matched text in a
// comment still passes this whole suite.
//
// Reachability and routing state ARE covered behaviourally, in `RemClawMacTests`
// (`MacRouterChatRoutingTests`), which executes the real `MacRouter`. Prefer adding coverage there.
// Treat a green run of this file as "the wiring is still spelled the way we agreed", not as a
// guarantee that the feature works.

/// Substring match that ignores indentation and line breaks.
///
/// The multi-line assertions in this file describe code *shape* — "the chat route is hosted in a
/// `NavigationStack` around `MacChatWindow`" — not code *formatting*. Pinning literal indentation
/// makes an unrelated re-indent fail a test for a reason that has nothing to do with what it
/// checks: `macChatUsesNativeNavigationHostAndFallbackTitle` went red on `staging` when the Mac
/// shell gained one more container around the route `switch` and every line shifted four columns.
///
/// Both sides collapse each run of whitespace to a single space, so matched tokens must still be
/// **contiguous** — nothing but whitespace may sit between them. This relaxes indentation width and
/// line breaks only; it does not weaken adjacency. That matters most for the negative assertions,
/// which an over-specific needle would let pass vacuously.
///
/// Two limits worth knowing before you add a needle:
///
///   * It normalizes whitespace *width*, not whitespace *presence*. `"DatePicker( \"Start Date\""`
///     still fails against a source that reads `DatePicker("Start Date"` on one line, because the
///     needle's space exists only because of a line break. So this survives re-indentation but not
///     line-*joining* — which is what a formatter does to short argument lists.
///   * Do not pass a needle that is empty or all whitespace: it would collapse to `""` and match
///     anything. The precondition below turns that into a loud failure instead of a silent pass.
private extension String {
    func containsIgnoringFormatting(_ needle: String) -> Bool {
        func collapsed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let collapsedNeedle = collapsed(needle)
        precondition(
            !collapsedNeedle.isEmpty,
            "containsIgnoringFormatting needs a non-empty needle — an empty one matches everything, "
            + "which would make this assertion (or its negation) pass for no reason."
        )
        return collapsed(self).contains(collapsedNeedle)
    }
}

struct MainWindowScreenRouteTests {
    @Test func settingsRouteUsesLowercaseNotificationPayload() {
        #expect(MainWindowScreenRoute.settings.rawValue == "settings")
    }

    @Test func nativeSettingsRouteIsIncludedInMainWindowRoutes() {
        #expect(MainWindowScreenRoute.allCases.contains(.settings))
        #expect(Notification.Name.openMainWindowScreen.rawValue == "remclaw.openMainWindowScreen")
    }

    @Test func nativeSettingsFallbackHasStableHideTarget() {
        #expect(MacNativeSettingsTab.fallbackWindowIdentifier == "rem.native-settings-fallback")
        #expect(MacNativeSettingsTab.legacyWindowTitles == [
            "Settings",
            "General",
            "Permissions",
            "Backup",
            "About",
        ])
        #expect(!MacNativeSettingsTab.legacyWindowTitles.contains("Skills"))
        #expect(!MacNativeSettingsTab.legacyWindowTitles.contains("MCP"))
        #expect(!MacNativeSettingsTab.legacyWindowTitles.contains("Accounts"))
        #expect(!MacNativeSettingsTab.legacyWindowTitles.contains("Devices"))
    }

    @Test func macShellUsesSingleSidebarAffordance() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let mainWindow = try read("RemClawMac/Sources/UI/MainWindow.swift", from: projectRoot)
        #expect(mainWindow.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
        #expect(!mainWindow.contains("ToolbarItem(placement: .navigation)"))
        #expect(!mainWindow.contains("Image(systemName: \"sidebar.leading\")"))
        #expect(!mainWindow.contains("toggleSidebar()"))

        let macApp = try read("RemClawMac/Sources/App/RemClawMacApp.swift", from: projectRoot)
        #expect(macApp.contains("SidebarCommands()"))

        let readme = try read("RemClawMac/Sources/UI/README.md", from: projectRoot)
        #expect(readme.contains("relies on standard macOS sidebar commands"))
    }

    @Test func macInboxUsesNativeNavigationTitleInsteadOfInlineHeader() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let inboxView = try read("Shared/Views/Tasks/SharedInboxView.swift", from: projectRoot)
        #expect(inboxView.containsIgnoringFormatting("#if os(macOS) inboxContent"))
        #expect(inboxView.contains(".navigationTitle(\"Inbox\")"))
        #expect(inboxView.contains("ToolbarItem(placement: .status)"))
        #expect(inboxView.contains("ToolbarItem(placement: .primaryAction)"))
        #expect(!inboxView.contains(".help(\"Refresh\")"))
        #expect(inboxView.contains(".task { await store.refresh() }"))
        #expect(inboxView.containsIgnoringFormatting("#else VStack(spacing: 0) { inboxHeader"))

        let readme = try read("RemClawMac/Sources/UI/README.md", from: projectRoot)
        #expect(readme.contains("native navigation title with creation/status toolbar chrome"))
    }

    @Test func macChatUsesNativeNavigationHostAndFallbackTitle() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let mainWindow = try read("RemClawMac/Sources/UI/MainWindow.swift", from: projectRoot)
        #expect(mainWindow.containsIgnoringFormatting("case .chat: NavigationStack { MacChatWindow()"))

        let chatWindow = try read("RemClawMac/Sources/UI/MacChatWindow.swift", from: projectRoot)
        #expect(chatWindow.containsIgnoringFormatting("notSignedInView .navigationTitle(\"Chat\")"))
        #expect(chatWindow.containsIgnoringFormatting("operatorUnavailableView .navigationTitle(\"Chat\")"))
        #expect(chatWindow.contains("ChatConnectionLoadingView(connectionState: .connected)"))
        #expect(!chatWindow.contains("ProgressView(\"Initializing chat...\")"))
        #expect(chatWindow.contains(".navigationTitle(\"Chat\")"))
        #expect(!chatWindow.containsIgnoringFormatting(
            ".frame(minWidth: 480, minHeight: 400) "
            + ".navigationTitle(\"Chat\")"
        ))

        let sharedChat = try read("Shared/Views/Chat/SharedRemChatView.swift", from: projectRoot)
        #expect(sharedChat.contains(".navigationTitle(sessionDisplayName)"))

        let readme = try read("RemClawMac/Sources/UI/README.md", from: projectRoot)
        #expect(readme.contains("Chat is also hosted in a `NavigationStack`"))
    }

    @Test func macChatWiresOneWindowOwnedOrchestratorSuggestionStoreIntoSharedChat() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let mainWindow = try read("RemClawMac/Sources/UI/MainWindow.swift", from: projectRoot)
        #expect(mainWindow.contains("@State private var orchestratorSuggestionStore = MacOrchestratorSuggestionStore()"))
        #expect(mainWindow.contains(".environment(taskStore)"))
        #expect(mainWindow.contains(".environment(orchestratorSuggestionStore)"))
        #expect(mainWindow.contains("guard session.isAuthenticated else { return \"signed-out\" }"))
        // Deliberately no assertion on the brace nesting that precedes `.onChange` here. It used
        // to pin `}` at 12 columns and `}` at 8 — the nesting depth WAS the whole assertion, so
        // unlike the others in this file it cannot survive being made indentation-insensitive
        // with its meaning intact. The next line asserts the modifier and its closure signature
        // directly, which is the part that carries information.
        #expect(mainWindow.contains(".onChange(of: orchestratorSuggestionScopeID) { _, newScopeID in"))
        #expect(mainWindow.contains("orchestratorSuggestionStore.invalidateForScopeChange(to: newScopeID)"))

        let chatWindow = try read("RemClawMac/Sources/UI/MacChatWindow.swift", from: projectRoot)
        #expect(chatWindow.contains("orchestratorSuggestionSnapshot: activeOrchestratorSuggestionSnapshot"))
        #expect(chatWindow.contains("await orchestratorSuggestionStore.accept("))
        #expect(chatWindow.contains("await orchestratorSuggestionStore.dismissSuggestion("))
        #expect(chatWindow.contains("refreshOrchestratorSuggestionsIfNeeded(for:"))
        #expect(!chatWindow.contains("orchestratorSuggestionStore.invalidateForScopeChange"))

        #expect(mainWindow.contains("await orchestratorSuggestionStore.refreshForCalendarDayChange()"))
    }

    @Test func iOSVoiceChatWiresMuteAndKeepsStreamingQuestionBeforeLiveReply() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let remChatView = try read("RemClaw/Sources/Chat/RemChatView.swift", from: projectRoot)
        #expect(remChatView.contains("onToggleMute: { toggleVoiceMute() }"))
        #expect(remChatView.contains("private func toggleVoiceMute()"))
        #expect(remChatView.contains("tm.unmute()"))
        #expect(remChatView.contains("tm.mute()"))

        let sharedChat = try read("Shared/Views/Chat/SharedRemChatView.swift", from: projectRoot)
        #expect(sharedChat.contains("shouldRenderStreamingBeforeVoicePlaceholder"))
        #expect(sharedChat.containsIgnoringFormatting(
            "if shouldRenderStreamingBeforeVoicePlaceholder { "
            + "assistantTailContent"
        ))
        #expect(sharedChat.contains("voiceTranscriptionPlaceholder"))
        #expect(sharedChat.contains("voiceResponsePhase: VoiceResponsePhase = .idle"))
        #expect(sharedChat.contains(".onChange(of: voiceTranscriptionState)"))
        #expect(sharedChat.contains("proxy.scrollTo(\"chat-bottom\", anchor: .bottom)"))
    }

    @Test func macChatTransportHasBoundedMemoryDiagnostics() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let transport = try read("RemClawMac/Sources/Gateway/MacChatTransport.swift", from: projectRoot)
        #expect(transport.containsIgnoringFormatting(
            "#if DEBUG /// Lightweight counters for #601 dogfood "
            + "memory investigations"
        ))
        #expect(transport.contains("private final class MacChatMemoryDiagnostics"))
        #expect(transport.contains("bufferingPolicy: .bufferingNewest(200)"))
        #expect(transport.contains("memoryDiagnostics.recordHistory(payload: rawPayload, rawBytes: res.count)"))
        #expect(transport.contains("memoryDiagnostics.recordYield(result, kind: kind)"))
        #expect(transport.contains("[MacMemoryDiagnostics]"))
        #expect(transport.contains("lastHistoryPayloadBytes"))
        #expect(!transport.contains("lastHistoryTextBytes"))
        #expect(transport.contains("droppedEvents"))
        #expect(transport.contains("droppedEvents == 1 || droppedEvents % 25 == 0"))
        #expect(!transport.contains("private static func historyMetrics(payload: OpenClawChatHistoryPayload)"))

        let readme = try read("RemClawMac/Sources/Gateway/README.md", from: projectRoot)
        #expect(readme.contains("DEBUG-only `[MacMemoryDiagnostics]` counters"))
        #expect(readme.containsIgnoringFormatting("counts and payload bytes only, not chat text"))
    }

    @Test func macSettingsChildRoutesOwnNativeNavigationTitles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let permissionsTab = try read("RemClawMac/Sources/UI/PermissionsTab.swift", from: projectRoot)
        #expect(permissionsTab.contains(".navigationTitle(\"Permissions\")"))
        #expect(permissionsTab.contains("calendarConnectorDestination"))
        #expect(permissionsTab.containsIgnoringFormatting("NavigationLink { calendarConnectorDestination()"))
        #expect(permissionsTab.contains("calendarConnectorLabel(statusText: \"Open Connector\")"))
        #expect(permissionsTab.contains("calendarConnectorLabel(statusText: \"Connector\")"))
        #expect(permissionsTab.contains("Device access stays on this Mac"))
        #expect(permissionsTab.contains("static var permissionsTabRows: [MacPermission]"))
        #expect(permissionsTab.contains("[.accessibility, .screenRecording, .microphone, .speechRecognition, .notifications]"))
        #expect(permissionsTab.contains("Apple Calendar"))
        #expect(permissionsTab.contains("Managed in Connectors"))
        #expect(permissionsTab.contains("Use Connectors to review local Apple Calendar and provider-backed calendars such as Google Calendar."))
        #expect(permissionsTab.contains("Voice input"))
        #expect(permissionsTab.contains("Voice transcription"))

        let macFullSettings = try read("RemClawMac/Sources/UI/MacFullSettingsView.swift", from: projectRoot)
        // Billing was stripped from the open-core app; the Mac settings no longer
        // carries a "Billing & Usage" route.
        #expect(!macFullSettings.contains(".navigationTitle(\"Billing & Usage\")"))

        let sharedSettings = try read("Shared/Views/Settings/SharedSettingsView.swift", from: projectRoot)
        #expect(sharedSettings.contains(".navigationTitle(\"Settings\")"))
        #expect(!sharedSettings.contains("SharedComposioConnectionsView"))
        #expect(!sharedSettings.contains("SharedSkillsHomeView"))
        #expect(sharedSettings.contains("Text(\"Your agent runtime\")"))
        #expect(sharedSettings.contains("Text(\"OpenClaw\")"))
        #expect(!sharedSettings.contains(".navigationTitle(\"Custom Tool Servers\")"))

        let gatewayDetail = try read("Shared/Views/Gateway/SharedGatewayDetailView.swift", from: projectRoot)
        #expect(gatewayDetail.contains("Text(\"Paired Devices\")"))
        #expect(gatewayDetail.contains("Text(\"Connectors\")"))
        #expect(gatewayDetail.contains(".navigationTitle(\"Skills\")"))
        #expect(gatewayDetail.contains("Text(\"Skills\")"))
        #expect(!gatewayDetail.contains("SharedChannelsSettingsView"))
        #expect(!gatewayDetail.contains("Text(\"Channels\")"))

        let readme = try read("RemClawMac/Sources/UI/README.md", from: projectRoot)
        #expect(readme.contains("Settings child routes own their native navigation title"))
        #expect(readme.contains("Permissions is for local macOS device access"))
        #expect(readme.contains("Calendar readiness is managed in Connectors"))
        #expect(readme.contains("navigate to Connectors instead of remaining a static explanation"))
        #expect(readme.contains("Voice readiness owns microphone and speech grants"))
        #expect(readme.contains("push-to-talk and global hotkey support remain Accessibility-scoped"))
    }

    @Test func connectorsUsesOneComposioCatalogWithoutASeparateChannelsProduct() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let connectors = try read("Shared/Views/Settings/SharedComposioConnectionsView.swift", from: projectRoot)
        let gatewayDetail = try read("Shared/Views/Gateway/SharedGatewayDetailView.swift", from: projectRoot)

        #expect(!connectors.contains("Text(\"Messaging channels\")"))
        #expect(!connectors.contains("SharedChannelsSettingsView"))
        // The native-channel product is gone entirely: Composio owns Discord/WhatsApp/Telegram.
        // Guard against a second Channels surface being reintroduced beside the one catalog.
        #expect(!connectors.contains("Manage previous channel connections"))
        #expect(!connectors.contains("LegacyChannelManagement"))
        #expect(!connectors.contains("ChannelsProviding"))
        #expect(connectors.contains("case \"discord\": return \"Discord\""))
        #expect(connectors.contains("case \"discordbot\": return \"Discord Bot\""))
        #expect(connectors.contains("case \"whatsapp\": return \"WhatsApp Business\""))
        #expect(connectors.contains("case \"telegram\": return \"Telegram\""))
        #expect(connectors.contains(".task { await loadApps() }"))
        #expect(!connectors.contains("if isLoading && toolkits.isEmpty"))
        #expect(!gatewayDetail.contains("SharedChannelsSettingsView"))
    }

    @Test func connectorAppsPresentationKeepsLoadingErrorAndContentTruthful() {
        #expect(ConnectorAppsPresentationState.resolve(
            isLoading: true, configured: true, toolkitCount: 0, loadError: nil
        ) == .loading)
        #expect(ConnectorAppsPresentationState.resolve(
            isLoading: false, configured: true, toolkitCount: 0, loadError: "Unavailable"
        ) == .error("Unavailable"))
        #expect(ConnectorAppsPresentationState.resolve(
            isLoading: false, configured: false, toolkitCount: 0, loadError: nil
        ) == .notConfigured)
        #expect(ConnectorAppsPresentationState.resolve(
            isLoading: false, configured: true, toolkitCount: 0, loadError: nil
        ) == .empty)
        #expect(ConnectorAppsPresentationState.resolve(
            isLoading: true, configured: true, toolkitCount: 3, loadError: nil
        ) == .content(error: nil))
        #expect(ConnectorAppsPresentationState.resolve(
            isLoading: false, configured: true, toolkitCount: 3, loadError: "Refresh failed"
        ) == .content(error: "Refresh failed"))

    }

    @Test func macPermissionsFixtureAndDocsExplainDeviceVsConnectorScope() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let macApp = try read("RemClawMac/Sources/App/RemClawMacApp.swift", from: projectRoot)
        #expect(macApp.contains("--rem-permissions-fixture"))
        #expect(macApp.containsIgnoringFormatting("NavigationStack { PermissionsTab(calendarConnectorDestination:"))

        let macFullSettings = try read("RemClawMac/Sources/UI/MacFullSettingsView.swift", from: projectRoot)
        #expect(macFullSettings.contains("PermissionsTab(calendarConnectorDestination: calendarConnectorDestination)"))
        #expect(macFullSettings.contains("private var calendarConnectorDestination: (() -> AnyView)?"))

        let permissionManager = try read("RemClawMac/Sources/Permissions/MacPermissionManager.swift", from: projectRoot)
        #expect(permissionManager.contains("import Speech"))
        #expect(permissionManager.contains("case microphone"))
        #expect(permissionManager.contains("case speechRecognition"))
        #expect(permissionManager.contains("AVCaptureDevice.authorizationStatus(for: .audio)"))
        #expect(permissionManager.contains("SFSpeechRecognizer.authorizationStatus()"))
        #expect(permissionManager.contains("openMicrophoneSettings()"))
        #expect(permissionManager.contains("openSpeechRecognitionSettings()"))
        #expect(permissionManager.contains("case calendar"))
        #expect(permissionManager.contains("\"Read and update events when you ask Rem to plan your day\""))

        let project = try read("RemClaw.xcodeproj/project.pbxproj", from: projectRoot)
        #expect(project.contains("INFOPLIST_KEY_NSMicrophoneUsageDescription"))
        #expect(project.contains("INFOPLIST_KEY_NSSpeechRecognitionUsageDescription"))

        let macEntitlements = try read("RemClawMac.entitlements", from: projectRoot)
        #expect(macEntitlements.contains("com.apple.security.device.audio-input"))

        let permissionsReadme = try read("RemClawMac/Sources/Permissions/README.md", from: projectRoot)
        #expect(permissionsReadme.contains("Apple Calendar and Google Calendar, belong in Connectors"))
        #expect(permissionsReadme.contains("Microphone and Speech Recognition are first-class rows"))
        #expect(permissionsReadme.contains("Camera and Location are not advertised Rem capabilities today."))
    }

    @Test func macTaskCreateSheetUsesNativeNavigationChrome() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let taskCreateView = try read("RemClawMac/Sources/UI/MacTaskCreateView.swift", from: projectRoot)
        #expect(taskCreateView.contains("NavigationStack {"))
        #expect(taskCreateView.contains(".navigationTitle(\"New Task\")"))
        #expect(taskCreateView.contains("ToolbarItem(placement: .cancellationAction)"))
        #expect(taskCreateView.contains("ToolbarItem(placement: .confirmationAction)"))
        #expect(taskCreateView.contains(".formStyle(.grouped)"))
        #expect(!taskCreateView.contains("VStack(spacing: 0)"))
        #expect(!taskCreateView.contains(".buttonStyle(.borderedProminent)"))

        let readme = try read("RemClawMac/Sources/UI/README.md", from: projectRoot)
        #expect(readme.contains("Task creation sheets use native navigation chrome"))
    }

    @Test func macTaskDetailUsesNativeRouteChrome() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let mainWindow = try read("RemClawMac/Sources/UI/MainWindow.swift", from: projectRoot)
        #expect(mainWindow.contains(".navigationDestination(item: $agendaDetailTask)"))
        #expect(mainWindow.contains(".navigationDestination(item: $inboxDetailTask)"))
        #expect(mainWindow.contains("MacTaskDetailView(task: task, taskStore: taskStore)"))

        let taskDetail = try read("RemClawMac/Sources/UI/MacTaskDetailView.swift", from: projectRoot)
        #expect(taskDetail.contains("task.isEvent ? \"Event Details\" : \"Task Details\""))
        #expect(taskDetail.contains("Image(systemName: \"checkmark.circle\")"))
        #expect(taskDetail.contains(".help(\"Mark Complete\")"))
        #expect(taskDetail.contains(".accessibilityLabel(\"Mark Complete\")"))
        #expect(taskDetail.contains("MacTaskDetailChromeFixtureView"))
        #expect(taskDetail.contains(".frame(width: 360, height: 560)"))
        #expect(taskDetail.contains(".accessibilityLabel(task.isEvent ? \"Event Actions\" : \"Task Actions\")"))
        #expect(taskDetail.contains("@State private var isEditingSchedule = false"))
        #expect(taskDetail.containsIgnoringFormatting("DatePicker( \"Start Date\""))
        #expect(taskDetail.contains("private func beginScheduleEditing()"))
        #expect(taskDetail.contains("private func saveSchedule()"))
        #expect(!taskDetail.contains("Label(\"Mark Complete\", systemImage: \"checkmark.circle\")"))
        #expect(!taskDetail.contains("Label(\"Mark complete\", systemImage: \"checkmark.circle\")"))
        #expect(!taskDetail.contains("showRescheduleSheet"))
        #expect(!taskDetail.contains("MacTaskRescheduleSheet"))

        let readme = try read("RemClawMac/Sources/UI/README.md", from: projectRoot)
        #expect(readme.contains("Task detail chrome"))
        #expect(readme.contains("open inline detail routes"))
        #expect(readme.contains("Schedule and reschedule controls expand inline"))
        #expect(readme.contains("Task detail editing scope (#710)"))
        #expect(readme.contains("use a detail-column edit state in `MacTaskDetailView`"))
        #expect(readme.contains("title, notes, priority, category, due date, and start date"))
        #expect(readme.contains("Calendar-event field editing stays unavailable on Mac"))
        #expect(readme.contains("apart from the existing remove action"))
        #expect(readme.contains("MacTaskStore` only owns Rem task REST mutations today"))

        let macApp = try read("RemClawMac/Sources/App/RemClawMacApp.swift", from: projectRoot)
        #expect(macApp.contains("--rem-task-detail-chrome-fixture"))
    }

    @Test func sessionPreviewContractKeepsActivityFeedBeforeVisualPreview() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let contract = try read("docs/product/SESSION_PREVIEW_CONTRACT.md", from: projectRoot)
        #expect(contract.contains("Session preview starts as an **activity preview**, not remote desktop."))
        #expect(contract.containsIgnoringFormatting(
            "Do not start with live stream, always-on screen recording, background "
            + "desktop monitoring, or browser-control loops."
        ))
        #expect(contract.containsIgnoringFormatting(
            "Cloud gateway fallback cannot replace Mac shell, local files, clipboard, "
            + "screen/app context, browser state, or desktop preview."
        ))
        #expect(contract.containsIgnoringFormatting(
            "`Action Feed Only`: safe activity preview is available, but "
            + "visual preview is not approved."
        ))
        #expect(contract.containsIgnoringFormatting(
            "Never store raw secrets, full tokens, private file contents, full command output, full "
            + "accessibility trees, or unapproved screenshots in preview entries."
        ))

        let productReadme = try read("docs/product/README.md", from: projectRoot)
        #expect(productReadme.contains("SESSION_PREVIEW_CONTRACT.md"))
        #expect(productReadme.contains("activity feed first, visual preview only after explicit consent and action logs"))

        let securityModel = try read("docs/product/SECURITY_MODEL.md", from: projectRoot)
        #expect(securityModel.contains("SESSION_PREVIEW_CONTRACT.md"))
        #expect(securityModel.contains("Session preview starts as redacted activity observability, not remote desktop"))

        let capabilitiesIA = try read("docs/product/CAPABILITIES_IA.md", from: projectRoot)
        #expect(capabilitiesIA.containsIgnoringFormatting("For the in-app session preview boundary, see"))
        #expect(capabilitiesIA.contains("SESSION_PREVIEW_CONTRACT.md"))
    }

    private func read(_ relativePath: String, from projectRoot: URL) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
