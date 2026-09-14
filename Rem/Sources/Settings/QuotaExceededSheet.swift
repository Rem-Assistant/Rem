import SwiftUI

struct QuotaExceededSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UsageService.self) private var usageService
    @Environment(IAPService.self) private var iapService
    @State private var isPurchasing = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .padding(.top, 24)
                
                Text(usageService.quotaPresentation.title)
                    .font(.title.bold())
                
                if let error = usageService.quotaError {
                    Text(error.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Remaining today:")
                            Spacer()
                            Text("\(error.remaining.day)")
                                .fontWeight(.semibold)
                        }
                        HStack {
                            Text("Remaining this month:")
                            Spacer()
                            Text("\(error.remaining.month)")
                                .fontWeight(.semibold)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Spacer()
                
                VStack(spacing: 12) {
                    Button {
                        performPrimaryAction()
                    } label: {
                        if isPurchasing {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .cornerRadius(12)
                        } else {
                            Text(usageService.quotaPresentation.primaryActionTitle)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.blue)
                                .foregroundStyle(.white)
                                .cornerRadius(12)
                        }
                    }
                    .disabled(isPurchasing)
                    
                    Button {
                        dismiss()
                        usageService.dismissQuotaError()
                    } label: {
                        Text("Maybe Later")
                            .foregroundStyle(.secondary)
                    }
                    .disabled(isPurchasing)

                    legalLinks
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                        usageService.dismissQuotaError()
                    }
                    .disabled(isPurchasing)
                }
            }
            .sheet(isPresented: $showAppleSubscription) {
                if #available(iOS 17.0, *) {
                    AppleSubscriptionSheet(onStoreKitStateChanged: refreshAfterStoreKitChange)
                }
            }
        }
    }

    @State private var showAppleSubscription = false
    @State private var showTerms = false
    @State private var showPrivacy = false

    private var legalLinks: some View {
        HStack(spacing: 4) {
            Button("Terms of Service") { showTerms = true }
            Text("and")
                .foregroundStyle(.secondary)
            Button("Privacy Policy") { showPrivacy = true }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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

    private func refreshAfterStoreKitChange() async throws {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            try await iapService.reconcileStoreKitState()
            if usageService.hasQuotaForUI {
                usageService.dismissQuotaError()
            }
        } catch {
            errorMessage = "Your App Store change succeeded, but Rem couldn't refresh your plan and usage. Try again."
            throw error
        }
    }

    private func performPrimaryAction() {
        switch usageService.quotaPresentation.primaryAction {
        case .upgradeToPro:
            showAppleSubscription = true
        case .manageSubscription:
            guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
            UIApplication.shared.open(url)
        case .refreshBilling:
            Task { await refreshBillingEvidence() }
        }
    }

    @MainActor
    private func refreshBillingEvidence() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            try await usageService.fetchSummary()
            if usageService.hasQuotaForUI {
                usageService.dismissQuotaError()
                dismiss()
            }
        } catch {
            errorMessage = "Rem couldn't refresh your plan and usage. Check your connection and try again."
        }
    }
}

#Preview {
    QuotaExceededSheet()
        .environment(UsageService())
        .environment(IAPService())
}
