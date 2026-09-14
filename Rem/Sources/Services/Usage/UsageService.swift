import Foundation
import Observation

@Observable @MainActor
final class UsageService {
    struct RequestSlotReservation: Hashable, Sendable {
        fileprivate let id: UUID
    }

    typealias RequestAuthorityProvider = @MainActor () -> AuthenticatedHttpClient.AccountRequestAuthority?
    typealias ConsumeRequester = @MainActor (
        _ authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) async throws -> (Data, HTTPURLResponse)
    typealias SummaryRequester = @MainActor (
        _ authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) async throws -> (Data, HTTPURLResponse)
    typealias ResetScheduler = @MainActor (
        _ resetDate: Date,
        _ action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>

    private(set) var summary: UsageSummary?
    private var quotaExceededStored = false
    private(set) var quotaError: QuotaExceededError?
    private(set) var isLoading = false
    private(set) var summaryLoadError: String?
    private(set) var summaryIsStale = false
    private var retryBlockedScopes: Set<ReservationScope>
    private var pendingDispatchReservations: [UUID: ReservationScope]
    private var inFlightReservationScopes: Set<ReservationScope> = []
    private var accountResetGeneration: UInt64 = 0
    private var summaryRequestGeneration: UInt64 = 0
    private var summaryObservedAt: Date?
    private var quotaErrorObservedAt: Date?
    private(set) var quotaFreshnessRevision: UInt64 = 0
    @ObservationIgnored private let requestAuthorityProvider: RequestAuthorityProvider
    @ObservationIgnored private let consumeRequester: ConsumeRequester
    @ObservationIgnored private let summaryRequester: SummaryRequester
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let resetScheduler: ResetScheduler
    @ObservationIgnored private var quotaResetTask: Task<Void, Never>?

    private static let retryBlockadesDefaultsKey = "rem.usage.ambiguous-reservation-scopes.v1"
    private static let pendingDispatchDefaultsKey = "rem.usage.pending-reservation-dispatch-scopes.v1"

    init(
        requestAuthorityProvider: @escaping RequestAuthorityProvider = {
            AuthenticatedHttpClient.captureAccountRequestAuthority()
        },
        consumeRequester: @escaping ConsumeRequester = { authority in
            try await AuthenticatedHttpClient.request(
                path: "/api/v1/usage/consume",
                method: "POST",
                body: Data("{}".utf8),
                authority: authority
            )
        },
        summaryRequester: @escaping SummaryRequester = { authority in
            try await AuthenticatedHttpClient.request(
                path: "/api/v1/usage/summary",
                method: "GET",
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
        self.requestAuthorityProvider = requestAuthorityProvider
        self.consumeRequester = consumeRequester
        self.summaryRequester = summaryRequester
        self.defaults = defaults
        self.now = now
        self.resetScheduler = resetScheduler
        self.retryBlockedScopes = Self.loadRetryBlockedScopes(from: defaults)
        self.pendingDispatchReservations = Self.loadPendingDispatchReservations(from: defaults)
    }

    var reservationRetryBlocked: Bool {
        guard let authority = requestAuthorityProvider() else { return false }
        let scope = reservationScope(for: authority)
        return retryBlockedScopes.contains(scope)
            || pendingDispatchReservations.values.contains(scope)
    }

    var pendingDispatchReservationCount: Int {
        pendingDispatchReservations.count
    }

    var quotaExceeded: Bool {
        _ = quotaFreshnessRevision
        return quotaExceededStored && QuotaPresentation.currentDenial(
            plan: summary?.plan,
            remaining: effectiveRemaining
        ) != nil
    }
    
    var effectiveRemaining: RemainingQuota? {
        _ = quotaFreshnessRevision
        let summaryRemaining = currentRemaining(summary?.remaining, observedAt: summaryObservedAt)
        let errorRemaining = currentRemaining(quotaError?.remaining, observedAt: quotaErrorObservedAt)
        if let summaryRemaining, let errorRemaining {
            return RemainingQuota(
                day: min(summaryRemaining.day, errorRemaining.day),
                month: min(summaryRemaining.month, errorRemaining.month)
            )
        }
        return summaryRemaining ?? errorRemaining
    }

    var hasQuotaForUI: Bool {
        guard let remaining = effectiveRemaining else { return true }
        return remaining.day > 0 && remaining.month > 0
    }

    var quotaPresentation: QuotaPresentation {
        QuotaPresentation.make(
            // A consume/429 validates quota balance, not cached subscription metadata. Never turn
            // an unverified plan into Upgrade or Manage Subscription while Billing is stale/failed.
            plan: summaryIsStale || summaryLoadError != nil ? nil : summary?.plan,
            remaining: effectiveRemaining ?? RemainingQuota(day: 0, month: 0)
        )
    }
    
    func fetchSummary() async throws {
        summaryRequestGeneration &+= 1
        summaryIsStale = summary != nil
        isLoading = true
        summaryLoadError = nil
        guard let requestAuthority = requestAuthorityProvider() else {
            isLoading = false
            summaryLoadError = "Sign in again to load your plan and usage."
            return
        }
        let authority = SummaryOperationAuthority(
            accountGeneration: accountResetGeneration,
            requestGeneration: summaryRequestGeneration,
            request: requestAuthority
        )

        defer {
            if canCommitSummary(authority) {
                isLoading = false
            }
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await summaryRequester(requestAuthority)
        } catch {
            guard canCommitSummary(authority) else { return }
            summaryIsStale = summary != nil
            summaryLoadError = "Rem couldn't load your plan and usage. Check your connection and try again."
            throw error
        }

        guard canCommitSummary(authority) else { return }

        guard http.statusCode == 200 else {
            summaryIsStale = summary != nil
            summaryLoadError = "Rem couldn't load your plan and usage. Check your connection and try again."
            throw UsageError.httpError(http.statusCode)
        }
        do {
            applyFreshSummary(try JSONDecoder().decode(UsageSummary.self, from: data))
        } catch {
            summaryIsStale = summary != nil
            summaryLoadError = "Rem couldn't load your plan and usage. Check your connection and try again."
            throw error
        }
    }

    func consumeRequestSlot() async throws -> RequestSlotReservation {
        guard let requestAuthority = requestAuthorityProvider() else {
            throw UsageError.notAuthenticated
        }
        let authority = OperationAuthority(
            generation: accountResetGeneration,
            request: requestAuthority
        )
        let accountScope = reservationScope(for: requestAuthority)
        guard !retryBlockedScopes.contains(accountScope),
              !pendingDispatchReservations.values.contains(accountScope)
        else {
            throw UsageError.reservationRetryBlocked
        }
        guard inFlightReservationScopes.insert(accountScope).inserted else {
            throw UsageError.reservationInProgress
        }
        defer { inFlightReservationScopes.remove(accountScope) }

        // The actor cannot be interleaved between this final scope check and entering the
        // requester. Keeping it after the in-flight claim prevents a second caller from passing
        // an older blockade snapshot while the first reservation is unresolved.
        guard !retryBlockedScopes.contains(accountScope),
              !pendingDispatchReservations.values.contains(accountScope)
        else {
            throw UsageError.reservationRetryBlocked
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await consumeRequester(requestAuthority)
        } catch {
            guard !Self.isDefinitelyUncommitted(error) else { throw error }
            blockRetries(for: accountScope)
            throw UsageError.reservationOutcomeUnknown
        }

        // HTTP 200 is the authoritative commit boundary. Persist the captured scope before any
        // mutable-current-authority check can retire this continuation; an A→B swap must never
        // turn A's committed slot into an identity-less generic blockade.
        let acceptedReservation = http.statusCode == 200
            ? beginDispatchHandoff(for: accountScope)
            : nil

        // Reset/account replacement retires the caller, but it cannot make a committed or
        // ambiguous reservation safe to replay. Fence the captured account before denying the old
        // continuation; definite 4xx responses remain recoverable and publish no replacement state.
        guard canCommit(authority) else {
            if acceptedReservation != nil {
                throw UsageError.reservationOutcomeUnknown
            }
            if !(400...499).contains(http.statusCode) {
                blockRetries(for: accountScope)
                throw UsageError.reservationOutcomeUnknown
            }
            throw UsageError.notAuthenticated
        }

        if http.statusCode == 429 {
            if let quota = try? JSONDecoder().decode(QuotaErrorResponse.self, from: data) {
                // Fence the older GET at the response boundary, before control returns to a caller
                // that may present this already-published structured denial.
                supersedeSummaryRequestsForQuotaEvidence()
                publishQuotaExceeded(quota.error, observedAt: now())
                throw UsageError.quotaExceeded(quota.error)
            }
            throw UsageError.httpError(http.statusCode)
        }

        guard http.statusCode == 200 else {
            // The authenticated route rejects 4xx requests before committing a slot. Transport,
            // invalid-response, and 5xx outcomes are not authoritative: a proxy may have lost the
            // origin's committed 200. Freeze this account instead of issuing a second reservation.
            if !(400...499).contains(http.statusCode) {
                blockRetries(for: accountScope)
                throw UsageError.reservationOutcomeUnknown
            }
            throw UsageError.httpError(http.statusCode)
        }
        guard let acceptedReservation else {
            throw UsageError.reservationOutcomeUnknown
        }

        // HTTP 200 committed a reservation even if its response body is malformed or says ok:false.
        // Fence older GET snapshots before decoding so neither failure path can later restore the
        // pre-reservation balance. The durable handoff above remains the reservation safety fence.
        supersedeSummaryRequestsForQuotaEvidence()

        // A 200 is the endpoint's authoritative acceptance boundary. The transaction committed
        // before the route emitted it. Persist the reservation-to-chat.send handoff before
        // returning so cancellation or process death cannot lose the committed slot and charge a
        // retry. Only the exact gateway-accepted run clears this handoff.
        guard let consume = try? JSONDecoder().decode(UsageConsumeResponse.self, from: data) else {
            summaryIsStale = summary != nil
            return acceptedReservation
        }
        guard consume.ok else {
            summaryIsStale = summary != nil
            blockRetries(for: accountScope)
            throw UsageError.reservationOutcomeUnknown
        }
        if let current = summary {
            summary = UsageSummary(
                plan: current.plan,
                status: current.status,
                limits: current.limits,
                usage: consume.usage,
                remaining: consume.remaining
            )
            summaryObservedAt = now()
            scheduleQuotaReset()
        }
        return acceptedReservation
    }

    /// Retires only the reservation whose downstream gateway RPC returned an accepted run ID.
    func markReservedRequestAccepted(_ reservation: RequestSlotReservation) {
        retireDispatchHandoff(reservation)
    }

    /// Retires exactly one committed quota reservation when its owning request is cancelled before
    /// `chat.send` begins. The backend quota unit remains charged; this is a terminal local
    /// disposition that prevents the stale utterance from being retried or blocking a future turn.
    func markReservedRequestCancelledBeforeDispatch(_ reservation: RequestSlotReservation) {
        retireDispatchHandoff(reservation)
    }

    private func retireDispatchHandoff(_ reservation: RequestSlotReservation) {
        guard pendingDispatchReservations.removeValue(forKey: reservation.id) != nil else { return }
        Self.persistPendingDispatchReservations(pendingDispatchReservations, to: defaults)
    }
    
    func handleQuotaExceeded(_ error: QuotaExceededError) {
        // `consumeRequestSlot` publishes structured 429 evidence at its response boundary. Callers
        // only re-present that exact evidence after unwinding their catch path; they must never
        // publish an older error after a newer summary has already cleared it.
        guard quotaErrorMatches(error) else { return }
        quotaExceededStored = true
    }

    private func publishQuotaExceeded(_ error: QuotaExceededError, observedAt: Date) {
        quotaExceededStored = true
        quotaError = error
        quotaErrorObservedAt = observedAt
        if let current = summary {
            summary = UsageSummary(
                plan: current.plan,
                status: current.status,
                limits: current.limits,
                usage: current.usage,
                remaining: error.remaining
            )
            summaryObservedAt = observedAt
        }
        scheduleQuotaReset()
    }

    private func quotaErrorMatches(_ error: QuotaExceededError) -> Bool {
        guard let quotaError else { return false }
        return quotaError.type == error.type
            && quotaError.message == error.message
            && quotaError.remaining.day == error.remaining.day
            && quotaError.remaining.month == error.remaining.month
    }

    @discardableResult
    func presentCurrentQuotaDenial() -> Bool {
        guard QuotaPresentation.currentDenial(
            plan: summary?.plan,
            remaining: effectiveRemaining
        ) != nil else { return false }
        quotaExceededStored = true
        return true
    }
    
    func dismissQuotaError() {
        quotaExceededStored = false
        quotaError = nil
        quotaErrorObservedAt = nil
    }

    /// Remove plan and limit evidence made stale by a confirmed StoreKit change. Preserve the
    /// quota gate until a fresh backend summary proves the account has capacity again.
    func invalidateSummary() {
        summaryRequestGeneration &+= 1
        summary = nil
        summaryObservedAt = nil
        summaryLoadError = nil
        summaryIsStale = false
        scheduleQuotaReset()
        isLoading = false
    }

    func reset() {
        accountResetGeneration &+= 1
        summaryRequestGeneration &+= 1
        summary = nil
        summaryObservedAt = nil
        summaryLoadError = nil
        summaryIsStale = false
        quotaExceededStored = false
        quotaError = nil
        quotaErrorObservedAt = nil
        quotaResetTask?.cancel()
        quotaResetTask = nil
        isLoading = false
    }

    private func applyFreshSummary(_ freshSummary: UsageSummary) {
        summary = freshSummary
        summaryObservedAt = now()
        // This decoded response is newer canonical quota evidence than a retained 429. Clear the
        // stale payload so it cannot keep an upgraded account at zero through effectiveRemaining.
        quotaExceededStored = false
        quotaError = nil
        quotaErrorObservedAt = nil
        summaryLoadError = nil
        summaryIsStale = false
        scheduleQuotaReset()
    }

    private func supersedeSummaryRequestsForQuotaEvidence() {
        summaryRequestGeneration &+= 1
        isLoading = false
        // Consume responses validate only usage and remaining. Retained plan, status, and limits
        // keep their existing freshness, and an existing summary-load failure stays visible to
        // Billing. Malformed committed responses separately mark the whole retained payload stale.
    }

    private func currentRemaining(_ remaining: RemainingQuota?, observedAt: Date?) -> RemainingQuota? {
        guard let remaining else { return nil }
        guard remaining.day <= 0 || remaining.month <= 0 else { return remaining }
        return QuotaEvidenceFreshness.canBlockLocally(
            remaining: remaining,
            observedAt: observedAt,
            now: now()
        ) ? remaining : nil
    }

    private func scheduleQuotaReset() {
        quotaResetTask?.cancel()
        let currentDate = now()
        let candidates = [
            blockingResetDate(for: summary?.remaining, observedAt: summaryObservedAt, now: currentDate),
            blockingResetDate(for: quotaError?.remaining, observedAt: quotaErrorObservedAt, now: currentDate),
        ].compactMap { $0 }
        guard let nextReset = candidates.min() else {
            quotaResetTask = nil
            return
        }
        quotaResetTask = resetScheduler(nextReset) { [weak self] in
            guard let self else { return }
            self.quotaFreshnessRevision &+= 1
            self.scheduleQuotaReset()
        }
    }

    private func blockingResetDate(
        for remaining: RemainingQuota?,
        observedAt: Date?,
        now: Date
    ) -> Date? {
        guard let remaining, let observedAt,
              QuotaEvidenceFreshness.canBlockLocally(
                  remaining: remaining,
                  observedAt: observedAt,
                  now: now
              ) else { return nil }
        return QuotaEvidenceFreshness.resetDate(for: remaining, observedAt: observedAt)
    }

    private struct OperationAuthority {
        let generation: UInt64
        let request: AuthenticatedHttpClient.AccountRequestAuthority
    }

    private struct SummaryOperationAuthority {
        let accountGeneration: UInt64
        let requestGeneration: UInt64
        let request: AuthenticatedHttpClient.AccountRequestAuthority
    }

    private struct ReservationScope: Codable, Hashable {
        let accountID: String
        let normalizedBaseURL: String
    }

    private struct PersistedRetryBlockades: Codable {
        let version: Int
        let scopes: [ReservationScope]
    }

    private struct PersistedDispatchHandoff: Codable {
        let id: UUID
        let scope: ReservationScope
    }

    private struct PersistedDispatchHandoffs: Codable {
        let version: Int
        let reservations: [PersistedDispatchHandoff]
    }

    private struct LegacyPersistedDispatchHandoffs: Codable {
        let version: Int
        let scopes: [ReservationScope]
    }

    private func canCommit(_ authority: OperationAuthority) -> Bool {
        guard authority.generation == accountResetGeneration,
              let current = requestAuthorityProvider()
        else { return false }
        return current.accountID == authority.request.accountID
            && normalized(current.baseURL) == normalized(authority.request.baseURL)
    }

    private func canCommitSummary(_ authority: SummaryOperationAuthority) -> Bool {
        guard authority.accountGeneration == accountResetGeneration,
              authority.requestGeneration == summaryRequestGeneration,
              let current = requestAuthorityProvider()
        else { return false }
        return current.accountID == authority.request.accountID
            && normalized(current.baseURL) == normalized(authority.request.baseURL)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func reservationScope(
        for authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) -> ReservationScope {
        ReservationScope(
            accountID: authority.accountID,
            normalizedBaseURL: normalized(authority.baseURL)
        )
    }

    private func blockRetries(for scope: ReservationScope) {
        guard retryBlockedScopes.insert(scope).inserted else { return }
        Self.persistRetryBlockedScopes(retryBlockedScopes, to: defaults)
    }

    private func beginDispatchHandoff(for scope: ReservationScope) -> RequestSlotReservation {
        let reservation = RequestSlotReservation(id: UUID())
        pendingDispatchReservations[reservation.id] = scope
        Self.persistPendingDispatchReservations(pendingDispatchReservations, to: defaults)
        return reservation
    }

    private static func loadRetryBlockedScopes(from defaults: UserDefaults) -> Set<ReservationScope> {
        guard let data = defaults.data(forKey: retryBlockadesDefaultsKey),
              let ledger = try? JSONDecoder().decode(PersistedRetryBlockades.self, from: data),
              ledger.version == 1
        else { return [] }
        return Set(ledger.scopes)
    }

    private static func persistRetryBlockedScopes(
        _ scopes: Set<ReservationScope>,
        to defaults: UserDefaults
    ) {
        let ledger = PersistedRetryBlockades(
            version: 1,
            scopes: scopes.sorted {
                ($0.accountID, $0.normalizedBaseURL) < ($1.accountID, $1.normalizedBaseURL)
            }
        )
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: retryBlockadesDefaultsKey)
    }

    private static func loadPendingDispatchReservations(
        from defaults: UserDefaults
    ) -> [UUID: ReservationScope] {
        guard let data = defaults.data(forKey: pendingDispatchDefaultsKey) else { return [:] }
        if let ledger = try? JSONDecoder().decode(PersistedDispatchHandoffs.self, from: data),
           ledger.version == 2 {
            return Dictionary(uniqueKeysWithValues: ledger.reservations.map { ($0.id, $0.scope) })
        }
        // Development builds may have written the scope-only v1 format. Preserve every fence
        // while upgrading it to an opaque identity on the next write.
        if let legacy = try? JSONDecoder().decode(LegacyPersistedDispatchHandoffs.self, from: data),
           legacy.version == 1 {
            return Dictionary(uniqueKeysWithValues: legacy.scopes.map { (UUID(), $0) })
        }
        return [:]
    }

    private static func persistPendingDispatchReservations(
        _ reservations: [UUID: ReservationScope],
        to defaults: UserDefaults
    ) {
        let ledger = PersistedDispatchHandoffs(
            version: 2,
            reservations: reservations.map { PersistedDispatchHandoff(id: $0.key, scope: $0.value) }
                .sorted {
                    ($0.scope.accountID, $0.scope.normalizedBaseURL, $0.id.uuidString)
                        < ($1.scope.accountID, $1.scope.normalizedBaseURL, $1.id.uuidString)
            }
        )
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: pendingDispatchDefaultsKey)
    }

    private static func isDefinitelyUncommitted(_ error: Error) -> Bool {
        switch error {
        case AuthenticatedHttpError.notAuthenticated,
             AuthenticatedHttpError.unauthorized,
             AuthenticatedHttpError.invalidURL(_),
             UsageError.notAuthenticated,
             UsageError.invalidURL:
            true
        default:
            false
        }
    }
}

/// One instance belongs to one concrete text transport. It carries that transport's individual
/// opaque reservation from the quota hook to its acceptance callback without session-key lookup.
@MainActor
final class TextRequestSlotHandoff {
    private var reservation: UsageService.RequestSlotReservation?

    func install(_ reservation: UsageService.RequestSlotReservation) {
        self.reservation = reservation
    }

    func accept(using service: UsageService) {
        guard let reservation else { return }
        self.reservation = nil
        service.markReservedRequestAccepted(reservation)
    }
}

enum UsageError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case httpError(Int)
    case invalidURL
    case quotaExceeded(QuotaExceededError)
    case reservationOutcomeUnknown
    case reservationRetryBlocked
    case reservationInProgress
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated"
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code):
            return "Server error: \(code)"
        case .invalidURL:
            return "Invalid URL"
        case .quotaExceeded(let quota):
            return quota.message
        case .reservationOutcomeUnknown:
            return "The quota reservation result is unknown"
        case .reservationRetryBlocked:
            return "A previous quota reservation result is still unknown"
        case .reservationInProgress:
            return "A quota reservation is already in progress"
        }
    }
}

/// Classifies every failed quota reservation as a denied send. The backend is the quota
/// authority, so transport/auth/server failures cannot be treated as an implicit unlimited plan.
enum UsageSlotFailurePolicy {
    enum Decision {
        case quotaExceeded(QuotaExceededError)
        case verificationUnavailable
        case reservationRetryBlocked
    }

    static func classify(_ error: Error) -> Decision {
        if case let UsageError.quotaExceeded(quota) = error {
            return .quotaExceeded(quota)
        }
        if case UsageError.reservationOutcomeUnknown = error {
            return .reservationRetryBlocked
        }
        if case UsageError.reservationRetryBlocked = error {
            return .reservationRetryBlocked
        }
        if case UsageError.invalidResponse = error {
            return .reservationRetryBlocked
        }
        if case UsageError.reservationInProgress = error {
            return .verificationUnavailable
        }
        if case let UsageError.httpError(code) = error, code >= 500 {
            return .reservationRetryBlocked
        }
        return .verificationUnavailable
    }
}
