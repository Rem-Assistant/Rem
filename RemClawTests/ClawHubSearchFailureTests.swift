import Foundation
import Testing
@testable import RemClaw

struct ClawHubSearchFailureTests {
    @Test func mapsUnknownSkillsSearchMethodToUnsupportedGateway() {
        let failure = ClawHubSearchFailure.from(
            errorDescription: "skills.search: [INVALID_REQUEST] unknown method: skills.search"
        )

        #expect(failure == .unsupportedGateway)
        #expect(failure.title == "Skill browsing is not available")
        #expect(failure.message == "The active machine does not support ClawHub browsing yet. You can still manage installed skills here.")
    }

    @Test func mapsGenericErrorsToSearchFailedMessage() {
        let failure = ClawHubSearchFailure.from(errorDescription: "network request timed out")

        #expect(failure == .other(message: "network request timed out"))
        #expect(failure.title == "Search failed")
        #expect(failure.message == "network request timed out")
    }
}
