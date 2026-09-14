import AppIntents
import Foundation

struct PauseFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Focus Session"
    static var description = IntentDescription("Pause the currently running focus session")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session ID")
    var sessionId: String

    init() {}

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func perform() async throws -> some IntentResult {
        FocusSessionSharedState.pendingAction = "pause:\(sessionId)"

        NotificationCenter.default.post(
            name: Notification.Name("remclaw.didOpenURL"),
            object: URL(string: "remclaw://focus/pause?sessionId=\(sessionId)")!
        )

        return .result()
    }
}

struct ResumeFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Focus Session"
    static var description = IntentDescription("Resume the paused focus session")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session ID")
    var sessionId: String

    init() {}

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func perform() async throws -> some IntentResult {
        FocusSessionSharedState.pendingAction = "resume:\(sessionId)"

        NotificationCenter.default.post(
            name: Notification.Name("remclaw.didOpenURL"),
            object: URL(string: "remclaw://focus/resume?sessionId=\(sessionId)")!
        )

        return .result()
    }
}

struct StopFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Focus Session"
    static var description = IntentDescription("Stop and end the focus session")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session ID")
    var sessionId: String

    init() {}

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func perform() async throws -> some IntentResult {
        FocusSessionSharedState.pendingAction = "stop:\(sessionId)"

        NotificationCenter.default.post(
            name: Notification.Name("remclaw.didOpenURL"),
            object: URL(string: "remclaw://focus/stop?sessionId=\(sessionId)")!
        )

        return .result()
    }
}

struct StartFocusSessionFromPreSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Focus Session"
    static var description = IntentDescription("Start a focus session for the scheduled task")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Task Title")
    var taskTitle: String

    @Parameter(title: "Duration")
    var duration: TimeInterval?

    init() {}

    init(taskId: String, taskTitle: String, duration: TimeInterval? = nil) {
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.duration = duration
    }

    func perform() async throws -> some IntentResult {
        var actionString = "startFromPreSession:\(taskId):\(taskTitle)"
        if let duration {
            actionString += ":\(Int(duration))"
        }
        FocusSessionSharedState.pendingAction = actionString

        var urlString = "remclaw://focus/startFromPreSession?taskId=\(taskId)&taskTitle=\(taskTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskTitle)"
        if let duration {
            urlString += "&duration=\(Int(duration))"
        }

        NotificationCenter.default.post(
            name: Notification.Name("remclaw.didOpenURL"),
            object: URL(string: urlString)!
        )

        return .result()
    }
}
