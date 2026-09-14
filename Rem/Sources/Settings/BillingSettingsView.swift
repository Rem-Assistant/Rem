import SwiftUI

// MARK: - Billing Settings (drill-down)

struct BillingSettingsView: View {
    @Environment(UsageService.self) private var usageService
    @Environment(IAPService.self) private var iapService

    @State private var showUpgradeSheet = false
    @State private var showTerms = false
    @State private var showPrivacy = false

    var body: some View {
        Group {
            switch BillingSummaryPresentationState.resolve(
                hasSummary: usageService.summary != nil,
                isLoading: usageService.isLoading,
                hasError: usageService.summaryLoadError != nil || usageService.summaryIsStale
            ) {
            case .loading:
                billingSkeleton
            case .available:
                if let summary = usageService.summary {
                    billingList(summary: summary)
                } else {
                    unavailableList
                }
            case .unavailable:
                unavailableList
            }
        }
        .navigationTitle("Billing & Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSummary() }
        .sheet(isPresented: $showUpgradeSheet) {
            if #available(iOS 17.0, *) {
                AppleSubscriptionSheet(onStoreKitStateChanged: refreshAfterStoreKitChange)
            }
        }
    }

    private func billingList(summary: UsageSummary) -> some View {
        List {
            Section {
                HStack {
                    Text("Plan")
                        .font(DesignTokens.Typography.body)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(BillingPlanPresentation.planName(summary.plan))
                            .font(DesignTokens.Typography.bodyBold)
                            .foregroundStyle(summary.plan.lowercased() == "pro" ? .blue : .secondary)
                        if let status = BillingPlanPresentation.statusLabel(
                            plan: summary.plan,
                            status: summary.status
                        ) {
                            Text(status)
                                .font(DesignTokens.Typography.caption1)
                                .foregroundStyle(DesignTokens.Color.systemOrange)
                        }
                    }
                }
            } header: {
                Text("Current Plan")
            }

            Section {
                let remaining = usageService.effectiveRemaining ?? summary.remaining
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Today")
                            .font(DesignTokens.Typography.body)
                        Spacer()
                        Text("\(summary.usage.day) / \(summary.limits.requestsPerDay) used")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(remaining.day < 10 ? .orange : .secondary)
                    }
                    ProgressView(
                        value: Double(summary.usage.day),
                        total: Double(max(summary.limits.requestsPerDay, 1))
                    )
                    .tint(remaining.day < 10 ? .orange : .blue)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("This Month")
                            .font(DesignTokens.Typography.body)
                        Spacer()
                        Text("\(summary.usage.month) / \(summary.limits.requestsPerMonth) used")
                            .font(DesignTokens.Typography.caption1)
                            .foregroundStyle(remaining.month < 50 ? .orange : .secondary)
                    }
                    ProgressView(
                        value: Double(summary.usage.month),
                        total: Double(max(summary.limits.requestsPerMonth, 1))
                    )
                    .tint(remaining.month < 50 ? .orange : .blue)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Usage")
            }

            Section {
                switch QuotaPresentation.make(
                    plan: summary.plan,
                    remaining: summary.remaining
                ).primaryAction {
                case .manageSubscription:
                    Button {
                        openSubscriptionManagement()
                    } label: {
                        Text("Manage Subscription")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                case .upgradeToPro:
                    Button {
                        showUpgradeSheet = true
                    } label: {
                        Text("Upgrade to Pro")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                case .refreshBilling:
                    Button {
                        Task { await loadSummary() }
                    } label: {
                        Text("Refresh Billing")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            } footer: {
                legalFooter
            }
        }
    }

    private var billingSkeleton: some View {
        List {
            Section("Current Plan") {
                skeletonRow(width: 110)
            }
            Section("Usage") {
                skeletonRow(width: 210)
                skeletonRow(width: 190)
            }
        }
    }

    private func skeletonRow(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(DesignTokens.Color.fillTertiary)
            .frame(width: width, height: 16)
            .redacted(reason: .placeholder)
            .shimmering()
            .padding(.vertical, 7)
    }

    private var unavailableList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("Billing is unavailable")
                        .font(DesignTokens.Typography.bodyBold)
                    Text(usageService.summaryLoadError ?? "Rem couldn't load your plan and usage right now.")
                        .font(DesignTokens.Typography.caption1)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                    Button("Try Again") {
                        Task { await loadSummary() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            } footer: {
                legalFooter
            }
        }
    }

    @MainActor
    private func loadSummary() async {
        do {
            try await usageService.fetchSummary()
        } catch {
            print("[BillingSettings] fetchSummary failed: \(error)")
        }
    }

    @MainActor
    private func refreshAfterStoreKitChange() async throws {
        try await iapService.reconcileStoreKitState()
    }

    // MARK: - Legal Footer

    private var legalFooter: some View {
        HStack(spacing: 4) {
            Button("Terms of Service") { showTerms = true }
            Text("and")
            Button("Privacy Policy") { showPrivacy = true }
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                LegalDocumentView(
                    title: "Terms of Service",
                    lastUpdated: LegalContent.termsLastUpdated,
                    sections: LegalContent.termsOfServiceSections)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showTerms = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                LegalDocumentView(
                    title: "Privacy Policy",
                    lastUpdated: LegalContent.privacyLastUpdated,
                    sections: LegalContent.privacyPolicySections)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showPrivacy = false }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func openSubscriptionManagement() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

}
