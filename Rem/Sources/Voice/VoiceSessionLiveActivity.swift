#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

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

@MainActor
final class VoiceSessionLiveActivityManager {
    private var activity: Activity<VoiceSessionActivityAttributes>?
    private var startedAt: Date?

    func startOrUpdate(
        sessionKey: String,
        status: String,
        isListening: Bool,
        isSpeaking: Bool,
        latestUserMessage: String?,
        latestAssistantMessage: String?
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let startTime = startedAt ?? Date()
        startedAt = startTime

        let trimmedUser = latestUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistant = latestAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = VoiceSessionActivityAttributes.ContentState(
            status: status,
            startedAt: startTime,
            isListening: isListening,
            isSpeaking: isSpeaking,
            latestUserMessage: trimmedUser?.isEmpty == false ? trimmedUser : nil,
            latestAssistantMessage: trimmedAssistant?.isEmpty == false ? trimmedAssistant : nil
        )
        let content = ActivityContent(state: state, staleDate: nil)

        if let activity, activity.activityState == .active {
            await activity.update(content)
            return
        }

        let attributes = VoiceSessionActivityAttributes(sessionKey: sessionKey)
        activity = try? Activity.request(attributes: attributes, content: content)
    }

    func end() async {
        // End the handle we're holding, if any…
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
            self.activity = nil
        }
        // …AND sweep any live activity of this type we may have lost the handle to. Without this,
        // an activity started before an app relaunch/teardown (when `self.activity` is nil again)
        // would strand on the lock screen forever — `end()` used to early-return in that case.
        await endAllLiveActivities()
        startedAt = nil
    }

    /// Ends every live Voice Live Activity, including orphans this manager has no in-memory handle
    /// for. Call at launch (no voice session is active on a cold start, so any live one is a stray
    /// from a previous run that was killed mid-session) and as a belt-and-suspenders inside `end()`.
    func reconcileStaleActivitiesAtLaunch() async {
        await endAllLiveActivities()
    }

    private func endAllLiveActivities() async {
        for activity in Activity<VoiceSessionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
