import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.remclaw", category: "gateway-discovery")

/// Browses the local network for OpenClaw gateways advertised via
/// `_openclaw-gw._tcp` using `Network.framework`'s `NWBrowser`.
///
/// iOS gates local-network access behind an explicit permission prompt
/// (added in iOS 14). Calling `startBrowsing()` triggers the prompt the
/// first time — we only call it from a user-initiated tap on the Nearby
/// tile, never at cold launch, so the prompt has visible context.
///
/// **Permission detection**: iOS provides no API that says "user granted
/// or denied Local Network." We can only infer:
/// - If results arrive → `.authorized` (the OS only delivers mDNS when
///   the user authorized).
/// - If `NWBrowser` enters `.failed` → `.denied` (the typical cause on
///   iOS, though not the only one).
/// - Otherwise stays `.undetermined`. We never auto-downgrade to
///   `.denied` based on a "no results in N seconds" heuristic — that
///   would falsely flag empty LANs (coffee shops, networks with no
///   gateways) as a denial. The view shows a clean empty state in that
///   case, with a manual "Try again" affordance.
///
/// Mirrors the Mac `LocalGatewayDiscovery` and conforms to
/// `GatewayDiscovering` so `SharedNearbyGatewaysView` can render either.
@MainActor @Observable
final class IOSGatewayDiscovery: GatewayDiscovering {

    private(set) var discoveredGateways: [DiscoveredGateway] = []
    private(set) var isBrowsing: Bool = false
    private(set) var permissionState: LocalNetworkPermissionState = .undetermined

    // TODO(#252): port discovery — when gateway TXT records carry the
    // port, parse it instead of assuming the default. Mac's
    // LocalGatewayDiscovery has the same hard-coded assumption today.
    /// Default port advertised by an OpenClaw gateway.
    static let defaultPort: UInt16 = 19000

    private var browser: NWBrowser?

    func startBrowsing() {
        guard browser == nil else { return }

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_openclaw-gw._tcp", domain: nil)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let newBrowser = NWBrowser(for: descriptor, using: parameters)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                    log.info("mDNS browser ready")
                case .failed(let error):
                    log.error("mDNS browser failed: \(error.localizedDescription)")
                    self.isBrowsing = false
                    // On iOS, `NWBrowser` failure is most commonly caused by
                    // local-network permission denial. Other causes are rare
                    // (network framework internal errors). Mapping to .denied
                    // surfaces the actionable "Open Settings" UI; in the rare
                    // false-positive case the user can retry, which restarts
                    // the browser and re-evaluates state.
                    self.permissionState = .denied
                case .cancelled:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results)
            }
        }

        newBrowser.start(queue: .main)
        self.browser = newBrowser
        log.info("started mDNS browsing for _openclaw-gw._tcp")
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        // Clear results so a re-appear of the view doesn't flash stale
        // gateways while the new browser warms up. Matches Mac behavior.
        discoveredGateways = []
    }

    // MARK: - Private

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var gateways: [DiscoveredGateway] = []

        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                continue
            }

            let serviceID = "\(name).\(type).\(domain)"
            let gateway = DiscoveredGateway(
                id: serviceID,
                name: name,
                host: "\(name).local",
                port: Self.defaultPort
            )
            gateways.append(gateway)
        }

        // Receiving a result implies permission is granted (the OS only
        // delivers mDNS data after the user authorized).
        if !gateways.isEmpty {
            permissionState = .authorized
        }

        discoveredGateways = gateways
        if !gateways.isEmpty {
            log.info("discovered \(gateways.count) gateway(s): \(gateways.map(\.name))")
        }
    }
}
