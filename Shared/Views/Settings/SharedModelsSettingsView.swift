import Foundation
import SwiftUI
import OpenClawChatUI
import OpenClawKit

// MARK: - Provider display names (shared)

/// Prettifies a raw provider id into a familiar label, mirroring the provider
/// display names OpenClaw upstream uses (`openclaw/src/infra/provider-usage.*`).
/// Shared by the composer's model picker and the Models settings page so both
/// group models under identical headers.
enum ModelProviderDisplay {
    static func name(for raw: String) -> String {
        switch raw.lowercased() {
        case "anthropic", "claude": return "Claude"
        case "openai", "codex", "gpt", "openai-codex": return "GPT"
        case "google", "gemini", "google-generative-ai", "google-vertex": return "Gemini"
        case "xai", "x-ai", "grok": return "Grok"
        case "deepseek": return "DeepSeek"
        case "mistral": return "Mistral"
        case "groq": return "Groq"
        case "moonshot", "kimi": return "Moonshot"
        case "openrouter": return "OpenRouter"
        case "together", "togetherai": return "Together"
        case "minimax", "gmi": return "MiniMax"
        case "zai", "z.ai", "z-ai": return "z.ai"
        case "nvidia": return "NVIDIA"
        case "": return "Other"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

/// User-facing model selection stays product-level: Automatic is the primary choice, while an
/// explicit model is shown by its human name. Provider transport jargon never becomes the label.
enum ModelPickerPresentation {
    static let automaticTitle = "Automatic"
    static let manageModelsTitle = "Manage Models"

    static func composerTitle(
        selectionID: String,
        models: [OpenClawChatModelChoice]
    ) -> String {
        guard selectionID != OpenClawChatViewModel.defaultModelSelectionID else {
            return automaticTitle
        }
        if let selected = models.first(where: { $0.selectionID == selectionID }) {
            return ModelUserFacingCopy.modelName(selected.name)
        }
        let leaf = selectionID.split(separator: "/").last.map(String.init) ?? selectionID
        let readable = leaf.replacingOccurrences(of: "-", with: " ")
        return ModelUserFacingCopy.modelName(readable)
    }
}

// MARK: - Model picker policy (shared)

/// Resolves the composer's visible model choices and copy from existing sources of truth:
/// gateway session defaults, the gateway model catalog, managed GMI, runtime-authenticated
/// providers, and the user's explicit enable/disable preferences. No model id is duplicated in
/// the client, and a device-local key is never mistaken for gateway authentication.
enum ModelPickerPolicy {
    struct ProviderGroup: Identifiable, Equatable {
        let provider: String
        let models: [OpenClawChatModelChoice]
        var id: String { provider }
    }

    private static let managedProviderIDs = ["gmi"]

    /// Mirrors OpenClaw's canonical provider identity at
    /// `src/agents/provider-id.ts`. Both catalog rows and auth-availability responses must pass
    /// through this one boundary: the gateway intentionally returns canonical ids, while older
    /// catalogs and provider plugins may still emit aliases such as `z.ai` or `qwencloud`.
    static func canonicalProviderID(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "google-generative-ai":
            // The catalog can retain this SDK-facing alias, but OpenClaw registers API-key auth
            // under `google`. Canonicalize before the authAvailability RPC as well as filtering.
            return "google"
        case "modelstudio", "qwencloud":
            return "qwen"
        case "z.ai", "z-ai":
            return "zai"
        case "opencode-zen":
            return "opencode"
        case "opencode-go-auth":
            return "opencode-go"
        case "anthropic-cli":
            return "claude-cli"
        case "kimi", "kimi-code", "kimi-coding":
            return "kimi"
        case "moonshotai", "moonshot-ai":
            return "moonshot"
        case "bedrock", "aws-bedrock":
            return "amazon-bedrock"
        case "bytedance", "doubao":
            return "volcengine"
        default:
            return normalized
        }
    }

    static func relevantProviderNames(runtimeConfiguredProviderIDs: [String]) -> Set<String> {
        Set((runtimeConfiguredProviderIDs + managedProviderIDs).map { ModelProviderDisplay.name(for: $0) })
    }

    static func isProviderUsable(
        _ rawProviderID: String,
        runtimeConfiguredProviderIDs: [String]
    ) -> Bool {
        let provider = canonicalProviderID(rawProviderID)
        var authorized = Set(managedProviderIDs.map(canonicalProviderID))
        for configured in runtimeConfiguredProviderIDs.map(canonicalProviderID) {
            authorized.insert(configured)
        }
        return authorized.contains(provider)
    }

    static func settingsModels(
        _ models: [OpenClawChatModelChoice],
        runtimeConfiguredProviderIDs: [String]
    ) -> [OpenClawChatModelChoice] {
        models.filter {
            isProviderUsable(
                $0.provider,
                runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs)
        }
    }

    static func runtimeAvailableProviderIDs(
        from providers: [ProviderAuthAvailabilityPayload.Provider]
    ) -> [String] {
        Array(Set(providers.compactMap { provider -> String? in
            guard provider.available else { return nil }
            let normalized = canonicalProviderID(provider.provider)
            return normalized.isEmpty ? nil : normalized
        })).sorted()
    }

    /// Providers whose runtime auth must be probed before the current session model can be
    /// reconciled. The explicit selection is an independent source because `models.list` is
    /// best-effort and may be empty even while session metadata still names a provider-qualified
    /// override.
    static func providerIDsForRuntimeEvidence(
        models: [OpenClawChatModelChoice],
        requestedSelectionID: String
    ) -> [String] {
        var providerIDs = models.map(\.provider)
        if let explicitProviderID = explicitProviderID(from: requestedSelectionID) {
            providerIDs.append(explicitProviderID)
        }
        return Array(Set(providerIDs.compactMap { provider -> String? in
            let canonical = canonicalProviderID(provider)
            return canonical.isEmpty ? nil : canonical
        })).sorted()
    }

    static func resolvedDefaultChoice(
        defaultModelLabel: String,
        models: [OpenClawChatModelChoice]
    ) -> OpenClawChatModelChoice? {
        let reference = defaultModelReference(from: defaultModelLabel)
        guard !reference.isEmpty else { return nil }
        if let exactSelection = models.first(where: { reference == $0.selectionID }) {
            return exactSelection
        }
        let exactModelIDs = models.filter { reference == $0.modelID }
        if exactModelIDs.count == 1 { return exactModelIDs[0] }
        let suffixMatches = models.filter { reference.hasSuffix("/\($0.modelID)") }
        return suffixMatches.count == 1 ? suffixMatches[0] : nil
    }

    static func resolvedDefaultName(
        defaultModelLabel: String,
        models: [OpenClawChatModelChoice]
    ) -> String {
        if let choice = resolvedDefaultChoice(defaultModelLabel: defaultModelLabel, models: models) {
            return choice.name
        }
        let reference = defaultModelReference(from: defaultModelLabel)
        return reference.isEmpty ? "Automatic" : humanReadableModelName(reference)
    }

    static func composerModels(
        _ models: [OpenClawChatModelChoice],
        runtimeConfiguredProviderIDs: [String],
        defaultModelLabel _: String
    ) -> [OpenClawChatModelChoice] {
        let relevant = models.filter { choice in
            // Rem's managed provider is a product entitlement, not a blanket BYOK credential.
            // Only the canonical MiniMax model is offered; sibling GMI catalog entries would
            // falsely imply that every model on the transport is part of Rem's plan. Enforce
            // this even when a stale session/default still names a sibling catalog model.
            if choice.provider.caseInsensitiveCompare(
                GatewayModelSettingsSnapshot.managedProviderID
            ) == .orderedSame {
                return GatewayModelSettingsSnapshot.isMiniMax(choice)
            }

            return isProviderUsable(
                choice.provider,
                runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs)
        }
        return relevant
    }

    static func composerGroups(
        _ models: [OpenClawChatModelChoice],
        runtimeConfiguredProviderIDs: [String],
        defaultModelLabel: String,
        hasAuthoritativeProviderEvidence: Bool = true
    ) -> [ProviderGroup] {
        // Managed MiniMax is normally entitlement-backed, but an unknown probe cannot prove that
        // this particular runtime has adopted the managed configuration. Keep only the caller's
        // unconditional Automatic + Manage Models rows until provider evidence is authoritative.
        guard hasAuthoritativeProviderEvidence else { return [] }
        let visible = composerModels(
            models,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs,
            defaultModelLabel: defaultModelLabel)
        return Dictionary(grouping: visible, by: { ModelProviderDisplay.name(for: $0.provider) })
            .map { provider, choices in
                ProviderGroup(
                    provider: provider,
                    models: choices.sorted {
                        ModelUserFacingCopy.modelName($0.name)
                            .localizedCaseInsensitiveCompare(ModelUserFacingCopy.modelName($1.name))
                            == .orderedAscending
                    })
            }
            .sorted {
                $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending
            }
    }

    static func effectiveSelectionID(
        requestedSelectionID: String,
        models: [OpenClawChatModelChoice],
        catalogCompleteness: OpenClawChatModelCatalogCompleteness,
        runtimeConfiguredProviderIDs: [String],
        defaultModelLabel: String
    ) -> String {
        guard requestedSelectionID != OpenClawChatViewModel.defaultModelSelectionID else {
            return requestedSelectionID
        }
        // A degraded `models.list` can still contain config-synthesized rows (Rem gateways normally
        // retain managed MiniMax), so list contents cannot prove catalog completeness. Preserve an
        // explicit selection only when the RPC marks the catalog incomplete and the independent
        // auth runtime verifies its provider. A complete catalog remains authoritative.
        if catalogCompleteness != .complete,
           let providerID = explicitProviderID(from: requestedSelectionID),
           isProviderUsable(
               providerID,
               runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs)
        {
            return requestedSelectionID
        }
        let visibleSelectionIDs = Set(composerModels(
            models,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs,
            defaultModelLabel: defaultModelLabel
        ).map(\.selectionID))
        return visibleSelectionIDs.contains(requestedSelectionID)
            ? requestedSelectionID
            : OpenClawChatViewModel.defaultModelSelectionID
    }

    static func explicitProviderID(from selectionID: String) -> String? {
        let selection = selectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selection != OpenClawChatViewModel.defaultModelSelectionID,
              let separator = selection.firstIndex(of: "/")
        else { return nil }
        let canonical = canonicalProviderID(String(selection[..<separator]))
        return canonical.isEmpty ? nil : canonical
    }

    private static func defaultModelReference(from label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Default:"
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else {
            return trimmed.caseInsensitiveCompare("Default") == .orderedSame ? "" : trimmed
        }
        return String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func humanReadableModelName(_ raw: String) -> String {
        let leaf = raw.split(separator: "/").last.map(String.init) ?? raw
        return leaf.replacingOccurrences(of: "-", with: " ")
    }
}

struct ProviderAuthAvailabilityPayload: Decodable, Equatable {
    struct Provider: Decodable, Equatable {
        let provider: String
        let available: Bool
    }

    let providers: [Provider]
}

/// Compatibility payload exposed by OpenClaw before `models.authAvailability` was added. This is
/// still structured runtime evidence: `static`, `ok`, and `expiring` describe a credential the
/// active gateway can presently resolve, while `expired` and `missing` do not.
struct ProviderAuthStatusPayload: Decodable, Equatable {
    struct Provider: Decodable, Equatable {
        let provider: String
        let status: String
    }

    let providers: [Provider]
}

enum ProviderAuthCompatibilityPolicy {
    static let legacyAuthStatusParamsJSON: String? = nil

    static func shouldUseAuthStatusFallback(
        after error: Error,
        gatewayProvider: GatewayProvider?
    ) -> Bool {
        guard gatewayProvider == .fly else { return false }
        guard let response = error as? GatewayResponseError else { return false }
        return response.method == "models.authAvailability"
            && response.code == "INVALID_REQUEST"
    }

    static func runtimeAvailableProviderIDs(
        from providers: [ProviderAuthStatusPayload.Provider],
        candidates: [String]
    ) -> [String] {
        let candidateSet = Set(candidates.map(ModelPickerPolicy.canonicalProviderID))
        let usableStatuses = Set(["static", "ok", "expiring"])
        return Array(Set(providers.compactMap { entry -> String? in
            let provider = ModelPickerPolicy.canonicalProviderID(entry.provider)
            guard candidateSet.contains(provider),
                  usableStatuses.contains(entry.status.lowercased())
            else { return nil }
            return provider
        })).sorted()
    }
}

/// Older managed gateways expose only a partial auth-health projection: a missing provider row is
/// not proof that env/config/AWS credentials are unavailable. Positive rows are safe to present,
/// but callers must not use this snapshot to reset an omitted explicit selection.
struct RuntimeProviderAuthPartialEvidence: Error, Equatable {
    let providerIDs: [String]
}

/// Auth availability has three materially different states. An empty verified list proves that no
/// candidate provider is usable; loading/failure without a prior same-session snapshot proves
/// nothing and must never trigger a destructive model reset.
enum RuntimeProviderAuthEvidence: Equatable {
    case loading(lastVerifiedProviderIDs: [String]?)
    case verified([String])
    case legacyPartial([String])
    case failed(lastVerifiedProviderIDs: [String]?)

    /// IDs safe to use for filtering and model reconciliation. Loading/error preserves only the
    /// last snapshot from the exact same operator-session generation.
    var effectiveProviderIDs: [String]? {
        switch self {
        case .verified(let providerIDs):
            providerIDs
        case .legacyPartial(let providerIDs):
            providerIDs
        case .loading(let providerIDs), .failed(let providerIDs):
            providerIDs
        }
    }

    var hasAuthoritativeSnapshot: Bool {
        if case .legacyPartial = self { return false }
        return effectiveProviderIDs != nil
    }

    var canLoadModelSettings: Bool { effectiveProviderIDs != nil }

    var canPresentProviderMenus: Bool {
        switch self {
        case .legacyPartial, .verified:
            true
        case .loading(let providerIDs), .failed(let providerIDs):
            providerIDs != nil
        }
    }

    var beginningSameScopeRefresh: RuntimeProviderAuthEvidence {
        if case .legacyPartial = self { return self }
        return .loading(lastVerifiedProviderIDs: hasAuthoritativeSnapshot ? effectiveProviderIDs : nil)
    }

    func canReconcileExplicitSelection(_ selectionID: String) -> Bool {
        guard selectionID != OpenClawChatViewModel.defaultModelSelectionID else { return true }
        switch self {
        case .legacyPartial(let providerIDs):
            guard let providerID = ModelPickerPolicy.explicitProviderID(from: selectionID) else {
                return false
            }
            return ModelPickerPolicy.isProviderUsable(
                providerID,
                runtimeConfiguredProviderIDs: providerIDs
            )
        default:
            return hasAuthoritativeSnapshot
        }
    }

    static func resolvingLoadFailure(
        _ error: Error,
        priorSameScopeEvidence: RuntimeProviderAuthEvidence?
    ) -> RuntimeProviderAuthEvidence {
        if let partial = error as? RuntimeProviderAuthPartialEvidence {
            return .legacyPartial(partial.providerIDs)
        }
        if let priorSameScopeEvidence,
           case .legacyPartial = priorSameScopeEvidence {
            return priorSameScopeEvidence
        }
        return .failed(
            lastVerifiedProviderIDs: priorSameScopeEvidence?.hasAuthoritativeSnapshot == true
                ? priorSameScopeEvidence?.effectiveProviderIDs
                : nil
        )
    }

    var modelSettingsState: ModelSettingsProviderEvidenceState {
        switch self {
        case .verified(let providerIDs):
            .available(providerIDs)
        case .legacyPartial(let providerIDs):
            .available(providerIDs)
        case .loading(let providerIDs):
            providerIDs.map(ModelSettingsProviderEvidenceState.available) ?? .loading
        case .failed(let providerIDs):
            providerIDs.map(ModelSettingsProviderEvidenceState.available) ?? .unavailable
        }
    }
}

enum ModelSettingsProviderEvidenceState: Equatable {
    case loading
    case available([String])
    case unavailable
}

private enum RuntimeProviderAuthEvidenceLoadError: LocalizedError {
    case noCandidateProviders

    var errorDescription: String? {
        "Provider authentication could not be verified because no provider candidates were available."
    }
}

private struct ProviderAuthAvailabilityRequest: Encodable {
    let providers: [String]
}

extension GatewaySessionProviding {
    /// Catalog rows are used only to bound the provider ids sent to the auth runtime. The catalog
    /// itself does not authorize anything.
    func loadRuntimeConfiguredProviderIDs() async throws -> [String] {
        let catalogData = try await skillsRequest(
            method: "models.list",
            paramsJSON: nil,
            timeoutSeconds: 15
        )
        let catalog = try JSONDecoder().decode(ModelsListPayload.self, from: catalogData)
        return try await loadRuntimeConfiguredProviderIDs(
            candidateProviderIDs: catalog.models.map(\.provider)
        )
    }

    /// Asks the gateway's model-auth runtime whether each catalog provider can resolve usable auth.
    /// Catalog/config membership and device-local credentials are deliberately not evidence.
    func loadRuntimeConfiguredProviderIDs(candidateProviderIDs: [String]) async throws -> [String] {
        try await requestRuntimeConfiguredProviderIDs(candidateProviderIDs: candidateProviderIDs)
    }

    /// Default Rem-runtime implementation. Kept separate from the protocol requirement so a Mac
    /// local-gateway override can fall through here for cloud/manual gateways without recursion.
    func requestRuntimeConfiguredProviderIDs(candidateProviderIDs: [String]) async throws -> [String] {
        let candidates = Array(Set(candidateProviderIDs.compactMap { provider -> String? in
            let normalized = ModelPickerPolicy.canonicalProviderID(provider)
            return normalized.isEmpty ? nil : normalized
        })).sorted()
        // No candidates is absence of evidence, not proof that every provider is unavailable.
        // Callers must retain an exact-session prior snapshot or block destructive reconciliation.
        guard !candidates.isEmpty else {
            throw RuntimeProviderAuthEvidenceLoadError.noCandidateProviders
        }
        let requestData = try JSONEncoder().encode(ProviderAuthAvailabilityRequest(providers: candidates))
        guard let paramsJSON = String(data: requestData, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                candidates,
                .init(codingPath: [], debugDescription: "Couldn't encode provider availability request"))
        }
        do {
            let data = try await skillsRequest(
                method: "models.authAvailability",
                paramsJSON: paramsJSON,
                timeoutSeconds: 15
            )
            let result = try JSONDecoder().decode(ProviderAuthAvailabilityPayload.self, from: data)
            return ModelPickerPolicy.runtimeAvailableProviderIDs(from: result.providers)
        } catch {
            // Managed gateways pinned before models.authAvailability still expose the upstream
            // structured models.authStatus snapshot. Fall back only for the exact schema/method
            // rejection; timeouts, auth failures, disconnects, and malformed responses stay failed
            // closed instead of trusting catalog membership or device-local keys.
            guard ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
                after: error,
                gatewayProvider: activeGatewayProviderForDisplay
            )
            else {
                throw error
            }
            let data = try await skillsRequest(
                method: "models.authStatus",
                // The oldest compatible schema accepts only the empty request shape. Its runtime
                // cache is bounded, so compatibility is more important than forcing refresh here.
                paramsJSON: ProviderAuthCompatibilityPolicy.legacyAuthStatusParamsJSON,
                timeoutSeconds: 15
            )
            let result = try JSONDecoder().decode(ProviderAuthStatusPayload.self, from: data)
            throw RuntimeProviderAuthPartialEvidence(
                providerIDs: ProviderAuthCompatibilityPolicy.runtimeAvailableProviderIDs(
                    from: result.providers,
                    candidates: candidates
                )
            )
        }
    }
}

// MARK: - Models settings page (shared across iOS and macOS)

/// The "Manage Models" page presents gateway-backed Automatic/MiniMax controls when their
/// authoritative values and mutations are supplied, followed by the searchable model catalog.
/// Catalog-only fixtures omit those inputs and therefore remain truthfully read-only.
/// Only providers confirmed by the active gateway are shown. Device-local credentials are not an
/// authorization source and are intentionally absent until the gateway credential lifecycle exists.
///
/// Pure view: it takes an already-loaded model list so it can be rendered both
/// from Settings (fetched via the gateway — see `SharedModelsSettingsScreen`)
/// and from the composer's "Manage models" footer (which already holds the
/// chat view model's `modelChoices`).
struct SharedModelsSettingsView: View {

    let models: [OpenClawChatModelChoice]
    /// Provider identifiers confirmed by the active gateway runtime. A key saved only on this
    /// device is intentionally not included.
    var runtimeConfiguredProviderIDs: [String] = []
    /// Present only when this page is backed by the active gateway's config. Nil keeps deterministic
    /// fixtures/catalog-only call sites read-only rather than rendering switches that cannot save.
    var automaticEnabled: Bool?
    var miniMaxEnabled: Bool?
    var miniMaxToggleDisabledReason: String?
    /// Explains why authoritative values are visible but both gateway mutations are unavailable.
    var modelSettingsReadOnlyReason: String? = nil
    var isSavingModelSettings: Bool = false
    var modelSettingsError: String?
    var onSetAutomatic: ((Bool) -> Void)?
    var onSetMiniMax: ((Bool) -> Void)?

    @State private var searchText = ""
    /// The product-level Automatic group owns the managed model and any providers the user adds.
    /// Provider implementation details stay collapsed until the user asks to manage them.
    @State private var automaticExpanded = false
    /// Providers whose model list is expanded. Empty by default: each provider header collapses to
    /// "<Provider> · N models" so the page is scannable, and only the ones the user taps open expand
    /// to reveal their models. Search bypasses this — see `isGroupExpanded`.
    @State private var expandedProviders: Set<String> = []
    /// Regional-variant families (e.g. "Claude Opus 4.5" → EU/US/Global) expanded to reveal the
    /// individual regional models. Keyed by "<provider>|<family>" so the same family under two
    /// providers stays independent.
    @State private var expandedVariantFamilies: Set<String> = []

    /// Models grouped by provider, matching the composer's ordering: providers
    /// sorted by display name, models alphabetically. Filtered by the search box.
    private var groupedModels: [(provider: String, models: [OpenClawChatModelChoice])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? models : models.filter { choice in
            ModelUserFacingCopy.modelName(choice.name).lowercased().contains(query)
                || ModelProviderDisplay.name(for: choice.provider).lowercased().contains(query)
        }
        let catalogModels = automaticEnabled == nil
            ? filtered
            : filtered.filter { !GatewayModelSettingsSnapshot.isMiniMax($0) }
        return Dictionary(grouping: catalogModels) { ModelProviderDisplay.name(for: $0.provider) }
            .map { (provider: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.provider < $1.provider }
    }

    /// The managed provider Rem routes through by default (GMI MaaS). Always shown.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Groups actually rendered: only raw providers authorized by the managed service or active
    /// runtime. Search narrows this same usable set; it never reveals an unavailable catalog.
    private var visibleGroups: [(provider: String, models: [OpenClawChatModelChoice])] {
        groupedModels.compactMap { group in
            let usable = ModelPickerPolicy.settingsModels(
                group.models,
                runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs)
            return usable.isEmpty ? nil : (provider: group.provider, models: usable)
        }
    }

    // MARK: - Regional-variant grouping

    /// A family of models that share a base name but differ only by region suffix
    /// (e.g. "Claude Opus 4.5", "Claude Opus 4.5 (EU)", "Claude Opus 4.5 (US)").
    /// A family with a single member renders as a plain row; a family with
    /// several collapses to one row that expands to the regional variants —
    /// this is what tames Bedrock's 12-Claude-variant wall.
    private struct ModelFamily: Identifiable {
        let base: String
        let models: [OpenClawChatModelChoice]
        var id: String { base }
        var isMulti: Bool { models.count > 1 }
    }

    /// Strips a trailing region/tier qualifier so regional variants collapse into
    /// one family. Matches a parenthesised suffix ("… (EU)", "… (US)", "… (Global)")
    /// or a bare trailing region token ("… EU", "… US"). Everything else is its own
    /// family, so distinct models never get merged.
    private static let regionSuffixes: Set<String> = [
        "eu", "us", "global", "apac", "emea", "cross-region", "cross region"
    ]

    private static func familyBase(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Parenthesised suffix: "Claude Opus 4.5 (EU)"
        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
            let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if regionSuffixes.contains(inside) {
                return String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        // Bare trailing region token: "Claude Opus 4 US"
        let parts = trimmed.split(separator: " ")
        if parts.count > 1, regionSuffixes.contains(String(parts.last!).lowercased()) {
            return parts.dropLast().joined(separator: " ")
        }
        return trimmed
    }

    /// Collapses a provider's models into families, preserving the incoming
    /// (alphabetical) order of first appearance.
    private func families(for models: [OpenClawChatModelChoice]) -> [ModelFamily] {
        var order: [String] = []
        var buckets: [String: [OpenClawChatModelChoice]] = [:]
        for model in models {
            let base = Self.familyBase(for: model.name)
            if buckets[base] == nil { order.append(base) }
            buckets[base, default: []].append(model)
        }
        return order.map { ModelFamily(base: $0, models: buckets[$0] ?? []) }
    }

    /// A provider group is expanded when the user tapped it open, or unconditionally
    /// while searching / showing the full catalog (results must be visible then).
    private func isGroupExpanded(_ provider: String) -> Bool {
        isSearching || expandedProviders.contains(provider)
    }

    var body: some View {
        platformContainer
            .navigationTitle(ModelPickerPresentation.manageModelsTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }

    /// iOS uses `List` + insetGrouped; macOS uses `Form` + grouped in the
    /// centered settings column — matching `SharedBYOKSettingsView`.
    @ViewBuilder
    private var platformContainer: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .macSettingsCenteredColumn()
        #else
        List { content }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // macOS Form has no `.searchable` list chrome — inline search field.
        Section {
            TextField("Search models", text: $searchText)
                .textFieldStyle(.roundedBorder)
        }
        #endif

        if let automaticEnabled {
            Section {
                Toggle(isOn: Binding(
                    get: { automaticEnabled },
                    set: { onSetAutomatic?($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ModelPickerPresentation.automaticTitle)
                        Text("Let Rem use any model available on this gateway.")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                    }
                }
                .disabled(isSavingModelSettings || onSetAutomatic == nil)
                .accessibilityIdentifier("models-automatic-toggle")

                if let miniMaxEnabled {
                    Toggle(isOn: Binding(
                        get: { miniMaxEnabled },
                        set: { onSetMiniMax?($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MiniMax M2.7")
                            Text("Rem's managed model")
                                .font(DesignTokens.Typography.caption1)
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                        }
                    }
                    .disabled(
                        isSavingModelSettings || onSetMiniMax == nil ||
                            (miniMaxEnabled && miniMaxToggleDisabledReason != nil)
                    )
                    .accessibilityIdentifier("models-minimax-toggle")
                }

                if isSavingModelSettings {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Saving on your gateway…")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                    }
                }

                if let modelSettingsError {
                    Text(modelSettingsError)
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.systemRed)
                }
            } header: {
                Text("Rem")
            } footer: {
                if let modelSettingsReadOnlyReason {
                    Text(modelSettingsReadOnlyReason)
                } else if let miniMaxToggleDisabledReason {
                    Text(miniMaxToggleDisabledReason)
                } else {
                    Text("Automatic changes which available models Rem may choose from. It does not change this conversation's selected model.")
                }
            }
        }

        if visibleGroups.isEmpty {
            Section {
                Text(isSearching ? "No available models match your search." : "No other models are available on this gateway.")
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
        } else {
            Section {
                if automaticEnabled == nil {
                    DisclosureGroup(isExpanded: Binding(
                        get: { isSearching || automaticExpanded },
                        set: { open in
                            guard !isSearching else { return }
                            automaticExpanded = open
                        }
                    )) {
                        ForEach(visibleGroups, id: \.provider) { group in
                            providerDisclosure(group)
                        }
                    } label: {
                        Text(ModelPickerPresentation.automaticTitle)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                    }
                    .accessibilityIdentifier("models-automatic-group")
                } else {
                    ForEach(visibleGroups, id: \.provider) { group in
                        providerDisclosure(group)
                    }
                }
            } header: {
                if automaticEnabled != nil { Text("Other available models") }
            }
        }
    }

    /// A single provider rendered as a collapse-by-default disclosure: the header
    /// reads "<Provider> · N models", and expanding reveals the model families.
    /// Collapsing every provider is what keeps the
    /// default page scannable instead of a wall of regional variants.
    @ViewBuilder
    private func providerDisclosure(_ group: (provider: String, models: [OpenClawChatModelChoice])) -> some View {
        let modelFamilies = families(for: group.models)
        DisclosureGroup(isExpanded: Binding(
            get: { isGroupExpanded(group.provider) },
            set: { open in
                // Search forces every group open; ignore collapse attempts while searching.
                guard !isSearching else { return }
                if open { expandedProviders.insert(group.provider) }
                else { expandedProviders.remove(group.provider) }
            }
        )) {
            ForEach(modelFamilies) { family in
                familyRows(family, provider: group.provider)
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(ModelProviderDisplay.name(for: group.provider))
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(DesignTokens.Color.labelPrimary)
                Spacer(minLength: 0)
                Text(modelCountLabel(total: group.models.count))
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
            }
        }
        .accessibilityIdentifier("models-provider-\(group.provider)")
    }

    private func modelCountLabel(total: Int) -> String {
        let noun = total == 1 ? "model" : "models"
        return "\(total) \(noun)"
    }

    /// Renders a model family: a single model is a plain row; a multi-region
    /// family collapses into one nested disclosure ("<Base> · N regions") that
    /// expands to the individual regional toggles.
    @ViewBuilder
    private func familyRows(_ family: ModelFamily, provider: String) -> some View {
        if family.isMulti {
            let key = "\(provider)|\(family.base)"
            DisclosureGroup(isExpanded: Binding(
                // Search force-expands the family too — otherwise a matched regional
                // variant ("Claude Opus 4.5 (EU)") stays hidden behind the collapsed
                // "… · N regions" row even though search claims to span every model.
                get: { isSearching || expandedVariantFamilies.contains(key) },
                set: { open in
                    guard !isSearching else { return }
                    if open { expandedVariantFamilies.insert(key) }
                    else { expandedVariantFamilies.remove(key) }
                }
            )) {
                ForEach(family.models) { choice in
                    modelCatalogRow(choice, label: variantLabel(choice.name, base: family.base))
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(family.base)
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(DesignTokens.Color.labelPrimary)
                    Spacer(minLength: 0)
                    Text("\(family.models.count) regions")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                }
            }
            .accessibilityIdentifier("models-family-\(key)")
        } else if let choice = family.models.first {
            modelCatalogRow(choice)
        }
    }

    /// Short label for a regional variant inside an expanded family — the region
    /// qualifier alone ("EU", "US", "Global"), or the full name if it has none.
    private func variantLabel(_ name: String, base: String) -> String {
        let suffix = name.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        return suffix.isEmpty ? name : suffix
    }

    private func modelCatalogRow(_ choice: OpenClawChatModelChoice, label: String? = nil) -> some View {
        Text(ModelUserFacingCopy.modelName(label ?? choice.name))
            .font(DesignTokens.Typography.body)
            .foregroundColor(DesignTokens.Color.labelPrimary)
            .accessibilityIdentifier("model-catalog-\(choice.selectionID)")
    }

}

// MARK: - Settings entry point (generic loader)

/// Gateway-backed wrapper that reads and writes the active runtime's model policy, reconciles
/// mutations, and hands authoritative state to the pure `SharedModelsSettingsView`. Settings and
/// both chat wrappers use this entry point; only deterministic previews use the catalog-only view.
struct SharedModelsSettingsScreen<Gateway: GatewaySessionProviding>: View {

    let gateway: Gateway
    let runtimeProviderAuthEvidence: RuntimeProviderAuthEvidence
    var onCatalogChanged: (() -> Void)?

    @State private var snapshot: GatewayModelSettingsSnapshot?
    @State private var isLoading = true
    @State private var pendingMutation: GatewayModelSettingMutation?
    @State private var loadError: String?
    @State private var mutationError: String?
    @State private var toast: RemToastItem?
    @State private var connectionRevision = 0
    @State private var mutationTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !gateway.operatorReady {
                disconnectedState
            } else if runtimeProviderAuthEvidence.modelSettingsState == .loading {
                modelSettingsSkeleton
            } else if runtimeProviderAuthEvidence.modelSettingsState == .unavailable {
                providerEvidenceFailureState
            } else if isLoading, snapshot == nil {
                modelSettingsSkeleton
            } else if let snapshot {
                SharedModelsSettingsView(
                    models: snapshot.userVisibleCatalogModels,
                    // Only the model-auth runtime may authorize providers. Catalog membership,
                    // including `snapshot.effectiveModels`, cannot widen this set.
                    runtimeConfiguredProviderIDs: runtimeProviderAuthEvidence.effectiveProviderIDs ?? [],
                    automaticEnabled: pendingAutomaticValue ?? snapshot.automaticEnabled,
                    miniMaxEnabled: pendingMiniMaxValue ?? snapshot.miniMaxPresentationValue,
                    miniMaxToggleDisabledReason: {
                        if snapshot.managedModelRef == nil {
                            return GatewayModelSettingsError.managedModelUnavailable.errorDescription
                        }
                        return snapshot.miniMaxIsPrimary
                            ? GatewayModelSettingsError.managedModelIsPrimary.errorDescription
                            : nil
                    }(),
                    modelSettingsReadOnlyReason: snapshot.catalogAuthority.readOnlyDescription,
                    isSavingModelSettings: pendingMutation != nil,
                    modelSettingsError: mutationError,
                    onSetAutomatic: snapshot.catalogAuthority.canMutate
                        ? { enabled in startMutation(.automatic(enabled)) }
                        : nil,
                    onSetMiniMax: snapshot.catalogAuthority.canMutate && snapshot.managedModelRef != nil
                        ? { enabled in startMutation(.miniMax(enabled)) }
                        : nil
                )
            } else {
                loadFailureState
            }
        }
        .navigationTitle(ModelPickerPresentation.manageModelsTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard runtimeProviderAuthEvidence.canLoadModelSettings else { return }
            await load(expectedRevision: connectionRevision)
        }
        .onChange(of: gateway.operatorReady) { _, ready in
            connectionRevision &+= 1
            let revision = connectionRevision
            mutationTask?.cancel()
            mutationTask = nil
            snapshot = nil
            pendingMutation = nil
            mutationError = nil
            loadError = nil
            isLoading = true
            if ready {
                Task { await load(expectedRevision: revision) }
            }
        }
        .onChange(of: runtimeProviderAuthEvidence.modelSettingsState) { _, evidenceState in
            connectionRevision &+= 1
            let revision = connectionRevision
            mutationTask?.cancel()
            mutationTask = nil
            snapshot = nil
            pendingMutation = nil
            mutationError = nil
            loadError = nil
            isLoading = true
            if gateway.operatorReady, case .available = evidenceState {
                Task { await load(expectedRevision: revision) }
            }
        }
        .remToast(item: $toast)
    }

    private var client: GatewayModelSettingsClient {
        GatewayModelSettingsClient { method, paramsJSON, timeout in
            try await gateway.skillsRequest(
                method: method,
                paramsJSON: paramsJSON,
                timeoutSeconds: timeout
            )
        }
    }

    private var pendingAutomaticValue: Bool? {
        guard case .automatic(let enabled)? = pendingMutation else { return nil }
        return enabled
    }

    private var pendingMiniMaxValue: Bool? {
        guard case .miniMax(let enabled)? = pendingMutation else { return nil }
        return enabled
    }

    @ViewBuilder
    private var modelSettingsSkeleton: some View {
        List {
            Section("Rem") {
                ForEach(0..<2, id: \.self) { _ in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DesignTokens.Color.fillTertiary)
                                .frame(width: 132, height: 16)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DesignTokens.Color.fillTertiary)
                                .frame(width: 220, height: 11)
                        }
                        Spacer()
                        Capsule()
                            .fill(DesignTokens.Color.fillTertiary)
                            .frame(width: 50, height: 30)
                    }
                    .redacted(reason: .placeholder)
                    .shimmering()
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .accessibilityIdentifier("models-settings-loading")
    }

    @ViewBuilder
    private var disconnectedState: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            RemContextualMessage(
                icon: "wifi.slash",
                iconColor: DesignTokens.Color.systemOrange,
                title: "Reconnect to manage models",
                subtitle: "Model choices live on your gateway so every signed-in device stays in sync."
            ) {
                Button("Reconnect") { gateway.reconnect() }
                    .remInlineRecoveryCTA()
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var providerEvidenceFailureState: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            RemContextualMessage(
                icon: "key.slash",
                iconColor: DesignTokens.Color.systemOrange,
                title: "Couldn't verify available models",
                subtitle: "Reconnect to confirm which model providers this gateway can use."
            ) {
                Button("Reconnect") { gateway.reconnect() }
                    .remInlineRecoveryCTA()
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("models-provider-evidence-unavailable")
    }

    @ViewBuilder
    private var loadFailureState: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            RemContextualMessage(
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                iconColor: DesignTokens.Color.systemOrange,
                title: "Couldn't load model settings",
                subtitle: loadError ?? "Check the gateway connection and try again."
            ) {
                Button("Try Again") { Task { await load() } }
                    .remInlineRecoveryCTA()
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func load(expectedRevision: Int? = nil) async {
        let revision = expectedRevision ?? connectionRevision
        guard gateway.operatorReady else {
            if revision == connectionRevision { isLoading = false }
            return
        }
        isLoading = true
        loadError = nil
        do {
            let loaded = try await client.load(
                runtimeConfiguredProviderIDs: runtimeProviderAuthEvidence.effectiveProviderIDs ?? []
            )
            guard revision == connectionRevision, gateway.operatorReady else { return }
            snapshot = loaded
        } catch {
            guard revision == connectionRevision, gateway.operatorReady else { return }
            loadError = (error as? LocalizedError)?.errorDescription
                ?? "The gateway didn't return its model settings. Try again when it's connected."
        }
        if revision == connectionRevision { isLoading = false }
    }

    private func startMutation(_ mutation: GatewayModelSettingMutation) {
        guard mutationTask == nil else { return }
        mutationTask = Task { await apply(mutation) }
    }

    private func apply(_ mutation: GatewayModelSettingMutation) async {
        guard pendingMutation == nil, let current = snapshot else { return }
        let revision = connectionRevision
        pendingMutation = mutation
        mutationError = nil
        defer {
            if revision == connectionRevision {
                pendingMutation = nil
                mutationTask = nil
            }
        }

        do {
            guard let runtimeConfiguredProviderIDs = runtimeProviderAuthEvidence.effectiveProviderIDs else {
                return
            }
            let updated = try await client.apply(
                mutation,
                to: current,
                runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
            )
            guard revision == connectionRevision, gateway.operatorReady else { return }
            snapshot = updated
            toast = .success("Model settings updated")
            onCatalogChanged?()
        } catch {
            if error is CancellationError { return }
            // The client performs a best-effort config rollback. Always refresh from the gateway so
            // switches snap to authoritative state instead of retaining an optimistic value.
            let refreshed = try? await client.load(
                runtimeConfiguredProviderIDs: runtimeProviderAuthEvidence.effectiveProviderIDs ?? []
            )
            guard revision == connectionRevision, gateway.operatorReady else { return }
            if let refreshed { snapshot = refreshed }
            mutationError = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't save the change. Check the connection and try again."
        }
    }
}
