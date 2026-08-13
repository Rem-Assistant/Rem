import Foundation

struct BrowserHandBackAuthority: Equatable {
    let accountID: String
    let accountLifecycleTicket: UInt64
    let gatewayURL: String
    let gatewayToken: String
    let credentialLifecycleTicket: UInt64
    let operatorGeneration: UInt64
    let sessionKey: String
    let browserOwnerLifecycleTicket: UInt64

    init(
        accountID: String,
        accountLifecycleTicket: UInt64,
        gatewayURL: String,
        gatewayToken: String,
        credentialLifecycleTicket: UInt64,
        operatorGeneration: UInt64,
        sessionKey: String,
        browserOwnerLifecycleTicket: UInt64
    ) {
        self.accountID = accountID
        self.accountLifecycleTicket = accountLifecycleTicket
        self.gatewayURL = gatewayURL
        self.gatewayToken = gatewayToken
        self.credentialLifecycleTicket = credentialLifecycleTicket
        self.operatorGeneration = operatorGeneration
        self.sessionKey = sessionKey
        self.browserOwnerLifecycleTicket = browserOwnerLifecycleTicket
    }

    var stableScope: StableScope {
        StableScope(
            accountID: accountID,
            accountLifecycleTicket: accountLifecycleTicket,
            gatewayURL: gatewayURL,
            gatewayToken: gatewayToken,
            credentialLifecycleTicket: credentialLifecycleTicket,
            sessionKey: sessionKey,
            browserOwnerLifecycleTicket: browserOwnerLifecycleTicket
        )
    }

    struct StableScope: Equatable {
        let accountID: String
        let accountLifecycleTicket: UInt64
        let gatewayURL: String
        let gatewayToken: String
        let credentialLifecycleTicket: UInt64
        let sessionKey: String
        let browserOwnerLifecycleTicket: UInt64
    }
}

enum BrowserHandBackOutcome: Equatable {
    case resumed
    case denied(String)
}

enum BrowserHandBackReservationDecision: Equatable {
    case reserved(UsageService.RequestSlotReservation)
    case denied(String)
}

/// Owns the one opaque request reservation associated with a browser hand-back until the hidden
/// resume `chat.send` is accepted. A retry after transport failure reuses that exact durable token
/// and the exact `chat.send` idempotency key instead of charging the user twice. Acceptance is a
/// terminal boundary for this hand-back even when later transport cleanup throws.
@MainActor
final class BrowserHandBackCoordinator {
    private final class DispatchProgress {
        var didStart = false
        var isAccepted = false
    }

    private enum DispatchState: Equatable {
        case notStarted
        case started
        case acceptedTerminal
    }

    private struct Attempt {
        let id: UUID
        var authority: BrowserHandBackAuthority
        let idempotencyKey: String
        var reservation: UsageService.RequestSlotReservation?
        var dispatchState: DispatchState
    }

    private var attempt: Attempt?
    private var generation: UInt64 = 0
    private var inFlight = false

    func invalidate(preservingRecoverableAttempt: Bool = false) {
        generation &+= 1
        if !preservingRecoverableAttempt {
            attempt = nil
        }
        inFlight = false
    }

    /// Waits for the previously-started takeover RPC without claiming coordinator state. A caller
    /// that becomes stale while suspended owns no attempt, so it must return locally and cannot
    /// invalidate a newer caller's retained ambiguity or accepted tombstone.
    func resumeAfterTakeoverSettles(
        waitForTakeover: @escaping @MainActor () async -> Void,
        authority: BrowserHandBackAuthority,
        isAuthorityCurrent: @escaping @MainActor () -> Bool,
        isStableScopeCurrent: @escaping @MainActor () -> Bool = { true },
        reserve: @escaping @MainActor () async -> BrowserHandBackReservationDecision,
        cancelBeforeDispatch: @escaping @MainActor (UsageService.RequestSlotReservation) -> Void,
        send: @escaping @MainActor (
            _ idempotencyKey: String,
            _ reservation: UsageService.RequestSlotReservation,
            _ onDispatchStarted: @escaping @MainActor @Sendable () -> Void,
            _ onAccepted: @escaping @MainActor @Sendable () -> Void
        ) async throws -> Void
    ) async -> BrowserHandBackOutcome {
        await waitForTakeover()
        guard isAuthorityCurrent() else {
            return .denied("This browser session changed. Open it again from chat.")
        }
        return await resume(
            authority: authority,
            isAuthorityCurrent: isAuthorityCurrent,
            isStableScopeCurrent: isStableScopeCurrent,
            reserve: reserve,
            cancelBeforeDispatch: cancelBeforeDispatch,
            send: send
        )
    }

    func resume(
        authority: BrowserHandBackAuthority,
        isAuthorityCurrent: @escaping @MainActor () -> Bool,
        isStableScopeCurrent: @escaping @MainActor () -> Bool = { true },
        reserve: @escaping @MainActor () async -> BrowserHandBackReservationDecision,
        cancelBeforeDispatch: @escaping @MainActor (UsageService.RequestSlotReservation) -> Void,
        send: @escaping @MainActor (
            _ idempotencyKey: String,
            _ reservation: UsageService.RequestSlotReservation,
            _ onDispatchStarted: @escaping @MainActor @Sendable () -> Void,
            _ onAccepted: @escaping @MainActor @Sendable () -> Void
        ) async throws -> Void
    ) async -> BrowserHandBackOutcome {
        guard !inFlight else {
            return .denied("Rem is already getting ready to continue.")
        }

        generation &+= 1
        let operationGeneration = generation
        inFlight = true
        defer {
            if operationGeneration == generation {
                inFlight = false
            }
        }

        if let existingAttempt = attempt,
           existingAttempt.authority.stableScope != authority.stableScope {
            if existingAttempt.dispatchState == .notStarted,
               let reservation = existingAttempt.reservation {
                cancelBeforeDispatch(reservation)
            }
            clearAttempt(ifOwnedBy: existingAttempt)
        }
        if var existingAttempt = attempt,
           existingAttempt.authority.operatorGeneration != authority.operatorGeneration,
           existingAttempt.dispatchState == .started {
            // A post-wire ambiguity belongs to the stable account/gateway/browser scope, not the
            // replaceable operator socket. Rebind only the generation; token and key stay exact.
            existingAttempt.authority = authority
            attempt = existingAttempt
        } else if let existingAttempt = attempt,
                  existingAttempt.authority.operatorGeneration != authority.operatorGeneration,
                  existingAttempt.dispatchState == .notStarted {
            if let reservation = existingAttempt.reservation {
                cancelBeforeDispatch(reservation)
            }
            clearAttempt(ifOwnedBy: existingAttempt)
        }
        if attempt == nil {
            attempt = Attempt(
                id: UUID(),
                authority: authority,
                idempotencyKey: UUID().uuidString,
                reservation: nil,
                dispatchState: .notStarted
            )
        }

        guard var currentAttempt = attempt else {
            return .denied("Rem couldn't prepare the browser handoff.")
        }
        if case .acceptedTerminal = currentAttempt.dispatchState {
            return .denied(Self.acceptedTerminalMessage)
        }

        if currentAttempt.reservation == nil {
            let decision = await reserve()
            guard operationGeneration == generation, isAuthorityCurrent() else {
                if case .reserved(let reservation) = decision {
                    cancelBeforeDispatch(reservation)
                }
                clearAttempt(ifOwnedBy: currentAttempt)
                return .denied("This browser session changed. Open it again from chat.")
            }
            switch decision {
            case .reserved(let reservation):
                currentAttempt.reservation = reservation
                attempt = currentAttempt
            case .denied(let message):
                clearAttempt(ifOwnedBy: currentAttempt)
                return .denied(message)
            }
        }

        guard operationGeneration == generation, isAuthorityCurrent() else {
            if let reservation = currentAttempt.reservation,
               currentAttempt.dispatchState == .notStarted {
                cancelBeforeDispatch(reservation)
                clearAttempt(ifOwnedBy: currentAttempt)
                return .denied("This browser session changed. Open it again from chat.")
            }
            if currentAttempt.dispatchState == .started,
               isStableScopeCurrent() {
                retain(currentAttempt, whileStableScopeCurrent: true)
                return .denied(Self.connectionRetryMessage)
            }
            clearAttempt(ifOwnedBy: currentAttempt)
            return .denied("This browser session changed. Open it again from chat.")
        }

        guard let reservation = currentAttempt.reservation else {
            clearAttempt(ifOwnedBy: currentAttempt)
            return .denied("Rem couldn't prepare the browser handoff.")
        }

        let idempotencyKey = currentAttempt.idempotencyKey
        let attemptID = currentAttempt.id
        let dispatchProgress = DispatchProgress()
        do {
            try await send(
                idempotencyKey,
                reservation,
                {
                    dispatchProgress.didStart = true
                    guard var activeAttempt = self.attempt,
                          activeAttempt.id == attemptID else { return }
                    activeAttempt.dispatchState = .started
                    self.attempt = activeAttempt
                },
                {
                    dispatchProgress.isAccepted = true
                    guard var activeAttempt = self.attempt,
                          activeAttempt.id == attemptID else { return }
                    activeAttempt.dispatchState = .acceptedTerminal
                    self.attempt = activeAttempt
                }
            )
        } catch {
            if dispatchProgress.isAccepted {
                currentAttempt.dispatchState = .acceptedTerminal
                retain(currentAttempt, whileStableScopeCurrent: isStableScopeCurrent())
                return .denied(Self.acceptedTerminalMessage)
            }
            guard operationGeneration == generation, isAuthorityCurrent() else {
                if currentAttempt.dispatchState == .notStarted,
                   !dispatchProgress.didStart {
                    cancelBeforeDispatch(reservation)
                    clearAttempt(ifOwnedBy: currentAttempt)
                    return .denied("This browser session changed. Open it again from chat.")
                }
                if isStableScopeCurrent() {
                    currentAttempt.dispatchState = .started
                    retain(currentAttempt, whileStableScopeCurrent: true)
                    return .denied(Self.connectionRetryMessage)
                }
                clearAttempt(ifOwnedBy: currentAttempt)
                return .denied("This browser session changed. Open it again from chat.")
            }
            if dispatchProgress.didStart {
                currentAttempt.dispatchState = .started
            }
            // Keep the exact opaque reservation and idempotency key. The next tap retries only the
            // same hidden dispatch; it never performs a second quota reservation.
            retain(currentAttempt, whileStableScopeCurrent: true)
            return .denied("Rem couldn't resume yet. Give control back again to retry.")
        }

        guard dispatchProgress.isAccepted else {
            if dispatchProgress.didStart {
                currentAttempt.dispatchState = .started
            }
            retain(currentAttempt, whileStableScopeCurrent: true)
            return .denied("Rem couldn't confirm the browser handoff. Give control back again to retry.")
        }

        // Acceptance is terminal before any final authority/generation check. A reconnect can
        // invalidate the awaiting operation after the gateway has already accepted the run; retain
        // the stable-scope tombstone so that race can never authorize another reservation/send.
        currentAttempt.dispatchState = .acceptedTerminal
        retain(currentAttempt, whileStableScopeCurrent: isStableScopeCurrent())
        guard operationGeneration == generation, isAuthorityCurrent() else {
            return .denied(Self.acceptedTerminalMessage)
        }
        clearAttempt(ifOwnedBy: currentAttempt)
        return .resumed
    }

    private func retain(_ candidate: Attempt, whileStableScopeCurrent isCurrent: Bool) {
        guard isCurrent else { return }
        guard attempt == nil || isSameAttempt(attempt, as: candidate) else { return }
        attempt = candidate
    }

    private func clearAttempt(ifOwnedBy candidate: Attempt) {
        guard isSameAttempt(attempt, as: candidate) else { return }
        attempt = nil
    }

    private func isSameAttempt(_ lhs: Attempt?, as rhs: Attempt) -> Bool {
        lhs?.id == rhs.id
    }

    private static let acceptedTerminalMessage =
        "Rem accepted this browser handoff, but its continuation didn't finish. Check the chat before continuing."
    private static let connectionRetryMessage =
        "Rem's connection changed before it could confirm the browser handoff. Give control back again to retry."
}
