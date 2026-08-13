import Foundation
import OpenClawChatUI
import OpenClawKit

/// The two product-level controls Rem exposes over OpenClaw's model visibility policy.
///
/// Upstream source of truth: `agents.defaults.models` (see
/// `openclaw/src/agents/model-selection-shared.ts`). A missing/empty map means "allow any
/// configured model"; a non-empty map is an explicit allowlist. `agents.defaults.model.primary`
/// and per-session overrides are deliberately outside this feature and are never rewritten.
enum GatewayModelSettingMutation: Equatable, Sendable {
    case automatic(Bool)
    case miniMax(Bool)
}

enum GatewayModelSettingsError: LocalizedError, Equatable {
    case missingConfigHash
    case noUsableModels
    case managedModelUnavailable
    case managedModelIsPrimary
    case fullCatalogUnavailable
    case legacyCatalogReadOnly
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .missingConfigHash:
            "This gateway can't safely save model changes yet. Update it, then try again."
        case .noUsableModels:
            "Keep at least one model enabled so Rem can still respond."
        case .managedModelUnavailable:
            "MiniMax M2.7 isn't available on this gateway right now."
        case .managedModelIsPrimary:
            "MiniMax M2.7 is Rem's current default, so it can't be turned off yet."
        case .fullCatalogUnavailable:
            "This gateway couldn't return its full model list. Reconnect or update it, then try again."
        case .legacyCatalogReadOnly:
            "This gateway can show its current model settings, but it needs an update before they can be changed."
        case .verificationFailed:
            "The gateway didn't confirm the change. Check the current setting and try again."
        }
    }
}

/// Whether a gateway proved both catalogs complete enough to materialize into config. Older
/// gateways return useful positive rows without completeness metadata; that state is display-only.
enum GatewayModelCatalogAuthority: Equatable, Sendable {
    case completeMutable
    case legacyReadOnly

    var canMutate: Bool { self == .completeMutable }

    var readOnlyDescription: String? {
        canMutate ? nil : GatewayModelSettingsError.legacyCatalogReadOnly.errorDescription
    }
}

/// Authoritative config + catalog read from one gateway. There is intentionally no UserDefaults
/// mirror: another signed-in device sees the same values after its next `config.get` refresh.
struct GatewayModelSettingsSnapshot: Equatable, Sendable {
    /// Mirrors the managed-provider contract in `backend/src/config/gateway-defaults.ts`:
    /// `GMI_PROVIDER_ID` + `GMI_MINIMAX_MODEL_ID`. Product copy may hide the provider name, but
    /// policy must never infer identity from display text or a fuzzy "M2.7" substring.
    static let managedProviderID = "gmi"
    static let managedModelID = "MiniMaxAI/MiniMax-M2.7"
    static let managedSelectionID = "gmi/MiniMaxAI/MiniMax-M2.7"

    let baseHash: String?
    let primaryModelRef: String?
    let allowlist: [String: JSONValue]?
    /// Full gateway catalog, including models currently hidden by an explicit allowlist. This is
    /// what lets a disabled managed model remain discoverable so its switch can be turned on again.
    let configuredModels: [OpenClawChatModelChoice]
    /// Models currently usable under the gateway's visibility policy.
    let effectiveModels: [OpenClawChatModelChoice]
    let catalogAuthority: GatewayModelCatalogAuthority
    /// Catalog membership alone never authorizes Rem's managed model. This override is populated
    /// only from exact managed identity plus positive runtime-auth evidence. Legacy catalogs also
    /// require that exact identity to appear in config because their rows are not authoritative.
    let legacyManagedModelRef: String?

    init(
        baseHash: String?,
        primaryModelRef: String?,
        allowlist: [String: JSONValue]?,
        configuredModels: [OpenClawChatModelChoice],
        effectiveModels: [OpenClawChatModelChoice],
        catalogAuthority: GatewayModelCatalogAuthority = .completeMutable,
        legacyManagedModelRef: String? = nil
    ) {
        self.baseHash = baseHash
        self.primaryModelRef = primaryModelRef
        self.allowlist = allowlist
        self.configuredModels = configuredModels
        self.effectiveModels = effectiveModels
        self.catalogAuthority = catalogAuthority
        self.legacyManagedModelRef = legacyManagedModelRef
    }

    /// Models appropriate for the read-only provider catalog below Rem's product-level switches.
    /// The managed provider is represented solely by the MiniMax M2.7 switch; leaking its sibling
    /// catalog entries would imply that Rem offers models the product has not enabled.
    var userVisibleCatalogModels: [OpenClawChatModelChoice] {
        effectiveModels.filter {
            Self.normalizedRef($0.provider) != Self.normalizedRef(Self.managedProviderID)
        }
    }

    var automaticEnabled: Bool {
        allowlist?.keys.isEmpty != false
    }

    var managedModelRef: String? {
        legacyManagedModelRef
    }

    var miniMaxEnabled: Bool {
        guard let managedModelRef else { return false }
        if automaticEnabled { return true }
        if let primaryModelRef,
           ModelAllowlistMatcher.matches(primaryModelRef, managedModelRef),
           ModelAllowlistMatcher.primaryIsAllowed(primaryModelRef, allowlist: allowlist)
        {
            return true
        }
        return ModelAllowlistMatcher.allows(
            managedModelRef,
            keys: allowlist?.keys.map { $0 } ?? []
        )
    }

    /// A partial catalog cannot prove that an unauthenticated/missing managed model is OFF. Hide
    /// that row rather than presenting unknown state as authoritative. A complete catalog can
    /// prove absence, so it may truthfully render the disabled OFF row.
    var miniMaxPresentationValue: Bool? {
        if catalogAuthority == .legacyReadOnly, managedModelRef == nil { return nil }
        return miniMaxEnabled
    }

    var miniMaxIsPrimary: Bool {
        guard let primaryModelRef, let managedModelRef else { return false }
        guard Self.normalizedRef(primaryModelRef) == Self.normalizedRef(managedModelRef) else {
            return false
        }
        let keys = allowlist?.keys.map { $0 } ?? []
        return ModelAllowlistMatcher.allows(primaryModelRef, keys: keys) ||
            ModelAllowlistMatcher.primaryIsAllowed(primaryModelRef, allowlist: allowlist)
    }

    var effectiveModelRefs: Set<String> {
        var refs = Set(effectiveModels.map(\.selectionID))
        if !automaticEnabled {
            refs.formUnion(
                (allowlist?.keys.map { $0 } ?? []).filter { !ModelAllowlistMatcher.isWildcard($0) }
            )
        }
        // Upstream always keeps the configured primary usable alongside an exact allowlist. Model
        // settings must reflect that instead of pretending removing its map entry disabled it.
        if let primaryModelRef,
           ModelAllowlistMatcher.primaryIsAllowed(primaryModelRef, allowlist: allowlist)
        {
            refs.insert(primaryModelRef)
        }
        return refs
    }

    static func isMiniMax(_ choice: OpenClawChatModelChoice) -> Bool {
        normalizedRef(choice.provider) == normalizedRef(managedProviderID) &&
            normalizedRef(choice.modelID) == normalizedRef(managedModelID) &&
            isManagedMiniMaxRef(choice.selectionID)
    }

    static func isManagedMiniMaxRef(_ raw: String) -> Bool {
        normalizedRef(raw) == normalizedRef(managedSelectionID)
    }

    private static func normalizedRef(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Mirrors OpenClaw's canonical exact-ref and `provider/*` visibility semantics. Keeping this
/// matcher shared by display, transition, and confirmation logic prevents a wildcard-enabled
/// MiniMax row from disagreeing with the patch policy.
enum ModelAllowlistMatcher {
    static func allows<S: Sequence>(_ modelRef: String, keys: S) -> Bool where S.Element == String {
        let normalizedModel = normalize(modelRef)
        guard let provider = provider(in: normalizedModel) else { return false }
        return keys.contains { rawKey in
            let key = normalize(rawKey)
            return key == normalizedModel || key == "\(provider)/*"
        }
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    static func isWildcard(_ raw: String) -> Bool {
        normalize(raw).hasSuffix("/*")
    }

    static func wildcardAllows(_ wildcard: String, modelRef: String) -> Bool {
        guard isWildcard(wildcard), let provider = provider(in: normalize(modelRef)) else {
            return false
        }
        return normalize(wildcard) == "\(provider)/*"
    }

    static func canonicalAllowlist(
        _ allowlist: [String: JSONValue]?
    ) -> [String: JSONValue]? {
        guard let allowlist else { return nil }
        var result: [String: JSONValue] = [:]
        for (rawKey, value) in allowlist {
            let key = normalize(rawKey)
            // A case/whitespace collision is malformed rather than equivalent. Returning nil keeps
            // ownership checks conservative and prevents rollback over ambiguous config.
            if result[key] != nil { return nil }
            result[key] = value
        }
        return result
    }

    /// Mirrors pinned upstream `buildAllowedModelSetWithFallbacks` exactly: the configured primary
    /// is implicit for allow-any, an exact-only allowlist, or a wildcard matching its provider. If
    /// any unrelated wildcard is mixed in, exact entries no longer implicitly admit the primary.
    static func primaryIsAllowed(
        _ primaryRef: String,
        allowlist: [String: JSONValue]?
    ) -> Bool {
        let keys = allowlist?.keys.map { $0 } ?? []
        if keys.isEmpty { return true }
        let wildcards = keys.filter(isWildcard)
        let exactCount = keys.count - wildcards.count
        if exactCount > 0, wildcards.isEmpty { return true }
        return wildcards.contains { wildcardAllows($0, modelRef: primaryRef) }
    }

    private static func provider(in normalizedRef: String) -> String? {
        guard let slash = normalizedRef.firstIndex(of: "/"), slash != normalizedRef.startIndex else {
            return nil
        }
        return String(normalizedRef[..<slash])
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// User-facing model/provider copy. Provider transport names are useful in diagnostics, but not in
/// ordinary Settings. Keep this sanitizer at the boundary where gateway-owned catalog names enter
/// the product UI so older gateways with the legacy name remain clean too.
enum ModelUserFacingCopy {
    static func modelName(_ raw: String) -> String {
        var result = raw
            .replacingOccurrences(
                of: #"\s*\(\s*via\s+GMI\s+MaaS\s*\)"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\s+via\s+GMI\s+MaaS"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "GMI MaaS",
                with: "MiniMax",
                options: .caseInsensitive
            )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Model" : result
    }
}

struct GatewayModelSettingsChange: Equatable, Sendable {
    let desiredAllowlist: [String: JSONValue]?
    let patch: [String: JSONValue]
    let mutation: GatewayModelSettingMutation

    /// Whether authoritative config now produces the product setting the user requested. OpenClaw
    /// may normalize model metadata while persisting an allowlist, so acknowledgement must not
    /// require byte-for-byte equality with the submitted values.
    func isEffectivelyConfirmed(by snapshot: GatewayModelSettingsSnapshot) -> Bool {
        switch mutation {
        case .automatic(let enabled):
            return snapshot.automaticEnabled == enabled
        case .miniMax(let enabled):
            return snapshot.miniMaxEnabled == enabled
        }
    }

    /// Whether the complete subtree is still exactly the state this client wrote. This stricter
    /// predicate is reserved for rollback ownership: aliases/params/runtime/streaming values
    /// changed by another device are C, even when C uses the same model refs as desired B.
    func isStillOwned(by snapshot: GatewayModelSettingsSnapshot) -> Bool {
        let desiredConfig = ModelAllowlistMatcher.canonicalAllowlist(desiredAllowlist)
        let actualConfig = ModelAllowlistMatcher.canonicalAllowlist(snapshot.allowlist)
        let configMatches = desiredAllowlist == nil
            ? snapshot.allowlist == nil
            : desiredConfig != nil && desiredConfig == actualConfig
        return configMatches && isEffectivelyConfirmed(by: snapshot)
    }
}

/// Pure transition policy for OpenClaw's allowlist. It owns the important invalid transitions:
/// all-off is impossible, and the configured primary cannot be disabled without changing primary
/// (which this feature intentionally never does).
enum GatewayModelSettingsPolicy {
    static func change(
        from snapshot: GatewayModelSettingsSnapshot,
        mutation: GatewayModelSettingMutation,
        runtimeConfiguredProviderIDs: [String] = []
    ) throws -> GatewayModelSettingsChange? {
        switch mutation {
        case .automatic(let enabled):
            if enabled == snapshot.automaticEnabled { return nil }
            if enabled {
                return makeChange(from: snapshot, desiredAllowlist: nil, mutation: mutation)
            }
            let refs = snapshot.effectiveModelRefs
            guard !refs.isEmpty else { throw GatewayModelSettingsError.noUsableModels }
            return makeChange(
                from: snapshot,
                desiredAllowlist: dictionary(for: refs, preserving: snapshot.allowlist),
                mutation: mutation
            )

        case .miniMax(let enabled):
            guard let miniMaxRef = snapshot.managedModelRef else {
                throw GatewayModelSettingsError.managedModelUnavailable
            }
            if enabled == snapshot.miniMaxEnabled { return nil }
            if !enabled && snapshot.miniMaxIsPrimary {
                throw GatewayModelSettingsError.managedModelIsPrimary
            }

            var desired = snapshot.allowlist ?? dictionary(
                for: snapshot.effectiveModelRefs,
                preserving: nil
            )
            if enabled {
                desired[miniMaxRef] = desired[miniMaxRef] ?? .object([:])
            } else {
                let removedWildcards = desired.keys.filter {
                    ModelAllowlistMatcher.isWildcard($0) &&
                        ModelAllowlistMatcher.wildcardAllows($0, modelRef: miniMaxRef)
                }
                for key in Array(desired.keys) where
                    ModelAllowlistMatcher.matches(key, miniMaxRef) || removedWildcards.contains(key)
                {
                    desired.removeValue(forKey: key)
                }
                // Removing `gmi/*` must not accidentally disable every other model it admitted.
                // Replace that broad grant with concrete non-MiniMax refs from the effective view.
                for choice in snapshot.effectiveModels where
                    !Self.isSameModel(choice.selectionID, miniMaxRef) &&
                    removedWildcards.contains(where: {
                        ModelAllowlistMatcher.wildcardAllows($0, modelRef: choice.selectionID)
                    })
                {
                    desired[choice.selectionID] = desired[choice.selectionID] ?? .object([:])
                }
            }

            // Catalog membership proves only that a model exists. Before removing Rem's managed
            // model, require another remaining catalog row whose provider the active runtime has
            // independently verified as authenticated. Unknown/stale exact refs cannot satisfy
            // this boundary even if they remain in the allowlist.
            let authenticatedProviders = Set(runtimeConfiguredProviderIDs.map {
                ModelPickerPolicy.canonicalProviderID($0)
            })
            let hasAuthenticatedRemainingModel = snapshot.configuredModels.contains { choice in
                guard ModelAllowlistMatcher.allows(choice.selectionID, keys: desired.keys),
                      !GatewayModelSettingsSnapshot.isMiniMax(choice)
                else { return false }
                let provider = ModelPickerPolicy.canonicalProviderID(choice.provider)
                return !provider.isEmpty && authenticatedProviders.contains(provider)
            }
            guard hasAuthenticatedRemainingModel else {
                throw GatewayModelSettingsError.noUsableModels
            }

            return makeChange(
                from: snapshot,
                desiredAllowlist: desired,
                mutation: mutation
            )
        }
    }

    private static func isSameModel(_ lhs: String, _ rhs: String) -> Bool {
        ModelAllowlistMatcher.matches(lhs, rhs)
    }

    static func restoreChange(
        current: GatewayModelSettingsSnapshot,
        originalAllowlist: [String: JSONValue]?
    ) -> GatewayModelSettingsChange {
        makeChange(
            from: current,
            desiredAllowlist: originalAllowlist,
            mutation: .automatic(originalAllowlist?.isEmpty != false)
        )
    }

    private static func dictionary(
        for refs: Set<String>,
        preserving existing: [String: JSONValue]?
    ) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: refs.map { ref in
            (ref, existing?[ref] ?? .object([:]))
        })
    }

    private static func makeChange(
        from snapshot: GatewayModelSettingsSnapshot,
        desiredAllowlist: [String: JSONValue]?,
        mutation: GatewayModelSettingMutation
    ) -> GatewayModelSettingsChange {
        let modelPatch: JSONValue
        if let desiredAllowlist {
            var entries: [String: JSONValue] = [:]
            let current = snapshot.allowlist ?? [:]
            for removed in Set(current.keys).subtracting(desiredAllowlist.keys) {
                entries[removed] = .null
            }
            for (ref, value) in desiredAllowlist where current[ref] != value {
                entries[ref] = value
            }
            modelPatch = .object(entries)
        } else {
            modelPatch = .null
        }
        return GatewayModelSettingsChange(
            desiredAllowlist: desiredAllowlist,
            patch: [
                "agents": .object([
                    "defaults": .object([
                        "models": modelPatch,
                    ]),
                ]),
            ],
            mutation: mutation
        )
    }
}

/// RPC lifecycle for a model-setting mutation.
///
/// - Reads a fresh hash immediately before every write.
/// - Reconciles an ambiguous/conflicting first failure against authoritative state, then retries
///   once with the fresh hash instead of parsing human error strings.
/// - Waits for short authoritative config readback after upstream's hot reload.
/// - Best-effort restores the original allowlist if authoritative verification never converges.
@MainActor
struct GatewayModelSettingsClient {
    typealias Request = @MainActor (_ method: String, _ paramsJSON: String?, _ timeout: Int) async throws -> Data
    typealias Sleep = @MainActor (_ duration: Duration) async -> Void

    let request: Request
    var sleep: Sleep = { duration in try? await Task.sleep(for: duration) }

    func load(
        runtimeConfiguredProviderIDs: [String] = []
    ) async throws -> GatewayModelSettingsSnapshot {
        try Task.checkCancellation()
        let configData = try await request("config.get", "{}", 15)
        try Task.checkCancellation()
        let config = try JSONDecoder().decode(ConfigGetResponse.self, from: configData)
        // Prime the gateway's complete catalog snapshot before asking it to filter the configured
        // view. Modern gateways can reuse that prepared snapshot without repeating discovery;
        // default chat catalog requests keep their independent, bounded read-only path.
        let prefetchedAllModelsData: Data?
        do {
            prefetchedAllModelsData = try await request(
                "models.list",
                #"{"view":"all"}"#,
                15
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            prefetchedAllModelsData = nil
        }
        try Task.checkCancellation()
        let effectiveModelsData: Data
        do {
            effectiveModelsData = try await request("models.list", #"{"view":"configured"}"#, 15)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // `view` was added after the base models.list RPC. Older gateways already return their
            // configured/visible catalog by default, so retry without the new parameter.
            try Task.checkCancellation()
            effectiveModelsData = try await request("models.list", nil, 15)
        }
        try Task.checkCancellation()
        let allModelsData: Data
        let allCatalogUsesEffectiveFallback: Bool
        if let prefetchedAllModelsData {
            allModelsData = prefetchedAllModelsData
            allCatalogUsesEffectiveFallback = false
        } else {
            // Pre-view gateways still return the positive, currently effective catalog from the
            // original RPC. It is insufficient mutation authority because a disabled model can be
            // absent, but it remains useful read authority: config can truthfully show Automatic
            // and exact provider/config evidence can show the managed model. Preserve that state
            // as legacy read-only instead of replacing the whole page with an error.
            allModelsData = effectiveModelsData
            allCatalogUsesEffectiveFallback = true
        }
        let effectivePayload = try JSONDecoder().decode(ModelsListPayload.self, from: effectiveModelsData)
        let allPayload = try JSONDecoder().decode(ModelsListPayload.self, from: allModelsData)
        let catalogAuthority: GatewayModelCatalogAuthority
        if !allCatalogUsesEffectiveFallback,
           allPayload.catalogComplete == true,
           effectivePayload.catalogComplete == true
        {
            catalogAuthority = .completeMutable
        } else {
            // An unsupported full-catalog view, a pre-completeness response, or an explicitly
            // partial catalog can all provide useful positive rows and config state. None can
            // prove an omission or authorize a write, so present the state read-only and keep
            // every mutation disabled until both views affirm completeness.
            catalogAuthority = .legacyReadOnly
        }
        let makeChoices: (ModelsListPayload) -> [OpenClawChatModelChoice] = { payload in
            payload.models.map { item in
                OpenClawChatModelChoice(
                    modelID: item.id,
                    name: ModelUserFacingCopy.modelName(item.name),
                    provider: item.provider,
                    contextWindow: item.contextwindow ?? 0
                )
            }
        }
        let allChoices = makeChoices(allPayload)
        guard !allChoices.isEmpty || catalogAuthority == .legacyReadOnly else {
            // A successful response with no catalog is still unusable: the picker cannot prove
            // which models can be enabled, even when the current primary identifies MiniMax.
            throw GatewayModelSettingsError.fullCatalogUnavailable
        }
        let legacyManagedModelRef = authorizedManagedModelRef(
            from: config,
            configuredModels: allChoices,
            catalogAuthority: catalogAuthority,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
        )
        return GatewayModelSettingsSnapshot(
            baseHash: config.patchBaseHash,
            primaryModelRef: config.config?.agents?.defaults?.primaryModelRef,
            allowlist: config.config?.agents?.defaults?.models,
            configuredModels: allChoices,
            effectiveModels: makeChoices(effectivePayload),
            catalogAuthority: catalogAuthority,
            legacyManagedModelRef: legacyManagedModelRef
        )
    }

    /// The active runtime's positive authentication evidence is mandatory in every catalog mode.
    /// Complete catalogs may then prove exact identity by catalog membership; legacy catalogs may
    /// only use exact config structure because their rows can be partial or stale.
    private func authorizedManagedModelRef(
        from response: ConfigGetResponse,
        configuredModels: [OpenClawChatModelChoice],
        catalogAuthority: GatewayModelCatalogAuthority,
        runtimeConfiguredProviderIDs: [String]
    ) -> String? {
        let authenticatedProviders = Set(runtimeConfiguredProviderIDs.map {
            ModelPickerPolicy.canonicalProviderID($0)
        })
        guard authenticatedProviders.contains(
            ModelPickerPolicy.canonicalProviderID(GatewayModelSettingsSnapshot.managedProviderID)
        ) else { return nil }

        if catalogAuthority == .completeMutable {
            if response.config?.agents?.defaults?.primaryModelRef
                .map(GatewayModelSettingsSnapshot.isManagedMiniMaxRef) == true
            {
                return GatewayModelSettingsSnapshot.managedSelectionID
            }
            let candidates = configuredModels.filter(GatewayModelSettingsSnapshot.isMiniMax)
            guard candidates.count == 1 else { return nil }
            return candidates[0].selectionID
        }

        if response.config?.agents?.defaults?.primaryModelRef
            .map(GatewayModelSettingsSnapshot.isManagedMiniMaxRef) == true
        {
            return GatewayModelSettingsSnapshot.managedSelectionID
        }

        guard let providers = response.config?.models?.providers else { return nil }
        let matchingProviders = providers.filter { rawID, _ in
            ModelPickerPolicy.canonicalProviderID(rawID) ==
                ModelPickerPolicy.canonicalProviderID(GatewayModelSettingsSnapshot.managedProviderID)
        }
        guard matchingProviders.count == 1,
              case .object(let provider)? = matchingProviders.first?.value,
              case .array(let models)? = provider["models"]
        else { return nil }

        let matchingModels = models.filter { value in
            guard case .object(let model) = value,
                  case .string(let rawID)? = model["id"] else { return false }
            return rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
                GatewayModelSettingsSnapshot.managedModelID.lowercased()
        }
        guard matchingModels.count == 1 else { return nil }
        return GatewayModelSettingsSnapshot.managedSelectionID
    }

    func apply(
        _ mutation: GatewayModelSettingMutation,
        to _: GatewayModelSettingsSnapshot,
        runtimeConfiguredProviderIDs: [String] = []
    ) async throws -> GatewayModelSettingsSnapshot {
        try Task.checkCancellation()
        // The screen snapshot can be old if another signed-in device changed this gateway. Always
        // establish both the rollback point and the patch base from a read immediately before write.
        let original = try await load(
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
        )
        guard original.catalogAuthority.canMutate else {
            throw GatewayModelSettingsError.legacyCatalogReadOnly
        }
        guard var activeChange = try GatewayModelSettingsPolicy.change(
            from: original,
            mutation: mutation,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
        ) else {
            return original
        }

        var base = original
        for attemptIndex in 0..<2 {
            try Task.checkCancellation()
            switch try await attempt(
                activeChange,
                from: base,
                runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
            ) {
            case .confirmed(let snapshot):
                return snapshot
            case .notApplied(let authoritative):
                guard attemptIndex == 0, let authoritative else {
                    throw GatewayModelSettingsError.verificationFailed
                }
                guard let rebased = try GatewayModelSettingsPolicy.change(
                    from: authoritative,
                    mutation: mutation,
                    runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
                ) else {
                    return authoritative
                }
                activeChange = rebased
                base = authoritative
            case .appliedButUnverified(let authoritative):
                try await rollbackIfStillOwned(
                    activeChange,
                    attemptBaseAllowlist: base.allowlist,
                    observed: authoritative,
                    runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
                )
                throw GatewayModelSettingsError.verificationFailed
            }
        }
        throw GatewayModelSettingsError.verificationFailed
    }

    private enum AttemptOutcome {
        case confirmed(GatewayModelSettingsSnapshot)
        case notApplied(GatewayModelSettingsSnapshot?)
        case appliedButUnverified(GatewayModelSettingsSnapshot?)
    }

    private func attempt(
        _ change: GatewayModelSettingsChange,
        from base: GatewayModelSettingsSnapshot,
        runtimeConfiguredProviderIDs: [String]
    ) async throws -> AttemptOutcome {
        try Task.checkCancellation()
        do {
            try await write(change, baseHash: base.baseHash)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            // `config.patch` can persist and then replace the operator socket before its reply is
            // delivered. A transport failure is therefore an ambiguous acknowledgement, while a
            // structured gateway rejection is definitive and can proceed directly to the single
            // authoritative rebase read. Confirm against config only: reloading both catalogs here
            // can turn a bounded recovery into several minutes of stacked RPC timeouts.
            try Task.checkCancellation()
            if !(error is GatewayResponseError) {
                if let verified = try await waitForConfirmation(
                    change,
                    from: base,
                    runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
                ) {
                    return .confirmed(verified)
                }
            }
            try Task.checkCancellation()
            let readback: GatewayModelSettingsSnapshot?
            do {
                readback = try await load(
                    runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                readback = nil
            }
            if let readback, change.isEffectivelyConfirmed(by: readback) {
                return .confirmed(readback)
            }
            return .notApplied(readback)
        }

        try Task.checkCancellation()
        if let verified = try await waitForConfirmation(
            change,
            from: base,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
        ) {
            return .confirmed(verified)
        }
        try Task.checkCancellation()
        let readback = try? await load(runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs)
        if let readback, change.isEffectivelyConfirmed(by: readback) {
            return .confirmed(readback)
        }
        return .appliedButUnverified(readback)
    }

    private func rollbackIfStillOwned(
        _ change: GatewayModelSettingsChange,
        attemptBaseAllowlist: [String: JSONValue]?,
        observed: GatewayModelSettingsSnapshot?,
        runtimeConfiguredProviderIDs: [String]
    ) async throws {
        try Task.checkCancellation()
        let current: GatewayModelSettingsSnapshot?
        if let observed {
            current = observed
        } else {
            current = try? await load(
                runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
            )
        }
        // If another device has already moved B to C, this client no longer owns the state and must
        // never restore A over C. Rollback is legal only while config still exactly represents B.
        guard let current, change.isStillOwned(by: current) else { return }
        let rollback = GatewayModelSettingsPolicy.restoreChange(
            current: current,
            originalAllowlist: attemptBaseAllowlist
        )
        try Task.checkCancellation()
        guard (try? await write(rollback, baseHash: current.baseHash)) != nil else { return }
        try Task.checkCancellation()
        _ = try await waitForConfirmation(
            rollback,
            from: current,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
        )
    }

    private func waitForConfirmation(
        _ change: GatewayModelSettingsChange,
        from base: GatewayModelSettingsSnapshot,
        runtimeConfiguredProviderIDs: [String]
    ) async throws -> GatewayModelSettingsSnapshot? {
        // A managed gateway may briefly replace its operator socket while activating a config
        // patch. Keep the UI pending through a short config-only recovery instead of issuing a
        // duplicate write or stacking full catalog discovery timeouts.
        let delays: [Duration] = [
            .zero,
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
        ]
        for delay in delays {
            if delay != .zero { await sleep(delay) }
            try Task.checkCancellation()
            do {
                let snapshot = try await loadConfigProjection(
                    from: base,
                    runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
                )
                if change.isEffectivelyConfirmed(by: snapshot) { return snapshot }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    /// Projects fresh config over the already-authoritative complete catalog used to authorize the
    /// mutation. Config patches in this surface only change `agents.defaults.models`, so catalog
    /// rediscovery is unnecessary for acknowledgement and would greatly extend the failure path.
    private func loadConfigProjection(
        from base: GatewayModelSettingsSnapshot,
        runtimeConfiguredProviderIDs: [String]
    ) async throws -> GatewayModelSettingsSnapshot {
        let configData = try await request("config.get", "{}", 3)
        try Task.checkCancellation()
        let config = try JSONDecoder().decode(ConfigGetResponse.self, from: configData)
        let allowlist = config.config?.agents?.defaults?.models
        let primary = config.config?.agents?.defaults?.primaryModelRef
        let effectiveModels: [OpenClawChatModelChoice]
        if let allowlist, !allowlist.isEmpty {
            effectiveModels = base.configuredModels.filter { choice in
                ModelAllowlistMatcher.allows(choice.selectionID, keys: allowlist.keys) ||
                    (primary.map { ModelAllowlistMatcher.matches($0, choice.selectionID) } == true &&
                        primary.map {
                            ModelAllowlistMatcher.primaryIsAllowed($0, allowlist: allowlist)
                        } == true)
            }
        } else {
            effectiveModels = base.configuredModels
        }
        let managedModelRef = authorizedManagedModelRef(
            from: config,
            configuredModels: base.configuredModels,
            catalogAuthority: base.catalogAuthority,
            runtimeConfiguredProviderIDs: runtimeConfiguredProviderIDs
        )
        return GatewayModelSettingsSnapshot(
            baseHash: config.patchBaseHash,
            primaryModelRef: primary,
            allowlist: allowlist,
            configuredModels: base.configuredModels,
            effectiveModels: effectiveModels,
            catalogAuthority: base.catalogAuthority,
            legacyManagedModelRef: managedModelRef
        )
    }

    private func write(_ change: GatewayModelSettingsChange, baseHash: String?) async throws {
        try Task.checkCancellation()
        guard let baseHash, !baseHash.isEmpty else {
            throw GatewayModelSettingsError.missingConfigHash
        }
        let rawData = try JSONEncoder().encode(change.patch)
        guard let raw = String(data: rawData, encoding: .utf8) else {
            throw GatewayModelSettingsError.verificationFailed
        }
        let params = ConfigPatchParams(raw: raw, baseHash: baseHash)
        let data = try JSONEncoder().encode(params)
        guard let paramsJSON = String(data: data, encoding: .utf8) else {
            throw GatewayModelSettingsError.verificationFailed
        }
        try Task.checkCancellation()
        _ = try await request("config.patch", paramsJSON, 20)
    }
}

struct ModelsListPayload: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: String
        let name: String
        let provider: String
        let contextwindow: Int?
    }

    let models: [Item]
    let catalogComplete: Bool?
    let catalogSource: String?
}
