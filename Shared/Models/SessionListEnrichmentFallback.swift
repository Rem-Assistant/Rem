import Foundation
import OpenClawKit

/// Compatibility policy for gateways that predate enriched `sessions.list`
/// parameters. Only a structured schema rejection warrants a second request;
/// retrying timeouts, disconnects, auth failures, or cancellation would double
/// outage latency and outlive canceled searches.
enum SessionListEnrichmentFallback {
    nonisolated static func shouldRetryMinimalParams(after error: Error) -> Bool {
        guard let response = error as? GatewayResponseError else { return false }
        return response.method == "sessions.list" && response.code == "INVALID_REQUEST"
    }
}
