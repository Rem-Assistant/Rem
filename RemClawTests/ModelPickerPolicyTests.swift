import Foundation
import Testing
import OpenClawChatUI
import OpenClawKit
@testable import RemClaw

@MainActor
struct ModelPickerPolicyTests {
    @Test func runtimeAuthEvidenceDistinguishesUnknownFromVerifiedEmptyAndRetainsPrior() {
        let loadingUnknown = RuntimeProviderAuthEvidence.loading(lastVerifiedProviderIDs: nil)
        let failedUnknown = RuntimeProviderAuthEvidence.failed(lastVerifiedProviderIDs: nil)
        let verifiedEmpty = RuntimeProviderAuthEvidence.verified([])
        let loadingWithPrior = RuntimeProviderAuthEvidence.loading(
            lastVerifiedProviderIDs: ["anthropic"])
        let failedWithPrior = RuntimeProviderAuthEvidence.failed(
            lastVerifiedProviderIDs: ["anthropic"])

        #expect(!loadingUnknown.hasAuthoritativeSnapshot)
        #expect(!failedUnknown.hasAuthoritativeSnapshot)
        #expect(verifiedEmpty.hasAuthoritativeSnapshot)
        #expect(verifiedEmpty.effectiveProviderIDs == [])
        #expect(loadingWithPrior.effectiveProviderIDs == ["anthropic"])
        #expect(failedWithPrior.effectiveProviderIDs == ["anthropic"])
        #expect(loadingUnknown.modelSettingsState == .loading)
        #expect(failedUnknown.modelSettingsState == .unavailable)
        #expect(verifiedEmpty.modelSettingsState == .available([]))
        #expect(loadingWithPrior.modelSettingsState == .available(["anthropic"]))
        #expect(failedWithPrior.modelSettingsState == .available(["anthropic"]))
    }

    @Test func legacyPartialEvidencePresentsPositiveRowsWithoutResettingOmissions() {
        let partial = RuntimeProviderAuthEvidence.legacyPartial(["openai"])

        #expect(!partial.hasAuthoritativeSnapshot)
        #expect(partial.canLoadModelSettings)
        #expect(partial.canPresentProviderMenus)
        #expect(partial.effectiveProviderIDs == ["openai"])
        #expect(partial.modelSettingsState == .available(["openai"]))
        #expect(partial.canReconcileExplicitSelection("openai/gpt-5"))
        #expect(partial.canReconcileExplicitSelection("gmi/MiniMaxAI/MiniMax-M2.7"))
        #expect(!partial.canReconcileExplicitSelection("anthropic/claude-sonnet-4-5"))
        #expect(partial.canReconcileExplicitSelection(
            OpenClawChatViewModel.defaultModelSelectionID
        ))
    }

    @Test func legacyPartialLoadFailureDoesNotBecomeVerifiedEmpty() {
        let partial = RuntimeProviderAuthEvidence.resolvingLoadFailure(
            RuntimeProviderAuthPartialEvidence(providerIDs: []),
            priorSameScopeEvidence: .verified(["anthropic"])
        )

        #expect(partial == .legacyPartial([]))
        #expect(!partial.hasAuthoritativeSnapshot)
        #expect(partial.beginningSameScopeRefresh == partial)
        #expect(RuntimeProviderAuthEvidence.resolvingLoadFailure(
            URLError(.timedOut),
            priorSameScopeEvidence: partial
        ) == partial)
    }

    @Test func explicitSelectionSuppliesAuthProbeWhenModelsListIsEmpty() {
        #expect(ModelPickerPolicy.providerIDsForRuntimeEvidence(
            models: [],
            requestedSelectionID: "anthropic/claude-opus-4-6") == ["anthropic"])
        #expect(ModelPickerPolicy.providerIDsForRuntimeEvidence(
            models: [],
            requestedSelectionID: OpenClawChatViewModel.defaultModelSelectionID).isEmpty)
    }

    @Test func modelCatalogWireMetadataDistinguishesConfiguredFallbackFromCompleteDiscovery() throws {
        let degradedJSON = """
        {
          "models": [{"id": "managed", "name": "Managed", "provider": "gmi"}],
          "catalogComplete": false,
          "catalogSource": "configured-fallback"
        }
        """
        let degraded = try JSONDecoder().decode(
            ModelsListPayload.self,
            from: Data(degradedJSON.utf8))
        let legacy = try JSONDecoder().decode(
            ModelsListPayload.self,
            from: Data(#"{"models":[]}"#.utf8))

        #expect(degraded.catalogComplete == false)
        #expect(degraded.catalogSource == "configured-fallback")
        #expect(legacy.catalogComplete == nil)
        #expect(legacy.catalogSource == nil)
    }

    @Test func iOSTransportPreservesCatalogCompletenessTriState() throws {
        let complete = try IOSGatewayChatTransport.decodeModelCatalog(
            from: Data(#"{"models":[],"catalogComplete":true}"#.utf8))
        let incomplete = try IOSGatewayChatTransport.decodeModelCatalog(
            from: Data(#"{"models":[],"catalogComplete":false}"#.utf8))
        let legacyUnknown = try IOSGatewayChatTransport.decodeModelCatalog(
            from: Data(#"{"models":[]}"#.utf8))

        #expect(complete.completeness == .complete)
        #expect(incomplete.completeness == .incomplete)
        #expect(legacyUnknown.completeness == .unknown)
    }

    @Test func verifiedExplicitProviderSurvivesIncompleteCatalogThroughSendSelectionPolicy() {
        let explicitSelection = "anthropic/claude-opus-4-6"

        let selectionPassedToSend = ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: explicitSelection,
            models: [miniMax],
            catalogCompleteness: .incomplete,
            runtimeConfiguredProviderIDs: ["anthropic"],
            defaultModelLabel: "Default")
        let unavailableSelection = ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: explicitSelection,
            models: [miniMax],
            catalogCompleteness: .incomplete,
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default")
        let authoritativeCatalogMiss = ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: explicitSelection,
            models: [miniMax],
            catalogCompleteness: .complete,
            runtimeConfiguredProviderIDs: ["anthropic"],
            defaultModelLabel: "Default")
        let legacyUnknownCatalog = ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: explicitSelection,
            models: [miniMax],
            catalogCompleteness: .unknown,
            runtimeConfiguredProviderIDs: ["anthropic"],
            defaultModelLabel: "Default")

        #expect(selectionPassedToSend == explicitSelection)
        #expect(unavailableSelection == OpenClawChatViewModel.defaultModelSelectionID)
        #expect(authoritativeCatalogMiss == OpenClawChatViewModel.defaultModelSelectionID)
        #expect(legacyUnknownCatalog == explicitSelection)
    }

    @Test func sharedComposerAllowsOnlyExactSessionCommandsWithoutAuthOrQuota() {
        for command in ["/new", "/reset", "/clear", "/compact", "  /RESET\n"] {
            #expect(ChatComposerSendPolicy.canSend(
                input: command,
                hasAuthoritativeProviderEvidence: false,
                requiresProviderEvidence: true,
                isPreparingSend: false,
                viewModelCanSend: true,
                browserCapabilityAttached: false))
            #expect(ChatComposerSendPolicy.hasRequiredQuota(input: command, hasQuota: false))
        }

        for message in ["hello", "/reset now", "/compact please"] {
            #expect(!ChatComposerSendPolicy.canSend(
                input: message,
                hasAuthoritativeProviderEvidence: false,
                requiresProviderEvidence: true,
                isPreparingSend: false,
                viewModelCanSend: true,
                browserCapabilityAttached: false))
            #expect(!ChatComposerSendPolicy.hasRequiredQuota(input: message, hasQuota: false))
        }
    }

    @Test func automaticChatDoesNotDependOnOptionalProviderEvidence() {
        #expect(ChatComposerSendPolicy.canSend(
            input: "Plan my day",
            hasAuthoritativeProviderEvidence: false,
            requiresProviderEvidence: false,
            isPreparingSend: false,
            viewModelCanSend: true,
            browserCapabilityAttached: false))
        #expect(ChatComposerSendPolicy.canSend(
            input: "",
            hasAuthoritativeProviderEvidence: false,
            requiresProviderEvidence: false,
            isPreparingSend: false,
            viewModelCanSend: false,
            browserCapabilityAttached: true))
        #expect(!ChatComposerSendPolicy.canSend(
            input: "Plan my day",
            hasAuthoritativeProviderEvidence: false,
            requiresProviderEvidence: true,
            isPreparingSend: false,
            viewModelCanSend: true,
            browserCapabilityAttached: false))
    }

    @Test func persistedExplicitSelectionCanAlwaysOpenAutomaticEscape() {
        #expect(ChatComposerSendPolicy.canOpenModelPicker(
            isPreparingSend: false,
            isSending: false))
        #expect(!ChatComposerSendPolicy.canOpenModelPicker(
            isPreparingSend: true,
            isSending: false))
        #expect(!ChatComposerSendPolicy.canOpenModelPicker(
            isPreparingSend: false,
            isSending: true))

        #expect(ModelPickerPolicy.composerGroups(
            [miniMax],
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default",
            hasAuthoritativeProviderEvidence: false).isEmpty)
    }

    private let miniMax = OpenClawChatModelChoice(
        modelID: "MiniMaxAI/MiniMax-M2.7",
        name: "MiniMax M2.7",
        provider: "gmi",
        contextWindow: 196_608)
    private let staleSonnet = OpenClawChatModelChoice(
        modelID: "claude-sonnet-4-5",
        name: "Claude Sonnet 4.5",
        provider: "anthropic",
        contextWindow: 200_000)
    private let directMiniMax = OpenClawChatModelChoice(
        modelID: "MiniMax-M2.7",
        name: "MiniMax M2.7",
        provider: "minimax",
        contextWindow: 196_608)

    @Test func composerTitleReflectsAutomaticAndExplicitSelection() {
        #expect(ModelPickerPresentation.composerTitle(
            selectionID: OpenClawChatViewModel.defaultModelSelectionID,
            models: [miniMax, staleSonnet]) == "Automatic")
        #expect(ModelPickerPresentation.composerTitle(
            selectionID: staleSonnet.selectionID,
            models: [miniMax, staleSonnet]) == "Claude Sonnet 4.5")
        #expect(ModelPickerPresentation.composerTitle(
            selectionID: "openai/gpt-5-5",
            models: []) == "gpt 5 5")
    }

    @Test func composerGroupsOnlyUsableProvidersAndSortsModels() {
        let olderSonnet = OpenClawChatModelChoice(
            modelID: "claude-sonnet-4-0",
            name: "Claude Sonnet 4.0",
            provider: "anthropic",
            contextWindow: 100_000)
        let groups = ModelPickerPolicy.composerGroups(
            [staleSonnet, miniMax, olderSonnet],
            runtimeConfiguredProviderIDs: ["anthropic"],
            defaultModelLabel: "Default: gmi/MiniMaxAI/MiniMax-M2.7")

        #expect(groups.map(\.provider) == ["Claude", "MiniMax"])
        #expect(groups[0].models.map(\.name) == ["Claude Sonnet 4.0", "Claude Sonnet 4.5"])
        #expect(groups[1].models.map(\.selectionID) == [miniMax.selectionID])
    }

    @Test func composerDoesNotExposeManagedProviderSiblingModels() {
        let managedSibling = OpenClawChatModelChoice(
            modelID: "SomeOtherManagedModel",
            name: "Some Other Managed Model",
            provider: "gmi",
            contextWindow: 32_000)

        let visible = ModelPickerPolicy.composerModels(
            [managedSibling, miniMax],
            runtimeConfiguredProviderIDs: ["gmi"],
            defaultModelLabel: "Default: gmi/MiniMaxAI/MiniMax-M2.7")

        #expect(visible.map(\.selectionID) == [miniMax.selectionID])
    }

    @Test func staleManagedSiblingDefaultCannotBypassMiniMaxFilter() {
        let managedSibling = OpenClawChatModelChoice(
            modelID: "claude-sonnet-4-5",
            name: "Claude Sonnet 4.5",
            provider: "gmi",
            contextWindow: 200_000)

        let visible = ModelPickerPolicy.composerModels(
            [managedSibling, miniMax],
            runtimeConfiguredProviderIDs: ["gmi"],
            defaultModelLabel: "Default: \(managedSibling.selectionID)")

        #expect(visible.map(\.selectionID) == [miniMax.selectionID])
    }

    @Test func resolvesManagedDefaultToHumanName() {
        #expect(ModelPickerPolicy.resolvedDefaultName(
            defaultModelLabel: "Default: gmi/MiniMaxAI/MiniMax-M2.7",
            models: [miniMax, staleSonnet]) == "MiniMax M2.7")
    }

    @Test func hidesProviderWithoutRuntimeAuthentication() {
        let visible = ModelPickerPolicy.composerModels(
            [miniMax, staleSonnet],
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default: gmi/MiniMaxAI/MiniMax-M2.7")

        #expect(visible.map(\.selectionID) == [miniMax.selectionID])
    }

    @Test func preservesProviderWhenRuntimeReportsAuthentication() {
        let visible = ModelPickerPolicy.composerModels(
            [miniMax, staleSonnet],
            runtimeConfiguredProviderIDs: ["anthropic"],
            defaultModelLabel: "Default: gmi/MiniMaxAI/MiniMax-M2.7")

        #expect(Set(visible.map(\.selectionID)) == Set([miniMax.selectionID, staleSonnet.selectionID]))
    }

    @Test func settingsPreserveProviderWhenRuntimeReportsAuthentication() {
        let hidden = ModelPickerPolicy.settingsModels(
            [miniMax, staleSonnet],
            runtimeConfiguredProviderIDs: [])
        let visible = ModelPickerPolicy.settingsModels(
            [miniMax, staleSonnet],
            runtimeConfiguredProviderIDs: ["anthropic"])

        #expect(hidden.map(\.selectionID) == [miniMax.selectionID])
        #expect(Set(visible.map(\.selectionID)) == Set([miniMax.selectionID, staleSonnet.selectionID]))
    }

    @Test func derivesStableRuntimeProviderIDsOnlyFromAvailableAuthSignals() {
        #expect(ModelPickerPolicy.runtimeAvailableProviderIDs(from: [
            .init(provider: "OpenAI", available: false),
            .init(provider: " Anthropic ", available: true),
            .init(provider: "anthropic", available: true),
        ]) == ["anthropic"])
    }

    @Test func canonicalizesCatalogAndRuntimeProviderAliasesThroughOnePolicy() {
        #expect(ModelPickerPolicy.canonicalProviderID(" z.ai ") == "zai")
        #expect(ModelPickerPolicy.canonicalProviderID("qwencloud") == "qwen")
        #expect(ModelPickerPolicy.canonicalProviderID("aws-bedrock") == "amazon-bedrock")
        #expect(ModelPickerPolicy.canonicalProviderID("google-generative-ai") == "google")

        for (catalogProvider, runtimeProvider) in [
            ("z.ai", "zai"),
            ("qwencloud", "qwen"),
            ("aws-bedrock", "amazon-bedrock"),
            ("google-generative-ai", "google"),
        ] {
            #expect(ModelPickerPolicy.isProviderUsable(
                catalogProvider,
                runtimeConfiguredProviderIDs: [runtimeProvider]
            ))
        }
    }

    @Test func decodesStructuredProviderAuthAvailabilityResponse() throws {
        let data = Data(
            #"{"ts":1,"providers":[{"provider":"openai","available":false},{"provider":"anthropic","available":true}]}"#.utf8
        )
        let payload = try JSONDecoder().decode(ProviderAuthAvailabilityPayload.self, from: data)

        #expect(ModelPickerPolicy.runtimeAvailableProviderIDs(from: payload.providers) == ["anthropic"])
    }

    @Test func olderGatewayAuthStatusAuthorizesOnlyHealthyRequestedProviders() throws {
        let data = Data(
            #"{"ts":1,"providers":[{"provider":"GMI","displayName":"GMI","status":"static","profiles":[]},{"provider":"anthropic","displayName":"Anthropic","status":"expired","profiles":[]},{"provider":"openai","displayName":"OpenAI","status":"ok","profiles":[]},{"provider":"google","displayName":"Google","status":"expiring","profiles":[]},{"provider":"unrequested","displayName":"Other","status":"static","profiles":[]}]}"#.utf8
        )
        let payload = try JSONDecoder().decode(ProviderAuthStatusPayload.self, from: data)

        #expect(ProviderAuthCompatibilityPolicy.runtimeAvailableProviderIDs(
            from: payload.providers,
            candidates: ["gmi", "anthropic", "openai", "google"]
        ) == ["gmi", "google", "openai"])
    }

    @Test func olderGatewayFallbackRequiresExactStructuredMethodRejection() {
        #expect(ProviderAuthCompatibilityPolicy.legacyAuthStatusParamsJSON == nil)
        let eligible = GatewayResponseError(
            method: "models.authAvailability",
            code: "INVALID_REQUEST",
            message: "unknown method",
            details: nil
        )
        #expect(ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
            after: eligible,
            gatewayProvider: .fly
        ))
        #expect(!ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
            after: eligible,
            gatewayProvider: .local
        ))
        #expect(!ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
            after: eligible,
            gatewayProvider: .manual
        ))
        #expect(!ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
            after: eligible,
            gatewayProvider: nil
        ))
        #expect(!ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
            after:
            GatewayResponseError(
                method: "models.authAvailability",
                code: "UNAVAILABLE",
                message: "gateway timed out",
                details: nil
            ),
            gatewayProvider: .fly
        ))
        #expect(!ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
            after:
            GatewayResponseError(
                method: "models.authStatus",
                code: "INVALID_REQUEST",
                message: "bad request",
                details: nil
            ),
            gatewayProvider: .fly
        ))
        #expect(!ProviderAuthCompatibilityPolicy.shouldUseAuthStatusFallback(
            after: CancellationError(),
            gatewayProvider: .fly
        ))
    }

    @Test func olderGatewayAuthStatusDoesNotAuthorizeMissingOrUnknownStatuses() {
        let providers = [
            ProviderAuthStatusPayload.Provider(provider: "openai", status: "missing"),
            ProviderAuthStatusPayload.Provider(provider: "anthropic", status: "future-status"),
        ]

        #expect(ProviderAuthCompatibilityPolicy.runtimeAvailableProviderIDs(
            from: providers,
            candidates: ["openai", "anthropic"]
        ).isEmpty)
    }

    @Test func unavailableAuthSignalDoesNotAuthorizeProviderMenus() {
        let visible = ModelPickerPolicy.composerModels(
            [staleSonnet, miniMax],
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default: anthropic/claude-sonnet-4-5")
        let groups = ModelPickerPolicy.composerGroups(
            [staleSonnet, miniMax],
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default: anthropic/claude-sonnet-4-5")
        let settingsModels = ModelPickerPolicy.settingsModels(
            [staleSonnet, miniMax],
            runtimeConfiguredProviderIDs: [])

        #expect(visible.map(\.selectionID) == [miniMax.selectionID])
        #expect(groups.map(\.provider) == ["MiniMax"])
        #expect(settingsModels.map(\.selectionID) == [miniMax.selectionID])
    }

    @Test func unavailableExplicitSelectionFailsClosedToAutomatic() {
        #expect(ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: staleSonnet.selectionID,
            models: [staleSonnet, miniMax],
            catalogCompleteness: .complete,
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default: anthropic/claude-sonnet-4-5"
        ) == OpenClawChatViewModel.defaultModelSelectionID)
        #expect(ModelPickerPolicy.effectiveSelectionID(
            requestedSelectionID: staleSonnet.selectionID,
            models: [staleSonnet, miniMax],
            catalogCompleteness: .complete,
            runtimeConfiguredProviderIDs: ["anthropic"],
            defaultModelLabel: "Default: anthropic/claude-sonnet-4-5"
        ) == staleSonnet.selectionID)
    }

    @Test func gmiAndDirectProviderShareMiniMaxPresentation() {
        #expect(ModelProviderDisplay.name(for: miniMax.provider) == "MiniMax")
        #expect(ModelProviderDisplay.name(for: directMiniMax.provider) == "MiniMax")
        #expect(ModelPickerPolicy.relevantProviderNames(runtimeConfiguredProviderIDs: []) == ["MiniMax"])
        #expect(ModelPickerPolicy.isProviderUsable("gmi", runtimeConfiguredProviderIDs: []))
        #expect(!ModelPickerPolicy.isProviderUsable("minimax", runtimeConfiguredProviderIDs: []))
    }

    @Test func defaultModelDoesNotAuthorizeAnUnavailableProvider() {
        let custom = OpenClawChatModelChoice(
            modelID: "custom-v1",
            name: "Custom V1",
            provider: "private-provider",
            contextWindow: 32_000)
        #expect(ModelPickerPolicy.composerModels(
            [miniMax, custom],
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default: private-provider/custom-v1") == [miniMax])
        #expect(ModelPickerPolicy.composerModels(
            [miniMax, custom],
            runtimeConfiguredProviderIDs: ["private-provider"],
            defaultModelLabel: "Default: private-provider/custom-v1") == [miniMax, custom])
        #expect(ModelPickerPolicy.composerModels(
            [staleSonnet],
            runtimeConfiguredProviderIDs: [],
            defaultModelLabel: "Default").isEmpty)
    }

    @Test func credentialAliasesDoNotGrantDifferentAuthSchemes() {
        #expect(ModelPickerPolicy.isProviderUsable(
            "google-generative-ai", runtimeConfiguredProviderIDs: ["google"]))
        #expect(!ModelPickerPolicy.isProviderUsable(
            "google-vertex", runtimeConfiguredProviderIDs: ["google"]))
        #expect(ModelPickerPolicy.isProviderUsable("openai", runtimeConfiguredProviderIDs: ["openai"]))
        #expect(!ModelPickerPolicy.isProviderUsable("openai-codex", runtimeConfiguredProviderIDs: ["openai"]))
        #expect(!ModelPickerPolicy.isProviderUsable("codex", runtimeConfiguredProviderIDs: ["openai"]))
    }

    @Test func providerQualifiedDefaultWinsWhenModelIDsOverlap() {
        let direct = OpenClawChatModelChoice(
            modelID: "shared-model",
            name: "Direct Shared",
            provider: "anthropic",
            contextWindow: 32_000)
        let routed = OpenClawChatModelChoice(
            modelID: "shared-model",
            name: "OpenRouter Shared",
            provider: "openrouter",
            contextWindow: 32_000)

        #expect(ModelPickerPolicy.resolvedDefaultChoice(
            defaultModelLabel: "Default: openrouter/shared-model",
            models: [direct, routed])?.selectionID == routed.selectionID)
        #expect(ModelPickerPolicy.resolvedDefaultChoice(
            defaultModelLabel: "Default: shared-model",
            models: [direct, routed]) == nil)
    }

    @Test func preservesAuthoritativeCatalogPunctuation() {
        let gpt = OpenClawChatModelChoice(
            modelID: "gpt-4-1",
            name: "GPT-4.1",
            provider: "openai",
            contextWindow: 32_000)
        #expect(ModelPickerPolicy.resolvedDefaultName(
            defaultModelLabel: "Default: openai/gpt-4-1",
            models: [gpt]) == "GPT-4.1")
    }
}
