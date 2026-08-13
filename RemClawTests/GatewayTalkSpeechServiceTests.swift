import Foundation
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import RemClaw

private let canonicalMP3ResponseJSON: String = {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Shared/Tests/Fixtures/talk-canonical.mp3")
    let audio = try! Data(contentsOf: fixtureURL).base64EncodedString()
    return #"{"audioBase64":"\#(audio)","provider":"configured-provider","outputFormat":"mp3","mimeType":"audio/mpeg","fileExtension":".mp3"}"#
}()

@MainActor
struct GatewayTalkSpeechServiceTests {
    @Test func synthesisUsesAuthenticatedGatewayWithoutProviderCredentials() async throws {
        let gateway = GatewayTalkSpeechRequesterMock()
        let service = GatewayTalkSpeechService()
        service.attach(gateway)

        let audio = try await service.synthesize(GatewayTalkSpeechRequest(
            text: "Hello",
            voiceId: "saved-voice",
            modelId: "saved-model"
        ))
        let call = try #require(await gateway.firstCall(method: "talk.speak"))
        let params = try #require(
            JSONSerialization.jsonObject(with: Data(call.paramsJSON.utf8)) as? [String: Any]
        )

        #expect(audio.provider == "configured-provider")
        #expect(params["text"] as? String == "Hello")
        #expect(params["voiceId"] as? String == "saved-voice")
        #expect(params["modelId"] as? String == "saved-model")
        #expect(params["outputFormat"] as? String == "mp3_44100_128")
        #expect((params["previewId"] as? String)?.isEmpty == false)
        #expect(params["provider"] == nil)
        #expect(params["apiKey"] == nil)
    }

    @Test func rejectsNonCanonicalAudioBeforeNativePlayback() async {
        let gateway = GatewayTalkSpeechRequesterMock(responseJSON:
            #"{"audioBase64":"UklGRndhdi1maXh0dXJl","provider":"google","outputFormat":"wav","mimeType":"audio/wav","fileExtension":".wav"}"#)
        let service = GatewayTalkSpeechService()
        service.attach(gateway)

        do {
            _ = try await service.synthesize(GatewayTalkSpeechRequest(text: "Hello"))
            Issue.record("Expected non-canonical audio to be rejected")
        } catch GatewayTalkSpeechError.invalidResponse {
            // Expected: WAV/generic PCM never reaches the MP3 player.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func playbackPolicyRejectsCanonicalDescriptorsWithInvalidMP3Frames() throws {
        let response = try JSONDecoder().decode(
            GatewayTalkSpeechAudio.self,
            from: Data(
                #"{"audioBase64":"bm90LWFuLW1wMw==","provider":"configured-provider","outputFormat":"mp3","mimeType":"audio/mpeg","fileExtension":".mp3"}"#.utf8
            )
        )

        #expect(GatewayTalkSpeechPlaybackPolicy.playableData(from: response) == nil)
    }

    @Test func cancelAllTargetsTheExactInFlightAttempt() async throws {
        let gateway = GatewayTalkSpeechRequesterMock(blockSpeak: true)
        let service = GatewayTalkSpeechService()
        service.attach(gateway)
        let synthesis = Task {
            try await service.synthesize(GatewayTalkSpeechRequest(text: "Hello"))
        }
        await gateway.waitForCall(method: "talk.speak")
        let speak = try #require(await gateway.firstCall(method: "talk.speak"))
        let speakParams = try #require(
            JSONSerialization.jsonObject(with: Data(speak.paramsJSON.utf8)) as? [String: Any]
        )
        let previewId = try #require(speakParams["previewId"] as? String)

        service.cancelAll()
        await gateway.waitForCall(method: "talk.speak.cancel")
        let cancel = try #require(await gateway.firstCall(method: "talk.speak.cancel"))
        let cancelParams = try #require(
            JSONSerialization.jsonObject(with: Data(cancel.paramsJSON.utf8)) as? [String: Any]
        )

        #expect(cancelParams["previewId"] as? String == previewId)
        await gateway.releaseSpeak()
        _ = try await synthesis.value
    }

    @Test func fallbackRequiresStructuredGatewayEligibility() {
        let eligible = GatewayResponseError(
            method: "talk.speak",
            code: "UNAVAILABLE",
            message: "unavailable",
            details: ["fallbackEligible": AnyCodable(true)]
        )
        let transient = GatewayResponseError(
            method: "talk.speak",
            code: "UNAVAILABLE",
            message: "provider temporarily unavailable",
            details: ["reason": AnyCodable("synthesis_failed")]
        )

        #expect(GatewayTalkSpeechFallbackPolicy.shouldUseSystemVoice(for: eligible))
        #expect(!GatewayTalkSpeechFallbackPolicy.shouldUseSystemVoice(for: transient))
        #expect(!GatewayTalkSpeechFallbackPolicy.shouldUseSystemVoice(
            for: URLError(.networkConnectionLost)
        ))
    }

    @Test func retriesLegacyGatewayWithoutPreviewIDOnlyForThatSchemaError() async throws {
        let compatibilityError = GatewayResponseError(
            method: "talk.speak",
            code: "INVALID_REQUEST",
            message: "invalid talk.speak params: at root: unexpected property 'previewId'",
            details: nil
        )
        let gateway = GatewayTalkSpeechRequesterMock(firstSpeakError: compatibilityError)
        let service = GatewayTalkSpeechService()
        service.attach(gateway)

        _ = try await service.synthesize(GatewayTalkSpeechRequest(text: "Read this"))

        let calls = await gateway.calls(method: "talk.speak")
        #expect(calls.count == 2)
        let first = try #require(
            JSONSerialization.jsonObject(with: Data(calls[0].paramsJSON.utf8)) as? [String: Any]
        )
        let second = try #require(
            JSONSerialization.jsonObject(with: Data(calls[1].paramsJSON.utf8)) as? [String: Any]
        )
        #expect(first["previewId"] != nil)
        #expect(second["previewId"] == nil)
        #expect(GatewayTalkSpeechCompatibility.shouldRetryWithoutPreviewID(for: compatibilityError))
        #expect(!GatewayTalkSpeechCompatibility.shouldRetryWithoutPreviewID(for: URLError(.badURL)))
    }

    @Test func cancellationPreventsLegacyCompatibilityRetry() async throws {
        let compatibilityError = GatewayResponseError(
            method: "talk.speak",
            code: "INVALID_REQUEST",
            message: "invalid talk.speak params: at root: unexpected property 'previewId'",
            details: nil
        )
        let gateway = GatewayTalkSpeechRequesterMock(
            blockSpeak: true,
            firstSpeakError: compatibilityError
        )
        let service = GatewayTalkSpeechService()
        service.attach(gateway)
        let synthesis = Task {
            try await service.synthesize(GatewayTalkSpeechRequest(text: "Do not read this"))
        }
        await gateway.waitForCall(method: "talk.speak")

        synthesis.cancel()
        await gateway.releaseSpeak()

        do {
            _ = try await synthesis.value
            Issue.record("Expected cancellation before the legacy retry")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await gateway.calls(method: "talk.speak").count == 1)
    }
}

private actor GatewayTalkSpeechRequesterMock: GatewayTalkSpeechRequesting {
    struct Call: Sendable {
        let method: String
        let paramsJSON: String
    }

    private var calls: [Call] = []
    private let blockSpeak: Bool
    private let responseJSON: String
    private let firstSpeakError: Error?
    private var speakContinuation: CheckedContinuation<Void, Never>?
    private var speakCallCount = 0

    init(
        blockSpeak: Bool = false,
        responseJSON: String = canonicalMP3ResponseJSON,
        firstSpeakError: Error? = nil
    ) {
        self.blockSpeak = blockSpeak
        self.responseJSON = responseJSON
        self.firstSpeakError = firstSpeakError
    }

    func request(method: String, paramsJSON: String?, timeoutSeconds _: Int) async throws -> Data {
        calls.append(Call(method: method, paramsJSON: paramsJSON ?? "{}"))
        if method == "talk.speak" {
            speakCallCount += 1
        }
        if method == "talk.speak", blockSpeak {
            await withCheckedContinuation { continuation in
                speakContinuation = continuation
            }
        }
        if method == "talk.speak", speakCallCount == 1, let firstSpeakError {
            throw firstSpeakError
        }
        if method == "talk.speak.cancel" {
            return Data(#"{"ok":true,"cancelled":true}"#.utf8)
        }
        return Data(responseJSON.utf8)
    }

    func firstCall(method: String) -> Call? {
        calls.first { $0.method == method }
    }

    func calls(method: String) -> [Call] {
        calls.filter { $0.method == method }
    }

    func waitForCall(method: String) async {
        while firstCall(method: method) == nil {
            await Task.yield()
        }
    }

    func releaseSpeak() {
        speakContinuation?.resume()
        speakContinuation = nil
    }
}
