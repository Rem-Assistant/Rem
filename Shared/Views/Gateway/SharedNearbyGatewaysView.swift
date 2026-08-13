import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Lists OpenClaw gateways discovered on the local network via mDNS.
/// Generic over `Discovery: GatewayDiscovering` so iOS and Mac inject
/// their own concrete browser (`IOSGatewayDiscovery` / `LocalGatewayDiscovery`).
///
/// States rendered:
///   - **searching** — browser is up, no results yet
///   - **results** — one or more gateways found; tap to connect
///   - **permission denied** — iOS Local Network access blocked, with
///     "Open Settings" deep link
///   - **empty after window** — browser ready but nothing on the network
///
/// Browsing only starts when the view appears (so the iOS Local Network
/// permission prompt has user-initiated context, not a cold-launch
/// surprise).
struct SharedNearbyGatewaysView<Discovery: GatewayDiscovering>: View {

    let discovery: Discovery
    var onConnect: (DiscoveredGateway) -> Void

    var body: some View {
        Group {
            switch state {
            case .denied:
                deniedView
            case .searching:
                searchingView
            case .empty:
                emptyView
            case .results(let gateways):
                resultsList(gateways)
            }
        }
        .navigationTitle("Nearby Gateways")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            discovery.startBrowsing()
        }
        .onDisappear {
            discovery.stopBrowsing()
        }
    }

    /// User-initiated retry. Stops then restarts the browser so the
    /// permission state machine re-evaluates from scratch.
    private func retry() {
        discovery.stopBrowsing()
        discovery.startBrowsing()
    }

    // MARK: - Computed state

    private enum DisplayState {
        case searching
        case empty
        case results([DiscoveredGateway])
        case denied
    }

    private var state: DisplayState {
        if discovery.permissionState == .denied {
            return .denied
        }
        if !discovery.discoveredGateways.isEmpty {
            return .results(discovery.discoveredGateways)
        }
        if discovery.isBrowsing {
            return .searching
        }
        return .empty
    }

    // MARK: - Subviews

    private var searchingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Searching for nearby gateways...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No gateways found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Make sure a gateway is running on your Mac and you're on the same Wi-Fi.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Local Network access blocked")
                .font(.title3)
            Text("Rem can't see gateways on your Wi-Fi without local network permission.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            #endif
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func resultsList(_ gateways: [DiscoveredGateway]) -> some View {
        List {
            Section {
                ForEach(gateways) { gateway in
                    Button {
                        onConnect(gateway)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gateway.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("\(gateway.host):\(String(gateway.port))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Tap a gateway to connect to it. You can also paste a setup code if your gateway isn't on the same network.")
                    .font(.footnote)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }
}

#if DEBUG
#Preview("Nearby Gateways — Empty") {
    NavigationStack {
        SharedNearbyGatewaysView(
            discovery: PreviewGatewayDiscovery(),
            onConnect: { _ in }
        )
    }
}

#Preview("Nearby Gateways — Searching") {
    NavigationStack {
        SharedNearbyGatewaysView(
            discovery: PreviewGatewayDiscovery(isBrowsing: true),
            onConnect: { _ in }
        )
    }
}

#Preview("Nearby Gateways — One Result") {
    NavigationStack {
        SharedNearbyGatewaysView(
            discovery: PreviewGatewayDiscovery(discoveredGateways: [PreviewGatewayDiscovery.nearbyMac]),
            onConnect: { _ in }
        )
    }
}

#Preview("Nearby Gateways — Permission Denied") {
    NavigationStack {
        SharedNearbyGatewaysView(
            discovery: PreviewGatewayDiscovery(permissionState: .denied),
            onConnect: { _ in }
        )
    }
}
#endif
