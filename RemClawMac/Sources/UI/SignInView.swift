import AppKit
import AuthenticationServices
import SwiftUI

struct MacSignInView: View {
    @Environment(MacGatewaySessionManager.self) private var session
    @Environment(\.localGateway) private var localGateway

    var launchStateOverride: MacLaunchState? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var appleSignInCoordinator: MacAppleSignInCoordinator?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 16, y: 8)

                VStack(spacing: 6) {
                    Text("Rem")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Turn your thoughts into actions")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 16) {
                MacLaunchStateCard(state: launchStateOverride ?? resolvedLaunchState)

                VStack(spacing: 10) {
                    if session.deployPhase.isDeploying {
                        deployProgressView
                    } else if isLoading {
                        ProgressView("Connecting...")
                            .controlSize(.regular)
                            .frame(width: 320, height: 46)
                    } else {
                        Button(action: startAppleSignIn) {
                            MacAuthProviderButton(
                                icon: {
                                    Image(systemName: "apple.logo")
                                        .font(.system(size: 16, weight: .semibold))
                                },
                                title: "Continue with Apple"
                            )
                        }
                        .buttonStyle(.plain)

                        Button(action: handleGoogleSignIn) {
                            MacAuthProviderButton(
                                icon: {
                                    GoogleLogo()
                                },
                                title: "Continue with Google"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Spacer()
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Color.backgroundPrimary)
    }

    private var resolvedLaunchState: MacLaunchState {
        if session.deployPhase.isDeploying {
            return .reconnecting
        }

        if session.connectionState.isConnected {
            return .connected
        }

        guard let localGateway else {
            return .signedOut
        }

        if localGateway.status.isRunning {
            return .localGatewayReady
        }

        if localGateway.isCLIInstalled {
            return .localGatewayFound
        }

        return .localGatewayMissing
    }

    private var deployProgressView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text("Setting up your gateway...")
                .font(.headline)

            Text(session.deployPhase.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
    }

    private func startAppleSignIn() {
        guard !isLoading else { return }
        errorMessage = nil
        if session.backendURL == nil || session.backendURL?.isEmpty == true {
            session.backendURL = Bundle.main.infoDictionary?["APIBaseURL"] as? String
        }
        guard let attempt = session.beginSignInAttempt() else {
            errorMessage = "Rem couldn't start sign-in. Check the backend configuration."
            return
        }
        isLoading = true

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let coordinator = MacAppleSignInCoordinator { result in
            handleAppleSignInResult(result, attempt: attempt)
            appleSignInCoordinator = nil
        }
        appleSignInCoordinator = coordinator

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = coordinator
        controller.presentationContextProvider = coordinator
        controller.performRequests()
    }

    private func handleAppleSignInResult(
        _ result: Result<ASAuthorization, Error>,
        attempt: MacSignInAttemptAuthority
    ) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken,
                  let idToken = String(data: identityToken, encoding: .utf8) else {
                errorMessage = "Failed to get Apple ID token"
                isLoading = false
                return
            }
            let authorizationCode = credential.authorizationCode.flatMap {
                String(data: $0, encoding: .utf8)
            }
            var profile: [String: String?]?
            if credential.fullName?.givenName != nil || credential.fullName?.familyName != nil {
                profile = [
                    "given_name": credential.fullName?.givenName,
                    "family_name": credential.fullName?.familyName,
                ]
            }

            errorMessage = nil

            Task {
                var signInAuthority: MacBackendAuthAuthority?
                do {
                    signInAuthority = try await session.authenticateWithBackend(
                        provider: "apple",
                        idToken: idToken,
                        profile: profile,
                        appleAuthorizationCode: authorizationCode,
                        attempt: attempt
                    )
                    try await fetchCredentialsOrDeploy()
                } catch {
                    if !session.deployPhase.isDeploying, let signInAuthority {
                        let cleanupError = session.clearBackendAuthenticationAfterFailedSignIn(
                            ifCurrent: signInAuthority
                        )
                        errorMessage = cleanupError
                            ?? "Sign-in failed: \(error.localizedDescription)"
                    } else if !session.deployPhase.isDeploying {
                        errorMessage = "Sign-in failed: \(error.localizedDescription)"
                    }
                }
                isLoading = false
            }

        case .failure(let error):
            isLoading = false
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                return
            }
            errorMessage = appleSignInErrorMessage(error)
        }
    }

    private func handleGoogleSignIn() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        if session.backendURL == nil || session.backendURL?.isEmpty == true {
            session.backendURL = Bundle.main.infoDictionary?["APIBaseURL"] as? String
        }
        guard let attempt = session.beginSignInAttempt() else {
            errorMessage = "Rem couldn't start sign-in. Check the backend configuration."
            isLoading = false
            return
        }

        Task {
            do {
                try await session.signInWithGoogle(attempt: attempt)
            } catch MacGatewayError.noGatewayDeployed {
                await triggerDeploy()
            } catch MacGatewayError.authCancelled {
                // User cancelled.
            } catch {
                if !session.deployPhase.isDeploying {
                    errorMessage = "Google Sign-In failed: \(error.localizedDescription)"
                }
            }
            isLoading = false
        }
    }

    private func fetchCredentialsOrDeploy() async throws {
        do {
            try await session.fetchGatewayCredentials()
        } catch MacGatewayError.noGatewayDeployed {
            await triggerDeploy()
        }
    }

    private func triggerDeploy() async {
        do {
            try await session.deployGateway()
        } catch {
            errorMessage = "Deploy failed: \(error.localizedDescription)"
        }
    }

    private func appleSignInErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == ASAuthorizationError.errorDomain else {
            return "Apple Sign-In failed: \(error.localizedDescription)"
        }

        if nsError.code == ASAuthorizationError.unknown.rawValue {
            return """
            Apple Sign-In is not available for this Mac build. Make sure the \
            `samatwork.RemClawMac` App ID has Sign in with Apple enabled and \
            this build is signed with `RemClawMac.entitlements`.
            """
        }

        return "Apple Sign-In failed: \(error.localizedDescription)"
    }
}

enum MacLaunchState: String, CaseIterable {
    case signedOut = "signed-out"
    case localGatewayMissing = "local-missing"
    case localGatewayFound = "local-found"
    case localGatewayReady = "local-ready"
    case reconnecting
    case gatewayOffline = "offline"
    case connected

    init?(launchArgument: String) {
        let normalized = launchArgument
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "signed-out", "signedout", "auth":
            self = .signedOut
        case "local-missing", "missing", "not-installed":
            self = .localGatewayMissing
        case "local-found", "found", "local":
            self = .localGatewayFound
        case "local-ready", "ready", "mac-ready":
            self = .localGatewayReady
        case "reconnecting", "checking":
            self = .reconnecting
        case "offline", "unreachable":
            self = .gatewayOffline
        case "connected":
            self = .connected
        default:
            return nil
        }
    }

    var accountTitle: String {
        switch self {
        case .connected:
            "Signed in"
        default:
            "Sign in to Rem"
        }
    }

    var accountMessage: String {
        switch self {
        case .connected:
            "Your Rem account is ready on this Mac."
        default:
            "Use the same account across iPhone and Mac."
        }
    }

    var gatewayIcon: String {
        switch self {
        case .signedOut: "macbook.and.iphone"
        case .localGatewayMissing: "arrow.down.circle"
        case .localGatewayFound: "desktopcomputer"
        case .localGatewayReady: "checkmark.circle.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .gatewayOffline: "wifi.slash"
        case .connected: "bolt.horizontal.circle.fill"
        }
    }

    var gatewayTitle: String {
        switch self {
        case .signedOut:
            "Gateway check comes next"
        case .localGatewayMissing:
            "Mac gateway not installed"
        case .localGatewayFound:
            "Mac gateway found"
        case .localGatewayReady:
            "Mac gateway ready"
        case .reconnecting:
            "Checking your gateway"
        case .gatewayOffline:
            "Gateway offline"
        case .connected:
            "Ready to open Rem"
        }
    }

    var gatewayMessage: String {
        switch self {
        case .signedOut:
            "After sign-in, Rem will connect this Mac or help you choose another gateway."
        case .localGatewayMissing:
            "After sign-in, Rem can install the local gateway or connect to your cloud gateway."
        case .localGatewayFound:
            "Rem can start the local gateway after sign-in if this Mac should run your tasks."
        case .localGatewayReady:
            "This Mac can handle requests while it is awake and connected."
        case .reconnecting:
            "Rem is checking whether your Mac or cloud gateway is available."
        case .gatewayOffline:
            "You can still sign in; Rem will help recover or switch gateways."
        case .connected:
            "Your account and gateway are connected."
        }
    }

    var tint: Color {
        switch self {
        case .gatewayOffline:
            DesignTokens.Color.systemOrange
        case .localGatewayMissing, .reconnecting:
            DesignTokens.Color.labelSecondary
        default:
            DesignTokens.Color.brandBlue
        }
    }
}

private struct MacLaunchStateCard: View {
    let state: MacLaunchState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacLaunchStatusRow(
                icon: "person.crop.circle.badge.checkmark",
                title: state.accountTitle,
                message: state.accountMessage,
                tint: DesignTokens.Color.brandBlue
            )

            Divider()

            MacLaunchStatusRow(
                icon: state.gatewayIcon,
                title: state.gatewayTitle,
                message: state.gatewayMessage,
                tint: state.tint
            )
        }
        .padding(16)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DesignTokens.Color.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignTokens.Color.separator.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("MacLaunchStateCard")
    }
}

private struct MacAuthProviderButton<Icon: View>: View {
    @ViewBuilder var icon: () -> Icon
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            icon()
                .frame(width: 18, height: 18)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(width: 320, height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)
        )
    }
}

private struct MacLaunchStatusRow: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private final class MacAppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let completion: (Result<ASAuthorization, Error>) -> Void

    init(completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.completion = completion
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        completion(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(error))
    }
}

private struct GoogleLogo: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w / 2
            let cy = h / 2
            let r = min(w, h) / 2
            let ringWidth = r * 0.35
            let outerR = r
            let innerR = r - ringWidth

            drawArc(context: context, center: CGPoint(x: cx, y: cy),
                    outerR: outerR, innerR: innerR,
                    startAngle: .degrees(-45), endAngle: .degrees(10),
                    color: Color(red: 66/255, green: 133/255, blue: 244/255))
            drawArc(context: context, center: CGPoint(x: cx, y: cy),
                    outerR: outerR, innerR: innerR,
                    startAngle: .degrees(10), endAngle: .degrees(100),
                    color: Color(red: 52/255, green: 168/255, blue: 83/255))
            drawArc(context: context, center: CGPoint(x: cx, y: cy),
                    outerR: outerR, innerR: innerR,
                    startAngle: .degrees(100), endAngle: .degrees(190),
                    color: Color(red: 251/255, green: 188/255, blue: 4/255))
            drawArc(context: context, center: CGPoint(x: cx, y: cy),
                    outerR: outerR, innerR: innerR,
                    startAngle: .degrees(190), endAngle: .degrees(315),
                    color: Color(red: 234/255, green: 67/255, blue: 53/255))

            let barHeight = ringWidth
            let barRect = CGRect(x: cx - 1, y: cy - barHeight / 2, width: r + 1, height: barHeight)
            context.fill(Path(barRect),
                         with: .color(Color(red: 66/255, green: 133/255, blue: 244/255)))

            let innerCircle = Path(ellipseIn: CGRect(x: cx - innerR, y: cy - innerR,
                                                     width: innerR * 2, height: innerR * 2))
            context.fill(innerCircle, with: .color(.white))
        }
    }

    private func drawArc(context: GraphicsContext, center: CGPoint,
                         outerR: CGFloat, innerR: CGFloat,
                         startAngle: Angle, endAngle: Angle,
                         color: Color) {
        var path = Path()
        path.addArc(center: center, radius: outerR,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerR,
                    startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}
