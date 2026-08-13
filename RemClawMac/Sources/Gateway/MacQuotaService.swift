import Foundation
import Observation

struct MacQuotaDispatchContext: Codable, Hashable, Sendable {
    let id: UUID
    fileprivate let accountID: String
    fileprivate let normalizedBackendURL: String
}

struct MacQuotaReservationToken: Codable, Hashable, Sendable {
    let id: UUID
    let dispatchContext: MacQuotaDispatchContext
}

/// The downstream boundary that makes an accepted quota reservation replay-safe. A task existing
/// locally is not evidence that the gateway saw it; only the exact `chat.send` response carrying a
/// run ID acknowledges that the gateway ordered and accepted the request.
struct MacGatewayDispatchAcknowledgement: Sendable {
    let dispatchContext: MacQuotaDispatchContext?
    let runID: String
    let responseData: Data
}

/// A synchronous cancellation gate shared by the owner task and its detached gateway worker.
/// Cancellation can win before the worker begins (preventing any later send), or it can be recorded
/// after dispatch begins so the accepted run is aborted only after its exact run ID arrives.
final class MacGatewayDispatchBoundary: @unchecked Sendable {
    enum CancellationResolution {
        case resolved
        case retryableAbort
    }

    private enum State: Equatable {
        case pending
        case started
        case finished
    }

    private enum AbortState: Equatable {
        case notStarted
        case inProgress
        case completed
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var cancellationRequested = false
    private var acknowledgement: MacGatewayDispatchAcknowledgement?
    private var abortState: AbortState = .notStarted
    private var dispatchResolved = false
    private var resolutionWaiters: [CheckedContinuation<CancellationResolution, Never>] = []

    func beginGatewayRequest() -> Bool {
        lock.withLock {
            guard state == .pending, !cancellationRequested else { return false }
            state = .started
            return true
        }
    }

    func requestCancellation() {
        lock.withLock {
            cancellationRequested = true
        }
    }

    /// Returns whether the accepted run must be aborted. This transition is atomic with respect to
    /// cancellation, so cancellation cannot slip between acceptance and the abort decision.
    func finishAcknowledgement(_ acknowledgement: MacGatewayDispatchAcknowledgement) -> Bool {
        lock.withLock {
            guard state == .started else { return cancellationRequested }
            state = .finished
            self.acknowledgement = acknowledgement
            guard cancellationRequested, abortState == .notStarted else { return false }
            abortState = .inProgress
            return true
        }
    }

    /// Claims the exact accepted run for a late production abort. The send path and every external
    /// abort caller arbitrate through this state, so only one of them can issue `chat.abort`.
    func claimAcceptedRunForCancellation() -> MacGatewayDispatchAcknowledgement? {
        lock.withLock {
            guard cancellationRequested,
                  abortState == .notStarted,
                  let acknowledgement else { return nil }
            abortState = .inProgress
            return acknowledgement
        }
    }

    var acceptedRunID: String? {
        lock.withLock { acknowledgement?.runID }
    }

    func completeAcceptedRunAbort() {
        let waiters = lock.withLock {
            guard abortState == .inProgress else {
                return [CheckedContinuation<CancellationResolution, Never>]()
            }
            abortState = .completed
            return takeResolutionWaitersIfReadyLocked()
        }
        for waiter in waiters { waiter.resume(returning: .resolved) }
    }

    /// Makes a failed exact abort claimable again. Existing joiners wake and compete for the retry;
    /// the caller that observed the failure still propagates it to its production caller.
    func failAcceptedRunAbort() {
        let waiters = lock.withLock {
            guard abortState == .inProgress else {
                return [CheckedContinuation<CancellationResolution, Never>]()
            }
            abortState = .notStarted
            let waiters = resolutionWaiters
            resolutionWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: .retryableAbort) }
    }

    /// Waits until the dispatch has been prevented or failed, or until its one exact accepted-run
    /// abort has completed. A resolved boundary deliberately retains its acknowledgement for a
    /// production abort arriving through either the live registry entry or its bounded tombstone.
    func waitUntilCancellationResolved() async -> CancellationResolution {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if cancellationResolutionIsReadyLocked { return true }
                resolutionWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume(returning: .resolved) }
        }
    }

    func resolve() {
        let waiters = lock.withLock {
            guard !dispatchResolved else {
                return [CheckedContinuation<CancellationResolution, Never>]()
            }
            dispatchResolved = true
            return takeResolutionWaitersIfReadyLocked()
        }
        for waiter in waiters { waiter.resume(returning: .resolved) }
    }

    private var cancellationResolutionIsReadyLocked: Bool {
        guard dispatchResolved else { return false }
        guard cancellationRequested, acknowledgement != nil else { return true }
        return abortState == .completed
    }

    private func takeResolutionWaitersIfReadyLocked()
        -> [CheckedContinuation<CancellationResolution, Never>]
    {
        guard cancellationResolutionIsReadyLocked else { return [] }
        let waiters = resolutionWaiters
        resolutionWaiters.removeAll()
        return waiters
    }
}

/// Runs one quota-backed gateway request across the only safe cancellation boundary:
///
/// 1. A cancellation that wins before `beginGatewayRequest` prevents the detached worker from
///    issuing a later send; the owning surface receives the exact pre-dispatch disposition hook.
/// 2. Once the worker begins, the reservation remains persisted until a decodable gateway run ID.
/// 3. Cancellation during that interval waits for the run ID, retires the exact reservation through
///    `onAcknowledged`, then aborts only that accepted run.
enum MacQuotaGatewayDispatch {
    typealias Request = @Sendable () async throws -> Data
    typealias DecodeRunID = @Sendable (Data) throws -> String
    typealias OnAcknowledged = @Sendable (MacGatewayDispatchAcknowledgement) async -> Void
    typealias AbortAcceptedRun = @Sendable (MacGatewayDispatchAcknowledgement) async throws -> Void

    static func run(
        boundary: MacGatewayDispatchBoundary = MacGatewayDispatchBoundary(),
        dispatchContext: MacQuotaDispatchContext?,
        beforeGatewayStart: (@Sendable () async -> Void)? = nil,
        onCancelledBeforeGatewayStart: (@Sendable () async -> Void)? = nil,
        request: @escaping Request,
        decodeRunID: @escaping DecodeRunID,
        onAcknowledged: @escaping OnAcknowledged,
        abortAcceptedRun: @escaping AbortAcceptedRun
    ) async throws -> MacGatewayDispatchAcknowledgement {
        let requestTask = Task.detached {
            if let beforeGatewayStart { await beforeGatewayStart() }
            guard boundary.beginGatewayRequest() else {
                await onCancelledBeforeGatewayStart?()
                throw CancellationError()
            }
            let responseData = try await request()
            return MacGatewayDispatchAcknowledgement(
                dispatchContext: dispatchContext,
                runID: try decodeRunID(responseData),
                responseData: responseData
            )
        }

        defer { boundary.resolve() }
        return try await withTaskCancellationHandler {
            let acknowledgement = try await requestTask.value
            await onAcknowledged(acknowledgement)
            if boundary.finishAcknowledgement(acknowledgement) {
                do {
                    try await abortAcceptedRun(acknowledgement)
                } catch {
                    boundary.failAcceptedRunAbort()
                    throw error
                }
                boundary.completeAcceptedRunAbort()
                throw CancellationError()
            }
            return acknowledgement
        } onCancel: {
            boundary.requestCancellation()
        }
    }
}

enum MacQuotaReservationError: Error, LocalizedError {
    case unavailable
    case quotaExceeded(QuotaExceededError)
    case outcomeUnknown
    case retryBlocked
    case reservationInFlight

    var errorDescription: String? {
        switch self {
        case .unavailable: "Rem couldn't verify your plan right now."
        case .quotaExceeded(let quota): quota.message
        case .outcomeUnknown: "The quota reservation result is unknown."
        case .retryBlocked: "A previous quota reservation or dispatch is still unresolved."
        case .reservationInFlight: "Another quota check is still in progress."
        }
    }
}

enum MacQuotaFailurePolicy {
    enum Decision {
        case quotaExceeded(QuotaExceededError)
        case verificationUnavailable
        case reservationRetryBlocked
    }

    static func classify(_ error: Error) -> Decision {
        guard let quotaError = error as? MacQuotaReservationError else {
            return .verificationUnavailable
        }
        switch quotaError {
        case .quotaExceeded(let quota): return .quotaExceeded(quota)
        case .outcomeUnknown, .retryBlocked: return .reservationRetryBlocked
        case .unavailable, .reservationInFlight: return .verificationUnavailable
        }
    }
}

enum MacQuotaAvailability {
    /// Unknown or stale billing state must reach the backend reservation gate; it is never Free-plan proof.
    static func hasQuota(summary: UsageSummary?, summaryIsCurrent: Bool, latestRemaining: RemainingQuota?) -> Bool {
        if let latestRemaining { return latestRemaining.day > 0 && latestRemaining.month > 0 }
        guard summaryIsCurrent, let summary else { return true }
        return summary.remaining.day > 0 && summary.remaining.month > 0
    }
}

enum MacQuotaBannerPolicy {
    static let exhausted = "Daily request limit reached"
    static let dispatchUnresolved = "That request wasn't sent, but its quota reservation is unresolved. "
        + "To avoid counting it twice, don't retry it. Check Usage or contact support."

    static func message(
        reservationRetryBlocked: Bool,
        plan: String? = nil,
        remaining: RemainingQuota = RemainingQuota(day: 0, month: 1)
    ) -> String {
        if reservationRetryBlocked { return dispatchUnresolved }
        return QuotaPresentation.make(plan: plan, remaining: remaining).bannerText
    }
}

@Observable @MainActor
final class MacQuotaService {
    typealias AuthorityProvider = @MainActor () -> MacBackendAuthAuthority?
    typealias Requester = @MainActor (MacBackendAuthAuthority) async throws -> (Data, HTTPURLResponse)
    typealias ResetScheduler = @MainActor (
        _ resetDate: Date,
        _ action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>

    private struct Scope: Codable, Hashable {
        let accountID: String
        let normalizedBackendURL: String
    }

    private struct ScopeLedger: Codable {
        let version: Int
        let scopes: [Scope]
    }

    private struct ReservationLedger: Codable {
        let version: Int
        let reservations: [MacQuotaReservationToken]
    }

    private static let retryBlockadesKey = "rem.mac.usage.ambiguous-reservation-scopes.v1"
    private static let pendingDispatchKey = "rem.mac.usage.pending-reservation-dispatches.v1"

    private var scopedRemaining: RemainingQuota?
    private var remainingScope: Scope?
    private var remainingObservedAt: Date?
    private(set) var quotaFreshnessRevision: UInt64 = 0
    private var retryBlockedScopes: Set<Scope>
    private var pendingDispatches: Set<MacQuotaReservationToken>
    private var inFlightScopes: Set<Scope> = []
    @ObservationIgnored private let authorityProvider: AuthorityProvider
    @ObservationIgnored private let requester: Requester
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let resetScheduler: ResetScheduler
    @ObservationIgnored private var quotaResetTask: Task<Void, Never>?

    init(
        authorityProvider: @escaping AuthorityProvider = {
            MacAuthenticatedHttpClient.currentAuthenticationAuthority?()
        },
        requester: @escaping Requester = { authority in
            try await MacAuthenticatedHttpClient.request(
                path: "/api/v1/usage/consume",
                method: "POST",
                body: Data("{}".utf8),
                authority: authority
            )
        },
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = Date.init,
        resetScheduler: @escaping ResetScheduler = { resetDate, action in
            Task { @MainActor in
                let delay = max(0, resetDate.timeIntervalSinceNow)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                action()
            }
        }
    ) {
        self.authorityProvider = authorityProvider
        self.requester = requester
        self.defaults = defaults
        self.now = now
        self.resetScheduler = resetScheduler
        self.retryBlockedScopes = Self.loadRetryBlockedScopes(from: defaults)
        self.pendingDispatches = Self.loadPendingDispatches(from: defaults)
    }

    var reservationRetryBlocked: Bool {
        guard let activeScope = currentScope() else { return false }
        return retryBlockedScopes.contains(activeScope)
            || pendingDispatches.contains { scope(for: $0.dispatchContext) == activeScope }
    }

    var latestRemaining: RemainingQuota? {
        _ = quotaFreshnessRevision
        guard let currentScope = currentScope(), currentScope == remainingScope else { return nil }
        if let scopedRemaining,
           (scopedRemaining.day <= 0 || scopedRemaining.month <= 0),
           !QuotaEvidenceFreshness.canBlockLocally(
               remaining: scopedRemaining,
               observedAt: remainingObservedAt,
               now: now()
           ) {
            return nil
        }
        return scopedRemaining
    }

    func effectiveRemaining(fallbackSummary summary: UsageSummary?, summaryIsCurrent: Bool) -> RemainingQuota? {
        _ = quotaFreshnessRevision
        guard let currentScope = currentScope() else { return nil }
        if currentScope == remainingScope {
            // Scoped evidence owns this account/backend even after a cached denial expires. Falling
            // back to the summary that originally supplied that zero would locally re-lock the UI.
            return latestRemaining
        }
        return summaryIsCurrent ? summary?.remaining : nil
    }

    /// Creates a route-bound dispatch identity while the current account/backend owns the intent.
    /// A transport or voice turn must retain this exact value through ordered `chat.send` dispatch.
    func makeDispatchContext() -> MacQuotaDispatchContext? {
        guard let scope = currentScope() else { return nil }
        return MacQuotaDispatchContext(
            id: UUID(),
            accountID: scope.accountID,
            normalizedBackendURL: scope.normalizedBackendURL
        )
    }

    /// Accepts only a summary already fenced by MacGatewaySessionManager. Binding it to the current
    /// account/backend prevents a prior account's exhausted balance from disabling a replacement.
    func recordAuthoritativeRemaining(_ remaining: RemainingQuota) {
        guard let scope = currentScope() else { return }
        remainingScope = scope
        scopedRemaining = remaining
        remainingObservedAt = now()
        scheduleQuotaReset()
    }

    /// Reserves one backend slot and durably binds every accepted HTTP 200 to the exact downstream
    /// dispatch context before returning. Cancellation or relaunch therefore cannot charge a retry.
    func consumeRequestSlot(
        dispatchContext: MacQuotaDispatchContext
    ) async throws -> MacQuotaReservationToken {
        guard let authority = authorityProvider(), let reservationScope = scope(for: authority),
              scope(for: dispatchContext) == reservationScope else {
            throw MacQuotaReservationError.unavailable
        }
        guard !isBlocked(reservationScope) else { throw MacQuotaReservationError.retryBlocked }
        guard inFlightScopes.insert(reservationScope).inserted else {
            throw MacQuotaReservationError.reservationInFlight
        }
        defer { inFlightScopes.remove(reservationScope) }

        // No interleaving occurs on MainActor between this final blockade check and entering the
        // requester. It closes the second-caller window after claiming the single-flight scope.
        guard !isBlocked(reservationScope) else { throw MacQuotaReservationError.retryBlocked }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await requester(authority)
        } catch {
            if isDefinitelyUncommitted(error) { throw MacQuotaReservationError.unavailable }
            blockRetries(for: reservationScope)
            throw MacQuotaReservationError.outcomeUnknown
        }

        // Every accepted 200 is committed before the route emits it. Persist the exact downstream
        // handoff before checking replacement authority; task cancellation still returns this exact
        // token so its owning surface can record a truthful pre-dispatch terminal disposition.
        let acceptedToken: MacQuotaReservationToken?
        if response.statusCode == 200 {
            let token = MacQuotaReservationToken(id: UUID(), dispatchContext: dispatchContext)
            beginDispatchHandoff(token)
            acceptedToken = token
        } else {
            acceptedToken = nil
        }

        if !canPublish(authority) {
            if response.statusCode == 200 {
                throw MacQuotaReservationError.outcomeUnknown
            }
            if !(400...499).contains(response.statusCode) {
                blockRetries(for: reservationScope)
                throw MacQuotaReservationError.outcomeUnknown
            }
            throw MacQuotaReservationError.unavailable
        }

        if response.statusCode == 429 {
            guard let quota = try? JSONDecoder().decode(QuotaErrorResponse.self, from: data).error else {
                throw MacQuotaReservationError.unavailable
            }
            recordRemaining(quota.remaining, for: reservationScope)
            throw MacQuotaReservationError.quotaExceeded(quota)
        }

        guard response.statusCode == 200 else {
            if !(400...499).contains(response.statusCode) {
                blockRetries(for: reservationScope)
                throw MacQuotaReservationError.outcomeUnknown
            }
            throw MacQuotaReservationError.unavailable
        }

        guard let token = acceptedToken else {
            blockRetries(for: reservationScope)
            throw MacQuotaReservationError.outcomeUnknown
        }

        // HTTP 200 is committed even if its optional summary is malformed. The durable token still
        // blocks replay and can be retired only when the gateway acknowledges an exact chat run.
        guard let consume = try? JSONDecoder().decode(UsageConsumeResponse.self, from: data) else {
            return token
        }
        if consume.ok {
            recordRemaining(consume.remaining, for: reservationScope)
        }
        return token
    }

    /// Retires only the exact reservation whose downstream gateway returned an accepted run ID.
    func markReservedRequestAcknowledged(_ token: MacQuotaReservationToken) {
        retireDispatchHandoff(token)
    }

    /// Retires exactly one committed quota reservation when its owning turn loses authority before
    /// `chat.send` begins. The backend quota unit remains charged; this terminal local disposition
    /// prevents the stale turn from retrying or blocking a later request.
    func markReservedRequestCancelledBeforeDispatch(_ token: MacQuotaReservationToken) {
        retireDispatchHandoff(token)
    }

    /// Text transport owns the exact route context rather than the reservation return value. Since
    /// one unresolved reservation blocks its scope, a context identifies at most one exact token.
    func markReservedRequestAcknowledged(in dispatchContext: MacQuotaDispatchContext) {
        let matches = pendingDispatches.filter { $0.dispatchContext == dispatchContext }
        guard matches.count == 1, let token = matches.first else { return }
        markReservedRequestAcknowledged(token)
    }

    private func canPublish(_ captured: MacBackendAuthAuthority) -> Bool {
        guard let current = authorityProvider() else { return false }
        return captured.accountGeneration == current.accountGeneration
            && normalized(captured.backendURL) == normalized(current.backendURL)
    }

    private func currentScope() -> Scope? {
        guard let authority = authorityProvider() else { return nil }
        return scope(for: authority)
    }

    private func scope(for authority: MacBackendAuthAuthority) -> Scope? {
        guard let accountID = VoiceConfigurationAccountIdentity.accountID(fromJWT: authority.backendToken) else {
            return nil
        }
        return Scope(accountID: accountID, normalizedBackendURL: normalized(authority.backendURL))
    }

    private func scope(for context: MacQuotaDispatchContext) -> Scope {
        Scope(accountID: context.accountID, normalizedBackendURL: context.normalizedBackendURL)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func isBlocked(_ scope: Scope) -> Bool {
        retryBlockedScopes.contains(scope)
            || pendingDispatches.contains { self.scope(for: $0.dispatchContext) == scope }
    }

    private func blockRetries(for scope: Scope) {
        guard retryBlockedScopes.insert(scope).inserted else { return }
        persistRetryBlockedScopes()
    }

    private func beginDispatchHandoff(_ token: MacQuotaReservationToken) {
        guard pendingDispatches.insert(token).inserted else { return }
        persistPendingDispatches()
    }

    private func retireDispatchHandoff(_ token: MacQuotaReservationToken) {
        guard pendingDispatches.remove(token) != nil else { return }
        persistPendingDispatches()
    }

    private func recordRemaining(_ remaining: RemainingQuota, for scope: Scope) {
        remainingScope = scope
        scopedRemaining = remaining
        remainingObservedAt = now()
        scheduleQuotaReset()
    }

    private func scheduleQuotaReset() {
        quotaResetTask?.cancel()
        guard let remaining = scopedRemaining,
              let observedAt = remainingObservedAt,
              QuotaEvidenceFreshness.canBlockLocally(
                  remaining: remaining,
                  observedAt: observedAt,
                  now: now()
              ),
              let resetDate = QuotaEvidenceFreshness.resetDate(
                  for: remaining,
                  observedAt: observedAt
              ) else {
            quotaResetTask = nil
            return
        }
        quotaResetTask = resetScheduler(resetDate) { [weak self] in
            guard let self else { return }
            self.quotaFreshnessRevision &+= 1
            self.scheduleQuotaReset()
        }
    }

    private static func loadRetryBlockedScopes(from defaults: UserDefaults) -> Set<Scope> {
        guard let data = defaults.data(forKey: retryBlockadesKey),
              let ledger = try? JSONDecoder().decode(ScopeLedger.self, from: data),
              ledger.version == 1 else { return [] }
        return Set(ledger.scopes)
    }

    private func persistRetryBlockedScopes() {
        let ledger = ScopeLedger(version: 1, scopes: retryBlockedScopes.sorted {
            ($0.accountID, $0.normalizedBackendURL) < ($1.accountID, $1.normalizedBackendURL)
        })
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.retryBlockadesKey)
    }

    private static func loadPendingDispatches(from defaults: UserDefaults) -> Set<MacQuotaReservationToken> {
        guard let data = defaults.data(forKey: pendingDispatchKey),
              let ledger = try? JSONDecoder().decode(ReservationLedger.self, from: data),
              ledger.version == 1 else { return [] }
        return Set(ledger.reservations)
    }

    private func persistPendingDispatches() {
        let ledger = ReservationLedger(version: 1, reservations: pendingDispatches.sorted {
            $0.id.uuidString < $1.id.uuidString
        })
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.pendingDispatchKey)
    }

    private func isDefinitelyUncommitted(_ error: Error) -> Bool {
        guard let authError = error as? MacAuthenticatedHttpError else { return false }
        switch authError {
        case .notAuthenticated, .unauthorized, .invalidURL: return true
        case .invalidResponse, .httpError: return false
        }
    }
}
