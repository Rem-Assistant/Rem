import Foundation
import OpenClawChatUI
import OpenClawKit
import Observation
import Testing
@testable import RemClawMac

@Suite("Mac quota reservation lifecycle", .serialized)
@MainActor
struct MacQuotaServiceTests {
    private enum MacAbortTestError: Error {
        case disconnected
    }

    @Test("Unknown and stale summaries reach the backend gate without plan inference")
    func unknownSummaryDoesNotInferFreePlan() {
        let exhausted = summary(dayRemaining: 0)

        #expect(MacQuotaAvailability.hasQuota(
            summary: nil,
            summaryIsCurrent: false,
            latestRemaining: nil
        ))
        #expect(MacQuotaAvailability.hasQuota(
            summary: exhausted,
            summaryIsCurrent: false,
            latestRemaining: nil
        ))
        #expect(!MacQuotaAvailability.hasQuota(
            summary: exhausted,
            summaryIsCurrent: true,
            latestRemaining: nil
        ))
        #expect(!MacQuotaAvailability.hasQuota(
            summary: nil,
            summaryIsCurrent: false,
            latestRemaining: RemainingQuota(day: 5, month: 0)
        ))
    }

    @Test("Reset publishes Mac text and voice unlock without falling back to summary zero")
    func retainedDenialExpiresAtReset() async {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-expiry", generation: 1)
        let observedAt = Date(timeIntervalSince1970: 1_786_406_340)
        var now = observedAt
        let scheduler = MacQuotaResetSchedulerProbe()
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults,
            now: { now },
            resetScheduler: scheduler.schedule
        )
        let retainedSummary = summary(dayRemaining: 0)

        service.recordAuthoritativeRemaining(RemainingQuota(day: 0, month: 20))
        #expect(service.latestRemaining?.day == 0)
        #expect(service.effectiveRemaining(
            fallbackSummary: retainedSummary,
            summaryIsCurrent: true
        )?.day == 0)
        #expect(scheduler.resetDate == observedAt.addingTimeInterval(60))

        let observation = MacObservationInvalidationProbe()
        withObservationTracking {
            _ = service.effectiveRemaining(
                fallbackSummary: retainedSummary,
                summaryIsCurrent: true
            )
        } onChange: {
            Task { @MainActor in observation.didInvalidate = true }
        }

        now = observedAt.addingTimeInterval(120)
        scheduler.fire()
        await Task.yield()
        #expect(observation.didInvalidate)
        #expect(service.latestRemaining == nil)
        // Text composer/presentation must not fall back to the still-current summary zero.
        #expect(service.effectiveRemaining(
            fallbackSummary: retainedSummary,
            summaryIsCurrent: true
        ) == nil)
        // Talk Mode reads latestRemaining directly; nil intentionally reaches the backend gate.
        #expect(MacVoiceQuotaCapturePolicy.decision(
            serviceAttached: true,
            reservationRetryBlocked: false,
            latestRemaining: service.latestRemaining
        ) == .allowed)
    }

    @Test("An ambiguous transport result persists a retry block for only its account and backend")
    func ambiguousResultPersistsPerScope() async {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let accountA = Self.authority(accountID: "account-a", generation: 1)
        let accountB = Self.authority(accountID: "account-b", generation: 2)
        var current: MacBackendAuthAuthority? = accountA
        var requestCount = 0

        let service = MacQuotaService(
            authorityProvider: { current },
            requester: { _ in
                requestCount += 1
                throw URLError(.timedOut)
            },
            defaults: defaults
        )
        let contextA = service.makeDispatchContext()!

        await expectReservationError(.outcomeUnknown) {
            _ = try await service.consumeRequestSlot(dispatchContext: contextA)
        }
        #expect(requestCount == 1)
        #expect(service.reservationRetryBlocked)
        await expectReservationError(.retryBlocked) {
            _ = try await service.consumeRequestSlot(dispatchContext: contextA)
        }
        #expect(requestCount == 1)

        current = accountB
        #expect(!service.reservationRetryBlocked)

        let reloaded = MacQuotaService(
            authorityProvider: { current },
            requester: { _ in throw URLError(.timedOut) },
            defaults: defaults
        )
        #expect(!reloaded.reservationRetryBlocked)
        current = accountA
        #expect(reloaded.reservationRetryBlocked)
    }

    @Test("A committed response retired by account replacement blocks replay only for the old account")
    func committedResponseCannotPublishAcrossAccounts() async {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let accountA = Self.authority(accountID: "account-a", generation: 10)
        let accountB = Self.authority(accountID: "account-b", generation: 11)
        var current: MacBackendAuthAuthority? = accountA
        let service = MacQuotaService(
            authorityProvider: { current },
            requester: { _ in
                current = accountB
                return (Self.consumeResponse(day: 8), Self.response(status: 200))
            },
            defaults: defaults
        )
        let contextA = service.makeDispatchContext()!

        await expectReservationError(.outcomeUnknown) {
            _ = try await service.consumeRequestSlot(dispatchContext: contextA)
        }
        #expect(!service.reservationRetryBlocked)
        current = accountA
        #expect(service.reservationRetryBlocked)
        service.markReservedRequestAcknowledged(in: contextA)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("A same-account token refresh may publish the reservation result")
    func sameAccountRefreshPublishes() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let original = Self.authority(accountID: "account-a", generation: 20, accountGeneration: 7)
        var current: MacBackendAuthAuthority? = original
        let service = MacQuotaService(
            authorityProvider: { current },
            requester: { _ in
                current = Self.authority(
                    accountID: "account-a",
                    generation: 21,
                    accountGeneration: 7
                )
                return (Self.consumeResponse(day: 6), Self.response(status: 200))
            },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!

        let token = try await service.consumeRequestSlot(dispatchContext: context)
        #expect(service.latestRemaining?.day == 6)
        #expect(service.reservationRetryBlocked)
        service.markReservedRequestAcknowledged(token)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("A structured 429 is a truthful quota denial without an ambiguity block")
    func quotaExceededIsNotAmbiguous() async {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-a", generation: 30)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in
                let payload = """
                {
                  "error": {
                    "type": "quota_exceeded",
                    "message": "Daily request limit reached",
                    "remaining": {"day": 0, "month": 4}
                  }
                }
                """
                return (Data(payload.utf8), Self.response(status: 429))
            },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!

        do {
            _ = try await service.consumeRequestSlot(dispatchContext: context)
            Issue.record("Expected quota denial")
        } catch let MacQuotaReservationError.quotaExceeded(quota) {
            #expect(quota.remaining.day == 0)
            #expect(quota.message == "Daily request limit reached")
        } catch {
            Issue.record("Expected quotaExceeded, got \(error)")
        }
        #expect(!service.reservationRetryBlocked)
        #expect(service.latestRemaining?.day == 0)
    }

    @Test("A voice-style malformed 200 stays fenced until its exact token dispatches")
    func malformedSuccessRequiresExactVoiceDispatch() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-a", generation: 40)
        var requestCount = 0
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in
                requestCount += 1
                return (Data("not-json".utf8), Self.response(status: 200))
            },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!

        let token = try await service.consumeRequestSlot(dispatchContext: context)
        await expectReservationError(.retryBlocked) {
            _ = try await service.consumeRequestSlot(dispatchContext: context)
        }
        #expect(requestCount == 1)
        #expect(service.reservationRetryBlocked)

        let relaunched = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in
                requestCount += 1
                return (Data("not-json".utf8), Self.response(status: 200))
            },
            defaults: defaults
        )
        #expect(relaunched.reservationRetryBlocked)
        let wrongToken = MacQuotaReservationToken(id: UUID(), dispatchContext: context)
        relaunched.markReservedRequestAcknowledged(wrongToken)
        #expect(relaunched.reservationRetryBlocked)
        relaunched.markReservedRequestAcknowledged(token)
        #expect(!relaunched.reservationRetryBlocked)

        _ = try await relaunched.consumeRequestSlot(dispatchContext: context)
        #expect(requestCount == 2)
    }

    @Test("Text preparation cancellation leaves its context fence across relaunch")
    func textCancellationBeforeDispatchCannotChargeRetry() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-a", generation: 45)
        var requestCount = 0
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in
                requestCount += 1
                return (Self.consumeResponse(day: 5), Self.response(status: 200))
            },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        let lifecycle = Task { @MainActor in
            _ = try await service.consumeRequestSlot(dispatchContext: context)
            try await Task.sleep(for: .seconds(60))
        }
        await waitUntil { service.reservationRetryBlocked }
        lifecycle.cancel()
        _ = try? await lifecycle.value

        let relaunched = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in
                requestCount += 1
                return (Self.consumeResponse(day: 4), Self.response(status: 200))
            },
            defaults: defaults
        )
        await expectReservationError(.retryBlocked) {
            _ = try await relaunched.consumeRequestSlot(dispatchContext: context)
        }
        #expect(requestCount == 1)
        relaunched.markReservedRequestAcknowledged(in: context)
        #expect(!relaunched.reservationRetryBlocked)
    }

    @Test("Text transport context cannot retire a replacement account and backend reservation")
    func replacementScopeCannotRetireAnotherToken() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let accountA = Self.authority(accountID: "account-a", generation: 46)
        let accountB = Self.authority(
            accountID: "account-b",
            generation: 47,
            backendURL: "https://replacement.example.test"
        )
        var current: MacBackendAuthAuthority? = accountA
        let service = MacQuotaService(
            authorityProvider: { current },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let contextA = service.makeDispatchContext()!
        let tokenA = try await service.consumeRequestSlot(dispatchContext: contextA)
        #expect(service.reservationRetryBlocked)

        current = accountB
        #expect(!service.reservationRetryBlocked)
        let contextB = service.makeDispatchContext()!
        let tokenB = try await service.consumeRequestSlot(dispatchContext: contextB)
        #expect(service.reservationRetryBlocked)

        service.markReservedRequestAcknowledged(in: contextA)
        #expect(service.reservationRetryBlocked)
        service.markReservedRequestAcknowledged(tokenA)
        #expect(service.reservationRetryBlocked)
        service.markReservedRequestAcknowledged(tokenB)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Pre-dispatch cancellation retires only its exact account reservation")
    func cancelledBeforeDispatchRetiresExactScopeOnly() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let accountA = Self.authority(accountID: "account-cancelled-a", generation: 48)
        let accountB = Self.authority(accountID: "account-cancelled-b", generation: 49)
        var current: MacBackendAuthAuthority? = accountA
        let service = MacQuotaService(
            authorityProvider: { current },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )

        let contextA = service.makeDispatchContext()!
        let tokenA = try await service.consumeRequestSlot(dispatchContext: contextA)
        current = accountB
        let contextB = service.makeDispatchContext()!
        let tokenB = try await service.consumeRequestSlot(dispatchContext: contextB)

        service.markReservedRequestCancelledBeforeDispatch(tokenA)
        #expect(service.reservationRetryBlocked)

        current = accountA
        #expect(!service.reservationRetryBlocked)
        let replacementA = try await service.consumeRequestSlot(dispatchContext: contextA)
        service.markReservedRequestCancelledBeforeDispatch(replacementA)
        #expect(!service.reservationRetryBlocked)

        current = accountB
        #expect(service.reservationRetryBlocked)
        service.markReservedRequestCancelledBeforeDispatch(tokenB)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Authoritative remaining quota cannot leak across account scope")
    func remainingIsAccountScoped() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let accountA = Self.authority(accountID: "account-a", generation: 50)
        let accountB = Self.authority(accountID: "account-b", generation: 51)
        var current: MacBackendAuthAuthority? = accountA
        let service = MacQuotaService(
            authorityProvider: { current },
            requester: { _ in (Data(), Self.response(status: 200)) },
            defaults: defaults
        )

        service.recordAuthoritativeRemaining(RemainingQuota(day: 0, month: 0))
        #expect(service.latestRemaining?.day == 0)
        current = accountB
        #expect(service.latestRemaining == nil)
    }

    @Test("Text cancellation after worker creation but before gateway start cannot send later")
    func textCancellationBeforeGatewayStartKeepsReservation() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-text-prestart", generation: 60)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let startGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                events.append("accepted")
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, _, _ in
                await MainActor.run { events.append(method) }
                return Self.acceptedChatSendResponse(runID: "late-text-run")
            },
            beforeChatGatewayStart: { await startGate.wait() }
        )

        let send = Task {
            try await transport.sendMessage(
                sessionKey: "text-prestart",
                message: "hello",
                thinking: "low",
                idempotencyKey: UUID().uuidString,
                attachments: []
            )
        }
        await startGate.waitUntilEntered()
        send.cancel()
        await startGate.open()
        await expectCancellation(of: send)

        #expect(events.values.isEmpty)
        #expect(service.reservationRetryBlocked)
    }

    @Test("Text cancellation after gateway start waits for acceptance, retires, then aborts exact run")
    func textCancellationAfterGatewayStartIsAcceptedThenAborted() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-text-started", generation: 61)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let responseGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                events.append("accepted")
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                if method == "chat.send" {
                    await MainActor.run { events.append("send-started") }
                    await responseGate.wait()
                    return Self.acceptedChatSendResponse(runID: "text-run-1")
                }
                let runID = Self.runID(from: paramsJSON) ?? "missing"
                let blocked = await MainActor.run { service.reservationRetryBlocked }
                await MainActor.run { events.append("abort:\(runID):blocked=\(blocked)") }
                return Data()
            }
        )

        let send = Task {
            try await transport.sendMessage(
                sessionKey: "text-started",
                message: "hello",
                thinking: "low",
                idempotencyKey: UUID().uuidString,
                attachments: []
            )
        }
        await waitUntil { events.values.contains("send-started") }
        send.cancel()

        // Simulated process termination here would leave the accepted quota token durable because
        // no gateway run acknowledgement has arrived yet.
        #expect(service.reservationRetryBlocked)
        #expect(!events.values.contains(where: { $0.hasPrefix("abort:") }))

        await responseGate.open()
        await expectCancellation(of: send)
        #expect(events.values == [
            "send-started",
            "accepted",
            "abort:text-run-1:blocked=false",
        ])
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Production abort before gateway start joins the pending text dispatch and prevents send")
    func productionAbortBeforeGatewayStartKeepsReservation() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-production-abort-prestart", generation: 64)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let startGate = MacDispatchTestGate()
        let abortJoinedGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let idempotencyKey = "pending-production-text-prestart"
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                events.append("accepted")
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, _, _ in
                await MainActor.run { events.append(method) }
                return Self.acceptedChatSendResponse(runID: "unexpected-text-run")
            },
            beforeChatGatewayStart: { await startGate.wait() },
            onPendingChatAbortJoined: { await abortJoinedGate.wait() }
        )

        let send = Task {
            try await transport.sendMessage(
                sessionKey: "production-text-prestart",
                message: "hello",
                thinking: "low",
                idempotencyKey: idempotencyKey,
                attachments: []
            )
        }
        await startGate.waitUntilEntered()
        let abort = Task {
            try await transport.abortRun(
                sessionKey: "production-text-prestart",
                runId: idempotencyKey
            )
        }
        await abortJoinedGate.waitUntilEntered()
        await abortJoinedGate.open()
        await startGate.open()

        await expectCancellation(of: send)
        try await abort.value
        #expect(events.values.isEmpty)
        #expect(service.reservationRetryBlocked)
    }

    @Test("Production abort after gateway start waits for acceptance and aborts the exact text run")
    func productionAbortAfterGatewayStartIsAcceptedThenAborted() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-production-abort-started", generation: 65)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let responseGate = MacDispatchTestGate()
        let abortJoinedGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let idempotencyKey = "pending-production-text-started"
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                events.append("accepted")
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                if method == "chat.send" {
                    await MainActor.run { events.append("send-started") }
                    await responseGate.wait()
                    return Self.acceptedChatSendResponse(runID: "production-text-run-1")
                }
                let runID = Self.runID(from: paramsJSON) ?? "missing"
                let blocked = await MainActor.run { service.reservationRetryBlocked }
                await MainActor.run { events.append("abort:\(runID):blocked=\(blocked)") }
                return Data()
            },
            onPendingChatAbortJoined: { await abortJoinedGate.wait() }
        )

        let send = Task {
            try await transport.sendMessage(
                sessionKey: "production-text-started",
                message: "hello",
                thinking: "low",
                idempotencyKey: idempotencyKey,
                attachments: []
            )
        }
        await waitUntil { events.values.contains("send-started") }
        let abort = Task {
            try await transport.abortRun(
                sessionKey: "production-text-started",
                runId: idempotencyKey
            )
        }
        await abortJoinedGate.waitUntilEntered()
        await abortJoinedGate.open()

        #expect(service.reservationRetryBlocked)
        #expect(!events.values.contains(where: { $0.hasPrefix("abort:") }))
        await responseGate.open()

        await expectCancellation(of: send)
        try await abort.value
        #expect(events.values == [
            "send-started",
            "accepted",
            "abort:production-text-run-1:blocked=false",
        ])
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Production abort after dispatch acknowledgement still aborts the exact text run once")
    func productionAbortAfterDispatchAcknowledgementAbortsExactRunOnce() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-production-abort-acknowledged", generation: 66)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let afterAcknowledgementGate = MacDispatchTestGate()
        let abortJoinedGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let idempotencyKey = "pending-production-text-acknowledged"
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                events.append("accepted")
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                if method == "chat.send" {
                    await MainActor.run { events.append("send-started") }
                    return Self.acceptedChatSendResponse(runID: "production-text-run-acknowledged")
                }
                let runID = Self.runID(from: paramsJSON) ?? "missing"
                let blocked = await MainActor.run { service.reservationRetryBlocked }
                await MainActor.run { events.append("abort:\(runID):blocked=\(blocked)") }
                return Data()
            },
            onPendingChatAbortJoined: { await abortJoinedGate.wait() },
            afterChatDispatchAcknowledged: { await afterAcknowledgementGate.wait() }
        )

        let send = Task {
            try await transport.sendMessage(
                sessionKey: "production-text-acknowledged",
                message: "hello",
                thinking: "low",
                idempotencyKey: idempotencyKey,
                attachments: []
            )
        }
        await afterAcknowledgementGate.waitUntilEntered()
        #expect(events.values == ["send-started", "accepted"])
        #expect(!service.reservationRetryBlocked)

        let abort = Task {
            try await transport.abortRun(
                sessionKey: "production-text-acknowledged",
                runId: idempotencyKey
            )
        }
        await abortJoinedGate.waitUntilEntered()
        await abortJoinedGate.open()
        try await abort.value

        // A second production abort joins the same completed boundary and must not issue another
        // gateway request while the owning send is still inside its post-acknowledgement work.
        try await transport.abortRun(
            sessionKey: "production-text-acknowledged",
            runId: idempotencyKey
        )
        #expect(events.values == [
            "send-started",
            "accepted",
            "abort:production-text-run-acknowledged:blocked=false",
        ])

        await afterAcknowledgementGate.open()
        let response = try await send.value
        #expect(response.runId == "production-text-run-acknowledged")
    }

    @Test("Production abort after send return resolves stale idempotency to the exact run once")
    func productionAbortAfterSendReturnUsesExactRunTombstone() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-production-abort-returned", generation: 67)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let events = MacDispatchEventLog()
        let idempotencyKey = "stale-production-text-returned"
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                if method == "chat.send" {
                    return Self.acceptedChatSendResponse(runID: "production-text-run-returned")
                }
                let runID = Self.runID(from: paramsJSON) ?? "missing"
                await MainActor.run { events.append("abort:\(runID)") }
                return Data()
            }
        )

        _ = try await transport.sendMessage(
            sessionKey: "production-text-returned",
            message: "hello",
            thinking: "low",
            idempotencyKey: idempotencyKey,
            attachments: []
        )

        try await transport.abortRun(
            sessionKey: "production-text-returned",
            runId: idempotencyKey
        )
        try await transport.abortRun(
            sessionKey: "production-text-returned",
            runId: idempotencyKey
        )
        #expect(events.values == ["abort:production-text-run-returned"])
    }

    @Test("Accepted run alias shares one tombstone abort across concurrent and sequential callers")
    func acceptedRunAliasDeduplicatesConcurrentAndSequentialAborts() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-accepted-alias", generation: 73)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let abortGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                if method == "chat.send" {
                    return Self.acceptedChatSendResponse(runID: "accepted-alias-run")
                }
                let runID = Self.runID(from: paramsJSON) ?? "missing"
                await MainActor.run { events.append("abort:\(runID)") }
                await abortGate.wait()
                return Data()
            }
        )

        _ = try await transport.sendMessage(
            sessionKey: "accepted-alias-session",
            message: "hello",
            thinking: "low",
            idempotencyKey: "accepted-alias-local",
            attachments: []
        )

        let first = Task {
            try await transport.abortRun(
                sessionKey: "accepted-alias-session",
                runId: "accepted-alias-run"
            )
        }
        await abortGate.waitUntilEntered()
        let second = Task {
            try await transport.abortRun(
                sessionKey: "accepted-alias-session",
                runId: "accepted-alias-run"
            )
        }
        await Task.yield()
        await abortGate.open()
        try await first.value
        try await second.value

        try await transport.abortRun(
            sessionKey: "accepted-alias-session",
            runId: "accepted-alias-run"
        )
        try await transport.abortRun(
            sessionKey: "accepted-alias-session",
            runId: "accepted-alias-local"
        )
        #expect(events.values == ["abort:accepted-alias-run"])
    }

    @Test("Failed exact abort stays retryable through the resolved dispatch tombstone")
    func failedExactAbortCanRetryThroughTombstone() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-production-abort-retry", generation: 68)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        _ = try await service.consumeRequestSlot(dispatchContext: context)
        let events = MacDispatchEventLog()
        let idempotencyKey = "stale-production-text-retry"
        let transport = MacChatTransport(
            gateway: GatewayNodeSession(),
            quotaDispatchContext: context,
            onChatSendAcknowledged: { acceptedContext in
                service.markReservedRequestAcknowledged(in: acceptedContext)
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                if method == "chat.send" {
                    return Self.acceptedChatSendResponse(runID: "production-text-run-retry")
                }
                let runID = Self.runID(from: paramsJSON) ?? "missing"
                let attempt = await MainActor.run {
                    events.append("abort:\(runID)")
                    return events.values.count
                }
                if attempt == 1 { throw MacAbortTestError.disconnected }
                return Data()
            }
        )

        _ = try await transport.sendMessage(
            sessionKey: "production-text-retry",
            message: "hello",
            thinking: "low",
            idempotencyKey: idempotencyKey,
            attachments: []
        )

        do {
            try await transport.abortRun(
                sessionKey: "production-text-retry",
                runId: idempotencyKey
            )
            Issue.record("Expected exact abort failure")
        } catch MacAbortTestError.disconnected {
            // Expected and remains retryable.
        } catch {
            Issue.record("Unexpected abort failure: \(error)")
        }
        try await transport.abortRun(
            sessionKey: "production-text-retry",
            runId: idempotencyKey
        )
        try await transport.abortRun(
            sessionKey: "production-text-retry",
            runId: idempotencyKey
        )
        #expect(events.values == [
            "abort:production-text-run-retry",
            "abort:production-text-run-retry",
        ])
    }

    @Test("Resolved dispatch tombstones are strictly bounded without evicting live boundaries")
    func resolvedDispatchTombstonesAreBounded() {
        let registry = MacActiveQuotaDispatchRegistry(maxResolvedEntries: 2)
        let live = MacGatewayDispatchBoundary()
        registry.register(live, sessionKey: "live", idempotencyKey: "live")

        for index in 0..<3 {
            let boundary = MacGatewayDispatchBoundary()
            let key = "resolved-\(index)"
            registry.register(boundary, sessionKey: key, idempotencyKey: key)
            boundary.resolve()
            registry.markResolved(boundary, sessionKey: key, idempotencyKey: key)
        }

        #expect(registry.resolvedEntryCount == 2)
        #expect(registry.boundary(sessionKey: "live", idempotencyKey: "live") === live)
        #expect(registry.boundary(sessionKey: "resolved-0", idempotencyKey: "resolved-0") == nil)
        #expect(registry.boundary(sessionKey: "resolved-2", idempotencyKey: "resolved-2") != nil)
    }

    @Test("Voice stop before gateway worker start prevents send and retires its exact token")
    func voiceStopBeforeGatewayStartRetiresReservation() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-prestart", generation: 62)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        let reservation = try await service.consumeRequestSlot(dispatchContext: context)
        let startGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let manager = RemMacTalkModeManager()
        manager.beforeChatGatewayStart = { await startGate.wait() }
        manager.chatLifecycleRequester = { method, _, _ in
            await MainActor.run { events.append(method) }
            return Self.acceptedChatSendResponse(runID: "late-voice-run")
        }

        let send = Task { @MainActor in
            do {
                _ = try await manager.sendChat(
                    "hello",
                    sessionKey: "voice-prestart",
                    gateway: GatewayNodeSession(),
                    reservation: reservation,
                    quotaService: service
                )
                Issue.record("Expected stop cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }
        manager.activeTranscriptTask = send
        await startGate.waitUntilEntered()
        manager.stop()
        await startGate.open()
        await send.value

        #expect(events.values.isEmpty)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Voice stop after gateway start waits for run acceptance before exact abort")
    func voiceStopAfterGatewayStartIsAcceptedThenAborted() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-started", generation: 63)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        let reservation = try await service.consumeRequestSlot(dispatchContext: context)
        let responseGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let manager = RemMacTalkModeManager()
        manager.chatLifecycleRequester = { method, paramsJSON, _ in
            if method == "chat.send" {
                await MainActor.run { events.append("send-started") }
                await responseGate.wait()
                return Self.acceptedChatSendResponse(runID: "voice-run-1")
            }
            let runID = Self.runID(from: paramsJSON) ?? "missing"
            let blocked = await MainActor.run { service.reservationRetryBlocked }
            await MainActor.run { events.append("abort:\(runID):blocked=\(blocked)") }
            return Data()
        }

        let send = Task { @MainActor in
            do {
                _ = try await manager.sendChat(
                    "hello",
                    sessionKey: "voice-started",
                    gateway: GatewayNodeSession(),
                    reservation: reservation,
                    quotaService: service
                )
                Issue.record("Expected stop cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }
        manager.activeTranscriptTask = send
        await waitUntil { events.values.contains("send-started") }
        manager.stop()
        #expect(service.reservationRetryBlocked)
        #expect(!events.values.contains(where: { $0.hasPrefix("abort:") }))

        await responseGate.open()
        await send.value
        #expect(events.values == [
            "send-started",
            "abort:voice-run-1:blocked=false",
        ])
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Failed Stop abort retains the exact voice run and retries it before a later turn")
    func failedVoiceStopAbortRetriesBeforeLaterTurn() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-abort-retry", generation: 75)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let context = service.makeDispatchContext()!
        let reservation = try await service.consumeRequestSlot(dispatchContext: context)
        let responseGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let gateway = GatewayNodeSession()
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("voice-abort-retry")
        manager.attachGateway(gateway)
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.chatLifecycleRequester = { method, paramsJSON, _ in
            if method == "chat.send" {
                let sendAttempt = await MainActor.run {
                    events.append("send")
                    return events.values.filter { $0 == "send" }.count
                }
                if sendAttempt == 1 {
                    await responseGate.wait()
                    return Self.acceptedChatSendResponse(runID: "voice-abort-retry-run")
                }
                throw URLError(.cannotConnectToHost)
            }
            let runID = Self.runID(from: paramsJSON) ?? "missing"
            let abortAttempt = await MainActor.run {
                events.append("abort:\(runID)")
                return events.values.filter { $0.hasPrefix("abort:") }.count
            }
            if abortAttempt == 1 { throw URLError(.networkConnectionLost) }
            return Data()
        }

        let firstSend = Task { @MainActor in
            do {
                _ = try await manager.sendChat(
                    "first",
                    sessionKey: "voice-abort-retry",
                    gateway: gateway,
                    reservation: reservation,
                    quotaService: service
                )
                Issue.record("Expected the first exact Stop abort to fail")
            } catch let error as RemMacTalkModeManager.AcceptedChatRunAbortError {
                events.append("abort-error:\(error.runID)")
            } catch {
                Issue.record("Unexpected Stop abort error: \(error)")
            }
        }
        manager.activeTranscriptTask = firstSend
        await waitUntil { events.values == ["send"] }
        manager.stop()
        await responseGate.open()
        await firstSend.value

        #expect(manager.pendingAcceptedVoiceAbortRunID == "voice-abort-retry-run")
        #expect(!service.reservationRetryBlocked)

        manager.startTranscriptProcessing("later turn", restartAfter: false)
        let laterTurn = try #require(manager.activeTranscriptTask)
        await laterTurn.value

        #expect(events.values == [
            "send",
            "abort:voice-abort-retry-run",
            "abort-error:voice-abort-retry-run",
            "abort:voice-abort-retry-run",
            "send",
        ])
        #expect(manager.pendingAcceptedVoiceAbortRunID == nil)
    }

    @Test("Talk Mode capture gates only on known denial, ambiguity, or missing authority")
    func voiceCapturePolicy() {
        #expect(MacVoiceQuotaCapturePolicy.decision(
            serviceAttached: true,
            reservationRetryBlocked: false,
            latestRemaining: nil
        ) == .allowed)
        #expect(MacVoiceQuotaCapturePolicy.decision(
            serviceAttached: true,
            reservationRetryBlocked: false,
            latestRemaining: RemainingQuota(day: 0, month: 5)
        ) == .quotaExceeded(QuotaPresentation.make(
            plan: nil,
            remaining: RemainingQuota(day: 0, month: 5)
        )))
        #expect(MacVoiceQuotaCapturePolicy.decision(
            serviceAttached: true,
            reservationRetryBlocked: false,
            latestRemaining: RemainingQuota(day: 5, month: 0)
        ) == .quotaExceeded(QuotaPresentation.make(
            plan: nil,
            remaining: RemainingQuota(day: 5, month: 0)
        )))
        #expect(MacVoiceQuotaCapturePolicy.decision(
            serviceAttached: true,
            reservationRetryBlocked: true,
            latestRemaining: RemainingQuota(day: 3, month: 5)
        ) == .reservationRetryBlocked)
        #expect(MacVoiceQuotaCapturePolicy.decision(
            serviceAttached: false,
            reservationRetryBlocked: false,
            latestRemaining: nil
        ) == .verificationUnavailable)
    }

    @Test("Ambiguity banner never claims quota exhaustion or advertises upgrade")
    func ambiguityBannerIsTruthful() {
        let ambiguity = MacQuotaBannerPolicy.message(reservationRetryBlocked: true)
        #expect(ambiguity.contains("unresolved"))
        #expect(!ambiguity.localizedCaseInsensitiveContains("daily limit"))
        #expect(!ambiguity.localizedCaseInsensitiveContains("upgrade"))
        #expect(MacQuotaBannerPolicy.message(
            reservationRetryBlocked: false,
            plan: "free",
            remaining: RemainingQuota(day: 0, month: 10)
        ) == "Daily request limit reached. Upgrade or come back tomorrow.")
    }

    @Test("Denied Talk Mode transcript is cleared on route change and cannot unmute into the new route")
    func deniedVoiceTranscriptCannotCrossRoutes() {
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("session-a")
        manager.applyQuotaDenial(
            transcript: "keep this on A",
            originSessionKey: "session-a",
            message: "Quota unavailable"
        )
        #expect(manager.transcriptionState == .transcribing("keep this on A"))
        #expect(manager.isMuted)

        manager.updateSessionKey("session-b")
        #expect(manager.transcriptionState == .idle)
        manager.isEnabled = true
        manager.unmute()
        #expect(manager.isMuted)
        #expect(manager.transcriptionState == .idle)
        #expect(manager.attachedSessionKey == "session-b")
    }

    @Test("Talk Mode route A to B during quota cannot dispatch or publish into B")
    func voiceRouteChangeDuringQuotaCannotCrossAttachment() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let quotaGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let account = Self.authority(accountID: "account-voice-route-quota", generation: 70)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in
                await quotaGate.wait()
                return (Self.consumeResponse(day: 5), Self.response(status: 200))
            },
            defaults: defaults
        )
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("voice-route-quota-a")
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.chatLifecycleRequester = { method, _, _ in
            await MainActor.run { events.append(method) }
            return Self.acceptedChatSendResponse(runID: "unexpected-route-run")
        }

        manager.startTranscriptProcessing("stay on A", restartAfter: false)
        let task = try #require(manager.activeTranscriptTask)
        await quotaGate.waitUntilEntered()
        manager.updateSessionKey("voice-route-quota-b")
        await quotaGate.open()
        await task.value

        #expect(events.values.isEmpty)
        #expect(manager.attachedSessionKey == "voice-route-quota-b")
        #expect(manager.transcriptionState == .idle)
        #expect(manager.responsePhase == .idle)
    }

    @Test("Talk Mode pre-start cancellation never publishes a reserved transcript as sent")
    func voicePreStartCancellationDoesNotPublishSentTranscript() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-publish-prestart", generation: 74)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let startGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let sessionKey = "voice-publish-prestart-\(UUID().uuidString)"
        let transcript = "never claim this was sent"
        defer { SessionDisplayNames.removeName(for: sessionKey) }
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey(sessionKey)
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.beforeChatGatewayStart = { await startGate.wait() }
        manager.chatLifecycleRequester = { method, _, _ in
            await MainActor.run { events.append(method) }
            return Self.acceptedChatSendResponse(runID: "unexpected-prestart-run")
        }

        manager.startTranscriptProcessing(transcript, restartAfter: false)
        let task = try #require(manager.activeTranscriptTask)
        await startGate.waitUntilEntered()
        manager.stop()
        await startGate.open()
        await task.value

        #expect(events.values.isEmpty)
        #expect(!manager.voiceTranscripts.contains(transcript))
        #expect(manager.transcriptionState == .idle)
        #expect(SessionDisplayNames.name(for: sessionKey) == nil)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Talk Mode send failure never publishes a reserved transcript as sent")
    func voiceSendFailureDoesNotPublishSentTranscript() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-publish-failure", generation: 76)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let sessionKey = "voice-publish-failure-\(UUID().uuidString)"
        let transcript = "network failed before acceptance"
        defer { SessionDisplayNames.removeName(for: sessionKey) }
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey(sessionKey)
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.chatLifecycleRequester = { method, _, _ in
            #expect(method == "chat.send")
            throw URLError(.cannotConnectToHost)
        }

        manager.startTranscriptProcessing(transcript, restartAfter: false)
        let task = try #require(manager.activeTranscriptTask)
        await task.value

        #expect(!manager.voiceTranscripts.contains(transcript))
        #expect(manager.transcriptionState != .sent(transcript))
        #expect(SessionDisplayNames.name(for: sessionKey) == nil)
        #expect(service.reservationRetryBlocked)
    }

    @Test("Talk Mode route A to B to A during send cannot regain stale attachment ownership")
    func voiceRouteABAChangeDuringSendCannotPublishStaleTurn() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-route-send", generation: 71)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let sendGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let routeA = "voice-route-send-a-\(UUID().uuidString)"
        defer { SessionDisplayNames.removeName(for: routeA) }
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey(routeA)
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.chatLifecycleRequester = { method, paramsJSON, _ in
            if method == "chat.send" {
                await MainActor.run { events.append("send-started") }
                await sendGate.wait()
                return Self.acceptedChatSendResponse(runID: "voice-route-send-run")
            }
            let runID = Self.runID(from: paramsJSON) ?? "missing"
            await MainActor.run { events.append("abort:\(runID)") }
            return Data()
        }

        manager.startTranscriptProcessing("never republish", restartAfter: false)
        let task = try #require(manager.activeTranscriptTask)
        await waitUntil { events.values.contains("send-started") }
        manager.updateSessionKey("voice-route-send-b")
        manager.updateSessionKey(routeA)
        await sendGate.open()
        await task.value

        #expect(events.values == ["send-started", "abort:voice-route-send-run"])
        #expect(manager.attachedSessionKey == routeA)
        #expect(manager.transcriptionState == .idle)
        #expect(manager.responsePhase == .idle)
        #expect(SessionDisplayNames.name(for: routeA) == nil)
        #expect(!service.reservationRetryBlocked)
    }

    @Test("Talk Mode route A to B during completion cannot publish history or speech into B")
    func voiceRouteChangeDuringCompletionCannotPublishStaleTurn() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-route-completion", generation: 72)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let completionGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("voice-route-completion-a")
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.chatLifecycleRequester = { method, _, _ in
            await MainActor.run { events.append(method) }
            return Self.acceptedChatSendResponse(runID: "voice-route-completion-run")
        }
        manager.chatCompletionWaiter = { _ in
            await completionGate.wait()
            return .final
        }

        manager.startTranscriptProcessing("finish only on A", restartAfter: false)
        let task = try #require(manager.activeTranscriptTask)
        await completionGate.waitUntilEntered()
        manager.updateSessionKey("voice-route-completion-b")
        await completionGate.open()
        await task.value

        #expect(events.values == ["chat.send"])
        #expect(manager.attachedSessionKey == "voice-route-completion-b")
        #expect(manager.transcriptionState == .idle)
        #expect(manager.responsePhase == .idle)
        #expect(!manager.isSpeaking)
    }

    @Test("A-B-A overlapping composer task cannot clear its replacement task")
    func overlappingComposerTasksKeepReplacementOwnership() async {
        let oldGate = MacDispatchTestGate()
        let replacementGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("composer-overlap-a")
        manager.attachGateway(GatewayNodeSession())
        manager.isEnabled = true
        manager.composerStreamOperation = {
            let attempt = await MainActor.run {
                events.append("composer")
                return events.values.count
            }
            if attempt == 1 {
                await oldGate.wait()
            } else {
                await replacementGate.wait()
            }
        }

        manager.speakNextResponse()
        await oldGate.waitUntilEntered()
        manager.updateSessionKey("composer-overlap-b")
        manager.updateSessionKey("composer-overlap-a")
        manager.speakNextResponse()
        await replacementGate.waitUntilEntered()

        await oldGate.open()
        await Task.yield()
        #expect(manager.hasComposerStreamingTask)

        await replacementGate.open()
        await waitUntil { !manager.hasComposerStreamingTask }
        #expect(events.values == ["composer", "composer"])
    }

    @Test("Composer takeover during voice quota suspension retains composer generation and phase")
    func composerTakeoverDuringVoiceQuotaSuspensionWinsOwnership() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-composer-quota", generation: 77)
        let quotaGate = MacDispatchTestGate()
        let composerGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in
                await MainActor.run { events.append("quota") }
                await quotaGate.wait()
                return (Self.consumeResponse(day: 5), Self.response(status: 200))
            },
            defaults: defaults
        )
        let transcript = "quota suspended voice turn"
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("voice-composer-quota")
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.isEnabled = true
        manager.chatLifecycleRequester = { method, _, _ in
            await MainActor.run { events.append(method) }
            return Self.acceptedChatSendResponse(runID: "unexpected-quota-run")
        }
        manager.composerStreamOperation = {
            manager.responsePhase = .speaking
            await composerGate.wait()
        }

        manager.startTranscriptProcessing(transcript, restartAfter: false)
        let voiceTask = try #require(manager.activeTranscriptTask)
        await quotaGate.waitUntilEntered()
        manager.speakNextResponse()
        await Task.yield()
        let composerEnteredBeforeQuotaResolution = await composerGate.hasEntered
        #expect(!composerEnteredBeforeQuotaResolution)
        await quotaGate.open()
        await voiceTask.value
        await composerGate.waitUntilEntered()

        #expect(events.values == ["quota"])
        #expect(!manager.voiceTranscripts.contains(transcript))
        #expect(manager.hasComposerStreamingTask)
        #expect(manager.responsePhase == .speaking)
        #expect(!service.reservationRetryBlocked)

        let futureContext = try #require(service.makeDispatchContext())
        let futureReservation = try await service.consumeRequestSlot(
            dispatchContext: futureContext
        )
        #expect(events.values == ["quota", "quota"])
        service.markReservedRequestCancelledBeforeDispatch(futureReservation)
        #expect(!service.reservationRetryBlocked)

        await composerGate.open()
        await waitUntil { !manager.hasComposerStreamingTask }
        manager.stop()
    }

    @Test("Composer takeover before voice gateway start prevents stale dispatch")
    func composerTakeoverBeforeVoiceGatewayStartPreventsDispatch() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-composer-gateway", generation: 78)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let gatewayGate = MacDispatchTestGate()
        let composerGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let transcript = "gateway suspended voice turn"
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("voice-composer-gateway")
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.isEnabled = true
        manager.beforeChatGatewayStart = { await gatewayGate.wait() }
        manager.chatLifecycleRequester = { method, _, _ in
            await MainActor.run { events.append(method) }
            return Self.acceptedChatSendResponse(runID: "voice-composer-gateway-run")
        }
        manager.composerStreamOperation = {
            manager.responsePhase = .speaking
            await composerGate.wait()
        }

        manager.startTranscriptProcessing(transcript, restartAfter: false)
        let voiceTask = try #require(manager.activeTranscriptTask)
        await gatewayGate.waitUntilEntered()
        manager.speakNextResponse()
        await Task.yield()
        let composerEnteredBeforeGatewayResolution = await composerGate.hasEntered
        #expect(!composerEnteredBeforeGatewayResolution)
        await gatewayGate.open()
        await voiceTask.value
        await composerGate.waitUntilEntered()

        #expect(events.values.isEmpty)
        #expect(!manager.voiceTranscripts.contains(transcript))
        #expect(manager.hasComposerStreamingTask)
        #expect(manager.responsePhase == .speaking)
        #expect(!service.reservationRetryBlocked)

        await composerGate.open()
        await waitUntil { !manager.hasComposerStreamingTask }
        manager.stop()
    }

    @Test("Composer takeover after voice dispatch aborts the exact accepted run")
    func composerTakeoverAfterVoiceDispatchAbortsExactRun() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-composer-started", generation: 79)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let responseGate = MacDispatchTestGate()
        let composerGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let transcript = "already dispatched voice turn"
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("voice-composer-started")
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.isEnabled = true
        manager.chatLifecycleRequester = { method, paramsJSON, _ in
            if method == "chat.send" {
                await MainActor.run { events.append("chat.send") }
                await responseGate.wait()
                return Self.acceptedChatSendResponse(runID: "voice-composer-started-run")
            }
            let runID = Self.runID(from: paramsJSON) ?? "missing"
            await MainActor.run { events.append("chat.abort:\(runID)") }
            return Data()
        }
        manager.composerStreamOperation = {
            manager.responsePhase = .speaking
            await composerGate.wait()
        }

        manager.startTranscriptProcessing(transcript, restartAfter: false)
        let voiceTask = try #require(manager.activeTranscriptTask)
        await waitUntil { events.values == ["chat.send"] }
        manager.speakNextResponse()
        await Task.yield()
        let composerEnteredBeforeAcceptedRunAbort = await composerGate.hasEntered
        #expect(!composerEnteredBeforeAcceptedRunAbort)
        await responseGate.open()
        await voiceTask.value
        await composerGate.waitUntilEntered()

        #expect(events.values == [
            "chat.send",
            "chat.abort:voice-composer-started-run",
        ])
        #expect(!manager.voiceTranscripts.contains(transcript))
        #expect(manager.pendingAcceptedVoiceAbortRunID == nil)
        #expect(!service.reservationRetryBlocked)
        #expect(manager.hasComposerStreamingTask)
        #expect(manager.responsePhase == .speaking)

        await composerGate.open()
        await waitUntil { !manager.hasComposerStreamingTask }
        manager.stop()
    }

    @Test("Session switch retains old voice resolution before new composer stream")
    func sessionSwitchThenComposerAwaitsOldExactAbort() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let account = Self.authority(accountID: "account-voice-switch-composer", generation: 80)
        let service = MacQuotaService(
            authorityProvider: { account },
            requester: { _ in (Self.consumeResponse(day: 5), Self.response(status: 200)) },
            defaults: defaults
        )
        let responseGate = MacDispatchTestGate()
        let composerGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("voice-switch-a")
        manager.attachGateway(GatewayNodeSession())
        manager.attachQuotaService(service)
        manager.updateGatewayConnected(true)
        manager.isEnabled = true
        manager.chatLifecycleRequester = { method, paramsJSON, _ in
            if method == "chat.send" {
                await MainActor.run { events.append("chat.send:voice-switch-a") }
                await responseGate.wait()
                return Self.acceptedChatSendResponse(runID: "voice-switch-old-run")
            }
            let runID = Self.runID(from: paramsJSON) ?? "missing"
            await MainActor.run { events.append("chat.abort:\(runID)") }
            return Data()
        }
        manager.composerStreamOperation = {
            events.append("composer:\(manager.attachedSessionKey)")
            await composerGate.wait()
        }

        manager.startTranscriptProcessing("old session voice", restartAfter: false)
        let oldVoiceTask = try #require(manager.activeTranscriptTask)
        await waitUntil { events.values == ["chat.send:voice-switch-a"] }

        manager.updateSessionKey("voice-switch-b")
        manager.speakNextResponse()
        await Task.yield()
        let composerEnteredBeforeOldResolution = await composerGate.hasEntered
        #expect(!composerEnteredBeforeOldResolution)
        #expect(events.values == ["chat.send:voice-switch-a"])

        await responseGate.open()
        await oldVoiceTask.value
        await composerGate.waitUntilEntered()

        #expect(events.values == [
            "chat.send:voice-switch-a",
            "chat.abort:voice-switch-old-run",
            "composer:voice-switch-b",
        ])
        #expect(!manager.voiceTranscripts.contains("old session voice"))
        #expect(!service.reservationRetryBlocked)
        #expect(manager.hasComposerStreamingTask)

        await composerGate.open()
        await waitUntil { !manager.hasComposerStreamingTask }
        manager.stop()
    }

    @Test("A-B-A overlapping incremental task cannot finish or clear replacement speech")
    func overlappingIncrementalTasksKeepReplacementOwnership() async {
        let oldGate = MacDispatchTestGate()
        let replacementGate = MacDispatchTestGate()
        let events = MacDispatchEventLog()
        let manager = RemMacTalkModeManager()
        manager.updateSessionKey("incremental-overlap-a")
        manager.isEnabled = true
        manager.incrementalSegmentOperation = { segment in
            await MainActor.run { events.append(segment) }
            if segment == "old segment" {
                await oldGate.wait()
            } else {
                await replacementGate.wait()
            }
        }

        manager.resetIncrementalSpeech()
        manager.enqueueIncrementalSpeech("old segment")
        await oldGate.waitUntilEntered()
        manager.updateSessionKey("incremental-overlap-b")
        manager.updateSessionKey("incremental-overlap-a")
        manager.resetIncrementalSpeech()
        manager.enqueueIncrementalSpeech("replacement segment")
        await replacementGate.waitUntilEntered()

        await oldGate.open()
        await Task.yield()
        #expect(manager.hasIncrementalSpeechTask)

        await replacementGate.open()
        await waitUntil { !manager.hasIncrementalSpeechTask }
        #expect(events.values == ["old segment", "replacement segment"])
    }

    private enum ExpectedReservationError {
        case outcomeUnknown
        case retryBlocked
    }

    private func expectReservationError(
        _ expected: ExpectedReservationError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected reservation error")
        } catch let error as MacQuotaReservationError {
            switch (expected, error) {
            case (.outcomeUnknown, .outcomeUnknown), (.retryBlocked, .retryBlocked):
                break
            default:
                Issue.record("Unexpected reservation error: \(error)")
            }
        } catch {
            Issue.record("Expected MacQuotaReservationError, got \(error)")
        }
    }

    private func expectCancellation<T>(of task: Task<T, Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for asynchronous test condition")
                return
            }
            await Task.yield()
        }
    }

    nonisolated private static func runID(from paramsJSON: String?) -> String? {
        guard let paramsJSON,
              let data = paramsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["runId"] as? String
    }

    nonisolated private static func acceptedChatSendResponse(runID: String) -> Data {
        Data(#"{"runId":"\#(runID)","status":"started"}"#.utf8)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MacQuotaServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName") ?? ""
    }

    private static func authority(
        accountID: String,
        generation: UInt64,
        accountGeneration: UInt64? = nil,
        backendURL: String = "https://api.example.test"
    ) -> MacBackendAuthAuthority {
        MacBackendAuthAuthority(
            generation: generation,
            accountGeneration: accountGeneration,
            backendURL: backendURL,
            backendToken: jwt(subject: accountID)
        )
    }

    private static func jwt(subject: String) -> String {
        let payload = Data("{\"sub\":\"\(subject)\"}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func consumeResponse(day: Int) -> Data {
        Data("{\"ok\":true,\"usage\":{\"day\":2,\"month\":3},\"remaining\":{\"day\":\(day),\"month\":20}}".utf8)
    }

    private func summary(dayRemaining: Int) -> UsageSummary {
        UsageSummary(
            plan: "paid",
            status: "active",
            limits: PlanLimits(requestsPerDay: 10, requestsPerMonth: 100),
            usage: UsageStats(day: 10 - dayRemaining, month: 20),
            remaining: RemainingQuota(day: dayRemaining, month: 80)
        )
    }
}

private actor MacDispatchTestGate {
    private var entered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !entered, clock.now < deadline {
            await Task.yield()
        }
        if !entered {
            Issue.record("Timed out waiting for test gate entry")
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MacDispatchEventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class MacObservationInvalidationProbe {
    var didInvalidate = false
}

@MainActor
private final class MacQuotaResetSchedulerProbe {
    var resetDate: Date?
    private var action: (@MainActor () -> Void)?

    func schedule(
        resetDate: Date,
        action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        self.resetDate = resetDate
        self.action = action
        return Task {}
    }

    func fire() {
        let pendingAction = action
        action = nil
        pendingAction?()
    }
}
