import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct VoiceSessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var startedAt: Date
        var isListening: Bool
        var isSpeaking: Bool
        var latestUserMessage: String?
        var latestAssistantMessage: String?
    }

    var sessionKey: String
}
#endif
