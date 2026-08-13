import Foundation
import OpenClawKit
import OpenClawProtocol

protocol GatewayTalkSpeechRequesting: Sendable {
    func request(method: String, paramsJSON: String?, timeoutSeconds: Int) async throws -> Data
}

extension GatewayNodeSession: GatewayTalkSpeechRequesting {}

struct GatewayTalkSpeechRequest: Encodable, Equatable, Sendable {
    let text: String
    var previewId: String?
    var voiceId: String?
    var modelId: String?
    var outputFormat: String?
    var speed: Double?
    var rateWpm: Int?
    var stability: Double?
    var similarity: Double?
    var style: Double?
    var speakerBoost: Bool?
    var seed: Int?
    var normalize: String?
    var language: String?
    var latencyTier: Int?

    init(
        text: String,
        previewId: String? = nil,
        voiceId: String? = nil,
        modelId: String? = nil,
        outputFormat: String? = nil,
        speed: Double? = nil,
        rateWpm: Int? = nil,
        stability: Double? = nil,
        similarity: Double? = nil,
        style: Double? = nil,
        speakerBoost: Bool? = nil,
        seed: Int? = nil,
        normalize: String? = nil,
        language: String? = nil,
        latencyTier: Int? = nil
    ) {
        self.text = text
        self.previewId = previewId
        self.voiceId = voiceId
        self.modelId = modelId
        self.outputFormat = outputFormat
        self.speed = speed
        self.rateWpm = rateWpm
        self.stability = stability
        self.similarity = similarity
        self.style = style
        self.speakerBoost = speakerBoost
        self.seed = seed
        self.normalize = normalize
        self.language = language
        self.latencyTier = latencyTier
    }
}

struct GatewayTalkSpeechAudio: Decodable, Equatable, Sendable {
    let audioBase64: String
    let provider: String
    let outputFormat: String?
    let mimeType: String?
    let fileExtension: String?

    var data: Data? { Data(base64Encoded: audioBase64) }

    var isCanonicalMP3: Bool {
        guard outputFormat?.lowercased() == "mp3",
              mimeType?.lowercased() == "audio/mpeg",
              fileExtension?.lowercased() == ".mp3",
              let data,
              data.isEmpty == false
        else { return false }
        return MP3FrameValidator.isValid(data)
    }
}

enum GatewayTalkSpeechPlaybackPolicy {
    /// Native players only receive audio that satisfies the gateway's complete
    /// buffered MP3 contract. Descriptor-only checks are not sufficient because
    /// malformed or mislabeled payloads can otherwise reach AVAudioPlayer.
    static func playableData(from audio: GatewayTalkSpeechAudio) -> Data? {
        guard audio.isCanonicalMP3 else { return nil }
        return audio.data
    }
}

enum GatewayTalkSpeechError: Error {
    case unavailable
    case invalidRequest
    case invalidResponse
}

enum GatewayTalkSpeechFallbackPolicy {
    static func shouldUseSystemVoice(for error: Error) -> Bool {
        guard let response = error as? GatewayResponseError,
              response.method.caseInsensitiveCompare("talk.speak") == .orderedSame
        else { return false }
        if response.details["fallbackEligible"]?.value as? Bool == true {
            return true
        }
        switch response.detailsReason?.lowercased() {
        case "talk_unconfigured", "talk_provider_unsupported", "method_unavailable":
            return true
        default:
            return false
        }
    }
}

enum GatewayTalkSpeechCompatibility {
    /// Gateways released before cancellable previews reject `previewId` at schema validation.
    /// Retry that one narrow compatibility failure without the field; all other invalid requests
    /// remain visible programming/configuration errors.
    static func shouldRetryWithoutPreviewID(for error: Error) -> Bool {
        guard let response = error as? GatewayResponseError,
              response.method.caseInsensitiveCompare("talk.speak") == .orderedSame,
              response.code.caseInsensitiveCompare("INVALID_REQUEST") == .orderedSame
        else { return false }
        let message = response.message.lowercased()
        return message.contains("unexpected property") && message.contains("previewid")
    }
}

/// Authenticated, provider-neutral Talk synthesis transport shared by iOS and macOS.
///
/// The gateway owns provider selection and credentials. Each request receives a
/// unique id before its RPC is sent; cancellation sends the matching
/// `talk.speak.cancel`, including when task cancellation races request dispatch.
@MainActor
final class GatewayTalkSpeechService {
    private var gateway: (any GatewayTalkSpeechRequesting)?
    private var activeRequests: [String: any GatewayTalkSpeechRequesting] = [:]

    func attach(_ gateway: (any GatewayTalkSpeechRequesting)?) {
        if gateway == nil {
            cancelAll()
        }
        self.gateway = gateway
    }

    func synthesize(_ request: GatewayTalkSpeechRequest) async throws -> GatewayTalkSpeechAudio {
        guard let gateway else { throw GatewayTalkSpeechError.unavailable }
        let previewId = UUID().uuidString
        var request = request
        request.previewId = previewId
        request.outputFormat = IncrementalSpeechPrefetchPolicy.bufferedOutputFormat(
            for: request.outputFormat)
        let data = try JSONEncoder().encode(request)
        guard let paramsJSON = String(data: data, encoding: .utf8) else {
            throw GatewayTalkSpeechError.invalidRequest
        }
        activeRequests[previewId] = gateway

        return try await withTaskCancellationHandler {
            defer { activeRequests.removeValue(forKey: previewId) }
            let responseData: Data
            do {
                responseData = try await gateway.request(
                    method: "talk.speak",
                    paramsJSON: paramsJSON,
                    timeoutSeconds: 45
                )
            } catch where GatewayTalkSpeechCompatibility.shouldRetryWithoutPreviewID(for: error) {
                // The legacy request cannot be cancelled by preview id, so stop advertising it as
                // an active cancellable request before retrying. Task cancellation still stops the
                // client wait; current gateways continue using the cancellable path above.
                activeRequests.removeValue(forKey: previewId)
                try Task.checkCancellation()
                request.previewId = nil
                let legacyData = try JSONEncoder().encode(request)
                guard let legacyParamsJSON = String(data: legacyData, encoding: .utf8) else {
                    throw GatewayTalkSpeechError.invalidRequest
                }
                responseData = try await gateway.request(
                    method: "talk.speak",
                    paramsJSON: legacyParamsJSON,
                    timeoutSeconds: 45
                )
            }
            try Task.checkCancellation()
            let response = try JSONDecoder().decode(GatewayTalkSpeechAudio.self, from: responseData)
            guard GatewayTalkSpeechPlaybackPolicy.playableData(from: response) != nil else {
                throw GatewayTalkSpeechError.invalidResponse
            }
            return response
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(previewId: previewId)
            }
        }
    }

    func cancelAll() {
        let requests = activeRequests
        activeRequests.removeAll()
        for (previewId, gateway) in requests {
            Task { await Self.sendCancel(previewId: previewId, gateway: gateway) }
        }
    }

    private func cancel(previewId: String) {
        guard let gateway = activeRequests.removeValue(forKey: previewId) else { return }
        Task { await Self.sendCancel(previewId: previewId, gateway: gateway) }
    }

    private static func sendCancel(
        previewId: String,
        gateway: any GatewayTalkSpeechRequesting
    ) async {
        let params = ["previewId": previewId]
        guard let data = try? JSONEncoder().encode(params),
              let paramsJSON = String(data: data, encoding: .utf8)
        else { return }
        _ = try? await gateway.request(
            method: "talk.speak.cancel",
            paramsJSON: paramsJSON,
            timeoutSeconds: 5
        )
    }
}
