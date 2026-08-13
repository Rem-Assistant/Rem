import SwiftUI

/// Cross-platform "Choose your Gateway" view used by both onboarding and
/// "Add Gateway" flows. Replaces the iOS direct-form sheet and the Mac's
/// platform-specific `GatewayChoiceView`.
///
/// The four options:
///   1. **Deploy/Repair Cloud Gateway** — runs the existing cloud deploy.
///   2. **Use my Mac** (iOS) / **This Mac** (Mac) — only shown when a
///      `localGatewayActionLabel` is supplied, indicating the platform
///      can either start a local gateway (Mac) or wants to nudge the user
///      toward setup-code/discovery (iOS).
///   3. **Nearby Gateways** — pushes `SharedNearbyGatewaysView` if a
///      `discovery` is provided. Tapping a discovered gateway pushes
///      `SharedSetupCodeEntryView` with the gateway pre-filled so the
///      user can complete auth via setup code or token — Bonjour locates
///      the gateway but doesn't carry credentials (#276).
///   4. **Setup code / Manual** — pushes `SharedSetupCodeEntryView` for
///      paste-and-go or the legacy URL+token form via Advanced disclosure.
struct SharedChooseGatewayView<Discovery: GatewayDiscovering>: View {

    /// Cloud deploy callback. Optional — Add Gateway from settings on
    /// iOS doesn't currently expose deploy, so the tile is hidden when nil.
    var onCloudDeploy: (() -> Void)? = nil
    var cloudDeployTitle: String = "Deploy to Cloud"
    var cloudDeploySubtitle: String = "Create your Rem cloud gateway on Fly.io. Reachable from any device."
    var cloudDeployBadge: String? = "Recommended"
    var cloudDeployDisabled: Bool = false
    var cloudDeployConfirmationTitle: String?
    var cloudDeployConfirmationMessage: String?
    var cloudDeployConfirmationButtonTitle: String = "Continue"
    var onLocalGateway: (() -> Void)? = nil
    var localGatewayActionLabel: String? = nil
    var localGatewaySubtitle: String = ""
    var localGatewayDisabled: Bool = false

    var discovery: Discovery? = nil
    var onConnect: (GatewayConfig) -> Void

    var onCancel: (() -> Void)? = nil

    @State private var path = NavigationPath()
    @State private var showCloudDeployConfirmation = false

    /// Typed navigation destinations. Using a single `NavigationPath` +
    /// `.navigationDestination(for:)` lets us push *from* the nearby
    /// view into setup-code entry (carrying the discovered gateway as
    /// prefill) — the old two-binding layout couldn't layer destinations.
    private enum Destination: Hashable {
        case nearby
        case setupCode
        case setupCodeWithDiscovery(DiscoveredGateway)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 24) {
                Spacer(minLength: 8)
                if showCloudDeployConfirmation {
                    cloudDeployConfirmation
                } else {
                    header
                    cards
                    Spacer()
                    if let onCancel {
                        Button("Cancel", action: onCancel)
                            .keyboardShortcut(.cancelAction)
                            .padding(.bottom, 4)
                    }
                }
            }
            .padding(24)
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .nearby:
                    if let discovery {
                        SharedNearbyGatewaysView(discovery: discovery) { gateway in
                            path.append(Destination.setupCodeWithDiscovery(gateway))
                        }
                    }
                case .setupCode:
                    SharedSetupCodeEntryView(onConnect: onConnect)
                case .setupCodeWithDiscovery(let gateway):
                    SharedSetupCodeEntryView(
                        prefilledDiscovery: gateway,
                        onConnect: onConnect
                    )
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Set Up Your Gateway")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Choose how you want to connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(spacing: 12) {
            if let onCloudDeploy {
                Button {
                    guard !cloudDeployDisabled else { return }
                    if requiresCloudDeployConfirmation {
                        showCloudDeployConfirmation = true
                    } else {
                        onCloudDeploy()
                    }
                } label: {
                    SharedGatewayChoiceCard(
                        icon: "cloud.fill",
                        title: cloudDeployTitle,
                        subtitle: cloudDeploySubtitle,
                        badge: cloudDeployBadge,
                        disabled: cloudDeployDisabled
                    )
                }
                .buttonStyle(.plain)
                .disabled(cloudDeployDisabled)
            }

            if let onLocalGateway, let label = localGatewayActionLabel {
                Button {
                    onLocalGateway()
                } label: {
                    SharedGatewayChoiceCard(
                        icon: "desktopcomputer",
                        title: label,
                        subtitle: localGatewaySubtitle,
                        badge: nil,
                        disabled: localGatewayDisabled
                    )
                }
                .buttonStyle(.plain)
                .disabled(localGatewayDisabled)
            }

            if discovery != nil {
                Button {
                    path.append(Destination.nearby)
                } label: {
                    SharedGatewayChoiceCard(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Nearby Gateways",
                        subtitle: "Find a gateway running on your Wi-Fi via Bonjour."
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                path.append(Destination.setupCode)
            } label: {
                SharedGatewayChoiceCard(
                    icon: "key.viewfinder",
                    title: setupCodeTitle,
                    subtitle: setupCodeSubtitle
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 480)
    }

    private var requiresCloudDeployConfirmation: Bool {
        cloudDeployConfirmationTitle != nil || cloudDeployConfirmationMessage != nil
    }

    private var cloudDeployConfirmation: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(cloudDeployConfirmationTitle ?? "Continue?")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                if let cloudDeployConfirmationMessage {
                    Text(cloudDeployConfirmationMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(spacing: 12) {
                Button {
                    onCloudDeploy?()
                } label: {
                    Text(cloudDeployConfirmationButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    showCloudDeployConfirmation = false
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 480)
    }

    private var setupCodeTitle: String {
        onCloudDeploy == nil ? "Cloud or Setup Code" : "Setup Code"
    }

    private var setupCodeSubtitle: String {
        if onCloudDeploy == nil {
            return "Connect a cloud gateway with a setup code, or enter URL + token manually."
        }
        return "Paste a code from your gateway dashboard, or enter URL + token manually."
    }
}

#if DEBUG
#Preview("Choose Gateway — Cloud First") {
    SharedChooseGatewayView(
        onCloudDeploy: {},
        discovery: PreviewGatewayDiscovery(discoveredGateways: [PreviewGatewayDiscovery.nearbyMac]),
        onConnect: { _ in }
    )
}

#Preview("Choose Gateway — Repair Existing") {
    SharedChooseGatewayView(
        onCloudDeploy: {},
        cloudDeployTitle: "Repair Cloud Gateway",
        cloudDeploySubtitle: "Reconnect your existing Fly.io gateway. This will not create a second cloud gateway.",
        cloudDeployBadge: "Existing",
        cloudDeployConfirmationTitle: "Repair Cloud Gateway?",
        cloudDeployConfirmationMessage: "This may update your active managed gateway and connection token.",
        cloudDeployConfirmationButtonTitle: "Repair Gateway",
        discovery: PreviewGatewayDiscovery(),
        onConnect: { _ in }
    )
}
#endif
