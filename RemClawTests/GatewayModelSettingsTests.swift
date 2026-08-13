import Foundation
import OpenClawChatUI
import OpenClawKit
import Testing
@testable import RemClaw

@MainActor
struct GatewayModelSettingsTests {
    private let miniMaxRef = "gmi/MiniMaxAI/MiniMax-M2.7"
    private let claudeRef = "anthropic/claude-sonnet-4-6"

    @Test func providerJargonIsRemovedFromUserFacingNames() {
        #expect(ModelUserFacingCopy.modelName("MiniMax M2.7 (via GMI MaaS)") == "MiniMax M2.7")
        #expect(ModelUserFacingCopy.modelName("MiniMax M2.7 via GMI MaaS") == "MiniMax M2.7")
        #expect(ModelUserFacingCopy.modelName("GMI MaaS") == "MiniMax")
        #expect(BYOKProvider.provider(id: "gmi")?.displayName == "MiniMax")
        #expect(BYOKProvider.provider(id: "gmi")?.detail.contains("GMI") == false)
    }

    @Test func automaticOffFreezesCurrentGatewayCatalogWithoutChangingPrimary() throws {
        let snapshot = makeSnapshot(primary: miniMaxRef, allowlist: nil, refs: [miniMaxRef, claudeRef])
        let proposed = try GatewayModelSettingsPolicy.change(
            from: snapshot,
            mutation: .automatic(false)
        )
        let change = try #require(proposed)

        #expect(Set(change.desiredAllowlist?.keys.map { $0 } ?? []) == [miniMaxRef, claudeRef])
        #expect(snapshot.primaryModelRef == miniMaxRef)
    }

    @Test func soleModelCannotBeDisabled() {
        let snapshot = makeSnapshot(primary: nil, allowlist: nil, refs: [miniMaxRef])

        #expect(throws: GatewayModelSettingsError.noUsableModels) {
            try GatewayModelSettingsPolicy.change(from: snapshot, mutation: .miniMax(false))
        }
    }

    @Test func currentPrimaryCannotBeDisabled() {
        let snapshot = makeSnapshot(
            primary: miniMaxRef,
            allowlist: [miniMaxRef: .object([:]), claudeRef: .object([:])],
            refs: [miniMaxRef, claudeRef]
        )

        #expect(throws: GatewayModelSettingsError.managedModelIsPrimary) {
            try GatewayModelSettingsPolicy.change(from: snapshot, mutation: .miniMax(false))
        }
    }

    @Test func unrelatedWildcardDoesNotImplicitlyEnableOrLockMiniMaxPrimary() throws {
        let snapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: miniMaxRef,
            allowlist: ["anthropic/*": .object([:])],
            configuredModels: [choice(for: miniMaxRef), choice(for: claudeRef)],
            effectiveModels: [choice(for: claudeRef)],
            legacyManagedModelRef: miniMaxRef
        )

        #expect(!snapshot.miniMaxEnabled)
        #expect(!snapshot.miniMaxIsPrimary)
        let proposed = try GatewayModelSettingsPolicy.change(
            from: snapshot,
            mutation: .miniMax(true),
            runtimeConfiguredProviderIDs: ["gmi", "anthropic"]
        )
        #expect(proposed?.desiredAllowlist?[miniMaxRef] != nil)
    }

    @Test func exactMiniMaxPrimaryRemainsLockedWithUnrelatedWildcard() {
        let snapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: miniMaxRef,
            allowlist: [
                miniMaxRef: .object([:]),
                "anthropic/*": .object([:]),
            ],
            configuredModels: [choice(for: miniMaxRef), choice(for: claudeRef)],
            effectiveModels: [choice(for: miniMaxRef), choice(for: claudeRef)],
            legacyManagedModelRef: miniMaxRef
        )

        #expect(snapshot.miniMaxEnabled)
        #expect(snapshot.miniMaxIsPrimary)
        #expect(throws: GatewayModelSettingsError.managedModelIsPrimary) {
            try GatewayModelSettingsPolicy.change(from: snapshot, mutation: .miniMax(false))
        }
    }

    @Test func mixedExactAndUnrelatedWildcardDoNotImplicitlyAdmitPrimary() throws {
        let snapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: miniMaxRef,
            allowlist: [
                "anthropic/*": .object([:]),
                claudeRef: .object(["alias": .string("Writing")]),
            ],
            configuredModels: [choice(for: miniMaxRef), choice(for: claudeRef)],
            effectiveModels: [choice(for: claudeRef)],
            legacyManagedModelRef: miniMaxRef
        )

        #expect(!ModelAllowlistMatcher.primaryIsAllowed(miniMaxRef, allowlist: snapshot.allowlist))
        #expect(!snapshot.effectiveModelRefs.contains(miniMaxRef))
        #expect(!snapshot.miniMaxEnabled)
        let proposed = try GatewayModelSettingsPolicy.change(
            from: snapshot,
            mutation: .miniMax(true),
            runtimeConfiguredProviderIDs: ["gmi", "anthropic"]
        )
        #expect(proposed?.desiredAllowlist?[miniMaxRef] != nil)
    }

    @Test func disabledMiniMaxRemainsDiscoverableAndCanBeEnabledAgain() throws {
        let miniMax = choice(for: miniMaxRef)
        let claude = choice(for: claudeRef)
        let snapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: claudeRef,
            allowlist: [claudeRef: .object([:])],
            configuredModels: [miniMax, claude],
            effectiveModels: [claude],
            legacyManagedModelRef: miniMaxRef
        )

        #expect(snapshot.managedModelRef == miniMaxRef)
        #expect(snapshot.miniMaxEnabled == false)
        let proposed = try GatewayModelSettingsPolicy.change(
            from: snapshot,
            mutation: .miniMax(true),
            runtimeConfiguredProviderIDs: ["gmi", "anthropic"]
        )
        let change = try #require(proposed)
        #expect(Set(change.desiredAllowlist?.keys.map { $0 } ?? []) == [miniMaxRef, claudeRef])
    }

    @Test func managedIdentityIgnoresM27DecoysRegardlessOfCatalogOrder() {
        let managed = choice(for: miniMaxRef)
        let decoys = [
            modelChoice(provider: "minimax", modelID: "MiniMax-M2.7", name: "MiniMax M2.7"),
            modelChoice(provider: "portal", modelID: "MiniMaxAI/MiniMax-M2.7", name: "MiniMax M2.7"),
            modelChoice(provider: "openrouter", modelID: "minimax/minimax-m2.7", name: "MiniMax M2.7"),
            modelChoice(provider: "highspeed", modelID: "MiniMaxAI/MiniMax-M2.7", name: "MiniMax M2.7"),
        ]
        let orders = [
            [managed] + decoys,
            decoys + [managed],
            [decoys[2], managed, decoys[0], decoys[3], decoys[1]],
        ]

        for configuredModels in orders {
            let snapshot = GatewayModelSettingsSnapshot(
                baseHash: "hash",
                primaryModelRef: claudeRef,
                allowlist: [claudeRef: .object([:])],
                configuredModels: configuredModels,
                effectiveModels: [choice(for: claudeRef)],
                legacyManagedModelRef: miniMaxRef
            )
            #expect(snapshot.managedModelRef == miniMaxRef)
        }
    }

    @Test func oldGatewayWithOnlyOtherM27ModelsFailsClosed() {
        let snapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: "minimax/MiniMax-M2.7",
            allowlist: [claudeRef: .object([:])],
            configuredModels: [
                modelChoice(provider: "minimax", modelID: "MiniMax-M2.7", name: "MiniMax M2.7"),
                modelChoice(provider: "openrouter", modelID: "minimax/minimax-m2.7", name: "MiniMax M2.7"),
            ],
            effectiveModels: [choice(for: claudeRef)]
        )

        #expect(snapshot.managedModelRef == nil)
        #expect(!snapshot.miniMaxEnabled)
        #expect(throws: GatewayModelSettingsError.managedModelUnavailable) {
            try GatewayModelSettingsPolicy.change(from: snapshot, mutation: .miniMax(true))
        }
    }

    @Test func duplicateManagedCandidatesFailClosedUnlessExactManagedPrimaryOverrides() {
        let duplicate = [choice(for: miniMaxRef), choice(for: miniMaxRef)]
        let ambiguous = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: claudeRef,
            allowlist: [claudeRef: .object([:])],
            configuredModels: duplicate,
            effectiveModels: [choice(for: claudeRef)]
        )
        let exactPrimary = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: miniMaxRef,
            allowlist: [miniMaxRef: .object([:])],
            configuredModels: duplicate,
            effectiveModels: duplicate,
            legacyManagedModelRef: miniMaxRef
        )

        #expect(ambiguous.managedModelRef == nil)
        #expect(exactPrimary.managedModelRef == miniMaxRef)
        #expect(exactPrimary.miniMaxIsPrimary)
    }

    @Test func wildcardEnabledMiniMaxCanBeDisabledWithoutDroppingSiblingModels() throws {
        let otherGMIRef = "gmi/another-model"
        let miniMax = choice(for: miniMaxRef)
        let otherGMI = choice(for: otherGMIRef)
        let claude = choice(for: claudeRef)
        let wildcardSnapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: claudeRef,
            allowlist: ["GMI/*": .object([:]), claudeRef: .object([:])],
            configuredModels: [miniMax, otherGMI, claude],
            effectiveModels: [miniMax, otherGMI, claude],
            legacyManagedModelRef: miniMaxRef
        )

        #expect(wildcardSnapshot.miniMaxEnabled)
        let disabledProposal = try GatewayModelSettingsPolicy.change(
            from: wildcardSnapshot,
            mutation: .miniMax(false),
            runtimeConfiguredProviderIDs: ["gmi", "anthropic"]
        )
        let disabled = try #require(disabledProposal)
        let disabledKeys = Set(disabled.desiredAllowlist?.keys.map { $0 } ?? [])
        #expect(!disabledKeys.contains("GMI/*"))
        #expect(!disabledKeys.contains(miniMaxRef))
        #expect(disabledKeys.contains(otherGMIRef))
        #expect(disabledKeys.contains(claudeRef))

        let disabledSnapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash-2",
            primaryModelRef: claudeRef,
            allowlist: disabled.desiredAllowlist,
            configuredModels: [miniMax, otherGMI, claude],
            effectiveModels: [otherGMI, claude],
            legacyManagedModelRef: miniMaxRef
        )
        let enabledProposal = try GatewayModelSettingsPolicy.change(
            from: disabledSnapshot,
            mutation: .miniMax(true),
            runtimeConfiguredProviderIDs: ["gmi", "anthropic"]
        )
        let enabled = try #require(enabledProposal)
        #expect(enabled.desiredAllowlist?[miniMaxRef] != nil)
    }

    @Test func miniMaxCannotBeDisabledWhenRemainingCatalogProviderLacksRuntimeAuth() {
        let snapshot = makeSnapshot(
            primary: claudeRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )

        #expect(throws: GatewayModelSettingsError.noUsableModels) {
            try GatewayModelSettingsPolicy.change(
                from: snapshot,
                mutation: .miniMax(false),
                runtimeConfiguredProviderIDs: []
            )
        }
    }

    @Test func miniMaxCanBeDisabledWhenRemainingCatalogProviderHasVerifiedRuntimeAuth() throws {
        let snapshot = makeSnapshot(
            primary: claudeRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )

        let proposed = try GatewayModelSettingsPolicy.change(
            from: snapshot,
            mutation: .miniMax(false),
            runtimeConfiguredProviderIDs: ["anthropic"]
        )

        #expect(proposed?.desiredAllowlist?[miniMaxRef] == nil)
        #expect(proposed?.desiredAllowlist?[claudeRef] != nil)
    }

    @Test func managedProviderSiblingsStayOutOfUserVisibleCatalog() {
        let otherGMI = choice(for: "gmi/another-model")
        let claude = choice(for: claudeRef)
        let snapshot = GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: claudeRef,
            allowlist: nil,
            configuredModels: [choice(for: miniMaxRef), otherGMI, claude],
            effectiveModels: [choice(for: miniMaxRef), otherGMI, claude]
        )

        #expect(snapshot.userVisibleCatalogModels.map(\.selectionID) == [claudeRef])
    }

    @Test func resetToAutomaticRemovesOnlyCurationAndPreservesPrimary() throws {
        let snapshot = makeSnapshot(
            primary: claudeRef,
            allowlist: [miniMaxRef: .object([:]), claudeRef: .object([:])],
            refs: [miniMaxRef, claudeRef]
        )
        let proposed = try GatewayModelSettingsPolicy.change(from: snapshot, mutation: .automatic(true))
        let change = try #require(proposed)

        #expect(change.desiredAllowlist == nil)
        #expect(change.patch["agents"] != nil)
        #expect(change.patch["models"] == nil)
        #expect(snapshot.primaryModelRef == claudeRef)
    }

    @Test func configConflictReReadsAndRetriesWithFreshHash() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.failFirstPatch = true
        var observedDelays: [Duration] = []
        var configTimeouts: [Int] = []
        let client = GatewayModelSettingsClient(
            request: { method, params, timeout in
                if method == "config.get" { configTimeouts.append(timeout) }
                return try rpc.request(method: method, paramsJSON: params)
            },
            sleep: { observedDelays.append($0) }
        )

        let original = try await client.load()
        let updated = try await client.apply(.automatic(false), to: original)

        #expect(rpc.patchAttempts == 2)
        #expect(observedDelays.isEmpty)
        #expect(configTimeouts.last == 3)
        #expect(Set(updated.allowlist?.keys.map { $0 } ?? []) == [miniMaxRef, claudeRef])
        #expect(updated.primaryModelRef == miniMaxRef)
    }

    @Test func unappliedMismatchDoesNotWriteACompensatingRollback() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.ignoreNonNullModelPatches = true
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        await #expect(throws: GatewayModelSettingsError.verificationFailed) {
            try await client.apply(.automatic(false), to: original)
        }

        #expect(rpc.patchAttempts == 1)
        #expect(!rpc.lastPatchClearedAllowlist)
        #expect(rpc.allowlist == nil)
    }

    @Test func confirmationReadFailureDoesNotReportSuccessAndRestoresOriginal() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        // Exhaust the five short confirmation reads and the final full read. The rollback
        // ownership read then succeeds and restores the exact original subtree.
        rpc.configFailuresAfterPatchRemaining = 6
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        await #expect(throws: GatewayModelSettingsError.verificationFailed) {
            try await client.apply(.automatic(false), to: original)
        }

        #expect(rpc.allowlist == nil)
        #expect(rpc.patchAttempts == 2)
    }

    @Test func secondClientReadsTheSameGatewayBackedSetting() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        let request: GatewayModelSettingsClient.Request = { method, params, _ in
            try rpc.request(method: method, paramsJSON: params)
        }
        let firstClient = GatewayModelSettingsClient(request: request, sleep: { _ in })
        let secondClient = GatewayModelSettingsClient(request: request, sleep: { _ in })

        let original = try await firstClient.load()
        _ = try await firstClient.apply(.automatic(false), to: original)
        let refreshedElsewhere = try await secondClient.load()

        #expect(refreshedElsewhere.automaticEnabled == false)
        #expect(Set(refreshedElsewhere.allowlist?.keys.map { $0 } ?? []) == [miniMaxRef, claudeRef])
    }

    @Test func newerCrossDeviceStateWithRequestedEffectiveSettingIsAcceptedWithoutRollback() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        let crossDeviceState = [claudeRef: JSONValue.object([:])]
        rpc.replaceAllowlistOnFirstConfigAfterPatch = crossDeviceState
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        let updated = try await client.apply(.automatic(false), to: original)

        #expect(rpc.patchAttempts == 1)
        #expect(!updated.automaticEnabled)
        #expect(rpc.allowlist == crossDeviceState)
        #expect(!rpc.lastPatchClearedAllowlist)
    }

    @Test func sameKeysWithNewerMetadataConfirmEffectiveSettingWithoutRollback() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        let crossDeviceState: [String: JSONValue] = [
            miniMaxRef: .object([:]),
            claudeRef: .object([
                "alias": .string("Work model"),
                "params": .object(["temperature": .number(0.2)]),
                "runtime": .string("remote"),
                "streaming": .bool(false),
            ]),
        ]
        rpc.replaceAllowlistOnFirstConfigAfterPatch = crossDeviceState
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        let updated = try await client.apply(.automatic(false), to: original)

        #expect(rpc.patchAttempts == 1)
        #expect(!updated.automaticEnabled)
        #expect(updated.allowlist == crossDeviceState)
        #expect(rpc.allowlist == crossDeviceState)
        #expect(!rpc.lastPatchClearedAllowlist)
    }

    @Test func rebasedFailedVerificationRestoresThatAttemptsMetadataBase() async throws {
        let initial: [String: JSONValue] = [
            miniMaxRef: .object([:]),
            claudeRef: .object([:]),
        ]
        let rebasedBase: [String: JSONValue] = [
            miniMaxRef: .object([:]),
            claudeRef: .object([
                "alias": .string("Cross-device C"),
                "params": .object(["temperature": .number(0.4)]),
                "runtime": .string("remote"),
                "streaming": .bool(false),
            ]),
        ]
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: initial,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.failFirstPatch = true
        rpc.replaceAllowlistOnFirstPatchFailure = rebasedBase
        // The failed first patch is a structured rejection and rebases immediately. Keep the
        // replacement write unavailable for one short confirmation window so rollback is exercised.
        rpc.configFailuresAfterPatchRemaining = 6
        rpc.configFailuresStartPatchAttempt = 2
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        await #expect(throws: GatewayModelSettingsError.verificationFailed) {
            try await client.apply(.automatic(true), to: original)
        }

        #expect(rpc.patchAttempts == 3)
        #expect(rpc.allowlist == rebasedBase)
    }

    @Test func ambiguousInitialPatchThatPersistedIsAcceptedByReadback() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.throwAfterApplyingPatchAttempt = 1
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        let updated = try await client.apply(.automatic(false), to: original)

        #expect(rpc.patchAttempts == 1)
        #expect(!updated.automaticEnabled)
    }

    @Test func gatewayNormalizedModelMetadataStillConfirmsAutomaticOff() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.normalizeAllowlistMetadataAfterPatch = true
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        let updated = try await client.apply(.automatic(false), to: original)

        #expect(rpc.patchAttempts == 1)
        #expect(!updated.automaticEnabled)
        #expect(updated.allowlist?[claudeRef] == .object(["alias": .string("sonnet")]))
    }

    @Test func ambiguousPersistedPatchWaitsForReplacementConnectionBeforeRebasing() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.throwAfterApplyingPatchAttempt = 1
        rpc.configFailuresAfterPatchRemaining = 2
        var observedDelays: [Duration] = []
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { observedDelays.append($0) }
        )
        let original = try await client.load()

        let updated = try await client.apply(.automatic(false), to: original)

        #expect(rpc.patchAttempts == 1)
        #expect(!updated.automaticEnabled)
        #expect(observedDelays == [.milliseconds(500), .seconds(1)])
    }

    @Test func ambiguousRebasedPatchThatPersistedIsAcceptedByReadback() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.failFirstPatch = true
        rpc.throwAfterApplyingPatchAttempt = 2
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()

        let updated = try await client.apply(.automatic(false), to: original)

        #expect(rpc.patchAttempts == 2)
        #expect(!updated.automaticEnabled)
        #expect(Set(updated.allowlist?.keys.map { $0 } ?? []) == [miniMaxRef, claudeRef])
    }

    @Test func oldGatewayWithoutFullCatalogShowsCurrentStateReadOnly() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: [claudeRef: .object([:])],
            refs: [claudeRef]
        )
        rpc.failFullCatalog = true
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])

        #expect(snapshot.catalogAuthority == .legacyReadOnly)
        #expect(!snapshot.automaticEnabled)
        #expect(snapshot.managedModelRef == miniMaxRef)
        #expect(snapshot.miniMaxPresentationValue == true)
        #expect(snapshot.catalogAuthority.readOnlyDescription != nil)
        #expect(rpc.modelListParams == [#"{"view":"all"}"#, #"{"view":"configured"}"#])
    }

    @Test func completeCatalogIsRequestedBeforeConfiguredCatalog() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])

        #expect(snapshot.catalogAuthority == .completeMutable)
        #expect(rpc.modelListParams == [#"{"view":"all"}"#, #"{"view":"configured"}"#])
    }

    @Test func successfulCompleteEmptyCatalogOverridesExactPrimaryEvidence() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: [claudeRef: .object([:])],
            refs: [claudeRef]
        )
        rpc.allRefs = []
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        await #expect(throws: GatewayModelSettingsError.fullCatalogUnavailable) {
            try await client.load()
        }
    }

    @Test func legacyCatalogShowsExactPrimaryAndAutomaticReadOnlyWithPositiveAuth() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.allCatalogComplete = nil
        rpc.effectiveCatalogComplete = nil
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])

        #expect(snapshot.catalogAuthority == .legacyReadOnly)
        #expect(snapshot.automaticEnabled)
        #expect(snapshot.managedModelRef == miniMaxRef)
        #expect(snapshot.miniMaxEnabled)
        #expect(snapshot.catalogAuthority.readOnlyDescription != nil)
    }

    @Test func legacyCatalogUsesExactProviderModelIdentityWithPositiveAuth() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: [miniMaxRef: .object([:])],
            refs: [miniMaxRef, claudeRef]
        )
        rpc.allCatalogComplete = nil
        rpc.effectiveCatalogComplete = nil
        rpc.configuredProviderModels = [
            (provider: " GMI ", id: "MiniMaxAI/MiniMax-M2.7"),
        ]
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])

        #expect(!snapshot.automaticEnabled)
        #expect(snapshot.managedModelRef == miniMaxRef)
        #expect(snapshot.miniMaxEnabled)
    }

    @Test func legacyCatalogRequiresPositiveRuntimeAuthForExactConfigEvidence() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef]
        )
        rpc.allCatalogComplete = nil
        rpc.effectiveCatalogComplete = nil
        rpc.configuredProviderModels = [
            (provider: "gmi", id: "MiniMaxAI/MiniMax-M2.7"),
        ]
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["anthropic"])

        #expect(snapshot.catalogAuthority == .legacyReadOnly)
        #expect(snapshot.managedModelRef == nil)
        #expect(!snapshot.miniMaxEnabled)
        #expect(snapshot.miniMaxPresentationValue == nil)
    }

    @Test func legacyCatalogNeverTrustsExactRowsOrManagedDisplayText() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: nil,
            refs: [miniMaxRef]
        )
        rpc.allCatalogComplete = nil
        rpc.effectiveCatalogComplete = nil
        rpc.configuredProviderModels = [
            (provider: "gmi", id: "another-model"),
            (provider: "portal", id: "MiniMaxAI/MiniMax-M2.7"),
        ]
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])

        #expect(snapshot.effectiveModels.contains(where: GatewayModelSettingsSnapshot.isMiniMax))
        #expect(snapshot.managedModelRef == nil)
        #expect(!snapshot.miniMaxEnabled)
    }

    @Test func legacyReadOnlySnapshotCannotPatchAnyMutation() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.allCatalogComplete = nil
        rpc.effectiveCatalogComplete = nil
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])

        await #expect(throws: GatewayModelSettingsError.legacyCatalogReadOnly) {
            try await client.apply(.automatic(false), to: snapshot)
        }
        await #expect(throws: GatewayModelSettingsError.legacyCatalogReadOnly) {
            try await client.apply(.miniMax(false), to: snapshot)
        }
        #expect(rpc.patchAttempts == 0)
    }

    @Test func incompleteFullCatalogIsReadOnlyAndCanRecoverOnRetry() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.allCatalogComplete = false
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let degraded = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])
        #expect(degraded.catalogAuthority == .legacyReadOnly)

        rpc.allCatalogComplete = true
        let recovered = try await client.load()
        #expect(recovered.catalogAuthority == .completeMutable)
        #expect(Set(recovered.configuredModels.map(\.selectionID)) == [miniMaxRef, claudeRef])
    }

    @Test func missingFullCatalogCompletenessStaysReadOnly() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.allCatalogComplete = nil
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])
        #expect(snapshot.catalogAuthority == .legacyReadOnly)
    }

    @Test func incompleteEffectiveCatalogStaysReadOnly() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.effectiveCatalogComplete = false
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])
        #expect(snapshot.catalogAuthority == .legacyReadOnly)
    }

    @Test func missingEffectiveCatalogCompletenessStaysReadOnly() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        rpc.effectiveCatalogComplete = nil
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["gmi"])
        #expect(snapshot.catalogAuthority == .legacyReadOnly)
    }

    @Test func successfulFullCatalogMissingManagedModelStillShowsAutomaticAndCatalog() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: [claudeRef: .object([:])],
            refs: [claudeRef]
        )
        rpc.allRefs = [claudeRef]
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["anthropic"])

        #expect(snapshot.catalogAuthority == .completeMutable)
        #expect(!snapshot.automaticEnabled)
        #expect(snapshot.managedModelRef == nil)
        #expect(snapshot.userVisibleCatalogModels.map(\.selectionID) == [claudeRef])
        #expect(snapshot.miniMaxPresentationValue == false)
    }

    @Test func completeCatalogCannotAuthorizeManagedModelWithoutRuntimeAuth() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: [claudeRef: .object([:])],
            refs: [miniMaxRef, claudeRef]
        )
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )

        let snapshot = try await client.load(runtimeConfiguredProviderIDs: ["anthropic"])

        #expect(snapshot.catalogAuthority == .completeMutable)
        #expect(snapshot.managedModelRef == nil)
        #expect(snapshot.miniMaxPresentationValue == false)
        #expect(throws: GatewayModelSettingsError.managedModelUnavailable) {
            try GatewayModelSettingsPolicy.change(
                from: snapshot,
                mutation: .miniMax(true),
                runtimeConfiguredProviderIDs: ["anthropic"]
            )
        }
    }

    @Test func wildcardLifecyclePersistsDisableThenReEnableThroughRPC() async throws {
        let otherGMIRef = "gmi/another-model"
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: claudeRef,
            allowlist: ["gmi/*": .object(["alias": .string("Managed")]), claudeRef: .object([:])],
            refs: [miniMaxRef, otherGMIRef, claudeRef]
        )
        let request: GatewayModelSettingsClient.Request = { method, params, _ in
            try rpc.request(method: method, paramsJSON: params)
        }
        let client = GatewayModelSettingsClient(request: request, sleep: { _ in })

        let initial = try await client.load(runtimeConfiguredProviderIDs: ["gmi", "anthropic"])
        #expect(initial.miniMaxEnabled)
        let disabled = try await client.apply(
            .miniMax(false),
            to: initial,
            runtimeConfiguredProviderIDs: ["gmi", "anthropic"]
        )
        #expect(!disabled.miniMaxEnabled)
        #expect(disabled.managedModelRef == miniMaxRef)
        #expect(disabled.allowlist?["gmi/*"] == nil)
        #expect(disabled.allowlist?[otherGMIRef] != nil)

        let enabled = try await client.apply(
            .miniMax(true),
            to: disabled,
            runtimeConfiguredProviderIDs: ["gmi", "anthropic"]
        )
        #expect(enabled.miniMaxEnabled)
        #expect(enabled.managedModelRef == miniMaxRef)
        #expect(enabled.allowlist?[miniMaxRef] != nil)
        #expect(enabled.allowlist?[otherGMIRef] != nil)
        #expect(rpc.patchAttempts == 2)
    }

    @Test func cancelledMutationCannotWriteOrRollback() async throws {
        var rpc = FakeModelSettingsRPC(
            hash: "hash-1",
            primary: miniMaxRef,
            allowlist: nil,
            refs: [miniMaxRef, claudeRef]
        )
        let client = GatewayModelSettingsClient(
            request: { method, params, _ in try rpc.request(method: method, paramsJSON: params) },
            sleep: { _ in }
        )
        let original = try await client.load()
        let mutation = Task { try await client.apply(.automatic(false), to: original) }

        mutation.cancel()
        var observedCancellation = false
        do {
            _ = try await mutation.value
        } catch is CancellationError {
            observedCancellation = true
        }

        #expect(observedCancellation)
        #expect(rpc.patchAttempts == 0)
        #expect(rpc.allowlist == nil)
    }

    private func makeSnapshot(
        primary: String?,
        allowlist: [String: JSONValue]?,
        refs: [String]
    ) -> GatewayModelSettingsSnapshot {
        GatewayModelSettingsSnapshot(
            baseHash: "hash",
            primaryModelRef: primary,
            allowlist: allowlist,
            configuredModels: refs.map(choice(for:)),
            effectiveModels: refs.map(choice(for:)),
            legacyManagedModelRef: refs.filter { $0 == miniMaxRef }.count == 1 ? miniMaxRef : nil
        )
    }

    private func choice(for ref: String) -> OpenClawChatModelChoice {
        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        return OpenClawChatModelChoice(
            modelID: parts.count == 2 ? parts[1] : ref,
            name: ref == miniMaxRef ? "MiniMax M2.7 (via GMI MaaS)" : "Claude Sonnet 4.6",
            provider: parts.count == 2 ? parts[0] : "",
            contextWindow: 196_608
        )
    }

    private func modelChoice(
        provider: String,
        modelID: String,
        name: String
    ) -> OpenClawChatModelChoice {
        OpenClawChatModelChoice(
            modelID: modelID,
            name: name,
            provider: provider,
            contextWindow: 196_608
        )
    }

    private struct FakeConflict: Error {}

    private struct FakeModelSettingsRPC {
        var hash: String
        let primary: String?
        var allowlist: [String: JSONValue]?
        let refs: [String]
        var allRefs: [String]? = nil
        var failFirstPatch = false
        var ignoreNonNullModelPatches = false
        var normalizeAllowlistMetadataAfterPatch = false
        var throwAfterApplyingPatchAttempt: Int?
        var replaceAllowlistOnFirstConfigAfterPatch: [String: JSONValue]?
        var replaceAllowlistOnFirstPatchFailure: [String: JSONValue]?
        var failFullCatalog = false
        var allCatalogComplete: Bool? = true
        var effectiveCatalogComplete: Bool? = true
        var configFailuresAfterPatchRemaining = 0
        var configFailuresStartPatchAttempt = 1
        var configuredProviderModels: [(provider: String, id: String)] = []
        var modelListParams: [String?] = []
        var patchAttempts = 0
        var lastPatchClearedAllowlist = false

        mutating func request(method: String, paramsJSON: String?) throws -> Data {
            switch method {
            case "config.get":
                if patchAttempts > 0, let replacement = replaceAllowlistOnFirstConfigAfterPatch {
                    allowlist = replacement
                    replaceAllowlistOnFirstConfigAfterPatch = nil
                    hash = "hash-cross-device"
                }
                if patchAttempts >= configFailuresStartPatchAttempt,
                   configFailuresAfterPatchRemaining > 0
                {
                    configFailuresAfterPatchRemaining -= 1
                    throw FakeConflict()
                }
                return configData()
            case "models.list":
                modelListParams.append(paramsJSON)
                if failFullCatalog, paramsJSON?.contains(#""view":"all""#) == true {
                    throw FakeConflict()
                }
                return modelsData(paramsJSON: paramsJSON)
            case "config.patch":
                patchAttempts += 1
                if failFirstPatch, patchAttempts == 1 {
                    if let replacement = replaceAllowlistOnFirstPatchFailure {
                        allowlist = replacement
                        replaceAllowlistOnFirstPatchFailure = nil
                    }
                    hash = "hash-conflict"
                    throw GatewayResponseError(
                        method: "config.patch",
                        code: "CONFLICT",
                        message: "config changed",
                        details: nil
                    )
                }
                try applyPatch(paramsJSON)
                if normalizeAllowlistMetadataAfterPatch, let ref = refs.last {
                    allowlist?[ref] = .object(["alias": .string("sonnet")])
                }
                hash = "hash-\(patchAttempts + 1)"
                if throwAfterApplyingPatchAttempt == patchAttempts {
                    throw FakeConflict()
                }
                return Data(#"{"ok":true}"#.utf8)
            default:
                throw NSError(domain: "FakeModelSettingsRPC", code: 404)
            }
        }

        private func configData() -> Data {
            var defaults: [String: JSONValue] = [:]
            if let primary { defaults["model"] = .object(["primary": .string(primary)]) }
            if let allowlist {
                defaults["models"] = .object(allowlist)
            }
            var config: [String: JSONValue] = [
                "agents": .object(["defaults": .object(defaults)]),
            ]
            if !configuredProviderModels.isEmpty {
                var providers: [String: JSONValue] = [:]
                for group in Dictionary(grouping: configuredProviderModels, by: \.provider) {
                    providers[group.key] = .object([
                        "models": .array(group.value.map { model in
                            .object([
                                "id": .string(model.id),
                                // Deliberately untrusted: policy must use provider/model ids only.
                                "name": .string("MiniMax M2.7"),
                            ])
                        }),
                    ])
                }
                config["models"] = .object(["providers": .object(providers)])
            }
            let object = JSONValue.object([
                "hash": .string(hash),
                "config": .object(config),
            ])
            return try! JSONEncoder().encode(object)
        }

        private func modelsData(paramsJSON: String?) -> Data {
            let isAll = paramsJSON?.contains(#""view":"all""#) == true
            let sourceRefs: [String]
            if isAll {
                sourceRefs = allRefs ?? refs
            } else if let allowlist, !allowlist.isEmpty {
                sourceRefs = refs.filter { ref in
                    ModelAllowlistMatcher.allows(ref, keys: allowlist.keys) ||
                        (primary.map { ModelAllowlistMatcher.matches($0, ref) } ?? false)
                }
            } else {
                sourceRefs = refs
            }
            let models = sourceRefs.map { ref -> [String: Any] in
                let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
                return [
                    "id": parts.count == 2 ? parts[1] : ref,
                    "name": ref.contains("MiniMax") ? "MiniMax M2.7 (via GMI MaaS)" : "Claude Sonnet 4.6",
                    "provider": parts.count == 2 ? parts[0] : "",
                    "contextwindow": 196_608,
                ]
            }
            var payload: [String: Any] = ["models": models]
            let catalogComplete = isAll ? allCatalogComplete : effectiveCatalogComplete
            if let catalogComplete {
                payload["catalogComplete"] = catalogComplete
            }
            return try! JSONSerialization.data(withJSONObject: payload)
        }

        private mutating func applyPatch(_ paramsJSON: String?) throws {
            let paramsData = Data(try #require(paramsJSON).utf8)
            let params = try #require(
                JSONSerialization.jsonObject(with: paramsData) as? [String: Any]
            )
            let raw = try #require(params["raw"] as? String)
            let patch = try JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8))
            let agents = try #require(patch["agents"]?.objectValue)
            let defaults = try #require(agents["defaults"]?.objectValue)
            let models = try #require(defaults["models"])
            if models == .null {
                lastPatchClearedAllowlist = true
                allowlist = nil
                return
            }
            guard !ignoreNonNullModelPatches else { return }
            let entries = try #require(models.objectValue)
            var next = allowlist ?? [:]
            for (ref, value) in entries {
                if value == .null { next.removeValue(forKey: ref) }
                else { next[ref] = value }
            }
            allowlist = next
        }
    }
}
