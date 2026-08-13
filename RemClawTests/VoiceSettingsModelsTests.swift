import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import RemClaw

struct VoiceSettingsModelsTests {
    @Test func voiceCatalogTreatsVoicesEndpointAsReadinessAuthority() throws {
        let staleCatalog = try JSONDecoder().decode(
            TalkCatalogResponse.self,
            from: Data(
                """
                {
                  "speech": {
                    "activeProvider": "elevenlabs",
                    "providers": [{"id":"elevenlabs","configured":false}]
                  }
                }
                """.utf8
            )
        )
        #expect(VoiceSettingsCatalogPolicy.providerToLoad(
            catalog: staleCatalog,
            selection: nil
        ) == "elevenlabs")

        let missingActiveProvider = try JSONDecoder().decode(
            TalkCatalogResponse.self,
            from: Data(#"{"speech":{"providers":[]}}"#.utf8)
        )
        #expect(VoiceSettingsCatalogPolicy.providerToLoad(
            catalog: missingActiveProvider,
            selection: VoiceSettingsSelection(
                provider: "elevenlabs",
                voiceID: nil,
                modelID: nil,
                outputFormat: nil
            )
        ) == "elevenlabs")
    }

    @Test func parsesCanonicalResolvedVoiceSelection() throws {
        let data = Data(
            """
            {
              "config": {
                "talk": {
                  "provider": "elevenlabs",
                  "providers": {
                    "elevenlabs": {
                      "voiceId": "raw-provider-value"
                    }
                  },
                  "resolved": {
                    "provider": "elevenlabs",
                    "config": {
                      "voiceId": "voice-sarah",
                      "modelId": "model-v3",
                      "outputFormat": "mp3_44100_128",
                      "apiKey": "__OPENCLAW_REDACTED__"
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let selection = try VoiceSettingsConfigParser.selection(from: data)

        #expect(selection == VoiceSettingsSelection(
            provider: "elevenlabs",
            voiceID: "voice-sarah",
            modelID: "model-v3",
            outputFormat: "mp3_44100_128"
        ))
    }

    @Test func rejectsLegacyFlatTalkVoice() throws {
        let data = Data(
            """
            {
              "config": {
                "talk": {
                  "voiceId": "legacy-voice",
                  "modelId": "legacy-model"
                }
              }
            }
            """.utf8
        )

        #expect(try VoiceSettingsConfigParser.selection(from: data) == nil)
    }

    @Test func runtimePrefersCanonicalSelectedProviderAndFallsBackToLegacyOnlyWhenNeeded() throws {
        let canonical = Data(
            """
            {
              "config": {
                "talk": {
                  "provider": "google",
                  "providers": {
                    "elevenlabs": { "voiceId": "wrong-provider" },
                    "google": {
                      "voiceId": "canonical-voice",
                      "modelId": "canonical-model",
                      "outputFormat": "mp3"
                    }
                  },
                  "voiceId": "stale-flat-voice"
                }
              }
            }
            """.utf8
        )
        let legacy = Data(
            """
            {
              "config": {
                "talk": {
                  "voiceId": "legacy-voice",
                  "modelId": "legacy-model",
                  "outputFormat": "mp3"
                }
              }
            }
            """.utf8
        )

        #expect(try VoiceSettingsConfigParser.runtimeSelection(from: canonical) == VoiceSettingsSelection(
            provider: "google",
            voiceID: "canonical-voice",
            modelID: "canonical-model",
            outputFormat: "mp3"
        ))
        #expect(try VoiceSettingsConfigParser.runtimeSelection(from: legacy) == VoiceSettingsSelection(
            provider: "elevenlabs",
            voiceID: "legacy-voice",
            modelID: "legacy-model",
            outputFormat: "mp3"
        ))
    }

    @Test func omittedResolvedVoiceOptionsRemainNilSoRuntimeCanClearStaleValues() throws {
        let data = Data(
            """
            {
              "config": {
                "talk": {
                  "resolved": {
                    "provider": "elevenlabs",
                    "config": {}
                  }
                }
              }
            }
            """.utf8
        )

        let parsedSelection = try VoiceSettingsConfigParser.selection(from: data)
        let selection = try #require(parsedSelection)

        #expect(selection.provider == "elevenlabs")
        #expect(selection.voiceID == nil)
        #expect(selection.modelID == nil)
        #expect(selection.outputFormat == nil)
    }

    @Test func patchUsesCanonicalNestedProviderShape() throws {
        let raw = try VoiceSettingsConfigParser.encodePatch(
            provider: "elevenlabs",
            voiceID: "voice-new"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        let talk = try #require(object["talk"] as? [String: Any])
        let providers = try #require(talk["providers"] as? [String: Any])
        let provider = try #require(providers["elevenlabs"] as? [String: Any])

        #expect(talk["provider"] as? String == "elevenlabs")
        #expect(provider["voiceId"] as? String == "voice-new")
        #expect(provider["apiKey"] == nil)
        #expect(talk["voiceId"] == nil)
    }

    @Test func patchUsesHashFromFreshSnapshot() throws {
        let snapshot = Data(
            """
            {
              "hash": "fresh-server-hash",
              "baseHash": "stale-client-hash",
              "config": {}
            }
            """.utf8
        )

        let params = try VoiceSettingsConfigParser.patchParams(
            snapshotData: snapshot,
            provider: "elevenlabs",
            voiceID: "voice-new"
        )
        let encoded = try JSONEncoder().encode(params)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(object["baseHash"] as? String == "fresh-server-hash")
        #expect((object["raw"] as? String)?.contains("voice-new") == true)
    }

    @Test func voicePrefersGatewayNameAndFriendlyFallback() {
        let named = VoiceSettingsVoice(
            id: "opaque-id",
            name: "  Sarah  ",
            category: nil,
            description: "  Warm and conversational  ",
            locale: nil,
            gender: nil,
            personalities: nil
        )
        let unnamed = VoiceSettingsVoice(
            id: "calm_narrator-voice",
            name: nil,
            category: nil,
            description: nil,
            locale: nil,
            gender: nil,
            personalities: ["warm", "clear", "steady"]
        )

        #expect(named.displayName == "Sarah")
        #expect(named.displayDetail == "Warm and conversational")
        #expect(unnamed.displayName == "Calm Narrator Voice")
        #expect(unnamed.displayDetail == "warm · clear")
    }

    @Test func activePreviewCanCancelWhileLoadingAndPlaying() {
        var state = VoicePreviewStateMachine()

        #expect(state.tap(voiceID: "sarah") == .start(voiceID: "sarah"))
        #expect(state.phase == .loading(voiceID: "sarah"))
        #expect(state.buttonEnabled(for: "sarah", isSaving: false))
        #expect(!state.buttonEnabled(for: "other", isSaving: false))
        #expect(state.tap(voiceID: "sarah") == .stop)
        #expect(state.phase == .idle)

        #expect(state.tap(voiceID: "sarah") == .start(voiceID: "sarah"))
        state.didStartPlaying(voiceID: "sarah")
        #expect(state.phase == .playing(voiceID: "sarah"))
        #expect(state.tap(voiceID: "sarah") == .stop)
        #expect(state.phase == .idle)
    }

    @MainActor
    @Test func previewReplacementWaitsForCancellationAndRepeatedStopsAreSafe() async {
        let gate = VoicePreviewRequestGate()
        let barrier = VoicePreviewTestBarrier()
        var events: [String] = []
        let firstCommand = gate.claimReplacement(previewID: "preview-a")
        await gate.executeReplacement(
            firstCommand,
            cancelCurrent: { events.append("unexpected-cancel-\($0)") },
            startNext: { events.append("start-\($0)") }
        )
        let replacementCommand = gate.claimReplacement(previewID: "preview-b")

        let replacement = Task { @MainActor in
            await gate.executeReplacement(
                replacementCommand,
                cancelCurrent: { previewID in
                    events.append("cancel-start-\(previewID)")
                    await barrier.wait()
                    events.append("cancel-finished-\(previewID)")
                },
                startNext: { previewID in
                    events.append("start-\(previewID)")
                }
            )
        }

        while !barrier.isWaiting {
            await Task.yield()
        }
        #expect(events == ["start-preview-a", "cancel-start-preview-a"])
        #expect(!events.contains("start-preview-b"))

        barrier.release()
        await replacement.value
        #expect(events == [
            "start-preview-a",
            "cancel-start-preview-a",
            "cancel-finished-preview-a",
            "start-preview-b",
        ])

        let firstStop = gate.claimStop()
        await gate.executeStop(firstStop) { events.append("stop-1-\($0)") }
        let secondStop = gate.claimStop()
        await gate.executeStop(secondStop) { events.append("unexpected-stop-2-\($0)") }
        #expect(events.last == "stop-1-preview-b")
        #expect(!events.contains(where: { $0.hasPrefix("unexpected-stop-2") }))
    }

    @MainActor
    @Test func delayedStaleReplacementCannotInvalidateNewerPreview() async {
        let gate = VoicePreviewRequestGate()
        var state = VoicePreviewStateMachine()
        var events: [String] = []

        let staleA = gate.claimReplacement(previewID: "preview-a")
        let currentB = gate.claimReplacement(previewID: "preview-b")
        _ = state.tap(voiceID: "b")

        await gate.executeReplacement(
            currentB,
            cancelCurrent: { events.append("cancel-\($0)") },
            startNext: { previewID in
                events.append("start-\(previewID)")
                state.didStartPlaying(voiceID: "b")
            }
        )
        // Simulate A's cancelled Task receiving a scheduling turn only after B.
        await gate.executeReplacement(
            staleA,
            cancelCurrent: { events.append("stale-cancel-\($0)") },
            startNext: { events.append("stale-start-\($0)") }
        )

        #expect(events == ["cancel-preview-a", "start-preview-b"])
        #expect(state.phase == .playing(voiceID: "b"))
    }

    @MainActor
    @Test func staleStopCannotPoisonLaterReplacement() async {
        let gate = VoicePreviewRequestGate()
        var state = VoicePreviewStateMachine()
        var events: [String] = []

        let initialA = gate.claimReplacement(previewID: "preview-a")
        await gate.executeReplacement(
            initialA,
            cancelCurrent: { events.append("unexpected-initial-cancel-\($0)") },
            startNext: { events.append("start-\($0)") }
        )
        let staleStop = gate.claimStop()
        let currentReplacement = gate.claimReplacement(previewID: "preview-b")
        _ = state.tap(voiceID: "b")

        // Simulate the cancelled Stop task entering after the replacement was claimed.
        await gate.executeStop(staleStop) { events.append("stale-stop-\($0)") }
        await gate.executeReplacement(
            currentReplacement,
            cancelCurrent: { events.append("cancel-\($0)") },
            startNext: { previewID in
                events.append("start-\(previewID)")
                state.didStartPlaying(voiceID: "b")
            }
        )

        #expect(events == ["start-preview-a", "cancel-preview-a", "start-preview-b"])
        #expect(state.phase == .playing(voiceID: "b"))
    }

    @MainActor
    @Test func delayedInFlightStopCanOnlyCancelItsCapturedPredecessor() async {
        let gate = VoicePreviewRequestGate()
        let barrier = VoicePreviewTestBarrier()
        var state = VoicePreviewStateMachine()
        var events: [String] = []

        let initialA = gate.claimReplacement(previewID: "preview-a")
        await gate.executeReplacement(
            initialA,
            cancelCurrent: { events.append("unexpected-initial-cancel-\($0)") },
            startNext: { events.append("start-\($0)") }
        )
        let stopA = gate.claimStop()
        let delayedStop = Task { @MainActor in
            await gate.executeStop(stopA) { previewID in
                events.append("stop-sent-\(previewID)")
                await barrier.wait()
                events.append("stop-arrived-\(previewID)")
            }
        }
        while !barrier.isWaiting { await Task.yield() }

        let replacementB = gate.claimReplacement(previewID: "preview-b")
        _ = state.tap(voiceID: "b")
        await gate.executeReplacement(
            replacementB,
            cancelCurrent: { events.append("replacement-cancel-\($0)") },
            startNext: { previewID in
                events.append("start-\(previewID)")
                state.didStartPlaying(voiceID: "b")
            }
        )
        barrier.release()
        await delayedStop.value

        #expect(events == [
            "start-preview-a",
            "stop-sent-preview-a",
            "replacement-cancel-preview-a",
            "start-preview-b",
            "stop-arrived-preview-a",
        ])
        #expect(!events.contains("stop-arrived-preview-b"))
        #expect(state.phase == .playing(voiceID: "b"))
    }

    @Test(arguments: ["talk.catalog", "talk.config", "talk.voices"])
    func olderGatewayHasFriendlyVoiceSettingsFallback(method: String) {
        let error = GatewayResponseError(
            method: method,
            code: "INVALID_REQUEST",
            message: "unknown method: \(method)",
            details: nil
        )
        let message = VoiceSettingsLoadPresentation.message(for: error)

        #expect(message.contains("Update the agent"))
        #expect(!message.contains(method))
        #expect(!message.lowercased().contains("provider"))
    }

    @Test(arguments: ["talk.catalog", "talk.config", "talk.voices"])
    func unsupportedVoiceSettingsCapabilityUsesOlderGatewayRecovery(method: String) {
        let error = GatewayResponseError(
            method: method,
            code: "UNAVAILABLE",
            message: "provider request failed",
            details: ["reason": AnyCodable("provider_unsupported")]
        )

        #expect(VoiceSettingsLoadPresentation.message(for: error).contains("Update the agent"))
    }

    @Test func unsupportedVoiceCapabilityRoutesToTheCorrectUpdateDestination() {
        let error = GatewayResponseError(
            method: "talk.voices",
            code: "UNAVAILABLE",
            message: "provider request failed",
            details: ["reason": AnyCodable("provider_unsupported")]
        )

        let managed = VoiceSettingsLoadPresentation.presentation(
            for: error,
            gatewayProvider: .fly
        )
        let local = VoiceSettingsLoadPresentation.presentation(
            for: error,
            gatewayProvider: .local
        )
        let manual = VoiceSettingsLoadPresentation.presentation(
            for: error,
            gatewayProvider: .manual
        )

        #expect(managed.action == .openManagedGatewayUpdate)
        #expect(managed.action.destination == .managedGatewayDetail)
        #expect(local.action == .openSelfManagedUpdate)
        #expect(local.action.destination == .selfManagedUpdateInstructions)
        #expect(manual.action == .openSelfManagedUpdate)
        #expect(manual.action.destination == .selfManagedUpdateInstructions)
    }

    @Test func transientVoiceCatalogFailureDoesNotClaimAgentUpdateIsRequired() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "connection lost"]
        )
        let message = VoiceSettingsLoadPresentation.message(for: error)

        #expect(message.contains("connection"))
        #expect(!message.contains("Update the agent"))
    }

    @Test func voiceCatalogAuthQuotaAndConfigFailuresHaveTruthfulCopy() {
        let auth = GatewayResponseError(
            method: "talk.voices",
            code: "UNAVAILABLE",
            message: "provider request failed",
            details: ["reason": AnyCodable("provider_authentication")]
        )
        let quota = GatewayResponseError(
            method: "talk.voices",
            code: "UNAVAILABLE",
            message: "provider request failed",
            details: ["reason": AnyCodable("provider_quota")]
        )
        let config = GatewayResponseError(
            method: "talk.voices",
            code: "UNAVAILABLE",
            message: "provider request failed",
            details: ["reason": AnyCodable("provider_not_configured")]
        )

        #expect(VoiceSettingsLoadPresentation.message(for: auth).contains("authentication"))
        #expect(VoiceSettingsLoadPresentation.message(for: quota).contains("temporarily"))
        #expect(VoiceSettingsLoadPresentation.message(for: config).contains("configured"))
    }

    @Test func providerAuthenticationRoutesManagedKeysToRepairAndBYOKToSetup() {
        let error = GatewayResponseError(
            method: "talk.voices",
            code: "UNAVAILABLE",
            message: "provider request failed",
            details: ["reason": AnyCodable("provider_authentication")]
        )

        #expect(
            VoiceSettingsLoadPresentation.presentation(
                for: error,
                gatewayProvider: .fly
            ).action == .repairManagedConfiguration
        )
        #expect(
            VoiceSettingsLoadPresentation.presentation(
                for: error,
                gatewayProvider: .local
            ).action == .openProviderSetup
        )
        #expect(
            VoiceSettingsLoadPresentation.presentation(
                for: error,
                gatewayProvider: .manual
            ).action == .openProviderSetup
        )
    }

    @Test func voiceCatalogClassificationNeverReadsHumanMessageText() {
        let transient = GatewayResponseError(
            method: "talk.voices",
            code: "UNAVAILABLE",
            message: "unknown method quota not configured authentication required",
            details: ["reason": AnyCodable("provider_transient")]
        )

        let message = VoiceSettingsLoadPresentation.message(for: transient)

        #expect(message.contains("connection"))
        #expect(!message.contains("Update the agent"))
    }

    @Test func missingProviderMapsToManagedRepairOnlyForManagedCloudGateway() {
        let error = GatewayResponseError(
            method: "talk.voices",
            code: "UNAVAILABLE",
            message: "untrusted human text",
            details: ["reason": AnyCodable("provider_not_configured")]
        )

        #expect(
            VoiceSettingsLoadPresentation.presentation(
                for: error,
                gatewayProvider: .fly
            ).action == .repairManagedConfiguration
        )
        #expect(
            VoiceSettingsLoadPresentation.presentation(
                for: error,
                gatewayProvider: .local
            ).action == .openProviderSetup
        )
        #expect(
            VoiceSettingsLoadPresentation.presentation(
                for: error,
                gatewayProvider: .manual
            ).action == .openProviderSetup
        )
    }

    @Test func successfulVoiceConfigurationRecoveryReloadsForSameAccount() {
        #expect(
            VoiceConfigurationRecoveryPolicy.completion(
                for: .response(.repaired),
                requestAccountID: "account-a",
                currentAccountID: "account-a"
            ) == .reload
        )
        #expect(
            VoiceConfigurationRecoveryPolicy.completion(
                for: .response(.alreadyConfigured),
                requestAccountID: "account-a",
                currentAccountID: "account-a"
            ) == .reload
        )
    }

    @Test func voiceConfigurationRecoveryRequestOutlivesTheExplicitServerBudgets() {
        let lifecycleAndOwnershipChecks: TimeInterval = 68 + 68
        let wakeLifecycleFence: TimeInterval = 2 + 2 + 2
        let wakeAndHealth: TimeInterval = 5 + 30 + 60 + 13
        let talkReadAndActivatedPatch: TimeInterval = 120 + 120
        let minimumExplicitServerBudget = lifecycleAndOwnershipChecks
            + wakeLifecycleFence
            + wakeAndHealth
            + talkReadAndActivatedPatch

        #expect(VoiceConfigurationRecoveryRequestPolicy.timeoutSeconds == 600)
        #expect(VoiceConfigurationRecoveryRequestPolicy.timeoutSeconds > minimumExplicitServerBudget)
        #expect(VoiceConfigurationRecoveryRequestPolicy.timeoutSeconds - minimumExplicitServerBudget > 100)
    }

    @Test(arguments: [
        (wasReady: false, isReady: true, reloadPending: true, expected: true),
        (wasReady: true, isReady: true, reloadPending: true, expected: false),
        (wasReady: false, isReady: false, reloadPending: true, expected: false),
        (wasReady: false, isReady: true, reloadPending: false, expected: false),
    ])
    func configurationRecoveryReloadWaitsForANewOperatorReadyEdge(
        wasReady: Bool,
        isReady: Bool,
        reloadPending: Bool,
        expected: Bool
    ) {
        #expect(
            VoiceConfigurationRecoveryPolicy.shouldConsumePendingReload(
                wasReady: wasReady,
                isReady: isReady,
                reloadPending: reloadPending
            ) == expected
        )
    }

    @Test func failedVoiceConfigurationRecoveryRemainsRetryableForSameAccount() {
        #expect(
            VoiceConfigurationRecoveryPolicy.completion(
                for: .failed,
                requestAccountID: "account-a",
                currentAccountID: "account-a"
            ) == .showFailure
        )
        #expect(
            VoiceConfigurationRecoveryPolicy.completion(
                for: .response(.subscriptionRequired),
                requestAccountID: "account-a",
                currentAccountID: "account-a"
            ) == .openProviderSetup
        )
    }

    @Test func voiceConfigurationRecoveryDiscardsCompletionAfterAccountChange() {
        #expect(
            VoiceConfigurationRecoveryPolicy.completion(
                for: .response(.repaired),
                requestAccountID: "account-a",
                currentAccountID: "account-b"
            ) == .discardAccountChange
        )
        #expect(
            VoiceConfigurationRecoveryPolicy.completion(
                for: .failed,
                requestAccountID: "account-a",
                currentAccountID: nil
            ) == .discardAccountChange
        )
    }

    @Test func cancelledRecoveryCannotClearANewerAttempt() {
        let cancelledAttempt = UUID()
        let replacementAttempt = UUID()

        #expect(
            !VoiceConfigurationRecoveryPolicy.ownsCurrentAttempt(
                attemptID: cancelledAttempt,
                currentAttemptID: replacementAttempt
            )
        )
        #expect(
            VoiceConfigurationRecoveryPolicy.ownsCurrentAttempt(
                attemptID: replacementAttempt,
                currentAttemptID: replacementAttempt
            )
        )
        #expect(
            !VoiceConfigurationRecoveryPolicy.ownsCurrentAttempt(
                attemptID: cancelledAttempt,
                currentAttemptID: nil
            )
        )
    }

    @Test @MainActor
    func managedRecoveryLetsCancelledViewDetachWhileAReplacementJoinsTheSameMutation() async {
        let coordinator = VoiceConfigurationRecoveryCoordinator()
        let barrier = VoiceRecoveryTestBarrier()
        var requestCount = 0

        let disappearingView = Task { @MainActor in
            await coordinator.recover(accountID: "account-a") {
                requestCount += 1
                await barrier.wait()
                return VoiceConfigurationRecoveryResponse(outcome: .repaired)
            }
        }
        while !barrier.isWaiting {
            await Task.yield()
        }
        #expect(coordinator.inFlightWaiterCount(for: "account-a") == 1)
        disappearingView.cancel()
        for _ in 0..<20 where coordinator.inFlightWaiterCount(for: "account-a") != 0 {
            await Task.yield()
        }
        #expect(coordinator.inFlightWaiterCount(for: "account-a") == 0)
        #expect(await disappearingView.value == .cancelled)

        let replacementView = Task { @MainActor in
            await coordinator.recover(accountID: "account-a") {
                requestCount += 1
                return VoiceConfigurationRecoveryResponse(outcome: .alreadyConfigured)
            }
        }
        await Task.yield()

        #expect(requestCount == 1)
        #expect(coordinator.inFlightWaiterCount(for: "account-a") == 1)
        barrier.release()
        #expect(await replacementView.value == .response(.repaired))
        #expect(coordinator.inFlightWaiterCount(for: "account-a") == 0)
        #expect(requestCount == 1)
    }

    @Test func voiceRecoveryAccountIdentityReadsOnlyTheJWTSubject() {
        let token = "e30.eyJzdWIiOiJhY2NvdW50LWEiLCJyb2xlIjoidXNlciJ9.signature"

        #expect(VoiceConfigurationAccountIdentity.accountID(fromJWT: token) == "account-a")
        #expect(VoiceConfigurationAccountIdentity.accountID(fromJWT: "invalid") == nil)
    }

    @Test func longLivedRecoveryCanMutateAuthOnlyForItsCapturedAccount() {
        let accountAToken = "e30.eyJzdWIiOiJhY2NvdW50LWEifQ.signature"
        let accountBToken = "e30.eyJzdWIiOiJhY2NvdW50LWIifQ.signature"

        #expect(
            VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
                requestAccountID: "account-a",
                authorityTokens: [accountAToken],
                currentToken: accountAToken
            )
        )
        #expect(
            !VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
                requestAccountID: "account-a",
                authorityTokens: [accountAToken],
                currentToken: accountBToken
            )
        )
        #expect(
            !VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
                requestAccountID: "account-a",
                authorityTokens: [accountAToken],
                currentToken: nil
            )
        )
        let replacementAccountAToken = "e30.eyJzdWIiOiJhY2NvdW50LWEifQ.new-signature"
        #expect(
            !VoiceConfigurationRecoveryAuthorizationPolicy.canMutateCurrentAuthentication(
                requestAccountID: "account-a",
                authorityTokens: [accountAToken],
                currentToken: replacementAccountAToken
            )
        )
    }

    @Test @MainActor
    func recoveryRequestKeepsImmutableCapturedAuthorityAfterCurrentAccountChanges() async throws {
        var currentAuthority = "account-a-token"
        let capturedAuthority = currentAuthority
        let request = VoiceConfigurationRecoveryRequest(accountID: "account-a") {
            #expect(capturedAuthority == "account-a-token")
            return VoiceConfigurationRecoveryResponse(outcome: .repaired)
        }

        currentAuthority = "account-b-token"
        #expect(request.accountID == "account-a")
        #expect(try await request.perform() == VoiceConfigurationRecoveryResponse(outcome: .repaired))
        #expect(currentAuthority == "account-b-token")
    }

    @Test func sameVoiceIDOnDifferentProviderDoesNotConfirmReadback() {
        let selection = VoiceSettingsSelection(
            provider: "other-provider",
            voiceID: "shared-voice",
            modelID: nil,
            outputFormat: nil
        )

        #expect(!selection.matches(provider: "elevenlabs", voiceID: "shared-voice"))
        #expect(selection.matches(provider: "OTHER-PROVIDER", voiceID: "shared-voice"))
    }

    @Test(arguments: [
        (operatorReady: true, aggregateConnected: true, expected: true),
        (operatorReady: true, aggregateConnected: false, expected: true),
        (operatorReady: false, aggregateConnected: true, expected: false),
        (operatorReady: false, aggregateConnected: false, expected: false),
    ])
    func voiceSettingsReadinessFollowsOnlyTheOperatorLeg(
        operatorReady: Bool,
        aggregateConnected: Bool,
        expected: Bool
    ) {
        #expect(
            VoiceSettingsReadinessPolicy.canIssueOperatorRequests(
                operatorReady: operatorReady,
                aggregateConnected: aggregateConnected
            ) == expected
        )
    }

    @Test func rejectedFreshHashWriteDoesNotPollOrChangeSelection() {
        let decision = VoiceSaveLifecyclePolicy.afterPatch(
            .rejected,
            previousVoiceID: "old",
            requestedVoiceID: "new"
        )

        #expect(!decision.shouldPoll)
        #expect(!decision.isConfirmed)
        #expect(decision.visibleVoiceID == "old")
    }

    @Test func ambiguousPatchIsConfirmedByRestartReadback() {
        let afterPatch = VoiceSaveLifecyclePolicy.afterPatch(
            .ambiguous,
            previousVoiceID: "old",
            requestedVoiceID: "new"
        )
        let afterReadback = VoiceSaveLifecyclePolicy.afterReadback(
            .matched,
            previousVoiceID: "old",
            requestedVoiceID: "new"
        )

        #expect(afterPatch.shouldPoll)
        #expect(afterPatch.visibleVoiceID == "new")
        #expect(afterReadback.isConfirmed)
        #expect(afterReadback.visibleVoiceID == "new")
    }

    @Test(arguments: [VoiceConfigReadback.different, .unavailable])
    func failedRestartReadbackRestoresPreviousSelection(_ readback: VoiceConfigReadback) {
        let decision = VoiceSaveLifecyclePolicy.afterReadback(
            readback,
            previousVoiceID: "old",
            requestedVoiceID: "new"
        )

        #expect(!decision.isConfirmed)
        #expect(decision.visibleVoiceID == "old")
    }
}

@MainActor
private final class VoicePreviewTestBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

@MainActor
private final class VoiceRecoveryTestBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}
