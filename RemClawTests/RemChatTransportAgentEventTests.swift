import Foundation
import Testing
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
@testable import RemClaw

struct RemChatTransportAgentEventTests {
    @MainActor
    @Test func dispatchCallbackFiresOnlyAfterPreflightBeforeWireRequest() async throws {
        let preflight = ChatSendPreflightBlocker()
        let requester = OrderedChatLifecycleRequester()
        var dispatchCount = 0
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            onWillSend: { await preflight.wait() },
            onChatSendDispatched: { dispatchCount += 1 },
            chatLifecycleRequester: { method, paramsJSON, _ in
                try await requester.request(method: method, paramsJSON: paramsJSON)
            }
        )

        let send = Task {
            try await transport.sendMessage(
                sessionKey: "dispatch-boundary-session",
                message: "hello",
                thinking: "off",
                idempotencyKey: "dispatch-boundary-run",
                attachments: []
            )
        }
        #expect(await preflight.waitUntilStarted())
        #expect(dispatchCount == 0)
        #expect(await requester.methods.isEmpty)

        await preflight.release()
        await requester.waitUntilSendStarted()
        #expect(dispatchCount == 1)
        #expect(await requester.methods == ["chat.send"])

        await requester.acceptSend(runID: "accepted-run")
        _ = try await send.value
    }

    @MainActor
    @Test func rejectedDispatchAuthorizationNeverStartsWireRequest() async {
        let requester = OrderedChatLifecycleRequester()
        var dispatchCheckCount = 0
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            onChatSendDispatched: {
                dispatchCheckCount += 1
                throw CancellationError()
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                try await requester.request(method: method, paramsJSON: paramsJSON)
            }
        )

        do {
            _ = try await transport.sendMessage(
                sessionKey: "rejected-dispatch-session",
                message: "hello",
                thinking: "off",
                idempotencyKey: "rejected-dispatch-run",
                attachments: []
            )
            Issue.record("Expected dispatch authorization rejection")
        } catch is CancellationError {
            // Authority changed during preflight, before chat.send entered the requester.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(dispatchCheckCount == 1)
        #expect(await requester.methods.isEmpty)
    }

    @MainActor
    @Test func failedCancellationAbortRetainsExactRunForProductionRetry() async throws {
        let requester = OrderedChatLifecycleRequester()
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            chatLifecycleRequester: { method, paramsJSON, _ in
                try await requester.request(method: method, paramsJSON: paramsJSON)
            }
        )
        let send = Task {
            try await transport.sendMessage(
                sessionKey: "abort-retry-session",
                message: "hello",
                thinking: "off",
                idempotencyKey: "abort-retry-local-run",
                attachments: []
            )
        }
        await requester.waitUntilSendStarted()
        await requester.failNextAbort()
        send.cancel()
        await requester.acceptSend(runID: "abort-retry-accepted-run")

        do {
            _ = try await send.value
            Issue.record("Expected the owner cancellation abort failure to propagate")
        } catch is URLError {
            // The exact accepted-run mapping must remain available for production retry.
        } catch {
            Issue.record("Expected the abort transport error, got \(error)")
        }

        try await transport.abortRun(
            sessionKey: "abort-retry-session",
            runId: "abort-retry-local-run"
        )

        #expect(await requester.methods == ["chat.send", "chat.abort", "chat.abort"])
        #expect(await requester.abortedRunIDs == [
            "abort-retry-accepted-run",
            "abort-retry-accepted-run",
        ])
    }

    @MainActor
    @Test func cancelledAbortWaiterCannotAbortLaterAcceptedRun() async throws {
        let requester = OrderedChatLifecycleRequester()
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            chatLifecycleRequester: { method, paramsJSON, _ in
                try await requester.request(method: method, paramsJSON: paramsJSON)
            }
        )
        let send = Task {
            try await transport.sendMessage(
                sessionKey: "cancelled-abort-session",
                message: "hello",
                thinking: "off",
                idempotencyKey: "cancelled-abort-local-run",
                attachments: []
            )
        }
        await requester.waitUntilSendStarted()
        let abort = Task {
            try await transport.abortRun(
                sessionKey: "cancelled-abort-session",
                runId: "cancelled-abort-local-run"
            )
        }
        while transport.pendingAbortWaiterCount(
            sessionKey: "cancelled-abort-session",
            idempotencyKey: "cancelled-abort-local-run"
        ) == 0 {
            await Task.yield()
        }

        abort.cancel()
        do {
            try await abort.value
            Issue.record("Expected the pending abort waiter to observe cancellation")
        } catch is CancellationError {
            // Expected: cancellation unregisters this exact waiter before acceptance.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(transport.pendingAbortWaiterCount(
            sessionKey: "cancelled-abort-session",
            idempotencyKey: "cancelled-abort-local-run"
        ) == 0)

        await requester.acceptSend(runID: "later-accepted-run")
        _ = try await send.value

        #expect(await requester.methods == ["chat.send"])
        #expect(await requester.abortedRunIDs.isEmpty)
    }

    @MainActor
    @Test func productionAbortWaitsForMatchingSendAcknowledgement() async throws {
        let requester = OrderedChatLifecycleRequester()
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            chatLifecycleRequester: { method, paramsJSON, _ in
                try await requester.request(method: method, paramsJSON: paramsJSON)
            }
        )
        let send = Task {
            try await transport.sendMessage(
                sessionKey: "abort-session",
                message: "hello",
                thinking: "off",
                idempotencyKey: "local-run",
                attachments: []
            )
        }
        await requester.waitUntilSendStarted()
        let abort = Task {
            try await transport.abortRun(sessionKey: "abort-session", runId: "local-run")
        }
        while transport.pendingAbortWaiterCount(
            sessionKey: "abort-session",
            idempotencyKey: "local-run"
        ) == 0 {
            await Task.yield()
        }
        #expect(await requester.methods == ["chat.send"])

        await requester.acceptSend(runID: "accepted-run")
        _ = try await send.value
        try await abort.value

        #expect(await requester.methods == ["chat.send", "chat.abort"])
        #expect(await requester.abortedRunIDs == ["accepted-run"])
    }

    @MainActor
    @Test func cancellationWaitsForAcceptedRunBeforeExactAbort() async throws {
        let requester = OrderedChatLifecycleRequester()
        let suiteName = "RemChatTransportAgentEventTests.cancel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let authority = AuthenticatedHttpClient.AccountRequestAuthority(
            token: "token-a",
            baseURL: "https://api.example.test",
            accountID: "account-a"
        )
        let consumeHTTP = try #require(HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let usageService = UsageService(
            requestAuthorityProvider: { authority },
            consumeRequester: { _ in (Data("not-json".utf8), consumeHTTP) },
            defaults: defaults
        )
        let reservation = try await usageService.consumeRequestSlot()
        let handoff = TextRequestSlotHandoff()
        handoff.install(reservation)
        var acceptanceCount = 0
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            onChatSendAccepted: {
                acceptanceCount += 1
                handoff.accept(using: usageService)
            },
            chatLifecycleRequester: { method, paramsJSON, _ in
                try await requester.request(method: method, paramsJSON: paramsJSON)
            }
        )

        let send = Task {
            try await transport.sendMessage(
                sessionKey: "cancelled-session",
                message: "hello",
                thinking: "off",
                idempotencyKey: "reservation-run",
                attachments: []
            )
        }
        await requester.waitUntilSendStarted()
        send.cancel()
        #expect(await requester.methods == ["chat.send"])
        #expect(usageService.reservationRetryBlocked)

        await requester.acceptSend(runID: "accepted-run")
        do {
            _ = try await send.value
            Issue.record("Expected cancellation after the exact run was aborted")
        } catch is CancellationError {
            // Expected only after chat.send acceptance and the ordered chat.abort.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(acceptanceCount == 1)
        #expect(!usageService.reservationRetryBlocked)
        #expect(await requester.methods == ["chat.send", "chat.abort"])
        #expect(await requester.abortedRunIDs == ["accepted-run"])
    }

    @MainActor
    @Test func failedChatSendCancelsItsBrowserPlaceholder() async {
        var beganRuns: [(sessionKey: String, browserRequested: Bool)] = []
        var cancelledSessionKeys: [String] = []
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            onBrowserRunBegan: { sessionKey, browserRequested in
                beganRuns.append((sessionKey, browserRequested))
            },
            onBrowserRunCancelled: { cancelledSessionKeys.append($0) }
        )

        do {
            _ = try await transport.sendMessage(
                sessionKey: "chat-failed-send",
                message: "hello",
                thinking: "off",
                idempotencyKey: UUID().uuidString,
                attachments: []
            )
            Issue.record("Expected an unconnected gateway send to fail")
        } catch {
            // Expected: the concrete transport has no connected gateway channel.
        }

        #expect(beganRuns.map(\.sessionKey) == ["chat-failed-send"])
        #expect(beganRuns.map(\.browserRequested) == [false])
        #expect(cancelledSessionKeys == ["chat-failed-send"])
    }

    @MainActor
    @Test func cloudBrowserAttachmentPublishesBrowserIntentAtRunStart() async {
        var browserRequested: Bool?
        let transport = IOSGatewayChatTransport(
            gateway: GatewayNodeSession(),
            onBrowserRunBegan: { _, requested in browserRequested = requested }
        )

        do {
            _ = try await transport.sendMessage(
                sessionKey: "chat-browser-attachment",
                message: BrowserDirective.wrapChipSend(userText: "open example.com"),
                thinking: "off",
                idempotencyKey: UUID().uuidString,
                attachments: []
            )
            Issue.record("Expected an unconnected gateway send to fail")
        } catch {
            // Expected: callback evidence is emitted before the gateway request fails.
        }

        #expect(browserRequested == true)
    }

    @Test func reactivatingSameSessionPreservesHistorySessionID() {
        let state = IOSChatTransportState()
        state.activate(sessionKey: "chat-b")
        state.setSessionID("history-b", for: "chat-b")

        state.activate(sessionKey: "chat-b")

        #expect(state.route == IOSChatTransportState.Route(
            sessionKey: "chat-b", sessionId: "history-b"))
    }

    @Test func switchingSessionsClearsHistorySessionID() {
        let state = IOSChatTransportState()
        state.activate(sessionKey: "chat-a")
        state.setSessionID("history-a", for: "chat-a")

        state.activate(sessionKey: "chat-b")

        #expect(state.route == IOSChatTransportState.Route(
            sessionKey: "chat-b", sessionId: nil))
    }

    @Test func rewritesGatewayRunIDToHistorySessionID() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"gateway-run","seq":1,"stream":"tool","ts":123,"data":{"phase":"start","name":"browser","toolCallId":"call-1","args":{"action":"navigate"}}}"#.utf8))

        let normalized = IOSGatewayChatTransport.normalizingAgentRunID(
            payload,
            sessionId: "history-session")

        #expect(normalized.runId == "history-session")
        #expect(normalized.stream == "tool")
        #expect(normalized.data["name"]?.value as? String == "browser")
        #expect(BrowserCardStateResolver.argAction(normalized.data["args"]) == "navigate")
    }

    @Test func browserActivityPreservesGatewayRunIDForLifecycleScoping() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"voice-run","seq":1,"stream":"tool","ts":123,"data":{"phase":"start","name":"browser","toolCallId":"call-1","args":{"action":"tabs"}}}"#.utf8))

        let activity = IOSGatewayChatTransport.browserToolActivity(
            from: payload,
            sessionKey: "chat-browser")

        #expect(activity?.runID == "voice-run")
        #expect(activity?.action == "tabs")
    }

    @Test func leavesEventUnchangedWithoutHistorySessionID() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"gateway-run","stream":"assistant","data":{"text":"hello"}}"#.utf8))

        let normalized = IOSGatewayChatTransport.normalizingAgentRunID(payload, sessionId: nil)

        #expect(normalized.runId == "gateway-run")
        #expect(normalized.data["text"]?.value as? String == "hello")
    }

    @Test func acceptsMatchingCanonicalSessionAndRewritesRunID() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"gateway-run","stream":"assistant","data":{"text":"hello"}}"#.utf8))

        let routed = IOSGatewayChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: "agent:main:chat-b",
            activeSessionKey: "chat-b",
            sessionId: "history-b")

        #expect(routed?.runId == "history-b")
    }

    @Test func rejectsLateEventFromPreviousConversation() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"run-a","stream":"tool","data":{"phase":"start","name":"browser","toolCallId":"call-a","args":{"action":"navigate"}}}"#.utf8))

        let routed = IOSGatewayChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: "agent:main:chat-a",
            activeSessionKey: "chat-b",
            sessionId: "history-b")

        #expect(routed == nil)
    }

    @Test func rejectsSameSuffixFromAnotherCanonicalAgent() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"run-other","stream":"assistant","data":{"text":"private"}}"#.utf8))

        #expect(IOSGatewayChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: "agent:other:chat-b",
            activeSessionKey: "chat-b",
            sessionId: "history-b") == nil)
    }

    @Test func chatFinalRejectsSameSuffixFromAnotherCanonicalAgent() throws {
        let payload = try JSONDecoder().decode(
            OpenClawChatEventPayload.self,
            from: Data(#"{"runId":"run-other","sessionKey":"agent:other:chat-b","state":"final"}"#.utf8))

        #expect(IOSGatewayChatTransport.routedChatEvent(
            payload,
            activeSessionKey: "chat-b") == nil)

        let accepted = IOSGatewayChatTransport.routedChatEvent(
            try JSONDecoder().decode(
                OpenClawChatEventPayload.self,
                from: Data(#"{"runId":"run-main","sessionKey":"agent:main:chat-b","state":"final"}"#.utf8)),
            activeSessionKey: "chat-b")
        #expect(accepted?.sessionKey == "chat-b")
    }

    @Test func rejectsAgentEventWithoutSessionRouting() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"gateway-run","stream":"assistant","data":{"text":"hello"}}"#.utf8))

        #expect(IOSGatewayChatTransport.routedAgentEvent(
            payload,
            eventSessionKey: nil,
            activeSessionKey: "chat-b",
            sessionId: "history-b") == nil)
    }

    @Test func lifecycleActivityPreservesRawExecutionRunIDBeforeRewrite() throws {
        let payload = try JSONDecoder().decode(
            OpenClawAgentEventPayload.self,
            from: Data(#"{"runId":"execution-run","stream":"tool","data":{"phase":"start","name":"gmail"}}"#.utf8)
        )

        let evidence = IOSGatewayChatTransport.activeRunLifecycleEvidence(
            from: payload,
            sessionKey: "agent:main:chat-a"
        )

        #expect(evidence == RunLifecycleEvidence(
            run: .init(sessionKey: "chat-a", runID: "execution-run"),
            phase: .active
        ))
    }

    @Test func localSendRegistersExactRunIdentityBeforeAgentActivity() {
        #expect(IOSGatewayChatTransport.localRunLifecycleEvidence(
            sessionKey: "agent:main:chat-a",
            runID: "execution-run"
        ) == RunLifecycleEvidence(
            run: .init(sessionKey: "chat-a", runID: "execution-run"),
            phase: .localRegistered
        ))
    }

    @Test func terminalLifecycleRequiresExactRunIdentity() {
        let evidence = IOSGatewayChatTransport.terminalRunLifecycleEvidence(
            state: "final",
            sessionKey: "agent:main:chat-a",
            runID: "execution-run"
        )
        #expect(evidence == RunLifecycleEvidence(
            run: .init(sessionKey: "chat-a", runID: "execution-run"),
            phase: .terminal(.final)
        ))
        #expect(IOSGatewayChatTransport.terminalRunLifecycleEvidence(
            state: "final",
            sessionKey: "chat-a",
            runID: nil
        ) == nil)
    }
}

private actor OrderedChatLifecycleRequester {
    private var sendContinuation: CheckedContinuation<Data, Error>?
    private(set) var methods: [String] = []
    private(set) var abortedRunIDs: [String] = []
    private var shouldFailNextAbort = false

    func request(method: String, paramsJSON: String?) async throws -> Data {
        methods.append(method)
        if method == "chat.send" {
            return try await withCheckedThrowingContinuation { sendContinuation = $0 }
        }
        if method == "chat.abort",
           let paramsJSON,
           let data = paramsJSON.data(using: .utf8),
           let payload = try? JSONDecoder().decode(AbortPayload.self, from: data) {
            abortedRunIDs.append(payload.runId)
            if shouldFailNextAbort {
                shouldFailNextAbort = false
                throw URLError(.timedOut)
            }
        }
        return Data("{}".utf8)
    }

    func failNextAbort() {
        shouldFailNextAbort = true
    }

    func waitUntilSendStarted() async {
        while sendContinuation == nil { await Task.yield() }
    }

    func acceptSend(runID: String) {
        let continuation = sendContinuation
        sendContinuation = nil
        continuation?.resume(returning: Data(
            "{\"runId\":\"\(runID)\",\"status\":\"started\"}".utf8
        ))
    }

    private struct AbortPayload: Decodable {
        let runId: String
    }
}

private actor ChatSendPreflightBlocker {
    private var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func wait() async {
        didStart = true
        let waiters = Array(startWaiters.values)
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: true)
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted(timeout: Duration = .seconds(5)) async -> Bool {
        if didStart { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { waiter in
            startWaiters[waiterID] = waiter
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.finishStartWaiter(waiterID, result: false)
            }
        }
    }

    private func finishStartWaiter(_ waiterID: UUID, result: Bool) {
        startWaiters.removeValue(forKey: waiterID)?.resume(returning: result)
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}
