import Foundation
import OpenClawKit
import Testing
@testable import RemClaw

struct SessionListEnrichmentFallbackTests {
    @Test func retriesOnlyStructuredSessionListSchemaRejection() {
        #expect(SessionListEnrichmentFallback.shouldRetryMinimalParams(after: GatewayResponseError(
            method: "sessions.list",
            code: "INVALID_REQUEST",
            message: "unknown property includeDerivedTitles",
            details: nil)))

        #expect(!SessionListEnrichmentFallback.shouldRetryMinimalParams(after: GatewayResponseError(
            method: "sessions.list",
            code: "UNAVAILABLE",
            message: "gateway timed out",
            details: nil)))

        #expect(!SessionListEnrichmentFallback.shouldRetryMinimalParams(after: GatewayResponseError(
            method: "chat.history",
            code: "INVALID_REQUEST",
            message: "bad key",
            details: nil)))

        #expect(!SessionListEnrichmentFallback.shouldRetryMinimalParams(after: CancellationError()))
    }
}
