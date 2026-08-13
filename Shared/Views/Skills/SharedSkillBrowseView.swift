import SwiftUI

// MARK: - Shared Skill Browse View (ClawHub)
//
// Mirrors upstream browse+install pattern from:
//   - openclaw/ui/src/ui/controllers/skills.ts   (searchClawHub, loadClawHubDetail, installFromClawHub)
//   - openclaw/ui/src/ui/views/skills.ts         (renderClawHubResults, renderClawHubDetailDialog)
//
// The upstream Mac app (openclaw/apps/macos/Sources/OpenClaw/SkillsSettings.swift) does
// NOT ship a ClawHub browser — it only mirrors the local-installed status surface
// which we already have in SharedSkillsSettingsView. The web control UI is the
// correct upstream reference for this surface.
//
// Out of scope for this PR (tracked separately):
//   - Uninstall: upstream has no skills.uninstall RPC; we do not invent one.
//   - OAuth filtering: upstream ClawHub response has no structured requiresOAuth
//     signal, so we do not filter or disable OAuth-backed skills. Attempted
//     install of an OAuth-needing skill will fail at the gateway and the error
//     is surfaced verbatim. OAuth wiring is #277's responsibility.

/// Generic over `GatewaySessionProviding` so it works with both iOS and Mac
/// session managers. No platform forks — a single implementation.
struct SharedSkillBrowseView<Gateway: GatewaySessionProviding>: View {
    let gateway: Gateway

    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    /// The query whose results are currently in `results`. Used to race-guard
    /// late responses (mirrors upstream's `if (query !== state.clawhubSearchQuery) return`).
    @State private var lastIssuedQuery: String = ""
    @State private var results: [ClawHubSearchResult]? = nil
    @State private var searchFailure: ClawHubSearchFailure? = nil
    @State private var isSearching = false

    @State private var detailSlug: String? = nil
    @State private var detail: ClawHubSkillDetailResponse? = nil
    @State private var detailError: String? = nil
    @State private var isLoadingDetail = false

    /// Per-slug lifecycle state. Missing key == .notInstalled.
    @State private var installStates: [String: SkillInstallState] = [:]

    /// Top-level success/failure banner for the most recent install attempt.
    /// Mirrors upstream's `clawhubInstallMessage`.
    @State private var installBanner: InstallBanner? = nil

    private struct InstallBanner: Equatable {
        let kind: Kind
        let text: String
        enum Kind { case success, error }
    }

    var body: some View {
        Group {
            #if os(macOS)
            Form { browseSections }
                .formStyle(.grouped)
                .macSettingsCenteredColumn()
            #else
            List { browseSections }
                .listStyle(.insetGrouped)
            #endif
        }
        .accessibilityIdentifier("shared-skill-browse")
        .sheet(item: detailBinding) { item in
            SharedClawHubDetailSheet(
                slug: item.slug,
                detail: detail,
                error: detailError,
                isLoading: isLoadingDetail,
                installState: installStates[item.slug] ?? .notInstalled,
                onInstall: { Task { await install(slug: item.slug) } },
                onDismiss: { closeDetail() }
            )
        }
    }

    @ViewBuilder
    private var browseSections: some View {
        Section {
            searchField
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching ClawHub...")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
            if let banner = installBanner {
                installBannerView(banner)
            }
            if let searchFailure {
                searchFailureView(searchFailure)
            }
        } footer: {
            Text("Search and install skills from ClawHub, the OpenClaw skill registry.")
        }

        if let results {
            if results.isEmpty {
                Section {
                    Text("No skills found on ClawHub.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(results) { result in
                        SharedClawHubResultRow(
                            result: result,
                            installState: installStates[result.slug] ?? .notInstalled,
                            onTap: { openDetail(slug: result.slug) },
                            onReview: { openDetail(slug: result.slug) }
                        )
                    }
                }
            }
        } else if !isSearching && query.isEmpty && searchFailure == nil {
            Section {
                ContentUnavailableView(
                    "Search ClawHub",
                    systemImage: "magnifyingglass",
                    description: Text("Type a skill name to browse installable capabilities.")
                )
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search ClawHub skills", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { Task { await runSearch() } }
                .onChange(of: query) { _, newValue in
                    // Clear stale results as soon as user types, matching upstream
                    // setClawHubSearchQuery semantics. Don't auto-search on every
                    // keystroke to avoid hammering the gateway; user submits to search.
                    if newValue.isEmpty {
                        results = nil
                        searchFailure = nil
                        lastIssuedQuery = ""
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = nil
                    searchFailure = nil
                    lastIssuedQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button("Search") { Task { await runSearch() } }
                .buttonStyle(.borderless)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
        }
    }

    private func searchFailureView(_ failure: ClawHubSearchFailure) -> some View {
        ClawHubSearchFailureNotice(
            failure: failure,
            actionTitle: nil,
            action: nil
        )
    }

    @ViewBuilder
    private func installBannerView(_ banner: InstallBanner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(banner.kind == .success ? .green : .orange)
            Text(banner.text)
                .font(.footnote)
            Spacer()
            Button {
                installBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Detail sheet binding
    //
    // SwiftUI's `.sheet(item:)` requires an `Identifiable` value, so we wrap
    // the slug in a small identifiable struct. Upstream's web UI uses a dialog
    // keyed by `clawhubDetailSlug: string` — same idea.

    private var detailBinding: Binding<DetailSlugItem?> {
        Binding(
            get: { detailSlug.map(DetailSlugItem.init(slug:)) },
            set: { if $0 == nil { closeDetail() } }
        )
    }

    // MARK: - Actions

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = nil
            searchFailure = nil
            lastIssuedQuery = ""
            return
        }
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            searchFailure = .gatewayNotReady
            return
        }
        isSearching = true
        searchFailure = nil
        results = nil
        lastIssuedQuery = trimmed

        do {
            let data = try JSONEncoder().encode(SkillsSearchParams(query: trimmed, limit: 20))
            let json = String(data: data, encoding: .utf8)
            let res = try await gateway.skillsRequest(
                method: "skills.search",
                paramsJSON: json,
                timeoutSeconds: 20
            )
            // Race guard: only apply if current query still matches.
            guard trimmed == lastIssuedQuery else { return }
            let decoded = try JSONDecoder().decode(ClawHubSearchResponse.self, from: res)
            results = decoded.results
        } catch {
            guard trimmed == lastIssuedQuery else { return }
            searchFailure = .from(errorDescription: error.localizedDescription)
        }
        if trimmed == lastIssuedQuery {
            isSearching = false
        }
    }

    private func openDetail(slug: String) {
        detailSlug = slug
        detail = nil
        detailError = nil
        isLoadingDetail = true
        Task { await loadDetail(slug: slug) }
    }

    private func closeDetail() {
        detailSlug = nil
        detail = nil
        detailError = nil
        isLoadingDetail = false
    }

    private func loadDetail(slug: String) async {
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            detailError = "Not connected to machine"
            isLoadingDetail = false
            return
        }
        do {
            let data = try JSONEncoder().encode(SkillsDetailParams(slug: slug))
            let json = String(data: data, encoding: .utf8)
            let res = try await gateway.skillsRequest(
                method: "skills.detail",
                paramsJSON: json,
                timeoutSeconds: 15
            )
            // Race guard
            guard slug == detailSlug else { return }
            let decoded = try JSONDecoder().decode(ClawHubSkillDetailResponse.self, from: res)
            detail = decoded
        } catch {
            guard slug == detailSlug else { return }
            detailError = error.localizedDescription
        }
        if slug == detailSlug {
            isLoadingDetail = false
        }
    }

    private func install(slug: String) async {
        guard gateway.connectionState.isConnected, gateway.operatorReady else {
            installStates[slug] = .error(message: "Not connected to machine")
            return
        }
        do {
            try SkillInstallRequestPolicy.validateClawHubSlug(slug)
        } catch {
            installStates[slug] = .error(message: error.localizedDescription)
            installBanner = InstallBanner(kind: .error, text: error.localizedDescription)
            return
        }
        installStates[slug] = .installing
        installBanner = nil

        do {
            let data = try JSONEncoder().encode(SkillsInstallClawHubParams(slug: slug))
            let json = String(data: data, encoding: .utf8)
            _ = try await gateway.skillsRequest(
                method: "skills.install",
                paramsJSON: json,
                // ClawHub install downloads an archive and extracts it. Upstream UI
                // uses 120s for generic installs; we match that for safety.
                timeoutSeconds: 120
            )
            installStates[slug] = .installed
            installBanner = InstallBanner(kind: .success, text: "Installed \(slug)")
            // Reconciliation note: we intentionally do NOT call a manual
            // refetch here. The gateway emits a skills-change notification
            // after `skills.install` succeeds; `SharedSkillsSettingsView`'s
            // `.onChange(of: gateway.skillsSnapshotVersion)` triggers a
            // reload when the user switches back to the Installed tab.
            // Upstream invokes `loadSkills(state)` directly (see
            // `openclaw/ui/src/ui/controllers/skills.ts:290`); we rely on
            // the server-push instead so two installs in flight don't
            // race a manual fetch.
        } catch {
            let message = error.localizedDescription
            installStates[slug] = .error(message: message)
            installBanner = InstallBanner(kind: .error, text: message)
        }
    }
}

// MARK: - Result Row

private struct SharedClawHubResultRow: View {
    let result: ClawHubSearchResult
    let installState: SkillInstallState
    let onTap: () -> Void
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    SkillIconBadge(spec: result.iconSpec, size: 36, cornerRadius: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(result.displayName)
                                .font(.callout)
                                .foregroundColor(.primary)
                            if let version = result.version {
                                Text("v\(version)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let summary = result.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        } else {
                            Text(result.slug)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            installControl
        }
        .accessibilityIdentifier("clawhub-result-\(result.slug)")
    }

    @ViewBuilder
    private var installControl: some View {
        switch installState {
        case .notInstalled, .error:
            Button("Review", action: onReview)
                .remSettingsCTA(.primary, size: .compact)
        case .installing:
            ProgressView()
                .controlSize(.small)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .font(.callout)
                .accessibilityLabel("Installed")
        }
    }
}

// MARK: - Detail Sheet

private struct SharedClawHubDetailSheet: View {
    let slug: String
    let detail: ClawHubSkillDetailResponse?
    let error: String?
    let isLoading: Bool
    let installState: SkillInstallState
    let onInstall: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        #if os(macOS)
        macContainer
        #else
        NavigationStack {
            ScrollView {
                content
                    .padding()
            }
                .navigationTitle(detail?.skill?.displayName ?? slug)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDismiss() }
                    }
                }
        }
        #endif
    }

    #if os(macOS)
    private var macContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(detail?.skill?.displayName ?? slug)
                    .font(.title3.bold())
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView { content.padding() }
        }
        .frame(width: 440, height: 520)
    }
    #endif

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading details...")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    Text("Slug: \(slug)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let detail, let skill = detail.skill {
                if let summary = skill.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                }

                if let owner = detail.owner, let display = owner.displayName, !display.isEmpty {
                    HStack(spacing: 4) {
                        Text("By \(display)")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                        if let handle = owner.handle, !handle.isEmpty {
                            Text("(@\(handle))")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }

                if let latest = detail.latestVersion {
                    Text("Latest: v\(latest.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let changelog = latest.changelog, !changelog.isEmpty {
                        Divider()
                        Text(changelog)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                if let platforms = detail.metadata?.os, !platforms.isEmpty {
                    Text("Platforms: \(platforms.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                installDisclosure(for: detail)
                installSection
            } else {
                Text("Skill not found.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func installDisclosure(for detail: ClawHubSkillDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review before installing", systemImage: "shield.lefthalf.filled")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                disclosureRow(
                    title: "Source",
                    value: provenanceDescription(for: detail)
                )
                disclosureRow(
                    title: "Platforms",
                    value: platformRequirementsDescription(for: detail)
                )
                disclosureRow(
                    title: "Tools",
                    value: toolRequirementsDescription()
                )
                disclosureRow(
                    title: "Credentials",
                    value: credentialRequirementsDescription(for: detail)
                )
                disclosureRow(
                    title: "Capability impact",
                    value: capabilityImpactDescription(for: detail)
                )
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func disclosureRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func provenanceDescription(for detail: ClawHubSkillDetailResponse) -> String {
        var parts = ["ClawHub"]
        if let owner = detail.owner?.displayName, !owner.isEmpty {
            parts.append("publisher: \(owner)")
        } else if let handle = detail.owner?.handle, !handle.isEmpty {
            parts.append("publisher: @\(handle)")
        }
        if let latest = detail.latestVersion?.version, !latest.isEmpty {
            parts.append("version \(latest)")
        }
        return parts.joined(separator: " · ")
    }

    private func platformRequirementsDescription(for detail: ClawHubSkillDetailResponse) -> String {
        if let platforms = detail.metadata?.os, !platforms.isEmpty {
            return "Runs on \(platforms.map(SkillEntry.platformDisplayLabel).joined(separator: ", "))"
        }
        return "This ClawHub listing does not declare platform requirements."
    }

    private func toolRequirementsDescription() -> String {
        "This ClawHub listing does not declare binary requirements. After install, Rem checks the active machine and surfaces missing tools as Connector requirements when possible."
    }

    private func credentialRequirementsDescription(for detail: ClawHubSkillDetailResponse) -> String {
        var values = [
            "Installing does not connect accounts.",
            "If this skill needs sign-in or a token, Rem will show that as a Connector requirement."
        ]
        if let systems = detail.metadata?.systems, !systems.isEmpty {
            values.append("Declares system context entries: \(systems.joined(separator: ", ")).")
        }
        return values.joined(separator: " ")
    }

    private func capabilityImpactDescription(for detail: ClawHubSkillDetailResponse) -> String {
        let text = [
            detail.skill?.slug,
            detail.skill?.displayName,
            detail.skill?.summary
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if text.contains("github") || text.contains("git") || text.contains("pull request") || text.contains("issue") {
            return "Enables GitHub-related actions such as reading repository data or helping with issues and pull requests when the active machine has the required tool and auth."
        }
        if text.contains("calendar") || text.contains("schedule") || text.contains("agenda") {
            return "Enables scheduling-related actions when the matching Calendar Connector or device permission is available."
        }
        if text.contains("mail") || text.contains("gmail") || text.contains("email") {
            return "Enables email-related actions when the matching account Connector is authorized."
        }
        if text.contains("browser") || text.contains("web") || text.contains("url") {
            return "May enable browser or web actions. Rem should ask before high-risk browser actions."
        }
        if text.contains("file") || text.contains("shell") || text.contains("terminal") || text.contains("clipboard") {
            return "May expand local computer powers. Use this only on a private machine and device you trust."
        }
        return "Expands what the assistant can do on this machine. Review the description and install only from sources you trust."
    }

    @ViewBuilder
    private var installSection: some View {
        switch installState {
        case .notInstalled:
            Button(action: onInstall) {
                Text("Install \(detail?.skill?.displayName ?? slug)")
            }
            .remSettingsCTA(.primary)
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
                Button("Try Again", action: onInstall)
                    .remSettingsCTA(.primary, size: .compact)
            }
        }
    }
}

#if DEBUG
struct SharedClawHubUnavailableFixtureView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Text("github")
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("Search") {}
                            .buttonStyle(.borderless)
                    }

                    ClawHubSearchFailureNotice(
                        failure: .unsupportedGateway,
                        actionTitle: nil,
                        action: nil
                    )
                } footer: {
                    Text("Search and install skills from ClawHub, the OpenClaw skill registry.")
                }
            }
            .background(DesignTokens.Color.backgroundPrimary)
            .navigationTitle("Skills")
        }
    }
}

struct SharedClawHubReviewFixtureView: View {
    var body: some View {
        SharedClawHubDetailSheet(
            slug: "github",
            detail: .fixtureGitHub,
            error: nil,
            isLoading: false,
            installState: .notInstalled,
            onInstall: {},
            onDismiss: {}
        )
    }
}

private extension ClawHubSkillDetailResponse {
    static let fixtureGitHub = ClawHubSkillDetailResponse(
        skill: Skill(
            slug: "github",
            displayName: "GitHub",
            summary: "GitHub operations via gh CLI: issues, pull requests, CI runs, and repository queries.",
            createdAt: nil,
            updatedAt: nil
        ),
        latestVersion: LatestVersion(
            version: "1.4.0",
            createdAt: nil,
            changelog: "Adds focused helpers for pull request review, issue triage, and CI status checks."
        ),
        metadata: Metadata(
            os: ["darwin", "linux"],
            systems: ["gh"]
        ),
        owner: Owner(
            handle: "openclaw",
            displayName: "OpenClaw",
            image: nil
        )
    )
}
#endif

private struct ClawHubSearchFailureNotice: View {
    let failure: ClawHubSearchFailure
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: failure == .unsupportedGateway ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .remSettingsCTA(.primary, size: .compact)
                        .accessibilityIdentifier("clawhub-gateway-options-action")
                }
            }
        }
        .accessibilityIdentifier("clawhub-search-unavailable")
    }
}

// MARK: - File-scope Codable params
//
// Swift does not allow declaring types inside a generic function body, so these
// RPC param structs live at file scope (matches the existing pattern in
// SharedSkillsSettingsView.swift where SkillToggleParams is also file-scope).

private struct SkillsSearchParams: Codable {
    let query: String
    let limit: Int
}

private struct SkillsDetailParams: Codable {
    let slug: String
}

/// ClawHub-mode install params. Gateway dispatches on `source == "clawhub"`.
/// See openclaw/src/gateway/server-methods/skills.ts (skills.install handler).
private struct SkillsInstallClawHubParams: Codable {
    let source: String
    let slug: String
    init(slug: String) {
        self.source = "clawhub"
        self.slug = slug
    }
}

/// Identifiable wrapper for `.sheet(item:)` presentation. SwiftUI requires an
/// Identifiable payload; we key the sheet by the ClawHub slug itself.
private struct DetailSlugItem: Identifiable, Equatable {
    let slug: String
    var id: String { slug }
}

#if DEBUG
#Preview("Skill Browse — Empty Search") {
    NavigationStack {
        SharedSkillBrowseView(
            gateway: PreviewGatewaySession(scenario: .cloudConnected)
        )
        .navigationTitle("Browse")
    }
}

#Preview("Skill Browse — Gateway Unreachable") {
    NavigationStack {
        SharedSkillBrowseView(
            gateway: PreviewGatewaySession(scenario: .cloudUnreachable)
        )
        .navigationTitle("Browse")
    }
}
#endif
