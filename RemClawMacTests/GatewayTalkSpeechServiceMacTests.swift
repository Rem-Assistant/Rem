import Foundation
import OpenClawKit
import Testing
@testable import RemClawMac

private let canonicalMacMP3ResponseJSON: String = {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Shared/Tests/Fixtures/talk-canonical.mp3")
    let audio = try! Data(contentsOf: fixtureURL).base64EncodedString()
    return #"{"audioBase64":"\#(audio)","provider":"configured-provider","outputFormat":"mp3","mimeType":"audio/mpeg","fileExtension":".mp3"}"#
}()

@MainActor
struct GatewayTalkSpeechServiceMacTests {
    @Test func macLargeBufferedParagraphWaitsForAudibleCompletion() async {
        let paragraphAudio = Data(repeating: 0x5a, count: 160 * 1_024)
        let player = SuspendedMacBufferedMP3Player()
        let manager = RemMacTalkModeManager()
        manager.bufferedMP3Player = player
        let audio = GatewayTalkSpeechAudio(
            audioBase64: paragraphAudio.base64EncodedString(),
            provider: "test",
            outputFormat: "mp3",
            mimeType: "audio/mpeg",
            fileExtension: ".mp3"
        )
        var playbackReturned = false

        let playback = Task { @MainActor in
            let result = await manager.playGatewaySpeechAudio(audio)
            playbackReturned = true
            return result
        }
        await player.waitUntilStarted()

        #expect(player.receivedData == paragraphAudio)
        #expect(!playbackReturned)

        player.finishSuccessfully()
        let finished = await playback.value
        #expect(finished)
        #expect(playbackReturned)
    }

    @Test func macRuntimeUsesCanonicalSelectedProviderBeforeLegacyFlatValues() throws {
        let data = Data(
            """
            {
              "config": {
                "talk": {
                  "provider": "google",
                  "providers": {
                    "google": {
                      "voiceId": "canonical-voice",
                      "modelId": "canonical-model",
                      "outputFormat": "mp3"
                    }
                  },
                  "voiceId": "stale-flat-voice"
                }
              }
            }
            """.utf8
        )

        #expect(try VoiceSettingsConfigParser.runtimeSelection(from: data) == VoiceSettingsSelection(
            provider: "google",
            voiceID: "canonical-voice",
            modelID: "canonical-model",
            outputFormat: "mp3"
        ))
    }

    @Test func macSynthesisUsesTheProviderNeutralGatewayContract() async throws {
        let gateway = MacGatewayTalkSpeechRequesterMock()
        let service = GatewayTalkSpeechService()
        service.attach(gateway)

        let audio = try await service.synthesize(GatewayTalkSpeechRequest(
            text: "Hello from Mac",
            voiceId: "saved-voice"
        ))
        let call = try #require(await gateway.speakCall())
        let params = try #require(
            JSONSerialization.jsonObject(with: Data(call.utf8)) as? [String: Any]
        )

        #expect(audio.provider == "configured-provider")
        #expect(params["voiceId"] as? String == "saved-voice")
        #expect(params["outputFormat"] as? String == "mp3_44100_128")
        #expect((params["previewId"] as? String)?.isEmpty == false)
        #expect(params["provider"] == nil)
        #expect(params["apiKey"] == nil)
    }

    @Test func macRejectsWAVBeforeTheMP3Player() async {
        let gateway = MacGatewayTalkSpeechRequesterMock(responseJSON:
            #"{"audioBase64":"UklGRndhdi1maXh0dXJl","provider":"google","outputFormat":"wav","mimeType":"audio/wav","fileExtension":".wav"}"#)
        let service = GatewayTalkSpeechService()
        service.attach(gateway)

        do {
            _ = try await service.synthesize(GatewayTalkSpeechRequest(text: "Hello"))
            Issue.record("Expected non-canonical audio to be rejected")
        } catch GatewayTalkSpeechError.invalidResponse {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func macPlaybackPolicyRejectsCanonicalDescriptorsWithInvalidMP3Frames() throws {
        let response = try JSONDecoder().decode(
            GatewayTalkSpeechAudio.self,
            from: Data(
                #"{"audioBase64":"bm90LWFuLW1wMw==","provider":"configured-provider","outputFormat":"mp3","mimeType":"audio/mpeg","fileExtension":".mp3"}"#.utf8
            )
        )

        #expect(GatewayTalkSpeechPlaybackPolicy.playableData(from: response) == nil)
    }
}

@MainActor
private final class SuspendedMacBufferedMP3Player: BufferedMP3AudioPlaying {
    private(set) var receivedData: Data?
    private var continuation: CheckedContinuation<StreamingPlaybackResult, Never>?

    func play(data: Data) async -> StreamingPlaybackResult {
        receivedData = data
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stop() -> Double? {
        continuation?.resume(returning: StreamingPlaybackResult(finished: false, interruptedAt: 0))
        continuation = nil
        return 0
    }

    func waitUntilStarted() async {
        while receivedData == nil || continuation == nil {
            await Task.yield()
        }
    }

    func finishSuccessfully() {
        continuation?.resume(returning: StreamingPlaybackResult(finished: true, interruptedAt: nil))
        continuation = nil
    }
}

private actor MacGatewayTalkSpeechRequesterMock: GatewayTalkSpeechRequesting {
    private var calls: [(String, String)] = []
    private let responseJSON: String

    init(
        responseJSON: String = canonicalMacMP3ResponseJSON
    ) {
        self.responseJSON = responseJSON
    }

    func request(method: String, paramsJSON: String?, timeoutSeconds _: Int) async throws -> Data {
        calls.append((method, paramsJSON ?? "{}"))
        return Data(responseJSON.utf8)
    }

    func speakCall() -> String? {
        calls.first { $0.0 == "talk.speak" }?.1
    }
}
