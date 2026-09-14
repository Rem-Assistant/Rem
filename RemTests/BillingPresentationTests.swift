import Foundation
import Observation
import Testing
@testable import Rem

@MainActor
struct BillingPresentationTests {
    private enum ProbeError: Error, Equatable {
        case entitlement
    }

    @Test func knownPlansUseProductNamesWithoutLeakingUnknownBackendValues() {
        #expect(BillingPlanPresentation.planName("free") == "Free")
        #expect(BillingPlanPresentation.planName("PRO") == "Pro")
        #expect(BillingPlanPresentation.planName("future_internal_tier") == "Current plan")
    }

    @Test func activePlanNeedsNoWarningButNonActiveStatesStayVisible() {
        #expect(BillingPlanPresentation.statusLabel(plan: "pro", status: "active") == nil)
        #expect(BillingPlanPresentation.statusLabel(plan: "pro", status: " ACTIVE ") == nil)
        #expect(BillingPlanPresentation.statusLabel(
            plan: "pro",
            status: "past_due"
        ) == "Subscription payment issue")
        #expect(BillingPlanPresentation.statusLabel(plan: "free", status: "cancelled") == nil)
        #expect(BillingPlanPresentation.statusLabel(
            plan: "pro",
            status: "cancelled"
        ) == "No active subscription")
        #expect(BillingPlanPresentation.statusLabel(
            plan: "pro",
            status: "paused"
        ) == "Needs attention")
    }

    @Test func proBenefitsDescribeOnlyCurrentSubscriptionEntitlements() {
        let copy = SubscriptionBenefit.pro.map(\.title)

        #expect(copy.contains("Higher daily and monthly AI request limits"))
        #expect(copy.allSatisfy { !$0.localizedCaseInsensitiveContains("token") })
        #expect(copy.allSatisfy { !$0.localizedCaseInsensitiveContains("credit") })
        #expect(copy.allSatisfy { !$0.localizedCaseInsensitiveContains("calendar") })
        #expect(copy.allSatisfy { !$0.localizedCaseInsensitiveContains("voice") })
        #expect(copy.allSatisfy { !$0.localizedCaseInsensitiveContains("premium model") })
    }

    @Test func quotaPresentationPreservesLimitScopeAndSubscriptionTruth() {
        let freeDaily = QuotaPresentation.make(
            plan: "free",
            remaining: RemainingQuota(day: 0, month: 30)
        )
        #expect(freeDaily.title == "Daily request limit reached")
        #expect(freeDaily.primaryAction == .upgradeToPro)
        #expect(freeDaily.bannerText.contains("tomorrow"))

        let proMonthly = QuotaPresentation.make(
            plan: "pro",
            remaining: RemainingQuota(day: 0, month: 0)
        )
        #expect(proMonthly.title == "Monthly request limit reached")
        #expect(proMonthly.primaryAction == .manageSubscription)
        #expect(!proMonthly.bannerText.localizedCaseInsensitiveContains("upgrade"))

        let unknownPlan = QuotaPresentation.make(
            plan: nil,
            remaining: RemainingQuota(day: 0, month: 20)
        )
        #expect(unknownPlan.primaryAction == .refreshBilling)
        #expect(!unknownPlan.bannerText.localizedCaseInsensitiveContains("subscription"))

        let proDaily = QuotaPresentation.currentDenial(
            plan: "pro",
            remaining: RemainingQuota(day: 0, month: 20)
        )
        #expect(proDaily?.scope == .daily)
        let freeMonthly = QuotaPresentation.currentDenial(
            plan: "free",
            remaining: RemainingQuota(day: 5, month: 0)
        )
        #expect(freeMonthly?.scope == .monthly)
        #expect(QuotaPresentation.currentDenial(
            plan: "free",
            remaining: RemainingQuota(day: 1, month: 1)
        ) == nil)
    }

    @Test func cachedQuotaDenialExpiresAtItsUTCResetBoundary() {
        let dailyObservedAt = Date(timeIntervalSince1970: 1_786_406_340) // 2026-08-10 23:59 UTC
        let daily = RemainingQuota(day: 0, month: 20)
        #expect(QuotaEvidenceFreshness.canBlockLocally(
            remaining: daily,
            observedAt: dailyObservedAt,
            now: dailyObservedAt.addingTimeInterval(30)
        ))
        #expect(!QuotaEvidenceFreshness.canBlockLocally(
            remaining: daily,
            observedAt: dailyObservedAt,
            now: dailyObservedAt.addingTimeInterval(120)
        ))

        let monthlyObservedAt = Date(timeIntervalSince1970: 1_788_220_740) // 2026-08-31 23:59 UTC
        let monthly = RemainingQuota(day: 0, month: 0)
        #expect(QuotaEvidenceFreshness.canBlockLocally(
            remaining: monthly,
            observedAt: monthlyObservedAt,
            now: monthlyObservedAt.addingTimeInterval(30)
        ))
        #expect(!QuotaEvidenceFreshness.canBlockLocally(
            remaining: monthly,
            observedAt: monthlyObservedAt,
            now: monthlyObservedAt.addingTimeInterval(120)
        ))
    }

    @Test func firstPostResetTextSendReachesBackendWithoutRestampingSummaryZero() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_786_406_340)
        var now = observedAt
        var consumeRequestCount = 0
        let scheduler = QuotaResetSchedulerProbe()
        let summary = Self.summary(remainingDay: 0, remainingMonth: 20)
        let responseData = try JSONEncoder().encode(summary)
        let consumeData = try JSONEncoder().encode(UsageConsumeResponse(
            ok: true,
            usage: UsageStats(day: 11, month: 21),
            remaining: RemainingQuota(day: 9, month: 79)
        ))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-reset") },
            consumeRequester: { _ in
                consumeRequestCount += 1
                return (consumeData, Self.httpResponse(statusCode: 200))
            },
            summaryRequester: { _ in (responseData, Self.httpResponse(statusCode: 200)) },
            defaults: Self.testDefaults(),
            now: { now },
            resetScheduler: scheduler.schedule
        )
        try await service.fetchSummary()
        #expect(service.presentCurrentQuotaDenial())
        #expect(!service.hasQuotaForUI)
        #expect(service.quotaExceeded)
        #expect(scheduler.resetDate == observedAt.addingTimeInterval(60))

        let observation = ObservationInvalidationProbe()
        withObservationTracking {
            _ = service.hasQuotaForUI
            _ = service.quotaExceeded
        } onChange: {
            Task { @MainActor in observation.didInvalidate = true }
        }

        now = observedAt.addingTimeInterval(120)
        scheduler.fire()
        await Task.yield()
        #expect(observation.didInvalidate)
        #expect(service.hasQuotaForUI)
        #expect(!service.quotaExceeded)
        #expect(service.effectiveRemaining == nil)

        // This is the exact production text-send preflight used by RemChatView. Expired evidence
        // must return false so the authoritative reservation request below is attempted.
        #expect(!service.presentCurrentQuotaDenial())
        #expect(!service.quotaExceeded)
        #expect(service.effectiveRemaining == nil)
        _ = try await service.consumeRequestSlot()
        #expect(consumeRequestCount == 1)
        #expect(service.effectiveRemaining?.day == 9)
        #expect(service.effectiveRemaining?.month == 79)
    }

    @Test func billingSummaryPresentationNeverPublishesCachedDataWhileRefreshingOrFailed() {
        #expect(BillingSummaryPresentationState.resolve(
            hasSummary: true,
            isLoading: true,
            hasError: false
        ) == .loading)
        #expect(BillingSummaryPresentationState.resolve(
            hasSummary: true,
            isLoading: false,
            hasError: true
        ) == .unavailable)
        #expect(BillingSummaryPresentationState.resolve(
            hasSummary: true,
            isLoading: false,
            hasError: false
        ) == .available)
    }

    @Test func monthlyExhaustionBlocksUsageEvenWhenDailyQuotaRemains() async throws {
        let summaryData = try JSONEncoder().encode(Self.summary(remainingDay: 5, remainingMonth: 0))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "monthly-exhaustion") },
            summaryRequester: { _ in (summaryData, Self.httpResponse(statusCode: 200)) },
            defaults: Self.testDefaults()
        )
        try await service.fetchSummary()
        #expect(service.presentCurrentQuotaDenial())

        #expect(!service.hasQuotaForUI)
        #expect(service.quotaPresentation.scope == .monthly)
        #expect(service.quotaPresentation.primaryAction == .manageSubscription)
    }

    @Test func freshSummaryRetiresStaleQuotaErrorThroughProductionFetchPath() async throws {
        let freshSummary = Self.summary(remainingDay: 12, remainingMonth: 120)
        let responseData = try JSONEncoder().encode(freshSummary)
        let quota = QuotaExceededError(
            type: "quota_exceeded",
            message: "No requests remaining",
            remaining: RemainingQuota(day: 0, month: 0)
        )
        let quotaData = try JSONEncoder().encode(QuotaErrorResponse(error: quota))
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://api.example.test/api/v1/usage/summary")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in (quotaData, Self.httpResponse(statusCode: 429)) },
            summaryRequester: { _ in (responseData, response) },
            defaults: Self.testDefaults()
        )
        do {
            _ = try await service.consumeRequestSlot()
            Issue.record("Expected quotaExceeded")
        } catch UsageError.quotaExceeded(let error) {
            service.handleQuotaExceeded(error)
        }

        try await service.fetchSummary()

        #expect(service.summary?.remaining.day == 12)
        #expect(service.effectiveRemaining?.day == 12)
        #expect(service.hasQuotaForUI)
        #expect(!service.quotaExceeded)
        #expect(service.quotaError == nil)
    }

    @Test func delayedAccountAUsageResponseCannotPublishAfterResetToAccountB() async throws {
        let authorityState = MutableAuthorityState(Self.authority(accountID: "account-a"))
        let probe = DelayedUsageRequestProbe()
        let service = UsageService(
            requestAuthorityProvider: { authorityState.value },
            summaryRequester: { authority in
                try await probe.response(path: "/api/v1/usage/summary/\(authority.accountID)")
            },
            defaults: Self.testDefaults()
        )

        let accountARequest = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary/account-a")

        service.reset()
        authorityState.value = Self.authority(accountID: "account-b")
        let accountBRequest = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary/account-b")
        probe.succeed(
            path: "/api/v1/usage/summary/account-b",
            value: Self.summary(remainingDay: 9, remainingMonth: 90),
            statusCode: 200
        )
        try await accountBRequest.value

        probe.succeed(
            path: "/api/v1/usage/summary/account-a",
            value: Self.summary(remainingDay: 1, remainingMonth: 10),
            statusCode: 200
        )
        try await accountARequest.value

        #expect(service.summary?.remaining.day == 9)
        #expect(service.summary?.remaining.month == 90)
        #expect(!service.isLoading)
        #expect(service.summaryLoadError == nil)
        #expect(!service.summaryIsStale)
        #expect(!service.quotaExceeded)
    }

    @Test func supersededSummaryFailureCannotClearOrPublishOverNewerRefresh() async throws {
        let probe = DelayedUsageRequestProbe()
        var requestCount = 0
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-overlap") },
            summaryRequester: { _ in
                requestCount += 1
                return try await probe.response(path: "/api/v1/usage/summary/\(requestCount)")
            },
            defaults: Self.testDefaults()
        )

        let older = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary/1")
        let newer = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary/2")

        probe.succeed(
            path: "/api/v1/usage/summary/2",
            value: Self.summary(remainingDay: 14, remainingMonth: 140),
            statusCode: 200
        )
        try await newer.value
        probe.fail(path: "/api/v1/usage/summary/1", error: ProbeError.entitlement)
        try await older.value

        #expect(service.summary?.remaining.day == 14)
        #expect(service.summary?.remaining.month == 140)
        #expect(!service.isLoading)
        #expect(service.summaryLoadError == nil)
        #expect(!service.summaryIsStale)
    }

    @Test func overlappingSummaryCannotSuppressConsumeQuotaResponse() async throws {
        let probe = DelayedUsageRequestProbe()
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in try await probe.response(path: "/api/v1/usage/consume") },
            summaryRequester: { _ in try await probe.response(path: "/api/v1/usage/summary") },
            defaults: Self.testDefaults()
        )
        let consume = Task { try await service.consumeRequestSlot() }
        await probe.waitUntilStarted(path: "/api/v1/usage/consume")
        let summary = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary")

        probe.succeed(
            path: "/api/v1/usage/summary",
            value: Self.summary(remainingDay: 10, remainingMonth: 100),
            statusCode: 200
        )
        try await summary.value
        let quota = QuotaErrorResponse(error: QuotaExceededError(
            type: "quota_exceeded",
            message: "No requests remaining",
            remaining: RemainingQuota(day: 0, month: 0)
        ))
        probe.succeed(path: "/api/v1/usage/consume", value: quota, statusCode: 429)

        do {
            try await consume.value
            Issue.record("Expected quotaExceeded")
        } catch UsageError.quotaExceeded(let error) {
            service.handleQuotaExceeded(error)
        }
        #expect(service.quotaExceeded)
        #expect(service.effectiveRemaining?.day == 0)
    }

    @Test func overlappingSummaryCannotSuppressSuccessfulConsumeResponse() async throws {
        let probe = DelayedUsageRequestProbe()
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-a") },
            consumeRequester: { _ in try await probe.response(path: "/api/v1/usage/consume") },
            summaryRequester: { _ in try await probe.response(path: "/api/v1/usage/summary") },
            defaults: Self.testDefaults()
        )
        let consume = Task { try await service.consumeRequestSlot() }
        await probe.waitUntilStarted(path: "/api/v1/usage/consume")
        let summary = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary")

        probe.succeed(
            path: "/api/v1/usage/summary",
            value: Self.summary(remainingDay: 10, remainingMonth: 100),
            statusCode: 200
        )
        try await summary.value
        probe.succeed(
            path: "/api/v1/usage/consume",
            value: UsageConsumeResponse(
                ok: true,
                usage: UsageStats(day: 11, month: 101),
                remaining: RemainingQuota(day: 9, month: 99)
            ),
            statusCode: 200
        )
        try await consume.value

        #expect(service.summary?.usage.day == 11)
        #expect(service.summary?.remaining.day == 9)
        #expect(!service.summaryIsStale)
        #expect(service.summaryLoadError == nil)
    }

    @Test func staleSummaryCompletionCannotOverwriteNewerConsumeSuccess() async throws {
        let probe = DelayedUsageRequestProbe()
        var summaryRequestCount = 0
        let initialSummary = Self.summary(remainingDay: 10, remainingMonth: 100)
        let initialData = try JSONEncoder().encode(initialSummary)
        let consumeData = try JSONEncoder().encode(UsageConsumeResponse(
            ok: true,
            usage: UsageStats(day: 11, month: 101),
            remaining: RemainingQuota(day: 9, month: 99)
        ))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-ordering-success") },
            consumeRequester: { _ in (consumeData, Self.httpResponse(statusCode: 200)) },
            summaryRequester: { _ in
                summaryRequestCount += 1
                if summaryRequestCount == 1 {
                    return (initialData, Self.httpResponse(statusCode: 200))
                }
                return try await probe.response(path: "/api/v1/usage/summary")
            },
            defaults: Self.testDefaults()
        )
        try await service.fetchSummary()

        let staleSummary = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary")
        let reservation = try await service.consumeRequestSlot()
        service.markReservedRequestAccepted(reservation)
        #expect(service.summary?.remaining.day == 9)
        #expect(!service.isLoading)
        #expect(service.summaryIsStale)
        #expect(service.summaryLoadError == nil)

        probe.succeed(
            path: "/api/v1/usage/summary",
            value: Self.summary(remainingDay: 7, remainingMonth: 77),
            statusCode: 200
        )
        try await staleSummary.value

        #expect(service.summary?.remaining.day == 9)
        #expect(service.summary?.remaining.month == 99)
        #expect(service.summary?.plan == "pro")
        #expect(service.summaryIsStale)
        #expect(service.summaryLoadError == nil)
        #expect(service.hasQuotaForUI)
        #expect(BillingSummaryPresentationState.resolve(
            hasSummary: service.summary != nil,
            isLoading: service.isLoading,
            hasError: service.summaryLoadError != nil || service.summaryIsStale
        ) == .unavailable)
        #expect(service.quotaPresentation.primaryAction == .refreshBilling)
    }

    @Test func consumeBalanceUpdatePreservesFailedSummaryMetadataState() async throws {
        var summaryRequestCount = 0
        let initial = Self.summary(remainingDay: 10, remainingMonth: 100)
        let initialData = try JSONEncoder().encode(initial)
        let consumeData = try JSONEncoder().encode(UsageConsumeResponse(
            ok: true,
            usage: UsageStats(day: 11, month: 101),
            remaining: RemainingQuota(day: 9, month: 99)
        ))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-failed-metadata") },
            consumeRequester: { _ in (consumeData, Self.httpResponse(statusCode: 200)) },
            summaryRequester: { _ in
                summaryRequestCount += 1
                if summaryRequestCount == 1 {
                    return (initialData, Self.httpResponse(statusCode: 200))
                }
                return (Data(), Self.httpResponse(statusCode: 503))
            },
            defaults: Self.testDefaults()
        )
        try await service.fetchSummary()
        do {
            try await service.fetchSummary()
            Issue.record("Expected summary refresh failure")
        } catch UsageError.httpError(let statusCode) {
            #expect(statusCode == 503)
        } catch {
            Issue.record("Unexpected summary refresh error: \(error)")
        }
        let metadataError = try #require(service.summaryLoadError)
        #expect(service.summaryIsStale)

        let reservation = try await service.consumeRequestSlot()
        service.markReservedRequestAccepted(reservation)

        #expect(service.summary?.usage.day == 11)
        #expect(service.summary?.remaining.day == 9)
        #expect(service.summary?.plan == initial.plan)
        #expect(service.summary?.status == initial.status)
        #expect(service.summary?.limits.requestsPerDay == initial.limits.requestsPerDay)
        #expect(service.summaryIsStale)
        #expect(service.summaryLoadError == metadataError)
        #expect(BillingSummaryPresentationState.resolve(
            hasSummary: service.summary != nil,
            isLoading: service.isLoading,
            hasError: service.summaryLoadError != nil || service.summaryIsStale
        ) == .unavailable)
        #expect(service.quotaPresentation.primaryAction == .refreshBilling)
    }

    @Test func staleSummaryCompletionCannotOverwriteNewerQuotaError() async throws {
        let probe = DelayedUsageRequestProbe()
        var summaryRequestCount = 0
        let initialSummary = Self.summary(remainingDay: 10, remainingMonth: 100)
        let initialData = try JSONEncoder().encode(initialSummary)
        let quota = QuotaErrorResponse(error: QuotaExceededError(
            type: "quota_exceeded",
            message: "Monthly request limit reached",
            remaining: RemainingQuota(day: 8, month: 0)
        ))
        let quotaData = try JSONEncoder().encode(quota)
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-ordering-429") },
            consumeRequester: { _ in (quotaData, Self.httpResponse(statusCode: 429)) },
            summaryRequester: { _ in
                summaryRequestCount += 1
                if summaryRequestCount == 1 {
                    return (initialData, Self.httpResponse(statusCode: 200))
                }
                return try await probe.response(path: "/api/v1/usage/summary")
            },
            defaults: Self.testDefaults()
        )
        try await service.fetchSummary()

        let staleSummary = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary")
        do {
            _ = try await service.consumeRequestSlot()
            Issue.record("Expected quotaExceeded")
        } catch UsageError.quotaExceeded(let error) {
            service.handleQuotaExceeded(error)
        }
        #expect(service.quotaExceeded)
        #expect(!service.hasQuotaForUI)
        #expect(!service.isLoading)

        probe.succeed(
            path: "/api/v1/usage/summary",
            value: Self.summary(remainingDay: 7, remainingMonth: 77),
            statusCode: 200
        )
        try await staleSummary.value

        #expect(service.summary?.remaining.day == 8)
        #expect(service.summary?.remaining.month == 0)
        #expect(service.quotaError?.remaining.month == 0)
        #expect(service.quotaExceeded)
        #expect(!service.hasQuotaForUI)
        #expect(service.summaryIsStale)
        #expect(service.quotaPresentation.primaryAction == .refreshBilling)
    }

    @Test func callerQuotaPresentationCannotRetireRefreshStartedAfterAuthoritative429() async throws {
        let probe = DelayedUsageRequestProbe()
        var summaryRequestCount = 0
        let quota = QuotaExceededError(
            type: "quota_exceeded",
            message: "Daily request limit reached",
            remaining: RemainingQuota(day: 0, month: 80)
        )
        let quotaData = try JSONEncoder().encode(QuotaErrorResponse(error: quota))
        let initialData = try JSONEncoder().encode(Self.summary(remainingDay: 10, remainingMonth: 100))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-429-refresh") },
            consumeRequester: { _ in (quotaData, Self.httpResponse(statusCode: 429)) },
            summaryRequester: { _ in
                summaryRequestCount += 1
                if summaryRequestCount == 1 {
                    return (initialData, Self.httpResponse(statusCode: 200))
                }
                return try await probe.response(path: "/api/v1/usage/summary")
            },
            defaults: Self.testDefaults()
        )
        try await service.fetchSummary()

        let publishedQuota: QuotaExceededError
        do {
            _ = try await service.consumeRequestSlot()
            Issue.record("Expected quotaExceeded")
            return
        } catch UsageError.quotaExceeded(let error) {
            publishedQuota = error
        }

        let newerRefresh = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary")
        service.handleQuotaExceeded(publishedQuota)
        #expect(service.isLoading)

        probe.succeed(
            path: "/api/v1/usage/summary",
            value: Self.summary(remainingDay: 15, remainingMonth: 150),
            statusCode: 200
        )
        try await newerRefresh.value

        #expect(service.summary?.remaining.day == 15)
        #expect(service.hasQuotaForUI)
        #expect(!service.quotaExceeded)
        #expect(service.summaryLoadError == nil)
        #expect(!service.summaryIsStale)

        // The caller's catch path can resume after the newer refresh. Re-presenting its old 429
        // must not restore the cleared denial or mutate the newly committed summary.
        service.handleQuotaExceeded(publishedQuota)
        #expect(service.summary?.remaining.day == 15)
        #expect(service.hasQuotaForUI)
        #expect(!service.quotaExceeded)
    }

    @Test func malformedCommittedConsumeFencesOlderSummaryBeforeDecode() async throws {
        let probe = DelayedUsageRequestProbe()
        var summaryRequestCount = 0
        let initialData = try JSONEncoder().encode(Self.summary(remainingDay: 10, remainingMonth: 100))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-malformed-200") },
            consumeRequester: { _ in
                (Data("not-json".utf8), Self.httpResponse(statusCode: 200))
            },
            summaryRequester: { _ in
                summaryRequestCount += 1
                if summaryRequestCount == 1 {
                    return (initialData, Self.httpResponse(statusCode: 200))
                }
                return try await probe.response(path: "/api/v1/usage/summary")
            },
            defaults: Self.testDefaults()
        )
        try await service.fetchSummary()

        let staleSummary = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary")
        let reservation = try await service.consumeRequestSlot()
        #expect(service.pendingDispatchReservationCount == 1)
        #expect(!service.isLoading)
        #expect(service.summaryIsStale)

        probe.succeed(
            path: "/api/v1/usage/summary",
            value: Self.summary(remainingDay: 7, remainingMonth: 70),
            statusCode: 200
        )
        try await staleSummary.value

        #expect(service.summary?.remaining.day == 10)
        #expect(service.summary?.remaining.month == 100)
        #expect(service.summaryIsStale)
        service.markReservedRequestAccepted(reservation)
        #expect(service.pendingDispatchReservationCount == 0)
    }

    @Test func rejectedCommittedConsumeFencesOlderSummaryAndPreservesRetryBlockade() async throws {
        let probe = DelayedUsageRequestProbe()
        var summaryRequestCount = 0
        let initialData = try JSONEncoder().encode(Self.summary(remainingDay: 10, remainingMonth: 100))
        let rejectedData = try JSONEncoder().encode(UsageConsumeResponse(
            ok: false,
            usage: UsageStats(day: 11, month: 101),
            remaining: RemainingQuota(day: 9, month: 99)
        ))
        let service = UsageService(
            requestAuthorityProvider: { Self.authority(accountID: "account-rejected-200") },
            consumeRequester: { _ in (rejectedData, Self.httpResponse(statusCode: 200)) },
            summaryRequester: { _ in
                summaryRequestCount += 1
                if summaryRequestCount == 1 {
                    return (initialData, Self.httpResponse(statusCode: 200))
                }
                return try await probe.response(path: "/api/v1/usage/summary")
            },
            defaults: Self.testDefaults()
        )
        try await service.fetchSummary()

        let staleSummary = Task { try await service.fetchSummary() }
        await probe.waitUntilStarted(path: "/api/v1/usage/summary")
        do {
            _ = try await service.consumeRequestSlot()
            Issue.record("Expected reservationOutcomeUnknown")
        } catch UsageError.reservationOutcomeUnknown {
            // A committed but rejected response stays durably blocked from replay.
        }
        #expect(service.pendingDispatchReservationCount == 1)
        #expect(service.reservationRetryBlocked)
        #expect(!service.isLoading)
        #expect(service.summaryIsStale)

        probe.succeed(
            path: "/api/v1/usage/summary",
            value: Self.summary(remainingDay: 7, remainingMonth: 70),
            statusCode: 200
        )
        try await staleSummary.value

        #expect(service.summary?.remaining.day == 10)
        #expect(service.summary?.remaining.month == 100)
        #expect(service.summaryIsStale)
    }

    @Test func sameAccountResetInvalidatesCapturedIAPAuthority() {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")
        let operation = coordinator.capture(request: request)

        coordinator.invalidate()

        #expect(!coordinator.canCommit(operation, currentAccountID: "account-a"))
    }

    @Test func restoreRevisionAllocatedAfterSyncOrdersTransactionUpdateFirst() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")
        let restoreScope = coordinator.captureScope(request: request)

        // AppStore.sync may deliver this update before it returns to restore.
        let update = coordinator.capture(request: request)
        let updateOutcome = await coordinator.run(
            authority: update,
            source: .updates,
            currentAccountID: { "account-a" },
            operation: {}
        )

        // Restore retains its pre-sync account scope, but receives the next mutation revision.
        let restore = coordinator.allocateRevision(for: restoreScope)
        let restoreOutcome = await coordinator.run(
            authority: restore,
            source: .restore,
            currentAccountID: { "account-a" },
            operation: {}
        )

        #expect(update.revision == 1)
        #expect(restore.revision == 2)
        #expect(updateOutcome == .committed(revision: 1, source: .updates))
        #expect(restoreOutcome == .committed(revision: 2, source: .restore))
    }

    @Test func preSyncRestoreScopeCannotBorrowReplacementAccountAfterSync() {
        let coordinator = IAPEntitlementMutationCoordinator()
        let scope = coordinator.captureScope(request: Self.authority(accountID: "account-a"))

        coordinator.invalidate()
        let restore = coordinator.allocateRevision(for: scope)

        #expect(!coordinator.canCommit(scope, currentAccountID: "account-b"))
        #expect(!coordinator.canCommit(restore, currentAccountID: "account-b"))
        #expect(restore.request.accountID == "account-a")
    }

    @Test func restoreAcceptsNewerCommittedSameAuthorityWhenUpdateArrivesAfterAllocation() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")
        let restoreScope = coordinator.captureScope(request: request)
        let restore = coordinator.allocateRevision(for: restoreScope)

        // The update was emitted by sync, but actor scheduling captures it just after restore.
        let update = coordinator.capture(request: request)
        let updateOutcome = await coordinator.run(
            authority: update,
            source: .updates,
            currentAccountID: { "account-a" },
            operation: {}
        )
        let restoreOutcome = await coordinator.run(
            authority: restore,
            source: .restore,
            currentAccountID: { "account-a" },
            operation: { Issue.record("Superseded restore unexpectedly executed") }
        )

        #expect(updateOutcome == .committed(revision: 2, source: .updates))
        #expect(restoreOutcome == .stale(revision: 1, source: .restore))
        #expect(coordinator.hasNewerCommittedConvergence(
            than: restore,
            currentAccountID: "account-a"
        ))
    }

    @Test func restoreDoesNotAcceptNewerCommitFromDifferentAuthority() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let restore = coordinator.capture(request: Self.authority(
            accountID: "account-a",
            token: "token-a"
        ))
        let update = coordinator.capture(request: Self.authority(
            accountID: "account-a",
            token: "token-b"
        ))

        _ = await coordinator.run(
            authority: update,
            source: .updates,
            currentAccountID: { "account-a" },
            operation: {}
        )

        #expect(!coordinator.hasNewerCommittedConvergence(
            than: restore,
            currentAccountID: "account-a"
        ))
    }

    @Test func queuedIAPMutationIsSerializedAndRetiresAfterAccountReplacement() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let accountA = Self.authority(accountID: "account-a")
        let currentAccount = MutableStringState("account-a")
        let blocker = MutationBlocker()
        let first = coordinator.capture(request: accountA)
        let firstTask = Task {
            await coordinator.run(
                authority: first,
                source: .purchase,
                currentAccountID: { currentAccount.value },
                operation: { await blocker.wait() }
            )
        }
        await blocker.waitUntilStarted()

        let queued = coordinator.capture(request: accountA)
        let waiter = Task {
            await coordinator.run(
                authority: queued,
                source: .updates,
                currentAccountID: { currentAccount.value },
                operation: { Issue.record("Stale queued mutation unexpectedly executed") }
            )
        }
        await Task.yield()
        coordinator.invalidate()
        currentAccount.value = "account-b"
        blocker.release()

        #expect(await firstTask.value == .stale(revision: 1, source: .purchase))
        #expect(await waiter.value == .stale(revision: 2, source: .updates))
    }

    @Test func coordinatorReportsTypedMutationFailure() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let authority = coordinator.capture(request: Self.authority(accountID: "account-a"))

        let outcome = await coordinator.run(
            authority: authority,
            source: .restore,
            currentAccountID: { "account-a" },
            operation: { throw ProbeError.entitlement }
        )

        guard case .failed(let revision, let source, let failure) = outcome else {
            Issue.record("Expected typed failure, got \(outcome)")
            return
        }
        #expect(revision == 1)
        #expect(source == .restore)
        #expect(!failure.message.isEmpty)
        #expect(failure.disposition == .retryable)
    }

    @Test func queuedIAPMutationsRunInDeterministicFIFOOrder() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")
        let blocker = MutationBlocker()
        let executionOrder = MutableUInt64List()
        let first = coordinator.capture(request: request)
        let second = coordinator.capture(request: request)
        let third = coordinator.capture(request: request)

        let firstTask = Task {
            await coordinator.run(
                authority: first,
                source: .launch,
                currentAccountID: { "account-a" },
                operation: {
                    executionOrder.values.append(first.revision)
                    await blocker.wait()
                }
            )
        }
        await blocker.waitUntilStarted()

        let secondTask = Task {
            await coordinator.run(
                authority: second,
                source: .restore,
                currentAccountID: { "account-a" },
                operation: { executionOrder.values.append(second.revision) }
            )
        }
        while coordinator.queuedMutationCount != 1 { await Task.yield() }
        let thirdTask = Task {
            await coordinator.run(
                authority: third,
                source: .updates,
                currentAccountID: { "account-a" },
                operation: { executionOrder.values.append(third.revision) }
            )
        }
        while coordinator.queuedMutationCount != 2 { await Task.yield() }

        blocker.release()

        #expect(await firstTask.value == .committed(revision: 1, source: .launch))
        #expect(await secondTask.value == .committed(revision: 2, source: .restore))
        #expect(await thirdTask.value == .committed(revision: 3, source: .updates))
        #expect(executionOrder.values == [1, 2, 3])
    }

    @Test func failedNewerRevisionDoesNotSuppressOlderRecoverableMutation() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")
        let older = coordinator.capture(request: request)
        let newer = coordinator.capture(request: request)
        let executed = MutableUInt64List()

        let newerOutcome = await coordinator.run(
            authority: newer,
            source: .updates,
            currentAccountID: { "account-a" },
            operation: { throw ProbeError.entitlement }
        )
        let olderOutcome = await coordinator.run(
            authority: older,
            source: .reconcile,
            currentAccountID: { "account-a" },
            operation: { executed.values.append(older.revision) }
        )

        guard case .failed(let revision, let source, _) = newerOutcome else {
            Issue.record("Expected newer mutation failure, got \(newerOutcome)")
            return
        }
        #expect(revision == 2)
        #expect(source == .updates)
        #expect(olderOutcome == .committed(revision: 1, source: .reconcile))
        #expect(executed.values == [1])
    }

    @Test func canceledQueuedMutationNeverExecutes() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")
        let blocker = MutationBlocker()
        let executed = MutableUInt64List()
        let first = coordinator.capture(request: request)
        let canceled = coordinator.capture(request: request)

        let firstTask = Task {
            await coordinator.run(
                authority: first,
                source: .launch,
                currentAccountID: { "account-a" },
                operation: { await blocker.wait() }
            )
        }
        await blocker.waitUntilStarted()
        let canceledTask = Task {
            await coordinator.run(
                authority: canceled,
                source: .restore,
                currentAccountID: { "account-a" },
                operation: { executed.values.append(canceled.revision) }
            )
        }
        while coordinator.queuedMutationCount != 1 { await Task.yield() }

        canceledTask.cancel()
        #expect(await canceledTask.value == .stale(revision: 2, source: .restore))
        #expect(executed.values.isEmpty)
        #expect(coordinator.queuedMutationCount == 0)
        blocker.release()
        #expect(await firstTask.value == .committed(revision: 1, source: .launch))
    }

    @Test func newerFinishedRevisionRetiresOlderDelayedMutation() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")
        let older = coordinator.capture(request: request)
        let newer = coordinator.capture(request: request)

        let newerOutcome = await coordinator.run(
            authority: newer,
            source: .updates,
            currentAccountID: { "account-a" },
            operation: {}
        )
        let olderOutcome = await coordinator.run(
            authority: older,
            source: .purchase,
            currentAccountID: { "account-a" },
            operation: { Issue.record("Superseded mutation unexpectedly executed") }
        )

        #expect(newerOutcome == .committed(revision: 2, source: .updates))
        #expect(olderOutcome == .stale(revision: 1, source: .purchase))
    }

    @Test func deferredTransactionUpdateCommitsThenTriggersGlobalUsageConvergence() async throws {
        let convergenceRevisions = MutableUInt64List()
        let service = IAPService(
            captureRequestAuthority: { Self.authority(accountID: "account-a") },
            authorizedRequest: Self.iapRequest,
            convergeUsage: { revision in
                convergenceRevisions.values.append(revision)
                return .converged(revision: revision)
            },
            startAutomatically: false
        )

        let outcome = await service.processTransactionMutation(
            transactionId: "transaction-1",
            productId: IAPService.proProductID,
            source: .updates
        )

        #expect(outcome == .committed(revision: 1, source: .updates))
        #expect(service.lastMutationOutcome == outcome)
        #expect(service.lastUsageConvergenceOutcome == .converged(revision: 1))
        #expect(convergenceRevisions.values == [1])
        #expect(service.backendEntitlement?.plan == "pro")
        #expect(service.purchasedProductIDs == Set([IAPService.proProductID]))
    }

    @Test func purchaseSheetDismissesAfterNewerExactAuthorityConvergence() async throws {
        let service = IAPService(
            captureRequestAuthority: { Self.authority(accountID: "account-a", token: "token-a") },
            authorizedRequest: Self.iapRequest,
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )
        var updateOutcome: IAPEntitlementMutationOutcome?
        var didDismiss = false

        try await AppleSubscriptionPurchaseLifecycle.run(
            reconcileCanonicalState: {
                try await service.reconcileStoreKitState(afterCapturingAuthority: {
                    updateOutcome = await service.processTransactionMutation(
                        transactionId: "purchase-sheet-update",
                        productId: IAPService.proProductID,
                        source: .updates
                    )
                })
            },
            onConverged: { didDismiss = true }
        )

        #expect(updateOutcome == .committed(revision: 2, source: .updates))
        #expect(service.lastMutationOutcome == updateOutcome)
        #expect(service.lastUsageConvergenceOutcome == .converged(revision: 2))
        #expect(service.backendEntitlement?.plan == "pro")
        #expect(didDismiss)
    }

    @Test func purchaseSheetDismissesWhenItsOwnReconciliationCommitsFirst() async throws {
        let service = IAPService(
            captureRequestAuthority: { Self.authority(accountID: "account-a") },
            authorizedRequest: Self.iapRequest,
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )
        var didDismiss = false

        try await AppleSubscriptionPurchaseLifecycle.run(
            reconcileCanonicalState: service.reconcileStoreKitState,
            onConverged: { didDismiss = true }
        )

        #expect(service.lastMutationOutcome == .committed(revision: 1, source: .reconcile))
        #expect(service.lastUsageConvergenceOutcome == .converged(revision: 1))
        #expect(didDismiss)
    }

    @Test func purchaseSheetRejectsNewerDifferentAuthorityConvergence() async {
        let requestAuthority = MutableAuthorityState(Self.authority(
            accountID: "account-a",
            token: "token-a"
        ))
        let service = IAPService(
            captureRequestAuthority: { requestAuthority.value },
            authorizedRequest: Self.iapRequest,
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )
        var didDismiss = false

        do {
            try await AppleSubscriptionPurchaseLifecycle.run(
                reconcileCanonicalState: {
                    try await service.reconcileStoreKitState(afterCapturingAuthority: {
                        requestAuthority.value = Self.authority(
                            accountID: "account-a",
                            token: "token-b"
                        )
                        _ = await service.processTransactionMutation(
                            transactionId: "different-authority-update",
                            productId: IAPService.proProductID,
                            source: .updates
                        )
                    })
                },
                onConverged: { didDismiss = true }
            )
            Issue.record("Expected exact-authority reconciliation failure")
        } catch is CancellationError {
            // A newer token authority cannot satisfy the captured purchase callback.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!didDismiss)
    }

    @Test func purchaseSheetRejectsIncompleteEntitlementUsageConvergence() async {
        let service = IAPService(
            captureRequestAuthority: { Self.authority(accountID: "account-a") },
            authorizedRequest: Self.iapRequest,
            convergeUsage: { revision in
                .failed(revision: revision, message: "usage unavailable")
            },
            startAutomatically: false
        )
        var didDismiss = false

        do {
            try await AppleSubscriptionPurchaseLifecycle.run(
                reconcileCanonicalState: {
                    try await service.reconcileStoreKitState(afterCapturingAuthority: {
                        _ = await service.processTransactionMutation(
                            transactionId: "incomplete-update",
                            productId: IAPService.proProductID,
                            source: .updates
                        )
                    })
                },
                onConverged: { didDismiss = true }
            )
            Issue.record("Expected incomplete convergence failure")
        } catch {
            #expect(error.localizedDescription == "usage unavailable")
        }

        #expect(!didDismiss)
        #expect(service.lastSyncError == "usage unavailable")
    }

    @Test func nativePurchaseCompletionCannotCrossAccountReplacement() async throws {
        let authorityState = MutableAuthorityState(Self.authority(accountID: "account-a", token: "token-a"))
        var transactionSyncCount = 0
        let service = IAPService(
            captureRequestAuthority: { authorityState.value },
            authorizedRequest: { path, _, _, authority in
                if path == "/api/v1/iap/transaction-sync" {
                    transactionSyncCount += 1
                }
                return try Self.iapResponse(path: path, authority: authority)
            },
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )
        let context = try await service.prepareNativePurchaseContext()

        authorityState.value = Self.authority(accountID: "account-b", token: "token-b")
        service.clearEntitlementState()
        let (_, outcome) = await service.processNativePurchaseMutation(
            transactionId: "native-a-after-b",
            productId: IAPService.proProductID,
            transactionAppAccountToken: context.appAccountToken,
            context: context
        )

        #expect(outcome == .stale(revision: 2, source: .purchase))
        #expect(!IAPTransactionFinishPolicy.shouldFinish(after: outcome))
        #expect(transactionSyncCount == 0)
        #expect(service.backendEntitlement == nil)
    }

    @Test func nativePurchaseRequiresCapturedTokenBeforeCommitting() async throws {
        let service = IAPService(
            captureRequestAuthority: { Self.authority(accountID: "account-a", token: "token-a") },
            authorizedRequest: { path, _, _, authority in
                try Self.iapResponse(path: path, authority: authority)
            },
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )
        let context = try await service.prepareNativePurchaseContext()

        let (_, matching) = await service.processNativePurchaseMutation(
            transactionId: "native-matching",
            productId: IAPService.proProductID,
            transactionAppAccountToken: context.appAccountToken,
            context: context
        )

        #expect(matching == .committed(revision: 2, source: .purchase))
        #expect(IAPTransactionFinishPolicy.shouldFinish(after: matching))
        #expect(service.backendEntitlement?.plan == "pro")
    }

    @Test func nativePurchaseABAWithSameStableTokenCannotReplacePendingAuthority() async throws {
        let authorityState = MutableAuthorityState(Self.authority(accountID: "account-a", token: "token-a1"))
        let service = IAPService(
            captureRequestAuthority: { authorityState.value },
            authorizedRequest: { path, _, _, authority in
                try Self.iapResponse(path: path, authority: authority)
            },
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )
        let firstA = try await service.prepareNativePurchaseContext()
        _ = try service.beginNativePurchase(firstA)

        authorityState.value = Self.authority(accountID: "account-b", token: "token-b")
        service.clearEntitlementState()
        authorityState.value = Self.authority(accountID: "account-a", token: "token-a2")
        service.clearEntitlementState()
        let replacementA = try await service.prepareNativePurchaseContext()

        do {
            _ = try service.beginNativePurchase(replacementA)
            Issue.record("Replacement A unexpectedly replaced the first lifecycle's pending purchase")
        } catch {
            #expect(error.localizedDescription == "Another App Store purchase is still pending.")
        }
        let (_, oldOutcome) = await service.processNativePurchaseMutation(
            transactionId: "native-old-a",
            productId: IAPService.proProductID,
            transactionAppAccountToken: firstA.appAccountToken,
            context: firstA
        )
        #expect(oldOutcome == .stale(revision: 3, source: .purchase))
        #expect(!IAPTransactionFinishPolicy.shouldFinish(after: oldOutcome))
    }

    @Test func deferredUpdateTokenFromPriorAccountCannotBeClaimedByReplacement() async {
        let authorityState = MutableAuthorityState(Self.authority(accountID: "account-b", token: "token-b"))
        let tokenA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        var transactionSyncCount = 0
        let service = IAPService(
            captureRequestAuthority: { authorityState.value },
            authorizedRequest: { path, _, _, authority in
                if path == "/api/v1/iap/transaction-sync" {
                    transactionSyncCount += 1
                }
                return try Self.iapResponse(path: path, authority: authority)
            },
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )

        let outcome = await service.processTransactionMutation(
            transactionId: "deferred-a",
            productId: IAPService.proProductID,
            transactionAppAccountToken: tokenA,
            source: .updates
        )

        guard case .failed(_, .updates, let failure) = outcome else {
            Issue.record("Expected terminal ownership rejection, got \(outcome)")
            return
        }
        #expect(failure.disposition == .terminal)
        #expect(IAPTransactionFinishPolicy.shouldFinish(after: outcome))
        #expect(transactionSyncCount == 0)
        #expect(service.backendEntitlement == nil)
    }

    @Test func purchaseAdmissionExactAuthorityRaceCannotStartStoreKit() async {
        let authorityState = MutableAuthorityState(Self.authority(
            accountID: "account-a",
            token: "token-a"
        ))
        var purchaseStartCount = 0
        var invalidateAuthority: @MainActor () -> Void = {}
        let service = IAPService(
            captureRequestAuthority: { authorityState.value },
            authorizedRequest: { path, _, _, authority in
                let response = try Self.iapResponse(path: path, authority: authority)
                if path == "/api/v1/iap/context" {
                    authorityState.value = Self.authority(
                        accountID: "account-a",
                        token: "token-b"
                    )
                    invalidateAuthority()
                }
                return response
            },
            startAutomatically: false
        )
        invalidateAuthority = { service.clearEntitlementState() }

        do {
            let _: UUID = try await service.runPurchaseAdmission { token in
                purchaseStartCount += 1
                return token
            }
            Issue.record("StoreKit unexpectedly started after account authority changed")
        } catch is CancellationError {
            // Same account ID, but its exact bearer authority changed while the request suspended.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(purchaseStartCount == 0)
    }

    @Test func tokenlessDeferredUpdateCannotBeClaimed() async {
        var transactionSyncCount = 0
        let service = IAPService(
            captureRequestAuthority: { Self.authority(accountID: "account-a", token: "token-a") },
            authorizedRequest: { path, _, _, authority in
                if path == "/api/v1/iap/transaction-sync" {
                    transactionSyncCount += 1
                }
                return try Self.iapResponse(path: path, authority: authority)
            },
            convergeUsage: { .converged(revision: $0) },
            startAutomatically: false
        )

        let outcome = await service.processTransactionMutation(
            transactionId: "tokenless-deferred-update",
            productId: IAPService.proProductID,
            transactionAppAccountToken: nil,
            requireTransactionAppAccountToken: true,
            source: .updates
        )

        guard case .failed(_, .updates, let failure) = outcome else {
            Issue.record("Expected terminal tokenless ownership rejection, got \(outcome)")
            return
        }
        #expect(failure.disposition == .terminal)
        #expect(IAPTransactionFinishPolicy.shouldFinish(after: outcome))
        #expect(transactionSyncCount == 0)
        #expect(service.backendEntitlement == nil)
    }

    @Test func usageConvergenceFailurePreventsEntitlementMutationCommit() async throws {
        let service = IAPService(
            captureRequestAuthority: { Self.authority(accountID: "account-a") },
            authorizedRequest: Self.iapRequest,
            convergeUsage: { revision in
                .failed(revision: revision, message: "usage unavailable")
            },
            startAutomatically: false
        )

        let outcome = await service.processTransactionMutation(
            transactionId: "transaction-2",
            productId: IAPService.proProductID,
            source: .updates
        )

        guard case .failed(let revision, let source, let failure) = outcome else {
            Issue.record("Expected convergence failure, got \(outcome)")
            return
        }
        #expect(revision == 1)
        #expect(source == .updates)
        #expect(failure.message == "usage unavailable")
        #expect(service.lastUsageConvergenceOutcome == .failed(
            revision: 1,
            message: "usage unavailable"
        ))
        #expect(service.lastSyncError == "usage unavailable")
    }

    @Test func IAPBackendExecutorUsesCapturedAuthorityForResponseAndMaps401() async throws {
        let captured = Self.authority(accountID: "account-a", token: "token-a")
        var seen: [AuthenticatedHttpClient.AccountRequestAuthority] = []
        let executor = IAPBackendRequestExecutor { path, _, _, authority in
            seen.append(authority)
            if path == "/unauthorized" {
                throw AuthenticatedHttpError.unauthorized
            }
            return (
                try JSONEncoder().encode(Self.entitlement(plan: "pro")),
                Self.httpResponse(statusCode: 200)
            )
        }
        let entitlement: BackendEntitlement = try await executor.perform(
            path: "/entitlement",
            method: "GET",
            body: nil,
            authority: captured
        )
        #expect(entitlement.plan == "pro")
        #expect(seen == [captured])

        do {
            let _: BackendEntitlement = try await executor.perform(
                path: "/unauthorized",
                method: "GET",
                body: nil,
                authority: captured
            )
            Issue.record("Expected notAuthenticated")
        } catch IAPError.notAuthenticated {}
        #expect(seen == [captured, captured])
    }

    @Test func knownIAPValidation4xxIsTerminalButRecoveryFailuresRemainRetryable() async {
        #expect(IAPBackendValidationPolicy.isTerminal(
            statusCode: 422,
            code: "IAP_PRODUCT_MISMATCH"
        ))
        #expect(!IAPBackendValidationPolicy.isTerminal(
            statusCode: 401,
            code: "IAP_PRODUCT_MISMATCH"
        ))
        #expect(!IAPBackendValidationPolicy.isTerminal(
            statusCode: 422,
            code: "IAP_UNKNOWN_VALIDATION"
        ))
        // The backend's generic Apple-rejected bucket can include transient 4xx such as rate
        // limiting, and a missing user belongs to account recovery rather than transaction proof.
        #expect(!IAPBackendValidationPolicy.isTerminal(
            statusCode: 422,
            code: "IAP_APPLE_REQUEST_REJECTED"
        ))
        #expect(!IAPBackendValidationPolicy.isTerminal(
            statusCode: 404,
            code: "IAP_USER_NOT_FOUND"
        ))
        #expect(!IAPBackendValidationPolicy.isTerminal(
            statusCode: 503,
            code: "IAP_PRODUCT_MISMATCH"
        ))

        let executor = IAPBackendRequestExecutor { _, _, _, _ in
            let body = """
            {"error":"Product does not match transaction","code":"IAP_PRODUCT_MISMATCH"}
            """
            return (Data(body.utf8), Self.httpResponse(statusCode: 422))
        }

        do {
            let _: BackendEntitlement = try await executor.perform(
                path: "/api/v1/iap/transaction-sync",
                method: "POST",
                body: nil,
                authority: Self.authority(accountID: "account-a")
            )
            Issue.record("Expected terminal validation rejection")
        } catch IAPError.validationRejected(let code, let message) {
            #expect(code == "IAP_PRODUCT_MISMATCH")
            #expect(message == "Product does not match transaction")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func mutationClassificationKeepsAuthAndConvergenceRetryable() async {
        let coordinator = IAPEntitlementMutationCoordinator()
        let request = Self.authority(accountID: "account-a")

        let terminal = await coordinator.run(
            authority: coordinator.capture(request: request),
            source: .updates,
            currentAccountID: { "account-a" },
            operation: {
                throw IAPError.validationRejected(code: "IAP_PRODUCT_MISMATCH", message: "bad")
            }
        )
        let authentication = await coordinator.run(
            authority: coordinator.capture(request: request),
            source: .updates,
            currentAccountID: { "account-a" },
            operation: { throw IAPError.notAuthenticated }
        )
        let convergence = await coordinator.run(
            authority: coordinator.capture(request: request),
            source: .updates,
            currentAccountID: { "account-a" },
            operation: {
                throw IAPEntitlementMutationFailure(message: "usage unavailable")
            }
        )

        guard case .failed(_, _, let terminalFailure) = terminal,
              case .failed(_, _, let authFailure) = authentication,
              case .failed(_, _, let convergenceFailure) = convergence else {
            Issue.record("Expected three classified mutation failures")
            return
        }
        #expect(terminalFailure.disposition == .terminal)
        #expect(authFailure.disposition == .retryable)
        #expect(convergenceFailure.disposition == .retryable)
    }

    @Test func pendingStoreKitChangeCannotBeInteractivelyDismissedAfterRefreshFailure() {
        #expect(AppleSubscriptionDismissalPolicy.isDisabled(
            isReconciling: false,
            hasPendingStoreKitChange: true
        ))
        #expect(!AppleSubscriptionDismissalPolicy.isDisabled(
            isReconciling: false,
            hasPendingStoreKitChange: false
        ))
        #expect(!AppleSubscriptionDismissalPolicy.isDisabled(
            isReconciling: false,
            hasPendingStoreKitChange: true,
            terminalErrorAllowsExit: true
        ))
        #expect(AppleSubscriptionErrorPolicy.allowsExplicitExit(after:
            IAPEntitlementMutationFailure(message: "owned elsewhere", disposition: .terminal)
        ))
        #expect(!AppleSubscriptionErrorPolicy.allowsExplicitExit(after:
            IAPEntitlementMutationFailure(message: "offline")
        ))
    }

    @Test func restoreStaysPendingWhenConvergenceFailsAfterAppStoreSync() async {
        var hasPendingStoreKitChange = false

        do {
            try await AppleSubscriptionRestoreLifecycle.run(
                restore: { onStoreKitSyncCompleted in
                    onStoreKitSyncCompleted()
                    throw ProbeError.entitlement
                },
                onStoreKitSyncCompleted: {
                    hasPendingStoreKitChange = true
                }
            )
            Issue.record("Expected post-StoreKit convergence failure")
        } catch ProbeError.entitlement {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(hasPendingStoreKitChange)
        #expect(AppleSubscriptionDismissalPolicy.isDisabled(
            isReconciling: false,
            hasPendingStoreKitChange: hasPendingStoreKitChange
        ))
    }

    @Test func transactionUpdatesFinishOnlyAfterCommitOrTerminalConflict() {
        #expect(IAPTransactionFinishPolicy.shouldFinish(after: .committed(
            revision: 1,
            source: .updates
        )))
        #expect(!IAPTransactionFinishPolicy.shouldFinish(after: .stale(
            revision: 2,
            source: .updates
        )))
        #expect(!IAPTransactionFinishPolicy.shouldFinish(after: .failed(
            revision: 3,
            source: .updates,
            failure: IAPEntitlementMutationFailure(message: "offline")
        )))
        #expect(IAPTransactionFinishPolicy.shouldFinish(after: .failed(
            revision: 4,
            source: .updates,
            failure: IAPEntitlementMutationFailure(
                message: "owned elsewhere",
                disposition: .terminal
            )
        )))
        #expect(!IAPTransactionFinishPolicy.shouldFinish(after: .stale(
            revision: 5,
            source: .purchase
        )))
    }

    private static func summary(remainingDay: Int, remainingMonth: Int) -> UsageSummary {
        UsageSummary(
            plan: "pro",
            status: "active",
            limits: PlanLimits(requestsPerDay: 100, requestsPerMonth: 1_000),
            usage: UsageStats(day: 10, month: 100),
            remaining: RemainingQuota(day: remainingDay, month: remainingMonth)
        )
    }

    private static func authority(
        accountID: String,
        token: String = "test-token"
    ) -> AuthenticatedHttpClient.AccountRequestAuthority {
        .init(token: token, baseURL: "https://api.example.test", accountID: accountID)
    }

    private static func entitlement(plan: String) -> BackendEntitlement {
        BackendEntitlement(
            plan: plan,
            isActive: plan == "pro",
            status: "active",
            productId: IAPService.proProductID,
            expiresAt: nil,
            originalTransactionId: "original",
            environment: "Sandbox",
            updatedAt: nil
        )
    }

    private static func httpResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.example.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func iapRequest(
        path: String,
        method _: String,
        body _: Data?,
        authority _: AuthenticatedHttpClient.AccountRequestAuthority
    ) async throws -> (Data, HTTPURLResponse) {
        if path == "/api/v1/iap/context" {
            let context = """
            {
              "appAccountToken":"11111111-1111-1111-1111-111111111111",
              "productIds":["\(IAPService.proProductID)"],
              "entitlement":{
                "plan":"pro","isActive":true,"status":"active",
                "productId":"\(IAPService.proProductID)",
                "originalTransactionId":"original","environment":"Sandbox"
              }
            }
            """
            return (Data(context.utf8), httpResponse(statusCode: 200))
        }
        return (
            try JSONEncoder().encode(entitlement(plan: "pro")),
            httpResponse(statusCode: 200)
        )
    }

    private static func iapResponse(
        path: String,
        authority: AuthenticatedHttpClient.AccountRequestAuthority
    ) throws -> (Data, HTTPURLResponse) {
        if path == "/api/v1/iap/context" {
            let token = authority.accountID == "account-a"
                ? "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                : "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            let context = """
            {
              "appAccountToken":"\(token)",
              "productIds":["\(IAPService.proProductID)"],
              "entitlement":{
                "plan":"pro","isActive":true,"status":"active",
                "productId":"\(IAPService.proProductID)",
                "originalTransactionId":"original","environment":"Sandbox"
              }
            }
            """
            return (Data(context.utf8), httpResponse(statusCode: 200))
        }
        return (
            try JSONEncoder().encode(entitlement(plan: "pro")),
            httpResponse(statusCode: 200)
        )
    }

    private static func testDefaults() -> UserDefaults {
        UserDefaults(suiteName: "BillingPresentationTests.\(UUID().uuidString)")!
    }
}

@MainActor
private final class MutableAuthorityState {
    var value: AuthenticatedHttpClient.AccountRequestAuthority?

    init(_ value: AuthenticatedHttpClient.AccountRequestAuthority?) {
        self.value = value
    }
}

@MainActor
private final class MutableStringState {
    var value: String
    init(_ value: String) { self.value = value }
}

@MainActor
private final class MutableUInt64List {
    var values: [UInt64] = []
}

@MainActor
private final class ObservationInvalidationProbe {
    var didInvalidate = false
}

@MainActor
private final class QuotaResetSchedulerProbe {
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

@MainActor
private final class MutationBlocker {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class DelayedUsageRequestProbe {
    private var continuations: [String: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]

    func response(path: String) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuations[path] = $0 }
    }

    func waitUntilStarted(path: String) async {
        while continuations[path] == nil { await Task.yield() }
    }

    func succeed<Value: Encodable>(path: String, value: Value, statusCode: Int) {
        let data = try! JSONEncoder().encode(value)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.test\(path)")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        continuations.removeValue(forKey: path)?.resume(returning: (data, response))
    }

    func fail(path: String, error: Error) {
        continuations.removeValue(forKey: path)?.resume(throwing: error)
    }
}
