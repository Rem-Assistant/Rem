import Testing
import Foundation
import OpenClawKit
@testable import RemClaw

@Suite("Usage slot failure policy", .serialized)
struct UsageSlotFailurePolicyTests {
    @Test("Voice denial is visibly muted and recovers with one unmute")
    func voiceDenialPresentation() {
        let presentation = VoiceQuotaDeniedPresentation.recoverable(
            message: "Couldn't verify your plan."
        )

        #expect(!presentation.isListening)
        #expect(presentation.isMuted)
        #expect(presentation.statusText == "Couldn't verify your plan.")
    }

    @Test("Voice denial preserves recognized speech without claiming it was sent")
    @MainActor
    func voiceDenialPreservesRetryableUtterance() {
        let manager = RemTalkModeManager()

        manager.preserveDeniedUtterance("Please keep this request")

        #expect(manager.transcriptionState == .transcribing("Please keep this request"))
        #expect(manager.latestUserPreview == "Please keep this request")
        #expect(manager.messages.isEmpty)
        #expect(manager.voiceTranscripts.isEmpty)
    }

    @Test("A-B-A route switch during voice consume cannot restore old speech on Unmute")
    @MainActor
    func voiceRouteSwitchRetiresLateDeniedUtterance() async {
        let probe = DelayedConsumeRequester()
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { authority in try await probe.request(authority: authority) },
            defaults: Self.isolatedDefaults(named: #function)
        )
        let manager = RemTalkModeManager()
        manager.attachGateway(GatewayNodeSession())
        manager.attachUsageService(service)
        manager.updateGatewayConnected(true)
        manager.updateSessionKey("session-a")
        let originalRoute = manager.currentVoiceRoute()
        manager.preserveDeniedUtterance("speech for A", route: originalRoute)

        let processing = Task {
            await manager.processTranscript("speech for A", restartAfter: false)
        }
        await probe.waitUntilStarted()
        manager.updateSessionKey("session-b")
        manager.updateSessionKey("session-a")
        probe.succeed(statusCode: 400, body: Data())
        await processing.value

        // Reusing A's string does not restore the old attachment authority at consume, send, or
        // completion suspension boundaries. A late callback and Unmute remain inert.
        #expect(!manager.isCurrentVoiceRoute(originalRoute))
        manager.preserveDeniedUtterance("speech for A", route: originalRoute)
        manager.unmute()
        #expect(manager.transcriptionState == .idle)
        #expect(manager.latestUserPreview == nil)
        #expect(manager.messages.isEmpty)
        #expect(manager.voiceTranscripts.isEmpty)
    }

    @Test(
        "A-B-A invalidates voice authority at every suspension boundary",
        arguments: ["consume", "send", "completion"]
    )
    @MainActor
    func voiceRouteGenerationRejectsReusedSessionKey(_ boundary: String) {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let captured = manager.currentVoiceRoute()

        manager.updateSessionKey("session-b")
        manager.updateSessionKey("session-a")

        #expect(!manager.isCurrentVoiceRoute(captured), "stale at \(boundary)")
    }

    @Test(
        "Stop invalidates voice authority through completion history and catch",
        arguments: ["completion", "history", "catch"]
    )
    @MainActor
    func voiceStopInvalidatesEveryTailBoundary(_ boundary: String) {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let captured = manager.currentVoiceRoute()

        manager.stop()

        #expect(!manager.isCurrentVoiceRoute(captured), "stale at \(boundary)")
    }

    @Test("Empty voice detach invalidates attachment authority")
    @MainActor
    func emptyVoiceDetachInvalidatesAuthority() {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let captured = manager.currentVoiceRoute()

        manager.updateSessionKey(nil)

        #expect(!manager.isCurrentVoiceRoute(captured))
    }

    @Test("A-B-A stale task owner cannot clear the replacement task slot")
    @MainActor
    func voiceTaskSlotOwnershipSurvivesReusedRoute() {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let oldRoute = manager.currentVoiceRoute()
        let oldOwner = UUID()

        manager.updateSessionKey("session-b")
        manager.updateSessionKey("session-a")
        let newRoute = manager.currentVoiceRoute()
        let newOwner = UUID()

        #expect(!RemTalkModeManager.taskOwnerCanMutate(
            capturedOwner: oldOwner,
            currentOwner: newOwner,
            capturedRoute: oldRoute,
            currentRoute: newRoute
        ))
        #expect(RemTalkModeManager.taskOwnerCanMutate(
            capturedOwner: newOwner,
            currentOwner: newOwner,
            capturedRoute: newRoute,
            currentRoute: newRoute
        ))
    }

    @Test("A-B cancellation cannot publish A's late playback interruption into B")
    @MainActor
    func staleIncrementalPlaybackResultCannotMutateReplacement() async {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let routeA = manager.currentVoiceRoute()
        let ownerA = UUID()
        let ownerB = UUID()
        let gate = TranscriptTailTestGate()
        var currentOwner: UUID? = ownerA
        var currentRoute = routeA
        var currentGeneration: UInt64 = 71
        var replacementInterruptedAt: Double? = 42

        let stalePlayback = Task { @MainActor in
            await gate.suspend()
            guard RemTalkModeManager.incrementalTaskCanMutate(
                capturedOwner: ownerA,
                currentOwner: currentOwner,
                capturedRoute: routeA,
                currentRoute: currentRoute,
                capturedGeneration: 71,
                currentGeneration: currentGeneration
            ) else { return }
            replacementInterruptedAt = 7
        }
        await gate.waitUntilSuspended()

        manager.updateSessionKey("session-b")
        currentOwner = ownerB
        currentRoute = manager.currentVoiceRoute()
        currentGeneration = 72
        await gate.resume()
        await stalePlayback.value

        #expect(replacementInterruptedAt == 42)
        #expect(RemTalkModeManager.incrementalTaskCanMutate(
            capturedOwner: ownerB,
            currentOwner: ownerB,
            capturedRoute: currentRoute,
            currentRoute: currentRoute,
            capturedGeneration: 72,
            currentGeneration: 72
        ))
    }

    @Test("A stale scheduled transcript cannot adopt replacement route authority")
    @MainActor
    func scheduledTranscriptKeepsCapturedRoute() async {
        var consumeCount = 0
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in
                consumeCount += 1
                throw UsageError.notAuthenticated
            },
            defaults: Self.isolatedDefaults(named: #function)
        )
        let manager = RemTalkModeManager()
        manager.attachGateway(GatewayNodeSession())
        manager.attachUsageService(service)
        manager.updateGatewayConnected(true)
        manager.updateSessionKey("session-a")
        let capturedRoute = manager.currentVoiceRoute()

        manager.stop()
        manager.updateSessionKey("session-a")
        await manager.processTranscript(
            "stale scheduled speech",
            restartAfter: false,
            route: capturedRoute
        )

        #expect(consumeCount == 0)
        #expect(manager.messages.isEmpty)
        #expect(manager.voiceTranscripts.isEmpty)
        #expect(manager.latestUserPreview == nil)
    }

    @Test("A-B-A stale composer cannot finish or clear replacement speech")
    @MainActor
    func composerTaskOwnershipIncludesGeneration() {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let oldRoute = manager.currentVoiceRoute()
        let oldOwner = UUID()

        manager.updateSessionKey("session-b")
        manager.updateSessionKey("session-a")
        let newRoute = manager.currentVoiceRoute()
        let newOwner = UUID()

        #expect(!RemTalkModeManager.composerTaskCanMutate(
            capturedOwner: oldOwner,
            currentOwner: newOwner,
            capturedRoute: oldRoute,
            currentRoute: newRoute,
            capturedIncrementalGeneration: 7,
            currentIncrementalGeneration: 8
        ))
        #expect(!RemTalkModeManager.composerTaskCanMutate(
            capturedOwner: newOwner,
            currentOwner: newOwner,
            capturedRoute: newRoute,
            currentRoute: newRoute,
            capturedIncrementalGeneration: 7,
            currentIncrementalGeneration: 8
        ))
        #expect(RemTalkModeManager.composerTaskCanMutate(
            capturedOwner: newOwner,
            currentOwner: newOwner,
            capturedRoute: newRoute,
            currentRoute: newRoute,
            capturedIncrementalGeneration: 8,
            currentIncrementalGeneration: 8
        ))
    }

    @Test("Same-route barge-in retires the old transcript turn and speech generation")
    @MainActor
    func sameRouteBargeInRetiresOldTranscriptTail() {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let route = manager.currentVoiceRoute()
        let oldOwner = UUID()
        let replacementOwner = UUID()

        #expect(!RemTalkModeManager.transcriptTurnCanMutate(
            capturedOwner: oldOwner,
            currentOwner: replacementOwner,
            capturedRoute: route,
            currentRoute: route,
            expectedGeneration: 21,
            currentGeneration: 22
        ))
        #expect(RemTalkModeManager.transcriptTurnCanMutate(
            capturedOwner: replacementOwner,
            currentOwner: replacementOwner,
            capturedRoute: route,
            currentRoute: route,
            expectedGeneration: 22,
            currentGeneration: 22
        ))
    }

    @Test(
        "Suspended same-route transcript tails cannot adopt replacement speech",
        arguments: ["no-reply", "finalization", "catch"]
    )
    @MainActor
    func suspendedSameRouteTranscriptTailStaysRetired(_ tail: String) async {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let route = manager.currentVoiceRoute()
        let oldOwner = UUID()
        let replacementOwner = UUID()
        let gate = TranscriptTailTestGate()
        var currentOwner = oldOwner
        var currentGeneration: UInt64 = 41
        var mutations: [String] = []

        let oldTail = Task { @MainActor in
            await gate.suspend()
            guard RemTalkModeManager.transcriptTurnCanMutate(
                capturedOwner: oldOwner,
                currentOwner: currentOwner,
                capturedRoute: route,
                currentRoute: route,
                expectedGeneration: 41,
                currentGeneration: currentGeneration
            ) else { return }
            mutations.append(tail)
        }
        await gate.waitUntilSuspended()

        // A same-session barge-in replaces both authorities while the old no-reply/final/catch
        // continuation is suspended.
        currentOwner = replacementOwner
        currentGeneration = 42
        await gate.resume()
        await oldTail.value

        #expect(mutations.isEmpty)
        #expect(RemTalkModeManager.transcriptTurnCanMutate(
            capturedOwner: replacementOwner,
            currentOwner: replacementOwner,
            capturedRoute: route,
            currentRoute: route,
            expectedGeneration: 42,
            currentGeneration: 42
        ))
    }

    @Test("Composer overlap rejects suspended transcript stream deltas")
    @MainActor
    func composerOverlapCannotPolluteTranscriptStream() async {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let route = manager.currentVoiceRoute()
        let transcriptOwner = UUID()
        let composerOwner = UUID()
        let gate = TranscriptTailTestGate()
        var currentGeneration: UInt64 = 51
        var currentComposerOwner: UUID?
        var acceptedDeltas: [String] = []

        let oldTranscriptStream = Task { @MainActor in
            await gate.suspend()
            guard RemTalkModeManager.streamAssistantCanMutate(
                route: route,
                currentRoute: route,
                expectedGeneration: 51,
                currentGeneration: currentGeneration,
                transcriptOwner: transcriptOwner,
                currentTranscriptOwner: transcriptOwner,
                composerOwner: nil,
                currentComposerOwner: currentComposerOwner
            ) else { return }
            acceptedDeltas.append("old transcript delta")
        }
        await gate.waitUntilSuspended()

        // Production `speakNextResponse` resets incremental speech before installing its owner.
        currentGeneration = 52
        currentComposerOwner = composerOwner
        await gate.resume()
        await oldTranscriptStream.value

        #expect(acceptedDeltas.isEmpty)
        #expect(RemTalkModeManager.streamAssistantCanMutate(
            route: route,
            currentRoute: route,
            expectedGeneration: 52,
            currentGeneration: 52,
            transcriptOwner: nil,
            currentTranscriptOwner: transcriptOwner,
            composerOwner: composerOwner,
            currentComposerOwner: composerOwner
        ))
    }

    @Test("Generation-only overlap cannot idle replacement response phase")
    @MainActor
    func transcriptDeferRequiresCapturedSpeechGeneration() async {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let route = manager.currentVoiceRoute()
        let owner = UUID()
        let gate = TranscriptTailTestGate()
        var currentGeneration: UInt64 = 61
        var didSetIdle = false

        let oldDefer = Task { @MainActor in
            await gate.suspend()
            if RemTalkModeManager.transcriptTurnCanMutate(
                capturedOwner: owner,
                currentOwner: owner,
                capturedRoute: route,
                currentRoute: route,
                expectedGeneration: 61,
                currentGeneration: currentGeneration
            ) {
                didSetIdle = true
            }
        }
        await gate.waitUntilSuspended()

        currentGeneration = 62
        await gate.resume()
        await oldDefer.value

        #expect(!didSetIdle)
    }

    @Test(
        "Composer takeover retires pre-speech transcript continuations",
        arguments: ["quota", "gateway-acceptance"]
    )
    @MainActor
    func composerTakeoverRetiresSuspendedPreSpeechTurn(_ suspension: String) async {
        let manager = RemTalkModeManager()
        manager.updateSessionKey("session-a")
        let route = manager.currentVoiceRoute()
        let owner = UUID()
        let gate = TranscriptTailTestGate()
        var currentGeneration: UInt64 = 71
        var didResetComposerSpeech = false

        let suspendedTranscript = Task { @MainActor in
            await gate.suspend()
            guard RemTalkModeManager.transcriptTurnCanMutate(
                capturedOwner: owner,
                currentOwner: owner,
                capturedRoute: route,
                currentRoute: route,
                expectedGeneration: 71,
                currentGeneration: currentGeneration
            ) else { return }
            didResetComposerSpeech = true
        }
        await gate.waitUntilSuspended()

        // `speakNextResponse` establishes composer speech by resetting incremental generation while
        // the transcript owner and same-session route remain otherwise unchanged.
        currentGeneration = 72
        await gate.resume()
        await suspendedTranscript.value

        #expect(!didResetComposerSpeech, "stale after \(suspension)")
    }

    @Test("Composer takeover after a committed consume disposes the charge without dispatch")
    @MainActor
    func composerTakeoverAfterConsumeDisposesExactReservation() async throws {
        var consumeCount = 0
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in
                consumeCount += 1
                return try Self.successfulConsumeResponse()
            },
            defaults: Self.isolatedDefaults(named: #function)
        )
        let manager = RemTalkModeManager()
        manager.attachGateway(GatewayNodeSession())
        manager.attachUsageService(service)
        manager.updateGatewayConnected(true)
        manager.updateSessionKey("session-a")
        let postReservationGate = TranscriptTailTestGate()
        manager.afterVoiceQuotaReservationForTesting = {
            await postReservationGate.suspend()
        }

        let processing = Task { @MainActor in
            await manager.processTranscript("stale voice turn", restartAfter: false)
        }
        await postReservationGate.waitUntilSuspended()
        #expect(service.pendingDispatchReservationCount == 1)
        manager.beginComposerSpeechTakeoverForTesting()
        await postReservationGate.resume()
        await processing.value

        #expect(consumeCount == 1)
        #expect(manager.voiceChatDispatchCountForTesting == 0)
        #expect(service.pendingDispatchReservationCount == 0)
        #expect(!service.reservationRetryBlocked)
        #expect(manager.messages.isEmpty)
        #expect(manager.voiceTranscripts.isEmpty)

        manager.afterVoiceQuotaReservationForTesting = nil
        let future = try await service.consumeRequestSlot()
        #expect(consumeCount == 2)
        service.markReservedRequestCancelledBeforeDispatch(future)
        #expect(!service.reservationRetryBlocked)
        manager.stop()
    }

    @Test("Voice cancellation abort failure propagates and the exact run can retry")
    func voiceCancellationAbortCanRetryExactRun() async throws {
        let probe = VoiceAbortRetryProbe()

        do {
            try await RemTalkModeManager.abortAcceptedChatRun(
                runID: "voice-accepted-run",
                sessionKey: "voice-session",
                requester: { json in try await probe.request(json) }
            )
            Issue.record("Expected the first exact voice abort to fail")
        } catch let error as RemTalkModeManager.AcceptedChatRunAbortError {
            #expect(error.sessionKey == "voice-session")
            #expect(error.runID == "voice-accepted-run")
        } catch {
            Issue.record("Expected the exact accepted-run abort error, got \(error)")
        }

        try await RemTalkModeManager.abortAcceptedChatRun(
            runID: "voice-accepted-run",
            sessionKey: "voice-session",
            requester: { json in try await probe.request(json) }
        )

        #expect(await probe.runIDs == ["voice-accepted-run", "voice-accepted-run"])
    }

    @Test("An ambiguous voice reservation cannot retry through Unmute")
    func voiceAmbiguousReservationIsNotRecoverable() {
        #expect(VoiceQuotaRetryPolicy.allowsUnmute(reservationRetryBlocked: false))
        #expect(!VoiceQuotaRetryPolicy.allowsUnmute(reservationRetryBlocked: true))
    }

    @Test("Quota exhaustion retains the backend quota detail")
    func quotaExceeded() {
        let quota = QuotaExceededError(
            type: "quota_exceeded",
            message: "Daily request limit reached",
            remaining: RemainingQuota(day: 0, month: 12)
        )

        switch UsageSlotFailurePolicy.classify(UsageError.quotaExceeded(quota)) {
        case .quotaExceeded(let classified):
            #expect(classified.message == quota.message)
            #expect(classified.remaining.day == 0)
            #expect(classified.remaining.month == 12)
        case .verificationUnavailable:
            Issue.record("Expected quota exhaustion to retain its structured detail")
        case .reservationRetryBlocked:
            Issue.record("Expected quota exhaustion, not an ambiguous reservation")
        }
    }

    @Test(
        "Definite pre-commit rejection never authorizes a send",
        arguments: [
            UsageError.notAuthenticated,
            UsageError.httpError(400),
            UsageError.invalidURL,
        ]
    )
    func unavailableAuthority(_ error: UsageError) {
        switch UsageSlotFailurePolicy.classify(error) {
        case .verificationUnavailable:
            break
        case .quotaExceeded, .reservationRetryBlocked:
            Issue.record("Unverified quota authority must fail closed")
        }
    }

    @Test("Ambiguous reservation failures block retry")
    func ambiguousReservationBlocksRetry() {
        for error in [
            UsageError.reservationOutcomeUnknown,
            UsageError.reservationRetryBlocked,
            UsageError.invalidResponse,
            UsageError.httpError(503),
        ] {
            switch UsageSlotFailurePolicy.classify(error) {
            case .reservationRetryBlocked:
                break
            case .quotaExceeded, .verificationUnavailable:
                Issue.record("Ambiguous completion must not offer a retry")
            }
        }
    }

    @Test("A transport-ambiguous production request is issued only once")
    @MainActor
    func productionServiceSuppressesSecondConsume() async {
        var requestCount = 0
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in
                requestCount += 1
                throw URLError(.timedOut)
            },
            defaults: Self.isolatedDefaults(named: #function)
        )

        do {
            try await service.consumeRequestSlot()
            Issue.record("Expected the first ambiguous response to fail closed")
        } catch let error as UsageError {
            guard case .reservationOutcomeUnknown = error else {
                Issue.record("Expected reservationOutcomeUnknown, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected UsageError, got \(error)")
        }

        do {
            try await service.consumeRequestSlot()
            Issue.record("Expected retry to remain blocked")
        } catch let error as UsageError {
            guard case .reservationRetryBlocked = error else {
                Issue.record("Expected reservationRetryBlocked, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected UsageError, got \(error)")
        }

        #expect(requestCount == 1)
        #expect(service.reservationRetryBlocked)
    }

    @Test("A committed 200 with unusable summary remains fenced until chat dispatch")
    @MainActor
    func committedMalformedResponseDoesNotBecomeRetry() async throws {
        var requestCount = 0
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in
                requestCount += 1
                return (Data("not-json".utf8), response)
            },
            defaults: Self.isolatedDefaults(named: #function)
        )

        let reservation = try await service.consumeRequestSlot()

        #expect(requestCount == 1)
        #expect(service.reservationRetryBlocked)
        service.markReservedRequestAccepted(reservation)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Concurrent callers issue only one reservation for an account and backend")
    @MainActor
    func concurrentConsumeIsSingleFlightPerScope() async throws {
        let probe = DelayedConsumeRequester()
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { authority in try await probe.request(authority: authority) },
            defaults: Self.isolatedDefaults(named: #function)
        )

        let first = Task { try await service.consumeRequestSlot() }
        await probe.waitUntilStarted()

        await expectUsageError(.reservationInProgress) {
            try await service.consumeRequestSlot()
        }
        #expect(probe.authorities.count == 1)

        probe.succeed(
            statusCode: 200,
            body: UsageConsumeResponse(
                ok: true,
                usage: UsageStats(day: 1, month: 1),
                remaining: RemainingQuota(day: 9, month: 99)
            )
        )
        let reservation = try await first.value
        #expect(service.reservationRetryBlocked)
        service.markReservedRequestAccepted(reservation)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Cancellation after a committed success preserves the dispatch fence across relaunch")
    @MainActor
    func committedSuccessThenCancellationCannotChargeRetry() async throws {
        let suiteName = "UsageSlotFailurePolicyTests.success-cancel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        var requestCount = 0
        let authority = Self.authority(accountID: "account-a")
        let service = UsageService(
            requestAuthorityProvider: { authority },
            consumeRequester: { _ in
                requestCount += 1
                return (Data("not-json".utf8), response)
            },
            defaults: defaults
        )

        let lifecycle = Task { @MainActor in
            let reservation = try await service.consumeRequestSlot()
            try await Task.sleep(for: .seconds(60))
            service.markReservedRequestAccepted(reservation)
        }
        while !service.reservationRetryBlocked { await Task.yield() }
        lifecycle.cancel()
        _ = try? await lifecycle.value

        let relaunched = UsageService(
            requestAuthorityProvider: { authority },
            consumeRequester: { _ in
                requestCount += 1
                return (Data("not-json".utf8), response)
            },
            defaults: try #require(UserDefaults(suiteName: suiteName))
        )
        await expectUsageError(.reservationRetryBlocked) {
            try await relaunched.consumeRequestSlot()
        }

        #expect(requestCount == 1)
        #expect(relaunched.reservationRetryBlocked)
    }

    @Test("Same-key text sends retain individual reservations across an account swap")
    @MainActor
    func textAcceptanceUsesOpaqueReservationAcrossAccountSwap() async throws {
        let state = MutableUsageAuthority(Self.authority(accountID: "account-a"))
        let response = try Self.successfulConsumeResponse()
        let service = UsageService(
            requestAuthorityProvider: { state.value },
            consumeRequester: { _ in response },
            defaults: Self.isolatedDefaults(named: #function)
        )

        let accountA = try await service.consumeRequestSlot()
        let accountAHandoff = TextRequestSlotHandoff()
        accountAHandoff.install(accountA)
        state.value = Self.authority(accountID: "account-b")
        let accountB = try await service.consumeRequestSlot()
        let accountBHandoff = TextRequestSlotHandoff()
        accountBHandoff.install(accountB)

        // Both transports may represent the same visible session key. Acceptance travels through
        // the individual send handoff, not that shared string.
        accountAHandoff.accept(using: service)
        state.value = Self.authority(accountID: "account-a")
        #expect(!service.reservationRetryBlocked)
        state.value = Self.authority(accountID: "account-b")
        #expect(service.reservationRetryBlocked)

        accountBHandoff.accept(using: service)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Voice acceptance retires its opaque reservation across an account swap")
    @MainActor
    func voiceAcceptanceUsesOpaqueReservationAcrossAccountSwap() async throws {
        let state = MutableUsageAuthority(Self.authority(accountID: "account-a"))
        let response = try Self.successfulConsumeResponse()
        let service = UsageService(
            requestAuthorityProvider: { state.value },
            consumeRequester: { _ in response },
            defaults: Self.isolatedDefaults(named: #function)
        )

        let accountA = try await service.consumeRequestSlot()
        state.value = Self.authority(accountID: "account-b")
        _ = try await service.consumeRequestSlot()

        service.markReservedRequestAccepted(accountA)
        state.value = Self.authority(accountID: "account-a")
        #expect(!service.reservationRetryBlocked)
        state.value = Self.authority(accountID: "account-b")
        #expect(service.reservationRetryBlocked)
    }

    @Test("A 5xx production response blocks a second consume")
    @MainActor
    func serverAmbiguitySuppressesSecondConsume() async throws {
        var requestCount = 0
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        ))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in
                requestCount += 1
                return (Data(), response)
            },
            defaults: Self.isolatedDefaults(named: #function)
        )

        for expectedError in ["reservationOutcomeUnknown", "reservationRetryBlocked"] {
            do {
                try await service.consumeRequestSlot()
                Issue.record("Expected \(expectedError)")
            } catch let error as UsageError {
                switch (expectedError, error) {
                case ("reservationOutcomeUnknown", .reservationOutcomeUnknown),
                     ("reservationRetryBlocked", .reservationRetryBlocked):
                    break
                default:
                    Issue.record("Expected \(expectedError), got \(error)")
                }
            } catch {
                Issue.record("Expected UsageError, got \(error)")
            }
        }

        #expect(requestCount == 1)
    }

    @Test("A transport failure after the production 401 retry installs the ambiguity fence")
    @MainActor
    func postRefreshRetryTransportFailureBlocksSecondConsume() async {
        let originalExecutor = AuthenticatedHttpClient.requestExecutor
        let originalAuthorityProvider = AuthenticatedHttpClient.accountAuthorityProvider
        defer {
            AuthenticatedHttpClient.requestExecutor = originalExecutor
            AuthenticatedHttpClient.accountAuthorityProvider = originalAuthorityProvider
        }

        let authority = Self.authority(
            accountID: "account-a",
            token: Self.jwt(accountID: "account-a")
        )
        let probe = RetriedConsumeRequestExecutor()
        AuthenticatedHttpClient.requestExecutor = { request in
            try await probe.execute(request)
        }
        AuthenticatedHttpClient.accountAuthorityProvider = { authority }
        let service = UsageService(
            requestAuthorityProvider: { authority },
            consumeRequester: { captured in
                try await AuthenticatedHttpClient.request(
                    path: "/api/v1/usage/consume",
                    method: "POST",
                    body: Data("{}".utf8),
                    authority: captured
                )
            },
            defaults: Self.isolatedDefaults(named: #function)
        )

        await expectUsageError(.reservationOutcomeUnknown) {
            try await service.consumeRequestSlot()
        }
        await expectUsageError(.reservationRetryBlocked) {
            try await service.consumeRequestSlot()
        }

        #expect(probe.consumeCalls == 2)
        #expect(probe.refreshCalls == 1)
        #expect(service.reservationRetryBlocked)
    }

    @Test("Bound refresh dedupe includes the immutable backend URL")
    @MainActor
    func boundRefreshDedupeSeparatesBackendAuthorities() async throws {
        let originalExecutor = AuthenticatedHttpClient.requestExecutor
        defer { AuthenticatedHttpClient.requestExecutor = originalExecutor }

        let token = Self.jwt(accountID: "account-a")
        let firstAuthority = AuthenticatedHttpClient.AccountRequestAuthority(
            token: token,
            baseURL: "https://one.example.test",
            accountID: "account-a"
        )
        let secondAuthority = AuthenticatedHttpClient.AccountRequestAuthority(
            token: token,
            baseURL: "https://two.example.test",
            accountID: "account-a"
        )
        let probe = BoundRefreshRequestExecutor()
        AuthenticatedHttpClient.requestExecutor = { request in
            await probe.execute(request)
        }
        let first = Task {
            try await AuthenticatedHttpClient.request(
                path: "/resource",
                method: "GET",
                authority: firstAuthority
            )
        }
        #expect(await probe.waitUntilRefreshStarted(host: "one.example.test"))

        let second = Task {
            try await AuthenticatedHttpClient.request(
                path: "/resource",
                method: "GET",
                authority: secondAuthority
            )
        }
        #expect(await probe.waitUntilRefreshStarted(host: "two.example.test"))

        probe.completeRefresh(host: "one.example.test")
        probe.completeRefresh(host: "two.example.test")
        _ = try? await first.value
        _ = try? await second.value

        #expect(Set(probe.refreshHosts) == Set(["one.example.test", "two.example.test"]))
    }

    @Test("Concurrent summary and consume share one exact refreshed authority")
    @MainActor
    func concurrentSummaryAndConsumeAcceptSharedRefreshResult() async throws {
        let originalExecutor = AuthenticatedHttpClient.requestExecutor
        let originalAuthorityProvider = AuthenticatedHttpClient.accountAuthorityProvider
        let originalWaiterObserver = AuthenticatedHttpClient.boundRefreshWaiterObserver
        defer {
            AuthenticatedHttpClient.requestExecutor = originalExecutor
            AuthenticatedHttpClient.accountAuthorityProvider = originalAuthorityProvider
            AuthenticatedHttpClient.boundRefreshWaiterObserver = originalWaiterObserver
        }

        let original = Self.authority(
            accountID: "account-a",
            token: Self.jwt(accountID: "account-a")
        )
        let refreshed = Self.authority(
            accountID: "account-a",
            token: "shared-refreshed-token"
        )
        let state = MutableUsageAuthority(original)
        let probe = ConcurrentUsageRefreshExecutor()
        AuthenticatedHttpClient.accountAuthorityProvider = { state.value }
        AuthenticatedHttpClient.requestExecutor = { request in
            await probe.execute(request)
        }
        AuthenticatedHttpClient.boundRefreshWaiterObserver = {
            probe.recordBoundRefreshWaiter()
        }

        let summary = Task {
            try await AuthenticatedHttpClient.request(
                path: "/api/v1/usage/summary",
                method: "GET",
                authority: original
            )
        }
        await probe.waitUntilRefreshStarted()

        let consume = Task {
            try await AuthenticatedHttpClient.request(
                path: "/api/v1/usage/consume",
                method: "POST",
                body: Data("{}".utf8),
                authority: original
            )
        }
        await probe.waitUntilInitialRequest(path: "/api/v1/usage/consume")
        await probe.waitUntilBoundRefreshWaiters(2)

        // Model the first joined waiter installing this refresh result before the second waiter
        // resumes. Both may retry it; neither may overwrite a different third token.
        state.value = refreshed
        probe.completeRefresh(token: refreshed.token)

        let summaryResponse = try await summary.value
        let consumeResponse = try await consume.value
        #expect(summaryResponse.1.statusCode == 200)
        #expect(consumeResponse.1.statusCode == 200)
        #expect(probe.refreshCalls == 1)
        #expect(probe.requestCounts["/api/v1/usage/summary"] == 2)
        #expect(probe.requestCounts["/api/v1/usage/consume"] == 2)
        #expect(Set(probe.retryBearerTokens) == Set([refreshed.token]))
    }

    @Test("A retired or cancelled authority cannot issue the post-refresh retry")
    @MainActor
    func postRefreshRetryRequiresLiveExactAuthority() async {
        let originalExecutor = AuthenticatedHttpClient.requestExecutor
        let originalAuthorityProvider = AuthenticatedHttpClient.accountAuthorityProvider
        defer {
            AuthenticatedHttpClient.requestExecutor = originalExecutor
            AuthenticatedHttpClient.accountAuthorityProvider = originalAuthorityProvider
        }

        for scenario in RetryAuthorityRetirementScenario.allCases {
            let captured = Self.authority(
                accountID: "account-a",
                token: Self.jwt(accountID: "account-a")
            )
            let state = MutableUsageAuthority(captured)
            let probe = DelayedBoundRefreshRequestExecutor()
            AuthenticatedHttpClient.accountAuthorityProvider = { state.value }
            AuthenticatedHttpClient.requestExecutor = { request in
                await probe.execute(request)
            }

            let request = Task {
                try await AuthenticatedHttpClient.request(
                    path: "/api/v1/usage/consume",
                    method: "POST",
                    body: Data("{}".utf8),
                    authority: captured
                )
            }
            await probe.waitUntilRefreshStarted()

            switch scenario {
            case .signOut:
                state.value = nil
            case .accountReplacement:
                state.value = Self.authority(
                    accountID: "account-b",
                    token: Self.jwt(accountID: "account-b")
                )
            case .sameAccountNewerToken:
                state.value = Self.authority(
                    accountID: "account-a",
                    token: "unrelated-newer-account-a-token"
                )
            case .cancellation:
                request.cancel()
            }
            probe.completeRefresh()

            do {
                _ = try await request.value
                Issue.record("Expected \(scenario) to retire the retry")
            } catch let error as AuthenticatedHttpError {
                #expect(error == .notAuthenticated)
            } catch {
                Issue.record("Expected notAuthenticated for \(scenario), got \(error)")
            }
            #expect(probe.resourceCalls == 1)
            #expect(probe.refreshCalls == 1)
        }
    }

    @Test("Reset cannot reopen an ambiguous reservation for the same account")
    @MainActor
    func ambiguousResetSameAccountRemainsBlocked() async {
        var requestCount = 0
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in
                requestCount += 1
                throw URLError(.timedOut)
            },
            defaults: Self.isolatedDefaults(named: #function)
        )

        await expectUsageError(.reservationOutcomeUnknown) {
            try await service.consumeRequestSlot()
        }
        service.reset()
        await expectUsageError(.reservationRetryBlocked) {
            try await service.consumeRequestSlot()
        }

        #expect(requestCount == 1)
        #expect(service.reservationRetryBlocked)
    }

    @Test("An ambiguous account and backend remain blocked after service relaunch")
    @MainActor
    func ambiguousReservationPersistsAcrossRelaunch() async throws {
        let suiteName = "UsageSlotFailurePolicyTests.relaunch.\(UUID().uuidString)"
        let firstDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { firstDefaults.removePersistentDomain(forName: suiteName) }

        var requestCount = 0
        let firstAuthority = Self.authority(
            accountID: "account-a",
            token: "token-a",
            baseURL: " HTTPS://API.EXAMPLE.TEST/ "
        )
        let first = UsageService(
            requestAuthorityProvider: { firstAuthority },
            consumeRequester: { _ in
                requestCount += 1
                throw URLError(.timedOut)
            },
            defaults: firstDefaults
        )
        await expectUsageError(.reservationOutcomeUnknown) {
            try await first.consumeRequestSlot()
        }

        let relaunchedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let current = MutableUsageAuthority(Self.authority(
            accountID: "account-a",
            token: "token-a-refreshed"
        ))
        let relaunched = UsageService(
            requestAuthorityProvider: { current.value },
            consumeRequester: { _ in
                requestCount += 1
                throw URLError(.timedOut)
            },
            defaults: relaunchedDefaults
        )

        await expectUsageError(.reservationRetryBlocked) {
            try await relaunched.consumeRequestSlot()
        }
        #expect(requestCount == 1)

        current.value = Self.authority(
            accountID: "account-a",
            token: "token-a-refreshed",
            baseURL: "https://other.example.test"
        )
        #expect(!relaunched.reservationRetryBlocked)
    }

    @Test("Delayed account A 200 persists its captured token before reset retirement")
    @MainActor
    func delayedSuccessCannotCrossAccountReset() async throws {
        let state = MutableUsageAuthority(Self.authority(accountID: "account-a", token: "token-a"))
        let probe = DelayedConsumeRequester()
        let service = UsageService(
            requestAuthorityProvider: { state.value },
            consumeRequester: { authority in try await probe.request(authority: authority) },
            defaults: Self.isolatedDefaults(named: #function)
        )
        let consume = Task { try await service.consumeRequestSlot() }
        await probe.waitUntilStarted()

        service.reset()
        state.value = Self.authority(accountID: "account-b", token: "token-b")
        probe.succeed(
            statusCode: 200,
            body: UsageConsumeResponse(
                ok: true,
                usage: UsageStats(day: 1, month: 1),
                remaining: RemainingQuota(day: 9, month: 99)
            )
        )

        await expectUsageError(.reservationOutcomeUnknown) { try await consume.value }
        #expect(service.summary == nil)
        #expect(!service.quotaExceeded)
        #expect(!service.reservationRetryBlocked)
        #expect(service.pendingDispatchReservationCount == 1)
        #expect(probe.authorities == [Self.authority(accountID: "account-a", token: "token-a")])
        state.value = Self.authority(accountID: "account-a", token: "token-a-refreshed")
        #expect(service.reservationRetryBlocked)
    }

    @Test("Delayed account A quota response cannot publish into account B")
    @MainActor
    func delayedQuotaCannotCrossAccountReset() async throws {
        let state = MutableUsageAuthority(Self.authority(accountID: "account-a"))
        let probe = DelayedConsumeRequester()
        let service = UsageService(
            requestAuthorityProvider: { state.value },
            consumeRequester: { authority in try await probe.request(authority: authority) },
            defaults: Self.isolatedDefaults(named: #function)
        )
        let consume = Task { try await service.consumeRequestSlot() }
        await probe.waitUntilStarted()

        service.reset()
        state.value = Self.authority(accountID: "account-b")
        probe.succeed(
            statusCode: 429,
            body: QuotaErrorResponse(error: QuotaExceededError(
                type: "quota_exceeded",
                message: "Daily request limit reached",
                remaining: RemainingQuota(day: 0, month: 12)
            ))
        )

        await expectUsageError(.notAuthenticated) { try await consume.value }
        #expect(!service.quotaExceeded)
        #expect(service.quotaError == nil)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Cancelled-before-dispatch disposition clears only its exact account reservation")
    @MainActor
    func cancelledBeforeDispatchDispositionPreservesABIsolation() async throws {
        let state = MutableUsageAuthority(Self.authority(accountID: "account-a"))
        let response = try Self.successfulConsumeResponse()
        let service = UsageService(
            requestAuthorityProvider: { state.value },
            consumeRequester: { _ in response },
            defaults: Self.isolatedDefaults(named: #function)
        )

        let accountA = try await service.consumeRequestSlot()
        state.value = Self.authority(accountID: "account-b")
        let accountB = try await service.consumeRequestSlot()

        service.markReservedRequestCancelledBeforeDispatch(accountA)
        state.value = Self.authority(accountID: "account-a")
        #expect(!service.reservationRetryBlocked)

        let replacementA = try await service.consumeRequestSlot()
        service.markReservedRequestCancelledBeforeDispatch(replacementA)
        state.value = Self.authority(accountID: "account-b")
        #expect(service.reservationRetryBlocked)

        service.markReservedRequestCancelledBeforeDispatch(accountB)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Delayed account A transport ambiguity fences only account A after reset")
    @MainActor
    func delayedAmbiguityCannotCrossAccountReset() async {
        let state = MutableUsageAuthority(Self.authority(accountID: "account-a"))
        let probe = DelayedConsumeRequester()
        let service = UsageService(
            requestAuthorityProvider: { state.value },
            consumeRequester: { authority in try await probe.request(authority: authority) },
            defaults: Self.isolatedDefaults(named: #function)
        )
        let consume = Task { try await service.consumeRequestSlot() }
        await probe.waitUntilStarted()

        service.reset()
        state.value = Self.authority(accountID: "account-b")
        probe.fail(URLError(.timedOut))

        await expectUsageError(.reservationOutcomeUnknown) { try await consume.value }
        #expect(!service.reservationRetryBlocked)
        state.value = Self.authority(accountID: "account-a", token: "refreshed-a")
        #expect(service.reservationRetryBlocked)
    }

    @Test("A delayed account A summary cannot overwrite account B")
    @MainActor
    func delayedSummaryCannotCrossAccountReset() async {
        let state = MutableUsageAuthority(Self.authority(accountID: "account-a"))
        let probe = DelayedSummaryRequester()
        let service = UsageService(
            requestAuthorityProvider: { state.value },
            summaryRequester: { authority in try await probe.request(authority: authority) },
            defaults: Self.isolatedDefaults(named: #function)
        )

        let accountA = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(accountID: "account-a")

        service.reset()
        state.value = Self.authority(accountID: "account-b")
        let accountB = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(accountID: "account-b")

        probe.succeed(accountID: "account-b", summary: Self.summary(plan: "pro", day: 4))
        try? await accountB.value
        probe.succeed(accountID: "account-a", summary: Self.summary(plan: "free", day: 19))
        try? await accountA.value

        #expect(service.summary?.plan == "pro")
        #expect(service.summary?.usage.day == 4)
        #expect(!service.isLoading)
    }

    @MainActor
    private static func authority(
        accountID: String,
        token: String = "test-token",
        baseURL: String = "https://api.example.test"
    ) -> AuthenticatedHttpClient.AccountRequestAuthority {
        .init(token: token, baseURL: baseURL, accountID: accountID)
    }

    private static func isolatedDefaults(named name: String) -> UserDefaults {
        let suiteName = "UsageSlotFailurePolicyTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func jwt(accountID: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["sub": accountID])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private static func summary(plan: String, day: Int) -> UsageSummary {
        UsageSummary(
            plan: plan,
            status: "active",
            limits: PlanLimits(requestsPerDay: 20, requestsPerMonth: 200),
            usage: UsageStats(day: day, month: day),
            remaining: RemainingQuota(day: 20 - day, month: 200 - day)
        )
    }

    private static func successfulConsumeResponse() throws -> (Data, HTTPURLResponse) {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let body = UsageConsumeResponse(
            ok: true,
            usage: UsageStats(day: 1, month: 1),
            remaining: RemainingQuota(day: 9, month: 99)
        )
        return (try JSONEncoder().encode(body), response)
    }

    @MainActor
    private func expectUsageError(
        _ expected: UsageError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as UsageError {
            switch (expected, error) {
            case (.notAuthenticated, .notAuthenticated),
                 (.reservationOutcomeUnknown, .reservationOutcomeUnknown),
                 (.reservationRetryBlocked, .reservationRetryBlocked),
                 (.reservationInProgress, .reservationInProgress):
                break
            default:
                Issue.record("Expected \(expected), got \(error)")
            }
        } catch {
            Issue.record("Expected UsageError, got \(error)")
        }
    }
}

@MainActor
private final class MutableUsageAuthority {
    var value: AuthenticatedHttpClient.AccountRequestAuthority?
    init(_ value: AuthenticatedHttpClient.AccountRequestAuthority?) { self.value = value }
}

private enum RetryAuthorityRetirementScenario: CaseIterable {
    case signOut
    case accountReplacement
    case sameAccountNewerToken
    case cancellation
}

@MainActor
private final class DelayedConsumeRequester {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private(set) var authorities: [AuthenticatedHttpClient.AccountRequestAuthority] = []

    func request(
        authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) async throws -> (Data, HTTPURLResponse) {
        authorities.append(authority)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func succeed<Value: Encodable>(statusCode: Int, body: Value) {
        let data = try! JSONEncoder().encode(body)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        continuation?.resume(returning: (data, response))
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class RetriedConsumeRequestExecutor {
    private(set) var consumeCalls = 0
    private(set) var refreshCalls = 0

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/api/v1/auth/refresh" {
            refreshCalls += 1
            return httpResponse(
                statusCode: 200,
                data: Data("{\"access_token\":\"refreshed-account-a-token\"}".utf8),
                request: request
            )
        }

        consumeCalls += 1
        if consumeCalls == 1 {
            return httpResponse(statusCode: 401, data: Data(), request: request)
        }
        throw URLError(.timedOut)
    }
}

@MainActor
private final class DelayedBoundRefreshRequestExecutor {
    private var refreshContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private(set) var resourceCalls = 0
    private(set) var refreshCalls = 0

    func execute(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        if request.url?.path == "/api/v1/auth/refresh" {
            refreshCalls += 1
            return await withCheckedContinuation { refreshContinuation = $0 }
        }

        resourceCalls += 1
        return httpResponse(statusCode: 401, data: Data(), request: request)
    }

    func waitUntilRefreshStarted() async {
        while refreshContinuation == nil { await Task.yield() }
    }

    func completeRefresh() {
        guard let continuation = refreshContinuation else { return }
        refreshContinuation = nil
        let request = URLRequest(url: URL(string: "https://api.example.test/api/v1/auth/refresh")!)
        continuation.resume(returning: httpResponse(
            statusCode: 200,
            data: Data("{\"access_token\":\"refreshed-account-a-token\"}".utf8),
            request: request
        ))
    }
}

@MainActor
private final class BoundRefreshRequestExecutor {
    private var resourceCalls: [String: Int] = [:]
    private var refreshContinuations: [String: CheckedContinuation<(Data, HTTPURLResponse), Never>] = [:]
    private(set) var refreshHosts: [String] = []

    func execute(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        if request.url?.path == "/api/v1/auth/refresh" {
            refreshHosts.append(host)
            return await withCheckedContinuation { refreshContinuations[host] = $0 }
        }

        resourceCalls[host, default: 0] += 1
        let statusCode = resourceCalls[host] == 1 ? 401 : 200
        return httpResponse(statusCode: statusCode, data: Data(), request: request)
    }

    func waitUntilRefreshStarted(host: String) async -> Bool {
        for _ in 0..<2_000 {
            if refreshContinuations[host] != nil { return true }
            await Task.yield()
        }
        return false
    }

    func completeRefresh(host: String) {
        guard let continuation = refreshContinuations.removeValue(forKey: host) else { return }
        let request = URLRequest(url: URL(string: "https://\(host)/api/v1/auth/refresh")!)
        continuation.resume(returning: httpResponse(
            statusCode: 200,
            data: Data("{\"access_token\":\"refreshed-\(host)\"}".utf8),
            request: request
        ))
    }
}

@MainActor
private final class ConcurrentUsageRefreshExecutor {
    private var refreshContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private(set) var refreshCalls = 0
    private(set) var requestCounts: [String: Int] = [:]
    private(set) var retryBearerTokens: [String] = []
    private var boundRefreshWaiters = 0

    func execute(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        if path == "/api/v1/auth/refresh" {
            refreshCalls += 1
            return await withCheckedContinuation { refreshContinuation = $0 }
        }

        requestCounts[path, default: 0] += 1
        if requestCounts[path] == 1 {
            return httpResponse(statusCode: 401, data: Data(), request: request)
        }
        let bearer = request.value(forHTTPHeaderField: "Authorization")?
            .replacingOccurrences(of: "Bearer ", with: "") ?? ""
        retryBearerTokens.append(bearer)
        return httpResponse(statusCode: 200, data: Data("{}".utf8), request: request)
    }

    func waitUntilRefreshStarted() async {
        while refreshContinuation == nil { await Task.yield() }
    }

    func waitUntilInitialRequest(path: String) async {
        while requestCounts[path, default: 0] == 0 { await Task.yield() }
    }

    func recordBoundRefreshWaiter() {
        boundRefreshWaiters += 1
    }

    func waitUntilBoundRefreshWaiters(_ count: Int) async {
        while boundRefreshWaiters < count { await Task.yield() }
    }

    func completeRefresh(token: String) {
        guard let continuation = refreshContinuation else { return }
        refreshContinuation = nil
        let request = URLRequest(url: URL(string: "https://api.example.test/api/v1/auth/refresh")!)
        continuation.resume(returning: httpResponse(
            statusCode: 200,
            data: Data("{\"access_token\":\"\(token)\"}".utf8),
            request: request
        ))
    }
}

@MainActor
private final class DelayedSummaryRequester {
    private var continuations: [
        String: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ] = [:]

    func request(
        authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            continuations[authority.accountID] = continuation
        }
    }

    func waitUntilStarted(accountID: String) async {
        while continuations[accountID] == nil { await Task.yield() }
    }

    func succeed(accountID: String, summary: UsageSummary) {
        guard let continuation = continuations.removeValue(forKey: accountID) else { return }
        let request = URLRequest(url: URL(string: "https://api.example.test/api/v1/usage/summary")!)
        continuation.resume(returning: httpResponse(
            statusCode: 200,
            data: try! JSONEncoder().encode(summary),
            request: request
        ))
    }
}

private actor VoiceAbortRetryProbe {
    private(set) var runIDs: [String] = []

    func request(_ json: String) throws {
        struct Payload: Decodable { let runId: String }
        let data = try #require(json.data(using: .utf8))
        runIDs.append(try JSONDecoder().decode(Payload.self, from: data).runId)
        if runIDs.count == 1 { throw URLError(.timedOut) }
    }
}

private actor TranscriptTailTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        while continuation == nil { await Task.yield() }
    }

    func resume() {
        let suspended = continuation
        continuation = nil
        suspended?.resume()
    }
}

private func httpResponse(
    statusCode: Int,
    data: Data,
    request: URLRequest
) -> (Data, HTTPURLResponse) {
    (data, HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!)
}
