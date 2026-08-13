import Foundation

// MARK: - Skill Models (shared across iOS and macOS)

struct SkillsStatusResponse: Codable {
    let skills: [SkillEntry]
    let workspaceDir: String?
    let managedSkillsDir: String?

    /// Detected platform of the gateway that returned this response.
    var gatewayPlatform: GatewayPlatform {
        GatewayPlatform.from(workspaceDir: workspaceDir)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.skills = try container.decode([SkillEntry].self, forKey: .skills)
        self.workspaceDir = try container.decodeIfPresent(String.self, forKey: .workspaceDir)
        self.managedSkillsDir = try container.decodeIfPresent(String.self, forKey: .managedSkillsDir)
    }

    private enum CodingKeys: String, CodingKey {
        case skills, workspaceDir, managedSkillsDir
    }
}

/// Detected OS platform of the gateway, inferred from workspace directory paths.
enum GatewayPlatform: String {
    case macOS, linux, unknown

    static func from(workspaceDir: String?) -> GatewayPlatform {
        guard let dir = workspaceDir, !dir.isEmpty else { return .unknown }
        if dir.hasPrefix("/Users/") || dir.hasPrefix("/Applications/") { return .macOS }
        let linuxPrefixes = ["/app/", "/root/", "/home/", "/data/", "/opt/"]
        if linuxPrefixes.contains(where: dir.hasPrefix) { return .linux }
        // Generic Unix path — most Fly.io gateways run Linux
        if dir.hasPrefix("/") { return .linux }
        return .unknown
    }

    var displayLabel: String {
        switch self {
        case .linux: "Linux"
        case .macOS: "macOS"
        case .unknown: "Unknown OS"
        }
    }

    var sfSymbol: String {
        switch self {
        case .linux: "server.rack"
        case .macOS: "desktopcomputer"
        case .unknown: "questionmark.circle"
        }
    }
}

struct SkillMissing: Codable, Sendable {
    let bins: [String]?
    let anyBins: [String]?
    let env: [String]?
    let config: [String]?
    let os: [String]?

    var hasAnyRequirement: Bool {
        [bins, anyBins, env, config, os].contains { ($0 ?? []).isEmpty == false }
    }
}

struct SkillRequirements: Codable, Sendable {
    let bins: [String]?
    let anyBins: [String]?
    let env: [String]?
    let config: [String]?
    let os: [String]?
}

struct SkillConfigCheck: Codable, Sendable {
    let label: String?
    let status: String?
    let message: String?
}

struct SkillInstallStep: Codable, Sendable {
    let id: String?
    let kind: String?
    let label: String?
    let bins: [String]?
}

enum SkillInstallRequestValidationError: LocalizedError, Equatable, Sendable {
    case emptySkillName
    case emptyInstallId
    case unsafeInstallId(String)
    case unsupportedManifestInstallerKind(String?)
    case emptyClawHubSlug
    case unsafeClawHubSlug(String)

    var errorDescription: String? {
        switch self {
        case .emptySkillName:
            return "This installer is missing the skill name."
        case .emptyInstallId:
            return "This installer is missing a step id."
        case .unsafeInstallId:
            return "This installer step id is not safe to run."
        case .unsupportedManifestInstallerKind(let kind):
            if let kind, !kind.isEmpty {
                return "Rem cannot run installer kind \(kind)."
            }
            return "This installer does not declare a supported kind."
        case .emptyClawHubSlug:
            return "This ClawHub install is missing a skill id."
        case .unsafeClawHubSlug:
            return "This ClawHub skill id is not safe to install."
        }
    }
}

enum SkillInstallRequestPolicy {
    private static let supportedManifestInstallerKinds: Set<String> = [
        "brew",
        "node",
        "uv",
        "go",
        "download"
    ]

    private static let installIdPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#
    private static let slugPattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#

    static func validateManifestInstaller(name: String, installId: String, installerKind: String?) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillInstallRequestValidationError.emptySkillName
        }
        guard !installId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillInstallRequestValidationError.emptyInstallId
        }
        guard installId.range(of: installIdPattern, options: .regularExpression) != nil else {
            throw SkillInstallRequestValidationError.unsafeInstallId(installId)
        }
        guard
            let normalizedKind = installerKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            supportedManifestInstallerKinds.contains(normalizedKind)
        else {
            throw SkillInstallRequestValidationError.unsupportedManifestInstallerKind(installerKind)
        }
    }

    static func validateClawHubSlug(_ slug: String) throws {
        let normalizedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSlug.isEmpty else {
            throw SkillInstallRequestValidationError.emptyClawHubSlug
        }
        guard normalizedSlug.range(of: slugPattern, options: .regularExpression) != nil else {
            throw SkillInstallRequestValidationError.unsafeClawHubSlug(slug)
        }
    }
}

/// The kind of setup a not-yet-ready capability needs. Drives both the action verb
/// (`SkillEntry.setupActionLabel`) and the setup-chat prompt, so the two can't drift.
enum SkillSetupKind: Equatable, Sendable {
    /// Needs an account authorized through a known Connector provider.
    case connectAccount([SkillConnectorProvider])
    /// Needs credential values (env vars / tokens) the user has to supply.
    case credential([String])
    /// Needs a tool/binary present on the runtime.
    case installTool
}

struct SkillRequirementDisplayRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case binary
        case auth
        case config
        case platform
    }

    enum Status: Equatable, Sendable {
        case blocked
        case actionAvailable
    }

    enum ActionKind: Equatable, Sendable {
        case installTool(installerID: String?, installerKind: String?, label: String)
        case openConnector(SkillConnectorProvider)
        case openGatewayRecovery
        case manualGatewaySetup

        var label: String {
            switch self {
            case .installTool(_, _, let label):
                return label
            case .openConnector(let provider):
                return "Open \(provider.displayName) Connector"
            case .openGatewayRecovery:
                return "Open Machine Setup"
            case .manualGatewaySetup:
                return "Manual setup"
            }
        }
    }

    let id: String
    let kind: Kind
    let status: Status
    let title: String
    let detail: String
    let actionKind: ActionKind?

    init(
        id: String,
        kind: Kind,
        status: Status,
        title: String,
        detail: String,
        actionKind: ActionKind? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.detail = detail
        self.actionKind = actionKind
    }

    var systemImage: String {
        switch kind {
        case .binary:
            return "terminal.fill"
        case .auth:
            return "key.fill"
        case .config:
            return "doc.badge.gearshape"
        case .platform:
            return "desktopcomputer"
        }
    }
}

enum SkillConnectorProvider: String, CaseIterable, Equatable, Sendable {
    case github
    case gmail
    case google
    case notion

    var displayName: String {
        switch self {
        case .github:
            return "GitHub"
        case .gmail:
            return "Gmail"
        case .google:
            return "Google Workspace"
        case .notion:
            return "Notion"
        }
    }

    var connectorSystemImage: String {
        switch self {
        case .github:
            return "chevron.left.forwardslash.chevron.right"
        case .gmail:
            return "envelope.fill"
        case .google:
            return "g.circle"
        case .notion:
            return "doc.text.fill"
        }
    }

    var skillHandoffDetail: String {
        switch self {
        case .github:
            return "Authorize GitHub in Connectors for this Rem account. The active machine can reuse that account authorization when GitHub skills run; Rem does not need a raw GitHub token pasted into skill setup."
        case .gmail:
            return "Authorize Gmail in Connectors for this Rem account. The active machine can reuse that account authorization when Gmail skills run; Rem does not need a raw Gmail token pasted into skill setup."
        case .google:
            return "Authorize Google Workspace in Connectors once for this Rem account. The active machine can reuse that umbrella authorization for Google Workspace skills such as Drive, Docs, Slides, and Calendar when scopes are enabled."
        case .notion:
            return "Authorize Notion in Connectors for this Rem account and workspace. The active machine can reuse that account authorization when Notion skills run; Rem does not need a raw Notion token pasted into skill setup."
        }
    }

    func matchesOAuthProviderId(_ providerId: String) -> Bool {
        switch self {
        case .github:
            return providerId == "github"
        case .gmail:
            return providerId == "gmail"
        case .google:
            return providerId == "google" || providerId == "google-calendar" || providerId == "google-drive"
        case .notion:
            return providerId == "notion"
        }
    }

    static func mappedProvider(forEnvironmentKey key: String) -> SkillConnectorProvider? {
        let normalized = key.uppercased()
        let explicitMappings: [(provider: SkillConnectorProvider, keys: Set<String>)] = [
            (.github, ["GH_TOKEN", "GITHUB_TOKEN", "GITHUB_API_TOKEN", "GITHUB_OAUTH_TOKEN"]),
            (.gmail, ["GMAIL_ACCESS_TOKEN", "GMAIL_OAUTH_TOKEN"]),
            (.google, ["GOOGLE_ACCESS_TOKEN", "GOOGLE_OAUTH_TOKEN"]),
            (.notion, ["NOTION_TOKEN", "NOTION_ACCESS_TOKEN", "NOTION_OAUTH_TOKEN"])
        ]

        return explicitMappings.first { _, keys in
            keys.contains(normalized)
        }?.provider
    }
}

extension SkillRequirementDisplayRow {
    var connectorProvider: SkillConnectorProvider? {
        guard case .openConnector(let provider) = actionKind else { return nil }
        return provider
    }
}

struct SkillEntry: Codable, Identifiable, Sendable {
    var id: String { skillKey }
    let skillKey: String
    let name: String?
    let description: String?
    let emoji: String?
    let homepage: String?
    let disabled: Bool?
    let eligible: Bool?
    let missing: SkillMissing?
    let source: String?
    let bundled: Bool?
    let filePath: String?
    let requirements: SkillRequirements?
    let configChecks: [SkillConfigCheck]?
    let install: [SkillInstallStep]?
    /// Platform list from the skill manifest (e.g. ["darwin", "linux"]).
    let platforms: [String]?

    var isEnabled: Bool { isEligible && !(disabled ?? false) }
    var isEligible: Bool { eligible ?? true }
    var iconSpec: SkillIconSpec {
        SkillIconSpec.resolve(
            emoji: emoji,
            key: skillKey,
            name: name,
            summary: description
        )
    }

    var missingShortLabel: String {
        if let platformMismatchLabel {
            return platformMismatchLabel
        }
        guard let missing else { return "Missing requirements" }
        if let bins = missing.bins, !bins.isEmpty {
            return SkillEntry.missingBinaryLabel(for: bins)
        }
        if let anyBins = missing.anyBins, !anyBins.isEmpty {
            return SkillEntry.missingAnyBinaryLabel(for: anyBins)
        }
        if let env = missing.env, !env.isEmpty {
            return SkillEntry.missingEnvironmentLabel(for: env)
        }
        if let config = missing.config, !config.isEmpty {
            return SkillEntry.missingConfigLabel(for: config)
        }
        if let os = missing.os, !os.isEmpty {
            return SkillEntry.missingOSLabel(for: os)
        }
        return "Missing requirements"
    }

    /// What this capability actually needs before it can run. The structured form of
    /// `setupActionLabel` — the setup chat prompt has to branch on the *kind* of setup
    /// (authorize an account vs. paste a token vs. install a binary), and branching on
    /// the display verb would mean parsing "Connect"/"Install" back out of UI copy.
    /// Precedence matches `setupActionLabel`'s original order, so labels are unchanged.
    var setupKind: SkillSetupKind {
        let providers = connectorRequirementProviders
        if !providers.isEmpty { return .connectAccount(providers) }
        if let env = missing?.env, !env.isEmpty { return .credential(env) }
        return .installTool
    }

    /// App-Store-style trailing action verb for a capability that is not yet
    /// ready. "Connect" when it needs an account / credential (a Connector
    /// provider or a missing env var/token), "Install" when it only needs a
    /// tool/binary on the machine. Used by the capability list row's trailing
    /// button, which opens chat with a ready connect/install prompt.
    var setupActionLabel: String {
        switch setupKind {
        case .connectAccount, .credential: "Connect"
        case .installTool: "Install"
        }
    }

    var displayableConfigChecks: [SkillConfigCheck] {
        (configChecks ?? []).filter { check in
            let label = check.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = check.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !label.isEmpty || !message.isEmpty
        }
    }

    // Well-known macOS-only binaries
    private static let macOnlyBins: Set<String> = [
        "osascript", "open", "defaults", "pbcopy", "pbpaste",
        "screencapture", "say", "afplay", "mdls", "mdfind",
        "caffeinate", "networksetup", "launchctl"
    ]

    /// Whether missing binaries suggest a platform mismatch (macOS skill on Linux gateway).
    var hasPlatformMismatch: Bool {
        guard !isEligible else { return false }
        if let missingOS = missing?.os, !missingOS.isEmpty {
            return true
        }
        guard let missingBins = missing?.bins, !missingBins.isEmpty else { return false }
        return missingBins.contains { SkillEntry.macOnlyBins.contains($0) }
    }

    var platformMismatchLabel: String? {
        guard hasPlatformMismatch else { return nil }
        if let missingOS = missing?.os, !missingOS.isEmpty {
            return SkillEntry.missingOSLabel(for: missingOS)
        }
        return "Requires macOS"
    }

    func installLabel(for bin: String) -> String? {
        install?.first { ($0.bins ?? []).contains(bin) }?.label
    }

    func installStep(for bin: String) -> SkillInstallStep? {
        install?.first { ($0.bins ?? []).contains(bin) }
    }

    var requirementDisplayRows: [SkillRequirementDisplayRow] {
        guard let missing, missing.hasAnyRequirement else { return [] }

        var rows: [SkillRequirementDisplayRow] = []

        if let missingOS = missing.os, !missingOS.isEmpty {
            let platforms = missingOS.map(Self.platformLabel).joined(separator: ", ")
            rows.append(
                SkillRequirementDisplayRow(
                    id: "platform-\(missingOS.joined(separator: "-"))",
                    kind: .platform,
                    status: .blocked,
                    title: "Requires \(platforms)",
                    detail: "This skill is not available on the active machine yet.",
                    actionKind: nil
                )
            )
        } else if hasPlatformMismatch {
            rows.append(
                SkillRequirementDisplayRow(
                    id: "platform-mac",
                    kind: .platform,
                    status: .blocked,
                    title: "Requires macOS",
                    detail: "This skill needs Mac-only tools and is not available on the active cloud machine yet.",
                    actionKind: nil
                )
            )
        }

        if let bins = missing.bins, !bins.isEmpty {
            rows.append(contentsOf: bins.map { bin in
                let installStep = installStep(for: bin)
                let installLabel = installStep?.label
                return SkillRequirementDisplayRow(
                    id: "bin-\(bin)",
                    kind: .binary,
                    status: installLabel == nil ? .blocked : .actionAvailable,
                    title: "\(bin) is not installed",
                    detail: installLabel ?? "Install this tool on the active machine, then reconnect.",
                    actionKind: installLabel.map {
                        .installTool(
                            installerID: installStep?.id,
                            installerKind: installStep?.kind,
                            label: $0
                        )
                    }
                )
            })
        }

        if let anyBins = missing.anyBins, !anyBins.isEmpty {
            let installSteps = anyBins.compactMap { installStep(for: $0) }
            let installLabels = installSteps.compactMap(\.label)
            rows.append(
                SkillRequirementDisplayRow(
                    id: "any-bin-\(anyBins.joined(separator: "-"))",
                    kind: .binary,
                    status: installLabels.isEmpty ? .blocked : .actionAvailable,
                    title: "Install one required tool",
                    detail: installLabels.first ?? "Install one of \(anyBins.joined(separator: ", ")) on the active machine, then reconnect.",
                    actionKind: installLabels.first.map {
                        .installTool(
                            installerID: installSteps.first?.id,
                            installerKind: installSteps.first?.kind,
                            label: $0
                        )
                    }
                )
            )
        }

        if let env = missing.env, !env.isEmpty {
            rows.append(contentsOf: env.map { key in
                let authLike = Self.isAuthLikeEnvironmentKey(key)
                let connectorProvider = SkillConnectorProvider.mappedProvider(forEnvironmentKey: key)
                return SkillRequirementDisplayRow(
                    id: "env-\(key)",
                    kind: authLike ? .auth : .config,
                    status: connectorProvider == nil ? .blocked : .actionAvailable,
                    title: connectorProvider.map { "Connect \($0.displayName)" }
                        ?? (authLike ? "Connect or configure \(key)" : "Set \(key)"),
                    detail: connectorProvider.map { $0.skillRequirementRowDetail }
                        ?? (authLike
                            ? "This looks like an account credential. Use the matching Connector when available, or configure the secret on the active machine outside Rem."
                            : "Set this environment value on the active machine, then reconnect."),
                    actionKind: connectorProvider.map { .openConnector($0) }
                )
            })
        }

        if let config = missing.config, !config.isEmpty {
            rows.append(contentsOf: config.map { path in
                SkillRequirementDisplayRow(
                    id: "config-\(path)",
                    kind: .config,
                    status: .blocked,
                    title: "Configure \(path)",
                    detail: "Create or update this config on the active machine, then reconnect.",
                    actionKind: .manualGatewaySetup
                )
            })
        }

        return rows
    }

    var connectorRequirementProviders: [SkillConnectorProvider] {
        var providers: [SkillConnectorProvider] = []
        for row in requirementDisplayRows {
            guard let provider = row.connectorProvider, !providers.contains(provider) else { continue }
            providers.append(provider)
        }
        return providers
    }

    var connectorRequirementsSummaryTitle: String? {
        let providers = connectorRequirementProviders
        switch providers.count {
        case 0:
            return nil
        case 1:
            return "Needs \(providers[0].displayName) authorization"
        default:
            return "Needs \(providers.count) account authorizations"
        }
    }

    var connectorRequirementsSummaryDetail: String? {
        let providers = connectorRequirementProviders
        guard !providers.isEmpty else { return nil }

        let providerList: String
        switch providers.count {
        case 1:
            providerList = providers[0].displayName
        case 2:
            providerList = "\(providers[0].displayName) and \(providers[1].displayName)"
        default:
            let leading = providers.dropLast().map(\.displayName).joined(separator: ", ")
            providerList = "\(leading), and \(providers.last?.displayName ?? "the required provider")"
        }

        return "Authorize \(providerList) in Connectors for this Rem account. The active machine can reuse that account authorization when the skill runs."
    }

    private static func missingBinaryLabel(for bins: [String]) -> String {
        switch bins.count {
        case 1:
            return "Install \(bins[0])"
        case 2:
            return "Install \(bins[0]) and \(bins[1])"
        default:
            return "Install \(bins[0]) and \(bins.count - 1) more tools"
        }
    }

    private static func missingEnvironmentLabel(for env: [String]) -> String {
        switch env.count {
        case 1:
            return "Set \(env[0])"
        default:
            return "Set \(env.count) environment values"
        }
    }

    private static func missingAnyBinaryLabel(for bins: [String]) -> String {
        switch bins.count {
        case 1:
            return "Install \(bins[0])"
        case 2:
            return "Install \(bins[0]) or \(bins[1])"
        default:
            return "Install one of \(bins[0]) and \(bins.count - 1) more tools"
        }
    }

    private static func missingConfigLabel(for config: [String]) -> String {
        switch config.count {
        case 1:
            return "Configure \(config[0])"
        default:
            return "Configure \(config.count) files"
        }
    }

    private nonisolated static func missingOSLabel(for os: [String]) -> String {
        let labels = os.map(platformLabel)
        switch labels.count {
        case 1:
            return "Requires \(labels[0])"
        case 2:
            return "Requires \(labels[0]) or \(labels[1])"
        default:
            return "Requires \(labels[0]) and \(labels.count - 1) more platforms"
        }
    }

    nonisolated static func platformDisplayLabel(_ value: String) -> String {
        platformLabel(value)
    }

    private nonisolated static func platformLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "darwin", "macos", "macosx":
            return "macOS"
        case "linux":
            return "Linux"
        case "win32", "windows":
            return "Windows"
        default:
            return value
        }
    }

    private nonisolated static func isAuthLikeEnvironmentKey(_ value: String) -> Bool {
        let normalized = value.uppercased()
        return ["TOKEN", "API_KEY", "SECRET", "PASSWORD", "OAUTH", "AUTH", "CREDENTIAL"]
            .contains { normalized.contains($0) }
    }

    static func capabilitiesListSort(_ lhs: SkillEntry, _ rhs: SkillEntry) -> Bool {
        let leftBucket = lhs.capabilitiesSortBucket
        let rightBucket = rhs.capabilitiesSortBucket
        if leftBucket != rightBucket {
            return leftBucket < rightBucket
        }

        let leftName = (lhs.name ?? lhs.skillKey).localizedCaseInsensitiveCompare(rhs.name ?? rhs.skillKey)
        if leftName != .orderedSame {
            return leftName == .orderedAscending
        }

        return lhs.skillKey < rhs.skillKey
    }

    private var capabilitiesSortBucket: Int {
        if isEligible {
            return 0
        }
        if hasPlatformMismatch {
            return 2
        }
        return 1
    }
}

private extension SkillConnectorProvider {
    var skillRequirementRowDetail: String {
        switch self {
        case .github:
            return "Use the GitHub Connector to authorize this skill for this Rem account. The active machine can reuse that authorization when the skill runs."
        case .gmail:
            return "Use the Gmail Connector to authorize this skill for this Rem account. The active machine can reuse that authorization when the skill runs."
        case .google:
            return "Use the Google Workspace Connector to authorize this skill for this Rem account. The active machine can reuse that umbrella authorization when scopes are enabled."
        case .notion:
            return "Use the Notion Connector to authorize this skill for this Rem account and workspace. The active machine can reuse that authorization when the skill runs."
        }
    }
}

enum SkillFilter: String, CaseIterable {
    case standard = "Default"
    case installed = "Installed"
    case notInstalled = "Not installed"
}

// MARK: - ClawHub Browse + Install Models
//
// Mirrors upstream structures from openclaw/ui/src/ui/controllers/skills.ts
// (ClawHubSearchResult, ClawHubSkillDetail) and openclaw/src/infra/clawhub.ts.
// These are the shapes returned by the gateway RPCs:
//   - skills.search → { results: [ClawHubSearchResult] }
//   - skills.detail → ClawHubSkillDetail
//   - skills.install { source: "clawhub", slug } → { ok, slug, version, ... }

struct ClawHubSearchResult: Codable, Identifiable, Hashable, Sendable {
    var id: String { slug }
    let slug: String
    let displayName: String
    let summary: String?
    let version: String?
    /// Unix epoch millis from upstream. Optional because older index entries
    /// may omit it.
    let updatedAt: Double?
    let score: Double?
    var iconSpec: SkillIconSpec {
        SkillIconSpec.resolve(
            emoji: nil,
            key: slug,
            name: displayName,
            summary: summary
        )
    }

    init(slug: String, displayName: String, summary: String? = nil, version: String? = nil, updatedAt: Double? = nil, score: Double? = nil) {
        self.slug = slug
        self.displayName = displayName
        self.summary = summary
        self.version = version
        self.updatedAt = updatedAt
        self.score = score
    }
}

struct ClawHubSearchResponse: Codable, Sendable {
    let results: [ClawHubSearchResult]
}

struct SkillIconSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case emoji(String)
        case symbol(String)
    }

    let kind: Kind
    let tintName: String

    static func resolve(
        emoji: String?,
        key: String,
        name: String?,
        summary: String?
    ) -> SkillIconSpec {
        if let cleanEmoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines),
           cleanEmoji.isSingleDisplayEmoji {
            return SkillIconSpec(kind: .emoji(cleanEmoji), tintName: "accent")
        }

        let tokens = Set(
            [key, name, summary]
                .compactMap { $0 }
                .flatMap { $0.skillIconTokens }
        )

        for rule in fallbackRules where rule.matches.contains(where: { tokens.contains($0) }) {
            return SkillIconSpec(kind: .symbol(rule.symbol), tintName: rule.tintName)
        }

        return SkillIconSpec(kind: .symbol("puzzlepiece.extension.fill"), tintName: "purple")
    }

    private static let fallbackRules: [(matches: [String], symbol: String, tintName: String)] = [
        (["calendar", "reminder", "task", "agenda", "schedule"], "calendar.badge.clock", "orange"),
        (["mail", "gmail", "email", "message", "imsg", "slack", "discord"], "envelope.fill", "blue"),
        (["note", "notion", "document", "pdf", "summarize", "blog", "rss"], "doc.text.fill", "green"),
        (["github", "git", "coding", "code", "tmux", "terminal"], "chevron.left.forwardslash.chevron.right", "indigo"),
        (["voice", "audio", "whisper", "tts", "speak"], "waveform", "teal"),
        (["camera", "image", "gif", "video", "canvas", "screenshot", "peekaboo"], "photo.fill.on.rectangle.fill", "pink"),
        (["music", "spotify", "sonos", "bluetooth"], "music.note", "mint"),
        (["password", "secret", "token", "auth", "key"], "key.fill", "yellow"),
        (["browser", "web", "url", "search", "xurl"], "globe", "cyan"),
        (["health", "doctor", "status", "usage", "logs"], "stethoscope", "red")
    ]
}

private extension String {
    var isSingleDisplayEmoji: Bool {
        count == 1
            && unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji }
            && unicodeScalars.contains { !$0.properties.isASCIIHexDigit }
    }

    var skillIconTokens: [String] {
        let baseTokens = lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        return baseTokens.flatMap { token -> [String] in
            guard token.count > 3, token.hasSuffix("s") else { return [token] }
            return [token, String(token.dropLast())]
        }
    }
}

struct ClawHubSkillDetailResponse: Codable, Sendable {
    struct Skill: Codable, Sendable {
        let slug: String
        let displayName: String
        let summary: String?
        let createdAt: Double?
        let updatedAt: Double?
    }

    struct LatestVersion: Codable, Sendable {
        let version: String
        let createdAt: Double?
        let changelog: String?
    }

    struct Metadata: Codable, Sendable {
        let os: [String]?
        let systems: [String]?
    }

    struct Owner: Codable, Sendable {
        let handle: String?
        let displayName: String?
        let image: String?
    }

    let skill: Skill?
    let latestVersion: LatestVersion?
    let metadata: Metadata?
    let owner: Owner?
}

/// Lifecycle state for a per-slug install attempt.
///
/// Source of truth for "is the skill installed on the gateway?" is always the
/// `skills.status` RPC — this local enum tracks the in-memory progress of an
/// install the user kicked off in the current session, and any error text
/// returned by the gateway. On view reappear we call `skills.status` to
/// reconcile (handled by the Installed tab).
///
/// Transitions:
///   notInstalled → installing         (user tapped Install; RPC in-flight)
///   installing   → installed          (RPC returned ok)
///   installing   → error(message:)    (RPC threw / returned error)
///   error        → installing         (user tapped Install again to retry)
enum SkillInstallState: Equatable {
    case notInstalled
    case installing
    case installed
    case error(message: String)
}

enum ClawHubSearchFailure: Equatable {
    case gatewayNotReady
    case unsupportedGateway
    case other(message: String)

    static func from(errorDescription: String) -> ClawHubSearchFailure {
        let normalized = errorDescription.lowercased()
        if normalized.contains("skills.search"),
           normalized.contains("unknown method") || normalized.contains("method not found") {
            return .unsupportedGateway
        }
        if normalized.contains("invalid_request"),
           normalized.contains("skills.search") {
            return .unsupportedGateway
        }
        return .other(message: errorDescription)
    }

    var title: String {
        switch self {
        case .gatewayNotReady:
            "Machine is not ready"
        case .unsupportedGateway:
            "Skill browsing is not available"
        case .other:
            "Search failed"
        }
    }

    var message: String {
        switch self {
        case .gatewayNotReady:
            "Connect to a ready machine before browsing skills."
        case .unsupportedGateway:
            "The active machine does not support ClawHub browsing yet. You can still manage installed skills here."
        case .other(let message):
            message
        }
    }
}
