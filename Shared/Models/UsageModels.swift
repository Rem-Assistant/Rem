import Foundation

// MARK: - Usage Summary

/// Shared usage summary model matching the backend `/api/v1/usage/summary` response.
struct UsageSummary: Codable, Sendable {
    let plan: String
    let status: String
    let limits: PlanLimits
    let usage: UsageStats
    let remaining: RemainingQuota
}

struct PlanLimits: Codable, Sendable {
    let requestsPerDay: Int
    let requestsPerMonth: Int
}

struct UsageStats: Codable, Sendable {
    let day: Int
    let month: Int
}

struct RemainingQuota: Codable, Sendable {
    let day: Int
    let month: Int
}

struct QuotaExceededError: Codable, Sendable {
    let type: String
    let message: String
    let remaining: RemainingQuota
}

struct QuotaErrorResponse: Codable, Sendable {
    let error: QuotaExceededError
}

struct UsageConsumeResponse: Codable, Sendable {
    let ok: Bool
    let usage: UsageStats
    let remaining: RemainingQuota
}

/// Billing copy is derived from the backend's plan/status contract instead of assuming every
/// non-empty summary is an active subscription. Shared by iOS and macOS so both platforms expose
/// the same entitlement truth.
enum BillingPlanPresentation {
    static func planName(_ rawPlan: String) -> String {
        switch normalized(rawPlan) {
        case "free": "Free"
        case "pro": "Pro"
        default: "Current plan"
        }
    }

    static func statusLabel(plan rawPlan: String, status rawStatus: String) -> String? {
        let plan = normalized(rawPlan)
        return switch normalized(rawStatus) {
        case "", "active": nil
        case "past_due": "Subscription payment issue"
        // The backend intentionally collapses expired, revoked, family-shared, and no-chain
        // states into `free + cancelled`. Free already communicates the current entitlement;
        // calling that lossy bucket a user cancellation would invent history we do not have.
        case "cancelled", "canceled": plan == "free" ? nil : "No active subscription"
        default: "Needs attention"
        }
    }

    static func isFree(_ rawPlan: String?) -> Bool {
        guard let rawPlan else { return false }
        return normalized(rawPlan) == "free"
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum BillingSummaryPresentationState: Equatable, Sendable {
    case loading
    case available
    case unavailable

    static func resolve(hasSummary: Bool, isLoading: Bool, hasError: Bool) -> Self {
        if isLoading { return .loading }
        if hasError { return .unavailable }
        return hasSummary ? .available : .unavailable
    }
}

enum QuotaEvidenceFreshness {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// A cached denial is useful only until the constrained backend bucket resets. Positive or
    /// absent evidence never blocks locally and may always proceed to the authoritative backend.
    static func canBlockLocally(
        remaining: RemainingQuota,
        observedAt: Date?,
        now: Date
    ) -> Bool {
        guard remaining.day <= 0 || remaining.month <= 0,
              let observedAt else { return false }
        return resetDate(for: remaining, observedAt: observedAt).map { now < $0 } ?? false
    }

    static func resetDate(for remaining: RemainingQuota, observedAt: Date) -> Date? {
        guard remaining.day <= 0 || remaining.month <= 0 else { return nil }
        let calendar = utcCalendar
        if remaining.month <= 0 {
            return calendar.date(
                byAdding: .month,
                value: 1,
                to: calendar.dateInterval(of: .month, for: observedAt)?.start ?? observedAt
            )
        }
        return calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: observedAt)
        )
    }
}

/// User-facing quota state derived only from structured backend fields. Never parse the backend's
/// prose and never infer that an unavailable plan is Free.
struct QuotaPresentation: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case daily
        case monthly
    }

    enum PrimaryAction: Equatable, Sendable {
        case upgradeToPro
        case manageSubscription
        case refreshBilling
    }

    let scope: Scope
    let title: String
    let bannerText: String
    let primaryAction: PrimaryAction

    var primaryActionTitle: String {
        switch primaryAction {
        case .upgradeToPro: "Upgrade to Pro"
        case .manageSubscription: "Manage Subscription"
        case .refreshBilling: "Refresh Billing"
        }
    }

    static func make(plan: String?, remaining: RemainingQuota) -> QuotaPresentation {
        // When both buckets are empty, monthly is the durable constraint and the useful reset
        // horizon. A daily-only message would invite a retry tomorrow that must still fail.
        let scope: Scope = remaining.month <= 0 ? .monthly : .daily
        let normalizedPlan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let action: PrimaryAction = switch normalizedPlan {
        case "free": .upgradeToPro
        case "pro": .manageSubscription
        default: .refreshBilling
        }

        let title = scope == .monthly
            ? "Monthly request limit reached"
            : "Daily request limit reached"
        let bannerText: String
        switch (scope, action) {
        case (.daily, .upgradeToPro):
            bannerText = "Daily request limit reached. Upgrade or come back tomorrow."
        case (.monthly, .upgradeToPro):
            bannerText = "Monthly request limit reached. Upgrade or wait for your plan to reset."
        case (.daily, .manageSubscription):
            bannerText = "Daily request limit reached. Come back tomorrow or manage your subscription."
        case (.monthly, .manageSubscription):
            bannerText = "Monthly request limit reached. Manage your subscription or wait for your plan to reset."
        case (.daily, .refreshBilling):
            bannerText = "Daily request limit reached. Refresh Billing & Usage or come back tomorrow."
        case (.monthly, .refreshBilling):
            bannerText = "Monthly request limit reached. Refresh Billing & Usage or wait for your plan to reset."
        }
        return QuotaPresentation(
            scope: scope,
            title: title,
            bannerText: bannerText,
            primaryAction: action
        )
    }

    static func currentDenial(plan: String?, remaining: RemainingQuota?) -> QuotaPresentation? {
        guard let remaining, remaining.day <= 0 || remaining.month <= 0 else { return nil }
        return make(plan: plan, remaining: remaining)
    }
}
