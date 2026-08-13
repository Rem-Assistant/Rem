#if os(macOS)
import Foundation
import Testing
import OpenClawChatUI
@testable import RemClawMac

struct MacChatTransportRunLifecycleTests {
    @Test func localAuthProfileInventoryIsMetadataOnlyAndRejectsMalformedState() {
        let valid = Data(#"{"version":1,"profiles":{"anthropic:default":{"type":"api_key","provider":"anthropic","key":"secret"},"openai:default":{"type":"api_key","provider":"openai","key":"other"}}}"#.utf8)

        #expect(LocalGatewayManager.configuredProviderIDs(fromAuthProfilesData: valid) == [
            "anthropic", "openai",
        ])
        #expect(LocalGatewayManager.configuredProviderIDs(
            fromAuthProfilesData: Data(#"{"profiles":[]}"#.utf8)
        ) == nil)
    }

    @Test func runtimeAvailabilityRejectsExpiredMissingAndUnresolvedLocalProfileInventory() {
        let inventory = Data(#"{"version":1,"profiles":{"expired":{"type":"token","provider":"anthropic","token":"old","expires":1},"missing":{"type":"api_key","provider":"openai"},"unresolved":{"type":"api_key","provider":"google","keyRef":{"source":"env","id":"MISSING_KEY"}}}}"#.utf8)
        #expect(LocalGatewayManager.configuredProviderIDs(fromAuthProfilesData: inventory) == [
            "anthropic", "google", "openai",
        ])

        // The local Mac route now consumes only the active gateway runtime's structured result;
        // raw inventory above cannot widen this verified set.
        let runtimeResult: [ProviderAuthAvailabilityPayload.Provider] = [
            .init(provider: "anthropic", available: false),
            .init(provider: "openai", available: false),
            .init(provider: "google", available: false),
        ]
        #expect(ModelPickerPolicy.runtimeAvailableProviderIDs(from: runtimeResult).isEmpty)
    }

    @Test func runtimeAvailabilityPreservesEnvAndSyntheticAuthAbsentFromLocalProfileInventory() {
        let emptyInventory = Data(#"{"version":1,"profiles":{}}"#.utf8)
        #expect(LocalGatewayManager.configuredProviderIDs(fromAuthProfilesData: emptyInventory) == [])

        let runtimeResult: [ProviderAuthAvailabilityPayload.Provider] = [
            .init(provider: "amazon-bedrock", available: true),
            .init(provider: "custom-local", available: true),
        ]
        #expect(ModelPickerPolicy.runtimeAvailableProviderIDs(from: runtimeResult) == [
            "amazon-bedrock", "custom-local",
        ])
    }

    @Test func modelCatalogDecodesForMacComposerAndAuthProbes() throws {
        let data = Data(#"{"models":[{"id":"gpt-5.4","name":"GPT-5.4","provider":"openai","contextwindow":128000},{"id":"gemini-2.5-pro","name":"Gemini 2.5 Pro","provider":"google-generative-ai"}]}"#.utf8)

        let choices = try MacChatTransport.decodeModelChoices(from: data)

        #expect(choices.map(\.selectionID) == [
            "openai/gpt-5.4",
            "google-generative-ai/gemini-2.5-pro",
        ])
        #expect(choices.map(\.contextWindow) == [128_000, nil])
    }

    @Test func modelCatalogPreservesCompletenessTriState() throws {
        let complete = try MacChatTransport.decodeModelCatalog(
            from: Data(#"{"models":[],"catalogComplete":true}"#.utf8))
        let incomplete = try MacChatTransport.decodeModelCatalog(
            from: Data(#"{"models":[],"catalogComplete":false}"#.utf8))
        let legacyUnknown = try MacChatTransport.decodeModelCatalog(
            from: Data(#"{"models":[]}"#.utf8))

        #expect(complete.completeness == .complete)
        #expect(incomplete.completeness == .incomplete)
        #expect(legacyUnknown.completeness == .unknown)
    }

    @Test func activityPreservesRawExecutionRunIDAndCanonicalizesSession() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"execution-run","stream":"thinking","data":{"text":"Checking"}}"#.utf8)
        )

        let evidence = MacChatTransport.activeRunLifecycleEvidence(
            from: payload,
            sessionKey: "agent:main:chat-mac"
        )

        #expect(evidence == RunLifecycleEvidence(
            run: .init(sessionKey: "chat-mac", runID: "execution-run"),
            phase: .active
        ))
    }

    @Test func localSendRegistersExactRunIdentityBeforeAgentActivity() {
        #expect(MacChatTransport.localRunLifecycleEvidence(
            sessionKey: "agent:main:chat-mac",
            runID: "execution-run"
        ) == RunLifecycleEvidence(
            run: .init(sessionKey: "chat-mac", runID: "execution-run"),
            phase: .localRegistered
        ))
    }

    @Test func terminalRequiresKnownStateAndExactRunIdentity() {
        #expect(MacChatTransport.terminalRunLifecycleEvidence(
            state: "error",
            sessionKey: "agent:main:chat-mac",
            runID: "execution-run"
        ) == RunLifecycleEvidence(
            run: .init(sessionKey: "chat-mac", runID: "execution-run"),
            phase: .terminal(.error)
        ))
        #expect(MacChatTransport.terminalRunLifecycleEvidence(
            state: "final",
            sessionKey: "chat-mac",
            runID: nil
        ) == nil)
        #expect(MacChatTransport.terminalRunLifecycleEvidence(
            state: "delta",
            sessionKey: "chat-mac",
            runID: "execution-run"
        ) == nil)
    }

    @Test func malformedOuterCannotHideSensitiveInnerJSON() {
        let scan = UnknownToolContentProjection.jsonContainerScan(
            #"prefix { broken {"authorization":"Bearer secret"} trailing"#
        )
        #expect(scan.containsStructuredContainer)
        #expect(scan.bytesVisited <= 65_536)
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Set authorization preferences {later}"
        ))
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Cookie recipe {flour}"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            #"prefix " ignored {"authorization":"Bearer hidden-secret"}"#
        ))
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: required before calendar access."
        ))
        #expect(!UnknownToolContentProjection.containsStructuredEnvelope(
            "Cookie: recipe preferences are saved."
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.secret"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: Bearer !"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Authorization: Basic x"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Cookie: session=abc123secret"
        ))
        #expect(UnknownToolContentProjection.containsStructuredEnvelope(
            "Set-Cookie: s=!"
        ))
        #expect(UnknownToolContentProjection.jsonContainerScan("[1,2").containsStructuredContainer)
        #expect(UnknownToolContentProjection.jsonContainerScan(
            #"["sk-live-secret""#
        ).containsStructuredContainer)
        #expect(!UnknownToolContentProjection.jsonContainerScan(
            "Here is [a brief aside] for context."
        ).containsStructuredContainer)
        #expect(UnknownToolContentProjection.jsonContainerScan(
            #"prefix " ignored ["sk-live-secret""#
        ).containsStructuredContainer)
        #expect(!UnknownToolContentProjection.jsonContainerScan(
            #"She said "use [brackets] in prose" and finished."#
        ).containsStructuredContainer)

        let longProse = String(repeating: "This is an ordinary sentence. ", count: 3_000)
        let longScan = UnknownToolContentProjection.jsonContainerScan(longProse)
        #expect(longScan.containsStructuredContainer)
        #expect(longScan.bytesVisited == 65_536)
    }

    @MainActor
    @Test func exactTombstonesSurviveSessionSwitchAndRejectOlderEpoch() {
        let source = RunLifecycleEpochSource()
        let store = RunLifecycleEvidenceStore(epochSource: source)
        let firstEpoch = store.beginConnectionEpoch()
        let run = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "run-a")
        store.record(.init(run: run, phase: .terminal(.final), connectionEpoch: firstEpoch))
        store.retainOnly(sessionKey: "chat-b")
        store.record(.init(run: run, phase: .active, connectionEpoch: firstEpoch))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)

        let nextEpoch = store.beginConnectionEpoch()
        store.record(.init(run: run, phase: .active, connectionEpoch: nextEpoch))
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "older-epoch"),
            phase: .active,
            connectionEpoch: firstEpoch
        ))
        #expect(store.activeRunIDs(for: "chat-a") == ["run-a"])
    }

    @MainActor
    @Test func replacementTransportRetiresOldSubscriptionIdentity() {
        let source = RunLifecycleEpochSource()
        let store = RunLifecycleEvidenceStore(epochSource: source)
        let oldTransport = store.beginTransportEpoch()
        guard let oldReconnect = source.issueSubscription(for: oldTransport.transportID) else {
            Issue.record("Current transport must receive a subscription epoch")
            return
        }
        store.setCurrentConnectionEpoch(oldReconnect)

        let replacement = store.beginTransportEpoch()
        #expect(source.issueSubscription(for: oldTransport.transportID) == nil)
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "delayed-old"),
            phase: .active,
            connectionEpoch: oldReconnect
        ))
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "replacement"),
            phase: .active,
            connectionEpoch: replacement.epoch
        ))
        #expect(store.activeRunIDs(for: "chat-a") == ["replacement"])
    }

    @MainActor
    @Test func transportSetupGateRejectsInvertedCompletionAndTeardownWhileAwaiting() {
        let gate = ChatTransportSetupGate()
        let lifecycleStore = RunLifecycleEvidenceStore()
        var installed: [String] = []
        let a = gate.begin(
            bindingKey: "gateway-a|chat-a",
            lifecycleStore: lifecycleStore
        )
        let b = gate.begin(
            bindingKey: "gateway-b|chat-b",
            lifecycleStore: lifecycleStore
        )

        #expect(lifecycleStore.epochSource.issueSubscription(
            for: a.lifecycleLease.transportID
        ) == nil)
        #expect(!gate.commit(
            a.ticket,
            currentBindingKey: "gateway-b|chat-b",
            isReady: true
        ) { installed.append("A") })
        #expect(gate.commit(
            b.ticket,
            currentBindingKey: "gateway-b|chat-b",
            isReady: true
        ) { installed.append("B") })
        #expect(installed == ["B"])

        let teardown = gate.begin(
            bindingKey: "gateway-c|chat-c",
            lifecycleStore: lifecycleStore
        )
        gate.invalidate()
        #expect(!gate.commit(
            teardown.ticket,
            currentBindingKey: "gateway-c|chat-c",
            isReady: true
        ) { installed.append("C") })
        #expect(installed == ["B"])
    }

    @MainActor
    @Test func transportSetupRemainsReadyWhenOnlyNodeLegFails() {
        let health = GatewaySessionHealthSnapshot.compose(
            operatorSessionState: .connected,
            nodeSessionState: .failed("node unavailable"),
            gatewayProcessState: .running,
            manualRecoveryState: .nodeRetryRequired,
            detail: "Chat remains available"
        )
        #expect(ChatTransportSetupReadiness.isReady(
            operatorReady: true,
            sessionHealth: health
        ))

        let gate = ChatTransportSetupGate()
        let ticket = gate.begin(bindingKey: "gateway|chat")
        var installed = false
        #expect(gate.commit(
            ticket,
            currentBindingKey: "gateway|chat",
            isReady: ChatTransportSetupReadiness.isReady(
                operatorReady: true,
                sessionHealth: health
            )
        ) { installed = true })
        #expect(installed)
    }

    @MainActor
    @Test func tombstoneTTLBoundaryAndCapacityOverflowAreBounded() {
        var currentTime: TimeInterval = 3_000
        let store = RunLifecycleEvidenceStore(
            terminalCapacity: 512,
            terminalTTL: 120,
            now: { currentTime }
        )
        let epoch = store.beginConnectionEpoch()
        let oldest = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "run-0")
        for index in 0..<513 {
            store.record(.init(
                run: .init(sessionKey: "chat-a", runID: "run-\(index)"),
                phase: .terminal(.final),
                connectionEpoch: epoch
            ))
        }
        store.record(.init(run: oldest, phase: .active, connectionEpoch: epoch))
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "new-during-overflow"),
            phase: .active,
            connectionEpoch: epoch
        ))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)

        currentTime = 3_060
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "terminal-during-overflow-1"),
            phase: .terminal(.final),
            connectionEpoch: epoch
        ))
        currentTime = 3_119
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "terminal-during-overflow-2"),
            phase: .terminal(.final),
            connectionEpoch: epoch
        ))

        currentTime = 3_120
        store.record(.init(
            run: .init(sessionKey: "chat-a", runID: "new-after-ttl"),
            phase: .active,
            connectionEpoch: epoch
        ))
        #expect(store.activeRunIDs(for: "chat-a") == ["new-after-ttl"])
    }

    @MainActor
    @Test func duplicateTerminalRefreshesOnlyOneTombstone() {
        var currentTime: TimeInterval = 5_000
        let store = RunLifecycleEvidenceStore(terminalTTL: 120, now: { currentTime })
        let epoch = store.beginConnectionEpoch()
        let run = RunLifecycleEvidence.Run(sessionKey: "chat-a", runID: "same-run")
        store.record(.init(run: run, phase: .terminal(.final), connectionEpoch: epoch))
        currentTime = 5_100
        for _ in 0..<1_000 {
            store.record(.init(run: run, phase: .terminal(.final), connectionEpoch: epoch))
        }
        #expect(store.terminalTombstoneCount == 1)

        currentTime = 5_219
        store.record(.init(run: run, phase: .active, connectionEpoch: epoch))
        #expect(store.activeRunIDs(for: "chat-a").isEmpty)
        currentTime = 5_220
        store.record(.init(run: run, phase: .active, connectionEpoch: epoch))
        #expect(store.activeRunIDs(for: "chat-a") == ["same-run"])
    }
}
#endif
