import Foundation
import Testing
@testable import RemClawMac

@MainActor
struct VoiceUtteranceConfigurationLifecycleMacTests {
    @Test func macVoiceSelectionIsPinnedForCurrentUtteranceAndRefreshedForNext() async {
        let config = MacTalkConfigResponseSequence([
            .voice("voice-before-settings-change"),
            .voice("voice-after-settings-change"),
        ])
        let manager = RemMacTalkModeManager()
        manager.talkConfigRequestForTesting = { try await config.next() }

        let firstVoice = await manager.beginIncrementalUtteranceForTesting()
        #expect(firstVoice == "voice-before-settings-change")

        let stillFirstVoice = await manager.currentIncrementalUtteranceVoiceForTesting()
        let firstRequestCount = await config.requestCount
        #expect(stillFirstVoice == "voice-before-settings-change")
        #expect(firstRequestCount == 1)

        let nextVoice = await manager.beginIncrementalUtteranceForTesting()
        let finalRequestCount = await config.requestCount
        #expect(nextVoice == "voice-after-settings-change")
        #expect(finalRequestCount == 2)
    }

    @Test func macFailedNextUtteranceRefreshRetainsLastKnownGatewaySelection() async {
        let config = MacTalkConfigResponseSequence([
            .voice("last-confirmed-voice"),
            .failure,
        ])
        let manager = RemMacTalkModeManager()
        manager.talkConfigRequestForTesting = { try await config.next() }

        let firstVoice = await manager.beginIncrementalUtteranceForTesting()
        let retainedVoice = await manager.beginIncrementalUtteranceForTesting()
        let requestCount = await config.requestCount
        #expect(firstVoice == "last-confirmed-voice")
        #expect(retainedVoice == "last-confirmed-voice")
        #expect(requestCount == 2)
    }
}

private actor MacTalkConfigResponseSequence {
    enum Response: Sendable {
        case voice(String)
        case failure
    }

    private var responses: [Response]
    private(set) var requestCount = 0

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func next() throws -> Data {
        requestCount += 1
        guard !responses.isEmpty else { throw MacTalkConfigFixtureError.exhausted }
        switch responses.removeFirst() {
        case .voice(let voiceID):
            return Data(
                """
                {
                  "config": {
                    "talk": {
                      "provider": "elevenlabs",
                      "providers": {
                        "elevenlabs": {
                          "voiceId": "\(voiceID)",
                          "modelId": "model-v3",
                          "outputFormat": "mp3_44100_128"
                        }
                      }
                    }
                  }
                }
                """.utf8
            )
        case .failure:
            throw MacTalkConfigFixtureError.unavailable
        }
    }
}

private enum MacTalkConfigFixtureError: Error {
    case exhausted
    case unavailable
}
