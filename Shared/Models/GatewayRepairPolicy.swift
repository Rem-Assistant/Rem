import Foundation

enum GatewayRepairPolicy {
    static func shouldRunManagedCloudRepair(
        config: GatewayConfig?,
        storedProviderName: String,
        storedGatewayURL: String?
    ) -> Bool {
        if let config {
            return config.provider == .fly
        }

        if storedProviderName == "Fly.io" {
            return true
        }

        guard let storedGatewayURL,
              let host = URL(string: storedGatewayURL)?.host?.lowercased()
        else {
            return false
        }
        return host.hasSuffix(".fly.dev")
    }
}
