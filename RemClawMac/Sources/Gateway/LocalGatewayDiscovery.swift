import Foundation
import Network
import os

private let log = Logger(subsystem: "app.remclaw.mac", category: "gateway-discovery")

// `DiscoveredGateway` lives in Shared/Models so iOS and Mac share the same model.

/// Browses the local network for OpenClaw gateways advertised via
/// `_openclaw-gw._tcp` using Network.framework's `NWBrowser`.
@MainActor @Observable
final class LocalGatewayDiscovery: GatewayDiscovering {

    private(set) var discoveredGateways: [DiscoveredGateway] = []
    private(set) var isBrowsing: Bool = false

    /// macOS doesn't gate local-network access — always treat as authorized
    /// so the shared protocol stays meaningful across platforms.
    let permissionState: LocalNetworkPermissionState = .authorized

    private var browser: NWBrowser?

    /// Starts browsing for `_openclaw-gw._tcp` services on the local network.
    func startBrowsing() {
        guard browser == nil else { return }

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_openclaw-gw._tcp", domain: nil)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let newBrowser = NWBrowser(for: descriptor, using: parameters)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                    log.info("mDNS browser ready")
                case .failed(let error):
                    log.error("mDNS browser failed: \(error)")
                    self?.isBrowsing = false
                case .cancelled:
                    self?.isBrowsing = false
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

    /// Stops browsing.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discoveredGateways = []
        log.info("stopped mDNS browsing")
    }

    // MARK: - Private

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var gateways: [DiscoveredGateway] = []

        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                continue
            }

            let displayName = name
            let serviceID = "\(name).\(type).\(domain)"

            // Use default port; mDNS service records carry the port but
            // NWBrowser.Result doesn't expose it directly without resolving.
            let resolvedPort = UInt16(LocalGatewayManager.defaultPort)

            let gateway = DiscoveredGateway(
                id: serviceID,
                name: displayName,
                host: "\(name).local",
                port: resolvedPort
            )
            gateways.append(gateway)
        }

        discoveredGateways = gateways
        if !gateways.isEmpty {
            log.info("discovered \(gateways.count) gateway(s): \(gateways.map(\.name))")
        }
    }
}
