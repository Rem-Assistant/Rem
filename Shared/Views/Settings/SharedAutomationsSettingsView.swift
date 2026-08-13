import SwiftUI

/// Automations overview. The backend currently exposes three Daily Brief check-in slots; the
/// product presents them as triggers of one built-in automation instead of three unrelated
/// automations. Custom automation creation remains intentionally out of scope.
struct SharedAutomationsSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: DailyBriefAutomationStore
    /// Owned here rather than inside the detail route so one push/pop cycle does not re-fetch, and
    /// so a fixture or preview can inject rows through the same door as the check-in service.
    @State private var inputsStore: AutomationInputsStore
    /// Owned alongside `inputsStore` for the same reason, and because Outputs is now server-derived
    /// too: what the automation produces is a fact about the runner, not a literal in this binary.
    @State private var outputsStore: AutomationOutputsStore

    init(
        service: (any CheckinsProviding)? = nil,
        inputsService: (any AutomationInputsProviding)? = nil,
        outputsService: (any AutomationOutputsProviding)? = nil
    ) {
        _store = State(initialValue: DailyBriefAutomationStore(
            service: service ?? CheckinsService()))
        _inputsStore = State(initialValue: AutomationInputsStore(
            service: inputsService ?? AutomationInputsService(),
            kind: AutomationInputsKind.dailyBrief))
        _outputsStore = State(initialValue: AutomationOutputsStore(
            service: outputsService ?? AutomationOutputsService(),
            kind: AutomationInputsKind.dailyBrief))
    }

    var body: some View {
        platformContainer
            .navigationTitle("Automations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                // Refresh every time the route appears, but shimmer only when there is no
                // renderable cached state. Returning from detail or another device's write should
                // update in place rather than flashing a loading/null state.
                await store.load(showSkeleton: store.checkins.isEmpty)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !store.checkins.isEmpty else { return }
                Task { await store.load(showSkeleton: false) }
            }
    }

    @ViewBuilder
    private var content: some View {
        Section {
            if store.isLoading {
                AutomationOverviewRowSkeleton()
            } else if let loadError = store.loadError {
                automationLoadError(loadError)
            } else {
                NavigationLink {
                    DailyBriefAutomationDetailView(
                        store: store, inputsStore: inputsStore, outputsStore: outputsStore)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.md) {
                        ContainedIcon(
                            icon: "sparkles.rectangle.stack.fill",
                            color: DailyBriefAutomationPresentation.isEnabled(store.checkins)
                                ? DesignTokens.Color.systemBlue : .gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Daily Brief")
                                .foregroundColor(DesignTokens.Color.labelPrimary)
                            Text("Plans your day and follows up at the times you choose.")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                        }
                        Spacer(minLength: DesignTokens.Spacing.sm)
                        Text(DailyBriefAutomationPresentation.statusDescription(store.checkins))
                            .font(DesignTokens.Typography.caption1)
                            .foregroundColor(DesignTokens.Color.labelSecondary)
                    }
                }
            }
        } header: {
            Text("Built in")
        } footer: {
            Text("Daily Brief is Rem's default automation. Open it to choose when it runs, review what it uses, and see recent runs.")
                .font(DesignTokens.Typography.caption1)
        }
    }

    @ViewBuilder
    private func automationLoadError(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(errorTitle(error))
                .font(DesignTokens.Typography.body.weight(.semibold))
                .foregroundColor(DesignTokens.Color.labelPrimary)
            Text(errorMessage(error))
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Button("Try Again") { Task { await store.load(showSkeleton: true) } }
                .remSettingsCTA(.primary, size: .compact)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func errorTitle(_ error: Error) -> String {
        if let serviceError = error as? CheckinsServiceError,
           case let .requestFailed(statusCode, _) = serviceError,
           statusCode == 404 {
            return "Automations need a server update"
        }
        return "Couldn't load automations"
    }

    private func errorMessage(_ error: Error) -> String {
        if let serviceError = error as? CheckinsServiceError,
           case let .requestFailed(statusCode, _) = serviceError,
           statusCode == 404 {
            return "This server doesn't support Daily Brief scheduling yet. Try again after it updates."
        }
        return "Check your connection and try again."
    }

    @ViewBuilder
    private var platformContainer: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { content }
            .listStyle(.insetGrouped)
        #endif
    }

}

/// Placeholder while the derived Inputs are still being read. Deliberately shows no state text:
/// an unknown answer must not look like "Included".
private struct AutomationInputRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DesignTokens.Color.fillTertiary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignTokens.Color.fillTertiary)
                            .frame(width: 110, height: 13)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DesignTokens.Color.fillTertiary)
                            .frame(maxWidth: 220)
                            .frame(height: 10)
                    }
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DesignTokens.Color.fillTertiary)
                        .frame(width: 58, height: 11)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .shimmering()
        .accessibilityLabel("Loading inputs")
    }
}

private struct AutomationOverviewRowSkeleton: View {
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DesignTokens.Color.fillTertiary)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Color.fillTertiary)
                    .frame(width: 92, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Color.fillTertiary)
                    .frame(maxWidth: 250)
                    .frame(height: 11)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(DesignTokens.Color.fillTertiary)
                .frame(width: 54, height: 12)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .shimmering()
        .accessibilityLabel("Loading automations")
    }
}

private struct DailyBriefAutomationDetailView: View {
    enum Selection: String, CaseIterable, Identifiable {
        case settings = "Settings"
        case runHistory = "Run History"
        var id: String { rawValue }
    }

    let store: DailyBriefAutomationStore
    let inputsStore: AutomationInputsStore
    let outputsStore: AutomationOutputsStore

    @State private var selection: Selection = .settings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        platformContainer
            .navigationTitle("Daily Brief")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await store.refreshDetail() }
            // Shimmer only when there is nothing cached; returning from Connectors should update
            // the rows in place rather than flashing a loading state.
            .task { await inputsStore.load(showSkeleton: inputsStore.rows.isEmpty) }
            // Outputs move on their own too: a suggestion accepted elsewhere, or the day's first
            // brief landing, changes what this section can truthfully claim.
            .task { await outputsStore.load(showSkeleton: outputsStore.rows.isEmpty) }
            // Inputs state is owned by the SERVER and changes from outside this screen — the
            // Composio connect flow completes in the user's own browser, and another device can
            // connect or revoke at any time. `.task` alone fires once per view identity, so
            // connecting Gmail and coming back left the row reading "Not connected" until the
            // view was destroyed and rebuilt. These are the three ways a user gets back here:
            //
            //   scenePhase .active — returned from the OAuth hand-off in Safari (the main path)
            //   onAppear           — popped back from a pushed Connectors screen
            //   refreshable        — the manual escape hatch when a row looks wrong
            //
            // All three go through the same generation-guarded `load`, so overlapping refreshes
            // resolve to the newest answer, and none of them shimmers over renderable rows.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await inputsStore.load(showSkeleton: false) }
                Task { await outputsStore.load(showSkeleton: false) }
            }
            .onAppear {
                if inputsStore.hasLoaded {
                    Task { await inputsStore.load(showSkeleton: false) }
                }
                if outputsStore.hasLoaded {
                    Task { await outputsStore.load(showSkeleton: false) }
                }
            }
            .refreshable {
                async let detail: Void = store.refreshDetail()
                async let inputs: Void = inputsStore.load(showSkeleton: false)
                async let outputs: Void = outputsStore.load(showSkeleton: false)
                _ = await (detail, inputs, outputs)
            }
            .onChange(of: selection) { _, selected in
                guard selected == .runHistory else { return }
                Task { await store.refreshDetail() }
            }
    }

    @ViewBuilder
    private var content: some View {
        Section {
            Picker("View", selection: $selection) {
                ForEach(Selection.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
        }

        if let errorMessage = store.detailErrorMessage {
            Section {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.systemRed)
            }
        }

        switch selection {
        case .settings:
            settingsSections
        case .runHistory:
            runHistorySections
        }
    }

    @ViewBuilder
    private var settingsSections: some View {
        Section {
            LabeledContent("Status") {
                Text(DailyBriefAutomationPresentation.isEnabled(store.checkins) ? "Active" : "Off")
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("Daily Brief is active whenever at least one trigger below is on.")
                .font(DesignTokens.Typography.caption1)
        }

        Section {
            ForEach(store.checkins) { checkin in triggerRow(checkin) }
        } header: {
            Text("Triggers")
        } footer: {
            Text("At each enabled time, Rem builds a fresh brief and attempts to add it to Today and notify your devices.")
                .font(DesignTokens.Typography.caption1)
        }

        Section {
            Text("Orient me to the day and identify existing work that needs my attention.")
                .font(DesignTokens.Typography.body)
                .foregroundColor(DesignTokens.Color.labelPrimary)
        } header: {
            Text("Agent instructions")
        } footer: {
            Text("Built in · Custom instructions aren't editable yet.")
                .font(DesignTokens.Typography.caption1)
        }

        Section {
            if inputsStore.isLoading {
                AutomationInputRowSkeleton()
            } else if let loadError = inputsStore.loadError {
                inputsLoadError(loadError)
            } else if !inputsStore.hasLoaded {
                // The route's `.task` has not answered yet. An empty section here would read as
                // "this automation has no inputs", which is a claim we cannot make.
                AutomationInputRowSkeleton()
            } else if inputsStore.rows.isEmpty {
                emptyInputsRow
            } else {
                ForEach(inputsStore.rows) { row in inputRow(row) }
            }
        } header: {
            Text("Inputs")
        } footer: {
            Text("The server reports what this automation can actually read right now. A connected source whose last collection failed is shown as Unavailable, not Included.")
                .font(DesignTokens.Typography.caption1)
        }

        Section {
            if outputsStore.isLoading {
                AutomationInputRowSkeleton()
            } else if let loadError = outputsStore.loadError {
                outputsLoadError(loadError)
            } else if !outputsStore.hasLoaded {
                // The route's `.task` has not answered yet. An empty section here would read as
                // "this automation produces nothing", which is a claim we cannot make.
                AutomationInputRowSkeleton()
            } else if outputsStore.rows.isEmpty {
                emptyOutputsRow
            } else {
                ForEach(outputsStore.rows) { row in outputRow(row) }
            }
        } header: {
            Text("Output")
        } footer: {
            Text("The server reports what this automation actually produced. An output with nothing to show reads as Nothing yet, never as Included. Suggested tasks stay proposals: each names its source and waits for your acceptance before Rem creates lasting work.")
                .font(DesignTokens.Typography.caption1)
        }
    }

    // MARK: Inputs (server-derived)

    /// A `not_connected` row is the only actionable one, and Connectors is where it is resolved —
    /// the same destination as the gateway's `gateway-connectors-nav` row.
    @ViewBuilder
    private func inputRow(_ row: AutomationInputRow) -> some View {
        if AutomationInputsPresentation.opensConnectors(row) {
            NavigationLink {
                SharedComposioConnectionsView(service: ComposioService())
            } label: {
                inputRowContent(row)
            }
            .accessibilityIdentifier("automation-input-connect-\(inputIdentifier(row))")
        } else {
            inputRowContent(row)
                .accessibilityIdentifier("automation-input-\(inputIdentifier(row))")
        }
    }

    private func inputRowContent(_ row: AutomationInputRow) -> some View {
        let emphasis = AutomationInputsPresentation.emphasis(for: row.state)
        return HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            ContainedIcon(
                icon: AutomationInputsPresentation.icon(for: row),
                color: Self.inputIconColor(for: emphasis))
            VStack(alignment: .leading, spacing: 2) {
                Text(AutomationInputsPresentation.title(for: row))
                Text(row.detail)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                if let evidence = AutomationInputsPresentation.secondaryLine(for: row) {
                    Text(evidence)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(Self.inputEvidenceColor(for: emphasis))
                }
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Text(AutomationInputsPresentation.statusLabel(for: row.state))
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(Self.inputStatusColor(for: emphasis))
        }
    }

    private func inputIdentifier(_ row: AutomationInputRow) -> String {
        row.connector?.source ?? row.capability.wireValue
    }

    @ViewBuilder
    private func inputsLoadError(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(Self.inputsErrorTitle(error))
                .font(DesignTokens.Typography.body.weight(.semibold))
                .foregroundColor(DesignTokens.Color.labelPrimary)
            Text(Self.inputsErrorMessage(error))
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Button("Try Again") { Task { await inputsStore.load(showSkeleton: true) } }
                .remSettingsCTA(.primary, size: .compact)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityIdentifier("automation-inputs-error")
    }

    private var emptyInputsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("No inputs reported")
                .font(DesignTokens.Typography.body.weight(.semibold))
            Text("This server didn't list any sources for Daily Brief.")
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityIdentifier("automation-inputs-empty")
    }

    /// An older server has no automations route at all. Say that, rather than blaming the network.
    static func inputsErrorTitle(_ error: Error) -> String {
        isUnsupportedByServer(error) ? "Inputs need a server update" : "Couldn't load inputs"
    }

    static func inputsErrorMessage(_ error: Error) -> String {
        isUnsupportedByServer(error)
            ? "This server doesn't report what Daily Brief reads yet. Try again after it updates."
            : "Check your connection and try again."
    }

    static func isUnsupportedByServer(_ error: Error) -> Bool {
        guard let serviceError = error as? AutomationInputsServiceError,
              case let .requestFailed(statusCode, _) = serviceError
        else { return false }
        return statusCode == 404
    }

    /// `.attention` is amber on purpose: a connected source that stopped delivering must not read
    /// as inert gray, and must never read as the blue of a working one.
    static func inputIconColor(for emphasis: AutomationInputsPresentation.Emphasis) -> Color {
        switch emphasis {
        case .active: return DesignTokens.Color.systemBlue
        case .attention: return DesignTokens.Color.systemOrange
        case .muted: return .gray
        }
    }

    static func inputStatusColor(for emphasis: AutomationInputsPresentation.Emphasis) -> Color {
        emphasis == .attention
            ? DesignTokens.Color.systemOrange
            : DesignTokens.Color.labelSecondary
    }

    static func inputEvidenceColor(for emphasis: AutomationInputsPresentation.Emphasis) -> Color {
        emphasis == .attention
            ? DesignTokens.Color.systemOrange
            : DesignTokens.Color.labelTertiary
    }

    // MARK: Outputs (server-derived)

    private func outputRow(_ row: AutomationOutputRow) -> some View {
        let emphasis = AutomationOutputsPresentation.emphasis(for: row.state)
        return HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            ContainedIcon(
                icon: AutomationOutputsPresentation.icon(for: row),
                color: emphasis == .active ? DesignTokens.Color.systemBlue : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(AutomationOutputsPresentation.title(for: row))
                Text(row.detail)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                if let evidence = AutomationOutputsPresentation.secondaryLine(for: row) {
                    Text(evidence)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelTertiary)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Text(AutomationOutputsPresentation.statusLabel(for: row.state))
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
        .accessibilityIdentifier("automation-output-\(row.output.wireValue)")
    }

    @ViewBuilder
    private func outputsLoadError(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(AutomationOutputsPresentation.errorTitle(error))
                .font(DesignTokens.Typography.body.weight(.semibold))
                .foregroundColor(DesignTokens.Color.labelPrimary)
            Text(AutomationOutputsPresentation.errorMessage(error))
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
            Button("Try Again") { Task { await outputsStore.load(showSkeleton: true) } }
                .remSettingsCTA(.primary, size: .compact)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityIdentifier("automation-outputs-error")
    }

    private var emptyOutputsRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("No outputs reported")
                .font(DesignTokens.Typography.body.weight(.semibold))
            Text("This server didn't list anything Daily Brief produces.")
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityIdentifier("automation-outputs-empty")
    }


    @ViewBuilder
    private var runHistorySections: some View {
        let runs = DailyBriefAutomationPresentation.recentRuns(store.checkins)
        Section {
            if runs.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("No runs yet")
                        .font(DesignTokens.Typography.body.weight(.semibold))
                    Text("The latest scheduled processing time for each trigger will appear here.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            } else {
                ForEach(runs) { run in
                    HStack(spacing: DesignTokens.Spacing.md) {
                        ContainedIcon(
                            icon: icon(for: run.slot), color: Self.iconColor(for: run.slot))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(displayName(for: run.slot)) brief")
                            Text(run.processedAt, format: .dateTime.month().day().hour().minute())
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                        }
                    }
                }
            }
        } header: {
            Text("Last scheduled run")
        } footer: {
            Text("The server currently retains only the latest time each trigger was processed. This does not guarantee that chat authoring or notification delivery succeeded.")
                .font(DesignTokens.Typography.caption1)
        }
    }

    @ViewBuilder
    private func triggerRow(_ checkin: Checkin) -> some View {
        let saving = store.savingSlots.contains(checkin.slot)
        VStack(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                ContainedIcon(
                    icon: checkin.icon,
                    color: checkin.enabled ? Self.iconColor(for: checkin.slot) : .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text(checkin.displayName)
                    Text(Self.timeLabel(checkin))
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
                Spacer()
                Toggle("Enable \(checkin.displayName) trigger", isOn: Binding(
                    get: { checkin.enabled },
                    set: { newValue in
                        Task { await persist(checkin, enabled: newValue) }
                    }
                ))
                .labelsHidden()
                #if os(iOS)
                .toggleStyle(.switch)
                #endif
                .disabled(saving)
            }

            if checkin.enabled {
                HStack {
                    Text("Time")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                    Spacer()
                    DatePicker(
                        "\(checkin.displayName) time",
                        selection: Binding(
                            get: {
                                let value = Self.clamp(
                                    hour: checkin.deliveryHour,
                                    minute: checkin.deliveryMinute,
                                    to: checkin.slot)
                                return Self.date(forHour: value.hour, minute: value.minute)
                            },
                            set: { date in
                                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                                Task {
                                    await persist(
                                        checkin,
                                        enabled: true,
                                        hour: parts.hour ?? checkin.deliveryHour,
                                        minute: parts.minute ?? checkin.deliveryMinute)
                                }
                            }
                        ),
                        in: Self.dateRange(for: checkin.slot),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .disabled(saving)
                }
            }
        }
    }

    @ViewBuilder
    private var platformContainer: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { content }
            .listStyle(.insetGrouped)
        #endif
    }

    private func persist(
        _ checkin: Checkin,
        enabled: Bool,
        hour: Int? = nil,
        minute: Int? = nil
    ) async {
        let requestedHour = hour ?? checkin.deliveryHour
        let requestedMinute = minute ?? checkin.deliveryMinute
        let clamped = Self.clamp(hour: requestedHour, minute: requestedMinute, to: checkin.slot)
        await store.persist(
            slot: checkin.slot,
            enabled: enabled,
            deliveryHour: clamped.hour,
            deliveryMinute: clamped.minute)
    }

    private func displayName(for slot: String) -> String {
        store.checkins.first(where: { $0.slot == slot })?.displayName ?? slot.capitalized
    }

    private func icon(for slot: String) -> String {
        store.checkins.first(where: { $0.slot == slot })?.icon ?? "clock.fill"
    }

    static func timeLabel(_ checkin: Checkin) -> String {
        date(forHour: checkin.deliveryHour, minute: checkin.deliveryMinute)
            .formatted(date: .omitted, time: .shortened)
    }

    static func date(forHour hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    static func slotWindow(_ slot: String) -> (startHour: Int, endHour: Int) {
        switch slot {
        case "morning": return (5, 11)
        case "midday": return (12, 16)
        case "night": return (17, 23)
        default: return (0, 23)
        }
    }

    static func dateRange(for slot: String) -> ClosedRange<Date> {
        let window = slotWindow(slot)
        let start = date(forHour: window.startHour, minute: 0)
        let end = date(forHour: window.endHour, minute: 59)
        return start <= end ? start...end : start...start
    }

    static func clamp(hour: Int, minute: Int, to slot: String) -> (hour: Int, minute: Int) {
        let window = slotWindow(slot)
        if hour < window.startHour { return (window.startHour, 0) }
        if hour > window.endHour { return (window.endHour, 59) }
        return (hour, min(max(minute, 0), 59))
    }

    static func iconColor(for slot: String) -> Color {
        switch slot {
        case "morning": return DesignTokens.Color.systemOrange
        case "midday": return DesignTokens.Color.systemYellow
        case "night": return DesignTokens.Color.systemIndigo
        default: return DesignTokens.Color.systemBlue
        }
    }
}

#Preview {
    NavigationStack {
        SharedAutomationsSettingsView(
            service: MockCheckinsService(),
            inputsService: MockAutomationInputsService(),
            outputsService: MockAutomationOutputsService())
    }
}

#if DEBUG
/// Auth-free visual acceptance route. Launch iOS with `--rem-automations-fixture`, then open the
/// Daily Brief row to inspect its settings and run history against deterministic real-shaped data.
///
/// The Inputs rows deliberately cover all four derived states plus a state this build does not
/// recognize, so the "connected but failing" and "newer server" renderings can be seen without a
/// backend. Timestamps are relative to launch so the evidence line ("2h ago") stays meaningful.
struct SharedAutomationsFixtureView: View {
    var body: some View {
        NavigationStack {
            SharedAutomationsSettingsView(
                service: MockCheckinsService(
                    store: [
                        Checkin(
                            slot: "morning", enabled: true, deliveryHour: 8,
                            deliveryMinute: 15, timezone: "America/Los_Angeles",
                            lastRunAt: "2026-08-08T15:15:00.250Z"),
                        Checkin(
                            slot: "midday", enabled: false, deliveryHour: 12,
                            timezone: "America/Los_Angeles"),
                        Checkin(
                            slot: "night", enabled: true, deliveryHour: 20,
                            deliveryMinute: 30, timezone: "America/Los_Angeles",
                            lastRunAt: "2026-08-08T03:30:00Z"),
                    ],
                    simulatedDelay: .zero),
                inputsService: MockAutomationInputsService(
                    rows: Self.fixtureRows(), simulatedDelay: .zero),
                outputsService: MockAutomationOutputsService(
                    rows: Self.fixtureOutputRows(), simulatedDelay: .zero))
        }
        #if os(macOS)
        .frame(width: 760, height: 620)
        #endif
    }

    /// Covers all three derived output states plus one this build does not recognize, so the
    /// "Nothing yet" and "newer server" renderings can be seen without a backend.
    static func fixtureOutputRows(now: Date = Date()) -> [AutomationOutputRow] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        return [
            AutomationOutputRow(
                output: .dailyOrientation,
                state: .included,
                detail: "Orients you to what is on deck, overdue, blocked, and already done.",
                lastProducedAt: iso.string(from: now.addingTimeInterval(-3600 * 2))),
            AutomationOutputRow(
                output: .attentionTriage,
                state: .idle,
                detail: "Nothing is blocked or overdue right now, so there is nothing to surface.",
                lastItemCount: 0),
            AutomationOutputRow(
                output: .taskSuggestions,
                state: .included,
                detail: "Proposes tasks from your overdue work, your calendar, and your connected sources. A suggestion becomes a durable task only after you accept it.",
                lastItemCount: 4),
            AutomationOutputRow(
                output: .unrecognized("weekly_recap"),
                state: .unrecognized("partially_produced"),
                detail: "A newer server described an output this build has never heard of."),
        ]
    }

    static func fixtureRows(now: Date = Date()) -> [AutomationInputRow] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let hoursAgo: (Double) -> String = { iso.string(from: now.addingTimeInterval(-3600 * $0)) }

        return [
            AutomationInputRow(
                capability: .remTasks,
                state: .included,
                detail: "Reads scheduled, overdue, blocked, and completed task rows stored by Rem.",
                lastCollectedAt: hoursAgo(1),
                lastItemCount: 12),
            AutomationInputRow(
                capability: .remCalendarItems,
                state: .included,
                detail: "Includes calendar-event rows already available in Rem's task store.",
                lastCollectedAt: hoursAgo(1),
                lastItemCount: 1),
            AutomationInputRow(
                capability: .connector,
                state: .unavailable,
                detail: "Gmail is connected, but its last collection didn't complete.",
                connector: AutomationInputConnector(source: "gmail", displayName: "Gmail"),
                lastCollectedAt: hoursAgo(2),
                lastItemCount: 0,
                lastUnavailableReason: "connector_unavailable"),
            AutomationInputRow(
                capability: .connector,
                state: .notConnected,
                detail: "Connect Slack and Daily Brief can read the last day of messages.",
                connector: AutomationInputConnector(source: "slack", displayName: "Slack")),
            AutomationInputRow(
                capability: .cloudBrowser,
                state: .comingSoon,
                detail: "Cloud-browser findings aren't collected for Daily Brief yet."),
            AutomationInputRow(
                capability: .unrecognized("smart_home"),
                state: .unrecognized("degraded"),
                detail: "Reported by a newer server than this build of Rem understands.",
                lastCollectedAt: hoursAgo(26),
                lastItemCount: 4),
        ]
    }
}
#endif
