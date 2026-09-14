import SwiftUI
import StoreKit

/// Apple's native SubscriptionStoreView wrapper.
/// Automatically handles title, price, duration, and legal links.
@available(iOS 17.0, *)
struct AppleSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(IAPService.self) private var iapService

    private let subscriptionGroupID = "21954380"
    var onStoreKitStateChanged: @MainActor () async throws -> Void = {}

    @State private var isReconciling = false
    @State private var reconciliationError: String?
    @State private var hasPendingStoreKitChange = false
    @State private var terminalErrorAllowsExit = false

    var body: some View {
        VStack(spacing: 0) {
            SubscriptionStoreView(groupID: subscriptionGroupID) {
                VStack(spacing: 16) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)

                    Text("Upgrade to Rem Pro")
                        .font(.title2.bold())

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(SubscriptionBenefit.pro) { benefit in
                            benefitRow(icon: benefit.icon, text: benefit.title)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 20)
            }
            // StoreKit's inAppPurchaseOptions provider cannot throw or cancel. Returning an empty
            // option set after an authority failure would therefore start a tokenless purchase.
            // Own the control so StoreKit is entered only through IAPService's throwing,
            // appAccountToken-bound admission path.
            .subscriptionStoreControlStyle(BoundSubscriptionStoreControlStyle(
                isEnabled: !isReconciling && !hasPendingStoreKitChange,
                purchase: { product in
                    await purchaseAndDismiss(product)
                }
            ))
            // The native restore button has no completion hook for refreshing Rem's backend usage
            // authority. Keep restore visible, but own its lifecycle below so it cannot leave stale
            // plan limits behind.
            .storeButton(.hidden, for: .restorePurchases)

            VStack(spacing: 10) {
                if let reconciliationError {
                    Text(reconciliationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)

                    Button(hasPendingStoreKitChange ? "Refresh Plan" : "Try Restore") {
                        Task {
                            if hasPendingStoreKitChange {
                                await reconcileAndDismiss()
                            } else {
                                await restorePurchases()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isReconciling)

                    if terminalErrorAllowsExit {
                        Button("Close") { dismiss() }
                            .buttonStyle(.bordered)
                            .disabled(isReconciling)
                    }
                } else {
                    Button {
                        Task { await restorePurchases() }
                    } label: {
                        if isReconciling {
                            ProgressView()
                        } else {
                            Text("Restore Purchases")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReconciling)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        // Once StoreKit succeeds, keep the retry contract on-screen until canonical backend
        // entitlement and usage both converge. Dismissing here would strand stale quota state.
        .interactiveDismissDisabled(AppleSubscriptionDismissalPolicy.isDisabled(
            isReconciling: isReconciling,
            hasPendingStoreKitChange: hasPendingStoreKitChange,
            terminalErrorAllowsExit: terminalErrorAllowsExit
        ))
    }

    @MainActor
    private func restorePurchases() async {
        guard !isReconciling else { return }
        isReconciling = true
        reconciliationError = nil
        terminalErrorAllowsExit = false
        defer { isReconciling = false }

        do {
            try await AppleSubscriptionRestoreLifecycle.run(
                restore: { onStoreKitSyncCompleted in
                    try await iapService.restorePurchases(
                        onStoreKitSyncCompleted: onStoreKitSyncCompleted
                    )
                },
                onStoreKitSyncCompleted: {
                    hasPendingStoreKitChange = true
                }
            )
            hasPendingStoreKitChange = false
            dismiss()
        } catch {
            reconciliationError = error.localizedDescription
            terminalErrorAllowsExit = AppleSubscriptionErrorPolicy.allowsExplicitExit(after: error)
        }
    }

    @MainActor
    private func purchaseAndDismiss(_ product: Product) async {
        guard !isReconciling else { return }
        isReconciling = true
        reconciliationError = nil
        terminalErrorAllowsExit = false
        defer { isReconciling = false }

        do {
            let transaction = try await iapService.purchase(product) {
                hasPendingStoreKitChange = true
            }
            guard transaction != nil else { return }
            hasPendingStoreKitChange = false
            dismiss()
        } catch {
            reconciliationError = error.localizedDescription
            terminalErrorAllowsExit = AppleSubscriptionErrorPolicy.allowsExplicitExit(after: error)
        }
    }

    @MainActor
    private func reconcileAndDismiss() async {
        guard !isReconciling else { return }
        isReconciling = true
        reconciliationError = nil
        terminalErrorAllowsExit = false
        defer { isReconciling = false }

        do {
            try await AppleSubscriptionPurchaseLifecycle.run(
                reconcileCanonicalState: onStoreKitStateChanged,
                onConverged: {
                    hasPendingStoreKitChange = false
                    dismiss()
                }
            )
        } catch {
            reconciliationError = error.localizedDescription
            terminalErrorAllowsExit = AppleSubscriptionErrorPolicy.allowsExplicitExit(after: error)
            if reconciliationError?.isEmpty != false {
                reconciliationError = "Your App Store change succeeded, but Rem couldn't refresh your plan and usage. Try again."
            }
        }
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.blue)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

@available(iOS 17.0, *)
private struct BoundSubscriptionStoreControlStyle: SubscriptionStoreControlStyle {
    let isEnabled: Bool
    let purchase: @MainActor (Product) async -> Void

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 10) {
            ForEach(configuration.allOptions, id: \.id) { product in
                Button {
                    Task { await purchase(product) }
                } label: {
                    Text("Subscribe \(product.displayPrice)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled)
            }
        }
        .padding(.horizontal)
    }
}

enum AppleSubscriptionDismissalPolicy {
    static func isDisabled(
        isReconciling: Bool,
        hasPendingStoreKitChange: Bool,
        terminalErrorAllowsExit: Bool = false
    ) -> Bool {
        isReconciling || (hasPendingStoreKitChange && !terminalErrorAllowsExit)
    }
}

enum AppleSubscriptionErrorPolicy {
    static func allowsExplicitExit(after error: Error) -> Bool {
        if let failure = error as? IAPEntitlementMutationFailure {
            return failure.disposition == .terminal
        }
        if let iapError = error as? IAPError {
            switch iapError {
            case .ownershipConflict, .validationRejected:
                return true
            default:
                return false
            }
        }
        return false
    }
}

@MainActor
enum AppleSubscriptionPurchaseLifecycle {
    static func run(
        reconcileCanonicalState: @escaping @MainActor () async throws -> Void,
        onConverged: @escaping @MainActor () -> Void
    ) async throws {
        try await reconcileCanonicalState()
        onConverged()
    }
}

@MainActor
enum AppleSubscriptionRestoreLifecycle {
    typealias Restore = @MainActor (
        _ onStoreKitSyncCompleted: @escaping @MainActor () -> Void
    ) async throws -> Void

    static func run(
        restore: Restore,
        onStoreKitSyncCompleted: @escaping @MainActor () -> Void
    ) async throws {
        try await restore(onStoreKitSyncCompleted)
    }
}

/// Purchase-facing claims must stay inside the entitlement contract the app can prove today.
/// Pro raises request limits; credits remain deferred and device capabilities are not paywalled.
struct SubscriptionBenefit: Identifiable, Equatable {
    let icon: String
    let title: String
    var id: String { title }

    static let pro: [SubscriptionBenefit] = [
        SubscriptionBenefit(
            icon: "bolt.fill",
            title: "Higher daily and monthly AI request limits"
        ),
        SubscriptionBenefit(
            icon: "arrow.triangle.2.circlepath",
            title: "Subscription status synced to your Rem account"
        ),
        SubscriptionBenefit(
            icon: "checkmark.shield.fill",
            title: "Manage or cancel anytime through the App Store"
        ),
    ]
}
