import SwiftUI

/// Produces a transient success confirmation only for a genuine connection completion.
/// Repeated status reads of an already-connected toolkit must not replay the toast.
enum ComposioConnectionToastPolicy {
    static func consumeSuccessItem(
        displayName: String,
        toolkit: String,
        isConnected: Bool,
        pendingConfirmations: inout Set<String>
    ) -> RemToastItem? {
        guard isConnected, pendingConfirmations.remove(toolkit) != nil else { return nil }
        return .success("\(displayName) connected.")
    }
}

/// User-facing identity for Composio toolkit slugs. Keep provider and bot-oriented toolkits
/// distinct: Composio exposes `discord` and `discordbot` as separate grants.
enum ComposioToolkitPresentation {
    static func displayName(for toolkit: String) -> String {
        switch toolkit {
        case "gmail": return "Gmail"
        case "googlecalendar": return "Google Calendar"
        case "googledrive": return "Google Drive"
        case "googledocs": return "Google Docs"
        case "googlesheets": return "Google Sheets"
        case "github": return "GitHub"
        case "slack": return "Slack"
        case "discord": return "Discord"
        case "discordbot": return "Discord Bot"
        case "whatsapp": return "WhatsApp Business"
        case "telegram": return "Telegram"
        case "notion": return "Notion"
        case "linear": return "Linear"
        case "todoist": return "Todoist"
        case "asana": return "Asana"
        default: return toolkit.capitalized
        }
    }

    static func iconName(for toolkit: String) -> String {
        switch toolkit {
        case "gmail": return "envelope.fill"
        case "googlecalendar": return "calendar"
        case "googledrive": return "externaldrive.fill"
        case "googledocs": return "doc.text.fill"
        case "googlesheets": return "tablecells.fill"
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "slack": return "number"
        case "discord", "discordbot": return "bubble.left.and.bubble.right.fill"
        case "whatsapp": return "phone.bubble.left.fill"
        case "telegram": return "paperplane.fill"
        case "notion": return "note.text"
        case "linear": return "checklist"
        case "todoist": return "checkmark.circle.fill"
        case "asana": return "square.stack.3d.up.fill"
        default: return "link"
        }
    }
}

enum ComposioAvailabilityPresentation {
    static func statusLabel(for state: ComposioConnectionState?, isConnecting: Bool) -> String {
        if let state, state.isConnected {
            if state.isRuntimeSyncing {
                return state.isEnabled ? "Connected • Activating…" : "Connected • Updating…"
            }
            if !state.isEnabled { return "Connected • Paused" }
            if state.isRuntimeReady { return "Connected • Active" }
            return "Connected • Runtime unavailable"
        }
        return isConnecting ? "Connecting…" : "Not connected"
    }

    static func applying(
        _ result: ComposioMutationResult,
        to current: ComposioConnectionState,
        enabled: Bool
    ) -> ComposioConnectionState {
        ComposioConnectionState(
            toolkit: current.toolkit,
            status: current.status,
            connectedAccountId: current.connectedAccountId,
            enabled: enabled,
            runtimeReady: result.isRuntimeReady,
            runtimeSyncing: result.runtimeState == .syncing
        )
    }
}

enum ComposioMutationFailurePolicy {
    /// Only a client/auth rejection proves the backend never admitted the desired-state job.
    /// Transport, decoding, and 5xx failures are outcome-unknown: provider pagination may already
    /// have changed one or more accounts, so reverting the optimistic state would assert a lie.
    static func shouldRevertOptimisticState(for error: Error) -> Bool {
        guard case let ComposioServiceError.requestFailed(statusCode, _) = error else { return false }
        return [400, 401, 403, 404, 422].contains(statusCode)
    }
}

/// Pure rendering decision for the Composio-backed connected-app catalog.
enum ConnectorAppsPresentationState: Equatable {
    case loading
    case error(String)
    case notConfigured
    case empty
    case content(error: String?)

    static func resolve(
        isLoading: Bool,
        configured: Bool,
        toolkitCount: Int,
        loadError: String?
    ) -> Self {
        if toolkitCount > 0 { return .content(error: loadError) }
        if isLoading { return .loading }
        if let loadError { return .error(loadError) }
        if !configured { return .notConfigured }
        return .empty
    }
}

/// Prevents a catalog request admitted before a provider mutation from publishing stale grant
/// truth after the optimistic mutation state. Mutation admission invalidates every older load;
/// overlapping reads likewise allow only the newest generation to publish.
struct ComposioCatalogLoadGenerationFence {
    private(set) var current = 0

    mutating func begin() -> Int {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func canPublish(_ generation: Int) -> Bool {
        generation == current
    }
}

enum ComposioPollPublicationPolicy {
    static func nextGeneration(after current: Int?) -> Int {
        (current ?? 0) &+ 1
    }

    static func canPublish(
        isCancelled: Bool,
        currentConnectionId: String?,
        polledConnectionId: String,
        currentPollGeneration: Int?,
        polledGeneration: Int
    ) -> Bool {
        !isCancelled
            && currentConnectionId == polledConnectionId
            && currentPollGeneration == polledGeneration
    }

    static func canClearConnectingAfterExhaustion(
        isCancelled: Bool,
        currentConnectionId: String?,
        polledConnectionId: String,
        currentPollGeneration: Int?,
        polledGeneration: Int
    ) -> Bool {
        canPublish(
            isCancelled: isCancelled,
            currentConnectionId: currentConnectionId,
            polledConnectionId: polledConnectionId,
            currentPollGeneration: currentPollGeneration,
            polledGeneration: polledGeneration
        )
    }
}

/// What one status response means for the poll loop.
///
/// A committed OAuth grant is NOT the end of the connect lifecycle. The backend reports the
/// gateway runtime on a SEPARATE axis (`runtimeReady` / `runtimeSyncing`, composio.routes.ts)
/// because wiring this user's hosted-MCP endpoint into their gateway continues after the grant
/// commits, and `/composio/status/:id` bounds its own observation of that work to ~2s
/// (`RUNTIME_READINESS_OBSERVATION_MS`) while the first wire after a NEW grant has to mint a
/// Composio session and round-trip `config.get` + `config.patch` to a Fly machine — which that
/// service's own notes measure at 15-67s on this fleet.
///
/// So the first `connected` response very nearly always carries `runtimeSyncing: true`, which
/// the row renders as "Connected • Activating…". Treating that as terminal (the old behaviour)
/// stranded the row on that label: nothing re-asked, because `recheckInFlightConnections()`
/// skips toolkits that already read as connected. Only a full catalog reload — leaving and
/// re-entering the screen, or pull-to-refresh — could ever promote it to "Connected • Active".
enum ComposioConnectPollStep: Equatable {
    /// OAuth hasn't completed yet — keep waiting for the grant.
    case awaitingGrant
    /// Grant committed, gateway runtime still reconciling. Finish the CONNECT attempt (toast,
    /// spinner) but keep polling so the row can reach a real runtime verdict.
    case grantCommittedRuntimeSyncing
    /// Grant committed and the runtime axis is terminal — ready, or explicitly unavailable.
    case settled
    case failed

    static func resolve(_ state: ComposioConnectionState) -> Self {
        if state.status == "failed" { return .failed }
        guard state.isConnected else { return .awaitingGrant }
        return state.isRuntimeSyncing ? .grantCommittedRuntimeSyncing : .settled
    }

    var hasCommittedGrant: Bool {
        self == .grantCommittedRuntimeSyncing || self == .settled
    }
}

/// Drives one connect poll to a REAL terminal state across both phases.
///
/// The loop lives here — not inline in the view — so the sequencing itself is unit-testable
/// (`ComposioConnectPollDriverTests`) rather than only its label mapping. Effects are injected;
/// the driver owns attempt budgets and the terminal rule.
enum ComposioConnectPollDriver {
    struct Budget: Equatable {
        /// Waiting for the user to finish OAuth in the system browser.
        var grantAttempts: Int
        var grantDelay: Duration
        /// Waiting for the gateway to acknowledge the new hosted-MCP scope. Given its own budget
        /// because it is a slower, independent phase — spending the grant budget on it would let a
        /// slow OAuth return leave no attempts at all for the runtime.
        var runtimeAttempts: Int
        var runtimeDelay: Duration

        static let standard = Budget(
            grantAttempts: 5,
            grantDelay: .seconds(2),
            runtimeAttempts: 10,
            runtimeDelay: .seconds(3)
        )
    }

    enum Termination: Equatable {
        /// Grant committed and the runtime reported a terminal verdict.
        case settled
        case failed
        /// Budget exhausted while OAuth was still outstanding — the user is likely still in the browser.
        case grantNotObserved
        /// Grant committed but the runtime was still syncing when the budget ran out. The row keeps
        /// its honest "Activating…" label; foreground re-check is the recovery path.
        case runtimeNotSettled
        /// Cancelled, or superseded by a newer poll/mutation.
        case abandoned
    }

    /// - Parameters:
    ///   - publish: writes the state onto the row. Returns `false` when this poll has been
    ///     superseded (newer connection id, newer generation, cancelled, or a pause/disconnect
    ///     admission took the toolkit) — the driver then abandons without touching anything else.
    ///   - onGrantCommitted: fires at most once, the first time the grant is observed committed.
    static func run(
        budget: Budget = .standard,
        isCancelled: () -> Bool,
        sleep: (Duration) async -> Void,
        fetch: () async throws -> ComposioConnectionState,
        publish: (ComposioConnectionState) -> Bool,
        onGrantCommitted: (ComposioConnectionState) -> Void
    ) async -> Termination {
        var grantAttemptsLeft = budget.grantAttempts
        var runtimeAttemptsLeft = budget.runtimeAttempts
        var grantCommitted = false
        var isFirstAttempt = true

        // Exactly one budget governs at a time: the grant budget until the grant commits, the
        // runtime budget after. Letting the leftover grant budget also keep the loop alive would
        // never terminate — once committed, only `runtimeAttemptsLeft` decrements.
        while grantCommitted ? runtimeAttemptsLeft > 0 : grantAttemptsLeft > 0 {
            if isCancelled() { return .abandoned }
            if !isFirstAttempt {
                await sleep(grantCommitted ? budget.runtimeDelay : budget.grantDelay)
                if isCancelled() { return .abandoned }
            }
            isFirstAttempt = false
            if grantCommitted { runtimeAttemptsLeft -= 1 } else { grantAttemptsLeft -= 1 }

            let state: ComposioConnectionState
            do {
                state = try await fetch()
            } catch {
                continue // transient — spend the attempt, keep trying
            }
            guard publish(state) else { return .abandoned }

            let step = ComposioConnectPollStep.resolve(state)
            if step.hasCommittedGrant && !grantCommitted {
                grantCommitted = true
                onGrantCommitted(state)
            }
            switch step {
            case .settled: return .settled
            case .failed: return .failed
            case .grantCommittedRuntimeSyncing, .awaitingGrant: continue
            }
        }
        // A throwing fetch on the LAST attempt skips `publish`, so nothing on that pass could have
        // detected a supersede. Re-check before reporting exhaustion: a cancelled poll reporting
        // `.runtimeNotSettled` would release an admission gate a live replacement poll is holding.
        if isCancelled() { return .abandoned }
        return grantCommitted ? .runtimeNotSettled : .grantNotObserved
    }
}

/// Synchronous admission for hosted OAuth creation. The row's visual disabled state is rendered on
/// a later update, so two unstructured MainActor tasks can both enter `beginConnect` before that
/// redraw. This reference gate is the authoritative per-toolkit fence across those task entries.
@MainActor
final class ComposioConnectAdmissionGate {
    private var nextGeneration = 0
    private var generationByToolkit: [String: Int] = [:]

    func admit(_ toolkit: String) -> Int? {
        guard generationByToolkit[toolkit] == nil else { return nil }
        nextGeneration &+= 1
        generationByToolkit[toolkit] = nextGeneration
        return nextGeneration
    }

    func currentGeneration(for toolkit: String) -> Int? {
        generationByToolkit[toolkit]
    }

    func owns(_ toolkit: String, generation: Int) -> Bool {
        generationByToolkit[toolkit] == generation
    }

    func release(_ toolkit: String, generation: Int) {
        guard owns(toolkit, generation: generation) else { return }
        generationByToolkit[toolkit] = nil
    }

    func invalidate(_ toolkit: String) {
        generationByToolkit[toolkit] = nil
        nextGeneration &+= 1
    }

    func invalidateAll() -> Set<String> {
        let invalidated = Set(generationByToolkit.keys)
        generationByToolkit.removeAll()
        nextGeneration &+= 1
        return invalidated
    }
}

struct ConnectorSettingsPresentation: Equatable {
    let apps: ConnectorAppsPresentationState

    static func resolve(
        isLoading: Bool,
        configured: Bool,
        toolkitCount: Int,
        loadError: String?
    ) -> Self {
        Self(
            apps: .resolve(
                isLoading: isLoading,
                configured: configured,
                toolkitCount: toolkitCount,
                loadError: loadError
            )
        )
    }
}

/// Composio connections — one catalog for productivity and messaging integrations. Messaging rows
/// use Composio's real toolkit/auth lifecycle rather than routing into a second Channels product.
///
/// Flow (on-device OAuth, from the spike): tap Connect → backend `POST /composio/connect` returns a
/// Composio-hosted Connect Link → we open it in the system browser via SwiftUI `openURL` → the user
/// authorizes provider consent on THEIR device (residential IP, no datacenter block) → Composio
/// captures the token on its own callback → we poll `GET /composio/status/:id` until it flips to
/// "connected", re-checking when the app returns to the foreground since the user may spend a while
/// in the browser while backgrounded. No secret ever passes through Rem.
///
/// Row/CTA shape mirrors `SharedSkillsSettingsView`. TWO DISTINCT actions on a connected row:
///  - **Trailing switch = "Available to Rem" (enable/disable), NON-destructive.** On = the agent can
///    use the connector; Off = **paused** (the OAuth token is KEPT — the agent just can't use it —
///    and flipping back On is instant, no re-auth). Backend `setToolkitEnabled` disables/enables all
///    active accounts for the toolkit.
///  - **Metadata subtitle = drill-in** to a compact manage sheet whose only action is a destructive
///    **Disconnect & revoke access** button (confirmationDialog → the existing `disconnect` endpoint).
/// A not-connected row's trailing stays the shared `RemRowConnectCTA` pill (nothing to toggle). The
/// brand logo renders through `RemRemoteLogoView` (real SVG Composio logos, SF-Symbol fallback,
/// #1069) and is dimmed when the connector is paused so the state reads at a glance.
struct SharedComposioConnectionsView: View {
    /// Injected so previews can pass `MockComposioService` and the host passes the live
    /// `ComposioService()` (constructed at the call site rather than defaulted — a @MainActor
    /// default-arg is not expressible in a synchronous init).
    let service: any ComposioProviding

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var configured = true
    @State private var toolkits: [ComposioToolkitSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var statusByToolkit: [String: ComposioConnectionState] = [:]
    @State private var connectingToolkits: Set<String> = []
    /// Connection ids for toolkits the user has attempted to connect this session, kept around so
    /// a foreground re-poll (#1081) knows what to re-check without the user tapping Connect again.
    @State private var connectionIdByToolkit: [String: String] = [:]
    /// Connect attempts still owed one success confirmation. This attempt-owned state prevents a
    /// refresh that observes the new backend connection first from suppressing the toast.
    @State private var pendingConnectionConfirmations: Set<String> = []
    /// In-flight poll tasks, keyed by toolkit, so a new poll (retry or foreground re-check) cancels
    /// any stale one instead of racing it, and so `.onDisappear` can cancel all of them (#1081).
    @State private var pollTasks: [String: Task<Void, Never>] = [:]
    @State private var pollGenerationByToolkit: [String: Int] = [:]
    @State private var connectAdmissionGate = ComposioConnectAdmissionGate()
    @State private var banner: Banner?
    @State private var toast: RemToastItem?
    /// The connected toolkit whose manage/disconnect sheet is open (metadata drill-in target).
    @State private var managingToolkit: ComposioToolkitSummary?
    /// Toolkits with an in-flight enable/disable (pause) request — disables the switch so a rapid
    /// double-tap can't race two calls, and shows the switch is mid-update.
    @State private var togglingToolkits: Set<String> = []
    @State private var catalogLoadFence = ComposioCatalogLoadGenerationFence()

    init(service: any ComposioProviding) {
        self.service = service
    }

    struct Banner: Equatable {
        enum Kind { case success, error }
        let kind: Kind
        let text: String
    }

    var body: some View {
        listBody
        .macSettingsCenteredColumn()
        // "Connectors" matches the existing Settings entry-point label and the
        // copy in PermissionsTab / Skills' connector fallback text — kept
        // consistent with the surface it replaces rather than introducing a
        // second name for the same concept.
        .navigationTitle("Connectors")
        .task { await loadApps() }
        .refreshable { await loadApps() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            recheckInFlightConnections()
        }
        .onDisappear {
            for task in pollTasks.values { task.cancel() }
            pollTasks.removeAll()
            for toolkit in Array(pollGenerationByToolkit.keys) {
                pollGenerationByToolkit[toolkit] = ComposioPollPublicationPolicy.nextGeneration(
                    after: pollGenerationByToolkit[toolkit]
                )
            }
            let invalidatedToolkits = connectAdmissionGate.invalidateAll()
            connectingToolkits.subtract(invalidatedToolkits)
            for toolkit in invalidatedToolkits {
                connectionIdByToolkit[toolkit] = nil
                pendingConnectionConfirmations.remove(toolkit)
            }
        }
        .sheet(item: $managingToolkit) { toolkit in
            ComposioConnectionSheet(
                toolkit: toolkit,
                displayName: displayName(toolkit.slug),
                iconName: iconName(toolkit.slug),
                logoURL: toolkit.logoUrl.flatMap(URL.init(string:)),
                onDisconnect: { await performDisconnect(toolkit) }
            )
        }
        .remToast(item: $toast)
        .accessibilityIdentifier("shared-composio-connections")
    }

    // MARK: - List body

    private var listBody: some View {
        Group {
            #if os(macOS)
            Form { listSections }.formStyle(.grouped).macSettingsCenteredColumn()
            #else
            List { listSections }.listStyle(.insetGrouped)
            #endif
        }
    }

    @ViewBuilder
    private var listSections: some View {
        if let banner {
            Section { bannerView(banner) }
        }

        Section {
            switch screenPresentation.apps {
            case .loading:
                ConnectorListLoadingSkeleton(rowCount: 4)
            case let .error(message):
                recoveryView(message)
            case .notConfigured:
                Text("Connections aren't turned on for this workspace yet.")
                    .foregroundStyle(.secondary)
            case .empty:
                Text("No connected apps are available right now.")
                    .foregroundStyle(.secondary)
            case let .content(error):
                if let error { recoveryView(error) }
                ForEach(toolkits) { toolkit in
                    connectorRow(toolkit)
                }
            }
        } header: {
            Text("Connected apps")
        } footer: {
            Text("Connect an account so Rem can act in it (read your Gmail, add calendar events, open GitHub issues). You authorize on your own device; Rem never sees your password.")
        }

    }

    private var screenPresentation: ConnectorSettingsPresentation {
        .resolve(
            isLoading: isLoading,
            configured: configured,
            toolkitCount: toolkits.count,
            loadError: loadError
        )
    }

    private func recoveryView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(message)
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(DesignTokens.Color.labelSecondary)
            Button("Try Again") { Task { await loadApps() } }
                .remInlineRecoveryCTA()
        }
    }

    @ViewBuilder
    private func connectorRow(_ toolkit: ComposioToolkitSummary) -> some View {
        let slug = toolkit.slug
        if statusByToolkit[slug]?.isConnected == true {
            // Connected → LEFT/metadata drills into the manage/disconnect sheet; RIGHT is the
            // enable/disable (pause) switch. Two distinct actions, so the row is NOT a single button.
            HStack(spacing: 12) {
                Button {
                    managingToolkit = toolkit
                } label: {
                    HStack(spacing: 6) {
                        // Dim the logo when paused so the state reads at a glance.
                        connectorIcon(for: toolkit)
                            .opacity(isEnabled(slug) ? 1 : 0.4)
                        labelStack(slug)
                        Image(systemName: "chevron.forward")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connector-row-manage-\(slug)")
                .accessibilityHint("Opens options to disconnect \(displayName(slug))")

                Toggle(isOn: enabledBinding(slug)) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(togglingToolkits.contains(slug))
                    .accessibilityIdentifier("connector-enabled-toggle-\(slug)")
                    .accessibilityLabel("\(displayName(slug)) connection enabled")
            }
            .accessibilityIdentifier("connector-row-\(slug)")
        } else {
            HStack(spacing: 12) {
                connectorIcon(for: toolkit)
                labelStack(slug)
                Spacer(minLength: 0)
                trailing(slug)
            }
            .accessibilityIdentifier("connector-row-\(slug)")
        }
    }

    private func labelStack(_ slug: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName(slug)).font(.body).foregroundStyle(.primary)
            Text(statusLabel(slug)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Real per-toolkit branding (#1069). Composio's logos are SVG, which SwiftUI's `AsyncImage`
    /// can't decode — `RemRemoteLogoView` renders SVG (and raster) and falls back to the SF Symbol
    /// below while loading, on failure, or when the backend has no logo — never an empty slot.
    private func connectorIcon(for toolkit: ComposioToolkitSummary) -> some View {
        RemRemoteLogoView(url: toolkit.logoUrl.flatMap(URL.init(string:))) {
            SettingsIcon(icon: iconName(toolkit.slug), color: .blue)
        }
    }

    /// Not-connected trailing accessory — the shared `RemRowConnectCTA` pill (same component the
    /// Skills install row and Channels connect row use), or a spinner while connecting.
    @ViewBuilder
    private func trailing(_ toolkit: String) -> some View {
        if connectingToolkits.contains(toolkit) {
            ProgressView().controlSize(.small)
        } else {
            RemRowConnectCTA(
                title: "Connect",
                action: { Task { await beginConnect(toolkit) } },
                accessibilityLabel: "Connect \(displayName(toolkit))",
                accessibilityHint: "Opens your browser to authorize \(displayName(toolkit))"
            )
            .accessibilityIdentifier("connector-row-connect-\(toolkit)")
            .disabled(!configured)
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(banner.kind == .success ? .green : .orange)
            Text(banner.text).font(.callout)
        }
    }

    // MARK: - Actions

    private func loadApps() async {
        let generation = catalogLoadFence.begin()
        isLoading = true
        loadError = nil
        defer {
            if catalogLoadFence.canPublish(generation) { isLoading = false }
        }
        do {
            let resp = try await service.toolkits()
            guard catalogLoadFence.canPublish(generation) else { return }
            configured = resp.configured
            toolkits = resp.toolkits
            // Seed status from the user's real per-toolkit connection state (#1082) so a relaunch
            // shows "Connected" for toolkits already authorized instead of every row resetting to
            // "Not connected" until the user manually re-triggers a poll.
            for summary in resp.toolkits {
                statusByToolkit[summary.slug] = ComposioConnectionState(
                    toolkit: summary.slug,
                    status: summary.status,
                    connectedAccountId: nil,
                    // Seed the switch state from the backend's per-toolkit enabled flag so a paused
                    // connector shows its switch OFF on load, not defaulted ON.
                    enabled: summary.isConnected ? summary.isEnabled : nil,
                    runtimeReady: summary.isConnected ? resp.isRuntimeReady : false,
                    runtimeSyncing: summary.isConnected ? resp.isRuntimeSyncing : false
                )
                presentConnectionCompletionIfNeeded(
                    toolkit: summary.slug,
                    isConnected: summary.isConnected
                )
            }
        } catch {
            guard catalogLoadFence.canPublish(generation) else { return }
            loadError = Self.calmErrorText(
                for: error,
                fallback: "Couldn't load connections right now. Try again in a moment."
            )
        }
    }

    private func beginConnect(_ toolkit: String) async {
        guard let attemptGeneration = connectAdmissionGate.admit(toolkit) else { return }
        catalogLoadFence.invalidate()
        isLoading = false
        banner = nil
        connectingToolkits.insert(toolkit)
        do {
            let session = try await service.connect(toolkit: toolkit, callbackURL: nil)
            guard !Task.isCancelled,
                  connectAdmissionGate.owns(toolkit, generation: attemptGeneration) else { return }
            guard let url = URL(string: session.redirectUrl) else {
                connectingToolkits.remove(toolkit)
                connectAdmissionGate.release(toolkit, generation: attemptGeneration)
                banner = Banner(kind: .error, text: "Composio returned an invalid connect link.")
                return
            }
            connectionIdByToolkit[toolkit] = session.connectionId
            pendingConnectionConfirmations.insert(toolkit)
            // Open the Composio Connect Link in the system browser — the user authorizes provider
            // consent on THEIR device (residential IP). Composio captures the token via its own
            // callback, so we just poll status; there's no app-owned redirect to catch.
            openURL(url)
            startPolling(
                toolkit: toolkit,
                connectionId: session.connectionId,
                attemptGeneration: attemptGeneration
            )
        } catch {
            guard connectAdmissionGate.owns(toolkit, generation: attemptGeneration) else { return }
            connectingToolkits.remove(toolkit)
            connectAdmissionGate.release(toolkit, generation: attemptGeneration)
            banner = Banner(
                kind: .error,
                text: Self.calmErrorText(
                    for: error,
                    fallback: "Couldn't connect \(displayName(toolkit)) right now. Try again in a moment."
                )
            )
        }
    }

    // MARK: Enable / disable (pause)

    /// Current availability of a connected toolkit — defaults to available unless the backend/local
    /// state says paused.
    private func isEnabled(_ slug: String) -> Bool {
        statusByToolkit[slug]?.isEnabled ?? true
    }

    /// Binding the row's switch drives: reads local availability, and on flip fires the
    /// enable/disable (pause) request. Non-destructive — no confirmation needed (unlike disconnect).
    private func enabledBinding(_ slug: String) -> Binding<Bool> {
        Binding(
            get: { isEnabled(slug) },
            set: { newValue in Task { await setEnabled(slug, enabled: newValue) } }
        )
    }

    /// Pause (off) or resume (on) a connected toolkit. Optimistically flips the local switch so it
    /// feels instant, calls the backend, and reverts on failure. Keeps the row CONNECTED either way
    /// — pause is not disconnect; the OAuth token stays.
    private func setEnabled(_ slug: String, enabled: Bool) async {
        guard !togglingToolkits.contains(slug) else { return }
        invalidatePoll(for: slug)
        catalogLoadFence.invalidate()
        isLoading = false
        banner = nil
        let previous = statusByToolkit[slug]
        togglingToolkits.insert(slug)
        defer { togglingToolkits.remove(slug) }
        // Optimistic flip.
        if let current = statusByToolkit[slug] {
            statusByToolkit[slug] = ComposioConnectionState(
                toolkit: current.toolkit,
                status: current.status,
                connectedAccountId: current.connectedAccountId,
                enabled: enabled
            )
        }
        do {
            let result = try await service.setEnabled(toolkit: slug, enabled: enabled)
            if let current = statusByToolkit[slug] {
                statusByToolkit[slug] = ComposioAvailabilityPresentation.applying(
                    result,
                    to: current,
                    enabled: enabled
                )
            }
            if enabled && result.runtimeState == .syncing {
                banner = Banner(
                    kind: .success,
                    text: "\(displayName(slug)) enabled. Rem is still activating its tools."
                )
            } else if enabled && result.runtimeState == .unavailable {
                banner = Banner(
                    kind: .error,
                    text: "\(displayName(slug)) connected, but its tools aren't available right now. Try refreshing."
                )
            } else {
                banner = Banner(
                    kind: .success,
                    text: enabled ? "\(displayName(slug)) is available to Rem again." : "\(displayName(slug)) paused."
                )
            }
        } catch {
            if ComposioMutationFailurePolicy.shouldRevertOptimisticState(for: error) {
                // A 4xx proves the backend rejected the job before provider mutation began.
                statusByToolkit[slug] = previous
                banner = Banner(
                    kind: .error,
                    text: Self.calmErrorText(
                        for: error,
                        fallback: "Couldn't update \(displayName(slug)) right now. Try again in a moment."
                    )
                )
            } else {
                // A timeout/5xx can arrive after a partial or committed provider mutation. Keep the
                // requested state and require an authoritative catalog refresh instead of lying by
                // restoring the old switch position.
                if let current = statusByToolkit[slug] {
                    statusByToolkit[slug] = ComposioConnectionState(
                        toolkit: current.toolkit,
                        status: current.status,
                        connectedAccountId: current.connectedAccountId,
                        enabled: enabled,
                        runtimeReady: false,
                        runtimeSyncing: true
                    )
                }
                banner = Banner(
                    kind: .error,
                    text: "Rem couldn't confirm the final \(displayName(slug)) state. Refresh Connections before changing it again."
                )
            }
        }
    }

    /// Disconnect (revoke) a connected toolkit. Called from the manage sheet's switch/confirm.
    /// Returns `true` on success so the sheet can dismiss; flips the row back to not-connected.
    /// Toolkit-based: the backend revokes EVERY active account for the toolkit (allowMultiple), so a
    /// second active connection can't keep the agent connected after "Disconnect".
    private func performDisconnect(_ toolkit: ComposioToolkitSummary) async -> Bool {
        invalidatePoll(for: toolkit.slug)
        catalogLoadFence.invalidate()
        isLoading = false
        banner = nil
        let slug = toolkit.slug
        do {
            let result = try await service.disconnect(toolkit: slug)
            // Reflect the revoke immediately: the row flips back to not-connected and a fresh Connect
            // becomes available. Drop any stale in-flight poll id so a foreground re-check doesn't
            // resurrect the old connection.
            statusByToolkit[slug] = ComposioConnectionState(toolkit: slug, status: "not_connected", connectedAccountId: nil)
            connectionIdByToolkit[slug] = nil
            pendingConnectionConfirmations.remove(slug)
            pollTasks[slug]?.cancel()
            pollTasks[slug] = nil
            connectingToolkits.remove(slug)
            connectAdmissionGate.invalidate(slug)
            banner = Banner(
                kind: .success,
                text: result.isCompleted
                    ? "\(displayName(slug)) disconnected."
                    : "\(displayName(slug)) disconnect accepted. Rem is finishing the revoke."
            )
            return true
        } catch {
            banner = Banner(
                kind: .error,
                text: Self.calmErrorText(
                    for: error,
                    fallback: "Couldn't disconnect \(displayName(slug)) right now. Try again in a moment."
                )
            )
            return false
        }
    }

    /// Cancels any previous poll for this toolkit (retry or foreground re-check racing an older
    /// one) and starts a fresh one, tracked so `.onDisappear` can cancel it too (#1081).
    private func startPolling(toolkit: String, connectionId: String, attemptGeneration: Int) {
        pollTasks[toolkit]?.cancel()
        let generation = ComposioPollPublicationPolicy.nextGeneration(
            after: pollGenerationByToolkit[toolkit]
        )
        pollGenerationByToolkit[toolkit] = generation
        pollTasks[toolkit] = Task {
            await pollStatus(
                toolkit: toolkit,
                connectionId: connectionId,
                generation: generation,
                attemptGeneration: attemptGeneration
            )
        }
    }

    /// Retires any response already awaiting for this toolkit before a pause/revoke mutation can
    /// publish optimistic or final state. Cancellation is advisory, so generation is authoritative.
    ///
    /// Retiring the poll also retires the connect ATTEMPT that owns it. A poll abandoned this way
    /// returns without releasing the admission gate — correct when a newer poll took over (it holds
    /// the same attempt generation and will release it), but a pause retires the poll and starts no
    /// replacement, so the gate would stay held for a connect that is no longer running. That was
    /// survivable while the loop released at the committed grant a second or two in; the loop now
    /// stays alive through the runtime phase, so the window is wide enough to matter.
    ///
    /// Retiring the attempt also retires its SPINNER. `recheckInFlightConnections` now re-polls
    /// toolkits that are already connected, and those passes set `connectingToolkits` too, so an
    /// abandoned poll would otherwise leave the flag set with no owner left to clear it —
    /// invisible while the row reads connected, but a permanent spinner with no Connect button
    /// once a later catalog load seeds the row back to not-connected.
    private func invalidatePoll(for toolkit: String) {
        pollTasks[toolkit]?.cancel()
        pollTasks[toolkit] = nil
        pollGenerationByToolkit[toolkit] = ComposioPollPublicationPolicy.nextGeneration(
            after: pollGenerationByToolkit[toolkit]
        )
        connectAdmissionGate.invalidate(toolkit)
        connectingToolkits.remove(toolkit)
    }

    /// Poll after the user returns from the browser. The token is captured by Composio's callback
    /// out-of-band, so the grant is usually ready within a couple seconds — but the gateway runtime
    /// that makes those tools actually callable settles on its own, slower schedule, so the loop
    /// runs until BOTH are terminal (see `ComposioConnectPollDriver`).
    ///
    /// `connectingToolkits` (and so the "Connecting…" spinner) stays set for the toolkit across the
    /// whole grant phase, not just the initial `/connect` call, and clears the moment the grant
    /// commits — the runtime phase is not the user's connect attempt and must not hold the spinner.
    private func pollStatus(
        toolkit: String,
        connectionId: String,
        generation: Int,
        attemptGeneration: Int
    ) async {
        defer {
            if pollGenerationByToolkit[toolkit] == generation {
                pollTasks[toolkit] = nil
            }
        }
        let termination = await ComposioConnectPollDriver.run(
            isCancelled: { Task.isCancelled },
            sleep: { try? await Task.sleep(for: $0) },
            fetch: { try await service.status(connectionId: connectionId, toolkit: toolkit) },
            publish: { state in
                guard ComposioPollPublicationPolicy.canPublish(
                    isCancelled: Task.isCancelled,
                    currentConnectionId: connectionIdByToolkit[toolkit],
                    polledConnectionId: connectionId,
                    currentPollGeneration: pollGenerationByToolkit[toolkit],
                    polledGeneration: generation
                ), connectAdmissionGate.owns(toolkit, generation: attemptGeneration) else { return false }
                statusByToolkit[toolkit] = state
                return true
            },
            onGrantCommitted: { _ in
                // OAuth completion is newer than any catalog GET admitted before Connect, so retire
                // that response. Fires once, at the transition — the runtime phase that follows
                // publishes many more connected states, and invalidating the fence on each of them
                // would keep retiring catalog loads the user legitimately triggered.
                catalogLoadFence.invalidate()
                isLoading = false
                connectingToolkits.remove(toolkit)
                presentConnectionCompletionIfNeeded(toolkit: toolkit, isConnected: true)
            }
        )

        switch termination {
        case .abandoned:
            return
        case .failed:
            guard connectAdmissionGate.owns(toolkit, generation: attemptGeneration) else { return }
            connectingToolkits.remove(toolkit)
            connectAdmissionGate.release(toolkit, generation: attemptGeneration)
            pendingConnectionConfirmations.remove(toolkit)
            banner = Banner(kind: .error, text: "\(displayName(toolkit)) connection failed. Try again.")
        case .settled, .runtimeNotSettled:
            // The connect attempt is over either way. `runtimeNotSettled` leaves the row on its
            // honest "Connected • Activating…" label; `recheckInFlightConnections()` re-asks on the
            // next foreground, and a catalog reload also promotes it.
            //
            // Fenced like `.grantNotObserved` below, and for the same reason: `release`'s own
            // `owns` check cannot tell this poll from a REPLACEMENT poll holding the same attempt
            // generation — which `recheckInFlightConnections` deliberately arranges by reusing
            // `currentGeneration(for:)`. Releasing unfenced would hand the live poll's gate away
            // and strand the row on the very label this fix exists to clear.
            guard ComposioPollPublicationPolicy.canClearConnectingAfterExhaustion(
                isCancelled: Task.isCancelled,
                currentConnectionId: connectionIdByToolkit[toolkit],
                polledConnectionId: connectionId,
                currentPollGeneration: pollGenerationByToolkit[toolkit],
                polledGeneration: generation
            ) else { return }
            connectAdmissionGate.release(toolkit, generation: attemptGeneration)
        case .grantNotObserved:
            // Exhausted attempts without OAuth completing — the user is likely still mid-flow in
            // the browser. Revert the spinner so the row doesn't look stuck; `connectionIdByToolkit`
            // keeps the connection id around so returning to the foreground re-checks it without
            // the user tapping Connect again.
            guard ComposioPollPublicationPolicy.canClearConnectingAfterExhaustion(
                isCancelled: Task.isCancelled,
                currentConnectionId: connectionIdByToolkit[toolkit],
                polledConnectionId: connectionId,
                currentPollGeneration: pollGenerationByToolkit[toolkit],
                polledGeneration: generation
            ), connectAdmissionGate.owns(toolkit, generation: attemptGeneration) else { return }
            connectingToolkits.remove(toolkit)
            connectAdmissionGate.release(toolkit, generation: attemptGeneration)
        }
    }

    /// Re-checks any toolkit the user has attempted to connect this session but that isn't showing
    /// as connected yet (#1081). The original poll only runs for ~10s in a detached Task while the
    /// user is off in the external browser — often longer than that — so foreground is the more
    /// reliable moment to catch the real outcome.
    private func recheckInFlightConnections() {
        for (toolkit, connectionId) in connectionIdByToolkit {
            // A committed grant whose gateway runtime is still syncing is NOT settled. Skipping it
            // here (the old `isConnected != true` guard) is what left a freshly-connected row
            // stranded on "Connected • Activating…" — foreground was the one moment that could have
            // re-asked, and it declined to.
            guard ComposioConnectPollStep.resolve(
                statusByToolkit[toolkit] ?? ComposioConnectionState(
                    toolkit: toolkit,
                    status: "unknown",
                    connectedAccountId: nil
                )
            ) != .settled else { continue }
            let attemptGeneration: Int
            if let current = connectAdmissionGate.currentGeneration(for: toolkit) {
                attemptGeneration = current
            } else if let admitted = connectAdmissionGate.admit(toolkit) {
                attemptGeneration = admitted
            } else {
                continue
            }
            connectingToolkits.insert(toolkit)
            startPolling(
                toolkit: toolkit,
                connectionId: connectionId,
                attemptGeneration: attemptGeneration
            )
        }
    }

    /// Consumes the attempt-owned confirmation exactly once, regardless of whether polling or a
    /// refresh is the first path to observe the backend's connected state.
    private func presentConnectionCompletionIfNeeded(toolkit: String, isConnected: Bool) {
        guard let item = ComposioConnectionToastPolicy.consumeSuccessItem(
            displayName: displayName(toolkit),
            toolkit: toolkit,
            isConnected: isConnected,
            pendingConfirmations: &pendingConnectionConfirmations
        ) else { return }
        toast = item
    }

    // MARK: - Presentation helpers

    private func displayName(_ toolkit: String) -> String {
        ComposioToolkitPresentation.displayName(for: toolkit)
    }

    /// SF Symbol fallback shown while the real logo (toolkit.logoUrl) is loading, on fetch
    /// failure, or when the backend has no logo for this toolkit — never the only icon in the
    /// happy path, so an unmapped future slug falling through to "link" is a cosmetic-only gap.
    private func iconName(_ toolkit: String) -> String {
        ComposioToolkitPresentation.iconName(for: toolkit)
    }

    /// Subtitle keeps provider grant state separate from acknowledged gateway runtime readiness.
    /// ACTIVE is shown only after the hosted-MCP config reconciles successfully.
    private func statusLabel(_ toolkit: String) -> String {
        ComposioAvailabilityPresentation.statusLabel(
            for: statusByToolkit[toolkit],
            isConnecting: connectingToolkits.contains(toolkit)
        )
    }

    /// Maps a thrown error to calm, user-facing copy — never the raw "Request failed (HTTP 404)"
    /// a route-not-found or unconfigured-backend response would otherwise produce (#1070). A real
    /// backend-supplied message (e.g. "Unsupported toolkit …") is calm enough on its own and passes
    /// through; only a bare status code with no message gets replaced.
    private static func calmErrorText(for error: Error, fallback: String) -> String {
        guard let composioError = error as? ComposioServiceError else { return fallback }
        switch composioError {
        case .notConfigured:
            return "Connections aren't set up yet."
        case let .requestFailed(statusCode, message):
            if let message, !message.isEmpty { return message }
            if statusCode == 404 { return "Connections aren't set up yet." }
            return fallback
        }
    }
}

// MARK: - Loading skeleton

/// Loading placeholder for the Connectors list — a column of shimmering skeleton rows that mirror
/// the real connector-row layout (leading logo square, name + subtitle text bars, trailing Connect
/// pill) so the swap from skeleton to content doesn't visually jump. Mirrors
/// `SessionListLoadingSkeleton` (#1106): grey rounded bars filled with `DesignTokens.Color.fillTertiary`
/// under a single `.shimmering()` sweep. Cross-platform — no platform-only APIs.
private struct ConnectorListLoadingSkeleton: View {
    /// Fixed name-bar widths per row so the mock list reads as a set of varied connectors rather
    /// than identical bars (the subtitle bar derives from this). Mirrors the fixed-width approach in
    /// `SessionListLoadingSkeleton`.
    private let nameWidths: [CGFloat] = [120, 96, 140, 84, 132, 104, 116, 92]
    let rowCount: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(nameWidths.prefix(rowCount).enumerated()), id: \.offset) { _, width in
                skeletonRow(nameWidth: width)
            }
        }
        .shimmering()
        // Bars are decorative; announce the loading status once (the old spinner branch had an
        // accessible "Loading connections…" label) rather than exposing each bar to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading connections…")
    }

    private func skeletonRow(nameWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            // Leading logo slot — mirrors the 28×28 rounded-square `RemRemoteLogoView`.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DesignTokens.Color.fillTertiary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                bar(width: nameWidth, height: 14)
                bar(width: nameWidth * 0.7, height: 11)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            // Trailing "Connect" pill placeholder.
            Capsule()
                .fill(DesignTokens.Color.fillTertiary)
                .frame(width: 74, height: 24)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm + 2)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: height)
    }
}

// MARK: - Connected-item manage / disconnect sheet

/// Compact, min-height sheet reached by tapping a connected connector's metadata. Availability
/// (pause/resume) lives on the ROW's switch now — this sheet's only job is the DESTRUCTIVE path:
/// a single **Disconnect & revoke access** button that requires an explicit `confirmationDialog`
/// before it revokes (deletes the OAuth grant; reconnecting needs a fresh sign-in).
private struct ComposioConnectionSheet: View {
    let toolkit: ComposioToolkitSummary
    let displayName: String
    let iconName: String
    let logoURL: URL?
    /// Performs the revoke; returns `true` on success so the sheet dismisses. Owns the parent state
    /// update (row → not-connected) and the success/error banner.
    let onDisconnect: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var showConfirm = false

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            NavigationStack {
                core
                    .navigationTitle(displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            // Small sheet, not full-height — just the identity + the destructive action fit.
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.visible)
            #endif
        }
        // Explicit destructive confirmation — the button never revokes on the first tap.
        .confirmationDialog(
            "Disconnect \(displayName)?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect & Revoke Access", role: .destructive) {
                Task {
                    isWorking = true
                    let ok = await onDisconnect()
                    isWorking = false
                    if ok { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes Rem's access to \(displayName) and deletes the stored authorization. Reconnecting later requires a fresh sign-in.")
        }
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayName).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            core
        }
        .frame(width: 360, height: 250)
    }
    #endif

    /// Logo + name + one short line, then the destructive button pinned below. Deliberately plain
    /// (not a grouped `Form`/`List`) so the sheet stays compact at the min detent.
    private var core: some View {
        VStack(spacing: 16) {
            RemRemoteLogoView(url: logoURL, size: 52, cornerRadius: 12) {
                SettingsIcon(icon: iconName, color: .blue)
            }
            VStack(spacing: 4) {
                Text(displayName).font(.headline)
                Text("Rem can act in \(displayName) using your authorized account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                showConfirm = true
            } label: {
                Group {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Disconnecting…")
                        }
                    } else {
                        Text("Disconnect & Revoke Access")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(isWorking)
            .accessibilityIdentifier("connector-disconnect-button-\(toolkit.slug)")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#if DEBUG
#Preview("Connectors — Mock") {
    NavigationStack {
        SharedComposioConnectionsView(
            service: MockComposioService(
                connected: ["gmail", "googlecalendar", "notion", "slack"],
                paused: ["slack"]
            )
        )
    }
}
#endif
