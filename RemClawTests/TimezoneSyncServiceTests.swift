import Foundation
import Testing
@testable import RemClaw

@MainActor
struct TimezoneSyncServiceTests {
    @Test func coalescedGatewayTriggerReplaysAfterInFlightAttemptSettles() {
        var coalescer = GatewayTimezoneSyncCoalescer()

        let firstAttemptStarted = coalescer.begin(target: "gateway-a")
        let secondAttemptCoalesced = coalescer.begin(target: "gateway-a")
        let replayRequired = coalescer.finish(target: "gateway-a")
        let replayStarted = coalescer.begin(target: "gateway-a")
        let anotherReplayRequired = coalescer.finish(target: "gateway-a")

        #expect(firstAttemptStarted)
        #expect(!secondAttemptCoalesced)
        #expect(replayRequired)
        #expect(replayStarted)
        #expect(!anotherReplayRequired)
    }

    @Test func configSnapshotDecodesCurrentGatewayTimezone() throws {
        let data = try #require(
            #"{"hash":"config-hash","config":{"agents":{"defaults":{"userTimezone":"America/Los_Angeles"}}}}"#
                .data(using: .utf8)
        )
        let snapshot = try JSONDecoder().decode(ConfigGetResponse.self, from: data)

        #expect(snapshot.config?.agents?.defaults?.userTimezone == "America/Los_Angeles")
        #expect(snapshot.patchBaseHash == "config-hash")
    }

    @Test func gatewayPatchUsesStructuredUpstreamTimezoneConfig() throws {
        let paramsJSON = try TimezoneSyncService.gatewayTimezonePatchParamsJSON(
            timezone: "America/Los_Angeles",
            baseHash: "config-hash"
        )
        let paramsData = try #require(paramsJSON.data(using: .utf8))
        let params = try JSONSerialization.jsonObject(with: paramsData) as? [String: Any]

        #expect(params?["baseHash"] as? String == "config-hash")
        let raw = try #require(params?["raw"] as? String)
        let rawData = try #require(raw.data(using: .utf8))
        let patch = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        let agents = patch?["agents"] as? [String: Any]
        let defaults = agents?["defaults"] as? [String: Any]
        #expect(defaults?["userTimezone"] as? String == "America/Los_Angeles")
    }

    @Test func gatewayPatchRequiresConcurrencyHash() {
        #expect(throws: Error.self) {
            try TimezoneSyncService.gatewayTimezonePatchParamsJSON(
                timezone: "America/Los_Angeles",
                baseHash: nil
            )
        }
    }
}
