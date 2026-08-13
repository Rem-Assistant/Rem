import SwiftUI
import OpenClawKit

// MARK: - Shared Skills Settings View

/// Skills management view shared between iOS and macOS.
/// Uses `GatewaySessionProviding` protocol to work with either session manager.
struct SharedSkillsSettingsView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway
    var connectorDestination: ((SkillConnectorProvider) -> AnyView)? = nil

    @Environment(\.openSkillSetupChat) private var openSkillSetupChat

    @State private var skills: [SkillEntry] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var filter: SkillFilter = .standard
    @State private var detailSkill: SkillEntry?

    private var filteredSkills: [SkillEntry] {
        switch filter {
        case .standard: skills
        case .installed: skills.filter { $0.isEligible }
        case .notInstalled: skills.filter { !$0.isEligible }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading skills...")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = errorText {
                VStack(spacing: 12) {
                    Spacer()
                    Text(error)
                        .foregroundColor(.red)
                    Button("Retry") {
                        Task { await loadSkills() }
                    }
                    .remSettingsCTA(.primary, size: .compact)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if skills.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No skills available")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                #if os(macOS)
                Form { skillsSections }
                    .formStyle(.grouped)
                    .macSettingsCenteredColumn()
                #else
                List { skillsSections }
                    .listStyle(.insetGrouped)
                #endif
            }
        }
        .accessibilityIdentifier("shared-skills-settings")
        .task { await loadSkills() }
        .onChange(of: gateway.skillsSnapshotVersion) { _, _ in
            Task { await loadSkills() }
        }
        .sheet(item: $detailSkill) { skill in
            SharedSkillDetailSheet(
                skill: skill,
                gateway: gateway,
                connectorDestination: connectorDestination,
                openSetupChat: openSkillSetupChat,
                onRequirementsChanged: {
                    await loadSkills()
                    detailSkill = skills.first { $0.skillKey == skill.skillKey }
                }
            )
        }
    }

    @ViewBuilder
    private var skillsSections: some View {
        Section {
            Picker("Filter", selection: $filter) {
                ForEach(SkillFilter.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }

        Section {
            if filteredSkills.isEmpty {
                Text("No matching skills")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredSkills) { skill in
                    SharedSkillRow(
                        skill: skill,
                        // Only offer the row-level Connect/Install button when the
                        // host wired up chat routing (iOS). On Mac the closure is
                        // nil, so the row falls back to opening detail on tap.
                        onConnect: openSkillSetupChat.map { open in
                            {
                                let request = SkillSetupChatRequest(
                                    skill: skill,
                                    primaryRequirement: skill.requirementDisplayRows.first
                                )
                                open(request)
                            }
                        },
                        onToggle: { newEnabled in
                            await toggleSkill(key: skill.skillKey, enabled: newEnabled)
                        },
                        onDetail: {
                            detailSkill = skill
                        }
                    )
                }
            }
        } footer: {
            Text("Skills & integrations extend what your AI assistant can do.")
        }
    }

    private func loadSkills() async {
        #if DEBUG
        print("[Skills] loadSkills called — connected=\(gateway.connectionState.isConnected), operatorReady=\(gateway.operatorReady)")
        #endif
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            errorText = "Not connected to gateway"
            #if DEBUG
            print("[Skills] Skipped: gateway not connected or operator not ready")
            #endif
            return
        }
        isLoading = true
        errorText = nil
        do {
            #if DEBUG
            print("[Skills] Sending skills.status RPC...")
            #endif
            let res = try await gateway.skillsRequest(method: "skills.status", paramsJSON: nil)
            #if DEBUG
            if let raw = String(data: res, encoding: .utf8) {
                print("[Skills] Response (\(res.count) bytes): \(raw.prefix(500))")
            }
            #endif
            let decoded = try JSONDecoder().decode(SkillsStatusResponse.self, from: res)
            skills = decoded.skills.sorted(by: SkillEntry.capabilitiesListSort)
            #if DEBUG
            print("[Skills] Decoded \(skills.count) skills")
            #endif
        } catch {
            errorText = "Failed to load: \(error.localizedDescription)"
            #if DEBUG
            print("[Skills] Error: \(error)")
            #endif
        }
        isLoading = false
    }

    private func toggleSkill(key: String, enabled: Bool) async {
        do {
            let data = try JSONEncoder().encode(SkillToggleParams(skillKey: key, enabled: enabled))
            let json = String(data: data, encoding: .utf8)
            _ = try await gateway.skillsRequest(method: "skills.update", paramsJSON: json)
            await loadSkills()
        } catch {
            errorText = "Failed to update: \(error.localizedDescription)"
        }
    }
}

#if DEBUG
#Preview("Skills Settings — Connected") {
    NavigationStack {
        SharedSkillsSettingsView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected)
        )
        .navigationTitle("Installed")
    }
}

#Preview("Skills Settings — Unreachable") {
    NavigationStack {
        SharedSkillsSettingsView(
            gateway: PreviewGatewaySession(scenario: .cloudUnreachable)
        )
        .navigationTitle("Installed")
    }
}
#endif

/// Parameters for skills.update RPC call. Defined at top level because
/// Swift doesn't allow nested types inside generic functions/types.
private struct SkillToggleParams: Codable {
    var skillKey: String
    var enabled: Bool
}

// MARK: - Skill Row

private struct SharedSkillRow: View {
    let skill: SkillEntry
    /// Opens chat with a ready connect/install prompt for this capability.
    /// Nil when the host didn't wire chat routing (e.g. Mac) — the row then
    /// just taps through to detail.
    var onConnect: (() -> Void)?
    let onToggle: (Bool) async -> Void
    var onDetail: (() -> Void)?

    @State private var isToggling = false

    var body: some View {
        HStack(spacing: 10) {
            // Whole leading area taps through to the detail page. Reads like an
            // App Store search-result row: icon + name + short subtitle on the
            // left, action control on the right (no disclosure chevron).
            Button {
                onDetail?()
            } label: {
                HStack(spacing: 10) {
                    SkillIconBadge(spec: skill.iconSpec, isEnabled: skill.isEligible, size: 28, cornerRadius: 6)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name ?? skill.skillKey)
                            .font(.callout)
                            .foregroundColor(.primary)

                        if let description = skill.description {
                            Text(description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        if !skill.isEligible {
                            Text(skill.missingShortLabel)
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Trailing accessory (App-Store-style):
            //   - Ready capability      → enable/disable toggle (manage state).
            //   - Not-ready capability  → Connect/Install pill that opens chat
            //     pre-typed with a ready connect prompt, so the user just hits
            //     send and the agent runs the flow in chat.
            trailingAccessory
        }
        .accessibilityIdentifier("skill-row-\(skill.skillKey)")
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isToggling {
            ProgressView()
                .controlSize(.small)
        } else if skill.isEligible {
            Toggle("", isOn: Binding(
                get: { skill.isEnabled },
                set: { newValue in
                    isToggling = true
                    Task {
                        await onToggle(newValue)
                        isToggling = false
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        } else if let onConnect {
            // Shared pill CTA (#958) — same component the Channels connect row uses, so the two
            // browsable-capability surfaces read as one system.
            RemRowConnectCTA(
                title: skill.setupActionLabel,
                action: onConnect,
                accessibilityLabel: "\(skill.setupActionLabel) \(skill.name ?? skill.skillKey)",
                accessibilityHint: "Opens chat with a ready prompt to set up this capability"
            )
            .accessibilityIdentifier("skill-row-connect-\(skill.skillKey)")
        }
    }
}

// MARK: - Skill Icon Badge

struct SkillIconBadge: View {
    let spec: SkillIconSpec
    var isEnabled: Bool = true
    var size: CGFloat = 36
    var cornerRadius: CGFloat = 8

    private var tint: Color {
        guard isEnabled else { return .secondary }
        switch spec.tintName {
        case "accent": return .accentColor
        case "blue": return .blue
        case "cyan": return .cyan
        case "green": return .green
        case "indigo": return .indigo
        case "mint": return .mint
        case "orange": return .orange
        case "pink": return .pink
        case "red": return .red
        case "teal": return .teal
        case "yellow": return .yellow
        default: return .purple
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(tint.opacity(isEnabled ? 0.16 : 0.1))
            .frame(width: size, height: size)
            .overlay {
                switch spec.kind {
                case .emoji(let emoji):
                    Text(emoji)
                        .font(.system(size: size * 0.46))
                case .symbol(let symbol):
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundColor(tint)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Skill Detail Sheet

private struct SharedSkillDetailSheet<Gateway: GatewaySessionProviding>: View {
    let skill: SkillEntry
    let gateway: Gateway
    var connectorDestination: ((SkillConnectorProvider) -> AnyView)?
    var openSetupChat: ((SkillSetupChatRequest) -> Void)? = nil
    var onRequirementsChanged: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var actionContext: SkillRequirementActionContext?

    var body: some View {
        Group {
            #if os(macOS)
            macDetailView
            #else
            NavigationStack {
                detailContent
                    .navigationTitle(skill.name ?? skill.skillKey)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            #endif
        }
        .sheet(item: $actionContext) { context in
            SharedSkillRequirementActionSheet(
                context: context,
                gateway: gateway,
                connectorDestination: connectorDestination,
                onRequirementsChanged: onRequirementsChanged
            )
        }
    }

    #if os(macOS)
    private var macDetailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(skill.name ?? skill.skillKey)
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            detailContent
        }
        .frame(width: 420, height: 480)
    }
    #endif

    private var detailContent: some View {
        Group {
            #if os(macOS)
            Form { detailSections }
                .formStyle(.grouped)
            #else
            List { detailSections }
                .listStyle(.insetGrouped)
            #endif
        }
    }

    @ViewBuilder
    private var detailSections: some View {
            // Overview
            Section("Overview") {
                VStack(alignment: .leading, spacing: 6) {
                    if let desc = skill.description {
                        Text(desc).font(.callout)
                    }
                    LabeledContent("Key", value: skill.skillKey).font(.callout)
                    if let source = skill.source {
                        LabeledContent("Source", value: source).font(.callout)
                    }
                    LabeledContent("Eligible", value: skill.isEligible ? "Yes" : "No").font(.callout)
                    LabeledContent("Enabled", value: skill.isEnabled ? "On" : "Off").font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Declared Requirements
            if let reqs = skill.requirements,
               (reqs.bins ?? []).isEmpty == false || (reqs.env ?? []).isEmpty == false {
                Section("Declared Requirements") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let bins = reqs.bins, !bins.isEmpty {
                            ForEach(bins, id: \.self) { bin in
                                Label(bin, systemImage: "terminal.fill").font(.callout)
                            }
                        }
                        if let env = reqs.env, !env.isEmpty {
                            ForEach(env, id: \.self) { key in
                                Label(key, systemImage: "key.fill").font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            let requirementRows = skill.requirementDisplayRows
            if !requirementRows.isEmpty {
                Section("Setup Required") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let title = skill.connectorRequirementsSummaryTitle,
                           let detail = skill.connectorRequirementsSummaryDetail {
                            SkillConnectorRequirementsSummaryView(
                                title: title,
                                detail: detail,
                                providers: skill.connectorRequirementProviders
                            )
                        }

                        ForEach(requirementRows) { row in
                            SkillRequirementRowView(
                                row: row,
                                onAction: nil
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if openSetupChat != nil {
                    Section {
                        Button {
                            let request = SkillSetupChatRequest(
                                skill: skill,
                                primaryRequirement: requirementRows.first
                            )
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                openSetupChat?(request)
                            }
                        } label: {
                            Label("Install in chat", systemImage: "bubble.left.and.text.bubble.right.fill")
                        }
                        .remPrimaryActionButton()
                        .padding(.horizontal)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Rem will open a chat with this capability context so you can review the install step before anything changes.")
                    }
                }
            }

            // Config Checks
            let visibleChecks = skill.displayableConfigChecks
            if !visibleChecks.isEmpty {
                Section("Config Checks") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(visibleChecks.enumerated()), id: \.offset) { _, check in
                            HStack(spacing: 6) {
                                Image(
                                    systemName: check.status == "ok"
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill"
                                )
                                    .foregroundColor(check.status == "ok" ? .green : .orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    if let label = check.label { Text(label).font(.callout) }
                                    if let message = check.message {
                                        Text(message).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Install Steps
            if let steps = skill.install, !steps.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            VStack(alignment: .leading, spacing: 1) {
                                if let label = step.label { Text(label).font(.callout) }
                                if let bins = step.bins, !bins.isEmpty {
                                    Text("Covers: \(bins.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Install Steps")
                } footer: {
                    Text("Use Install in chat to review and run the safest next step with Rem.")
                }
            }
    }

}

private struct SkillConnectorRequirementsSummaryView: View {
    let title: String
    let detail: String
    let providers: [SkillConnectorProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                providerIcons
            }

            Text(detail)
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var providerIcons: some View {
        HStack(spacing: 6) {
            ForEach(providers, id: \.rawValue) { provider in
                Image(systemName: provider.connectorSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .accessibilityLabel(provider.displayName)
            }
        }
    }
}

private struct SkillRequirementActionContext: Identifiable, Equatable {
    let skillDisplayName: String
    let skillInstallKey: String
    let row: SkillRequirementDisplayRow

    var id: String { "\(skillInstallKey)-\(row.id)" }
}

private struct SkillRequirementRowView: View {
    let row: SkillRequirementDisplayRow
    var onAction: (() -> Void)?

    private var tint: Color {
        switch row.status {
        case .actionAvailable:
            return .orange
        case .blocked:
            return row.kind == .platform ? .orange : .red
        }
    }

    private var statusText: String? {
        switch row.status {
        case .actionAvailable:
            return nil
        case .blocked:
            return "Blocked"
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if let statusText {
                        Text(statusText)
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(tint)
                    }
                }

                Text(row.detail)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        Group {
            if let onAction {
                Button(action: onAction) {
                    rowContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens setup action")
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SharedSkillRequirementActionSheet<Gateway: GatewaySessionProviding>: View {
    let context: SkillRequirementActionContext
    let gateway: Gateway
    var connectorDestination: ((SkillConnectorProvider) -> AnyView)?
    var onRequirementsChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var installState: GatewaySkillInstallState = .idle

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.row.title)
                                .font(.headline)
                            Text(context.row.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: context.row.systemImage)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(context.skillDisplayName)
                }

                Section("Action") {
                    actionContent
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle(context.row.actionKind?.label ?? "Setup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        switch context.row.actionKind {
        case .installTool(let installerID, let installerKind, let label):
            VStack(alignment: .leading, spacing: 12) {
                Label("Review machine install", systemImage: "terminal.fill")
                    .font(.body.weight(.semibold))

                Text(label)
                    .font(.callout)

                Text("This setup runs on the active machine, not on this device. Rem asks OpenClaw to run the skill's selected manifest installer through its `skills.install` safety checks, keeps progress out of chat, and re-checks requirements after the install.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let installerKind {
                    LabeledContent("Installer", value: installerKind)
                }
                if let installerID {
                    LabeledContent("Step", value: installerID)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label(gateway.connectionState.isConnected && gateway.operatorReady ? "Machine is ready" : "Machine must be connected", systemImage: "checklist")
                    Label("User confirmation required", systemImage: "hand.tap")
                    Label("Install progress stays outside chat", systemImage: "text.bubble")
                    Label("Requirements re-check after install", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                installerStatusView

                Button {
                    Task { await installOnGateway(installId: installerID, installerKind: installerKind) }
                } label: {
                    switch installState {
                    case .installing:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing...")
                        }
                    case .succeeded:
                        Text("Installed")
                    default:
                        Text("Install on Machine")
                    }
                }
                    .remSettingsCTA(.primary, size: .compact)
                    .disabled(!canInstallOnGateway(installId: installerID, installerKind: installerKind))
                    .accessibilityHint("Runs the selected skill installer on the active machine after confirmation.")

                Text(installerFooterText(installId: installerID, installerKind: installerKind))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .openConnector(let provider):
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Authorize account in Connectors")
                            .font(.body.weight(.semibold))
                        Text(provider.skillHandoffDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: provider.connectorSystemImage)
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("Account authorization stays with this Rem account", systemImage: "person.crop.circle.badge.checkmark")
                    Label("The active machine can reuse approved connector tokens", systemImage: "server.rack")
                    Label("No raw provider token is pasted into this skill setup", systemImage: "key.slash")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let connectorDestination {
                    NavigationLink {
                        connectorDestination(provider)
                    } label: {
                        Label("Open \(provider.displayName) Connector", systemImage: "link.circle.fill")
                    }
                } else {
                    Text("Open Settings, then Connectors, to authorize \(provider.displayName) for this account. Skills opened directly from Gateway Details do not currently have account context for an automatic connector deep link.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .openGatewayRecovery:
            NavigationLink {
                SharedOpenClawGatewayHomeView(gateway: gateway)
            } label: {
                Label("Open Machine Setup", systemImage: "server.rack")
            }
            Text("Finish pairing or recovery for the private machine that can run this skill. This keeps you on the active machine.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .manualGatewaySetup:
            NavigationLink {
                SharedOpenClawGatewayHomeView(gateway: gateway)
            } label: {
                Label("Open Machine Setup", systemImage: "doc.badge.gearshape")
            }
            Text("Apply this config on the machine where the skill runs, then reconnect through setup or chat so Rem can re-check requirements.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case nil:
            Text("No setup action is available yet.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installerStatusView: some View {
        switch installState {
        case .idle:
            EmptyView()
        case .installing:
            Label("Installing on machine...", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .succeeded(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func canInstallOnGateway(installId: String?, installerKind: String?) -> Bool {
        do {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: context.skillInstallKey,
                installId: installId ?? "",
                installerKind: installerKind
            )
        } catch {
            return false
        }
        guard gateway.connectionState.isConnected, gateway.operatorReady else { return false }
        if case .installing = installState { return false }
        if case .succeeded = installState { return false }
        return true
    }

    private func installerFooterText(installId: String?, installerKind: String?) -> String {
        do {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: context.skillInstallKey,
                installId: installId ?? "",
                installerKind: installerKind
            )
        } catch {
            return error.localizedDescription
        }
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            return "Connect to a ready machine before installing this tool."
        }
        if case .succeeded = installState {
            return "Requirements were re-checked after the installer finished."
        }
        return "If OpenClaw blocks the installer, Rem will show the failure here instead of streaming terminal output into chat."
    }

    private func installOnGateway(installId: String?, installerKind: String?) async {
        do {
            try SkillInstallRequestPolicy.validateManifestInstaller(
                name: context.skillInstallKey,
                installId: installId ?? "",
                installerKind: installerKind
            )
        } catch {
            installState = .failed(error.localizedDescription)
            return
        }
        guard canInstallOnGateway(installId: installId, installerKind: installerKind), let installId else { return }
        installState = .installing

        do {
            let data = try JSONEncoder().encode(SkillsInstallManifestParams(
                name: context.skillInstallKey,
                installId: installId
            ))
            let json = String(data: data, encoding: .utf8)
            let response = try await gateway.skillsRequest(
                method: "skills.install",
                paramsJSON: json,
                timeoutSeconds: 120
            )
            let result = try? JSONDecoder().decode(SkillsInstallManifestResult.self, from: response)
            installState = .succeeded(result?.message ?? "Installer finished. Re-checking requirements...")
            await onRequirementsChanged()
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }
}

private enum GatewaySkillInstallState: Equatable {
    case idle
    case installing
    case succeeded(String)
    case failed(String)
}

private struct SkillsInstallManifestParams: Codable {
    let name: String
    let installId: String
    let timeoutMs: Int

    init(name: String, installId: String, timeoutMs: Int = 120_000) {
        self.name = name
        self.installId = installId
        self.timeoutMs = timeoutMs
    }
}

private struct SkillsInstallManifestResult: Codable {
    let message: String?
}

#if DEBUG
/// Deterministic visual QA surface for provider-backed skill requirements.
///
/// Launch with `--rem-skill-provider-requirements-fixture` to inspect the
/// installed-skill detail state without live OAuth credentials or a gateway.
struct SharedSkillProviderRequirementsFixtureView: View {
    var skill: SkillEntry = .fixtureProviderRequirement
    @State private var gateway = SharedSkillProviderRequirementsFixtureGateway()

    var body: some View {
        SharedSkillDetailSheet(
            skill: skill,
            gateway: gateway,
            connectorDestination: { provider in
                AnyView(Self.connectorPlaceholder(for: provider))
            },
            onRequirementsChanged: {}
        )
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
    }

    private static func connectorPlaceholder(for provider: SkillConnectorProvider) -> some View {
        VStack(spacing: 12) {
            Image(systemName: provider.connectorSystemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.blue)
            Text("\(provider.displayName) Connector")
                .font(DesignTokens.Typography.title3)
            Text("Fixture destination")
                .font(DesignTokens.Typography.caption1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(provider.displayName)
    }
}

#Preview("Skill Detail — Connector Setup") {
    SharedSkillProviderRequirementsFixtureView()
}

#Preview("Skill Detail — Requires macOS") {
    SharedSkillProviderRequirementsFixtureView(skill: .fixtureMacOSRequirement)
}

@MainActor
@Observable
private final class SharedSkillProviderRequirementsFixtureGateway: GatewaySessionProviding {
    var connectionState: GatewayConnectionState = .connected
    var sessionHealth = GatewaySessionHealthSnapshot.compose(
        operatorSessionState: .connected,
        nodeSessionState: .connected,
        gatewayProcessState: .running,
        manualRecoveryState: .none,
        detail: nil
    )
    var gatewayHostDisplay: String? = "fixture.rem.local"
    var operatorReady = true
    var skillsSnapshotVersion = 0
    var isAutoRePairInProgress = false
    var isConfigured = true
    var isAuthenticated = true
    var linkedDevices: [LinkedDevice] = []
    var isLoadingLinkedDevices = false
    var pendingDevices: [PendingDevice] = []
    var isLoadingPendingDevices = false
    var pendingDeviceError: String?
    var storedGatewayURL: String? = "https://fixture.rem.local"
    var storedGatewayToken: String? = "fixture-token"
    var activeLocalGatewayURL: String?
    var activeLocalGatewayToken: String?

    func fetchLinkedDevices() {}
    func unlinkDevice(_ device: LinkedDevice) {}
    func fetchPendingDevices() async {}
    func approveDevice(_ device: PendingDevice) {}
    func declineDevice(_ device: PendingDevice) {}
    func reconnect() {}
    func connectIfConfigured() {}
    func clearConfiguration() {}
    func configure(gatewayURL: String, gatewayToken: String) {}
    func configure(gatewayConfig: GatewayConfig) {}
    func signOut() {}
    func resetPairing() {}

    func skillsRequest(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data {
        throw URLError(.unsupportedURL)
    }
}

private extension SkillEntry {
    static let fixtureProviderRequirement = SkillEntry(
        skillKey: "github-review",
        name: "GitHub Review",
        description: "Summarize pull requests, inspect CI, and draft review notes.",
        emoji: nil,
        homepage: nil,
        disabled: nil,
        eligible: false,
        missing: SkillMissing(
            bins: nil,
            anyBins: nil,
            env: ["GITHUB_TOKEN"],
            config: nil,
            os: nil
        ),
        source: "openclaw",
        bundled: false,
        filePath: nil,
        requirements: SkillRequirements(
            bins: nil,
            anyBins: nil,
            env: ["GITHUB_TOKEN"],
            config: nil,
            os: nil
        ),
        configChecks: [],
        install: [],
        platforms: ["darwin", "linux"]
    )

    static let fixtureMacOSRequirement = SkillEntry(
        skillKey: "mac-screen-context",
        name: "Mac Screen Context",
        description: "Read approved Mac screen context for local computer tasks.",
        emoji: nil,
        homepage: nil,
        disabled: nil,
        eligible: false,
        missing: SkillMissing(
            bins: ["osascript"],
            anyBins: nil,
            env: nil,
            config: nil,
            os: nil
        ),
        source: "openclaw",
        bundled: false,
        filePath: nil,
        requirements: SkillRequirements(
            bins: ["osascript"],
            anyBins: nil,
            env: nil,
            config: nil,
            os: nil
        ),
        configChecks: [],
        install: [],
        platforms: ["darwin"]
    )
}
#endif
