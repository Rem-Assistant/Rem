import StoreKit
import Foundation

struct AccountScopedRequestAuthority: Equatable {
    let generation: UInt64
    let accountID: String
}

struct AccountScopedRequestAuthorityTracker {
    private(set) var generation: UInt64 = 0

    func capture(accountID: String) -> AccountScopedRequestAuthority {
        AccountScopedRequestAuthority(generation: generation, accountID: accountID)
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func canCommit(
        _ authority: AccountScopedRequestAuthority,
        currentAccountID: String?
    ) -> Bool {
        authority.generation == generation && authority.accountID == currentAccountID
    }
}

struct IAPAccountOperationAuthority: Equatable {
    let lifecycle: AccountScopedRequestAuthority
    let request: AuthenticatedHttpClient.AccountRequestAuthority
    let revision: UInt64
}

struct IAPAccountRequestScope: Equatable {
    let lifecycle: AccountScopedRequestAuthority
    let request: AuthenticatedHttpClient.AccountRequestAuthority
}

struct IAPNativePurchaseContext: Equatable {
    let scope: IAPAccountRequestScope
    let appAccountToken: UUID
    let serviceAuthorityRevision: UInt64
}

enum IAPEntitlementMutationSource: String, Equatable, Sendable {
    case purchase
    case restore
    case updates
    case launch
    case reconcile
}

enum IAPEntitlementMutationFailureDisposition: Equatable, Sendable {
    case retryable
    case terminal
}

struct IAPEntitlementMutationFailure: LocalizedError, Equatable, Sendable {
    let message: String
    let disposition: IAPEntitlementMutationFailureDisposition

    init(
        message: String,
        disposition: IAPEntitlementMutationFailureDisposition = .retryable
    ) {
        self.message = message
        self.disposition = disposition
    }

    var errorDescription: String? { message }
}

enum IAPEntitlementMutationOutcome: Equatable, Sendable {
    case committed(revision: UInt64, source: IAPEntitlementMutationSource)
    case stale(revision: UInt64, source: IAPEntitlementMutationSource)
    case failed(revision: UInt64, source: IAPEntitlementMutationSource, failure: IAPEntitlementMutationFailure)
}

enum IAPUsageConvergenceOutcome: Equatable, Sendable {
    case converged(revision: UInt64)
    case stale(revision: UInt64)
    case failed(revision: UInt64, message: String)
}

enum IAPTransactionFinishPolicy {
    static func shouldFinish(after outcome: IAPEntitlementMutationOutcome) -> Bool {
        switch outcome {
        case .committed:
            return true
        case .failed(_, _, let failure):
            // Deterministic ownership/validation failures cannot be repaired by replaying the same
            // transaction. Transport, auth, 5xx, unknown 4xx, cancellation, and convergence
            // failures remain unfinished so StoreKit/current-entitlement recovery can try again.
            return failure.disposition == .terminal
        case .stale:
            return false
        }
    }
}

@MainActor
final class IAPEntitlementMutationCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var tracker = AccountScopedRequestAuthorityTracker()
    private var nextRevision: UInt64 = 0
    private var latestCommittedRevision: UInt64 = 0
    private var latestCommittedAuthority: IAPAccountOperationAuthority?
    private var isMutating = false
    private var waiters: [Waiter] = []

    var queuedMutationCount: Int { waiters.count }

    func capture(
        request: AuthenticatedHttpClient.AccountRequestAuthority
    ) -> IAPAccountOperationAuthority {
        allocateRevision(for: captureScope(request: request))
    }

    /// Captures account authority without ordering the mutation yet. Restore uses this before
    /// `AppStore.sync`, then allocates its revision after sync so any transaction updates emitted by
    /// that call are ordered first instead of incorrectly making restore stale.
    func captureScope(
        request: AuthenticatedHttpClient.AccountRequestAuthority
    ) -> IAPAccountRequestScope {
        IAPAccountRequestScope(
            lifecycle: tracker.capture(accountID: request.accountID),
            request: request
        )
    }

    func allocateRevision(for scope: IAPAccountRequestScope) -> IAPAccountOperationAuthority {
        nextRevision &+= 1
        return IAPAccountOperationAuthority(
            lifecycle: scope.lifecycle,
            request: scope.request,
            revision: nextRevision
        )
    }

    func invalidate() { tracker.invalidate() }

    func canCommit(_ authority: IAPAccountOperationAuthority, currentAccountID: String?) -> Bool {
        tracker.canCommit(authority.lifecycle, currentAccountID: currentAccountID)
    }

    func canCommit(_ scope: IAPAccountRequestScope, currentAccountID: String?) -> Bool {
        tracker.canCommit(scope.lifecycle, currentAccountID: currentAccountID)
    }

    /// A StoreKit update can reach the main actor around a restore or native purchase callback. If
    /// that newer mutation fully committed for the exact same account authority, it already
    /// established the entitlement + usage state the older reconciliation required.
    func hasNewerCommittedConvergence(
        than authority: IAPAccountOperationAuthority,
        currentAccountID: String?
    ) -> Bool {
        guard let latestCommittedAuthority else { return false }
        return latestCommittedAuthority.revision > authority.revision
            && latestCommittedAuthority.lifecycle == authority.lifecycle
            && latestCommittedAuthority.request == authority.request
            && canCommit(authority, currentAccountID: currentAccountID)
    }

    func satisfiesCanonicalConvergence(
        _ outcome: IAPEntitlementMutationOutcome,
        for authority: IAPAccountOperationAuthority,
        currentAccountID: String?
    ) -> Bool {
        switch outcome {
        case .committed(let revision, _):
            return revision == authority.revision
        case .stale:
            return hasNewerCommittedConvergence(
                than: authority,
                currentAccountID: currentAccountID
            )
        case .failed:
            return false
        }
    }

    func run(
        authority: IAPAccountOperationAuthority,
        source: IAPEntitlementMutationSource,
        currentAccountID: @MainActor () -> String?,
        operation: @MainActor () async throws -> Void
    ) async -> IAPEntitlementMutationOutcome {
        guard await acquireTurn() else {
            return .stale(revision: authority.revision, source: source)
        }
        defer { releaseTurn() }

        guard !Task.isCancelled,
              authority.revision > latestCommittedRevision,
              canCommit(authority, currentAccountID: currentAccountID()) else {
            return .stale(revision: authority.revision, source: source)
        }

        do {
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
            guard canCommit(authority, currentAccountID: currentAccountID()) else {
                return .stale(revision: authority.revision, source: source)
            }
            latestCommittedRevision = max(latestCommittedRevision, authority.revision)
            latestCommittedAuthority = authority
            return .committed(revision: authority.revision, source: source)
        } catch is CancellationError {
            return .stale(revision: authority.revision, source: source)
        } catch {
            guard canCommit(authority, currentAccountID: currentAccountID()) else {
                return .stale(revision: authority.revision, source: source)
            }
            return .failed(
                revision: authority.revision,
                source: source,
                failure: Self.failure(for: error)
            )
        }
    }

    private func acquireTurn() async -> Bool {
        if !isMutating, waiters.isEmpty {
            guard !Task.isCancelled else { return false }
            isMutating = true
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releaseTurn() {
        if waiters.isEmpty {
            isMutating = false
        } else {
            let waiter = waiters.removeFirst()
            // Ownership transfers directly while `isMutating` remains true, so a new caller cannot
            // leapfrog work that was already queued.
            waiter.continuation.resume(returning: true)
        }
    }

    private static func failure(for error: Error) -> IAPEntitlementMutationFailure {
        let disposition: IAPEntitlementMutationFailureDisposition
        if let iapError = error as? IAPError {
            switch iapError {
            case .ownershipConflict, .validationRejected:
                disposition = .terminal
            case .failedVerification, .productUnavailable, .notAuthenticated, .invalidURL,
                 .invalidResponse, .invalidAppAccountToken, .backendRequestFailed:
                disposition = .retryable
            }
        } else if let failure = error as? IAPEntitlementMutationFailure {
            disposition = failure.disposition
        } else {
            disposition = .retryable
        }
        return IAPEntitlementMutationFailure(
            message: error.localizedDescription,
            disposition: disposition
        )
    }
}

enum IAPBackendValidationPolicy {
    /// These codes are emitted only for deterministic request/transaction validation failures.
    /// Authentication, unknown client errors, Apple/backend availability, and 5xx responses remain
    /// retryable because replay can converge after credentials or service health recover.
    private static let terminalCodes: Set<String> = [
        "IAP_OWNERSHIP_CONFLICT",
        "IAP_TRANSACTION_ID_REQUIRED",
        "IAP_PRODUCT_ID_REQUIRED",
        "IAP_UNSUPPORTED_PRODUCT",
        "IAP_INVALID_SOURCE",
        "IAP_INVALID_SIGNED_PAYLOAD",
        "IAP_INVALID_TRANSACTION_ID",
        "IAP_TRANSACTION_INFO_MISSING",
        "IAP_ORIGINAL_TRANSACTION_ID_MISSING",
        "IAP_PRODUCT_MISMATCH",
        "IAP_APP_ACCOUNT_TOKEN_MISMATCH",
    ]

    static func isTerminal(statusCode: Int, code: String?) -> Bool {
        guard (400...499).contains(statusCode), statusCode != 401,
              let code else { return false }
        return terminalCodes.contains(code)
    }
}

struct IAPBackendRequestExecutor {
    typealias Request = @MainActor (
        _ path: String,
        _ method: String,
        _ body: Data?,
        _ authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) async throws -> (Data, HTTPURLResponse)

    let request: Request

    @MainActor
    func perform<Response: Decodable>(
        path: String,
        method: String,
        body: Data?,
        authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) async throws -> Response {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await request(path, method, body, authority)
        } catch is AuthenticatedHttpError {
            throw IAPError.notAuthenticated
        }

        guard (200...299).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data)
            if http.statusCode == 409, serverError?.code == "IAP_OWNERSHIP_CONFLICT" {
                throw IAPError.ownershipConflict
            }
            let message = serverError?.error ?? serverError?.details ?? "HTTP \(http.statusCode)"
            if IAPBackendValidationPolicy.isTerminal(
                statusCode: http.statusCode,
                code: serverError?.code
            ) {
                throw IAPError.validationRejected(
                    code: serverError?.code ?? "IAP_VALIDATION_ERROR",
                    message: message
                )
            }
            throw IAPError.backendRequestFailed(message)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw IAPError.invalidResponse
        }
    }
}

@Observable @MainActor
final class IAPService {
    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var backendEntitlement: BackendEntitlement?
    private(set) var isLoading = false
    private(set) var productLoadError: String?
    private(set) var lastSyncError: String?
    private(set) var lastMutationOutcome: IAPEntitlementMutationOutcome?
    private(set) var lastUsageConvergenceOutcome: IAPUsageConvergenceOutcome?
    private(set) var accountAuthorityRevision: UInt64 = 0
    var hasNativePurchasePending: Bool { !nativePurchaseCompletionContexts.isEmpty }

    private struct CachedAppAccountToken {
        let lifecycle: AccountScopedRequestAuthority
        let request: AuthenticatedHttpClient.AccountRequestAuthority
        let token: UUID
    }

    private var cachedAppAccountToken: CachedAppAccountToken?
    private var nativePurchaseCompletionContexts: [UUID: IAPNativePurchaseContext] = [:]
    private var latestPublishedMutationRevision: UInt64 = 0
    private var latestPublishedUsageRevision: UInt64 = 0
    private let mutationCoordinator = IAPEntitlementMutationCoordinator()
    private let captureRequestAuthority: @MainActor () -> AuthenticatedHttpClient.AccountRequestAuthority?
    private let backendRequestExecutor: IAPBackendRequestExecutor
    private let convergeUsage: @MainActor (UInt64) async -> IAPUsageConvergenceOutcome
    private let appStoreSync: @MainActor () async throws -> Void

    static let proProductID = "com.remapp.rem.pro.monthly"

    init(
        captureRequestAuthority: @escaping @MainActor () -> AuthenticatedHttpClient.AccountRequestAuthority? = {
            AuthenticatedHttpClient.captureAccountRequestAuthority()
        },
        authorizedRequest: @escaping IAPBackendRequestExecutor.Request = { path, method, body, authority in
            try await AuthenticatedHttpClient.request(
                path: path,
                method: method,
                body: body,
                authority: authority
            )
        },
        convergeUsage: @escaping @MainActor (UInt64) async -> IAPUsageConvergenceOutcome = {
            .stale(revision: $0)
        },
        appStoreSync: @escaping @MainActor () async throws -> Void = {
            try await AppStore.sync()
        },
        startAutomatically: Bool = true
    ) {
        self.captureRequestAuthority = captureRequestAuthority
        self.backendRequestExecutor = IAPBackendRequestExecutor(request: authorizedRequest)
        self.convergeUsage = convergeUsage
        self.appStoreSync = appStoreSync
        debugLog("init bundleId=\(Bundle.main.bundleIdentifier ?? "nil") apiBaseURL=\(AppConfig.apiBaseURL)")
        guard startAutomatically else { return }
        listenForTransactions()
        Task {
            await loadProducts()
            guard let authority = beginAccountRequestAuthority() else { return }
            await syncCurrentEntitlementsWithBackend(source: .launch, authority: authority)
        }
    }

    var isPro: Bool {
        guard let entitlement = backendEntitlement else { return false }
        return entitlement.plan == "pro" && entitlement.isActive
    }

    var proProduct: Product? {
        products.first { $0.id == Self.proProductID }
    }

    func purchasePro() async throws -> Transaction? {
        guard let authority = beginAccountRequestAuthority() else {
            throw IAPError.notAuthenticated
        }
        let capturedServiceRevision = accountAuthorityRevision
        if proProduct == nil {
            await loadProducts()
        }
        guard canCommit(authority) else { throw CancellationError() }
        guard let product = proProduct else {
            throw IAPError.productUnavailable
        }
        return try await purchase(
            product,
            authority: authority,
            serviceAuthorityRevision: capturedServiceRevision
        )
    }

    /// Show restore only when we have signals this user may already have a prior subscription.
    var shouldShowRestoreAction: Bool {
        if isPro { return true }
        if !purchasedProductIDs.isEmpty { return true }
        if backendEntitlement?.originalTransactionId != nil { return true }
        return false
    }

    func clearEntitlementState() {
        accountAuthorityRevision &+= 1
        mutationCoordinator.invalidate()
        backendEntitlement = nil
        cachedAppAccountToken = nil
        purchasedProductIDs = []
        lastSyncError = nil
        lastMutationOutcome = nil
        lastUsageConvergenceOutcome = nil
    }

    func refreshEntitlementState() async {
        guard let authority = beginAccountRequestAuthority() else {
            lastSyncError = IAPError.notAuthenticated.localizedDescription
            return
        }
        _ = await syncCurrentEntitlementsWithBackend(source: .launch, authority: authority)
    }

    /// StoreKit completion is only local purchase proof. This service is the canonical owner of the
    /// ordered backend entitlement + `/usage/summary` convergence; UI callers must not append a
    /// second fetch that can turn an already committed StoreKit mutation back into pending state.
    func reconcileStoreKitState() async throws {
        try await reconcileStoreKitState(afterCapturingAuthority: {})
    }

    /// The hook makes the StoreKit update/reconcile actor schedules deterministic in tests. In
    /// production it is empty; `Transaction.updates` may naturally commit while this task is
    /// suspended after capturing its exact account authority.
    func reconcileStoreKitState(
        afterCapturingAuthority: @MainActor () async -> Void
    ) async throws {
        guard let authority = beginAccountRequestAuthority() else {
            throw IAPError.notAuthenticated
        }
        await afterCapturingAuthority()
        let outcome = await syncCurrentEntitlementsWithBackend(source: .reconcile, authority: authority)
        try requireCanonicalConvergence(outcome, for: authority)
        guard backendEntitlement != nil else {
            throw IAPError.invalidResponse
        }
    }

    func loadProducts() async {
        debugLog("loadProducts start productId=\(Self.proProductID)")
        isLoading = true
        productLoadError = nil
        defer { isLoading = false }

        do {
            products = try await Product.products(for: [Self.proProductID])
            let found = products.map { "\($0.id):\($0.displayPrice)" }.joined(separator: ", ")
            debugLog("loadProducts success count=\(products.count) products=[\(found)]")
            if products.isEmpty {
                productLoadError = "Product unavailable from App Store"
                debugLog("loadProducts empty result from StoreKit")
            }
        } catch {
            products = []
            productLoadError = error.localizedDescription
            debugLog("loadProducts failed error=\(error.localizedDescription)")
        }
    }

    func purchase(
        _ product: Product,
        onStoreKitPurchaseCompleted: @escaping @MainActor () -> Void = {}
    ) async throws -> Transaction? {
        guard let authority = beginAccountRequestAuthority() else {
            throw IAPError.notAuthenticated
        }
        let capturedServiceRevision = accountAuthorityRevision
        return try await purchase(
            product,
            authority: authority,
            serviceAuthorityRevision: capturedServiceRevision,
            onStoreKitPurchaseCompleted: onStoreKitPurchaseCompleted
        )
    }

    /// Captures the exact Rem account authority and its backend-issued StoreKit token before the
    /// native subscription control can begin a purchase. The context is immutable across the
    /// StoreKit sheet's suspension, so a later account cannot claim the completion.
    func prepareNativePurchaseContext() async throws -> IAPNativePurchaseContext {
        guard let scope = beginAccountRequestScope() else {
            throw IAPError.notAuthenticated
        }
        let capturedServiceRevision = accountAuthorityRevision
        let authority = mutationCoordinator.allocateRevision(for: scope)
        let token = try await ensureAppAccountToken(authority: authority)
        guard canCommit(scope), capturedServiceRevision == accountAuthorityRevision else {
            throw CancellationError()
        }
        let context = IAPNativePurchaseContext(
            scope: scope,
            appAccountToken: token,
            serviceAuthorityRevision: capturedServiceRevision
        )
        return context
    }

    /// Claims the single native StoreKit purchase at the options-provider boundary. Keeping this
    /// exact context until completion prevents a later A -> B -> A sheet from resolving an older
    /// transaction merely because the account's stable appAccountToken compares equal again.
    func beginNativePurchase(_ context: IAPNativePurchaseContext) throws -> UUID {
        guard context.serviceAuthorityRevision == accountAuthorityRevision,
              mutationCoordinator.canCommit(
                context.scope,
                currentAccountID: currentAccountID()
              ) else {
            throw CancellationError()
        }
        if let active = nativePurchaseCompletionContexts[context.appAccountToken] {
            guard active == context else {
                throw IAPError.backendRequestFailed("Another App Store purchase is still pending.")
            }
            return active.appAccountToken
        }
        nativePurchaseCompletionContexts[context.appAccountToken] = context
        return context.appAccountToken
    }

    func endNativePurchaseWithoutTransaction(_ context: IAPNativePurchaseContext) {
        guard nativePurchaseCompletionContexts[context.appAccountToken] == context else { return }
        nativePurchaseCompletionContexts.removeValue(forKey: context.appAccountToken)
    }

    /// Completes a SubscriptionStoreView purchase under the authority captured before StoreKit
    /// started. Verification, app-account-token ownership, entitlement sync, and usage convergence
    /// all precede the shared finish decision.
    func completeNativePurchase(
        _ verification: VerificationResult<Transaction>
    ) async throws {
        let transaction: Transaction
        do {
            transaction = try Self.checkVerified(verification)
        } catch {
            throw error
        }
        guard let transactionToken = transaction.appAccountToken,
              let context = nativePurchaseCompletionContexts[transactionToken],
              context.appAccountToken == transactionToken else {
            throw IAPError.ownershipConflict
        }
        defer { nativePurchaseCompletionContexts.removeValue(forKey: transactionToken) }
        let (authority, outcome) = await processNativePurchaseMutation(
            transactionId: String(transaction.id),
            productId: transaction.productID,
            transactionAppAccountToken: transaction.appAccountToken,
            context: context
        )
        if IAPTransactionFinishPolicy.shouldFinish(after: outcome) {
            await transaction.finish()
        }
        try requireCanonicalConvergence(outcome, for: authority)
    }

    /// Deterministic StoreKit-view seam: allocate ordering only when the completion arrives, while
    /// retaining the immutable account scope and token captured before purchase presentation.
    func processNativePurchaseMutation(
        transactionId: String,
        productId: String,
        transactionAppAccountToken: UUID?,
        context: IAPNativePurchaseContext
    ) async -> (IAPAccountOperationAuthority, IAPEntitlementMutationOutcome) {
        let authority = mutationCoordinator.allocateRevision(for: context.scope)
        guard context.serviceAuthorityRevision == accountAuthorityRevision else {
            return (authority, .stale(revision: authority.revision, source: .purchase))
        }
        let outcome = await performTransactionMutation(
            transactionId: transactionId,
            productId: productId,
            transactionAppAccountToken: transactionAppAccountToken,
            source: .purchase,
            authority: authority,
            requiredAppAccountToken: context.appAccountToken
        )
        return (authority, outcome)
    }

    private func purchase(
        _ product: Product,
        authority: IAPAccountOperationAuthority,
        serviceAuthorityRevision: UInt64,
        onStoreKitPurchaseCompleted: @escaping @MainActor () -> Void = {}
    ) async throws -> Transaction? {
        let (result, accountToken) = try await runPurchaseAdmission(
            authority: authority,
            serviceAuthorityRevision: serviceAuthorityRevision
        ) { accountToken in
            self.debugLog("purchase start productId=\(product.id)")
            TelemetryService.shared.track(eventName: "iap_purchase_started", properties: [
                "product_id": product.id,
            ])
            self.debugLog("purchase using appAccountToken=\(accountToken.uuidString)")
            let result = try await product.purchase(options: [.appAccountToken(accountToken)])
            return (result, accountToken)
        }

        switch result {
        case .success(let verification):
            let transaction = try Self.checkVerified(verification)
            onStoreKitPurchaseCompleted()
            TelemetryService.shared.track(eventName: "iap_purchase_completed_local", properties: [
                "product_id": transaction.productID,
                "transaction_id": String(transaction.id),
            ])
            debugLog("purchase completed in StoreKit transactionId=\(transaction.id) productId=\(transaction.productID)")

            do {
                let outcome = await performTransactionMutation(
                    transactionId: String(transaction.id),
                    productId: transaction.productID,
                    transactionAppAccountToken: transaction.appAccountToken,
                    source: .purchase,
                    authority: authority,
                    requiredAppAccountToken: accountToken
                )
                if IAPTransactionFinishPolicy.shouldFinish(after: outcome) {
                    await transaction.finish()
                }
                guard serviceAuthorityRevision == accountAuthorityRevision else {
                    throw CancellationError()
                }
                try requireCanonicalConvergence(outcome, for: authority)
                debugLog("purchase sync success transactionId=\(transaction.id) productId=\(transaction.productID)")
                TelemetryService.shared.track(eventName: "iap_purchase_result", properties: [
                    "result": "success",
                    "product_id": transaction.productID,
                ])
                return transaction
            } catch {
                TelemetryService.shared.track(eventName: "iap_purchase_result", properties: [
                    "result": "failed",
                    "product_id": transaction.productID,
                    "error": error.localizedDescription,
                ])
                throw error
            }

        case .userCancelled:
            TelemetryService.shared.track(eventName: "iap_purchase_result", properties: [
                "result": "cancelled",
                "product_id": product.id,
            ])
            return nil

        case .pending:
            TelemetryService.shared.track(eventName: "iap_purchase_result", properties: [
                "result": "pending",
                "product_id": product.id,
            ])
            return nil

        @unknown default:
            TelemetryService.shared.track(eventName: "iap_purchase_result", properties: [
                "result": "unknown",
                "product_id": product.id,
            ])
            return nil
        }
    }

    /// Testable admission boundary for every app-owned StoreKit purchase. The start closure is
    /// unreachable unless the backend token still belongs to the exact captured account authority.
    func runPurchaseAdmission<Result>(
        startPurchase: @escaping @MainActor (UUID) async throws -> Result
    ) async throws -> Result {
        guard let authority = beginAccountRequestAuthority() else {
            throw IAPError.notAuthenticated
        }
        let capturedServiceRevision = accountAuthorityRevision
        return try await runPurchaseAdmission(
            authority: authority,
            serviceAuthorityRevision: capturedServiceRevision,
            startPurchase: startPurchase
        )
    }

    private func runPurchaseAdmission<Result>(
        authority: IAPAccountOperationAuthority,
        serviceAuthorityRevision: UInt64,
        startPurchase: @escaping @MainActor (UUID) async throws -> Result
    ) async throws -> Result {
        guard serviceAuthorityRevision == accountAuthorityRevision,
              canCommit(authority) else { throw CancellationError() }
        let accountToken = try await ensureAppAccountToken(authority: authority)
        guard serviceAuthorityRevision == accountAuthorityRevision,
              canCommit(authority) else { throw CancellationError() }
        return try await startPurchase(accountToken)
    }

    func restorePurchases(
        onStoreKitSyncCompleted: @escaping @MainActor () -> Void = {}
    ) async throws {
        // Capture immutable account credentials before StoreKit may suspend, but do not allocate a
        // mutation revision yet: `AppStore.sync` can emit `Transaction.updates`, and those updates
        // must commit before the restore scan that observes their resulting entitlement set.
        guard let scope = beginAccountRequestScope() else {
            throw IAPError.notAuthenticated
        }
        debugLog("restorePurchases start")
        TelemetryService.shared.track(eventName: "iap_restore_started")
        try await appStoreSync()
        onStoreKitSyncCompleted()
        guard canCommit(scope) else { throw CancellationError() }
        let authority = mutationCoordinator.allocateRevision(for: scope)
        debugLog("restorePurchases AppStore.sync completed")
        let outcome = await syncCurrentEntitlementsWithBackend(source: .restore, authority: authority)
        try requireCanonicalConvergence(outcome, for: authority)
        debugLog("restorePurchases done isPro=\(isPro) plan=\(backendEntitlement?.plan ?? "nil") status=\(backendEntitlement?.status ?? "nil") lastSyncError=\(lastSyncError ?? "none")")
        TelemetryService.shared.track(eventName: "iap_restore_result", properties: [
            "result": isPro ? "success" : "no_active_entitlement",
        ])
    }

    private func updatePurchasedProductsLocally(
        authority: IAPAccountOperationAuthority
    ) async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try Self.checkVerified(result)
                purchased.insert(transaction.productID)
            } catch {
                debugLog("updatePurchasedProductsLocally verify failed error=\(error.localizedDescription)")
            }
        }

        guard canCommit(authority) else { return }
        purchasedProductIDs = purchased
    }

    private func syncCurrentEntitlementsWithBackend(
        source: IAPEntitlementMutationSource,
        authority: IAPAccountOperationAuthority
    ) async -> IAPEntitlementMutationOutcome {
        debugLog("syncCurrentEntitlements start source=\(source.rawValue) hasBackendToken=\(hasBackendToken)")
        return await runMutation(
            source: source,
            authority: authority,
            operation: { [weak self] in
                guard let self else { throw CancellationError() }
                await self.updatePurchasedProductsLocally(authority: authority)
                guard self.canCommit(authority) else { throw CancellationError() }
                let expectedToken = try await ensureAppAccountToken(authority: authority)
                var syncedCount = 0

                for await result in Transaction.currentEntitlements {
                    guard self.canCommit(authority) else { throw CancellationError() }
                    let transaction = try Self.checkVerified(result)
                    guard transaction.appAccountToken == expectedToken else {
                        throw IAPError.ownershipConflict
                    }
                    self.debugLog("syncCurrentEntitlements found transaction id=\(transaction.id) product=\(transaction.productID)")
                    try await self.syncTransactionWithBackend(
                        transactionId: String(transaction.id),
                        productId: transaction.productID,
                        source: source,
                        authority: authority
                    )
                    syncedCount += 1
                }

                guard self.canCommit(authority) else { throw CancellationError() }
                let entitlement = try await self.fetchEntitlementFromBackend(authority: authority)
                guard self.canCommit(authority) else { throw CancellationError() }
                self.backendEntitlement = entitlement
                self.debugLog("syncCurrentEntitlements complete source=\(source.rawValue) syncedCount=\(syncedCount) plan=\(self.backendEntitlement?.plan ?? "nil") status=\(self.backendEntitlement?.status ?? "nil")")
            }
        )
    }

    private func listenForTransactions() {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try Self.checkVerified(result)
                    await self.handleTransactionUpdate(transaction)
                } catch {
                    await self.debugLog("Transaction.updates verification failed error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func handleTransactionUpdate(_ transaction: Transaction) async {
        let outcome = await processTransactionMutation(
            transactionId: String(transaction.id),
            productId: transaction.productID,
            transactionAppAccountToken: transaction.appAccountToken,
            requireTransactionAppAccountToken: true,
            source: .updates
        )
        switch outcome {
        case .committed:
            debugLog("transaction update sync success transactionId=\(transaction.id) productId=\(transaction.productID)")
        case .stale:
            debugLog("transaction update retired as stale transactionId=\(transaction.id)")
        case .failed(_, _, let failure):
            debugLog("transaction update sync failed transactionId=\(transaction.id) error=\(failure.message)")
        }

        if IAPTransactionFinishPolicy.shouldFinish(after: outcome) {
            await transaction.finish()
        } else {
            debugLog("transaction update left unfinished for recovery transactionId=\(transaction.id)")
        }
    }

    /// Shared entry point for StoreKit callbacks and deterministic lifecycle tests. Capturing the
    /// account here prevents a deferred transaction from borrowing a later account after an actor hop.
    func processTransactionMutation(
        transactionId: String,
        productId: String,
        transactionAppAccountToken: UUID? = nil,
        requireTransactionAppAccountToken: Bool = false,
        source: IAPEntitlementMutationSource
    ) async -> IAPEntitlementMutationOutcome {
        guard let authority = beginAccountRequestAuthority() else {
            return .failed(
                revision: 0,
                source: source,
                failure: IAPEntitlementMutationFailure(
                    message: IAPError.notAuthenticated.localizedDescription
                )
            )
        }
        return await performTransactionMutation(
            transactionId: transactionId,
            productId: productId,
            transactionAppAccountToken: transactionAppAccountToken,
            source: source,
            authority: authority,
            requiredAppAccountToken: nil,
            requireTransactionAppAccountToken: requireTransactionAppAccountToken
        )
    }

    private func ensureAppAccountToken(
        authority: IAPAccountOperationAuthority
    ) async throws -> UUID {
        guard canCommit(authority) else { throw CancellationError() }
        if let cached = cachedAppAccountToken,
           cached.lifecycle == authority.lifecycle,
           cached.request == authority.request {
            debugLog("ensureAppAccountToken using cached token=\(cached.token.uuidString)")
            return cached.token
        }

        let context = try await fetchContextFromBackend(authority: authority)
        guard canCommit(authority) else { throw CancellationError() }
        guard let token = UUID(uuidString: context.appAccountToken) else {
            throw IAPError.invalidAppAccountToken
        }

        cachedAppAccountToken = CachedAppAccountToken(
            lifecycle: authority.lifecycle,
            request: authority.request,
            token: token
        )
        debugLog("ensureAppAccountToken fetched token=\(token.uuidString) productIds=\(context.productIds.joined(separator: ",")) plan=\(context.entitlement.plan) status=\(context.entitlement.status)")
        return token
    }

    private func fetchContextFromBackend(
        authority: IAPAccountOperationAuthority
    ) async throws -> ContextResponse {
        debugLog("fetchContextFromBackend request")
        let context: ContextResponse = try await performAuthorizedRequest(
            path: "/api/v1/iap/context",
            authority: authority
        )
        debugLog("fetchContextFromBackend response token=\(context.appAccountToken) plan=\(context.entitlement.plan) status=\(context.entitlement.status)")
        return context
    }

    private func fetchEntitlementFromBackend(
        authority: IAPAccountOperationAuthority
    ) async throws -> BackendEntitlement {
        debugLog("fetchEntitlementFromBackend request")
        let entitlement: BackendEntitlement = try await performAuthorizedRequest(
            path: "/api/v1/iap/entitlement",
            authority: authority
        )
        debugLog("fetchEntitlementFromBackend response plan=\(entitlement.plan) status=\(entitlement.status) isActive=\(entitlement.isActive) env=\(entitlement.environment ?? "nil")")
        return entitlement
    }

    private func syncTransactionWithBackend(
        transactionId: String,
        productId: String,
        source: IAPEntitlementMutationSource,
        authority: IAPAccountOperationAuthority
    ) async throws {
        guard canCommit(authority) else { throw CancellationError() }
        debugLog("syncTransactionWithBackend request transactionId=\(transactionId) productId=\(productId) source=\(source.rawValue)")
        TelemetryService.shared.track(eventName: "iap_transaction_sync_requested", properties: [
            "transaction_id": transactionId,
            "product_id": productId,
            "source": source.rawValue,
        ])

        let body = TransactionSyncRequest(
            transactionId: transactionId,
            productId: productId,
            source: source.rawValue
        )

        do {
            let entitlement: BackendEntitlement = try await performAuthorizedRequest(
                path: "/api/v1/iap/transaction-sync",
                method: "POST",
                body: body,
                authority: authority
            )
            guard canCommit(authority) else { throw CancellationError() }
            backendEntitlement = entitlement
            lastSyncError = nil
            debugLog("syncTransactionWithBackend success source=\(source.rawValue) plan=\(entitlement.plan) status=\(entitlement.status) isActive=\(entitlement.isActive)")

            TelemetryService.shared.track(eventName: "iap_transaction_sync_result", properties: [
                "result": "success",
                "source": source.rawValue,
                "product_id": productId,
                "status": entitlement.status,
                "plan": entitlement.plan,
            ])
        } catch {
            debugLog("syncTransactionWithBackend failed source=\(source.rawValue) error=\(error.localizedDescription)")
            TelemetryService.shared.track(eventName: "iap_transaction_sync_result", properties: [
                "result": "failed",
                "source": source.rawValue,
                "product_id": productId,
                "error": error.localizedDescription,
            ])
            throw error
        }
    }

    private func performAuthorizedRequest<Response: Decodable>(
        path: String,
        method: String = "GET",
        authority: IAPAccountOperationAuthority
    ) async throws -> Response {
        try await performAuthorizedRequest(
            path: path,
            method: method,
            encodedBody: nil,
            authority: authority
        )
    }

    private func performAuthorizedRequest<Response: Decodable, RequestBody: Encodable>(
        path: String,
        method: String = "GET",
        body: RequestBody,
        authority: IAPAccountOperationAuthority
    ) async throws -> Response {
        let encodedBody = try JSONEncoder().encode(body)
        return try await performAuthorizedRequest(
            path: path,
            method: method,
            encodedBody: encodedBody,
            authority: authority
        )
    }

    private func performAuthorizedRequest<Response: Decodable>(
        path: String,
        method: String,
        encodedBody: Data?,
        authority: IAPAccountOperationAuthority
    ) async throws -> Response {
        debugLog("http request method=\(method) path=\(path)")

        do {
            let response: Response = try await backendRequestExecutor.perform(
                path: path,
                method: method,
                body: encodedBody,
                authority: authority.request
            )
            debugLog("http response decoded method=\(method) path=\(path)")
            return response
        } catch {
            debugLog("http request failed method=\(method) path=\(path) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func debugLog(_ message: String) {
#if DEBUG
        print("[IAP-DEBUG] \(message)")
#endif
    }

    private func performTransactionMutation(
        transactionId: String,
        productId: String,
        transactionAppAccountToken: UUID?,
        source: IAPEntitlementMutationSource,
        authority: IAPAccountOperationAuthority,
        requiredAppAccountToken: UUID?,
        requireTransactionAppAccountToken: Bool = false
    ) async -> IAPEntitlementMutationOutcome {
        await runMutation(source: source, authority: authority) { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.canCommit(authority) else { throw CancellationError() }
            let expectedToken = try await self.ensureAppAccountToken(authority: authority)
            guard self.canCommit(authority) else { throw CancellationError() }
            if let requiredAppAccountToken,
               expectedToken != requiredAppAccountToken {
                throw IAPError.ownershipConflict
            }
            if let transactionAppAccountToken,
               transactionAppAccountToken != expectedToken {
                throw IAPError.ownershipConflict
            }
            if requiredAppAccountToken != nil,
               transactionAppAccountToken == nil {
                throw IAPError.ownershipConflict
            }
            if requireTransactionAppAccountToken,
               transactionAppAccountToken == nil {
                throw IAPError.ownershipConflict
            }
            self.purchasedProductIDs.insert(productId)
            try await self.syncTransactionWithBackend(
                transactionId: transactionId,
                productId: productId,
                source: source,
                authority: authority
            )
        }
    }

    private func runMutation(
        source: IAPEntitlementMutationSource,
        authority: IAPAccountOperationAuthority,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> IAPEntitlementMutationOutcome {
        var usageOutcome: IAPUsageConvergenceOutcome?
        let outcome = await mutationCoordinator.run(
            authority: authority,
            source: source,
            currentAccountID: { [weak self] in self?.currentAccountID() },
            operation: { [weak self] in
                guard let self else { throw CancellationError() }
                try await operation()
                guard self.canCommit(authority) else { throw CancellationError() }

                let convergence = await self.convergeUsage(authority.revision)
                guard self.canCommit(authority) else { throw CancellationError() }
                usageOutcome = convergence
                switch convergence {
                case .converged(let revision) where revision == authority.revision:
                    break
                case .stale:
                    throw CancellationError()
                case .failed(_, let message):
                    throw IAPEntitlementMutationFailure(message: message)
                case .converged:
                    usageOutcome = .stale(revision: authority.revision)
                    throw CancellationError()
                }
            }
        )

        guard canCommit(authority) else {
            return .stale(revision: authority.revision, source: source)
        }
        if authority.revision >= latestPublishedMutationRevision {
            latestPublishedMutationRevision = authority.revision
            lastMutationOutcome = outcome
        }
        if let usageOutcome, authority.revision >= latestPublishedUsageRevision {
            latestPublishedUsageRevision = authority.revision
            lastUsageConvergenceOutcome = usageOutcome
        }
        switch outcome {
        case .committed:
            lastSyncError = nil
        case .stale:
            break
        case .failed(_, _, let failure):
            lastSyncError = failure.message
        }
        return outcome
    }

    private func requireCommitted(_ outcome: IAPEntitlementMutationOutcome) throws {
        switch outcome {
        case .committed:
            break
        case .stale:
            throw CancellationError()
        case .failed(_, _, let failure):
            throw failure
        }
    }

    private func requireCanonicalConvergence(
        _ outcome: IAPEntitlementMutationOutcome,
        for authority: IAPAccountOperationAuthority
    ) throws {
        if mutationCoordinator.satisfiesCanonicalConvergence(
            outcome,
            for: authority,
            currentAccountID: currentAccountID()
        ) {
            return
        }
        try requireCommitted(outcome)
    }

    private func beginAccountRequestAuthority() -> IAPAccountOperationAuthority? {
        guard let scope = beginAccountRequestScope() else { return nil }
        return mutationCoordinator.allocateRevision(for: scope)
    }

    private func beginAccountRequestScope() -> IAPAccountRequestScope? {
        guard let request = captureRequestAuthority() else { return nil }
        return mutationCoordinator.captureScope(request: request)
    }

    private func canCommit(_ authority: IAPAccountOperationAuthority) -> Bool {
        mutationCoordinator.canCommit(
            authority,
            currentAccountID: currentAccountID()
        )
    }

    private func canCommit(_ scope: IAPAccountRequestScope) -> Bool {
        mutationCoordinator.canCommit(
            scope,
            currentAccountID: currentAccountID()
        )
    }

    private func currentAccountID() -> String? {
        captureRequestAuthority()?.accountID
    }

    private var hasBackendToken: Bool {
        captureRequestAuthority() != nil
    }

    private nonisolated static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw IAPError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}

private struct TransactionSyncRequest: Codable {
    let transactionId: String
    let productId: String
    let source: String
}

private struct ContextResponse: Codable {
    let appAccountToken: String
    let productIds: [String]
    let entitlement: BackendEntitlement
}

struct BackendEntitlement: Codable {
    let plan: String
    let isActive: Bool
    let status: String
    let productId: String?
    let expiresAt: String?
    let originalTransactionId: String?
    let environment: String?
    let updatedAt: String?
}

struct ServerErrorResponse: Codable {
    let error: String?
    let code: String?
    let details: String?
}

enum IAPError: Error, LocalizedError {
    case failedVerification
    case productUnavailable
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case invalidAppAccountToken
    case ownershipConflict
    case validationRejected(code: String, message: String)
    case backendRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "Failed to verify purchase with Apple"
        case .productUnavailable:
            return "Subscription product is not available right now"
        case .notAuthenticated:
            return "Please sign in to continue"
        case .invalidURL:
            return "Invalid billing server URL"
        case .invalidResponse:
            return "Invalid response from billing server"
        case .invalidAppAccountToken:
            return "Invalid app account token from server"
        case .ownershipConflict:
            return "This subscription belongs to a different Rem account"
        case .validationRejected(_, let message):
            return message
        case .backendRequestFailed(let message):
            return message
        }
    }
}
