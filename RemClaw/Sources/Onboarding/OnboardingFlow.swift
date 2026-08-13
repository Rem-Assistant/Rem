import Combine
import SwiftUI

/// Unified onboarding flow — sign-in and server deploy as one cohesive experience.
/// Shown from `ContentView` whenever the gateway is not yet configured.
struct OnboardingFlow: View {
    @Environment(RemGatewaySessionManager.self) private var gateway
    @Environment(RemAuthService.self) private var authService
    @AppStorage("rem.hasAcceptedAIDataSharing") private var hasAcceptedAIDataSharing = false
    @AppStorage("rem.hasSeenPostSetupActivation.v1") private var hasSeenPostSetupActivation = false

    @State private var step: Step

    @State private var authError: String?
    @State private var authRecoveryProvider: AuthProvider?
    @State private var authRecoveryMessage: String?
    @State private var showTerms = false
    @State private var showPrivacy = false
    @State private var deployId: String?
    @State private var deployPhase: String = "creating_project"
    @State private var deployError: String?
    @State private var deployStartDate: Date?
    @State private var phaseStartDate: Date?
    @State private var phaseElapsed: TimeInterval = 0
    private let previewShowsProviderButtons: Bool

    fileprivate enum Step { case signIn, dataSharingConsent, deploying, postSetupActivation }

    init() {
        _step = State(initialValue: .signIn)
        previewShowsProviderButtons = false
    }

    fileprivate init(
        previewStep: Step,
        previewAuthError: String? = nil,
        previewAuthRecoveryProvider: AuthProvider? = nil,
        previewAuthRecoveryMessage: String? = nil,
        previewShowsProviderButtons: Bool = false
    ) {
        _step = State(initialValue: previewStep)
        _authError = State(initialValue: previewAuthError)
        _authRecoveryProvider = State(initialValue: previewAuthRecoveryProvider)
        _authRecoveryMessage = State(initialValue: previewAuthRecoveryMessage)
        self.previewShowsProviderButtons = previewShowsProviderButtons
    }

    var body: some View {
        ZStack {
            DesignTokens.Color.backgroundPrimary
                .ignoresSafeArea()

            switch step {
            case .signIn:
                signInContent
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .dataSharingConsent:
                AIDataSharingConsentView {
                    beginDeployAfterConsent()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            case .deploying:
                deployingContent
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            case .postSetupActivation:
                PostSetupActivationView {
                    finishPostSetupActivation()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)
        .onChange(of: authService.isAuthenticated) { _, isAuth in
            if isAuth {
                continueAfterAuthentication(source: "isAuthenticated=true")
            }
        }
    }

    // MARK: - Sign-In Step

    private var signInContent: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                OnboardingLogoView()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Rem")
                        .font(DesignTokens.Typography.largeTitle.weight(.semibold))
                        .foregroundColor(DesignTokens.Color.labelPrimary)

                    Text("Turn your thoughts\ninto actions")
                        .font(DesignTokens.Typography.title1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DesignTokens.Spacing.xs)
                }

                Group {
                    if previewShowsProviderButtons {
                        providerButtons
                    } else if authService.isCheckingAuth {
                        // Still resolving auth state — show redacted placeholder button
                        signInPlaceholder
                    } else if authService.isAuthenticated {
                        // Returning user — Keychain token survived app reinstall
                        VStack(spacing: DesignTokens.Spacing.md) {
                            SignInButton(
                                icon: { returningUserAvatar },
                                title: "Continue as \(returningUserName)",
                                action: {
                                    print("[RemClaw] Continue as returning user → confirmReturningUser()")
                                    authService.confirmReturningUser()
                                    continueAfterAuthentication(source: "returning user")
                                }
                            )

                            Button {
                                authService.signOut()
                            } label: {
                                Text("Sign in with a different account")
                                    .font(DesignTokens.Typography.body)
                                    .foregroundColor(DesignTokens.Color.labelSecondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    } else {
                        // New user or signed out — show provider buttons
                        providerButtons
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: authService.isCheckingAuth)

                if let error = authError {
                    signInErrorView(error, recoveryProvider: authRecoveryProvider)
                } else if let authRecoveryMessage {
                    signInRecoveryConfirmation(authRecoveryMessage)
                }
            }
            .padding(DesignTokens.Spacing.md)

            Spacer()
        }
    }

    private func signInErrorView(_ message: String, recoveryProvider: AuthProvider?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.Color.systemRed)
                    .padding(.top, 1)

                Text(message)
                    .font(DesignTokens.Typography.caption1)
                    .foregroundColor(DesignTokens.Color.systemRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let recoveryProvider {
                Button {
                    resetProviderSignIn(recoveryProvider)
                } label: {
                    Label("Clear local sign-in state", systemImage: "arrow.counterclockwise")
                        .font(DesignTokens.Typography.caption1.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("OnboardingResetProviderSignInButton")
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Color.systemRed.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DesignTokens.Color.systemRed.opacity(0.22), lineWidth: 1)
        )
        .accessibilityIdentifier("OnboardingSignInError")
    }

    private func signInRecoveryConfirmation(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.systemGreen)
                .padding(.top, 1)

            Text(message)
                .font(DesignTokens.Typography.caption1)
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Color.systemGreen.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DesignTokens.Color.systemGreen.opacity(0.22), lineWidth: 1)
        )
        .accessibilityIdentifier("OnboardingSignInRecoveryConfirmation")
    }

    // MARK: - Legal Disclosure

    private var providerButtons: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            #if canImport(GoogleSignIn)
            SignInButton(
                icon: {
                    Image("google-icon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                },
                title: "Continue with Google",
                action: { signIn(with: .google) }
            )
            #endif

            SignInButton(
                icon: {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(DesignTokens.Color.backgroundPrimary)
                },
                title: "Continue with Apple",
                action: { signIn(with: .apple) }
            )

            onboardingLegalDisclosure
        }
    }

    private var onboardingLegalDisclosure: some View {
        VStack(spacing: 4) {
            Text("By clicking continue, you acknowledge that you have read and agree to Rem's")
                .foregroundColor(DesignTokens.Color.labelSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 4) {
                Button("Terms of Service") { showTerms = true }
                Text("and")
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Button("Privacy Policy") { showPrivacy = true }
            }
        }
        .font(DesignTokens.Typography.caption1)
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

    // MARK: - Returning User Helpers

    private var returningUserName: String {
        if let name = authService.currentUser?.full_name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        if let email = authService.currentUser?.email {
            return email.components(separatedBy: "@").first ?? email
        }
        return "your account"
    }

    private var signInPlaceholder: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Circle()
                .fill(DesignTokens.Color.backgroundPrimary.opacity(0.4))
                .frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 4)
                .fill(DesignTokens.Color.backgroundPrimary.opacity(0.4))
                .frame(width: 140, height: 14)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Color.buttonBackground)
        .cornerRadius(DesignTokens.CornerRadius.medium)
        .shimmering()
    }

    @ViewBuilder
    private var returningUserAvatar: some View {
        if let raw = authService.currentUser?.profile_picture_url,
           let url = URL(string: raw), !raw.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    fallbackAvatar
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
        } else {
            fallbackAvatar
        }
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(DesignTokens.Color.backgroundPrimary)
            .frame(width: 18, height: 18)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.buttonBackground)
            }
    }

    // MARK: - Deploy Step

    private var deployingContent: some View {
        VStack(spacing: 0) {
            deployProgressBar
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)

            Spacer()

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                OnboardingLogoView()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Setting Up")
                        .font(DesignTokens.Typography.largeTitle.weight(.semibold))
                        .foregroundColor(DesignTokens.Color.labelPrimary)

                    Text("Your personal server, deploying now")
                        .font(DesignTokens.Typography.title1)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .padding(.top, DesignTokens.Spacing.xs)
                }

                deployProgressIndicator
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)

            Spacer()
        }
        .onChange(of: deployPhase) { _, _ in
            phaseStartDate = Date()
            phaseElapsed = 0
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if let start = phaseStartDate {
                phaseElapsed = Date().timeIntervalSince(start)
            }
        }
    }

    @ViewBuilder
    private var deployProgressBar: some View {
        let progress = deployProgressValue
        VStack(spacing: DesignTokens.Spacing.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.Color.systemGreen.opacity(0.35))
                        .frame(height: 4)

                    Capsule()
                        .fill(DesignTokens.Color.systemGreen)
                        .frame(width: geo.size.width * progress, height: 4)
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 4)

            HStack {
                Text("This may take a minute or two")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundColor(DesignTokens.Color.labelTertiary)

                Spacer()

                if let start = deployStartDate {
                    ElapsedTimeLabel(since: start)
                }
            }
        }
    }

    /// Progress reaches 97% at deploy complete, 100% only when connected.
    private var deployProgressValue: CGFloat {
        if gateway.isCompletingDeploy {
            return gateway.connectionState.isConnected ? 1.0 : 0.97
        }
        return OnboardingPhaseInfo.progress(for: deployPhase)
    }

    private var deployProgressIndicator: some View {
        let phases = OnboardingPhaseInfo.allPhases
        let hasError = deployError != nil
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                let state = phase.state(current: deployPhase, hasError: hasError)
                let isLast = index == phases.count - 1
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    // Left column: icon + vertical connector
                    VStack(spacing: 0) {
                        phaseIcon(state)
                            .frame(width: 20, height: 20)
                        if !isLast {
                            Rectangle()
                                .fill(
                                    state == .done
                                        ? DesignTokens.Color.systemGreen.opacity(0.35)
                                        : state == .failed
                                            ? DesignTokens.Color.systemRed.opacity(0.35)
                                            : DesignTokens.Color.labelTertiary.opacity(0.25)
                                )
                                .frame(width: 2, height: 36)
                                .padding(.top, 2)
                        }
                    }
                    .frame(width: 20)

                    // Right column: label + sublabel + error
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.label)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(
                                state == .pending
                                    ? DesignTokens.Color.labelTertiary
                                    : state == .failed
                                        ? DesignTokens.Color.systemRed
                                        : DesignTokens.Color.labelPrimary
                            )

                        if state == .failed, let error = deployError {
                            Text(error)
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(DesignTokens.Color.systemRed)

                            HStack(spacing: 16) {
                                Button("Try Again") {
                                    deployError = nil
                                    startDeploy()
                                }
                                .font(DesignTokens.Typography.caption1Bold)
                                .foregroundColor(DesignTokens.Color.labelSecondary)

                                Button("Sign In Again") {
                                    authService.clearSessionBecauseUnauthorized()
                                    gateway.clearConfiguration()
                                    RemCredentialStore.clearAll()
                                    deployError = nil
                                    step = .signIn
                                }
                                .font(DesignTokens.Typography.caption1Bold)
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                            }
                            .padding(.top, 2)
                        } else {
                            Text(dynamicSubLabel(for: phase, state: state))
                                .font(DesignTokens.Typography.caption1)
                                .foregroundColor(
                                    state == .active
                                        ? DesignTokens.Color.labelPrimary
                                        : DesignTokens.Color.labelTertiary
                                )
                                .animation(.easeInOut(duration: 0.2), value: dynamicSubLabel(for: phase, state: state))
                                .contentTransition(.opacity)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func phaseIcon(_ state: OnboardingPhaseInfo.State) -> some View {
        switch state {
        case .pending:
            Circle()
                .stroke(DesignTokens.Color.labelTertiary, lineWidth: 1.5)
        case .active:
            IndeterminateCircle()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .foregroundColor(DesignTokens.Color.systemGreen)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .resizable()
                .foregroundColor(DesignTokens.Color.systemRed)
        }
    }

    // MARK: - Dynamic Sublabels

    /// Returns a context-aware sublabel for phases that take a long time.
    /// "Configuring Gateway" rotates messages based on elapsed time.
    /// "Finishing Up" shows connection state when isCompletingDeploy is true.
    private func dynamicSubLabel(for phase: OnboardingPhaseInfo, state: OnboardingPhaseInfo.State) -> String {
        guard state == .active else { return phase.defaultSubLabel }

        // Configuring Server — timed sublabels
        if phase.id == "gateway" {
            if phaseElapsed < 10 {
                return "Customizing server for your AI assistant"
            } else if phaseElapsed < 25 {
                return "Configuring controls"
            } else {
                return "Applying changes and restarting server"
            }
        }

        // Finishing Up — connection-aware sublabels
        if phase.id == "finish" && gateway.isCompletingDeploy {
            switch gateway.connectionState {
            case .pairingRequired:
                return "Pairing your device..."
            case .connecting:
                return "Connecting to your server..."
            case .connected:
                return "Your server is ready"
            default:
                return "Connecting to your server..."
            }
        }

        return phase.subLabel(current: deployPhase)
    }

    // MARK: - Actions

    private func continueAfterAuthentication(source: String) {
        print("[RemClaw] OnboardingFlow \(source) → recheckConfigured()")
        gateway.recheckConfigured()
        if gateway.isConfigured {
            print("[RemClaw] OnboardingFlow gateway.isConfigured=true → wakeAndConnectIfConfigured(), skip deploy")
            gateway.wakeAndConnectIfConfigured()
            return
        }
        beginNewGatewaySetup()
    }

    private func beginNewGatewaySetup() {
        if hasAcceptedAIDataSharing {
            print("[RemClaw] OnboardingFlow gateway not configured and consent already accepted → startDeploy()")
            step = .deploying
            startDeploy()
        } else {
            print("[RemClaw] OnboardingFlow gateway not configured → show AI data-sharing consent before deploy")
            step = .dataSharingConsent
        }
    }

    private func beginDeployAfterConsent() {
        hasAcceptedAIDataSharing = true
        print("[RemClaw] OnboardingFlow consent accepted → startDeploy()")
        step = .deploying
        startDeploy()
    }

    private func finishPostSetupActivation() {
        hasSeenPostSetupActivation = true
        print("[RemClaw] OnboardingFlow post-setup activation complete → release deploy gate")
        gateway.isCompletingDeploy = false
    }

    private func signIn(with provider: AuthProvider) {
        Task {
            do {
                authError = nil
                authRecoveryProvider = nil
                authRecoveryMessage = nil
                switch provider {
                case .apple: try await authService.signInWithApple()
                #if canImport(GoogleSignIn)
                case .google: try await authService.signInWithGoogle()
                #endif
                default: break
                }
            } catch AuthError.signInCancelled {
                authError = nil
                authRecoveryProvider = nil
                authRecoveryMessage = nil
            } catch {
                authError = error.localizedDescription
                authRecoveryProvider = recoveryProvider(for: error, attemptedProvider: provider)
                authRecoveryMessage = nil
            }
        }
    }

    private func recoveryProvider(for error: Error, attemptedProvider: AuthProvider) -> AuthProvider? {
        if let authError = error as? AuthError,
           case .identityProviderFailed = authError {
            return attemptedProvider
        }
        return nil
    }

    private func resetProviderSignIn(_ provider: AuthProvider) {
        Task {
            await authService.resetProviderSignInState(for: provider)
            authError = nil
            authRecoveryProvider = nil
            authRecoveryMessage = providerResetConfirmation(for: provider)
        }
    }

    private func providerResetConfirmation(for provider: AuthProvider) -> String {
        switch provider {
        case .google:
            "Local Rem sign-in state and cached Google SDK state were cleared. Try Google again. If the same keychain error appears, erase this simulator or remove the saved Google account from the device."
        case .apple:
            "Local Rem sign-in state was cleared. Apple Sign-In is managed by iCloud and system settings, so confirm this simulator or device can use Apple Sign-In before trying again."
        }
    }

    private func startDeploy() {
        print("[RemClaw] startDeploy() called → POST /api/v1/deploy")
        deployPhase = "creating_project"
        deployError = nil
        deployStartDate = Date()
        Task {
            do {
                let result = try await CloudGatewayDeployClient.startDeploy()
                deployId = result.deployId
                print("[RemClaw] startDeploy() ok deployId=\(result.deployId) → polling status")
                try await pollStatus(deployId: result.deployId)
            } catch {
                print("[RemClaw] startDeploy() failed: \(error.localizedDescription)")
                deployError = error.localizedDescription
            }
        }
    }

    private func pollStatus(deployId: String) async throws {
        var lastLoggedPhase: String?
        while true {
            try await Task.sleep(for: .seconds(1))
            let status = try await CloudGatewayDeployClient.getDeployStatus(deployId: deployId)
            deployPhase = status.phase
            if status.phase != lastLoggedPhase {
                print("[RemClaw] deploy status phase=\(status.phase) message=\(status.message)")
                lastLoggedPhase = status.phase
            }

            switch status.phase {
            case "complete":
                print("[RemClaw] deploy complete → configuring gateway and waiting for connection")

                // Hold OnboardingFlow visible while we wait for WebSocket connection.
                // Without this flag, gateway.configure() sets isConfigured=true which
                // causes ContentView to dismiss OnboardingFlow immediately.
                gateway.isCompletingDeploy = true

                if let url = status.gatewayUrl, let token = status.gatewayToken {
                    gateway.configure(gatewayURL: url, gatewayToken: token)
                }

                // Wait for the WebSocket to actually connect (includes pairing flow).
                // The "Finishing Up" UI stays visible with connection-status sublabels.
                let connectionTimeout: TimeInterval = 30
                let connectionStart = Date()
                while Date().timeIntervalSince(connectionStart) < connectionTimeout {
                    try await Task.sleep(for: .seconds(0.5))
                    if gateway.connectionState.isConnected {
                        print("[RemClaw] gateway connected after deploy")
                        break
                    }
                }
                if !gateway.connectionState.isConnected {
                    print("[RemClaw] gateway connection timed out after deploy (will continue)")
                } else {
                    // Let the user see "Your server is ready" at 100% before transitioning
                    try await Task.sleep(for: .seconds(1.5))
                }

                if hasSeenPostSetupActivation {
                    // Release the gate — ContentView will now transition to the main app.
                    gateway.isCompletingDeploy = false
                } else {
                    step = .postSetupActivation
                }
                return
            case "failed":
                deployError = status.message
                print("[RemClaw] deploy failed: \(status.message)")
                return
            default:
                continue
            }
        }
    }
}

// MARK: - Logo View

struct OnboardingLogoView: View {
    var body: some View {
        Group {
            if let appIcon = UIImage(named: "AppIcon") {
                Image(uiImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .cornerRadius(DesignTokens.CornerRadius.small)
            } else if let appIcon = Bundle.main.onboardingAppIcon {
                Image(uiImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .cornerRadius(DesignTokens.CornerRadius.small)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small)
                        .fill(Color.accentColor)
                        .frame(width: 40, height: 40)
                    Image(systemName: "network")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
        }
    }
}

// MARK: - Elapsed Time Label

private struct ElapsedTimeLabel: View {
    let since: Date
    @State private var elapsed: TimeInterval = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatted)
            .font(DesignTokens.Typography.footnote)
            .foregroundColor(DesignTokens.Color.labelTertiary)
            .monospacedDigit()
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(since)
            }
            .onAppear {
                elapsed = Date().timeIntervalSince(since)
            }
    }

    private var formatted: String {
        let total = Int(max(0, elapsed))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Indeterminate Circle

private struct IndeterminateCircle: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(
                DesignTokens.Color.labelPrimary,
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

extension Bundle {
    var onboardingAppIcon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last {
            return UIImage(named: lastIcon)
        }
        return nil
    }
}

// MARK: - Phase Info

private struct OnboardingPhaseInfo: Identifiable {
    let id: String
    let label: String
    let phases: [String]
    let subLabels: [String: String]
    let defaultSubLabel: String

    enum State { case pending, active, done, failed }

    func state(current: String, hasError: Bool = false) -> State {
        let ordered = Self.orderedPhases
        guard let currentIdx = ordered.firstIndex(of: current) else { return .pending }
        let myIndices = phases.compactMap { ordered.firstIndex(of: $0) }
        guard let myMin = myIndices.min(), let myMax = myIndices.max() else { return .pending }
        if currentIdx > myMax { return .done }
        if currentIdx >= myMin && currentIdx <= myMax {
            return hasError ? .failed : .active
        }
        return .pending
    }

    func subLabel(current: String) -> String {
        guard state(current: current) == .active else { return defaultSubLabel }
        return subLabels[current] ?? defaultSubLabel
    }

    static let orderedPhases = [
        "creating_project", "setting_variables", "deploying",
        "waiting_for_healthy", "running_onboarding", "saving_credentials", "complete"
    ]

    /// Maps each backend phase to a rough progress percentage (0.0–1.0).
    static func progress(for phase: String) -> CGFloat {
        switch phase {
        case "creating_project":    return 0.05
        case "setting_variables":   return 0.15
        case "deploying":           return 0.25
        case "waiting_for_healthy": return 0.55
        case "running_onboarding":  return 0.75
        case "saving_credentials":  return 0.90
        case "complete":            return 0.97
        default:                    return 0.0
        }
    }

    static let allPhases: [OnboardingPhaseInfo] = [
        .init(
            id: "create",
            label: "Creating Server",
            phases: ["creating_project", "setting_variables"],
            subLabels: [
                "creating_project": "Setting up your private server",
                "setting_variables": "Preparing secure environment"
            ],
            defaultSubLabel: "Setting up your private server"
        ),
        .init(
            id: "deploy",
            label: "Deploying Server",
            phases: ["deploying", "waiting_for_healthy"],
            subLabels: [
                "deploying": "Launching your server",
                "waiting_for_healthy": "Waiting for server to come online"
            ],
            defaultSubLabel: "Launching your server"
        ),
        .init(
            id: "gateway",
            label: "Configuring Server",
            phases: ["running_onboarding"],
            subLabels: [
                "running_onboarding": "Customizing server for your AI assistant"
            ],
            defaultSubLabel: "Customizing server for your AI assistant"
        ),
        .init(
            id: "finish",
            label: "Finishing Up",
            phases: ["saving_credentials", "complete"],
            subLabels: [
                "saving_credentials": "Saving your connection details",
                "complete": "Your server is ready"
            ],
            defaultSubLabel: "Connecting to your server"
        ),
    ]
}

#Preview("Sign In") {
    OnboardingFlow()
        .environment(RemGatewaySessionManager())
        .environment(RemAuthService())
}

#Preview("Sign In — Dark") {
    OnboardingFlow()
        .environment(RemGatewaySessionManager())
        .environment(RemAuthService())
        .preferredColorScheme(.dark)
}

#Preview("Deploy Step") {
    OnboardingFlow(previewStep: .deploying)
        .environment(RemGatewaySessionManager())
        .environment(RemAuthService())
}

#Preview("Data Sharing Consent") {
    OnboardingFlow(previewStep: .dataSharingConsent)
        .environment(RemGatewaySessionManager())
        .environment(RemAuthService())
}

#Preview("Post-Setup Activation") {
    OnboardingFlow(previewStep: .postSetupActivation)
        .environment(RemGatewaySessionManager())
        .environment(RemAuthService())
}

#Preview("Deploy Step — Dark") {
    OnboardingFlow(previewStep: .deploying)
        .environment(RemGatewaySessionManager())
        .environment(RemAuthService())
        .preferredColorScheme(.dark)
}

#if DEBUG
struct OnboardingFixtureView: View {
    var body: some View {
        OnboardingFlow(previewStep: .signIn, previewShowsProviderButtons: true)
            .environment(RemGatewaySessionManager())
            .environment(RemAuthService())
    }
}

struct OnboardingKeychainErrorFixtureView: View {
    private let message = IdentityProviderFailure.map(
        provider: "Google",
        operation: "open Google sign-in",
        error: NSError(
            domain: "com.google.GIDSignIn",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "keychain error"]
        )
    ).localizedDescription

    var body: some View {
        OnboardingFlow(
            previewStep: .signIn,
            previewAuthError: message,
            previewAuthRecoveryProvider: .google,
            previewShowsProviderButtons: true
        )
            .environment(RemGatewaySessionManager())
            .environment(RemAuthService())
    }
}
#endif
