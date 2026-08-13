@testable import RemClaw
import Foundation
import Testing

@Suite("Browser hand-back coordinator")
@MainActor
struct BrowserHandBackCoordinatorTests {
    private let authority = BrowserHandBackAuthority(
        accountID: "account-a",
        accountLifecycleTicket: 11,
        gatewayURL: "https://gateway.example.com",
        gatewayToken: "gateway-token-a",
        credentialLifecycleTicket: 23,
        operatorGeneration: 7,
        sessionKey: "chat-browser",
        browserOwnerLifecycleTicket: 37
    )

    @Test func opaqueReservationIsReusedAndRetiredOnlyAfterHiddenSendAcceptance() async throws {
        let coordinator = BrowserHandBackCoordinator()
        let service = makeUsageService()
        var reservationCount = 0
        var sentKeys: [String] = []
        var shouldFailSend = true

        let first = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { reservation in
                service.markReservedRequestCancelledBeforeDispatch(reservation)
            },
            send: { key, reservation, onDispatchStarted, onAccepted in
                sentKeys.append(key)
                onDispatchStarted()
                if shouldFailSend { throw TestFailure.expected }
                service.markReservedRequestAccepted(reservation)
                onAccepted()
            }
        )
        #expect(first == .denied("Rem couldn't resume yet. Give control back again to retry."))
        #expect(service.reservationRetryBlocked)

        shouldFailSend = false
        let second = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { reservation in
                service.markReservedRequestCancelledBeforeDispatch(reservation)
            },
            send: { key, reservation, onDispatchStarted, onAccepted in
                sentKeys.append(key)
                onDispatchStarted()
                service.markReservedRequestAccepted(reservation)
                onAccepted()
            }
        )

        #expect(second == .resumed)
        #expect(reservationCount == 1)
        #expect(sentKeys.count == 2)
        #expect(sentKeys.first == sentKeys.last)
        #expect(!service.reservationRetryBlocked)
    }

    @Test func denialNeverAttemptsHiddenSend() async {
        let coordinator = BrowserHandBackCoordinator()
        var sendCount = 0

        let result = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { true },
            reserve: { .denied("Daily request limit reached") },
            cancelBeforeDispatch: { _ in },
            send: { _, _, _, _ in sendCount += 1 }
        )

        #expect(result == .denied("Daily request limit reached"))
        #expect(sendCount == 0)
    }

    @Test func acceptedReservationIsNotRetriedWhenTransportTailThrows() async {
        let coordinator = BrowserHandBackCoordinator()
        let service = makeUsageService()
        var reservationCount = 0
        var sendCount = 0

        let result = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { reservation in
                service.markReservedRequestCancelledBeforeDispatch(reservation)
            },
            send: { _, reservation, onDispatchStarted, onAccepted in
                sendCount += 1
                onDispatchStarted()
                service.markReservedRequestAccepted(reservation)
                onAccepted()
                throw TestFailure.expected
            }
        )

        #expect(
            result == .denied(
                "Rem accepted this browser handoff, but its continuation didn't finish. Check the chat before continuing."
            )
        )
        #expect(reservationCount == 1)
        #expect(!service.reservationRetryBlocked)

        let retry = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { reservation in
                service.markReservedRequestCancelledBeforeDispatch(reservation)
            },
            send: { _, _, _, _ in sendCount += 1 }
        )

        #expect(retry == result)
        #expect(reservationCount == 1)
        #expect(sendCount == 1)
    }

    @Test func acceptedNormalReturnThenGenerationChangeKeepsTerminalTombstone() async {
        let coordinator = BrowserHandBackCoordinator()
        let service = makeUsageService()
        var operatorGeneration = authority.operatorGeneration
        var reservationCount = 0
        var sendCount = 0

        let result = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { operatorGeneration == authority.operatorGeneration },
            isStableScopeCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { service.markReservedRequestCancelledBeforeDispatch($0) },
            send: { _, reservation, onDispatchStarted, onAccepted in
                sendCount += 1
                onDispatchStarted()
                service.markReservedRequestAccepted(reservation)
                onAccepted()
                coordinator.invalidate(preservingRecoverableAttempt: true)
                operatorGeneration &+= 1
            }
        )

        #expect(result == .denied(
            "Rem accepted this browser handoff, but its continuation didn't finish. Check the chat before continuing."
        ))
        #expect(!service.reservationRetryBlocked)

        let refreshedAuthority = replacingOperatorGeneration(operatorGeneration)
        let replay = await coordinator.resume(
            authority: refreshedAuthority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { service.markReservedRequestCancelledBeforeDispatch($0) },
            send: { _, _, _, _ in sendCount += 1 }
        )

        #expect(replay == result)
        #expect(reservationCount == 1)
        #expect(sendCount == 1)
    }

    @Test func browserOwnerReplacementAfterReservationCancelsExactSlotAndCannotSend() async {
        let coordinator = BrowserHandBackCoordinator()
        let service = makeUsageService()
        var browserOwner = authority.sessionKey
        var sendCount = 0
        var cancellationCount = 0

        let result = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { browserOwner == authority.sessionKey },
            isStableScopeCurrent: { browserOwner == authority.sessionKey },
            reserve: {
                browserOwner = "chat-replacement"
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { reservation in
                cancellationCount += 1
                service.markReservedRequestCancelledBeforeDispatch(reservation)
            },
            send: { _, _, _, _ in sendCount += 1 }
        )

        #expect(result == .denied("This browser session changed. Open it again from chat."))
        #expect(sendCount == 0)
        #expect(cancellationCount == 1)
        #expect(!service.reservationRetryBlocked)
    }

    @Test func authorityLossAfterTransportCreationButBeforeWireDispatchCancelsExactSlot() async {
        let coordinator = BrowserHandBackCoordinator()
        let service = makeUsageService()
        var authorityIsCurrent = true
        var cancellationCount = 0

        let result = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { authorityIsCurrent },
            reserve: { .reserved(try! await service.consumeRequestSlot()) },
            cancelBeforeDispatch: { reservation in
                cancellationCount += 1
                service.markReservedRequestCancelledBeforeDispatch(reservation)
            },
            send: { _, _, _, _ in
                // Transport construction/preflight can suspend. Losing authority here is still
                // definitely before the detached chat.send request starts.
                authorityIsCurrent = false
                throw TestFailure.expected
            }
        )

        #expect(result == .denied("This browser session changed. Open it again from chat."))
        #expect(cancellationCount == 1)
        #expect(!service.reservationRetryBlocked)
    }

    @Test func unchangedLifecycleTicketsAllowOperatorGenerationReconnectToRetryExactAttempt() async {
        let coordinator = BrowserHandBackCoordinator()
        let service = makeUsageService()
        var operatorGeneration = authority.operatorGeneration
        var cancellationCount = 0
        var reservationCount = 0
        var sentKeys: [String] = []

        let first = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { operatorGeneration == authority.operatorGeneration },
            isStableScopeCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { reservation in
                cancellationCount += 1
                service.markReservedRequestCancelledBeforeDispatch(reservation)
            },
            send: { key, _, onDispatchStarted, _ in
                sentKeys.append(key)
                onDispatchStarted()
                coordinator.invalidate(preservingRecoverableAttempt: true)
                operatorGeneration &+= 1
                throw TestFailure.expected
            }
        )

        #expect(first == .denied(
            "Rem's connection changed before it could confirm the browser handoff. Give control back again to retry."
        ))
        #expect(cancellationCount == 0)
        #expect(service.reservationRetryBlocked)

        var oldGenerationSendCount = 0
        let staleRetry = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { operatorGeneration == authority.operatorGeneration },
            isStableScopeCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { _ in cancellationCount += 1 },
            send: { _, _, _, _ in oldGenerationSendCount += 1 }
        )
        #expect(staleRetry == first)
        #expect(oldGenerationSendCount == 0)

        let refreshedAuthority = replacingOperatorGeneration(operatorGeneration)
        let recovered = await coordinator.resume(
            authority: refreshedAuthority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: {
                reservationCount += 1
                return .reserved(try! await service.consumeRequestSlot())
            },
            cancelBeforeDispatch: { _ in cancellationCount += 1 },
            send: { key, reservation, onDispatchStarted, onAccepted in
                sentKeys.append(key)
                onDispatchStarted()
                service.markReservedRequestAccepted(reservation)
                onAccepted()
            }
        )

        #expect(recovered == .resumed)
        #expect(reservationCount == 1)
        #expect(cancellationCount == 0)
        #expect(sentKeys.count == 2)
        #expect(sentKeys.first == sentKeys.last)
        #expect(!service.reservationRetryBlocked)
    }

    @Test func staleSuspendedReservationCannotEraseReplacementAmbiguousAttempt() async {
        await expectStaleSuspendedReservationCannotEraseReplacement(accepted: false)
    }

    @Test func staleSuspendedReservationCannotEraseReplacementAcceptedTombstone() async {
        await expectStaleSuspendedReservationCannotEraseReplacement(accepted: true)
    }

    @Test func staleTakeoverWaiterCannotEraseReplacementAcceptedTombstone() async {
        let coordinator = BrowserHandBackCoordinator()
        let gate = MainActorSuspensionGate()
        var staleAuthorityIsCurrent = true
        var staleReserveCount = 0

        let staleTask = Task { @MainActor in
            await coordinator.resumeAfterTakeoverSettles(
                waitForTakeover: { await gate.wait() },
                authority: authority,
                isAuthorityCurrent: { staleAuthorityIsCurrent },
                isStableScopeCurrent: { false },
                reserve: {
                    staleReserveCount += 1
                    return .denied("Stale authority must not reserve")
                },
                cancelBeforeDispatch: { _ in Issue.record("Stale authority has no reservation") },
                send: { _, _, _, _ in Issue.record("Stale authority must not dispatch") }
            )
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        staleAuthorityIsCurrent = false
        let replacementAuthority = authorityWithTickets(
            account: authority.accountLifecycleTicket + 1,
            credential: authority.credentialLifecycleTicket,
            browserOwner: authority.browserOwnerLifecycleTicket,
            operatorGeneration: authority.operatorGeneration + 1
        )
        let replacementService = makeUsageService()
        var replacementReservationCount = 0
        var replacementSendCount = 0

        let replacement = await coordinator.resume(
            authority: replacementAuthority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: {
                replacementReservationCount += 1
                guard replacementReservationCount == 1 else {
                    return .denied("Replacement tombstone was erased")
                }
                return .reserved(try! await replacementService.consumeRequestSlot())
            },
            cancelBeforeDispatch: { replacementService.markReservedRequestCancelledBeforeDispatch($0) },
            send: { _, reservation, onDispatchStarted, onAccepted in
                replacementSendCount += 1
                onDispatchStarted()
                replacementService.markReservedRequestAccepted(reservation)
                onAccepted()
                throw TestFailure.expected
            }
        )
        #expect(replacement == .denied(
            "Rem accepted this browser handoff, but its continuation didn't finish. Check the chat before continuing."
        ))

        gate.release()
        let staleResult = await staleTask.value
        #expect(staleResult == .denied("This browser session changed. Open it again from chat."))
        #expect(staleReserveCount == 0)

        let replay = await coordinator.resume(
            authority: replacementAuthority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: {
                replacementReservationCount += 1
                return .denied("Replacement tombstone was erased")
            },
            cancelBeforeDispatch: { _ in },
            send: { _, _, _, _ in replacementSendCount += 1 }
        )
        #expect(replay == replacement)
        #expect(replacementReservationCount == 1)
        #expect(replacementSendCount == 1)
    }

    @Test func accountLifecycleABARejectsPriorAmbiguousAttempt() async {
        await expectLifecycleABARejectsPriorAttempt(
            replacementAuthority: authorityWithTickets(
                account: authority.accountLifecycleTicket + 2,
                credential: authority.credentialLifecycleTicket,
                browserOwner: authority.browserOwnerLifecycleTicket,
                operatorGeneration: authority.operatorGeneration + 1
            )
        )
    }

    @Test func credentialLifecycleABARejectsPriorAmbiguousAttempt() async {
        await expectLifecycleABARejectsPriorAttempt(
            replacementAuthority: authorityWithTickets(
                account: authority.accountLifecycleTicket,
                credential: authority.credentialLifecycleTicket + 2,
                browserOwner: authority.browserOwnerLifecycleTicket,
                operatorGeneration: authority.operatorGeneration + 1
            )
        )
    }

    @Test func browserOwnerLifecycleABARejectsPriorAmbiguousAttempt() async {
        await expectLifecycleABARejectsPriorAttempt(
            replacementAuthority: authorityWithTickets(
                account: authority.accountLifecycleTicket,
                credential: authority.credentialLifecycleTicket,
                browserOwner: authority.browserOwnerLifecycleTicket + 2,
                operatorGeneration: authority.operatorGeneration + 1
            )
        )
    }

    @Test func replacementAccountCannotReuseOrRetirePriorAccountsAmbiguousSlot() async {
        let coordinator = BrowserHandBackCoordinator()
        var requestAuthority = Self.requestAuthority(accountID: "account-a")
        let service = makeUsageService(requestAuthorityProvider: { requestAuthority })

        let first = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { requestAuthority.accountID == "account-a" },
            reserve: { .reserved(try! await service.consumeRequestSlot()) },
            cancelBeforeDispatch: { service.markReservedRequestCancelledBeforeDispatch($0) },
            send: { _, _, onDispatchStarted, _ in
                onDispatchStarted()
                throw TestFailure.expected
            }
        )
        #expect(first == .denied("Rem couldn't resume yet. Give control back again to retry."))
        #expect(service.reservationRetryBlocked)

        requestAuthority = Self.requestAuthority(accountID: "account-b")
        let replacementAuthority = BrowserHandBackAuthority(
            accountID: "account-b",
            accountLifecycleTicket: authority.accountLifecycleTicket + 1,
            gatewayURL: authority.gatewayURL,
            gatewayToken: "gateway-token-b",
            credentialLifecycleTicket: authority.credentialLifecycleTicket + 1,
            operatorGeneration: authority.operatorGeneration + 1,
            sessionKey: "chat-browser-b",
            browserOwnerLifecycleTicket: authority.browserOwnerLifecycleTicket + 1
        )
        let replacement = await coordinator.resume(
            authority: replacementAuthority,
            isAuthorityCurrent: { requestAuthority.accountID == "account-b" },
            reserve: { .reserved(try! await service.consumeRequestSlot()) },
            cancelBeforeDispatch: { service.markReservedRequestCancelledBeforeDispatch($0) },
            send: { _, reservation, onDispatchStarted, onAccepted in
                onDispatchStarted()
                service.markReservedRequestAccepted(reservation)
                onAccepted()
            }
        )

        #expect(replacement == .resumed)
        #expect(!service.reservationRetryBlocked)
        requestAuthority = Self.requestAuthority(accountID: "account-a")
        #expect(service.reservationRetryBlocked)
    }

    private func makeUsageService() -> UsageService {
        makeUsageService(requestAuthorityProvider: {
            Self.requestAuthority(accountID: "account-a")
        })
    }

    private func makeUsageService(
        requestAuthorityProvider: @escaping @MainActor () -> AuthenticatedHttpClient.AccountRequestAuthority?
    ) -> UsageService {
        let suite = "BrowserHandBackCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UsageService(
            requestAuthorityProvider: requestAuthorityProvider,
            consumeRequester: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.example.test/api/v1/usage/consume")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data("not-json".utf8), response)
            },
            defaults: defaults
        )
    }

    private static func requestAuthority(
        accountID: String
    ) -> AuthenticatedHttpClient.AccountRequestAuthority {
        AuthenticatedHttpClient.AccountRequestAuthority(
            token: "token-\(accountID)",
            baseURL: "https://api.example.test",
            accountID: accountID
        )
    }

    private func replacingOperatorGeneration(_ generation: UInt64) -> BrowserHandBackAuthority {
        BrowserHandBackAuthority(
            accountID: authority.accountID,
            accountLifecycleTicket: authority.accountLifecycleTicket,
            gatewayURL: authority.gatewayURL,
            gatewayToken: authority.gatewayToken,
            credentialLifecycleTicket: authority.credentialLifecycleTicket,
            operatorGeneration: generation,
            sessionKey: authority.sessionKey,
            browserOwnerLifecycleTicket: authority.browserOwnerLifecycleTicket
        )
    }

    private func authorityWithTickets(
        account: UInt64,
        credential: UInt64,
        browserOwner: UInt64,
        operatorGeneration: UInt64
    ) -> BrowserHandBackAuthority {
        BrowserHandBackAuthority(
            accountID: authority.accountID,
            accountLifecycleTicket: account,
            gatewayURL: authority.gatewayURL,
            gatewayToken: authority.gatewayToken,
            credentialLifecycleTicket: credential,
            operatorGeneration: operatorGeneration,
            sessionKey: authority.sessionKey,
            browserOwnerLifecycleTicket: browserOwner
        )
    }

    private func expectLifecycleABARejectsPriorAttempt(
        replacementAuthority: BrowserHandBackAuthority
    ) async {
        let coordinator = BrowserHandBackCoordinator()
        let service = makeUsageService()
        var sendCount = 0

        let first = await coordinator.resume(
            authority: authority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: { .reserved(try! await service.consumeRequestSlot()) },
            cancelBeforeDispatch: { service.markReservedRequestCancelledBeforeDispatch($0) },
            send: { _, _, onDispatchStarted, _ in
                sendCount += 1
                onDispatchStarted()
                throw TestFailure.expected
            }
        )
        #expect(first == .denied("Rem couldn't resume yet. Give control back again to retry."))
        #expect(service.reservationRetryBlocked)

        let replacement = await coordinator.resume(
            authority: replacementAuthority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: { .denied("Fresh lifecycle requires a fresh reservation") },
            cancelBeforeDispatch: { _ in },
            send: { _, reservation, onDispatchStarted, onAccepted in
                sendCount += 1
                onDispatchStarted()
                service.markReservedRequestAccepted(reservation)
                onAccepted()
            }
        )

        #expect(replacement == .denied("Fresh lifecycle requires a fresh reservation"))
        #expect(sendCount == 1)
        #expect(service.reservationRetryBlocked)
    }

    private func expectStaleSuspendedReservationCannotEraseReplacement(accepted: Bool) async {
        let coordinator = BrowserHandBackCoordinator()
        let staleService = makeUsageService()
        let replacementService = makeUsageService()
        let gate = MainActorSuspensionGate()
        var staleCancellationCount = 0

        let staleTask = Task { @MainActor in
            await coordinator.resume(
                authority: authority,
                isAuthorityCurrent: { true },
                isStableScopeCurrent: { false },
                reserve: {
                    await gate.wait()
                    return .reserved(try! await staleService.consumeRequestSlot())
                },
                cancelBeforeDispatch: { reservation in
                    staleCancellationCount += 1
                    staleService.markReservedRequestCancelledBeforeDispatch(reservation)
                },
                send: { _, _, _, _ in Issue.record("Stale attempt must not dispatch") }
            )
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        coordinator.invalidate()
        let replacementAuthority = authorityWithTickets(
            account: authority.accountLifecycleTicket + 1,
            credential: authority.credentialLifecycleTicket,
            browserOwner: authority.browserOwnerLifecycleTicket,
            operatorGeneration: authority.operatorGeneration + 1
        )
        var replacementReservationCount = 0
        var replacementKeys: [String] = []
        var replacementSendCount = 0

        let firstReplacement = await coordinator.resume(
            authority: replacementAuthority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: {
                replacementReservationCount += 1
                guard replacementReservationCount == 1 else {
                    return .denied("Replacement attempt was erased")
                }
                return .reserved(try! await replacementService.consumeRequestSlot())
            },
            cancelBeforeDispatch: { replacementService.markReservedRequestCancelledBeforeDispatch($0) },
            send: { key, reservation, onDispatchStarted, onAccepted in
                replacementSendCount += 1
                replacementKeys.append(key)
                onDispatchStarted()
                if accepted {
                    replacementService.markReservedRequestAccepted(reservation)
                    onAccepted()
                }
                throw TestFailure.expected
            }
        )
        if accepted {
            #expect(firstReplacement == .denied(
                "Rem accepted this browser handoff, but its continuation didn't finish. Check the chat before continuing."
            ))
        } else {
            #expect(firstReplacement == .denied("Rem couldn't resume yet. Give control back again to retry."))
        }

        gate.release()
        let staleResult = await staleTask.value
        #expect(staleResult == .denied("This browser session changed. Open it again from chat."))
        #expect(staleCancellationCount == 1)
        #expect(!staleService.reservationRetryBlocked)

        let retry = await coordinator.resume(
            authority: replacementAuthority,
            isAuthorityCurrent: { true },
            isStableScopeCurrent: { true },
            reserve: {
                replacementReservationCount += 1
                guard replacementReservationCount == 1 else {
                    return .denied("Replacement attempt was erased")
                }
                return .reserved(try! await replacementService.consumeRequestSlot())
            },
            cancelBeforeDispatch: { replacementService.markReservedRequestCancelledBeforeDispatch($0) },
            send: { key, reservation, onDispatchStarted, onAccepted in
                replacementSendCount += 1
                replacementKeys.append(key)
                onDispatchStarted()
                replacementService.markReservedRequestAccepted(reservation)
                onAccepted()
            }
        )

        #expect(replacementReservationCount == 1)
        if accepted {
            #expect(retry == firstReplacement)
            #expect(replacementSendCount == 1)
            #expect(replacementKeys.count == 1)
        } else {
            #expect(retry == .resumed)
            #expect(replacementSendCount == 2)
            #expect(replacementKeys.count == 2)
            #expect(replacementKeys.first == replacementKeys.last)
            #expect(!replacementService.reservationRetryBlocked)
        }
    }
}

@MainActor
private final class MainActorSuspensionGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum TestFailure: Error {
    case expected
}
